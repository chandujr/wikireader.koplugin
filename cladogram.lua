-- Cladogram (Template:Clade) conversion for WikiReader.
--
-- Wikipedia renders phylogenetic trees ("cladograms", from Template:Clade,
-- found mostly in biology articles) as deeply nested <table class="clade">
-- elements, where every branch line is drawn with CSS borders on the table
-- cells: the vertical trunk is the label cells' border-left, the horizontal
-- branch lines their border-bottom/top. crengine does not render those
-- one-sided table-cell borders in a reflowable EPUB, so the species names
-- survive but every connecting line vanishes, leaving a meaningless column
-- of text.
--
-- Like latex.lua does for formulas, this module re-parses the clade tables
-- and re-emits each diagram as a monospaced <pre> block drawn with Unicode
-- box-drawing characters, so the tree structure always shows regardless of
-- the CSS the renderer supports.

local util = require("util")
local wutil = require("wikiutil")

local M = {}

--[[-------------------------------------------------------------------------
Low-level HTML walking helpers
--]]

-- Finds the next <tag ...>...</tag> element (tracking nested same-tag
-- depth) whose open tag matches `open_tag_pat`, starting at `pos`.
-- Returns open_start, open_end, close_start, close_end, or nil.
local function findBalancedElement(html, tag, pos, open_tag_pat)
    while true do
        local os, oe = html:find(open_tag_pat, pos)
        if not os then return nil end
        local cs, ce = wutil.findMatchingClose(html, tag, oe)
        if cs then
            return os, oe, cs, ce
        end
        pos = oe + 1
    end
end

-- Returns a list of {open_start, open_end, close_start, close_end} for the
-- top-level `tag` elements within html[start, stop). "Top-level" here means
-- elements of THIS container only: nested same-name elements (a clade table
-- inside a cell inside a row, its cells, etc.) are skipped over by the
-- balanced matching, so we never mistake a nested table's <tr>/<td> for one
-- of our own.
local function findTopLevel(html, tag, start, stop)
    local res = {}
    local pos = start
    while pos < stop do
        local os, oe, cs, ce = findBalancedElement(html, tag, pos, "<" .. tag .. "[^>]*>")
        if not os or os > stop then break end
        if cs > stop then break end
        res[#res + 1] = { os, oe, cs, ce }
        pos = ce + 1
    end
    return res
end

-- Finds the first <table class="clade"> at or after `pos` (class attribute
-- may carry other classes around "clade"). Returns open_start, open_end.
local function findCladeTable(html, pos)
    while true do
        local os, oe = html:find("<table[^>]*>", pos)
        if not os then return nil end
        if html:sub(os, oe):find('class="[^"]*clade[^"]*"') then
            return os, oe
        end
        pos = oe + 1
    end
end

--[[-------------------------------------------------------------------------
Clade table -> tree parsing
--]]

-- Converts an HTML fragment to plain text: strips tags (and useless
-- <style>/<link> blocks), decodes entities and collapses whitespace.
local function plainText(frag)
    local text = frag
    text = text:gsub("<style[^>]*>.-</style>", " ")
    text = text:gsub("<link[^>]*/?>", " ")
    text = text:gsub("<[^>]*>", " ")
    text = util.htmlEntitiesToUtf8(text)
    text = text:gsub("%s+", " ")
    text = text:match("^%s*(.-)%s*$") or text
    return text
end

-- Parses the inner HTML of a <table class="clade"> (everything between the
-- open tag and </table>) into a tree node:
--   { label = "...", sublabel = "...", children = { {kind="leaf", text=..}
--     | {kind="node", node=<node>}, ... } }
--
-- MediaWiki's clade layout is a sequence of rows, one per child, each made
-- of a label cell (clade-label, empty for every child but the first) and a
-- rowspan-2 leaf cell (clade-leaf) holding either the child's text or a
-- nested clade table for a whole sub-clade. clade-slabel cells sit below
-- the labels and are almost always empty.
local function parseCladeTable(inner)
    local node = { label = "", sublabel = "", children = {} }
    local rows = findTopLevel(inner, "tr", 1, #inner + 1)
    for _, row in ipairs(rows) do
        local row_inner = inner:sub(row[2] + 1, row[3] - 1)
        local cells = findTopLevel(row_inner, "td", 1, #row_inner + 1)
        for _, cell in ipairs(cells) do
            local open_tag = row_inner:sub(cell[1], cell[2])
            local cls = open_tag:match('class%s*=%s*"([^"]*)"') or ""
            local cell_inner = row_inner:sub(cell[2] + 1, cell[3] - 1)
            if cls:find("clade%-slabel") then
                local t = plainText(cell_inner)
                if t ~= "" then node.sublabel = t end
            elseif cls:find("clade%-label") then
                local t = plainText(cell_inner)
                if t ~= "" then node.label = t end
            elseif cls:find("clade%-leaf") then
                local tos, toe = findCladeTable(cell_inner, 1)
                if tos then
                    local tcs, tce = wutil.findMatchingClose(cell_inner, "table", toe)
                    if tcs then
                        local child = parseCladeTable(cell_inner:sub(toe + 1, tcs - 1))
                        table.insert(node.children, { kind = "node", node = child })
                    else
                        local t = plainText(cell_inner)
                        if t ~= "" then table.insert(node.children, { kind = "leaf", text = t }) end
                    end
                else
                    local t = plainText(cell_inner)
                    if t ~= "" then table.insert(node.children, { kind = "leaf", text = t }) end
                end
            end
        end
    end
    return node
end

--[[-------------------------------------------------------------------------
Tree -> box-drawing text rendering
--]]

-- Maximum width of a rendered line, in characters. <pre> does not wrap in
-- crengine, so long species lists would run off the page; keep lines within
-- this bound and fold the overflow onto indented continuation lines. 55 is
-- narrow enough to fit comfortably on a 6\" e-ink reader's page width in a
-- monospace face, while still wide enough to avoid excessive wrapping.
local MAX_LINE_WIDTH = 55

-- Wraps `text` at spaces so no line is longer than `width`, and returns a
-- list of lines.
local function wrapText(text, width)
    local lines = {}
    while #text > width do
        -- Last space within the first `width` chars, if any
        local last_space = nil
        for j = width, 1, -1 do
            if text:sub(j, j) == " " then
                last_space = j
                break
            end
        end
        if last_space then
            table.insert(lines, text:sub(1, last_space - 1))
            text = text:sub(last_space + 1)
        else
            -- no space at all in sight: hard-break
            table.insert(lines, text:sub(1, width))
            text = text:sub(width + 1)
        end
        text = text:match("^%s*(.-)%s*$") or text
    end
    if text ~= "" then
        table.insert(lines, text)
    end
    return lines
end

-- Escapes a string so it is safe to embed in the generated HTML.
local function escapeHtml(text)
    text = text:gsub("&", "&amp;")
    text = text:gsub("<", "&lt;")
    text = text:gsub(">", "&gt;")
    return text
end

-- True when a node has neither a label nor a sublabel (it is an unnamed
-- branching point in the diagram).
local function isTransparent(node)
    return node.label == "" and node.sublabel == ""
end

-- True when an *unnamed* node is a pure chain link that should be folded
-- into its parent rather than drawn: it has at most two children and is not
-- a two-leaf fork. This turns the long chains of no-name clade tables that
-- MediaWiki emits for a simple comb into a compact flat fan under the
-- parent (matching how Wikipedia draws a comb as parallel branches), while
-- leaving genuine forks and every named node as a proper subtree.
local function isFork(child_node)
    local n = #child_node.children
    if n == 2 then
        -- A two-leaf fork (a genuine dichotomy) is kept;
        -- a one-leaf + one-subtree link is a chain link to be folded.
        local leaf = 0
        for _, c in ipairs(child_node.children) do
            if c.kind == "leaf" then leaf = leaf + 1 end
        end
        return leaf == 2
    end
    return n > 2
end

-- Flattens a parsed clade tree: keeps every named node and every genuine
-- fork, but folds the unnamed single-chain links up into their parent so
-- a comb renders as a simple fan instead of page after page of one-deep
-- nesting. Returns a new node with kind="leaf"/"node" children ready to draw.
local function flattenNode(node)
    local kids = {}
    for _, child in ipairs(node.children) do
        if child.kind == "leaf" then
            kids[#kids + 1] = child
        else
            local sub = child.node
            if isTransparent(sub) and not isFork(sub) then
                -- Unnamed, non-forking chain link: fold its (already
                -- flattened) children straight into this node's fan.
                local flat = flattenNode(sub)
                for _, gc in ipairs(flat.children) do
                    kids[#kids + 1] = gc
                end
            else
                kids[#kids + 1] = { kind = "node", node = flattenNode(sub) }
            end
        end
    end
    return { label = node.label, sublabel = node.sublabel, children = kids }
end

-- Emits a (possibly wrapped) line of text: the first chunk goes on the
-- line starting with `lead`, every overflow chunk on the next line(s)
-- indented by `cont`.
local function emitLines(out, lead, text, cont)
    local lp = lead
    for _, line in ipairs(wrapText(text, MAX_LINE_WIDTH - #lp)) do
        out[#out + 1] = lp .. line
        lp = cont
    end
end

-- Renders a node's children as an indented tree. `prefix` is the already
-- drawn "│  " run for ancestors; `out` accumulates the lines.
--
-- A child can be a leaf, a named subtree, or an unnamed fork (a genuine
-- unresolved branching point). Forks carry no label, so the fork's first
-- child is drawn inline on a "┬─ " connector line (┬ is the box-drawing
-- glyph for a branch point) and the remaining children fan out beneath it.
local function renderChildren(kids, prefix, out)
    local n = #kids
    for i, kid in ipairs(kids) do
        local last = (i == n)
        local branch = last and "\u{2514}\u{2500} " or "\u{251C}\u{2500} " -- └─ / ├─
        local cont = last and "   " or "\u{2502}  " --      / │
        if kid.kind == "leaf" then
            emitLines(out, prefix .. branch, kid.text, prefix .. cont)
        else
            local sub = kid.node
            local label = sub.label
            if label == "" then label = sub.sublabel end
            if label == "" then
                -- unnamed fork: first child inline after "┬─", rest below
                local fkids = sub.children
                local fn = #fkids
                local fork = prefix .. branch:sub(1, -2) .. "\u{252C}\u{2500} " -- …└─┬─ / …├─┬─
                if fn == 0 then
                    out[#out + 1] = fork:sub(1, -2) -- bare fork, no children
                else
                    local first = fkids[1]
                    if first.kind == "leaf" then
                        emitLines(out, fork, first.text, prefix .. cont)
                    else
                        local fl = first.node.label
                        if fl == "" then fl = first.node.sublabel end
                        emitLines(out, fork, fl, prefix .. cont)
                        renderChildren(first.node.children, prefix .. cont, out)
                    end
                    local rest = {}
                    for j = 2, fn do rest[#rest + 1] = fkids[j] end
                    renderChildren(rest, prefix .. cont, out)
                end
            else
                emitLines(out, prefix .. branch, label, prefix .. cont)
                renderChildren(sub.children, prefix .. cont, out)
            end
        end
    end
end

-- Renders a whole flattened clade tree as one <pre>-ready string.
local function renderTree(node)
    local out = {}
    if node.label ~= "" then
        out[#out + 1] = node.label
    elseif node.sublabel ~= "" then
        out[#out + 1] = node.sublabel
    end
    renderChildren(node.children, "", out)
    return escapeHtml(table.concat(out, "\n"))
end

--[[-------------------------------------------------------------------------
Public API
--]]

-- Replaces every top-level <table class="clade">...</table> (the clade
-- diagrams, each possibly nesting further clade tables) with a
-- <pre class="wikireader-cladogram"> box-drawing rendering of the tree.
-- Nested clade tables are consumed by their enclosing diagram, so scanning
-- from left to right naturally finds only whole diagrams.
function M.replaceCladograms(html)
    local out = {}
    local pos = 1
    while true do
        local os, oe = findCladeTable(html, pos)
        if not os then
            table.insert(out, html:sub(pos))
            break
        end
        table.insert(out, html:sub(pos, os - 1))
        local cs, ce = wutil.findMatchingClose(html, "table", oe)
        if not cs then
            -- Malformed: keep the original block as-is rather than lose it.
            table.insert(out, html:sub(os))
            pos = #html + 1
            break
        end
        local tree = flattenNode(parseCladeTable(html:sub(oe + 1, cs - 1)))
        local rendered = renderTree(tree)
        if rendered ~= "" then
            table.insert(out, '<pre class="wikireader-cladogram">' .. rendered .. '</pre>')
        end
        pos = ce + 1
    end
    return table.concat(out)
end

return M
