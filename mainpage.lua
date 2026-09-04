-- Scraping of the English Wikipedia main page for the "Wikipedia main
-- page" menu entry. Fetches the rendered main page once and cuts out its
-- three news boxes ("In the news", "Did you know", "On this day") by their
-- long-stable element ids, then strips everything that doesn't survive
-- reflow or leads to project-space pages. Only the English edition is
-- supported: other wikis use localized titles with different, often
-- id-less markup.

local socket_url = require("socket.url")
local logger = require("logger")

local htmlclean = require("htmlclean")
local wutil = require("wikiutil")

local M = {}

M.MAIN_PAGE_TITLE = "Main Page"

-- Box id -> section key, in EPUB section order.
local SECTION_IDS = {
    { key = "itn", id = "mp-itn" },
    { key = "dyk", id = "mp-dyk" },
    { key = "otd", id = "mp-otd" },
}

-- Link namespaces whose pages are editor-facing ("Archive",
-- "Nominate an article") rather than readable articles. Whole anchors
-- are removed, label included: without their target the labels are noise.
local JUNK_NAMESPACES = {
    "Wikipedia", "Wikipedia_talk", "Template", "Template_talk",
    "Help", "Help_talk", "Category", "Category_talk", "Portal",
    "Portal_talk", "File", "File_talk", "Special", "MediaWiki",
    "MediaWiki_talk", "User", "User_talk", "Draft", "Module",
}

-- Returns the inner HTML of the <div id="id"> box, or nil. Box divs nest
-- arbitrarily (image wrappers, footer lists), so the matching close tag
-- must be depth-walked, not pattern-matched.
local function extractBox(html, id)
    local open_start, open_end = html:find('<div id="' .. id .. '"', 1, true)
    if not open_start then return nil end
    local open_tag_end = html:find(">", open_end, true)
    if not open_tag_end then return nil end
    local close_start = wutil.findMatchingClose(html, "div", open_tag_end)
    if not close_start then return nil end
    return html:sub(open_tag_end + 1, close_start - 1)
end

local function cleanBoxHtml(html)
    -- TemplateStyles blocks and their dedup <link> stubs.
    html = html:gsub("<style[^>]*>.-</style>", "")
    html = html:gsub("<link[^>]*>", "")

    -- Box images (float-right thumbs, "(pictured)") are dropped wholesale,
    -- wrappers included; same for the footer nav boxes, which MediaWiki
    -- marks noprint -- stripping them whole keeps their labels from
    -- surviving as dangling text once their anchors are removed below.
    html = htmlclean.stripElementsByClass(html, "div", {
        "dyk-img", "itn-img", "otd-img", "thumb", "thumbinner", "mp-thumb",
        "dyk-footer", "itn-footer", "otd-footer", "noprint",
    })

    -- Every anchor that doesn't lead to a readable article: project-space
    -- pages, redlinks (/w/index.php?...redlink=1), external sites (the
    -- mailing-list "By email" link), and any leftover <img> icons.
    for _, ns in ipairs(JUNK_NAMESPACES) do
        html = html:gsub('<a[^>]-href="/wiki/' .. ns .. ':[^"]*"[^>]->.-</a>', "")
    end
    html = html:gsub('<a[^>]-href="/w/index%.php[^"]*"[^>]->.-</a>', "")
    html = html:gsub('<a[^>]-href="https?:[^"]*"[^>]->.-</a>', "")
    html = html:gsub("<img[^>]*>", "")

    -- <span typeof="mw:File"> wrappers left empty by the image removal.
    html = html:gsub('<span[^>]-typeof="mw:File[^"]*"[^>]->.-</span>', "")

    -- The link handler only recognises absolute wiki URLs (see
    -- wikiutil.parseWikiLink); fragments can stay, the handler opens
    -- the full article from the top.
    html = html:gsub('href="/wiki/', 'href="https://en.wikipedia.org/wiki/')

    return html
end

-- Fetches today's English main page and returns cleaned section HTML,
-- keyed itn/dyk/otd (sections whose box can't be found are omitted), or
-- nil with an error kind ("network"/"parse"/"layout") like
-- categories.fetchSections().
function M.fetchSections()
    local url = string.format(
        "https://en.wikipedia.org/w/api.php?action=parse&page=%s&format=json&formatversion=2&prop=text",
        socket_url.escape(M.MAIN_PAGE_TITLE)
    )
    local ok, code, sink = wutil.httpGetJSON(url)
    if not ok or code ~= 200 then return nil, "network" end
    local JSON = require("json")
    local parse_ok, data = pcall(JSON.decode, table.concat(sink))
    if not parse_ok or not data or not data.parse or not data.parse.text then
        return nil, "parse"
    end
    local html = data.parse.text

    local sections = {}
    local found = 0
    for _, spec in ipairs(SECTION_IDS) do
        local box = extractBox(html, spec.id)
        if box then
            sections[spec.key] = cleanBoxHtml(box)
            found = found + 1
        else
            logger.warn("wikireader: main page box not found:", spec.id)
        end
    end
    if found == 0 then
        return nil, "layout"
    end
    return sections
end

return M
