-- Locator-map (Template:Location map) compositing for WikiReader.
-- A Wikipedia locator map is a base map <img> with absolutely-positioned
-- red-pog marker overlays, which crengine cannot render (no position:
-- absolute). This pass composites each div.locmap into ONE RGB PNG --
-- the downloaded base map thumb with filled circles drawn at the
-- template's marker positions -- replacing the block with a marker span
-- the EPUB builder swaps for a real <img>. Only runs in lazy ("show")
-- mode; other modes drop locmaps entirely (qrimage/htmlclean).
--
-- Any per-locmap failure (fetch, decode, unknown format, caps) falls back
-- to the bare base map as an ordinary lazy placeholder -- a marker-less
-- map beats no map -- and never widens beyond that one locmap.

local wutil = require("wikiutil")
local qrimage = require("qrimage")
local logger = require("logger")

local ffi = require("ffi")
local bit = require("bit")
local zlib = require("ffi/zlib")

local M = {}

-- Composites fetched per article: each is a network download plus a
-- decoded pixel buffer in memory, so an upper bound keeps a locmap-heavy
-- article ({{Location map many}} stacks, switcher containers) from
-- turning into a long build stall. Overflow falls back to lazy markers.
local MAX_COMPOSITES = 24

-- Sanity ceiling on the decoded base map width; real location-map thumbs
-- are 250-500px, anything wider is malformed input we'd rather not blit.
local MAX_DECODED_WIDTH = 640

-- Marker styling: Wikipedia's standard red pog with a darker rim for
-- contrast on pale maps.
local FILL = { 0xCC, 0x2A, 0x2A }
local RING = { 0x8B, 0x11, 0x11 }

--[[-------------------------------------------------------------------------
RGB PNG encoder (color type 2) -- same chunk scheme as qrimage.lua
--]]

local crc_table
local function crc32(s)
    if not crc_table then
        crc_table = {}
        for i = 0, 255 do
            local c = i
            for _ = 1, 8 do
                if bit.band(c, 1) == 1 then
                    c = bit.bxor(bit.rshift(c, 1), 0xEDB88320)
                else
                    c = bit.rshift(c, 1)
                end
            end
            crc_table[i] = c
        end
    end
    local crc = 0xFFFFFFFF
    for i = 1, #s do
        crc = bit.bxor(crc_table[bit.band(bit.bxor(crc, s:byte(i)), 0xFF)], bit.rshift(crc, 8))
    end
    return bit.bxor(crc, 0xFFFFFFFF)
end

local function be32(n)
    return string.char(
        bit.band(bit.rshift(n, 24), 0xFF),
        bit.band(bit.rshift(n, 16), 0xFF),
        bit.band(bit.rshift(n, 8), 0xFF),
        bit.band(n, 0xFF))
end

local function png_chunk(ctype, data)
    local body = ctype .. data
    return be32(#data) .. body .. be32(crc32(body))
end

-- `scanlines` holds the image rows, each prefixed with its PNG filter byte
-- (always 0, "None"). Duplicated from qrimage rather than shared: the
-- greyscale/color-type-2 split would leak internals across both modules,
-- and the whole writer is ~40 lines.
local function encodeRgbPng(width, height, scanlines)
    local ihdr = be32(width) .. be32(height) .. string.char(8, 2, 0, 0, 0)
    local idat = zlib.zlib_compress(scanlines)
    return "\137PNG\r\n\26\n"
        .. png_chunk("IHDR", ihdr)
        .. png_chunk("IDAT", idat)
        .. png_chunk("IEND", "")
end

--[[-------------------------------------------------------------------------
Base map download + decode (ffi bits isolated for stubbing in tests)
--]]

-- Downloads `url` and returns the raw bytes, or nil on any failure.
local function fetchBytes(url)
    local ok, code, sink = wutil.httpGetJSON(url)
    if not ok or code ~= 200 or not sink then
        return nil
    end
    local data = table.concat(sink)
    if data == "" then
        return nil
    end
    return data
end

-- Test seam: tests replace these to run the blit/encode path without
-- network or ffi codecs.
M._fetchBytes = fetchBytes

-- Decodes `data` (PNG or JPEG bytes) into
-- { width, height, buf } where buf is a mutable RGB triple buffer
-- (uint8_t*, row-major). Returns nil for anything else (webp/gif/...):
-- the caller falls back to a plain lazy placeholder rather than
-- reimplementing decoders. The PNG path must go through a temp file
-- because ffi/png only exposes a file decoder.
local function decodeBaseMap(data)
    local Png = require("ffi/png")
    local Jpeg = require("ffi/jpeg")
    local is_png = data:sub(1, 4) == "\137PNG"
    local is_jpeg = data:sub(1, 2) == "\255\216"
    if not is_png and not is_jpeg then
        return nil
    end
    local w, h
    local src
    if is_png then
        local tmp = (os.getenv("TMPDIR") or "/tmp") .. "/wikireader-locmap-" .. tostring(os.clock()) .. ".png"
        local fh = io.open(tmp, "wb")
        if not fh then return nil end
        fh:write(data)
        fh:close()
        local ok, info = Png.decodeFromFile(tmp, 3)
        os.remove(tmp)
        if not ok or not info then return nil end
        w, h = info.width, info.height
        src = ffi.cast("const uint8_t*", info.data)
    else
        local ok, bb, jw, jh = pcall(Jpeg.openDocumentFromMem, data, true)
        if not ok or not bb then return nil end
        w, h = jw, jh
        -- Copy out of the BB's own buffer: it dies with the BB object.
        src = ffi.cast("const uint8_t*", bb.data)
        if bb.stride ~= w * 3 then
            local flat = ffi.new("uint8_t[?]", w * h * 3)
            for y = 0, h - 1 do
                ffi.copy(flat + y * w * 3, src + bb.stride * y, w * 3)
            end
            src = flat
        end
    end
    if not w or not h or w <= 0 or h <= 0 or w > MAX_DECODED_WIDTH then
        return nil
    end
    local buf = ffi.new("uint8_t[?]", w * h * 3)
    ffi.copy(buf, src, w * h * 3)
    return { width = w, height = h, buf = buf }
end

-- Test seam: see fetchBytes above.
M._decodeBaseMap = decodeBaseMap

--[[-------------------------------------------------------------------------
Marker drawing
--]]

-- Draws a filled circle of `d` px diameter centered at (cx, cy), with a
-- 1px rim once the dot is big enough for the rim to read. Simple
-- per-pixel radial test: dots are <= ~20px, so that's plenty.
local function drawDot(base, cx, cy, d)
    local radius = d / 2
    local x0 = math.max(0, math.floor(cx - radius))
    local x1 = math.min(base.width - 1, math.ceil(cx + radius))
    local y0 = math.max(0, math.floor(cy - radius))
    local y1 = math.min(base.height - 1, math.ceil(cy + radius))
    for y = y0, y1 do
        for x = x0, x1 do
            local dist = math.sqrt((x + 0.5 - cx) ^ 2 + (y + 0.5 - cy) ^ 2)
            if dist <= radius then
                local color = (d >= 8 and dist > radius - 1) and RING or FILL
                local off = (y * base.width + x) * 3
                base.buf[off] = color[1]
                base.buf[off + 1] = color[2]
                base.buf[off + 2] = color[3]
            end
        end
    end
end

--[[-------------------------------------------------------------------------
HTML parsing helpers
--]]

-- First <img ...> tag in `s`, as its raw attrs string, or nil.
local function firstImgAttrs(s)
    local start = s:find("<img", 1, true)
    if not start then return nil end
    local close = s:find(">", start, true)
    if not close then return nil end
    return s:sub(start + 4, close - 1)
end

-- Absolute, query-free download URL for a scheme-relative thumb src.
local function absoluteUrl(src)
    if not src then return nil end
    if src:sub(1, 2) == "//" then
        src = "https:" .. src
    elseif src:sub(1, 8) ~= "https://" then
        return nil
    end
    return (src:gsub("[?#].*$", ""))
end

-- Caption div of a locmap block: the wrapper div whose style declares a
-- padding-top (the template's "Location within ..." line). It is a child
-- of the width-wrapper div, not a top-level sibling, so scan all divs but
-- skip marker overlays (div.od) whose labels are never captions.
local function extractCaption(inner)
    local pos = 1
    while true do
        local o_s, o_e = inner:find("<div[^>]*>", pos)
        if not o_s then return nil end
        local open_tag = inner:sub(o_s, o_e)
        local cls = (open_tag:match([[class%s*=%s*"([^"]*)"]]) or ""):lower()
        if cls:find("od", 1, true) then
            local c_s, c_e = wutil.findMatchingClose(inner, "div", o_e)
            if not c_s then return nil end
            pos = c_e + 1
        else
            local style = open_tag:match([[style%s*=%s*"([^"]*)"]]) or ""
            if style:find("padding%-top") then
                local c_s, c_e = wutil.findMatchingClose(inner, "div", o_e)
                if not c_s then return nil end
                return inner:sub(o_s, c_e)
            end
            pos = o_e + 1
        end
    end
end

--[[-------------------------------------------------------------------------
One locmap block -> composite
--]]

-- Builds the composite for one locmap block. Returns the marker span HTML,
-- or nil to signal "fall back to the bare base map".
local function compositeLocMap(block, composites, opts)
    -- The base map is the mw:File img in the position:relative container;
    -- marker imgs all sit inside div.od overlays that follow it.
    local od_start = block:find('<div[^>]-class%s*=%s*"od', 1)
    local base_attrs = firstImgAttrs(od_start and block:sub(1, od_start) or block)
    if not base_attrs then return nil end

    local src = absoluteUrl(base_attrs:match([[src%s*=%s*"([^"]*)"]]))
    local w = tonumber(base_attrs:match([[%swidth%s*=%s*"(%d+)"]]))
    local h = tonumber(base_attrs:match([[%sheight%s*=%s*"(%d+)"]]))
    if not src or not w or not h or w <= 0 or h <= 0 then return nil end

    -- Markers: each div.od's top/left percentages against the RENDERED
    -- base dims (the .id half-size offset is already compensated by the
    -- template; the center is the percentage point itself).
    local markers = {}
    local marker_diameter
    local pos = od_start or 1
    while pos do
        local o_s = block:find('<div[^>]-class%s*=%s*"od', pos)
        if not o_s then break end
        local tag_end = block:find(">", o_s, true)
        local c_s, c_e = wutil.findMatchingClose(block, "div", tag_end)
        if not c_s then break end
        local od_open = block:sub(o_s, tag_end)
        local od_inner = block:sub(tag_end + 1, c_s - 1)
        local top = tonumber(od_open:match('top%s*:%s*([%-%d%.]+)%%'))
        local left = tonumber(od_open:match('left%s*:%s*([%-%d%.]+)%%'))
        if top and left then
            local img_attrs = firstImgAttrs(od_inner)
            if not marker_diameter and img_attrs then
                -- Rendered pog size (e.g. 8px on the 1x base); rescaled
                -- below when compositing a higher-resolution variant.
                marker_diameter = tonumber(img_attrs:match([[%swidth%s*=%s*"(%d+)"]]))
            end
            markers[#markers + 1] = { top = top / 100, left = left / 100 }
        end
        pos = c_e + 1
    end
    if #markers == 0 then return nil end

    -- Download the 1x src, or the srcset's larger variant in hi-res mode
    -- (still emitting the 1x footprint, same as the lazy images).
    local url = src
    if opts.hi_res then
        local srcset = " " .. (base_attrs:match([[srcset%s*=%s*"([^"]*)"]]) or "") .. ", "
        local variant = srcset:match([[ (%S+) 2x, ]]) or srcset:match([[ (%S+) 1.5x, ]])
        local vurl = variant and absoluteUrl(variant)
        -- Thumb URLs carry the rendered width ("/960px-..."); if the
        -- variant exceeds MAX_DECODED_WIDTH it would be refused at decode
        -- time, so use the 1x src instead of wasting the download.
        local vw = variant and tonumber(variant:match("/(%d+)px%-"))
        if vurl and vurl ~= src and (not vw or vw <= MAX_DECODED_WIDTH) then
            url = vurl
        end
    end

    local data = M._fetchBytes(url)
    if not data then return nil end
    local base = M._decodeBaseMap(data)
    if not base then return nil end

    -- Marker percentages refer to the rendered base (w x h) but the
    -- decoded variant may be bigger; project through the decoded width.
    local scale = base.width / w
    local diameter = marker_diameter
        and math.max(6, math.floor(marker_diameter * scale + 0.5))
        or math.max(6, math.floor(w * 0.032 + 0.5))

    for _, m in ipairs(markers) do
        drawDot(base, m.left * base.width, m.top * base.height, diameter)
    end

    local rows = {}
    local row_bytes = base.width * 3
    for y = 0, base.height - 1 do
        rows[#rows + 1] = "\0" .. ffi.string(base.buf + y * row_bytes, row_bytes)
    end
    local index = #composites + 1
    composites[index] = {
        path = string.format("images/locmap%05d.png", index),
        png = encodeRgbPng(base.width, base.height, table.concat(rows)),
    }
    return string.format(
        '<span class="wikireader-locmap" data-locindex="%d" style="width:%dpx;height:%dpx"></span>',
        index, w, h)
end

--[[-------------------------------------------------------------------------
Public pass
--]]

-- Replaces every div.locmap block with either a composite marker span or,
-- on failure, a lazy placeholder of the bare base map; the trailing
-- caption div survives in both cases. composites collects
-- { path = ..., png = ... } entries the EPUB builder injects via its
-- Archiver hooks. opts = { hi_res = bool, lazy_images = table (needed by
-- the fallback path to register the placeholder) }.
function M.replaceLocMaps(html, composites, opts)
    opts = opts or {}
    local out = {}
    local pos = 1
    while true do
        local open_start = html:find('<div[^>]-class%s*=%s*"[^"]*locmap[^"]*"', pos)
        if not open_start then
            table.insert(out, html:sub(pos))
            break
        end
        local close_start, close_end = wutil.findMatchingClose(html, "div", html:find(">", open_start, true))
        if not close_start then
            table.insert(out, html:sub(pos))
            break
        end
        local inner_start = html:find(">", open_start, true)
        local inner = html:sub(inner_start + 1, close_start - 1)
        local caption = extractCaption(inner)

        table.insert(out, html:sub(pos, open_start - 1))
        local marker
        if #composites < MAX_COMPOSITES then
            local ok, result = pcall(compositeLocMap, html:sub(open_start, close_end), composites, opts)
            marker = ok and result or nil
            if not ok then
                logger.warn("WikiReader locmap: composite failed, falling back:", result)
            end
        end
        if not marker then
            -- Fallback: bare base map as an ordinary lazy placeholder.
            local block = html:sub(open_start, close_start)
            local od_start = block:find('<div[^>]-class%s*=%s*"od', 1)
            local base_attrs = firstImgAttrs(od_start and block:sub(1, od_start) or block)
            if base_attrs then
                marker = qrimage.makeLazyImageTag(base_attrs, opts.lazy_images or {}, {}, 0, opts.hi_res, true)
            end
        end
        if marker then
            table.insert(out, marker)
        end
        if caption then
            table.insert(out, caption)
        end
        pos = close_end + 1
    end
    return table.concat(out)
end

return M
