--[[--
Image-box walker and lazy-image placeholders for WikiReader.

Articles are cached as EPUBs built immediately: the actual
photographs/diagrams are not downloaded during the build (an article can
carry dozens of them, each several hundred KB). This module instead finds
every boxed image (figure, legacy thumb, gallery box) and replaces it with
a placeholder span that reserves the image's real footprint; the EPUB
builder records the download URLs and lazyfetch.lua fetches them in the
background after the article opens, filling the placeholders in.

Media inside kept infobox tables keeps only genuine media (inline flag
icons are removed while keeping the name text they sit beside), routed
through the same placeholder pipeline.
]]

local bit = require("bit")
local wutil = require("wikiutil")

local M = {}

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

-- Wikimedia's standard thumb widths (see [[Common thumbnail sizes]]):
-- any other width gets a 400, so hi-res URL rewrites must snap to this.
local THUMB_LADDER = { 20, 40, 60, 120, 250, 330, 500, 960, 1280, 1920, 3840 }
-- Exposed for locmap.lua's hi-res rewrite (keeps the ladder in one place).
M.THUMB_LADDER = THUMB_LADDER

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
-- those becomes a lazy placeholder.
--
-- Note: <span typeof="mw:File"> is deliberately NOT an image-box context:
-- MediaWiki uses those spans for small inline icons in the prose (moon
-- phase symbols, flags, ...), which are not worth background-downloading.
-- Images in galleries are covered anyway via their div.thumb/li.gallerybox
-- parents.
-- Kept infoboxes (the "Show infoboxes" option) are an image-box context
-- only when opts.treat_infobox_as_imagebox is set: htmlclean leaves their
-- media cells in place (stripImageCells with keep_images) and img_fn turns
-- those imgs into lazy placeholders. Inline icons are removed
-- by stripImageCells first, so only genuine media survives inside the box.
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
        -- Video/audio figures have no image to show; mark
        -- the whole figure for the walker's locmap-style suppression so
        -- it, its caption and its media all vanish (no empty dashed box).
        if typeof:find("mw:video") ~= nil
            or typeof:find("mw:audio") ~= nil then
            return { tag = tag, is_dropped = true }
        end
    elseif tag == "div" then
        local cls = className(attrs)
        -- Substring "thumb" also matches thumbinner/thumbcaption, which are
        -- content inside a thumbnail box, not boxes themselves -- a caption
        -- div carries no media and must not count as an image box (the
        -- no-media suppression would then drop the caption whole).
        if cls:find("thumb") and not cls:find("thumbcaption") then
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

-- Picks the URL lazyfetch should download for an <img> with these attrs:
-- a sharper derivative of the 1x src. Returns the URL or nil if the tag
-- has no usable src.
local function pickDownloadSrc(attrs)
    local src = attrs:match([[src%s*=%s*"([^"]*)"]])
    if not src or src:sub(1, 5) == "data:" then
        return nil
    end
    if src:sub(1, 2) == "//" then
        src = "https:" .. src
    end
    -- Sharper variants keep the reserved 1x footprint so layout doesn't
    -- change (crengine just scales the sharper bitmap); the 1x src stays
    -- as lazyfetch's failure fallback.
    local download_src, fallback = src, nil
    do
        -- The srcset tops out at a ~960px "2x" entry, still low-res zoomed
        -- in on E-ink; THUMB_LADDER's bigger standard sizes are the only
        -- other widths Wikimedia serves (anything else gets a 400). Rewrite
        -- the /NNNpx- thumb segment to the next step at or above 4x the
        -- rendered width, clamped to the original's data-file-width; when
        -- no rewrite applies, use the srcset variant like KOReader's
        -- ui/wikipedia.lua.
        local variant
        local file_w = tonumber(attrs:match([[data%-file%-width%s*=%s*"(%d+)"]]))
        local w = tonumber(src:match("/(%d+)px-"))
        if w then
            -- Clamp to the original so tiny files aren't upscaled; the
            -- step above the clamp may still be (up to ~33%, harmless).
            local target = math.min(file_w or math.huge, w * 4)
            for _, size in ipairs(THUMB_LADDER) do
                if size >= target then
                    if size > w then
                        -- Replacement string: '%' is only pattern-magic on
                        -- the left side.
                        variant = src:gsub("/%d+px%-", "/" .. size .. "px-")
                    end
                    break
                end
            end
        end
        if not variant then
            local srcset = attrs:match([[srcset%s*=%s*"([^"]*)"]])
            if srcset then
                -- " " and trailing ", " make the match patterns work for the
                -- first/last srcset item too (same trick as ui/wikipedia.lua).
                srcset = " " .. srcset .. ", "
                variant = srcset:match([[ (%S+) 2x, ]])
                if not variant then
                    variant = srcset:match([[ (%S+) 1.5x, ]])
                end
            end
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
    return download_src, fallback
end

-- True if an <img> with these attrs is both downloadable and displayable
-- by crengine (the same rules lazyImageTag enforces before reserving a
-- placeholder).
local function usableLazyImg(attrs)
    local src = pickDownloadSrc(attrs)
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
local function lazyImageTag(attrs, lazy_images, seen, section, centered, infobox)
    local download_src, fallback = pickDownloadSrc(attrs)
    if not download_src then
        return ""
    end
    local ext = download_src:gsub("%?.*$", ""):match(".*%.(%S%S%S?%S?%S?)$")
    ext = ext and ext:lower()
    if not ext or not EXT_MIMETYPE[ext] then
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
    -- crengine doesn't center inline imgs via the parent cell's text-align.
    if centered then
        style_props[#style_props + 1] = "display:block"
        style_props[#style_props + 1] = "margin:0 auto"
    end
    local style = table.concat(style_props, "; ")
    -- The same image file can recur in different contexts (infobox media
    -- vs article body, or a different rendered footprint) that lazyfetch
    -- sizes by different rules, so only identical context dedupes.
    local key = download_src .. "\1" .. tostring(infobox) .. "\1" .. style
    if seen[key] then
        local hit = seen[key]
        return string.format('<span class="wikireader-lazyimg" data-lazyindex="%d" style="%s"></span>',
            hit.index, hit.style)
    end
    if #lazy_images >= MAX_LAZY_IMAGES then
        return ""
    end
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
    seen[key] = { index = index, style = style }
    return string.format('<span class="wikireader-lazyimg" data-lazyindex="%d" style="%s"></span>',
        index, style)
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
--   treat_infobox_as_imagebox: also treat class=infobox subtrees as
--     image-box context (lazy mode with "Show infoboxes": their kept
--     media imgs become lazy placeholders).
-- Blocks of media are suppressed whole when they contain no image -- a
-- figure whose content is a <video>/<audio> (Parsoid types those
-- mw:File/Thumb like images, so classify() can't tell) has nothing to
-- show, and keeping it would leave a caption-only stub.
-- drop_unsupported additionally suppresses the box when ANY contained
-- <img> fails the predicate (lazy mode: unusable format) instead of
-- leaving a caption-only stub. Infobox entries are exempt: losing an
-- entire infobox over one bad image is worse than an empty cell.
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
                -- Video/audio figures are dropped the same way (no image to
                -- keep, so no empty caption stub).
                if opts.treat_infobox_as_imagebox
                    and className(attrs):find("infobox", 1, true) then
                    entry.is_img = true
                    entry.is_infobox = true
                end
                -- Unusable-image boxes are suppressed whole, so their
                -- captions don't dangle without the image they describe.
                if entry.is_img and not entry.is_infobox then
                    local close_start = wutil.findMatchingClose(html, tagname, e)
                    if close_start then
                        local region = html:sub(e + 1, close_start - 1)
                        -- Optional caption-capture hook (see collectImageCaptions).
                        if opts.region_fn then opts.region_fn(region) end
                        local any_img
                        for img_attrs in region:gmatch("<img([^>]*)>") do
                            any_img = true
                            if opts.drop_unsupported and opts.drop_unsupported(img_attrs) then
                                entry.is_dropped = true
                                break
                            end
                        end
                        if not any_img then
                            entry.is_dropped = true
                        end
                    end
                elseif entry.is_infobox then
                    -- Kept infoboxes pair images and captions across table
                    -- rows/cells (see infoboxCaptions), not thumbcaptions.
                    local close_start = wutil.findMatchingClose(html, tagname, e)
                    if close_start and opts.infobox_fn then
                        opts.infobox_fn(html:sub(e + 1, close_start - 1))
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
    result = result:gsub('(<a[^>]*>%s*)(<span class="wikireader%-lazyimg"[^>]*></span>)(%s*</a>)', '%2')
    return result
end

--[[-------------------------------------------------------------------------
timeline-wrapper blocks (EasyTimeline)

{{#tag:timeline}} renders as a bare
<div class="timeline-wrapper"><map name="..."></map><img usemap="#..."
src="//upload.wikimedia.org/wikipedia/en/timeline/<hash>.png"/></div>:
hash-named, no thumb box, no width/height. The walker
sees no image box here, so this pass routes the chart through the same
placeholder machinery first. The PNG's real size never appears in the
markup, so the natural 900x500 canvas is reserved as the lazy footprint
(lazyfetch's realImageSizeStyle() re-caps it later).
--]]
-- Only this src layout identifies an EasyTimeline render.
local RENDER_PAT = [[src%s*=%s*"(//upload%.wikimedia%.org/wikipedia/[^/]+/timeline/[^/%"]+)%"]]

function M.replaceTimelineWrappers(html, lazy_images, seen)
    return html:gsub(
        '<div class="timeline%-wrapper">(.-)</div>',
        function(inner)
            local attrs = inner:match([[<img%s+([^>]*)>]])
            if not attrs or not attrs:match(RENDER_PAT) then
                return nil -- leave anything else with that class alone
            end
            local marker = lazyImageTag(attrs, lazy_images, seen, 0, true, false)
            if marker == "" then
                return "" -- unusable: drop the box
            end
            -- No width/height in the render to reserve; graft the
            -- natural-canvas footprint.
            marker = marker:gsub('style="',
                'style="width:900px; height:500px; ', 1)
            return marker
        end)
end

--[[-------------------------------------------------------------------------
Full-screen image captions

crengine exposes no image metadata at a held position, so the EPUB builder
wraps each captioned image in a sentinel link carrying the caption
(epub.lua's captionLink), and main.lua's hold-on-image hook decodes it into
the full-screen viewer's title. This pass collects each image box's caption
text (figcaption, or the old-parser thumbcaption/gallerytext div), keyed by
the box's original 1x image URL — the same key the marker tables' src or
fallback entries resolve to at swap time.
--]]

-- Minimal entity decoding for caption text (Parsoid only ever uses these
-- named entities and numeric references in captions).
local NAMED_ENTITIES = {
    amp = "&",
    lt = "<",
    gt = ">",
    quot = '"',
    apos = "'",
    nbsp = " ",
    shy = "",
    ndash = "\226\128\147",
    mdash = "\226\128\148",
    hellip = "\226\128\166",
    rsquo = "\226\128\153",
    lsquo = "\226\128\152",
    ldquo = "\226\128\156",
    rdquo = "\226\128\157",
}

local function codepointToUtf8(c)
    if c < 0x80 then
        return string.char(c)
    elseif c < 0x800 then
        return string.char(bit.bor(0xC0, bit.rshift(c, 6)), bit.bor(0x80, bit.band(c, 0x3F)))
    elseif c < 0x10000 then
        if c >= 0xD800 and c <= 0xDFFF then
            return "?" -- surrogates
        end
        return string.char(bit.bor(0xE0, bit.rshift(c, 12)),
            bit.bor(0x80, bit.band(bit.rshift(c, 6), 0x3F)),
            bit.bor(0x80, bit.band(c, 0x3F)))
    elseif c < 0x110000 then
        return string.char(bit.bor(0xF0, bit.rshift(c, 18)),
            bit.bor(0x80, bit.band(bit.rshift(c, 12), 0x3F)),
            bit.bor(0x80, bit.band(bit.rshift(c, 6), 0x3F)),
            bit.bor(0x80, bit.band(c, 0x3F)))
    end
    return "?"
end

local function decodeEntities(s)
    return (s:gsub("&([%w#]+);", function(name)
        if name:sub(1, 1) == "#" then
            local digits = name:sub(2)
            local code = digits:sub(1, 1) == "x"
                and tonumber(digits:sub(2), 16) or tonumber(digits)
            return code and code > 0 and codepointToUtf8(code) or ""
        end
        return NAMED_ENTITIES[name]
    end))
end

-- Captions show on the viewer's title bar, which reflows on its own, so
-- tag runs collapse to spaces and <br> is treated as a plain break there.
local function captionPlainText(text)
    text = text:gsub("%s*<%s*br%s*/?>%s*", " ")
    -- Footnote/reference markers ([2], [note 1]) ride in <sup> elements;
    -- the title bar wants the caption text alone. Balanced surgery keeps
    -- any nested markup inside the sup from leaking after the strip below.
    while true do
        local sup_open, sup_end = text:find("<sup[^>]*>")
        if not sup_open then break end
        local sup_close, sup_close_end = wutil.findMatchingClose(text, "sup", sup_end)
        if not sup_close then break end
        text = text:sub(1, sup_open - 1) .. " " .. text:sub(sup_close_end + 1)
    end
    text = text:gsub("<[^>]*>", " ")
    text = decodeEntities(text)
    text = text:gsub("%s+", " ")
    return (text:match("^%s*(.-)%s*$"))
end

-- Shared tail of every caption read: plain-text it and cap it for the
-- sentinel URL, cutting at a space so no UTF-8 sequence splits.
local function finalizeCaption(text)
    text = captionPlainText(text)
    if text == "" then
        return nil
    end
    if #text > 480 then
        -- Sentinel-URL sane: cut at a space so no UTF-8 sequence splits.
        text = text:sub(1, 480):match("^(.*%s)") or text:sub(1, 480)
    end
    return text
end

local function boxCaptionText(region)
    local text = region:match([[<figcaption[^>]*>(.-)</figcaption>]])
    if not text then
        -- Old-parser thumbnails and gallery items caption via divs.
        for _, token in ipairs({ "thumbcaption", "gallerytext" }) do
            local open_start, open_end = region:find(
                [[<div[^>]-class%s*=%s*"[^"]*]] .. token .. [[[^" ]*"[^>]*>]])
            if open_start then
                local close_start = wutil.findMatchingClose(region, "div", open_end)
                if close_start then
                    text = region:sub(open_end + 1, close_start - 1)
                    break
                end
            end
        end
    end
    if not text then
        return nil
    end
    return finalizeCaption(text)
end

-- force: per-item grid captions overwrite box-level defaults.
local function regionCaption(captions, region, cap, force)
    if not cap then return false end
    for attrs in region:gmatch("<img%s([^>]*)>") do
        local src = attrs:match([[src%s*=%s*"([^"]*)"]])
        if src and src:sub(1, 5) ~= "data:" then
            if src:sub(1, 2) == "//" then src = "https:" .. src end
            captions[src] = force and cap or (captions[src] or cap)
        end
    end
    return true
end

-- {{Multiple image}} grids caption per item; boxCaptionText on the whole
-- grid would stamp the first item's caption on all of them.
local function tsingleCaptions(region, captions, force)
    local got = false
    local pos = 1
    while true do
        local t_open, t_end = region:find(
            [[<div[^>]-class%s*=%s*"[^"]*tsingle[^" ]*"[^>]*>]], pos)
        if not t_open then break end
        local t_close = wutil.findMatchingClose(region, "div", t_end)
        local tsingle = region:sub(t_end + 1, t_close and t_close - 1 or #region)
        pos = t_close and t_close + 1 or #region + 1
        if tsingleCaptions(tsingle, captions, force) then
            got = true
        else
            local cap = boxCaptionText(tsingle)
            if not cap then
                -- Parsoid's tmulti captions items via text-align-* divs.
                local d_open, d_end = tsingle:find(
                    [[<div[^>]-class%s*=%s*"[^"]*text%-align[^" ]*"[^>]*>]])
                if d_open then
                    local d_close = wutil.findMatchingClose(tsingle, "div", d_end)
                    if d_close then
                        cap = finalizeCaption(tsingle:sub(d_end + 1, d_close - 1))
                    end
                end
            end
            got = regionCaption(captions, tsingle, cap, force) or got
        end
    end
    return got
end

-- Kept infoboxes caption via table shapes, not thumbcaptions: a figcaption
-- in the image's figure, an .infobox-caption cell/div in the row, or --
-- Speciesbox and the biota family -- a text-only row directly below, marked
-- by the templates' stable caption markers (88% style / infobox-caption).
local function infoboxCaptions(region, captions)
    local srcs = {} -- rebuilt per row
    local function collectRowImgs(row)
        srcs = {}
        for attrs in row:gmatch("<img([^>]*)>") do
            local src = attrs:match([[src%s*=%s*"([^"]*)"]])
            if src and src:sub(1, 5) ~= "data:" then
                if src:sub(1, 2) == "//" then src = "https:" .. src end
                srcs[#srcs + 1] = src
            end
        end
    end
    local function assign(list, cap)
        if cap and cap ~= "" then
            for _, src in ipairs(list) do
                captions[src] = captions[src] or cap
            end
        end
        return cap and cap ~= ""
    end
    -- Image rows only match their marker-marked caption row directly below
    -- them, so a random single-cell row later on can't steal the caption.
    local pending = nil
    local pos = 1
    while true do
        local r_open, r_end = region:find("<tr[^>]*>", pos)
        if not r_open then break end
        local close_start = wutil.findMatchingClose(region, "tr", r_end)
        local row = region:sub(r_end + 1, close_start and close_start - 1 or #region)
        pos = close_start and close_start + 1 or #region + 1
        collectRowImgs(row)
        if #srcs > 0 then
            local captioned = false
            -- A {{Multiple image}} grid without a div.thumb wrapper (kept
            -- infoboxes unwrap it) lives in the row's cell: pair its
            -- per-item captions first.
            if tsingleCaptions(row, captions, true) then
                captioned = true
            end
            -- Figures caption their own images.
            local fpos = 1
            while true do
                local f_open, f_end = row:find("<figure[^>]*>", fpos)
                if not f_open then break end
                local f_close = wutil.findMatchingClose(row, "figure", f_end)
                local fig = row:sub(f_end + 1, f_close and f_close - 1 or #row)
                fpos = f_close and f_close + 1 or #row + 1
                local fig_srcs = {}
                for attrs in fig:gmatch("<img([^>]*)>") do
                    local src = attrs:match([[src%s*=%s*"([^"]*)"]])
                    if src then fig_srcs[#fig_srcs + 1] = src end
                end
                if assign(fig_srcs, boxCaptionText(fig)) then captioned = true end
            end
            -- An .infobox-caption cell (td) or div in the row captions the
            -- whole row's images (map cells, grouped media cells). Lua
            -- patterns have no alternation, so the two shapes are probed.
            local cap_open, cap_end = row:find(
                [[<td[^>]-class%s*=%s*"[^"]*infobox%-caption[^" ]*"[^>]*>]])
            local cap_close
            if cap_open then
                local td_close = wutil.findMatchingClose(row, "td", cap_end)
                if td_close then cap_close = td_close - 1 end
            else
                cap_open, cap_end = row:find(
                    [[<div[^>]-class%s*=%s*"[^"]*infobox%-caption[^" ]*"[^>]*>]])
                if cap_open then
                    local div_close = wutil.findMatchingClose(row, "div", cap_end)
                    if div_close then cap_close = div_close - 1 end
                end
            end
            if cap_open and cap_close
                and assign(srcs, captionPlainText(row:sub(cap_end + 1, cap_close))) then
                captioned = true
            end
            pending = not captioned and #srcs > 0 and srcs or nil
        elseif pending then
            -- Speciesbox-style caption row: one bare marker-marked cell.
            if row:find("font%-size%s*:%s*88%%")
                and (row:find("<td[^>]*>") or row:find("<th[^>]*>"))
                and assign(pending, captionPlainText(row)) then
                pending = nil
            else
                pending = nil
            end
        end
    end
end

-- Fills `captions[src] = caption text`, keyed by the image's original 1x
-- URL (protocol-relative normalized). Read-only identity walk: infobox rows
-- are captured unconditionally, independent of the rewriting passes.
function M.collectImageCaptions(html, captions)
    walkImageBoxes(html, function(attrs)
        -- Identity replacement: this pass only reads the box regions.
        return "<img" .. attrs .. ">"
    end, {
        treat_infobox_as_imagebox = true,
        region_fn = function(region)
            if tsingleCaptions(region, captions) then
                return
            end
            regionCaption(captions, region, boxCaptionText(region))
        end,
        infobox_fn = function(region)
            infoboxCaptions(region, captions)
        end,
    })
end

-- Lazy-image mode: boxed <img>s become placeholders whose zip entries are
-- filled in later by lazyfetch.lua; each placeholder records the index of
-- the article section it sits in, which the background scheduler maps to
-- a page number via the document TOC. With "Show infoboxes", kept
-- infobox media (htmlclean keeps the image cells here) is routed through
-- the same placeholders. locmap divs are already gone by now: locmap.lua
-- replaces them with composite/lazy markers before this runs.
function M.replaceImagesWithLazy(html, lazy_images, opts)
    local seen = {}
    return walkImageBoxes(html,
        function(attrs, section, infobox)
            return lazyImageTag(attrs, lazy_images, seen, section or 0,
                infobox, infobox)
        end,
        {
            treat_infobox_as_imagebox = opts and opts.treat_infobox_as_imagebox,
            drop_unsupported = function(attrs)
                return not usableLazyImg(attrs)
            end
        })
end

-- Exposed for locmap.lua: builds a lazy placeholder span for arbitrary
-- <img> attrs, registering it in `lazy_images` like the walker does.
-- (centered only centers the placeholder; infobox marks infobox media,
-- which lazyfetch sizes cap-only, without the article images' floor.)
function M.makeLazyImageTag(attrs, lazy_images, seen, section, centered, infobox)
    return lazyImageTag(attrs, lazy_images, seen, section or 0, centered, infobox)
end

return M
