-- English-only featured-article category browsing: the menu entry lives
-- in the English-only "Featured Articles" submenu. Fetches the listing
-- page's sections and links, builds the tree, and provides the lookup
-- tables used by the link handler to navigate it.

local socket_url = require("socket.url")
local wutil = require("wikiutil")

local M = {}

local LISTING_PAGE = "Wikipedia:Featured articles"

-- section_index -> section_title, populated by fillLookup() and used by
-- the link handler to navigate the tree.
M.category_section_titles = {}
-- The full tree; fetchFeaturedCategoryArticles checks for children.
M.category_tree = {}
-- Session cache: section_index -> titles.
M.section_links_cache = {}

-- Builds the tree from the API's flat section list; span markup is stripped.
function M.buildCategoryTree(sections)
    local root = { title = "root", toclevel = 0, children = {} }
    local stack = { root }

    for _, s in ipairs(sections) do
        local node = {
            title = (s.line or ""):gsub("<[^>]*>", ""),
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

-- Fetches the listing's section list; nil + "network"/"parse" on failure.
function M.fetchSections()
    local url = string.format(
        "https://en.wikipedia.org/w/api.php?action=parse&page=%s&prop=sections&format=json",
        socket_url.escape(LISTING_PAGE:gsub(" ", "_")))
    local ok, code, sink = wutil.httpGetJSON(url)
    if not ok or code ~= 200 then return nil, "network" end
    local JSON = require("json")
    local parse_ok, data = pcall(JSON.decode, table.concat(sink))
    if not parse_ok or not data or not data.parse or not data.parse.sections then
        return nil, "parse"
    end
    return data.parse.sections
end

-- Opening a category needs the parent's links plus every child's (to
-- subtract subcategory articles), so fetch them together. The synchronous
-- path is the fallback when httpasync is unavailable (tests).
local ok_httpasync, httpasync = pcall(require, "wikireader-httpasync")
if not (ok_httpasync and type(httpasync) == "table" and httpasync.fetch_many) then
    httpasync = nil
end
-- httpasync's non-blocking sockets carry no timeout of their own, so
-- fetch_many would wait forever on a dead peer; cap the whole batch.
local BATCH_DEADLINE_S = 30

local function sectionLinksUrl(section_index)
    return string.format(
        "https://en.wikipedia.org/w/api.php?action=parse&page=%s&section=%s&prop=links&format=json",
        socket_url.escape(LISTING_PAGE:gsub(" ", "_")), section_index
    )
end

local function parseSectionLinks(body)
    local JSON = require("json")
    local parse_ok, data = pcall(JSON.decode, body)
    if not parse_ok or not data or not data.parse or not data.parse.links then
        return nil
    end
    local titles = {}
    for _, link in ipairs(data.parse.links) do
        if link.ns == 0 then
            titles[#titles + 1] = link["*"]
        end
    end
    return titles
end

-- Fetches sections in parallel; returns section_index -> titles
-- (failures absent). Cached sections skip the network.
function M.fetchSectionLinksBatch(section_indices)
    local results = {}
    local tasks = {}
    for _, section_index in ipairs(section_indices) do
        local cached = M.section_links_cache[section_index]
        if cached then
            results[section_index] = cached.titles
        else
            tasks[#tasks + 1] = { index = section_index, url = sectionLinksUrl(section_index) }
        end
    end
    if #tasks == 0 then return results end

    local function store(section_index, body)
        local titles = body and parseSectionLinks(body)
        if titles then
            M.section_links_cache[section_index] = { titles = titles }
            results[section_index] = titles
        end
    end

    if httpasync then
        local started = os.time()
        httpasync.fetch_many(tasks, {
            concurrency = 5,
            get_url = function(task) return task.url end,
            on_success = function(task, content)
                store(task.index, content)
            end,
            on_progress = function()
                return os.time() - started < BATCH_DEADLINE_S
            end,
        })
    else
        for _, task in ipairs(tasks) do
            local ok, code, sink = wutil.httpGetJSON(task.url)
            if ok and code == 200 then
                store(task.index, table.concat(sink))
            end
        end
    end
    return results
end

function M.fetchSectionLinks(section_index)
    return M.fetchSectionLinksBatch({ section_index })[section_index]
end

return M
