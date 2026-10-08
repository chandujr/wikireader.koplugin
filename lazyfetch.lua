--[[--
Background completion of lazily-built WikiReader EPUBs (formula SVGs and
photographs).

With formulas and/or "Fetch images in background", epub.lua builds the
article EPUB immediately, with each boxed image as a placeholder <img> and
each formula as a placeholder <img> whose zip entries do not exist yet, and
an OEBPS/wikireader-pending.json entry listing the URLs to fetch (formula
SVGs first: the downloader runs the list in order, so its concurrency slots
fill with formulas before photos). This module downloads the whole pending
set as ONE background batch after the document opens (each transfer in a
coroutine over non-blocking sockets, resumed only from scheduler ticks, so
downloads never hold the UI thread or block the open), rewrites the zip with
the downloads added and the pending entry dropped, and seamlessly reloads
the open document — that single reload is the article's only partial refresh.
A cached article interrupted mid-download keeps its pending entry, so the
next open finishes it the same way. Failed downloads are removed from
content.html and content.opf so no blank squares remain. Page turns
re-trigger the check (debounced via main.lua's onPageUpdate) but are
absorbed while a batch runs; a batch is abandoned only when the document
is closed, never on a page turn — every listed download is wanted whatever
page the reader is on.
]]

local Archiver = require("ffi/archiver")
local HTTPClient = require("httpclient")
local JSON = require("json")
local lfs = require("libs/libkoreader-lfs")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local logger = require("logger")

-- Non-blocking HTTP for the downloader: core's httpasync when the build
-- ships it (>= 2026.10), the vendored plugin copy otherwise — core's
-- frontend paths precede plugin paths on package.path. The blocking
-- socket.http branch below is the last-resort fallback if this cannot
-- load at all.
local ok_httpasync, httpasync = pcall(require, "httpasync")
if not (ok_httpasync and type(httpasync) == "table" and httpasync.fetch_url) then
    httpasync = nil
end

-- Sliced-scheduler tuning. FETCH_DEADLINE_S exists because httpasync's
-- non-blocking sockets have no timeout of their own: a stalled fetch must
-- not wedge the batch (and step_running with it).
local TICK_S = 0.05
local MAX_CONCURRENT = 6
local FETCH_DEADLINE_S = 30

local PENDING_ENTRY = "OEBPS/wikireader-pending.json"

-- Images are capped at HEIGHT_CAP_VH of the page height, expressed as a
-- max width of HEIGHT_CAP_VH*vh*(w/h) (see realImageSizeStyle).
local HEIGHT_CAP_VH = 33

-- Final inline style for a real image, from its reserved px footprint
-- (style): the px height is dropped so crengine keeps the aspect ratio.
-- The height cap is expressed as a max width of HEIGHT_CAP_VH*vh*(w/h)
-- -- the width at which a w:h-locked image is exactly that tall (vh
-- resolves against the page height even on a width property; crengine
-- has no calc()/min()).
--   infobox media: cap only -- the reserved px width stays, so a small
--   thumb is never upscaled (its larger render would just bloat the cell);
--   everything else: width floored AND capped at the cap width (same value
--   on purpose: crengine applies min-width after max-width, so a wider
--   floor would silently override the cap) -- wide images render
--   full-width, still under the height cap.
local function realImageSizeStyle(style, infobox)
    -- Percentage footprints are the multi-image grid (htmlclean fills those
    -- cells at build time, cap included); nothing to compute here.
    if style:match("width%s*:%s*[%d%.]+%%") then
        return style
    end
    local w = tonumber(style:match("width%s*:%s*(%d+)px"))
    local h = tonumber(style:match("height%s*:%s*(%d+)px"))
    local size
    if not (w and h and h > 0) then
        size = infobox and "max-width:33%" or "min-width:50%"
    elseif infobox then
        size = "max-width:" .. string.format("%.2fvh", HEIGHT_CAP_VH * w / h)
    elseif w < 100 then
        -- Reserved footprints narrower than 100px keep their px width: the
        -- cap width would stretch an 18px legend square well beyond its
        -- real size.
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
-- Exposed for tests.
M.realImageSizeStyle = realImageSizeStyle

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

-- Completed-build memoization: page turns must not re-open and walk the
-- zip of every finished wiki EPUB. Keyed by mtime+size, so a refetch or
-- swap invalidates it for free; builds with pending images are never cached.
local complete_cache = {}
local function readPendingCached(epub_path)
    local attr = lfs.attributes(epub_path)
    local cached = complete_cache[epub_path]
    if cached and attr and attr.modification == cached.mtime and attr.size == cached.size then
        return nil
    end
    local images = readPending(epub_path)
    if attr then
        if images then
            complete_cache[epub_path] = nil
        else
            complete_cache[epub_path] = { mtime = attr.modification, size = attr.size }
        end
    end
    return images
end

-- Rewrites the zip in place after one batch: adds the downloaded files,
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
        local is_math = img.math
        local idx = is_math and tonumber(img.imgpath:match("math(%d+)"))
            or tonumber(img.imgpath:match("wrimg(%d+)")) or i
        local path_pat = img.imgpath:gsub("%.", "%%.")
        -- Pending <img>s point at their per-image ".loading.svg" icon copy;
        -- cached EPUBs from earlier plugin versions point straight at the
        -- real path (handled by the plain path patterns below).
        local loading_pat = (img.imgpath .. ".loading.svg"):gsub("%.", "%%.")
        local content = results[i]
        if content then
            ok_count = ok_count + 1
            -- Formula SVGs need no markup change (the placeholder <img>
            -- already points at their final path); only photos swap their
            -- loading-icon placeholder for the real sizing (see
            -- realImageSizeStyle) and drop the "loading" hint span.
            if not is_math then
                html = html:gsub('src="' .. loading_pat .. '" style="([^"]*)"',
                    function(style)
                        return 'src="' .. img.imgpath .. '" style="'
                            .. realImageSizeStyle(style, img.infobox) .. '"'
                    end)
                html = html:gsub('src="' .. loading_pat .. '"', 'src="' .. img.imgpath .. '"')
                html = html:gsub('<span class="wikireader%-loading" data%-lazyindex="' .. idx .. '"[^>]*>.-</span>', "")
            end
        elseif content == false then
            -- Attempted and failed: remove the placeholder <img> and its
            -- manifest item so no blank square remains.
            if not is_math then
                html = html:gsub('<img src="' .. loading_pat .. '"[^>]*/>', "")
                html = html:gsub('<span class="wikireader%-loading" data%-lazyindex="' .. idx .. '"[^>]*>.-</span>', "")
            end
            html = html:gsub('<img src="' .. path_pat .. '"[^>]*/>', "")
            local id = (is_math and "wrmath" or "wrimg") .. string.format("%05d", idx)
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

-- Downloads the batch without freezing the UI, then calls on_all_done with
-- a map of batch index -> body (false = attempted and failed, absent = not
-- scheduled). `is_abandoned` is polled between slices; when it turns true
-- the batch is discarded (partial downloads dropped, pending entry intact)
-- and on_all_done(nil) fires.
local function downloadAll(images, on_all_done, is_abandoned)
    local results = {}
    if httpasync then
        -- Preferred path: each fetch runs in a coroutine over httpasync's
        -- non-blocking sockets; a tick resumes only what select() marks
        -- ready, so a transfer never holds the UI thread.
        local socket = require("socket")
        local DONE = {} -- unique completion sentinel; fetches otherwise yield (socket, "r"/"w")
        local queue = {}
        for i, img in ipairs(images) do
            queue[i] = { index = i, url = img.src, tried_fallback = false }
        end
        local active = {} -- { co=, item=, sock=, mode=, deadline= }

        local function failImage(item, why)
            local img = images[item.index]
            if not item.tried_fallback and img.fallback then
                -- 1x fallback: the wider derivative can fail where the 1x serves fine.
                logger.warn("WikiReader lazy: retrying failed image with 1x fallback:", img.fallback)
                item.tried_fallback = true
                item.url = img.fallback
                queue[#queue + 1] = item
            else
                results[item.index] = false
                logger.warn("WikiReader lazy: image download failed:", img.src, why)
            end
        end

        local function start(item)
            active[#active + 1] = {
                co = coroutine.create(function()
                    -- fetch_url returns (true, content_type, content) or
                    -- (false, err): only the 3rd value is the body, and
                    -- unpacking it as a pair silently loses it (upstream
                    -- bug #16135).
                    local ok, meta, content = httpasync.fetch_url(item.url)
                    coroutine.yield(DONE, ok and content or nil, ok and nil or meta)
                end),
                item = item,
                deadline = os.time() + FETCH_DEADLINE_S,
            }
        end

        local function tick()
            if is_abandoned() then
                for _, t in ipairs(active) do
                    if t.sock then pcall(t.sock.close, t.sock) end
                end
                on_all_done(nil)
                return
            end
            -- Expire stalled fetches: a peer that never answers must not
            -- hold the batch (and step_running) forever.
            local now = os.time()
            for i = #active, 1, -1 do
                if now > active[i].deadline then
                    if active[i].sock then pcall(active[i].sock.close, active[i].sock) end
                    failImage(active[i].item, "deadline exceeded")
                    table.remove(active, i)
                end
            end
            local recvt, sendt = {}, {}
            for _, t in ipairs(active) do
                if t.sock then
                    if t.mode == "r" then recvt[#recvt + 1] = t.sock else sendt[#sendt + 1] = t.sock end
                end
            end
            local ready
            if #recvt > 0 or #sendt > 0 then
                -- Timeout 0: poll, never wait — the 0.05s reschedule keeps
                -- the event loop between ticks.
                local ok_sel, r, w = pcall(socket.select, recvt, sendt, 0)
                if ok_sel then
                    ready = {}
                    for _, s in ipairs(r or {}) do ready[s] = true end
                    for _, s in ipairs(w or {}) do ready[s] = true end
                else
                    ready = nil -- select blew up: resume everything, let the fetches surface the error
                end
            end
            local next_active = {}
            for _, t in ipairs(active) do
                if not t.sock or not ready or ready[t.sock] then
                    t.sock, t.mode = nil, nil
                    local ok, v1, v2, v3 = coroutine.resume(t.co)
                    if v1 == DONE then
                        if v2 then
                            results[t.item.index] = v2
                        else
                            failImage(t.item, v3)
                        end
                    elseif not ok then
                        failImage(t.item, tostring(v1))
                    elseif coroutine.status(t.co) == "dead" then
                        failImage(t.item, "ended without result")
                    else
                        -- Yielded (socket, "r"/"w"): keep waiting on it.
                        t.sock, t.mode = v1, v2
                        next_active[#next_active + 1] = t
                    end
                else
                    next_active[#next_active + 1] = t
                end
            end
            active = next_active
            while #active < MAX_CONCURRENT and #queue > 0 do
                start(table.remove(queue, 1))
            end
            if #active > 0 or #queue > 0 then
                UIManager:scheduleIn(TICK_S, tick)
            else
                on_all_done(results)
            end
        end
        tick()
    elseif UIManager.looper then
        -- Turbo looper available (DUSE_TURBO_LIB, only on builds without
        -- httpasync): fully asynchronous requests.
        local client = HTTPClient:new {}
        local i = 0
        local function nextImage()
            if is_abandoned() then
                on_all_done(nil)
                return
            end
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
                    -- 1x fallback: the wider derivative can fail where the 1x serves fine.
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
        -- Last resort (no httpasync, no turbo): blocking socket.http, one
        -- image per scheduled tick. Each request freezes the UI for its
        -- duration, so the timeouts are kept tight (3s connect / 10s total)
        -- and the abandon check runs between images to stop early.
        local socket_http = require("socket.http")
        local socketutil = require("socketutil")
        local i = 0
        local function nextImage()
            if is_abandoned() then
                on_all_done(nil)
                return
            end
            i = i + 1
            if i > #images then
                on_all_done(results)
                return
            end
            local img = images[i]
            UIManager:scheduleIn(0.3, function()
                local sink = {}
                socketutil:set_timeout(3, 10)
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
                    -- 1x fallback: the wider derivative can fail where the 1x serves fine.
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

-- Coalescing, per EPUB: scheduleCompletion is called on article open and
-- again on every page turn, and a batch download can outlive several of
-- those triggers; step_running[path] marks that path's download as in
-- flight so overlapping _step passes (stacked timers) can't double-fetch
-- the same images or race the same zip rewrite.
local step_running = {}

-- epub_path -> true while offline and waiting on (or already declined for)
-- an image-batch attempt: KOReader drops runWhenOnline callbacks silently
-- when the wifi prompt is dismissed, with no plugin-visible signal, so this
-- is the only way to limit the prompt to one attempt per article. Cleared
-- by onNetworkConnected.
local net_blocked = {}

local scheduled_step = {} -- epub_path -> the pending (debounced) step action

local function planStep(epub_path)
    -- Trailing-edge debounce: a burst of page turns collapses into one
    -- check ~1s after the LAST trigger, instead of stacking a step per turn.
    local prev = scheduled_step[epub_path]
    if prev then
        UIManager:unschedule(prev)
    end
    local action
    action = function()
        scheduled_step[epub_path] = nil
        -- A download in flight absorbs the trigger.
        if step_running[epub_path] then return end
        M._step(epub_path)
    end
    scheduled_step[epub_path] = action
    -- Small delay so the article-open first render isn't contending with
    -- the first image request.
    UIManager:scheduleIn(1, action)
end

function M.scheduleCompletion(epub_path)
    -- No network check here: this fires on every page turn of every wiki
    -- EPUB; _step gates the wifi prompt on actual pending work.
    planStep(epub_path)
end

function M.onNetworkConnected()
    net_blocked = {}
end

function M._step(epub_path)
    if step_running[epub_path] then
        return -- a batch for this EPUB is already downloading
    end
    local images = readPendingCached(epub_path)
    if not images then
        return -- nothing pending: build is complete (or not a lazy build)
    end
    if NetworkMgr:isOnline() then
        net_blocked[epub_path] = nil
    elseif net_blocked[epub_path] then
        return -- prompted before and declined/still offline for this article
    else
        net_blocked[epub_path] = true
        NetworkMgr:runWhenOnline(function() planStep(epub_path) end)
        return
    end
    local doc = liveDocument(epub_path)
    if not doc then
        -- The reader moved on; fetched images persist in the zip, the rest
        -- is fetched on the next open.
        logger.dbg("WikiReader lazy: article no longer open, pausing completion")
        return
    end
    step_running[epub_path] = true
    -- Whole-article batch, run to completion even across page turns: the
    -- single seamless reload below is this build's only partial refresh.
    downloadAll(images, function(results)
        step_running[epub_path] = false
        if not results then
            return -- reader closed mid-batch; leftovers surface at the next open
        end
        -- Failed downloads lost their placeholders in the swap, and
        -- nothing remains pending: build is complete, no re-check needed.
        local ok = swapInImages(epub_path, images, results)
        if ok then
            -- XPointers are paragraph-anchored, so the reload keeps the
            -- reading position even though images reflow the text. Resolve
            -- the LIVE reader (self.ui may be the filemanager instance when
            -- the article was opened from a menu); skip when the reader has
            -- moved on — the images persist in the zip and surface at the
            -- next open.
            local ReaderUI = require("apps/reader/readerui")
            local ui = ReaderUI.instance
            if ui and ui.document and ui.document.file == epub_path then
                ui:reloadDocument(nil, true)
            end
        end
    end, function() return liveDocument(epub_path) == nil end)
end

-- Raw pending list of any EPUB path (save flow checks the open article).
function M.pendingImages(epub_path)
    return readPending(epub_path)
end

-- Exposed for the downloader self-check (tests/test_lazy_download.lua).
M._downloadAll = downloadAll

return M
