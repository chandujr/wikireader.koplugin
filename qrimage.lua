--[[--
QR-code image generation for WikiReader.

Articles are cached as EPUBs with images permanently disabled: the actual
photographs/diagrams are never downloaded, because an article can contain
dozens of them and each can be several hundred KB, and without replacement
the image box (image *and* caption) would be lost entirely.

Instead, this module replaces each article image with a small QR code
of the image's File: description page: the box (and its caption) stays
in the document, and scanning the QR code with a phone opens that page
(which shows the real image instead of a huge original download).
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
local wutil = require("wikiutil")

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

-- Image formats we are willing to background-download (lazy-image mode),
-- with the mimetype their EPUB manifest item needs.
-- webp thumbs exist, but crengine can't decode them, so they fall back to
-- the 1x URL. GIFs are excluded on purpose: crengine renders them as a
-- static first frame, which loses the only thing a GIF is there for.
local EXT_MIMETYPE = {
    png = "image/png",
    jpg = "image/jpeg",
    jpeg = "image/jpeg",
    webp = "image/webp",
    svg = "image/svg+xml",
}

-- Placeholder ceiling: an article can carry dozens of gallery images, and
-- every reserved box is a download plus reserved zip/memory space.
local MAX_LAZY_IMAGES = 60

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
-- occurs in the file's upload path, so we can recover it from the original
-- or thumbnail URL. Some URLs point at a /transcoded/ derived form rather
-- than the original; those are handled too. Returns nil if no filename
-- could be extracted (or no lang was given).
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
    area = true,
    base = true,
    br = true,
    col = true,
    embed = true,
    hr = true,
    img = true,
    input = true,
    link = true,
    meta = true,
    param = true,
    source = true,
    track = true,
    wbr = true,
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
-- Kept infoboxes (the "Show infoboxes" option) are not an image-box
-- context by default: in QR/none mode their media is stripped entirely
-- before this pass runs (htmlclean.stripImageCells), and in lazy mode
-- stripImageCells only runs with keep_images, leaving the (big) infobox
-- images in place -- there opts.treat_infobox_as_imagebox makes the
-- walker treat infobox subtrees as image-box context so those imgs get
-- lazy placeholders too. Either way, nothing inside an infobox should
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
            or typeof:find("mw:image") ~= nil then
            return { tag = tag, is_img = true }
        end
        -- Video/audio figures have no image to show or QR-encode; mark
        -- the whole figure for the walker's locmap-style suppression so
        -- it, its caption and its media all vanish (no empty dashed box).
        if typeof:find("mw:video") ~= nil
            or typeof:find("mw:audio") ~= nil then
            return { tag = tag, is_dropped = true }
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

local function inInfobox(stack)
    for i = 1, #stack do
        if stack[i].is_infobox then
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

-- Picks the URL lazyfetch should download for an <img> with these attrs:
-- in hi-res mode the srcset's 2x/1.5x derivative (the 1x URL is returned
-- as a failure fallback), else the 1x src. Returns the URL or nil if the
-- tag has no usable src.
local function pickDownloadSrc(attrs, hi_res)
    local src = attrs:match([[src%s*=%s*"([^"]*)"]])
    if not src or src:sub(1, 5) == "data:" then
        return nil
    end
    if src:sub(1, 2) == "//" then
        src = "https:" .. src
    end
    -- Hi-res mode: download the srcset's 2x (or 1.5x) derivative like
    -- KOReader's own highres option, keeping the reserved 1x footprint so
    -- layout doesn't change (crengine just scales the sharper bitmap).
    -- The 1x URL is recorded as a fallback for lazyfetch to retry when the
    -- bigger variant fails (derivatives can fail where the 1x succeeds).
    local download_src, fallback = src
    if hi_res then
        local srcset = attrs:match([[srcset%s*=%s*"([^"]*)"]])
        if srcset then
            -- " " and trailing ", " make the match patterns work for the
            -- first/last srcset item too (same trick as ui/wikipedia.lua).
            srcset = " " .. srcset .. ", "
            local variant = srcset:match([[ (%S+) 2x, ]])
            if not variant then
                variant = srcset:match([[ (%S+) 1.5x, ]])
            end
            if variant then
                if variant:sub(1, 2) == "//" then
                    variant = "https:" .. variant
                end
                if variant ~= src then
                    local vext = variant:gsub("%?.*$", ""):match(".*%.(%S%S%S?%S?%S?)$")
                    vext = vext and vext:lower()
                    if vext and EXT_MIMETYPE[vext] then
                        download_src = variant
                        fallback = src
                    end
                end
            end
        end
    end
    return download_src, fallback
end

-- True if an <img> with these attrs is both downloadable and displayable
-- by crengine (the same rules lazyImageTag enforces before reserving a
-- placeholder).
local function usableLazyImg(attrs, hi_res)
    local src = pickDownloadSrc(attrs, hi_res)
    if not src then return false end
    local ext = src:gsub("%?.*$", ""):match(".*%.(%S%S%S?%S?%S?)$")
    ext = ext and ext:lower()
    return ext ~= nil and EXT_MIMETYPE[ext] ~= nil
end

-- Replaces one <img> tag with a lazy-image placeholder span recording
-- the image's download URL and displayed footprint. The EPUB builder
-- later swaps markers for real <img> tags whose zip entries don't exist
-- yet; lazyfetch.lua downloads them and swaps the zip in place. Returns
-- "" for an image with no usable src/format; with the walker's
-- drop_unsupported predicate the whole box is removed then, otherwise
-- only the <img> vanishes (caption-only box). Returns "" for over-cap
-- images in either case.
local function lazyImageTag(attrs, lazy_images, seen, section, hi_res, centered, infobox)
    local download_src, fallback = pickDownloadSrc(attrs, hi_res)
    if not download_src then
        return ""
    end
    if seen[download_src] then
        local hit = seen[download_src]
        return string.format('<span class="wikireader-lazyimg" data-lazyindex="%d" style="%s"></span>',
            hit.index, hit.style)
    end
    if #lazy_images >= MAX_LAZY_IMAGES then
        return ""
    end
    -- Same style-carrying trick as KOReader's createEpub: crengine ignores
    -- width/height attributes but honors them in a style, and reserving
    -- the real footprint keeps the post-reload reflow minimal.
    local style_props = {}
    -- Anchored on whitespace so data-file-width/height can't match.
    local width = tonumber(attrs:match([[%swidth%s*=%s*"([^"]*)"]]))
    local height = tonumber(attrs:match([[%sheight%s*=%s*"([^"]*)"]]))
    if width then style_props[#style_props + 1] = string.format("width:%dpx", width) end
    if height then style_props[#style_props + 1] = string.format("height:%dpx", height) end
    -- crengine doesn't center inline imgs via the parent cell's text-align;
    -- block + auto margins also stacks multiple infobox images vertically,
    -- each centered.
    if centered then
        style_props[#style_props + 1] = "display:block"
        style_props[#style_props + 1] = "margin:0 auto"
    end
    local style = table.concat(style_props, "; ")
    local index = #lazy_images + 1
    lazy_images[index] = {
        src = download_src,
        imgpath = string.format("images/wrimg%05d.%s", index, ext),
        mimetype = EXT_MIMETYPE[ext],
        style = style,
        section = section,
        fallback = fallback,
        infobox = infobox,
    }
    seen[download_src] = { index = index, style = style }
    return string.format('<span class="wikireader-lazyimg" data-lazyindex="%d" style="%s"></span>',
        index, style)
end

-- Replaces one <img> tag with a QR placeholder span, appending the
-- generated PNG to `qr_images`. Returns the marker HTML, or "" if the
-- image had no usable URL / could not be QR-coded (the caption survives).
local function qrImageTag(attrs, qr_images, qr_size, lang)
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

-- Walks the article HTML and replaces every <img> that sits inside an
-- "image box" (figure, gallerybox, div.thumb) with a placeholder span
-- via the img_fn handler. The placeholders are later swapped for real
-- <img> tags by the EPUB builder, once it knows the final file layout.
-- Any other tagged media (inline symbols, timeline renderings,
-- pronunciation players outside boxes, ...) is left untouched for
-- createEpub() to handle.
-- img_fn also receives the number of h2-h6 headings seen so far, so the
-- lazy-image mode can record which article section each image sits under
-- (the TOC entry order matches the heading order).
-- opts (all optional):
--   drop_locmap: suppress div.locmap blocks entirely (qr mode; in lazy
--     mode locmaps are composited to marker spans by locmap.lua first).
--   treat_infobox_as_imagebox: also treat class=infobox subtrees as
--     image-box context (lazy mode with "Show infoboxes": their kept
--     media imgs become lazy placeholders).
--   drop_unsupported: predicate over <img> attrs; before emitting an
--     image box, the box's region is scanned and if ANY contained <img>
--     fails the predicate, the whole box (caption included) is
--     suppressed instead of leaving a caption-only stub. Infobox entries
--     are exempt: losing an entire infobox over one bad image is worse
--     than an empty cell.
local function walkImageBoxes(html, img_fn, opts)
    -- HTML comments can contain arbitrary text that would confuse the tag
    -- walker (and are meaningless in the final document anyway).
    html = html:gsub("<!%-%-.-%-%->", "")
    local out = {}
    local pos = 1
    local stack = {}
    local headings = 0
    -- Depth of suppressed containers currently being dropped
    -- (locmap divs and video/audio figures).
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
                    out[#out + 1] = img_fn(attrs, headings, inInfobox(stack))
                else
                    out[#out + 1] = full
                end
            elseif is_close ~= "" then
                if #stack > 0 and stack[#stack].tag == tagname then
                    stack[#stack] = nil
                end
                out[#out + 1] = full
            elseif (tagname == "video" or tagname == "audio") and inImageBox(stack) then
                -- Boxed video/audio is dropped: it has no image to encode.
                -- Still consume through the close tag -- its <source>
                -- children carry the actual URLs and would mispush the
                -- stack and leak into the output if walked.
                local close_start, close_end = html:find("</" .. tagname .. "%s*>", e + 1)
                if close_start then
                    out[#out + 1] = ""
                    consumed_until = close_end + 1 -- discard up to </video>|</audio>
                else
                    -- Malformed (no close tag): leave the tag as-is.
                    out[#out + 1] = full
                end
            elseif VOID_TAGS[tagname] or attrs:find("%s*/%s*$") then
                -- self-closing / void tag: nothing to push
                out[#out + 1] = full
            else
                local entry = classify(tagname, attrs)
                -- Headings index the article's sections (in the same order
                -- as the TOC entries), so lazy images can record their own
                -- section for the page-windowed download scheduler.
                if tagname:match("^h[2-6]$") then
                    headings = headings + 1
                end
                -- A location map (<div class="locmap">) is meant to be seen as
                -- its base map with marker overlays composited on top. With
                -- media images disabled we could only offer a bare, marker-
                -- less map as a QR, which would be meaningless to the reader.
                -- Drop the whole figure -- map, overlays and caption alike.
                -- Video/audio figures are dropped the same way (no image to
                -- keep, so no empty caption stub).
                if opts.drop_locmap and tagname == "div"
                    and hasClass(className(attrs), "locmap") then
                    entry.is_dropped = true
                elseif opts.treat_infobox_as_imagebox
                    and className(attrs):find("infobox", 1, true) then
                    entry.is_img = true
                    entry.is_infobox = true
                end
                -- Unusable-image boxes are suppressed whole, so their
                -- captions don't dangle without the image they describe.
                if opts.drop_unsupported and entry.is_img and not entry.is_infobox then
                    local close_start = wutil.findMatchingClose(html, tagname, e)
                    if close_start then
                        local region = html:sub(e + 1, close_start - 1)
                        for img_attrs in region:gmatch("<img([^>]*)>") do
                            if opts.drop_unsupported(img_attrs) then
                                entry.is_dropped = true
                                break
                            end
                        end
                    end
                end
                -- Suppression mode swallows the box and everything up to
                -- its matching close tag (caption included).
                if entry.is_dropped then
                    suppress = suppress + 1
                    out[#out + 1] = ""
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
    -- wrapper around our markers so they aren't a confusing tap target.
    result = result:gsub('(<a[^>]*>%s*)(<span class="wikireader%-qrimg"[^>]*></span>)(%s*</a>)', '%2')
    result = result:gsub('(<a[^>]*>%s*)(<span class="wikireader%-lazyimg"[^>]*></span>)(%s*</a>)', '%2')
    return result
end

-- QR mode: every boxed image becomes a QR code of its File:
-- description page.
function M.replaceImagesWithQr(html, qr_images, qr_size, lang)
    return walkImageBoxes(html,
        function(attrs)
            return qrImageTag(attrs, qr_images, qr_size, lang)
        end,
        { drop_locmap = true })
end

-- Lazy-image mode: boxed <img>s become placeholders whose zip entries are
-- filled in later by lazyfetch.lua; each placeholder records the index of
-- the article section it sits in, which the background scheduler maps to
-- a page number via the document TOC. With "Show infoboxes", kept
-- infobox media (htmlclean keeps the image cells here) is routed through
-- the same placeholders. locmap divs are already gone by now: locmap.lua
-- replaces them with composite/lazy markers before this runs.
function M.replaceImagesWithLazy(html, lazy_images, hi_res, opts)
    local seen = {}
    return walkImageBoxes(html,
        function(attrs, section, infobox)
            return lazyImageTag(attrs, lazy_images, seen, section or 0, hi_res,
                infobox, infobox)
        end,
        { treat_infobox_as_imagebox = opts and opts.treat_infobox_as_imagebox,
            drop_unsupported = function(attrs)
                return not usableLazyImg(attrs, hi_res)
            end })
end

-- Exposed for locmap.lua: builds a lazy placeholder span for arbitrary
-- <img> attrs, registering it in `lazy_images` like the walker does.
-- (centered only centers the placeholder; infobox marks infobox media,
-- which lazyfetch sizes differently.)
function M.makeLazyImageTag(attrs, lazy_images, seen, section, hi_res, centered, infobox)
    return lazyImageTag(attrs, lazy_images, seen, section or 0, hi_res, centered, infobox)
end

return M
