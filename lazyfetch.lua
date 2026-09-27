--[[--
Background image completion for lazily-built WikiReader EPUBs.

With "Fetch images in background" on, epub.lua builds the article EPUB
immediately, with each boxed image as a placeholder <img> whose zip entry
does not exist yet, and an OEBPS/wikireader-pending.json entry listing the
URLs to fetch. This module downloads those URLs asynchronously (KOReader's
turbo-based HTTPClient, so the UI never blocks), rewrites the EPUB zip with
the downloaded images added and the pending entry dropped, and seamlessly
reloads the open document — the images appear where their reserved
placeholders already were. A cached article that was interrupted
mid-download still carries its pending entry, so the next open finishes
it the same way. Failed downloads are removed from content.html and
content.opf so no blank squares remain.
]]

local Archiver = require("ffi/archiver")
local HTTPClient = require("httpclient")
local JSON = require("json")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local PENDING_ENTRY = "OEBPS/wikireader-pending.json"

local M = {}

-- Returns the pending image list from `epub_path`, or nil if the EPUB has
-- none (already completed, or not a lazy build).
local function readPending(epub_path)
    local reader = Archiver.Reader:new{}
    if not reader:open(epub_path) then
        logger.warn("WikiReader lazy: cannot open EPUB to read pending list:", epub_path)
        return nil
    end
    -- Reader:seek can only look up entries already walked over, so walk
    -- the archive once to populate its entry index before extracting.
    for entry in reader:iterate() do
        if entry.path == PENDING_ENTRY then
            local content = reader:extractToMemory(PENDING_ENTRY)
            reader:close()
            local ok, data = pcall(JSON.decode, content)
            if ok and type(data) == "table" and #data > 0 then
                return data
            end
            logger.warn("WikiReader lazy: pending entry unreadable:", content)
            return nil
        end
    end
    reader:close()
    logger.dbg("WikiReader lazy: no pending entry (already complete or not a lazy build)")
    return nil
end

-- Rewrites the zip in place: every original entry, plus the downloaded
-- image files, minus the pending entry (this build is now complete).
-- Failed downloads have their placeholder <img> and manifest item removed.
-- Rewrites the zip in place after one batch: adds the downloaded images,
-- removes the tags of attempted-but-failed ones (results[i] == false; they
-- would otherwise show as permanent blank squares), keeps not-yet-scheduled
-- placeholders intact (results[i] == nil), and rewrites the pending entry
-- with whatever remains. Drops the pending entry once nothing remains:
-- this build is then complete.
local function swapInImages(epub_path, images, results)
    local reader = Archiver.Reader:new{}
    if not reader:open(epub_path) then
        logger.warn("WikiReader lazy: swap failed opening EPUB:", reader.err)
        return false
    end
    local entries = {}
    for entry in reader:iterate() do
        if entry.mode == "file" and entry.path ~= PENDING_ENTRY then
            entries[entry.path] = reader:extractToMemory(entry.path)
        end
    end
    reader:close()
    local html = entries["OEBPS/content.html"]
    local opf = entries["OEBPS/content.opf"]
    if not html or not opf or not entries["mimetype"] then
        logger.warn("WikiReader lazy: swap failed, EPUB entries missing:",
            html ~= nil, opf ~= nil, entries["mimetype"] ~= nil)
        return false
    end
    local remaining = {}
    local ok_count = 0
    for i, img in ipairs(images) do
        local content = results[i]
        if content then
            ok_count = ok_count + 1
        elseif content == false then
            -- Attempted and failed: remove the placeholder <img> and its
            -- manifest item so no blank square remains.
            local path_pat = img.imgpath:gsub("%.", "%%.")
            html = html:gsub('<img src="' .. path_pat .. '"[^>]*>', "")
            local id = "wrimg" .. string.format("%05d", i)
            opf = opf:gsub('<item id="' .. id .. '"[^>]*/>%s*', "")
        else
            -- Not scheduled this cycle: keep the placeholder and the entry.
            remaining[#remaining + 1] = img
        end
    end
    entries["OEBPS/content.html"] = html
    entries["OEBPS/content.opf"] = opf
    if #remaining > 0 then
        local JSON = require("json")
        entries[PENDING_ENTRY] = JSON.encode(remaining)
    end

    -- Same .tmp-then-rename dance as the builders: renaming over the file
    -- crengine holds open is safe (it keeps reading the old inode), and a
    -- failed write never destroys the good EPUB.
    local tmp_path = epub_path .. ".tmp"
    local writer = Archiver.Writer:new{}
    if not writer:open(tmp_path, "epub") then
        logger.warn("WikiReader lazy: swap failed opening writer:", writer.err)
        return false
    end
    local mtime = os.time()
    -- mimetype must stay the first, uncompressed zip entry.
    writer:setZipCompression("store")
    writer:addFileFromMemory("mimetype", entries["mimetype"], mtime)
    writer:setZipCompression("deflate")
    for path, content in pairs(entries) do
        if path ~= "mimetype" then
            writer:addFileFromMemory(path, content, mtime)
        end
    end
    -- Photos are already compressed; only XML needs deflating.
    for i, img in ipairs(images) do
        local content = results[i]
        if content then
            writer:setZipCompression(img.mimetype == "image/svg+xml" and "deflate" or "store")
            writer:addFileFromMemory("OEBPS/" .. img.imgpath, content, mtime)
        end
    end
    writer:close()
    os.rename(tmp_path, epub_path)
    collectgarbage()
    logger.info("WikiReader lazy: fetched", ok_count, "images,", #remaining, "remaining")
    return true
end

-- Downloads the pending images, one per scheduled tick so the UI can
-- process events between requests.
--
-- ponytail: without the turbo looper (DUSE_TURBO_LIB is false by default)
-- each request briefly blocks the UI thread; per-image socketutil timeouts
-- (10s/30s) cap the worst case. Switch to a coroutine-sliced downloader if
-- freezes on slow networks become noticeable.
local function downloadAll(images, on_all_done)
    local results = {}
    local i = 0
    if UIManager.looper then
        -- Turbo looper available: fully asynchronous requests.
        local client = HTTPClient:new{}
        local function nextImage()
            i = i + 1
            if i > #images then
                on_all_done(results)
                return
            end
            client:request({ url = images[i].src }, function(res)
                if res and res.code == 200 and res.body and #res.body > 0 then
                    results[i] = res.body
                else
                    results[i] = false
                    logger.warn("WikiReader lazy: image download failed:", images[i].src, res and res.code)
                end
                UIManager:scheduleIn(0.05, nextImage)
            end)
        end
        nextImage()
    else
        -- Default KOReader (no turbo): blocking socket.http, one image per
        -- scheduled tick, same timeouts as the plugin's other HTTP calls.
        local socket_http = require("socket.http")
        local socketutil = require("socketutil")
        local function nextImage()
            i = i + 1
            if i > #images then
                on_all_done(results)
                return
            end
            local img = images[i]
            UIManager:scheduleIn(0.1, function()
                local sink = {}
                socketutil:set_timeout(10, 30)
                local pcall_ok = pcall(function()
                    local _, code = socket_http.request {
                        url = img.src,
                        sink = socketutil.table_sink(sink),
                    }
                    if code == 200 then
                        results[i] = table.concat(sink)
                    end
                end)
                -- Must run even after a pcall'd error, or all later
                -- LuaSocket traffic keeps the patched (tight) timeouts.
                socketutil:reset_timeout()
                if results[i] == nil then
                    results[i] = false
                    logger.warn("WikiReader lazy: image download failed:",
                        img.src, "pcall_ok:", pcall_ok)
                end
                nextImage()
            end)
        end
        nextImage()
    end
end

-- Position-windowed background buffering, like a video player pre-loading
-- ahead of the playhead:
--
--   W_AHEAD_PAGES   fetch images whose article section starts up to this
--                   many pages past the reading position.
--   W_BEHIND_PAGES  also fetch images this many pages back (TOC jumps
--                   otherwise leave everything behind the new position
--                   unfetched). Images further behind than this stay
--                   unfetched until the position moves near them again.
--   CHECK_INTERVAL  how often the window is re-evaluated while the article
--                   is open. Each cycle only downloads newly-in-window
--                   images; every swap costs one flashless reload, so the
--                   window trades buffering against reload frequency.
local W_AHEAD_PAGES = 10
local W_BEHIND_PAGES = 3
local CHECK_INTERVAL = 20

-- Returns the live cre document while it is still showing `epub_path`.
local function liveDocument(epub_path)
    local ReaderUI = require("apps/reader/readerui")
    local ui = ReaderUI.instance
    if ui and ui.document and ui.document.file == epub_path then
        return ui.document
    end
    return nil
end

-- Reading position as a page number, or nil if it can't be determined yet.
local function currentPage(doc)
    local ok, page = pcall(function()
        return doc:getPageFromXPointer(doc:getXPointer())
    end)
    if ok and page and page > 0 then
        return page
    end
    return nil
end

-- Section index -> page, resolved through the document TOC (its entries are
-- in the same order as the sections recorded at build time; entry 1 covers
-- everything before the first heading). Cached pages shift slightly after
-- failed downloads remove placeholders, which only costs a bit of window
-- precision.
local function sectionPages(doc)
    local ok, toc = pcall(function() return doc:getToc() end)
    if not ok or type(toc) ~= "table" then
        return nil
    end
    local pages = {}
    for i, entry in ipairs(toc) do
        local ok2, page = pcall(function() return doc:getPageFromXPointer(entry.xpointer) end)
        if ok2 and page and page > 0 then
            pages[i] = page
        end
    end
    return pages
end

-- Splits the pending list into the images worth fetching now and the rest.
local function partition(images, doc)
    if not doc then
        -- No live reader (e.g. completion of a cached file without one):
        -- fetch everything, like the pre-buffering behavior.
        return images, {}
    end
    local pos = currentPage(doc)
    if not pos then
        -- Document still loading; wait for a later check rather than
        -- assuming the start and over-fetching.
        return {}, images
    end
    local pages = sectionPages(doc)
    if not pages then
        -- No usable TOC: cannot map images to pages; fetch everything.
        return images, {}
    end
    local batch, remaining = {}, {}
    for _, img in ipairs(images) do
        local page = pages[(img.section or 0) + 1]
        if page and page >= pos - W_BEHIND_PAGES and page <= pos + W_AHEAD_PAGES then
            batch[#batch + 1] = img
        elseif not page then
            -- Unmappable section: fetch it rather than leave a gap.
            batch[#batch + 1] = img
        else
            remaining[#remaining + 1] = img
        end
    end
    logger.dbg("WikiReader lazy: position page", pos, "-",
        #batch, "in window,", #remaining, "out of window")
    return batch, remaining
end

function M.scheduleCompletion(epub_path)
    NetworkMgr:runWhenOnline(function()
        -- Small delay so the article's first render is never contending
        -- with the first image request.
        UIManager:scheduleIn(1, function()
            M._step(epub_path)
        end)
    end)
end

-- One buffering cycle: read what's pending, download the images inside the
-- window, swap them into the EPUB, seamlessly reload the reader, and
-- schedule the next window check. Exposed only for the offline checks.
function M._step(epub_path)
    local images = readPending(epub_path)
    if not images then
        return -- nothing pending: build is complete (or not a lazy build)
    end
    local doc = liveDocument(epub_path)
    if not doc then
        -- The reader moved on. The completed-so-far EPUB is the cache copy,
        -- so whatever was fetched is kept; the rest is fetched on the next
        -- open (fetchAndOpen restarts the completion then).
        logger.dbg("WikiReader lazy: article no longer open, pausing completion")
        return
    end
    local batch, remaining = partition(images, doc)
    if #batch == 0 then
        -- Window not full yet: keep watching while the user reads.
        UIManager:scheduleIn(CHECK_INTERVAL, function() M._step(epub_path) end)
        return
    end
    -- Map batch items back to their indexes in the full pending list.
    local index_of = {}
    for i, img in ipairs(images) do index_of[img] = i end
    downloadAll(batch, function(results)
        local results_all = {}
        for j, content in pairs(results) do
            results_all[index_of[batch[j]]] = content
        end
        local ok = swapInImages(epub_path, images, results_all)
        if ok then
            -- XPointers are paragraph-anchored, so the seamless reload
            -- keeps the reading position even though images reflow the
            -- text slightly. Resolve the LIVE reader (the plugin's self.ui
            -- may be the filemanager instance when the article was opened
            -- from a menu).
            local ReaderUI = require("apps/reader/readerui")
            local ui = ReaderUI.instance
            if ui and ui.document and ui.document.file == epub_path then
                ui:reloadDocument(nil, true)
            end
        end
        if #remaining > 0 then
            UIManager:scheduleIn(CHECK_INTERVAL, function() M._step(epub_path) end)
        end
    end)
end

return M
