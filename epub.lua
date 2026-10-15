-- EPUB building for WikiReader.
-- Wraps KOReader's built-in Wikipedia.createEpub() with HTML cleanup
-- (stripping navboxes, removing image captions, etc.; rendering math
-- formulas as SVGs/text; extracting hatnotes into bordered boxes).
-- Infobox tables are stripped by default; the "Show infoboxes"
-- setting keeps them instead, forced to span the full page
-- width like wikitables. Also provides standalone EPUB builders for
-- search results and category navigation pages.

local Archiver = require("ffi/archiver")
local DocSettings = require("docsettings")
local Trapper = require("ui/trapper")
local Wikipedia = require("ui/wikipedia")
local socket_url = require("socket.url")
local util = require("util")
local _ = require("gettext")

local cache = require("wikireader-cache")
local cladogram = require("cladogram")
local htmlclean = require("htmlclean")
local latex = require("latex")
local qrimage = require("qrimage")
local locmap = require("locmap")
local wutil = require("wikiutil")

local M = {}

-- Every lazy placeholder is wrapped in a sentinel anchor on the reserved
-- .invalid host (an https URI is required: unknown schemes get mangled by
-- crengine's base-URI resolution; the reserved host never sees a fetch).
-- Captioned ones carry the percent-encoded caption for main.lua's
-- hold-on-image hook; uncaptioned ones get an index-only href, still
-- under the reserved host so tap stays inert.
local IMG_CAPTION_URL = "https://wikireader.invalid/imgcap="
local IMG_INDEX_URL = "https://wikireader.invalid/wridx="
local function sentinelLink(img_html, href, img_style)
    local a_open = '<a href="' .. href .. '"'
    -- A block img (centered placeholders) inside an inline anchor would be
    -- laid out inline: keep the anchor's layout matching the img's.
    if img_style and img_style:find("display:block", 1, true) then
        a_open = a_open .. ' style="display:block"'
    end
    return a_open .. ">" .. img_html .. "</a>"
end
local function sentinelHref(caption, idx)
    if caption then
        return IMG_CAPTION_URL .. socket_url.escape(caption)
    end
    return IMG_INDEX_URL .. string.format("%05d", idx)
end

-- Hourglass "loading" icon shown inside an image box until lazyfetch swaps
-- the real bitmap in. One copy per image (each pending img points at its
-- own ".loading.svg" path). Sand drawn half-drained: a pile left in the
-- top bulb's lower half, the bottom bulb filled to its midline.
local LOADING_ICON = [[<g transform="translate(12 12)">
<path d="M5 2h14M5 22h14M17 2v4.172a2 2 0 0 1-.586 1.414L12 12l-4.414-4.414A2 2 0 0 1 7 6.172V2M7 22v-4.172a2 2 0 0 1 .586-1.414L12 12l4.414 4.414a2 2 0 0 1 .586 1.414V22"/>
<path fill="#888" stroke="none" d="M8 8h8L12 12ZM7.5 17h9l.5 5H7Z"/>
</g>]]

-- Hourglass "loading" icon shown inside an image box until lazyfetch swaps
-- in the real bitmap; one copy per image (each pending img points at its
-- own ".loading.svg" path), shaped to the image's aspect ratio (w/h, nil
-- without source dimensions). Grid/capped footprints reserve only a width,
-- so crengine derives the loading height from the icon's intrinsic ratio:
-- a square canvas would reserve page-breaking squares for wide images.
local function loadingSvg(aspect)
    local h = aspect and aspect > 0 and 48 / aspect or 48
    -- Wide canvases must scale the icon in; tall ones just center it.
    local s = h < 48 and h / 48 or 1
    return string.format(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 %g" width="48" height="%g"'
        .. ' fill="none" stroke="#888" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">'
        .. '<g transform="translate(24 %g) scale(%g) translate(-24 -24)">%s</g></svg>',
        h, h, h / 2, s, LOADING_ICON)
end
-- Exposed for tests.
M.loadingSvg = loadingSvg

-- KOReader paints table headers/captions with absolute greys (th #DDD,
-- caption #EEE, in its embedded Wikipedia stylesheet and base
-- data/epub.css alike). Author-origin rules override those but not
-- Wikipedia's own inline cell colors, so intentional template coloring
-- survives; needs the EPUB's "Embedded Style" to be on (the default).
local THEME_SAFE_TABLE_CSS = [[
th, table caption {
  background-color: rgba(0,0,0,0.04);
}
]]

--[[-------------------------------------------------------------------------
Full article EPUB builder
--]]

-- Fetches an article and converts it to an EPUB via Wikipedia.createEpub(),
-- after cleaning the HTML: clutter tables (navbox/sidebar/rmbox, and infobox
-- unless "Show infoboxes" is on) and the category list are stripped, math
-- formulas become SVGs (block) or text (inline), cladograms become text diagrams,
-- leading hatnotes are boxed. With "Show images" on, each boxed image
-- keeps its box and footprint but its bytes are downloaded after the
-- article opens (lazyfetch.lua); with it off, the boxes are removed
-- entirely. The resolved title and short
-- description are recovered from the API response and written into the EPUB
-- metadata. A kept infobox's media cells are dropped before the media pass,
-- except when "Show images" is on, where their images join the lazy
-- pipeline and locator maps become composited images.
-- fixed_path (save flow): build into the given path; skip the
-- resolved-title rename so a temp rebuild never becomes a cache entry.
function M.buildEpub(epub_path, title, lang, callback, fixed_path)
    local short_description = nil -- extracted from the HTML
    local resolved_title = nil    -- from the API response

    -- Boxed images become placeholder <img>s whose zip entries are
    -- missing at build time; the URL list rides along in the EPUB
    -- (wikireader-pending.json) for lazyfetch to complete after the
    -- article opens.
    local lazy_enabled = G_reader_settings:nilOrTrue("wikireader_show_images")
    local lazy_images = {}
    -- Box-caption texts keyed by original image URL, collected during the
    -- HTML pass and resolved in the marker swaps below (see sentinelLink).
    local image_captions = {}
    -- Read once at build scope: both the HTML-cleaning hook and the Archiver
    -- stylesheet hook below need it, and the Archiver hook must not read a
    -- bare global (that bug silently disabled the kept-infobox CSS).
    local infobox_full_width = G_reader_settings:isTrue("wikireader_show_infoboxes")
    -- Formula SVG URL records collected by latex.replaceMathElements;
    -- markers swap to <img> in the Archiver hooks below and the URLs join
    -- the pending list ahead of the photographs (see lazyfetch.lua).
    local math_images = {}
    -- Locator maps composited by locmap.replaceLocMaps (lazy mode only):
    -- base map PNG with the red marker dots drawn in; stitched in from the
    -- same Archiver hooks as the formula SVGs.
    local locmap_composites = {}

    -- Patch redirects support
    local original_phtml_redirects = Wikipedia.wiki_phtml_params.redirects
    Wikipedia.wiki_phtml_params.redirects = ""
    -- Oct-2026: enwiki defaulted action=parse to Parsoid, whose
    -- data-mw/typeof transclusion metadata crengine renders as raw
    -- wikitext garbage; the cleaning pipeline targets legacy-parser HTML.
    local original_phtml_parser = Wikipedia.wiki_phtml_params.parser
    Wikipedia.wiki_phtml_params.parser = "legacy"

    local original_getFullPageHtml = Wikipedia.getFullPageHtml
    Wikipedia.getFullPageHtml = function(self, wiki_title, wiki_lang)
        local ok, result = pcall(original_getFullPageHtml, self, wiki_title, wiki_lang)
        if not ok or not result then
            return nil
        end
        if result and result.text and result.text["*"] then
            local html = result.text["*"]

            -- Extract short description from the HTML before stripping it.
            local short_desc_pat = '<div[^>]*class="[^"]*shortdescription[^"]*"[^>]*>(.-)</div>'
            local short_desc_match = html:match(short_desc_pat)
            if short_desc_match then
                short_description = short_desc_match:gsub('&[^;]+;', ' '):gsub('%s+', ' '):match('^%s*(.-)%s*$')
                if short_description == '' then
                    short_description = nil
                end
            end

            -- Fallback: query API's pageprops for short description
            if not short_description then
                local JSON = require("json")
                local props_url = string.format(
                    "https://%s.wikipedia.org/w/api.php?action=query&prop=pageprops&titles=%s&format=json",
                    wiki_lang or "en", socket_url.escape(wiki_title)
                )
                local props_ok, props_code, props_sink = wutil.httpGetJSON(props_url)
                if props_ok and props_code == 200 then
                    local props_parse_ok, props_data = pcall(JSON.decode, table.concat(props_sink))
                    if props_parse_ok and props_data and props_data.query and props_data.query.pages then
                        for _, props_page in pairs(props_data.query.pages) do
                            if props_page.pageprops and props_page.pageprops["wikibase-shortdesc"] then
                                short_description = props_page.pageprops["wikibase-shortdesc"]
                                break
                            end
                        end
                    end
                end
            end

            if result.title then
                resolved_title = result.title
            end

            -- Force a kept table to span the whole page width and drop any
            -- inline float or horizontal margin, so body text can never sit
            -- beside it and it can never overflow the page margin in the
            -- single-column reflowable layout. (floatleft/floatright class
            -- removal is handled separately by cleanElementClasses.)
            --
            -- NOTE: cleanElementClasses splices this return value into the
            -- tag via a gsub replacement where % is special, so any literal
            -- percent must survive as %% (decoded back to % by that final
            -- splice). The width/float/margin declarations are therefore
            -- removed by *deleting* with a gsub (replacement "") and the
            -- "width:100%%" suffix is appended plain -- never pushed
            -- through a gsub replacement -- to avoid double-decoding it to
            -- "width:100".
            local function forceFullWidthStyle(style)
                style = style:gsub('width%s*:%s*[^;]+', '') -- existing fixed width
                style = style:gsub('float%s*:%s*[^;]+', '') -- inline float
                -- Horizontal margins sit on top of the width:100% box in
                -- crengine, pushing the table past the right page margin.
                -- The shorthand must go too, for its horizontal components.
                style = style:gsub('margin%s*:%s*[^;]+', '')
                style = style:gsub('margin%-left%s*:%s*[^;]+', '')
                style = style:gsub('margin%-right%s*:%s*[^;]+', '')
                style = style:gsub(';%s*;+', ';'):gsub('^%s*;?%s*', ''):gsub(';%s*$', '')
                -- Any % left in the kept declarations must also be escaped
                -- for the final splice (e.g. font-size: 80%): each % becomes
                -- %% here, which the splice decodes back to a single %.
                style = style:gsub('%%', '%%%%')
                if style == "" then
                    return "width:100%%"
                end
                return style .. ';width:100%%'
            end


            -- Star icons must become text before any media pass can blank them.
            html = htmlclean.ratingStarsToText(html)
            -- Legend color chips are TemplateStyles-sized; size them inline
            -- instead (see styleLegendChips).
            html = htmlclean.styleLegendChips(html)

            html = htmlclean.stripTextIndent(html)
            -- Strip clutter tables: chronology/nav/sidebar/route-map boxes
            -- are always dropped; infoboxes only while "Show infoboxes" is
            -- off (the default).
            local stripped_tables = { "navbox", "sidebar", "vertical-navbox", "rmbox" }
            if not infobox_full_width then
                table.insert(stripped_tables, "infobox")
            end
            html = htmlclean.stripElementsByClass(html, "table", stripped_tables)

            -- The "Temporal range" bar biology infoboxes render via
            -- {{Geological range}} is absolute-positioned CSS art (a
            -- 250px-wide row of colored era boxes) that wrecks the
            -- reflowable layout; the useful text summary it decorates sits
            -- just before it. Matched by id (MediaWiki emits
            -- id="Timeline-row").
            html = htmlclean.stripElementsByAttr(html, "div", "id", { "timeline-row" })
            -- Position:absolute label overlays ({{Image label}} map tags)
            -- stack into a text column in crengine; drop them in every
            -- mode, before any image pass can turn their content into
            -- placeholders. Must run before locmap.replaceLocMaps.
            html = htmlclean.stripPositionedOverlays(html)
            -- Column layouts (chart sections of music articles etc.) are
            -- scaffolding tables crengine renders as real columns,
            -- squishing the content tables into half-page cells; dissolve
            -- them first so their content stacks full width.
            html = htmlclean.unwrapColumnLayouts(html)

            html = htmlclean.cleanElementClasses(html, "table", { "wikitable" }, { "floatleft", "floatright" },
                forceFullWidthStyle)
            -- {{Bar box}} charts render as a <div class="barbox" style=
            -- "display:table; width:auto"> wrapping the real <table>, so
            -- they miss the full-width forcing above and render
            -- shrink-to-fit at the left margin. Same treatment, classes and
            -- style: the div becomes a full-width block like every table.
            html = htmlclean.cleanElementClasses(html, "div", { "barbox" }, { "floatleft", "floatright" },
                forceFullWidthStyle)
            if infobox_full_width then
                -- Force the kept infobox full width like every other table:
                -- infoboxes render as narrow floated boxes on the site, and
                -- text squeezed beside one leaves both columns too narrow
                -- on an e-ink page.
                html = htmlclean.cleanElementClasses(html, "table", { "infobox" }, { "floatleft", "floatright" },
                    forceFullWidthStyle)
                -- Nested sub-boxes span the infobox only via their own
                -- TemplateStyles (see forceNestedTableWidth).
                html = htmlclean.forceNestedTableWidth(html, { "infobox" }, forceFullWidthStyle)
                -- {{Infobox element}}'s periodic-table diagram is
                -- TemplateStyles/CSS art crengine can't render; drop it
                -- (with its header row) before the other infobox passes.
                html = htmlclean.stripElementPeriodicTable(html)
                -- Kept infobox: in lazy mode keep the media cells (their
                -- images become placeholders or map composites) and only
                -- drop non-image media; otherwise drop media cells, keep
                -- text data and inline names. Must run before the media passes.
                html = htmlclean.stripImageCells(html, nil,
                    { keep_images = lazy_enabled })
                -- Center full-width infobox rows inline (the base stylesheet
                -- has no .infobox rules and crengine ignores descendant
                -- selectors), mirroring Wikipedia's own alignment.
                html = htmlclean.centerInfoboxCells(html)
                -- {{Infobox settlement}} blocks its footnote markers below
                -- the label (see unwrapSettlementFnDivs).
                html = htmlclean.unwrapSettlementFnDivs(html)
            end
            html = htmlclean.forceFullWidthStyledTables(html, forceFullWidthStyle)
            -- Border infoboxes and wikitables as grids, inline (see
            -- borderTableCells: crengine ignores descendant selectors, so
            -- stylesheet rules can't reach the cells).
            html = htmlclean.borderTableCells(html)
            -- Tap-to-rotate hints (sentinel URLs handled in main.lua):
            -- crengine can only squish wide tables into the portrait width.
            html = htmlclean.addRotateHints(html)
            if lazy_enabled then
                -- Keep media boxes intact: their images become lazy
                -- placeholders.
                html = htmlclean.stripElementsByClass(html, "div",
                    { "catlinks", "navbox", "vertical-navbox", "side-box", "spoken-wikipedia", "shortdescription" })
            else
                -- Drop media boxes (and their captions) entirely.
                html = htmlclean.stripElementsByClass(html, "div",
                    { "thumb", "catlinks", "navbox", "vertical-navbox", "side-box", "spoken-wikipedia",
                        "shortdescription" })
                html = htmlclean.stripElementsByClass(html, "ul", { "gallery" })
            end
            html = htmlclean.cleanElementClasses(html, "div", { "quotebox", "pullquote", "rquote" },
                { "floatleft", "floatright" }, true)
            html = htmlclean.stripElementsByClass(html, "span", { "geo-inline-hidden" })
            html = htmlclean.mergeQuoteCites(html)
            -- "Disable hyperlinks": unwrap internal article links, keep
            -- reference/external ones. Runs before the image pass. Editor-junk
            -- links ([citation needed] markers, section "[edit]" links)
            -- are unwrapped unconditionally: their targets are editor pages
            -- no reader wants to open.
            html = htmlclean.stripMaintenanceLinks(html)
            html = htmlclean.stripEditSectionLinks(html)
            if G_reader_settings:isTrue("wikireader_disable_hyperlinks") then
                html = htmlclean.stripArticleLinks(html)
            end
            -- Media figures: in lazy mode boxed <img>s become placeholders;
            -- otherwise the media boxes are dropped entirely.
            if not lazy_enabled then
                html = htmlclean.stripElementsByAttr(html, "figure", "typeof",
                    { "mw:file", "mw:image", "mw:video", "mw:audio" })
                html = html:gsub("<audio.-</audio%s*>", "")
                -- Location maps are absolute-positioned overlays crengine
                -- can't draw; with no image pass to transform them, drop
                -- them whole (composites only exist in lazy mode).
                html = htmlclean.stripElementsByClass(html, "div", { "locmap" })
            end
            html = latex.replaceMathElements(html, math_images)
            -- Render cladograms (Template:Clade phylogeny trees) as text
            -- diagrams, since crengine cannot draw their CSS border lines.
            html = cladogram.replaceCladograms(html)
            -- EasyTimeline renders ({{#tag:timeline}}) are bare timeline-wrapper
            -- divs the walker sees no image box in; route them through the
            -- same placeholder machinery first.
            html = qrimage.replaceTimelineWrappers(html, lazy_images, {})
            -- Locator maps (Template:Location map) become ONE composited
            -- image (base map + drawn marker dots) in lazy mode, fetched at
            -- build time like the formula SVGs. Must run before the walker
            -- below, which has no locmap handling in this mode.
            if lazy_enabled then
                html = locmap.replaceLocMaps(html, locmap_composites,
                    { lazy_images = lazy_images })
            end
            if lazy_enabled then
                -- Collect box captions while the boxes still hold their
                -- original <img> tags (the walker replaces them next).
                qrimage.collectImageCaptions(html, image_captions)
                html = qrimage.replaceImagesWithLazy(html, lazy_images,
                    { treat_infobox_as_imagebox = infobox_full_width })
                -- Figures' mw-halign-* classes select base-stylesheet rules
                -- (floats, wide margins) that outrank the injected
                -- attribute-only selectors; drop them so the full-width
                -- figure rules below always win (see htmlclean.lua).
                html = htmlclean.stripFigureHalign(html)
                -- {{Multiple image}} uses flexbox, unsupported by crengine:
                -- body boxes rewrite into one tiny <table> per image (so
                -- nothing jumps pages as one block); boxes inside a kept
                -- infobox go back into the infobox's own grid rows, whose
                -- images the grid pass re-footprints (lazy_images threaded
                -- through; see fillItemMedia in htmlclean.lua).
                html = htmlclean.restructureMultiImages(html, lazy_images)
                -- {{Infobox settlement/columns}} uses CSS display:table
                -- (see settlementColsToTable in htmlclean.lua).
                html = htmlclean.settlementColsToTable(html)
                -- Gallery thumbs' inline width would pin the image to the
                -- left edge of the full-width box (see htmlclean.lua).
                html = htmlclean.centerGalleryThumbs(html)
            end

            -- Extract hatnotes and wrap section notices
            local notices, rest = htmlclean.extractLeadingNotices(html)
            rest = htmlclean.wrapSectionNotices(rest)
            if notices ~= "" then
                html = string.format(
                    [[<div class="wikireader-notices">%s</div><hr class="koreaderwikifrontpage"/>%s]],
                    notices, rest
                )
            else
                html = [[<hr class="koreaderwikifrontpage"/>]] .. rest
            end

            result.text["*"] = html
        end
        return result
    end

    -- Patch the Archiver to fix front matter, add the short description,
    -- and inject stylesheet rules.
    local original_addFileFromMemory = Archiver.Writer.addFileFromMemory
    Archiver.Writer.addFileFromMemory = function(self, entry_path, content, mtime)
        if entry_path == "OEBPS/content.html" then
            content = htmlclean.stripElementsByClass(content, "p", { "koreaderwikifrontpage" })
            content = htmlclean.stripElementsByClass(content, "h5", { "koreaderwikifrontpage" })
            content = content:gsub('<hr class="koreaderwikifrontpage"%s*/?>', "", 1)
            if short_description and short_description ~= "" then
                content = content:gsub(
                    '(<h1[^>]*>.-</h1>)',
                    '%1\n<div style="font-style:italic; color:rgba(0,0,0,0.6); margin-top:0.2em; margin-bottom:1em; text-align:center;">' ..
                    short_description .. '</div>'
                )
            end
            if resolved_title then
                content = content:gsub('(<title>).-(</title>)', '%1' .. resolved_title .. '%2')
            end
            -- Swap each lazy placeholder for a pending <img> pointing at a
            -- per-image copy of the loading icon, keeping the real footprint
            -- reserved so the box never changes size; the sentinel anchor
            -- (sentinelHref) keeps the placeholder inert on tap, and the
            -- unique loading path is what lazyfetch's src rewrite keys on.
            if next(lazy_images) then
                local loading_written = {}
                content = content:gsub('<span class="wikireader%-lazyimg" data%-lazyindex="(%d+)"[^>]*></span>',
                    function(idx)
                        local img = lazy_images[tonumber(idx)]
                        if not img then
                            return ""
                        end
                        local loading_src = img.imgpath .. ".loading.svg"
                        if not loading_written[loading_src] then
                            loading_written[loading_src] = true
                            original_addFileFromMemory(self, "OEBPS/" .. loading_src,
                                loadingSvg(img.aspect), mtime)
                        end
                        local img_tag = string.format('<img src="%s" style="%s" alt=""/>',
                            loading_src, img.style or "")
                        local caption = image_captions[img.fallback or img.src]
                        return sentinelLink(img_tag, sentinelHref(caption, tonumber(idx)), img.style)
                    end)
            end
            -- Locator map composites (locmap.lua): swap each marker span
            -- for a real <img> carrying the 1x footprint (the PNG may be a
            -- hi-res variant), and register the PNG files.
            if next(locmap_composites) then
                content = content:gsub(
                    '<span class="wikireader%-locmap" data%-locindex="(%d+)" style="([^"]*)"></span>',
                    function(idx, style)
                        local composite = locmap_composites[tonumber(idx)]
                        if not composite then
                            return ""
                        end
                        return string.format(
                            '<img src="%s" style="display:block; margin:0.6em auto; %s" class="wikireader-locmap" alt=""/>',
                            composite.path, style)
                    end)
                for _, composite in ipairs(locmap_composites) do
                    original_addFileFromMemory(self,
                        "OEBPS/" .. composite.path, composite.png, mtime)
                end
            end
            -- Swap each formula marker for a real <img>. The SVG zip
            -- entries are NOT written here: the files don't exist yet,
            -- lazyfetch.lua downloads them after the article opens and
            -- fills them in.
            if next(math_images) then
                content = content:gsub('<span class="wikireader%-mathimg" data%-mathimgindex="(%d+)"[^>]*></span>',
                    function(idx)
                        local mathimg = math_images[tonumber(idx)]
                        if not mathimg then
                            return ""
                        end
                        -- Own classes: the .wikireader-mathimg box rule
                        -- (background/border/padding, page-break-avoid) must
                        -- not wrap running-text formulas.
                        local cls = mathimg.inline and "wikireader-mathimg-inline" or "wikireader-mathimg"
                        return string.format(
                            '<img src="%s" style="%s" class="%s" alt=""/>',
                            mathimg.imgpath, mathimg.style, cls)
                    end)
            end
        elseif entry_path == "OEBPS/content.opf" then
            if resolved_title then
                content = content:gsub('(<dc:title>).-(</dc:title>)', '%1' .. resolved_title .. '%2')
                content = content:gsub('<dc:creator>.-</dc:creator>', '<dc:creator>Wikipedians</dc:creator>')
            end
            if next(locmap_composites) then
                for idx in ipairs(locmap_composites) do
                    content = content:gsub("</manifest>", string.format(
                        '<item id="locmap%05d" href="images/locmap%05d.png" media-type="image/png"/>\n  </manifest>',
                        idx, idx))
                end
            end
            -- Formula SVGs are lazy like the photographs, and their
            -- manifest items must be inserted BEFORE the wrimg ones so
            -- lazyfetch's download slots fill with formulas first.
            local math_manifest, math_pending = {}, nil
            if next(math_images) then
                math_pending = {}
                for idx, mathimg in ipairs(math_images) do
                    table.insert(math_manifest, string.format(
                        '<item id="wrmath%05d" href="%s" media-type="image/svg+xml"/>',
                        idx, mathimg.imgpath))
                    math_pending[idx] = {
                        src = mathimg.src,
                        imgpath = mathimg.imgpath,
                        mimetype = mathimg.mimetype,
                        section = mathimg.section or 0,
                        math = true,
                    }
                end
            end
            if math_pending then
                for _, item in ipairs(math_manifest) do
                    content = content:gsub("</manifest>", item .. "\n  </manifest>", 1)
                end
            end
            local JSON = require("json")
            if next(lazy_images) then
                for idx, img in ipairs(lazy_images) do
                    content = content:gsub("</manifest>", string.format(
                        '<item id="wrimg%05d" href="%s" media-type="%s"/>\n  </manifest>',
                        idx, img.imgpath, img.mimetype))
                    content = content:gsub("</manifest>", string.format(
                        '<item id="wrload%05d" href="%s.loading.svg" media-type="image/svg+xml"/>\n  </manifest>',
                        idx, img.imgpath))
                end
                -- The download URL list rides inside the EPUB, so an open
                -- interrupted before the images arrive can still be
                -- completed later (lazyfetch drops the entry once nothing
                -- remains).
                local pending = {}
                for _, rec in ipairs(math_pending or {}) do
                    pending[#pending + 1] = rec
                end
                for _, img in ipairs(lazy_images) do
                    local record =
                    { src = img.src, imgpath = img.imgpath, mimetype = img.mimetype, section = img.section or 0 }
                    if img.fallback then
                        record.fallback = img.fallback
                    end
                    if img.infobox then
                        record.infobox = true
                    end
                    pending[#pending + 1] = record
                end
                original_addFileFromMemory(self, "OEBPS/wikireader-pending.json", JSON.encode(pending), mtime)
            elseif math_pending then
                -- Formulas-only article (no photographs): the pending
                -- entry still rides along so lazyfetch completes it.
                original_addFileFromMemory(self, "OEBPS/wikireader-pending.json", JSON.encode(math_pending), mtime)
            end
        elseif entry_path == "OEBPS/toc.ncx" then
            if resolved_title then
                content = content:gsub('(<docTitle>%s*<text>).-(</text>%s*</docTitle>)', '%1' .. resolved_title .. '%2')
                content = content:gsub(
                    '(<navPoint[^>]*>%s*<navLabel>%s*<text>).-(</text>%s*</navLabel>%s*<content src="content%.html"/>)',
                    '%1Introduction%2')
            end
        elseif entry_path == "OEBPS/stylesheet.css" then
            -- Lazy-image boxes (see qrimage.lua): KOReader's base stylesheet
            -- zeroes the top padding of figure/gallery boxes when NO images
            -- are included (real thumbnails would get padding-top: 0.5em).
            -- A loading placeholder is a flat rectangle with no strut, so
            -- without this it would sit flush against the top border. The
            -- base stylesheet also boxes thumbnails with "border: dotted
            -- 1px black"; restyle them to a dashed border to match the
            -- notices.
            if lazy_enabled then
                content = content .. [[

figure[typeof~='mw:File/Thumb'],
figure[typeof~='mw:File/Frame'] {
    padding-top: 0.5em;
}
li.gallerybox {
    padding-top: 0.5em !important;
}

/* {{Multiple image}} boxes, rewritten into a native <table> by
   htmlclean.restructureMultiImages (crengine cannot do the template's
   flexbox layout). Mirror the figure-box styling of the base stylesheet
   (no page split, and -- unlike the floated article layout -- full width),
   with the same dashed border as the other image boxes. The template's inline width
   (e.g. 492px) is overridden below so very wide boxes never overflow the
   page; the rewrite footprints each image to fill its proportional
   inline-block cell (htmlclean.multiImageTransformRow), and margin auto
   centers the table itself (same pattern as html5.css's
   table[align=center] presentational hint). */
table.wikireader-tmulti {
    border: 1px dashed rgba(0,0,0,0.33);
    margin-left: auto !important;
    margin-right: auto !important;
    margin-top: 0.5em !important;
    margin-bottom: 0.5em !important;
    padding: 0 0.5em 0 0.5em;
    text-align: center;
    page-break-inside: avoid;
}
/* Belt-and-braces per-cell centering, not relying on inheritance from
   the table rule. */
table.wikireader-tmulti > tbody > tr > td,
table.wikireader-tmulti > tr > td {
    text-align: center;
}

/* Image boxes span the full text width instead of keeping the article's
   own float, width and alignment (base stylesheet's float: right,
   33%/25% shares, Parsoid's inline style="width: NNNpx"). Selectors
   mirror the base stylesheet's (including its :dir(rtl) variant) so
   these later !important rules win the cascade; the base rules for
   .mw-halign-* figures never come into play because htmlclean strips
   those classes. */
figure[typeof~='mw:File/Thumb'],
figure[typeof~='mw:File/Frame'] {
    border: 1px dashed rgba(0,0,0,0.33);
    width: 100% !important;
    max-width: 100% !important;
    margin: 0.5em 0 0.5em 0 !important;
}
body > div > figure[typeof~='mw:File/Thumb'],
body > div > figure[typeof~='mw:File/Frame'],
body > div:dir(rtl) > figure[typeof~='mw:File/Thumb'],
body > div:dir(rtl) > figure[typeof~='mw:File/Frame'] {
    float: none !important;
    clear: none !important;
    margin: 0.5em 0 0.5em 0 !important;
}
li.gallerybox {
    border: 1px dashed rgba(0,0,0,0.33);
    width: 100% !important;
    margin: 0.5em 0 0.5em 0 !important;
    /* The base stylesheet's gallery centering lives only in child-
       selectors (body > div > ul.gallery > *) that the article's own
       wrapper div can defeat via the stronger body { text-align: justify }
       (inheritance loses to any matching rule). Centering on the box
       itself covers captions and any gallery nesting shape. The
       rewritten tmulti table also carries .thumbcaption, whose alignment
       the rewrite is expected to provide (the class is kept so the
       template's TemplateStyles cannot reach it). */
    text-align: center;
}
div.gallerytext,
div.thumbcaption {
    text-align: center;
}
/* The thumbinner's inline "width:NNNpx;max-width:NNNpx" lands on the
   rewritten table; max-width is what actually shrinks the box (width
   alone loses to nothing but the cap still applies), so it must be
   overridden too. */
table.wikireader-tmulti {
    width: 100% !important;
    max-width: 100% !important;
    margin-top: 0.5em !important;
    margin-bottom: 0.5em !important;
    margin-left: auto !important;
    margin-right: auto !important;
}
]]
            end
            if infobox_full_width then
                -- Kept full-width infoboxes: mirror Wikipedia's own alignment
                -- (the site centers everything but label/data pairs). The
                -- width itself is forced inline on the table above, which
                -- works even with "Embedded Style" off; crengine has no
                -- descendant selectors, so these rules are belt-and-braces.
                content = content .. [[

.infobox .infobox-title,
.infobox .infobox-above,
.infobox .infobox-header,
.infobox .infobox-subheader,
.infobox .infobox-image,
.infobox .infobox-full-data,
.infobox .infobox-below {
  text-align: center;
}
]]
            end
            content = content .. [[

/* Borders, box shading and muted text use translucent black rather than
   opaque greys: crengine composites rgba() over whatever page background
   the user picked, so the tint blends into the theme (on white these
   render as the old #aaa/#ccc/#888/#666/#f4f4f4 greys). */

/* Editor furniture stays visible but recedes next to body prose:
   reference marks ([12], [b]) and inline maintenance markers
   ([citation needed]) are annotations, not article content. */
sup.reference,
sup.noprint,
span.mw-editsection {
  color: rgba(0,0,0,0.47);
}

.wikireader-notices {
  border: 1px solid rgba(0,0,0,0.33);
  padding: 0.6em 0.8em;
  margin: 0 0 1em 0;
  font-style: italic;
  font-size: 75%;
}

blockquote {
  background: rgba(0,0,0,0.04);
  border-left: 3px solid rgba(0,0,0,0.2);
  padding: 0.5em 0.8em;
  margin: 0.5em 0;
  font-style: italic;
}

/* Matches the blockquote box styling for article pseudocode blocks
   (e.g. Binary search). Inline <code> is deliberately not styled:
   crengine forces display:inline and doesn't paint inline backgrounds. */
pre {
  background: rgba(0,0,0,0.04);
  border: 1px solid rgba(0,0,0,0.2);
  padding: 0.5em 0.8em;
  page-break-inside: avoid;
}

/* Inline code snippets in prose get the same shading as block code; a
   full border/padding box reads as clutter at inline size. */
code {
  background: rgba(0,0,0,0.04);
}

/* Droid Sans Mono's glyphs run taller than the default serif at the
   same nominal size; drop both block and inline code to compensate. */
pre, code {
  font-size: 80%;
}

/* Attribution line of Template:Quote, merged inside blockquote by
   htmlclean.mergeQuoteCites(). Right-aligned, normal weight and slightly
   smaller so it reads as a distinct " — who said it" trailing note. */
.wikireader-cite {
  text-align: right;
  font-style: normal;
  font-size: 85%;
  margin-top: 0.4em;
}

/* Fallback in case any templatequotecite div was not merged into a
   blockquote, so it never renders as a bare dangling line. */
.templatequotecite {
  text-align: right;
  font-style: italic;
  font-size: 85%;
  margin: 0.2em 0 0.8em 0;
}

/* Display formulas (SVG images on their own line) get the same shaded box
   as code blocks and cladograms, so every non-prose element reads as a
   distinct "display" unit. Inline formula imgs carry a different class
   (wikireader-mathimg-inline) so the box never wraps running text. */
.wikireader-mathimg {
  background: rgba(0,0,0,0.04);
  border: 1px solid rgba(0,0,0,0.2);
  padding: 0.5em 0.8em;
  page-break-inside: avoid;
}

/* Cladogram (phylogeny tree) diagrams, converted to ASCII tree text by
   cladogram.lua. The base stylesheet already keeps <pre> left-aligned;
   shrink the monospace a touch and keep lines from stretching across the
   full page so the tree reads as one compact diagram; keep the whole
   diagram on one page, since a tree split across a page turn loses its
   root context. */
pre.wikireader-cladogram {
  font-size: 80%;
  line-height: 1.25;
  border: 1px solid rgba(0,0,0,0.47);
  padding: 0.6em 0.8em;
  margin: 0 0 1em 0;
  page-break-inside: avoid;
}

/* |title= row of a {{cladogram}} box, re-emitted above the diagram by
   cladogram.lua. */
.wikireader-cladogram-title {
  font-weight: bold;
  text-align: center;
  font-size: 85%;
  margin: 0 0 0.3em 0;
}

/* |caption= row of a {{cladogram}} box, re-emitted under the diagram by
   cladogram.lua. */
.wikireader-cladogram-caption {
  font-size: 85%;
  margin: 0 0 1em 0;
}
]]
            content = content .. THEME_SAFE_TABLE_CSS
        end
        return original_addFileFromMemory(self, entry_path, content, mtime)
    end

    Trapper:wrap(function()
        local ok, success = pcall(Wikipedia.createEpub, Wikipedia, epub_path, title, lang, false)
        -- Always restore all patches
        Wikipedia.wiki_phtml_params.redirects = original_phtml_redirects
        Wikipedia.wiki_phtml_params.parser = original_phtml_parser
        Wikipedia.getFullPageHtml = original_getFullPageHtml
        Archiver.Writer.addFileFromMemory = original_addFileFromMemory
        if ok and success then
            local used_path = epub_path
            if not fixed_path and resolved_title and resolved_title ~= title then
                local new_path = cache.getCachePath(resolved_title, lang)
                if new_path ~= epub_path then
                    os.rename(epub_path, new_path)
                    DocSettings.updateLocation(epub_path, new_path)
                    used_path = new_path
                end
            end
            callback(true, used_path, resolved_title)
        else
            Trapper:reset()
            callback(false)
        end
    end)
end

--[[-------------------------------------------------------------------------
Single-page EPUB writer (shared by the standalone builders)
--]]

-- Writes one XHTML page plus stylesheet and package/NCX metadata for the
-- standalone helper pages (search results, category lists, main page),
-- which don't go through Wikipedia.createEpub(). Returns true on success.
-- chapters (optional): { label=..., anchor=... } in display order; anchor
-- must be an element id already present in html_content. Adds TOC entries.
-- extras (optional, main page only): image data collected by
-- mainpage.fetchSections and stitched by buildMainPageEpub:
--   files          { path = "OEBPS/...", content = bytes }
--   manifest_items { "<item .../>" } appended to the package manifest
local function writeSinglePageEpub(epub_path, title, lang, bookid_prefix, html_content, css, chapters, toc_label, extras)
    local mtime = os.time()

    local epub = Archiver.Writer:new {}
    local epub_path_tmp = epub_path .. ".tmp"
    if not epub:open(epub_path_tmp, "epub") then
        return false
    end

    epub:setZipCompression("store")
    epub:addFileFromMemory("mimetype", "application/epub+zip", mtime)
    epub:setZipCompression("deflate")

    epub:addFileFromMemory("META-INF/container.xml", [[
<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>]], mtime)

    local safe_title = title:gsub("[^%w]", "_")
    local bookid = string.format("%s_%s_%s_%d", bookid_prefix, lang, safe_title, mtime)
    local opf = string.format([[<?xml version='1.0' encoding='utf-8'?>
<package xmlns="http://www.idpf.org/2007/opf"
        xmlns:dc="http://purl.org/dc/elements/1.1/"
        unique-identifier="bookid" version="2.0">
  <metadata>
    <dc:title>%s</dc:title>
    <dc:identifier id="bookid">%s</dc:identifier>
    <dc:language>%s</dc:language>
    <dc:creator>Wikipedians</dc:creator>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="content" href="content.html" media-type="application/xhtml+xml"/>
    <item id="css" href="stylesheet.css" media-type="text/css"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="content"/>
  </spine>
</package>
]], title, bookid, lang)
    if extras then
        -- Function replacement: % chars in the generated markup must
        -- survive the gsub splice.
        for _, item in ipairs(extras.manifest_items or {}) do
            opf = opf:gsub("</manifest>", function() return item .. "\n  </manifest>" end)
        end
    end
    epub:addFileFromMemory("OEBPS/content.opf", opf, mtime)
    epub:addFileFromMemory("OEBPS/content.html", html_content, mtime)
    epub:addFileFromMemory("OEBPS/stylesheet.css", css .. THEME_SAFE_TABLE_CSS, mtime)
    if extras then
        for _, file in ipairs(extras.files or {}) do
            epub:addFileFromMemory(file.path, file.content, mtime)
        end
    end

    local escape = function(s)
        return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
    end
    local nav_points
    if chapters and #chapters > 0 then
        -- Same one-line navPoint markup as Wikipedia.createEpub's NCX entries
        nav_points = ""
        for i, chapter in ipairs(chapters) do
            local num = i
            nav_points = nav_points ..
                string.format(
                    [[<navPoint id="navpoint-%s" playOrder="%s"><navLabel><text>%s</text></navLabel><content src="content.html#%s"/></navPoint>]],
                    num, num, escape(chapter.label), chapter.anchor)
        end
    else
        nav_points = string.format([[<navPoint id="navpoint-1" playOrder="1">
      <navLabel>
        <text>%s</text>
      </navLabel>
      <content src="content.html"/>
    </navPoint>]], escape(toc_label or title))
    end
    local ncx = string.format([[
<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head>
    <meta name="dtb:uid" content="%s"/>
    <meta name="dtb:depth" content="1"/>
    <meta name="dtb:totalPageCount" content="0"/>
    <meta name="dtb:maxPageNumber" content="0"/>
  </head>
  <docTitle>
    <text>%s</text>
  </docTitle>
  <navMap>
    %s
  </navMap>
</ncx>
]], bookid, escape(title), nav_points)
    epub:addFileFromMemory("OEBPS/toc.ncx", ncx, mtime)
    epub:close()

    os.rename(epub_path_tmp, epub_path)
    return true
end

-- Shared document prologue for the search/category/main-page builders.
local function beginDoc(parts, title)
    table.insert(parts, '<?xml version="1.0" encoding="utf-8"?>\n')
    table.insert(parts, '<!DOCTYPE html>\n')
    table.insert(parts, '<html xmlns="http://www.w3.org/1999/xhtml">\n')
    table.insert(parts, '<head>\n')
    table.insert(parts, '<meta charset="utf-8"/>\n')
    table.insert(parts, '<link rel="stylesheet" type="text/css" href="stylesheet.css"/>\n')
    table.insert(parts, '<title>')
    table.insert(parts, title)
    table.insert(parts, '</title>\n')
    table.insert(parts, '</head>\n')
    table.insert(parts, '<body>\n')
end

local function endDoc(parts)
    table.insert(parts, '</body>\n')
    table.insert(parts, '</html>\n')
    return table.concat(parts)
end

-- Shared rules for the search-results and main-page pages; each builder
-- appends its own extra rules below. The a rule matches article EPUBs'
-- link style; otherwise crengine's default blue shows.
local FRONTPAGE_CSS = [[
body {
  text-align: justify;
}
h1.koreaderwikifrontpage {
  text-align: center;
  margin-top: 0;
}
p.koreaderwikifrontpage {
  font-style: italic;
  text-align: center;
  margin-bottom: 1em;
  text-indent: 0;
}
hr.koreaderwikifrontpage {
  margin-left: 20%;
  margin-right: 20%;
  margin-bottom: 1.2em;
}
a {
  text-decoration: underline;
  color: inherit;
}
]]

--[[-------------------------------------------------------------------------
Search results EPUB builder
--]]

-- Build a minimal EPUB from a list of Wikipedia search results. Each
-- result is a clickable link the plugin's link handler can intercept.
-- If custom_title is provided, it's used as the page heading instead of
-- "Search results for...".
function M.buildSearchEpub(epub_path, query, lang, results, callback, custom_title)
    local display_title = custom_title or query
    local is_search = not custom_title

    local html_parts = {}
    beginDoc(html_parts, is_search and string.format('Search results for "%s"', query) or display_title)
    if is_search then
        table.insert(html_parts, '<h1 class="koreaderwikifrontpage">Search results</h1>\n')
        table.insert(html_parts, '<p class="koreaderwikifrontpage">')
        table.insert(html_parts, string.format('for "%s"', query))
        table.insert(html_parts, '</p>\n')
        table.insert(html_parts, '<hr class="koreaderwikifrontpage"/>\n')
    else
        table.insert(html_parts, '<h1 class="koreaderwikifrontpage">')
        table.insert(html_parts, display_title)
        table.insert(html_parts, '</h1>\n')
        table.insert(html_parts, '<hr class="koreaderwikifrontpage"/>\n')
    end

    for _, result in ipairs(results) do
        local result_title = result.title
        local snippet = (result.snippet or ""):gsub("<[^>]*>", "")
        snippet = util.htmlEntitiesToUtf8(snippet)
        if snippet ~= "" and not snippet:match("[.!?…]$") then
            snippet = snippet .. "…"
        end
        result_title = result_title:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
        snippet = snippet:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
        local link = string.format('https://%s.wikipedia.org/wiki/%s', lang, socket_url.escape(result.title))

        if snippet == "" then
            table.insert(html_parts, string.format(
                '<p class="article-link"><a href="%s">· %s</a></p>\n',
                link, result_title))
        else
            table.insert(html_parts, string.format(
                '<p class="article-link"><a href="%s">· %s</a></p>\n<p class="snippet">%s</p>\n',
                link, result_title, snippet))
        end
    end

    local html_content = endDoc(html_parts)

    local css = FRONTPAGE_CSS .. [[
.search-result {
  margin-bottom: 1em;
}
p.article-link {
  margin: 0.4em 0;
}
p.snippet {
  margin: 0 0 0.8em 0;
  font-size: 80%;
}
]]

    -- Leaf-category pages come through here with custom_title; they list
    -- only articles, so "Search results" would be wrong for them.
    local toc_label = is_search and _("Search results") or _("Articles")
    if not writeSinglePageEpub(epub_path, display_title, lang, "search", html_content, css, nil, toc_label) then
        callback(false)
        return
    end
    callback(true, epub_path)
end

--[[-------------------------------------------------------------------------
Category EPUB builder
--]]

-- Build an EPUB for a level of the category tree (subcategories plus any
-- leaf articles), then open it. Subcategories use a special URL format
-- that the link handler intercepts; articles use standard Wikipedia URLs.
function M.buildCategoryEpub(nodes, title, lang, direct_articles)
    local html_parts = {}
    beginDoc(html_parts, title)
    table.insert(html_parts, '<h1>')
    table.insert(html_parts, title)
    table.insert(html_parts, '</h1>\n')
    table.insert(html_parts, '<hr/>\n')

    for _, node in ipairs(nodes) do
        local escaped_title = node.title:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
        local link = string.format('https://%s.wikipedia.org/wiki/Wikipedia:Featured_articles#section_%s',
            lang, node.section_index)
        table.insert(html_parts, string.format(
            '<p class="category-link"><a href="%s">▸ %s</a></p>\n',
            link, escaped_title))
    end

    if direct_articles and #direct_articles > 0 then
        if #nodes > 0 then
            table.insert(html_parts, '<hr/>\n')
        end
        for _, article in ipairs(direct_articles) do
            local escaped_title = article.title:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
            local link = string.format('https://%s.wikipedia.org/wiki/%s', lang, socket_url.escape(article.title))
            table.insert(html_parts, string.format(
                '<p class="article-link"><a href="%s">· %s</a></p>\n',
                link, escaped_title))
        end
    end

    local html_content = endDoc(html_parts)

    local css = [[
body {
  text-align: justify;
}
h1 {
  text-align: center;
  margin-top: 0;
}
h2 {
  font-size: 120%;
  margin-top: 1em;
}
hr {
  margin-left: 20%;
  margin-right: 20%;
  margin-bottom: 1em;
}
p.category-link {
  margin: 0.5em 0;
}
p.article-link {
  margin: 0.3em 0;
}
a {
  text-decoration: underline;
  color: inherit;
}
]]

    local epub_path = cache.getCachePath("__category__" .. title, lang)
    local toc_label = direct_articles and _("Categories & Articles") or _("Categories")
    if not writeSinglePageEpub(epub_path, title, lang, "category", html_content, css, nil, toc_label) then
        return false
    end
    return true, epub_path
end

--[[-------------------------------------------------------------------------
Main page EPUB builder
--]]

-- Builds the "Wikipedia main page" EPUB from mainpage.fetchSections()
-- output. The date is part of the cache key and title: each day is its
-- own cache entry, so a cached copy never outlives the day's news.
-- lazy_images comes from the fetchSections call that produced `sections`
-- (nil when "Show images" is off): loading placeholders plus a
-- wikireader-pending.json entry that lazyfetch.lua completes in the
-- background (same mechanics as the article EPUBs).
function M.buildMainPageEpub(date_str, lang, sections, lazy_images)
    local year, month, day = date_str:match("^(%d+)%-(%d+)%-(%d+)$")
    local display_date = date_str
    if year then
        -- hour=12 keeps the DST-sensitive %B conversion away from
        -- midnight edges; the C locale gives English month names.
        local t = os.time { year = year, month = month, day = day, hour = 12 }
        display_date = string.format("%s %d, %d", os.date("%B", t), day, year)
    end

    local page_title = _("Wikipedia main page")
    local display_title = page_title .. " (" .. display_date .. ")"

    local html_parts = {}
    beginDoc(html_parts, display_title)
    table.insert(html_parts, '<h1 class="koreaderwikifrontpage">')
    table.insert(html_parts, page_title)
    table.insert(html_parts, '</h1>\n')
    table.insert(html_parts, '<p class="koreaderwikifrontpage">')
    table.insert(html_parts, display_date)
    table.insert(html_parts, '</p>\n')
    table.insert(html_parts, '<hr class="koreaderwikifrontpage"/>\n')

    local section_headings = {
        itn = _("In the news"),
        dyk = _("Did you know"),
        otd = _("On this day"),
    }
    local chapters = {}
    for _, key in ipairs({ "itn", "dyk", "otd" }) do
        if sections[key] then
            table.insert(html_parts, string.format('<h2 class="wikireader-mainpage-section" id="%s">', key))
            table.insert(html_parts, section_headings[key])
            table.insert(html_parts, '</h2>\n')
            table.insert(html_parts, sections[key])
            table.insert(html_parts, '\n')
            table.insert(chapters, { label = section_headings[key], anchor = key })
        end
    end

    local html_content = endDoc(html_parts)

    -- Same stitching as the article flow's Archiver hooks, passed as plain
    -- parameters since writeSinglePageEpub writes the EPUB itself.
    local extras
    if lazy_images and next(lazy_images) then
        extras = { files = {}, manifest_items = {} }
        local seen_loading = {}
        html_content = html_content:gsub('<span class="wikireader%-lazyimg" data%-lazyindex="(%d+)"[^>]*></span>',
            function(idx)
                local img = lazy_images[tonumber(idx)]
                if not img then return "" end
                local loading_src = img.imgpath .. ".loading.svg"
                if not seen_loading[loading_src] then
                    seen_loading[loading_src] = true
                    table.insert(extras.files, {
                        path = "OEBPS/" .. loading_src,
                        content = loadingSvg(img.aspect)
                    })
                end
                return sentinelLink(
                    string.format('<img src="%s" style="%s" alt=""/>', loading_src, img.style or ""),
                    sentinelHref(nil, tonumber(idx)), img.style)
            end)
        local pending = {}
        for i, img in ipairs(lazy_images) do
            table.insert(extras.manifest_items, string.format(
                '<item id="wrimg%05d" href="%s" media-type="%s"/>', i, img.imgpath, img.mimetype))
            table.insert(extras.manifest_items, string.format(
                '<item id="wrload%05d" href="%s.loading.svg" media-type="image/svg+xml"/>', i, img.imgpath))
            local record = { src = img.src, imgpath = img.imgpath, mimetype = img.mimetype, section = 0 }
            if img.fallback then record.fallback = img.fallback end
            pending[#pending + 1] = record
        end
        table.insert(extras.files, {
            path = "OEBPS/wikireader-pending.json",
            content = require("json").encode(pending)
        })
    end

    local css = FRONTPAGE_CSS .. [[
h2.wikireader-mainpage-section {
  font-size: 120%;
  border-bottom: 1px solid rgba(0,0,0,0.33);
  padding-bottom: 0.2em;
  margin-top: 1em;
}
]]
    if extras then
        css = css .. [[

/* Image boxes full-width and centered, like the article figures (their
   TemplateStyles floats are stripped with the other <style> blocks, and
   the wrappers' inline floats/widths are stripped in mainpage.lua). */
div.itn-img, div.dyk-img, #mp-otd-img {
  float: none;
  width: 100%;
  margin: 0.5em 0;
}
div.thumbinner {
  border: 1px dashed rgba(0,0,0,0.33);
  padding: 4px;
  width: 100%;
  text-align: center;
}
div.thumbcaption {
  text-align: center;
}
]]
    end

    local epub_path = cache.getHelperCachePath("__mainpage__", date_str, lang)
    if not writeSinglePageEpub(epub_path, display_title, lang, "mainpage", html_content, css, chapters, nil, extras) then
        return false
    end
    return true, epub_path
end

return M
