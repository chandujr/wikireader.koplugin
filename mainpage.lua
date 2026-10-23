-- "Wikipedia main page": scrapes the wiki's rendered main page and cuts
-- out its boxes by long-stable anchors. Only the ten most-read Wikipedias
-- are tuned (the markup is localized and differs per wiki); the featured-
-- feed API has no news/DYK for almost any of them, so untuned wikis have
-- no entry. English keeps only the news boxes; others get their article of
-- the day first.

local logger = require("logger")
local socket_url = require("socket.url")

local htmlclean = require("htmlclean")
local qrimage = require("qrimage")
local wutil = require("wikiutil")

local M = {}

local API_URL = "https://%s.wikipedia.org/w/api.php"
    .. "?action=parse&page=%s&format=json&formatversion=2&prop=text&parser=legacy"

-- Section selectors, in EPUB order.
--   id            a box element (depth-walked)
--   heading       a heading found by id or text prefix; the body is then
--                 the nearest ancestor with `container`, or the next
--                 element with `after`
--   block         a main-page-block-heading text (pt); its contents div
--   heading_prev  the <h2> just above an `id` box supplies the heading
local LANGUAGES = {
    en = {
        page = "Main Page",
        sections = {
            { key = "itn", id = "mp-itn", heading_prev = true },
            { key = "dyk", id = "mp-dyk", heading_prev = true },
            { key = "otd", id = "mp-otd", heading_prev = true },
        },
    },
    es = {
        page = "Wikipedia:Portada",
        sections = {
            { key = "tfa", id = "main-tfa" },
            { key = "ga", id = "main-tga" },
            { key = "itn", id = "main-cur" },
            { key = "otd", id = "main-itd" },
        },
    },
    de = {
        page = "Wikipedia:Hauptseite",
        sections = {
            { key = "tfa", id = "artikel" },
            { key = "itn", id = "nachrichten" },
            { key = "deaths", id = "verstorbene" },
            { key = "dyk", id = "wissenswertes" },
            { key = "otd", id = "ereignisse" },
        },
    },
    ja = {
        page = "メインページ",
        sections = {
            { key = "tfa", id = "fa_and_ga" },
            { key = "new", id = "new_articles" },
            { key = "enhanced", id = "enhanced_articles" },
            { key = "otd", id = "on_this_day" },
        },
    },
    fr = {
        page = "Wikipédia:Accueil principal",
        sections = {
            { key = "tfa", heading = "Article labellisé du jour", container = "accueil_2017_cadre" },
            { key = "itn", heading = "Actualités", container = "accueil_2017_cadre" },
            { key = "dyk", heading = "Le saviez-vous", container = "accueil_2017_cadre" },
            { key = "otd", heading = "Éphéméride", container = "accueil_2017_cadre" },
        },
    },
    ru = {
        page = "Заглавная страница",
        sections = {
            { key = "tfa", id = "main-tfa" },
            { key = "ga", id = "main-tga" },
            { key = "itn", id = "main-cur" },
            { key = "dyk", id = "main-dyk" },
            { key = "otd", id = "main-itd" },
        },
    },
    it = {
        page = "Pagina principale",
        sections = {
            { key = "tfa", heading = "Vetrina", after = "itwiki-template-finestrahome-contenuto" },
            { key = "ga", heading = "Voci di qualità", after = "itwiki-template-finestrahome-contenuto" },
            { key = "dyk", heading = "Lo sapevi che", after = "itwiki-template-finestrahome-contenuto" },
            { key = "otd", heading = "Ricorrenze", after = "itwiki-template-finestrahome-contenuto" },
        },
    },
    pl = {
        page = "Wikipedia:Strona główna",
        sections = {
            { key = "tfa", id = "main-page-featured-article" },
            { key = "ga", id = "main-page-good-article" },
            { key = "itn", id = "main-page-news" },
            { key = "dyk", id = "main-page-didyouknow" },
            { key = "otd", id = "main-page-anniversaries" },
        },
    },
    zh = {
        page = "Wikipedia:首页",
        sections = {
            { key = "tfa", id = "column-feature", heading_prev = true },
            { key = "ga", id = "column-good", heading_prev = true },
            { key = "itn", id = "column-itn", heading_prev = true },
            { key = "dyk", id = "column-dyk", heading_prev = true },
            { key = "otd", id = "column-otd", heading_prev = true },
        },
    },
    pt = {
        page = "Wikipédia:Página principal",
        sections = {
            { key = "tfa", block = "Artigo em destaque" },
            { key = "itn", block = "Eventos atuais" },
            { key = "dyk", block = "Sabia que" },
            { key = "otd", block = "na história" },
        },
    },
}

-- Some wikis print a section label in a classed div, separate from the
-- article-title h2. Tokens are plain substrings, like htmlclean classes.
local HEADING_CLASSES = {
    "main-head", "main-header", "main-box-section", "main-box-header",
    "main-box-title", "mainpage-heading", "finestrahome-titolo",
    "main-page-block-heading", "hauptseite-box-title", "fake-heading",
}

local function decodeEntities(s)
    local named = {
        amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ",
        ndash = "–", mdash = "—", hellip = "…",
    }
    local function utf8char(n)
        if n < 0x80 then
            return string.char(n)
        elseif n < 0x800 then
            return string.char(0xC0 + math.floor(n / 0x40), 0x80 + n % 0x40)
        elseif n < 0x10000 then
            return string.char(0xE0 + math.floor(n / 0x1000),
                0x80 + math.floor(n / 0x40) % 0x40, 0x80 + n % 0x40)
        end
        return string.char(0xF0 + math.floor(n / 0x40000),
            0x80 + math.floor(n / 0x1000) % 0x40,
            0x80 + math.floor(n / 0x40) % 0x40, 0x80 + n % 0x40)
    end
    s = s:gsub("&#x(%x+);", function(h) return utf8char(tonumber(h, 16)) end)
    s = s:gsub("&#(%d+);", function(d) return utf8char(tonumber(d)) end)
    s = s:gsub("&(%a+);", function(n) return named[n] or ("&" .. n .. ";") end)
    return s
end

local function plainText(html)
    html = html:gsub("<[^>]*>", " ")
    html = decodeEntities(html):gsub("\194\173", ""):gsub("\194\160", " ")
    return (html:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

-- Element whose opening tag starts at `start`; nil for void/malformed tags.
local function elementAt(html, start)
    local tag = html:match("^<([%w]+)", start)
    if not tag then return nil end
    local open_end = html:find(">", start, true)
    if not open_end then return nil end
    local close_start, close_end = wutil.findMatchingClose(html, tag, open_end)
    if not close_start then return nil end
    return {
        tag = tag, start = start, open_end = open_end,
        inner = html:sub(open_end + 1, close_start - 1), close_end = close_end,
    }
end

local function elementById(html, id)
    local id_pos = html:find('id="' .. id .. '"', 1, true)
    if not id_pos then
        -- MediaWiki sometimes entity-encodes underscores in ids (ja).
        local encoded = id:gsub("_", "&#95;")
        if encoded ~= id then
            id_pos = html:find('id="' .. encoded .. '"', 1, true)
        end
    end
    if not id_pos then return nil end
    local start = html:sub(1, id_pos):match(".*()<") or 1
    return elementAt(html, start)
end

-- The last h2/h3 before `pos` belongs to the box that follows it (en/zh).
local function headingBefore(html, pos)
    local prefix = html:sub(1, pos - 1)
    local best
    for _, tag in ipairs({ "h2", "h3" }) do
        local search = 1
        while true do
            local s = prefix:find("<" .. tag, search, true)
            if not s then break end
            if not best or s > best then best = s end
            search = s + 1
        end
    end
    local el = best and elementAt(prefix, best)
    return el and plainText(el.inner) or nil
end

-- Heading by id first, then by text prefix (OTD headings carry a date).
local function findHeading(html, wanted)
    local pos = 1
    while true do
        local s2 = html:find("<h2", pos, true)
        local s3 = html:find("<h3", pos, true)
        local s = s2 and s3 and math.min(s2, s3) or s2 or s3
        if not s then return nil end
        local el = elementAt(html, s)
        if el then
            local id = html:sub(s, el.open_end):match('id="([^"]*)"')
            local text = plainText(el.inner)
            if id == wanted or text:sub(1, #wanted) == wanted then
                return el.close_end, text
            end
            pos = el.close_end + 1
        else
            pos = s + 1
        end
    end
end

-- Nearest ancestor whose class contains `class_name` (fr section wrapper).
local function ancestorByClass(html, pos, class_name)
    local prefix = html:sub(1, pos - 1)
    local last
    local search = 1
    while true do
        local s = prefix:find("<", search, true)
        if not s then break end
        local open_end = prefix:find(">", s, true)
        if not open_end then break end
        local cls = prefix:sub(s, open_end):match('class="([^"]*)"')
        if cls and cls:find(class_name, 1, true) then last = s end
        search = open_end + 1
    end
    local el = last and elementAt(html, last)
    return el and el.inner
end

-- Next element after `pos` whose class contains `class_name` (it body).
local function nextByClass(html, pos, class_name)
    local search = pos
    while true do
        local s = html:find("<", search, true)
        if not s then return nil end
        local open_end = html:find(">", s, true)
        if not open_end then return nil end
        local cls = html:sub(s, open_end):match('class="([^"]*)"')
        if cls and cls:find(class_name, 1, true) then
            local el = elementAt(html, s)
            return el and el.inner
        end
        search = open_end + 1
    end
end

-- pt's blocks: heading div followed by a contents div, no ids at all.
local function blockByHeading(html, wanted)
    local pos = 1
    while true do
        local s = html:find('class="main-page-block-heading', pos, true)
        if not s then return nil end
        s = html:sub(1, s):match(".*()<") or s
        local el = elementAt(html, s)
        if not el then return nil end
        local text = plainText(el.inner)
        if text:find(wanted, 1, true) then
            local c = html:find('class="main-page-block-contents', el.close_end, true)
            if not c then return nil end
            c = html:sub(1, c):match(".*()<") or c
            local cel = elementAt(html, c)
            return cel and cel.inner, text
        end
        pos = el.close_end + 1
    end
end

-- Splits the box's own label off the body so the EPUB has one heading.
local function splitHeading(html)
    local best_start, best_el, best_text
    for _, tag in ipairs({ "h2", "h3" }) do
        local s = html:find("<" .. tag, 1, true)
        if s then
            local el = elementAt(html, s)
            if el and (not best_start or s < best_start) then
                best_start, best_el, best_text = s, el, plainText(el.inner)
            end
        end
    end
    local pos = 1
    while true do
        local s = html:find("<div", pos, true)
        if not s then break end
        local open_end = html:find(">", s, true)
        if not open_end then break end
        local cls = html:sub(s, open_end):match('class="([^"]*)"')
        if cls then
            for _, token in ipairs(HEADING_CLASSES) do
                if cls:find(token, 1, true) then
                    local el = elementAt(html, s)
                    -- A long "heading" div is a section wrapper; measure its
                    -- text (label icons can be long) so removing it doesn't
                    -- delete the body.
                    if el and #plainText(el.inner) < 200 and (not best_start or s < best_start) then
                        best_start, best_el, best_text = s, el, plainText(el.inner)
                    end
                    break
                end
            end
        end
        pos = open_end + 1
    end
    if not best_el then return nil, html end
    return best_text, html:sub(1, best_start - 1) .. html:sub(best_el.close_end + 1)
end

local function stripPageNoise(html)
    html = html:gsub("<style[^>]*>.-</style>", "")
    html = html:gsub("<script[^>]*>.-</script>", "")
    html = html:gsub("<link[^>]*>", "")
    return html:gsub("<!%-%-.-%-%->", "")
end

-- Namespace links (File:, Portal:, Wikipedia:, ...) are navigation:
-- keep the label, drop the anchor. Article links become absolute.
local function rewriteLinks(html, lang)
    return (html:gsub('<a([^>]-)href="([^"]*)"([^>]*)>(.-)</a>', function(before, href, after, label)
        local title = href:match("^/wiki/(.*)$")
            or href:match("^%./(.*)$")
            or href:match("^https?://[%w%-]+%.wikipedia%.org/wiki/(.*)$")
        if not title or title:find(":", 1, true) then
            return label
        end
        return '<a' .. before .. 'href="https://' .. lang .. '.wikipedia.org/wiki/'
            .. title .. '"' .. after .. '>' .. label .. '</a>'
    end))
end

local function dropImages(html)
    html = htmlclean.stripElementsByAttr(html, "figure", "typeof", { "mw:file" })
    html = htmlclean.stripElementsByClass(html, "div", { "thumb", "gallery", "-img" })
    html = htmlclean.stripElementsByAttr(html, "span", "typeof", { "mw:file" })
    html = html:gsub("<img[^>]*>", "")
    return html:gsub("<figcaption[^>]*>.-</figcaption>", "")
end

-- Images outside the walker's boxes still need the lazy pipeline. Tiny
-- icons are decoration; the rest is centered (bare spans have no figure).
local function lazyInlineImages(html, lazy_images)
    local seen = {}
    html = html:gsub("<img([^>]*)>", function(attrs)
        local width = tonumber(attrs:match('width%s*=%s*"(%d+)"'))
        if width and width <= 24 then return "" end
        return qrimage.makeLazyImageTag(attrs, lazy_images, seen, 0, true, false)
    end)
    html = html:gsub('(<a[^>]*>%s*)(<span class="wikireader%-lazyimg"[^>]*></span>)(%s*</a>)', '%2')
    -- The block-centered placeholder must not stay inside an inline span.
    return (html:gsub('<span[^>]-typeof="mw:File[^"]*"[^>]->(%s*<span class="wikireader%-lazyimg"[^>]*></span>%s*)</span>', '%1'))
end

-- Sections end with wikis' own nav footers ("More…", "Archive",
-- "RSS-Feed"). Drop trailing short elements that link only to
-- namespace/external pages or carry a known footer phrase.
local NAV_KEYWORDS = {
    "more anniversaries", "more current events",
    "archive", "archiv", "архив", "archivo",
    "rss", "nominate", "proponi", "propositions", "propozycje",
    "кандидат", "candidat", "start a new article", "jak napisać",
    "modifier", "modifica", "просмотр шаблона", "tutte le voci",
    "todos los", "все ", "inne ", "weitere ", "programme",
    "sélection", "contenus de qualité", "bons contenus", "lire la suite",
    "leggi la voce", "czytaj więcej", "ver mais", "ver todos",
    "índice geral", "sugestões", "compartilhe", "outros dias",
    "читать", "kalendarium", "więcej", "zum artikel", "artigo completo",
    "véase también", "siehe auch", "voir aussi", "vedi anche",
    "see also", "zobacz też", "смотрите также",
}

local VOID_TAGS = {
    br = true, img = true, hr = true, input = true, meta = true, link = true,
    source = true, track = true, wbr = true, area = true, base = true,
    col = true, embed = true, param = true,
}

-- Footers can be a block or a one-line <p>; prose elements are never
-- descended into, so inline article links aren't mistaken for navigation.
local NAV_TAGS = {
    div = true, ul = true, ol = true, dl = true, table = true,
    section = true, nav = true, p = true,
}
local DESCEND_TAGS = {
    div = true, ul = true, ol = true, dl = true, table = true,
    section = true, nav = true, li = true, dd = true, dt = true,
}

-- Last direct child: start, open-tag end, close-tag start, end. Bounds let
-- the caller descend the last-child chain without reparsing siblings.
local function lastChildBounds(html)
    local tag_pat = "<(/?)%s*([%w]+)([^>]*)>"
    local pos = 1
    local depth = 0
    local current_start, current_open_end
    local last
    while true do
        local s, e, is_close, tag, attrs = html:find(tag_pat, pos)
        if not s then break end
        local t = tag:lower()
        if is_close == "" then
            if VOID_TAGS[t] or attrs:find("%s*/%s*$") then
                if depth == 0 then last = { s, e, e, e } end
            else
                if depth == 0 then current_start, current_open_end = s, e end
                depth = depth + 1
            end
        else
            depth = depth - 1
            if depth == 0 then last = { current_start, current_open_end, s, e } end
            if depth < 0 then depth = 0 end
        end
        pos = e + 1
    end
    return (table.unpack or unpack)(last or {})
end

local function isNavElement(el)
    local text = plainText(el)
    if #text > 250 then return false end
    local has_link, has_article
    for href in el:gmatch('href="([^"]*)"') do
        has_link = true
        local title = href:match("^/wiki/(.*)$")
            or href:match("^%./(.*)$")
            or href:match("^https?://[%w%-]+%.wikipedia%.org/wiki/(.*)$")
        if title and not title:find(":", 1, true) then
            has_article = true
        end
    end
    if not has_link then return false end
    local lower = text:lower()
    local keyword = false
    -- Sentence-like text is article prose, not a footer phrase.
    local prose = lower:find("%.[%s]")
        or lower:find("![%s]") or lower:find("%?[%s]") or lower:match("%.$")
    if not prose then
        for _, word in ipairs(NAV_KEYWORDS) do
            if lower:find(word, 1, true) then
                keyword = true
                break
            end
        end
    end
    -- Images are content unless the footer phrase confirms otherwise.
    if (el:find("<img", 1, true) or el:find("<figure", 1, true)) and not keyword then
        return false
    end
    return keyword or not has_article
end

-- Descends the last-child chain to the footer it ends in; footers sit at
-- different nesting depths per wiki.
local function stripTrailingNav(html)
    for _ = 1, 6 do
        local nav_start, nav_end
        local base = 0
        local inner = html
        while true do
            local s, open_end, close_start, e = lastChildBounds(inner)
            if not s then break end
            local abs_start, abs_open_end = base + s, base + open_end
            local abs_close_start, abs_end = base + close_start, base + e
            local tag = inner:sub(s, open_end):match("^<([%w]+)")
            tag = tag and tag:lower()
            if not (tag and (NAV_TAGS[tag] or DESCEND_TAGS[tag])) then break end
            local el = html:sub(abs_start, abs_end)
            if NAV_TAGS[tag] then
                -- Empty layout stubs (clear:both divs) hide the real last child.
                if plainText(el) == ""
                    and not el:find("<img", 1, true) and not el:find("<figure", 1, true) then
                    nav_start, nav_end = abs_start, abs_end
                    break
                end
                if isNavElement(el) then
                    nav_start, nav_end = abs_start, abs_end
                    break
                end
            end
            if not DESCEND_TAGS[tag] or abs_close_start <= abs_open_end then break end
            base = abs_open_end
            inner = html:sub(abs_open_end + 1, abs_close_start - 1)
        end
        if not nav_start then break end
        html = html:sub(1, nav_start - 1) .. html:sub(nav_end + 1)
    end
    return html
end

-- "Read the full article" links are appended to the last paragraph, so
-- cut that paragraph at the link instead of dropping the block.
local READ_MORE = {
    "zum artikel", "artigo completo", "artículo completo", "czytaj więcej",
    "lire la suite", "leggi la voce", "read more", "weiterlesen",
    "lees meer", "ver mais", "ver todos",
}

local function stripTrailingSeparators(s)
    local separators = { "–", "—", "(", ")", "[", "]", "{", "}",
        "•", "·", "…", ",", ":", ";", "\194\160" }
    while true do
        local before = s
        s = s:gsub("%s+$", "")
        for _, sep in ipairs(separators) do
            if s:sub(-#sep) == sep then
                s = s:sub(1, -#sep - 1)
            end
        end
        if s == before then return s end
    end
end

local function stripTrailingReadMore(html)
    local last_start, last_label
    local pos = 1
    while true do
        local s, e, _, label = html:find("<a([^>]*)>(.-)</a>", pos)
        if not s then break end
        last_start, last_label = s, label
        pos = e + 1
    end
    if not last_start then return html end

    local label = plainText(last_label):lower()
    local match = false
    for _, word in ipairs(READ_MORE) do
        if label:find(word, 1, true) then
            match = true
            break
        end
    end
    if not match then return html end

    local stack = {}
    pos = 1
    while true do
        local s, e, is_close, tag = html:find("<(/?)%s*([%w]+)([^>]*)>", pos)
        if not s or s >= last_start then break end
        local t = tag:lower()
        if is_close == "" then
            local attrs = html:sub(s, e)
            if not (VOID_TAGS[t] or attrs:find("%s*/%s*$")) then
                stack[#stack + 1] = { tag = t, open_end = e }
            end
        else
            stack[#stack] = nil
        end
        pos = e + 1
    end
    local parent
    for i = #stack, 1, -1 do
        if NAV_TAGS[stack[i].tag] then
            parent = stack[i]
            break
        end
    end
    if not parent then return html end
    local close_start, close_end = wutil.findMatchingClose(html, parent.tag, parent.open_end)
    if not close_start then return html end

    local before = html:sub(parent.open_end + 1, last_start - 1)
    -- Drop the inline wrappers that held the link, then the separator before
    -- them (de uses <span><i><a>).
    local open_tags = {}
    pos = 1
    while true do
        local s, e, is_close, tag = before:find("<(/?)%s*([%w]+)([^>]*)>", pos)
        if not s then break end
        local t = tag:lower()
        if is_close == "" and not (VOID_TAGS[t] or before:sub(s, e):find("%s*/%s*$")) then
            open_tags[#open_tags + 1] = { tag = t, start = s }
        elseif is_close ~= "" then
            open_tags[#open_tags] = nil
        end
        pos = e + 1
    end
    if #open_tags > 0 then
        local cut = open_tags[1].start
        for i = 2, #open_tags do
            cut = math.min(cut, open_tags[i].start)
        end
        before = before:sub(1, cut - 1)
    end
    before = stripTrailingSeparators(before)
    return html:sub(1, parent.open_end) .. before
        .. html:sub(close_start, close_end) .. html:sub(close_end + 1)
end

local function cleanContent(raw, lang, image_transform)
    -- Footer/nav boxes and hidden elements go whole; their labels would
    -- dangle once their anchors are unwrapped.
    for _, tag in ipairs({ "div", "ul", "table" }) do
        raw = htmlclean.stripElementsByClass(raw, tag,
            { "noprint", "-footer", "main-footer", "tfa-recent", "main-page-footer" })
        raw = htmlclean.stripElementsByAttr(raw, tag, "style", { "display:none", "display: none" })
    end

    -- Inline styles out-rank the EPUB stylesheet and break reflow.
    raw = raw:gsub('%s+style="[^"]*"', "")
    -- Fixed table widths would overflow the page.
    raw = raw:gsub('(<t[%a]+[^>]-)%s+width="[^"]*"', '%1')
    raw = raw:gsub('(<t[%a]+[^>]-)%s+height="[^"]*"', '%1')
    raw = raw:gsub("<video[^>]*>.-</video>", "")
    raw = raw:gsub("<audio[^>]*>.-</audio>", "")
    -- Before links are rewritten: namespace targets are the nav signal.
    raw = stripTrailingNav(raw)
    raw = stripTrailingReadMore(raw)
    raw = rewriteLinks(raw, lang)
    -- Feed/edit icons would reserve a lazy box each.
    raw = htmlclean.removeInlineIcons(raw)

    if image_transform then
        qrimage.collectImageCaptions(raw, image_transform.captions)
        raw = qrimage.replaceImagesWithLazy(raw, image_transform.lazy)
        raw = lazyInlineImages(raw, image_transform.lazy)
    else
        raw = dropImages(raw)
    end

    raw = raw:gsub("<p[^>]*>%s*</p>", "")
    return (raw:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function buildSection(html, lang, spec, image_transform)
    local raw, heading, strip_heading
    if spec.block then
        raw, heading = blockByHeading(html, spec.block)
    elseif spec.heading then
        local after_heading, text = findHeading(html, spec.heading)
        if after_heading then
            heading = text
            if spec.container then
                raw = ancestorByClass(html, after_heading, spec.container)
                strip_heading = true
            else
                raw = nextByClass(html, after_heading + 1, spec.after)
            end
        end
    elseif spec.id then
        local el = elementById(html, spec.id)
        if el then
            raw = el.inner
            if spec.heading_prev then
                heading = headingBefore(html, el.start)
            else
                strip_heading = true
            end
        end
    end
    if not raw then return nil end

    if strip_heading then
        local split_text, stripped = splitHeading(raw)
        heading = heading or split_text
        raw = stripped
    end
    local body = cleanContent(raw, lang, image_transform)
    if body == "" then return nil end
    return { heading = heading, html = body }
end

function M.isSupported(lang)
    return LANGUAGES[lang] ~= nil
end

-- Returns section tables keyed tfa/itn/dyk/otd (config order in `.order`),
-- or nil plus "unsupported"/"network"/"parse"/"layout". show_images routes
-- media through the lazy pipeline into opts.lazy_images.
function M.fetchSections(lang, show_images, opts)
    lang = lang or "en"
    local config = LANGUAGES[lang]
    if not config then return nil, "unsupported" end

    opts = opts or {}
    local image_transform
    if show_images then
        image_transform = {
            lazy = opts.lazy_images or {},
            captions = opts.image_captions or {},
        }
    end

    local url = string.format(API_URL, lang,
        socket_url.escape(config.page:gsub(" ", "_")))
    local ok, code, sink = wutil.httpGetJSON(url)
    if not ok or code ~= 200 then return nil, "network" end
    local JSON = require("json")
    local parse_ok, data = pcall(JSON.decode, table.concat(sink))
    if not parse_ok or type(data) ~= "table" or not data.parse or not data.parse.text then
        return nil, "parse"
    end
    local html = stripPageNoise(data.parse.text)

    local sections, order = {}, {}
    for _, spec in ipairs(config.sections) do
        local ok_build, section = pcall(buildSection, html, lang, spec, image_transform)
        if not ok_build then
            logger.warn("wikireader: main page section failed:", spec.key, section)
        elseif section then
            sections[spec.key] = section
            order[#order + 1] = spec.key
        end
    end
    if #order == 0 then
        return nil, "layout"
    end
    sections.order = order
    return sections
end

return M
