--[[--
QR-code image generation for WikiReader.

Articles are cached as EPUBs with images permanently disabled: the actual
photographs/diagrams are never downloaded, because an article can contain
dozens of them and each can be several hundred KB. Previously that meant
dropping the whole image box -- image *and* caption -- from the EPUB.

Instead, this module replaces each article image with a small QR code of
the image's URL: the box (and its caption) stays in the document, and
scanning the QR code with a phone opens the real image. Nothing is ever
fetched; a tiny black-and-white PNG is embedded per figure.

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

-- Turns a Wikipedia <img> src into the URL the QR code should point at:
-- absolute, free of tracking query params, and upgraded from the thumbnail
-- to the original full-size file when the src is a thumb URL. Returns nil
-- for URLs we can't make sense of (relative paths, data: URIs, ...).
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
local function classify(tag, attrs)
    if tag == "figure" then
        local typeof = (attrs:match([[typeof%s*=%s*"([^"]*)"]]) or ""):lower()
        if typeof:find("mw:file") ~= nil or typeof:find("mw:image") ~= nil then
            return { tag = tag, is_img = true }
        end
    elseif tag == "div" then
        local cls = (attrs:match([[class%s*=%s*"([^"]*)"]]) or ""):lower()
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

-- Replaces one <img> tag with a QR placeholder span, appending the
-- generated PNG to `qr_images`. Returns the marker HTML, or "" if the
-- image had no usable URL / could not be QR-coded (the caption survives).
local function qrImageTag(img_tag, attrs, qr_images, qr_size)
    local src = attrs:match([[src%s*=%s*"([^"]*)"]])
    if not src or src:sub(1, 5) == "data:" then
        return ""
    end
    local url = M.cleanImageUrl(src)
    if not url then
        return ""
    end
    local index = #qr_images + 1
    local png = M.qrPng(url, qr_size)
    if not png then
        return ""
    end
    qr_images[index] = { path = string.format("images/qr%05d.png", index), png = png, url = url }
    return string.format('<span class="wikireader-qrimg" data-qrindex="%d"></span>', index)
end

-- Walks the article HTML and replaces every image that sits inside an
-- "image box" (figure, gallerybox, div.thumb) with a QR placeholder span.
-- The placeholders are later swapped for real <img> tags by the EPUB
-- builder, once it knows the final file layout. Any other <img> (inline
-- symbols, timeline renderings, ...) is left untouched for createEpub()
-- to deal with as before.
function M.replaceImagesWithQr(html, qr_images, qr_size)
    -- HTML comments can contain arbitrary text that would confuse the tag
    -- walker (and are meaningless in the final document anyway).
    html = html:gsub("<!%-%-.-%-%->", "")
    local out = {}
    local pos = 1
    local stack = {}
    local tag_pat = "<(/?)%s*([a-zA-Z][a-zA-Z0-9]*)([^>]*)>"
    while true do
        local s, e, is_close, tag, attrs = html:find(tag_pat, pos)
        if not s then
            out[#out + 1] = html:sub(pos)
            break
        end
        out[#out + 1] = html:sub(pos, s - 1)
        local tagname = tag:lower()
        local full = html:sub(s, e)
        if tagname == "img" then
            if inImageBox(stack) then
                out[#out + 1] = qrImageTag(full, attrs, qr_images, qr_size)
            else
                out[#out + 1] = full
            end
        elseif is_close ~= "" then
            if #stack > 0 and stack[#stack].tag == tagname then
                stack[#stack] = nil
            end
            out[#out + 1] = full
        elseif VOID_TAGS[tagname] or attrs:find("%s*/%s*$") then
            -- self-closing / void tag: nothing to push
            out[#out + 1] = full
        else
            stack[#stack + 1] = classify(tagname, attrs)
            out[#out + 1] = full
        end
        pos = e + 1
    end
    local result = table.concat(out)
    -- Some layouts wrap the image in a link to the file page; drop that
    -- wrapper around our QR marker so the QR isn't a confusing tap target.
    result = result:gsub('(<a[^>]*>%s*)(<span class="wikireader%-qrimg"[^>]*></span>)(%s*</a>)', '%2')
    return result
end

return M
