-- Featured-article category handling for WikiReader: resolves each
-- wiki's featured-articles listing page via its Wikidata sitelink (so
-- localized titles come from one generic source, no word table), fetches
-- the section list and per-section article links, builds the tree from
-- the flat section list, and provides the lookup tables used by the link
-- handler to navigate the tree.

local socket_url = require("socket.url")
local wutil = require("wikiutil")

local M = {}

-- Wikidata item connecting the featured-articles listing pages across
-- wikis; its sitelinks are the localized listing titles.
local LISTING_ITEM = "Q16465"

-- lang -> resolved listing page title (session cache; en hard-wired to
-- skip the Wikidata roundtrip).
local resolved_pages = {}
-- The listing page last resolved; a different one on the next resolve
-- means a language switch, so the per-language caches must be reset.
local current_page = nil

-- section_index -> section_title, populated by fillLookup() and used by
-- the link handler to navigate the tree.
M.category_section_titles = {}
-- The full tree; fetchFeaturedCategoryArticles checks whether a section
-- has children (and then builds a subcategory EPUB instead of fetching
-- articles directly).
M.category_tree = {}
-- Session cache: section_index -> { titles = { "Article1", ... } }
M.section_links_cache = {}

-- anchor keys registered by buildCategoryTree; lang -> the listing
-- page's rendered HTML, fetched once for all its T-sections.
local slice_anchors = {}
local page_html_cache = {}

-- Article titles linked from one slice of the listing page's HTML (used
-- for transcluded-section listings): the slice runs from the heading
-- matching the section's anchor to the next heading.
local function titlesFromHtmlSlice(html, anchor)
    local start_pat = { 'id="h-' .. anchor .. '"', 'id="' .. anchor .. '"' }
    local start
    for _, pat in ipairs(start_pat) do
        start = html:find(pat, 1, true)
        if start then break end
    end
    if not start then return nil end
    local nxt = html:find('<h%d[^>]*id="h%-', start + 1)
    local slice = nxt and html:sub(start, nxt - 1) or html:sub(start)
    local titles, seen = {}, {}
    for title in slice:gmatch('href="/wiki/([^"#?]+)"') do
        if not title:find(":", 1, true) then
            title = socket_url.unescape(title):gsub("_", " ")
            if not seen[title] then
                seen[title] = true
                table.insert(titles, title)
            end
        end
    end
    return titles
end

-- Build the category tree from the flat sections list returned by the
-- API; each node has title, section_index, children[]. Returns the
-- toplevel nodes. Some wikis wrap section lines in markup (es/zh spans).
function M.buildCategoryTree(sections)
    local root = { title = "root", toclevel = 0, children = {} }
    local stack = { root }

    for _, s in ipairs(sections) do
        local index = s.index
        -- Transcluded-section listings (de/pt/es "T-N" indices): the
        -- per-section links API rejects them, and sections sharing one
        -- transclusion share its index (de: all "T-1"), so key by the
        -- heading anchor and fetch links by slicing the listing page's
        -- HTML between headings (id="h-<anchor>").
        if (index or ""):find("^T%-") and s.anchor then
            index = s.anchor
            slice_anchors[index] = index
        end
        local node = {
            title = (s.line or ""):gsub("<[^>]*>", ""),
            section_index = index,
            toclevel = s.toclevel,
            children = {},
        }
        while #stack > 0 and stack[#stack].toclevel >= s.toclevel do
            table.remove(stack)
        end
        table.insert(stack[#stack].children, node)
        table.insert(stack, node)
    end

    return root.children
end

function M.fillLookup(nodes)
    for _, node in ipairs(nodes) do
        M.category_section_titles[node.section_index] = node.title
        M.fillLookup(node.children)
    end
end

function M.findNode(nodes, index)
    for _, node in ipairs(nodes) do
        if node.section_index == index then
            return node
        end
        local found = M.findNode(node.children, index)
        if found then return found end
    end
    return nil
end

-- Returns the wiki's featured-articles listing page title (localized
-- via Wikidata sitelinks), or nil with an error kind ("network" or
-- "unsupported": the wiki has no listing). Populates the session caches.
function M.resolveListingPage(lang)
    if resolved_pages[lang] then
        return resolved_pages[lang]
    end
    local page = "Wikipedia:Featured articles"
    if lang ~= "en" then
        local url = string.format(
            "https://www.wikidata.org/w/api.php?action=wbgetentities&ids=%s&props=sitelinks&sitefilter=%swiki&format=json",
            LISTING_ITEM, lang)
        local ok, code, sink = wutil.httpGetJSON(url)
        if not ok or code ~= 200 then return nil, "network" end
        local JSON = require("json")
        local parse_ok, data = pcall(JSON.decode, table.concat(sink))
        local entity = parse_ok and data and data.entities and data.entities[LISTING_ITEM]
        local link = entity and entity.sitelinks and entity.sitelinks[lang .. "wiki"]
        if not (link and link.title) then return nil, "unsupported" end
        page = link.title
    end
    -- Category caches are per-language; a language switch must not mix
    -- trees built from another wiki's listing.
    if current_page and current_page ~= page then
        M.category_section_titles = {}
        M.category_tree = {}
        M.section_links_cache = {}
    end
    resolved_pages[lang] = page
    current_page = page
    return page
end

-- Fetch the section list of the wiki's featured-articles listing page
-- (the raw input for buildCategoryTree). Returns the sections, or nil
-- plus an error kind ("network", "parse" or "unsupported") so the
-- caller can pick a message.
function M.fetchSections(lang)
    local page, err = M.resolveListingPage(lang)
    if not page then return nil, err end
    local url = string.format(
        "https://%s.wikipedia.org/w/api.php?action=parse&page=%s&prop=sections&format=json",
        lang, socket_url.escape(page:gsub(" ", "_")))
    local ok, code, sink = wutil.httpGetJSON(url)
    if not ok or code ~= 200 then return nil, "network" end
    local JSON = require("json")
    local parse_ok, data = pcall(JSON.decode, table.concat(sink))
    if not parse_ok or not data or not data.parse or not data.parse.sections then
        return nil, "parse"
    end
    return data.parse.sections
end

-- Article titles linked from one section of the wiki's featured-articles
-- listing page, served from the session cache when possible. Returns the
-- titles, or nil on network/parse failure (not cached, so a retry
-- refetches).
function M.fetchSectionLinks(lang, section_index)
    local cached = M.section_links_cache[section_index]
    if cached then
        return cached.titles
    end
    local page = resolved_pages[lang]
    if not page then return nil end
    local anchor = slice_anchors[section_index]
    if anchor then
        local html = page_html_cache[lang]
        if not html then
            local url = string.format(
                "https://%s.wikipedia.org/w/api.php?action=parse&page=%s&prop=text&format=json",
                lang, socket_url.escape(page:gsub(" ", "_")))
            local ok, code, sink = wutil.httpGetJSON(url)
            if not ok or code ~= 200 then return nil end
            local JSON = require("json")
            local parse_ok, data = pcall(JSON.decode, table.concat(sink))
            if not parse_ok or not data or not data.parse or not data.parse.text then return nil end
            html = data.parse.text["*"]
            page_html_cache[lang] = html
        end
        local titles = titlesFromHtmlSlice(html, anchor)
        if titles then
            M.section_links_cache[section_index] = { titles = titles }
        end
        return titles
    end
    local url = string.format(
        "https://%s.wikipedia.org/w/api.php?action=parse&page=%s&section=%s&prop=links&format=json",
        lang, socket_url.escape(page:gsub(" ", "_")), section_index
    )
    local ok, code, sink = wutil.httpGetJSON(url)
    if not ok or code ~= 200 then return nil end
    local JSON = require("json")
    local parse_ok, data = pcall(JSON.decode, table.concat(sink))
    if not parse_ok or not data or not data.parse or not data.parse.links then return nil end
    local titles = {}
    for _, link in ipairs(data.parse.links) do
        if link.ns == 0 then
            table.insert(titles, link["*"])
        end
    end
    M.section_links_cache[section_index] = { titles = titles }
    return titles
end

return M
