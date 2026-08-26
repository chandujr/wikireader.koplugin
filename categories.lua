-- Category tree building for WikiReader's featured-article browser.
-- Builds a tree from Wikipedia's flat section list and provides the
-- lookup tables used by the link handler to navigate the tree.

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

return M
