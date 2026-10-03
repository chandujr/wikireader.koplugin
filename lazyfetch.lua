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

Only the images on the CURRENT reading page are fetched: the page is
bracketed with XPointers and its HTML is matched against each pending
image's placeholder src path. Page turns re-trigger completion via
main.lua's onPageUpdate handler; the periodic re-check only covers a
not-yet-determinable position and the tail of an in-flight download,
stopping once a page is confirmed image-free. Any failure to determine
the current page or its HTML fetches nothing that cycle; there is no
fetch-all fallback, so an API failure can only delay fetching, never
widen the batch.
]]

local Archiver = require("ffi/archiver")
local HTTPClient = require("httpclient")
local JSON = require("json")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local PENDING_ENTRY = "OEBPS/wikireader-pending.json"

-- Images are capped at HEIGHT_CAP_VH of the page height, expressed as a
-- min/max width of HEIGHT_CAP_VH*vh*(w/h) (see realImageSizeStyle).
local HEIGHT_CAP_VH = 40

-- Reserved footprints narrower than this keep their px width: the cap
-- width would stretch an 18px legend square or inline symbol well beyond
-- its real size.
local MIN_ENLARGE_WIDTH = 100

-- Final inline style for a real image, from its reserved px footprint
-- (style) and its context: the px height is dropped so crengine keeps the
-- aspect ratio. The height cap is expressed as a min/max width of
-- HEIGHT_CAP_VH*vh*(w/h) -- the width at which a w:h-locked image is
-- exactly that tall (vh resolves against the page height even on a width
-- property; crengine has no calc()/min()). Floor and cap are the same
-- value on purpose: crengine (per the CSS spec) applies min-width after
-- max-width, so a separate wider floor would silently override the cap.
--   infobox media: at most 33% of the (full-width) cell, no floor;
--   everything else: the cap width -- wide images overflow it and render
--   full-width, still under the height cap.
local function realImageSizeStyle(style, infobox)
    local w = tonumber(style:match("width%s*:%s*(%d+)px"))
    local h = tonumber(style:match("height%s*:%s*(%d+)px"))
    local size
    if not (w and h and h > 0) then
        size = infobox and "max-width:33%" or "min-width:50%"
    elseif infobox then
        size = "max-width:33%; max-height:40vh"
    elseif w < MIN_ENLARGE_WIDTH then
        size = ""
    else
        local cap = string.format("%.2fvh", HEIGHT_CAP_VH * w / h)
        size = "min-width:" .. cap .. "; max-width:" .. cap
    end
    style = style:gsub("height%s*:%s*%d+px%s*;?%s*", "")
    style = style:gsub(";[%s]*;[%s]*", "; ")
    style = style:gsub(";[%s]*$", ""):gsub("^;[%s]*", "")
    if size == "" then
        return style
    end
    if style ~= "" then style = style .. "; " end
    return style .. size
end

local M = {}

-- Returns the pending image list from `epub_path`, or nil if the EPUB has
-- none (already completed, or not a lazy build).
local function readPending(epub_path)
    local reader = Archiver.Reader:new {}
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
    local reader = Archiver.Reader:new {}
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
        -- The hint span and OPF id are keyed by the BUILD index, which
        -- outlives the pending list: every swap rewrites the pending JSON
        -- with only the remaining images, so from the second batch on the
        -- loop position no longer matches the index burned into the HTML.
        -- Derive it from the imgpath instead.
        local idx = tonumber(img.imgpath:match("wrimg(%d+)")) or i
        local path_pat = img.imgpath:gsub("%.", "%%.")
        -- Pending <img>s point at their per-image ".loading.svg" icon copy;
        -- cached EPUBs from earlier plugin versions point straight at the
        -- real path (handled by the plain path patterns below).
        local loading_pat = (img.imgpath .. ".loading.svg"):gsub("%.", "%%.")
        local content = results[i]
        if content then
            ok_count = ok_count + 1
            -- Image arrived: point the img at the real file, and drop any
            -- "loading" hint span left by earlier plugin versions. The
            -- reserved footprint swaps for the real sizing (see
            -- realImageSizeStyle); the plain src swap below is a fallback
            -- for tags without a style attribute right after src.
            html = html:gsub('src="' .. loading_pat .. '" style="([^"]*)"',
                function(style)
                    return 'src="' .. img.imgpath .. '" style="'
                        .. realImageSizeStyle(style, img.infobox) .. '"'
                end)
            html = html:gsub('src="' .. loading_pat .. '"', 'src="' .. img.imgpath .. '"')
            html = html:gsub('<span class="wikireader%-loading" data%-lazyindex="' .. idx .. '"[^>]*>.-</span>', "")
        elseif content == false then
            -- Attempted and failed: remove the placeholder <img> and its
            -- manifest item so no blank square remains.
            html = html:gsub('<img src="' .. loading_pat .. '"[^>]*/>', "")
            html = html:gsub('<img src="' .. path_pat .. '"[^>]*/>', "")
            html = html:gsub('<span class="wikireader%-loading" data%-lazyindex="' .. idx .. '"[^>]*>.-</span>', "")
            local id = "wrimg" .. string.format("%05d", idx)
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
    local writer = Archiver.Writer:new {}
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
        local client = HTTPClient:new {}
        local function nextImage()
            i = i + 1
            if i > #images then
                on_all_done(results)
                return
            end
            client:request({ url = images[i].src }, function(res)
                if res and res.code == 200 and res.body and #res.body > 0 then
                    results[i] = res.body
                    UIManager:scheduleIn(0.05, nextImage)
                elseif images[i].fallback then
                    -- One retry with the original 1x URL: the wider
                    -- derivative can fail where the 1x serves fine, and
                    -- without it the image would be lost entirely.
                    logger.warn("WikiReader lazy: retrying failed image with 1x fallback:", images[i].fallback)
                    client:request({ url = images[i].fallback }, function(fb)
                        if fb and fb.code == 200 and fb.body and #fb.body > 0 then
                            results[i] = fb.body
                        else
                            results[i] = false
                            logger.warn("WikiReader lazy: image download failed:", images[i].src, res and res.code)
                        end
                        UIManager:scheduleIn(0.05, nextImage)
                    end)
                else
                    results[i] = false
                    logger.warn("WikiReader lazy: image download failed:", images[i].src, res and res.code)
                    UIManager:scheduleIn(0.05, nextImage)
                end
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
                if results[i] == nil and img.fallback then
                    -- One retry with the original 1x URL: the wider
                    -- derivative can fail where the 1x serves fine, and
                    -- without it the image would be lost entirely.
                    logger.warn("WikiReader lazy: retrying failed image with 1x fallback:", img.fallback)
                    local fb_sink = {}
                    pcall_ok = pcall(function()
                        local _, code = socket_http.request {
                            url = img.fallback,
                            sink = socketutil.table_sink(fb_sink),
                        }
                        if code == 200 then
                            results[i] = table.concat(fb_sink)
                        end
                    end)
                    socketutil:reset_timeout()
                end
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

-- HTML of the current page, found by bracketing its XPointer range. Any
-- failure here (empty/nil on either side) yields nil rather than any
-- approximate page content. cf. koassistant.koplugin's context extractor
-- for the same getPageXPointer(page)/getPageXPointer(page+1) pattern.
local function currentPageHtml(doc, page)
    local xp_start = doc:getPageXPointer(page)
    if not xp_start or xp_start == "" then
        return nil
    end
    local xp_end = doc:getPageXPointer(page + 1)
    if not xp_end or xp_end == "" then
        return nil
    end
    local ok_html, html = pcall(function()
        if doc.getHTMLFromXPointers then
            return doc:getHTMLFromXPointers(xp_start, xp_end)
        end
    end)
    if not ok_html or not html or html == "" then
        return nil
    end
    return html
end

-- Splits the pending list into the images appearing on the current page
-- (their placeholder src path, e.g. "images/wrimg01234.ext", shows up in
-- the page's HTML) and the rest. On the last page the page+1 bracket
-- fails, so everything left is fetched at once (and this build completes):
-- koassistant's screen-selection document-end probe exists but navigates
-- the live document, too intrusive for a background tick. Other unusable
-- brackets fetch nothing, so an API failure can only delay fetching,
-- never widen the batch (no fetch-all fallback).
local function partition(images, doc, page)
    if not doc or not page then
        return {}, images
    end
    local ok, page_count = pcall(function() return doc:getPageCount() end)
    if ok and page_count and page >= page_count then
        -- Last page: no page+1 bracket exists; the user is done reading,
        -- so finish the article instead of stranding its final images.
        return images, {}
    end
    local page_html = currentPageHtml(doc, page)
    if not page_html then
        return {}, images
    end
    local batch, remaining = {}, {}
    for _, img in ipairs(images) do
        if page_html:find(img.imgpath, 1, true) then
            batch[#batch + 1] = img
        else
            remaining[#remaining + 1] = img
        end
    end
    logger.dbg("WikiReader lazy: current page", page, "-",
        #batch, "on page,", #remaining, "elsewhere")
    return batch, remaining
end

-- How often a not-yet-determinable position is re-probed while the
-- article stays open; page turns make this rare (see _step).
local CHECK_INTERVAL = 20

-- Coalescing, per EPUB: scheduleCompletion is called on article open and
-- again on every page turn, and a batch download can outlive several of
-- those triggers; step_running[path] marks that path's download as in
-- flight so overlapping _step passes (stacked timers) can't double-fetch
-- the same images or race the same zip rewrite.
local step_running = {}

function M.scheduleCompletion(epub_path)
    NetworkMgr:runWhenOnline(function()
        -- Small delay so an article-open-triggered first render is never
        -- contending with the first image request.
        UIManager:scheduleIn(1, function()
            -- A download in flight absorbs the trigger; the cycle's own
            -- completion-time re-check covers the fresh position.
            if step_running[epub_path] then return end
            M._step(epub_path)
        end)
    end)
end

-- Exposed only for the offline checks.
function M._step(epub_path)
    if step_running[epub_path] then
        return -- a batch for this EPUB is already downloading
    end
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
    local page = currentPage(doc)
    if not page then
        -- Document still rendering/positioning itself; wait for a later
        -- check rather than assuming the start and over-fetching.
        UIManager:scheduleIn(CHECK_INTERVAL, function() M._step(epub_path) end)
        return
    end
    local batch = partition(images, doc, page)
    if #batch == 0 then
        -- Page and its HTML confirmed image-free: stop polling; the next
        -- page turn (main.lua onPageUpdate) or the next open re-triggers.
        return
    end
    -- Map batch items back to their indexes in the full pending list.
    local index_of = {}
    for i, img in ipairs(images) do index_of[img] = i end
    step_running[epub_path] = true
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
        step_running[epub_path] = false
        -- The position may have moved while the batch ran (and the reload
        -- re-renders the page); one re-check either fetches the new page's
        -- images or confirms it image-free and stops the loop.
        UIManager:scheduleIn(0, function() M._step(epub_path) end)
    end)
end

return M
