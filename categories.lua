-- Featured-article category handling for WikiReader: fetches the section
-- list and per-section article links from Wikipedia:Featured_articles,
-- builds the tree from the flat section list, and provides the lookup
-- tables used by the link handler to navigate the tree.

local wutil = require("wikiutil")

local M = {}

-- section_index -> section_title, populated by fillLookup() and used by
-- the link handler to navigate the tree.
M.category_section_titles = {}
-- The full tree; fetchFeaturedCategoryArticles checks whether a section
-- has children (and then builds a subcategory EPUB instead of fetching
-- articles directly).
M.category_tree = {}
-- Session cache: section_index -> { titles = { "Article1", ... } }
M.section_links_cache = {}

-- Build the category tree from the flat sections list returned by the
-- API; each node has title, section_index, children[]. Returns the
-- toplevel nodes.
function M.buildCategoryTree(sections)
    local root = { title = "root", toclevel = 0, children = {} }
    local stack = { root }

    for _, s in ipairs(sections) do
        local node = {
            title = s.line,
            section_index = s.index,
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

-- Fetch the section list of Wikipedia:Featured_articles (the raw input
-- for buildCategoryTree). Returns the sections, or nil plus an error
-- kind ("network" or "parse") so the caller can pick a message.
function M.fetchSections(lang)
    local url = string.format(
        "https://%s.wikipedia.org/w/api.php?action=parse&page=Wikipedia:Featured_articles&prop=sections&format=json",
        lang
    )
    local ok, code, sink = wutil.httpGetJSON(url)
    if not ok or code ~= 200 then return nil, "network" end
    local JSON = require("json")
    local parse_ok, data = pcall(JSON.decode, table.concat(sink))
    if not parse_ok or not data or not data.parse or not data.parse.sections then
        return nil, "parse"
    end
    return data.parse.sections
end

-- Article titles linked from one section of Wikipedia:Featured_articles,
-- served from the session cache when possible. Returns the titles, or
-- nil on network/parse failure (not cached, so a retry refetches).
function M.fetchSectionLinks(lang, section_index)
    local cached = M.section_links_cache[section_index]
    if cached then
        return cached.titles
    end
    local url = string.format(
        "https://%s.wikipedia.org/w/api.php?action=parse&page=Wikipedia:Featured_articles&section=%s&prop=links&format=json",
        lang, section_index
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
