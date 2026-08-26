--[[--
QR-code image generation for WikiReader.

Articles are cached as EPUBs with images permanently disabled: the actual
photographs/diagrams are never downloaded, because an article can contain
dozens of them and each can be several hundred KB, and without replacement
the image box (image *and* caption) would be lost entirely.

Instead, this module replaces each article image -- and each video/audio
figure -- with a small QR code of the media's File: description page:
the box (and its caption) stays in the document, and scanning the QR
code with a phone opens that page (which shows the real image, or a
transcoded player for video/audio instead of a huge original download).
Nothing is ever fetched; a tiny
black-and-white PNG is embedded per figure.

Media inside infobox tables is stripped (genuine image cells dropped, and
inline flag icons removed while keeping the name text they sit beside), so
kept infoboxes show text only; prose icons inside
<span typeof="mw:File"> remain untouched.

The QR encoding itself is KOReader's own pure-Lua implementation
(ffi/qrencode -- the same one the built-in QR sharing widget uses), and
the PNG is written with a minimal chunk writer, with the IDAT payload
deflated by KOReader's zlib binding (ffi/zlib).
]]

local bit = require("bit")
local zlib = require("ffi/zlib")
local qrencode = require("ffi/qrencode")

-- Display width/height, in CSS pixels, each QR image is given in the EPUB.
-- (The embedded PNG is generated at a slightly higher resolution and scaled
-- down by crengine, so it stays crisp when the reader zooms in.)
local DEFAULT_QR_SIZE = 150
-- Quiet zone: number of empty modules left around the QR grid on each side,
-- so a phone camera can locate and frame the code reliably.
local QR_QUIET = 4

local M = {}

-- Exposed so the EPUB builder can use it as the fallback display size.
M.DEFAULT_QR_SIZE = DEFAULT_QR_SIZE

--[[-------------------------------------------------------------------------
Minimal PNG writer (8-bit greyscale, zlib-compressed)
--]]

-- CRC-32 (reflected polynomial 0xEDB88320), as required for PNG chunks.
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

-- `raw_scanlines` is the concatenated image rows, each prefixed with its
-- PNG filter byte (we always use filter 0, "None").
local function encode_png(width, height, raw_scanlines)
    local ihdr = be32(width) .. be32(height) .. string.char(8, 0, 0, 0, 0)
        -- bit depth 8, color type 0 (greyscale), compression 0, filter 0, interlace 0
    local idat = zlib.zlib_compress(raw_scanlines)
    return "\137PNG\r\n\26\n"
        .. png_chunk("IHDR", ihdr)
        .. png_chunk("IDAT", idat)
        .. png_chunk("IEND", "")
end

--[[-------------------------------------------------------------------------
QR generation
--]]

-- Returns the bytes of a PNG (greyscale, black on white, with quiet zone)
-- encoding `url`, or nil if the QR could not be generated.
function M.qrPng(url, qr_size)
    local ok, grid = qrencode.qrcode(url)
    if not ok or not grid then
        return nil
    end
    local n = #grid
    local dim_modules = n + 2 * QR_QUIET
    -- Rasterize at enough pixels per module that the PNG is never smaller
    -- than the display size the EPUB requests for it.
    local module_px = math.max(2, math.ceil((qr_size or DEFAULT_QR_SIZE) / dim_modules))
    local dim = dim_modules * module_px
    -- grid[x][y]: 1-based, x = column (left to right), y = row (top to bottom).
    -- Values > 0 are dark modules, < 0 are light.
    local raw_parts = {}
    for y = 0, dim - 1 do
        local grow = math.floor(y / module_px) - QR_QUIET + 1
        local row = {}
        for x = 0, dim - 1 do
            local gcol = math.floor(x / module_px) - QR_QUIET + 1
            local dark = grow >= 1 and grow <= n and gcol >= 1 and gcol <= n
                and grid[gcol][grow] > 0
            row[#row + 1] = dark and 0 or 255
        end
        raw_parts[#raw_parts + 1] = "\0" .. string.char(table.unpack(row))
    end
    return encode_png(dim, dim, table.concat(raw_parts))
end

--[[-------------------------------------------------------------------------
Image URL handling
--]]

-- Resolves a Wikipedia <img>/<media> src to an absolute URL, free of
-- tracking query params, and upgraded from the original full-size file
-- when the src is a thumbnail URL. Used by filePageUrl() to recover the
-- original filename. Returns nil for URLs we can't make sense of
-- (relative paths, data: URIs, ...).
function M.cleanImageUrl(src)
    if src:sub(1, 2) == "//" then
        src = "https:" .. src
    elseif src:sub(1, 1) == "/" then
        return nil
    elseif not src:find("^https?://") then
        return nil
    end
    src = src:gsub("[?#].*$", "")
    -- Thumb URL: .../wikipedia/commons/thumb/X/XY/File.ext/NNNpx-File.ext
    -- Original: .../wikipedia/commons/X/XY/File.ext
    local prefix, hashpath = src:match("^(https?://[^/]+/wikipedia/[^/]+/)thumb/([^/]+/[^/]+/[^/]+)/%d+px%-")
    if prefix and hashpath then
        return prefix .. hashpath
    end
    return src
end

-- Builds the File: description-page URL for the upload.wikimedia.org media
-- URL `mediaUrl` points at, on the wiki edition `lang`. The filename always
-- occurs in the file's upload path, so we can recover it from any of the
-- three forms (original, thumbnail, or transcoded derivative) and steer
-- every QR scan -- image, video or audio alike -- at the File: page, where
-- the description, the transcoded player (instead of the huge original
-- download), and attribution live. Returns nil if no filename could be
-- extracted (or no lang was given).
function M.filePageUrl(mediaUrl, lang)
    if not mediaUrl or not lang then
        return nil
    end
    if mediaUrl:sub(1, 2) == "//" then
        mediaUrl = "https:" .. mediaUrl
    end
    local filename
    if mediaUrl:find("/transcoded/", 1, true) then
        -- Transcoded media derivative, e.g.
        --   .../wikipedia/commons/transcoded/c/dd/Original.ext/Original.ext.360p.vp9.webm
        -- The original filename is the path segment right before the final
        -- (derivative) segment, whatever the derivative's own name.
        filename = mediaUrl:match("^.+/([^/]+)/[^/]+$")
    else
        -- Thumbnail or plain original: resolve to the original full-size
        -- file, whose last path segment is the original filename.
        local original = M.cleanImageUrl(mediaUrl)
        if not original then
            return nil
        end
        filename = original:match("([^/]+)$")
    end
    if not filename then
        return nil
    end
    return string.format("https://%s.wikipedia.org/wiki/File:%s", lang, filename)
end

--[[-------------------------------------------------------------------------
HTML transform
--]]

-- Tags that never have a close tag, so they must not be pushed on the
-- walker's stack (Wikipedia's HTML is XHTML-ish and self-closes them, but
-- be tolerant).
local VOID_TAGS = {
    area = true, base = true, br = true, col = true, embed = true,
    hr = true, img = true, input = true, link = true, meta = true,
    param = true, source = true, track = true, wbr = true,
}

-- Classifies an open tag for the walker: <figure> with a mw:File/mw:Image
-- typeof, div.thumb (legacy thumbs, multiple-image boxes, gallery thumbs)
-- and li.gallerybox are all "image box" contexts -- any <img> inside one of
-- those becomes a QR code.
--
-- Note: <span typeof="mw:File"> is deliberately NOT an image-box context:
-- MediaWiki uses those spans for small inline icons in the prose (moon
-- phase symbols, flags, ...), which would be silly as QR codes. Images in
-- galleries are covered anyway via their div.thumb/li.gallerybox parents.
-- Kept infoboxes (the "Show infoboxes" option) are NOT an
-- image-box context either: their media is stripped entirely before this
-- pass runs (see htmlclean.stripImageCells), so nothing inside them should
-- become a QR code.
local function hasClass(cls, token)
    for w in cls:gmatch("[^%s]+") do
        if w == token then
            return true
        end
    end
    return false
end

local function className(attrs)
    return (attrs:match([[class%s*=%s*"([^"]*)"]]) or ""):lower()
end

local function classify(tag, attrs)
    if tag == "figure" then
        local typeof = (attrs:match([[typeof%s*=%s*"([^"]*)"]]) or ""):lower()
        if typeof:find("mw:file") ~= nil
            or typeof:find("mw:image") ~= nil
            or typeof:find("mw:video") ~= nil then
            return { tag = tag, is_img = true }
        end
    elseif tag == "div" then
        local cls = className(attrs)
        if cls:find("thumb") then
            return { tag = tag, is_img = true }
        end
    elseif tag == "li" then
        local cls = (attrs:match([[class%s*=%s*"([^"]*)"]]) or ""):lower()
        if cls:find("gallerybox") then
            return { tag = tag, is_img = true }
        end
    end
    return { tag = tag }
end

local function inImageBox(stack)
    for i = 1, #stack do
        if stack[i].is_img then
            return true
        end
    end
    return false
end

-- Generates the QR PNG for `url`, appends it to `qr_images` and returns
-- the marker span. Returns "" if the URL could not be QR-coded.
local function makeQr(url, qr_images, qr_size)
    local index = #qr_images + 1
    local png = M.qrPng(url, qr_size)
    if not png then
        return ""
    end
    qr_images[index] = { path = string.format("images/qr%05d.png", index), png = png, url = url }
    return string.format('<span class="wikireader-qrimg" data-qrindex="%d"></span>', index)
end

-- Replaces one <img> tag with a QR placeholder span, appending the
-- generated PNG to `qr_images`. Returns the marker HTML, or "" if the
-- image had no usable URL / could not be QR-coded (the caption survives).
local function qrImageTag(img_tag, attrs, qr_images, qr_size, lang)
    local src = attrs:match([[src%s*=%s*"([^"]*)"]])
    if not src or src:sub(1, 5) == "data:" then
        return ""
    end
    local url = M.filePageUrl(src, lang)
    if not url then
        return ""
    end
    return makeQr(url, qr_images, qr_size)
end

-- Replaces a video or <audio> element found inside an image box with
-- a QR placeholder of the media's File: page. MediaWiki video/audio
-- figures put the actual streams in <source> children: a handful of
-- transcoded derivatives and usually the original full media file. The
-- QR points at the file's description page (recovering the filename from
-- the original file when one is present, or from the first usable
-- <source>/poster otherwise), so the scan opens the transcoded player
-- rather than a huge original download. Returns the marker HTML, or ""
-- if nothing usable was found (the caption survives).
local function qrMediaTag(media_tag, media, qr_images, qr_size, lang)
    -- <source> children carry the actual streams. <track> children are
    -- subtitle metadata (timedtext API), not media, so ignore them.
    local original_src
    local first_src
    for src in media:gmatch([[<source[^>]*src%s*=%s*"([^"]*)"[^>]*>]]) do
        if src:sub(1, 5) ~= "data:" then
            if not first_src then
                first_src = src
            end
            if not src:find("transcoded", 1, true) then
                original_src = src
            end
        end
    end
    local url = original_src or first_src
    if not url then
        -- No <source> children: a direct <video src="...">, else the
        -- poster thumbnail as a last resort.
        url = media_tag:match([[src%s*=%s*"([^"]*)"]])
            or media_tag:match([[poster%s*=%s*"([^"]*)"]])
    end
    if not url then
        return ""
    end
    url = M.filePageUrl(url, lang)
    if not url then
        return ""
    end
    return makeQr(url, qr_images, qr_size)
end

-- Walks the article HTML and replaces every image, video or audio
-- element that sits inside an "image box" (figure, gallerybox, div.thumb)
-- with a QR placeholder span. The placeholders are later swapped for real
-- <img> tags by the EPUB builder, once it knows the final file layout.
-- Any other <img>/<video>/<audio> (inline symbols, timeline renderings,
-- pronunciation players outside boxes, ...) is left untouched for
-- createEpub() to deal with as before.
function M.replaceImagesWithQr(html, qr_images, qr_size, lang)
    -- HTML comments can contain arbitrary text that would confuse the tag
    -- walker (and are meaningless in the final document anyway).
    html = html:gsub("<!%-%-.-%-%->", "")
    local out = {}
    local pos = 1
    local stack = {}
    -- Depth of locmap containers currently being dropped (see below).
    local suppress = 0
    local tag_pat = "<(/?)%s*([a-zA-Z][a-zA-Z0-9]*)([^>]*)>"
    while true do
        local s, e, is_close, tag, attrs = html:find(tag_pat, pos)
        if not s then
            -- Trailing text after the last tag; unless we're mid-drop of a
            -- locmap figure, keep it.
            if suppress == 0 then
                out[#out + 1] = html:sub(pos)
            end
            break
        end
        local tagname = tag:lower()
        local full = html:sub(s, e)

        if suppress > 0 then
            -- Inside a removed locmap figure: swallow every tag and the text
            -- between them, but keep tracking open/close tags so we know when
            -- the dropped container finally closes.
            if is_close ~= "" then
                if #stack > 0 and stack[#stack].tag == tagname then
                    local entry = stack[#stack]
                    stack[#stack] = nil
                    if entry.is_dropped then
                        suppress = suppress - 1
                    end
                end
            elseif not (VOID_TAGS[tagname] or attrs:find("%s*/%s*$")) then
                stack[#stack + 1] = { tag = tagname }
            end
            pos = e + 1
        else
            out[#out + 1] = html:sub(pos, s - 1)
            local consumed_until
            if tagname == "img" then
                if inImageBox(stack) then
                    out[#out + 1] = qrImageTag(full, attrs, qr_images, qr_size, lang)
                else
                    out[#out + 1] = full
                end
            elseif is_close ~= "" then
                if #stack > 0 and stack[#stack].tag == tagname then
                    stack[#stack] = nil
                end
                out[#out + 1] = full
            elseif (tagname == "video" or tagname == "audio") and inImageBox(stack) then
                -- Inside an image box: replace the whole <video>…</video> /
                -- <audio>…</audio> element, since its <source> children carry
                -- the actual URLs.
                local close_start, close_end = html:find("</" .. tagname .. "%s*>", e + 1)
                if close_start then
                    out[#out + 1] = qrMediaTag(full, html:sub(e + 1, close_start - 1), qr_images, qr_size, lang)
                    consumed_until = close_end + 1  -- discard up to </video>|</audio>
                else
                    -- Malformed (no close tag): leave the tag as-is.
                    out[#out + 1] = full
                end
            elseif VOID_TAGS[tagname] or attrs:find("%s*/%s*$") then
                -- self-closing / void tag: nothing to push
                out[#out + 1] = full
            else
                local entry = classify(tagname, attrs)
                -- A location map (<div class="locmap">) is meant to be seen as
                -- its base map with marker overlays composited on top. With
                -- media images disabled we could only offer a bare, marker-
                -- less map as a QR, which would be meaningless to the reader.
                -- Drop the whole figure -- map, overlays and caption alike.
                if tagname == "div" and hasClass(className(attrs), "locmap") then
                    entry.is_dropped = true
                    suppress = suppress + 1
                    out[#out + 1] = ""  -- drop the locmap's open tag
                else
                    out[#out + 1] = full
                end
                stack[#stack + 1] = entry
            end
            pos = consumed_until or (e + 1)
        end
    end
    local result = table.concat(out)
    -- Some layouts wrap the image in a link to the file page; drop that
    -- wrapper around our QR marker so the QR isn't a confusing tap target.
    result = result:gsub('(<a[^>]*>%s*)(<span class="wikireader%-qrimg"[^>]*></span>)(%s*</a>)', '%2')
    return result
end

return M
