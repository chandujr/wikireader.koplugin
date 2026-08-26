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
-- open tag and </table>) into a list of children, each either
-- {kind="leaf", text=..} or {kind="node", node={label=.., sublabel=..,
-- children=<list>}}.
--
-- Module:Clade (the engine behind {{clade}}) lays out each child as its
-- own pair of rows: row 1 holds that child's OWN clade-label cell
-- (built from its own |labelN= parameter) with its clade-leaf cell, the
-- leaf carrying rowspan="2" so it also covers row 2; row 2 holds only
-- that child's clade-slabel cell. Crucially, |label1=, |label2=, ... are
-- independent per-child parameters -- ANY child can be named -- so a
-- label found in a row names *that row's own child* and nothing else.
local function parseCladeTable(inner)
    local children = {}
    local rows = findTopLevel(inner, "tr", 1, #inner + 1)
    for _, row in ipairs(rows) do
        local row_inner = inner:sub(row[2] + 1, row[3] - 1)
        local cells = findTopLevel(row_inner, "td", 1, #row_inner + 1)
        local row_label, row_sublabel, row_child = "", "", nil
        for _, cell in ipairs(cells) do
            local open_tag = row_inner:sub(cell[1], cell[2])
            local cls = open_tag:match('class%s*=%s*"([^"]*)"') or ""
            local cell_inner = row_inner:sub(cell[2] + 1, cell[3] - 1)
            if cls:find("clade%-slabel") then
                local t = plainText(cell_inner)
                if t ~= "" then row_sublabel = t end
            elseif cls:find("clade%-label") then
                local t = plainText(cell_inner)
                if t ~= "" then row_label = t end
            elseif cls:find("clade%-leaf") then
                local tos, toe = findCladeTable(cell_inner, 1)
                if tos then
                    local tcs, tce = wutil.findMatchingClose(cell_inner, "table", toe)
                    if tcs then
                        local sub_children = parseCladeTable(cell_inner:sub(toe + 1, tcs - 1))
                        row_child = { kind = "node", node = { label = "", sublabel = "", children = sub_children } }
                    else
                        local t = plainText(cell_inner)
                        if t ~= "" then row_child = { kind = "leaf", text = t } end
                    end
                else
                    local t = plainText(cell_inner)
                    if t ~= "" then row_child = { kind = "leaf", text = t } end
                end
            end
        end
        if row_child then
            if row_label ~= "" or row_sublabel ~= "" then
                if row_child.kind == "node" then
                    row_child.node.label = row_label
                    row_child.node.sublabel = row_sublabel
                else
                    -- A leaf can carry its own label too (e.g. a single
                    -- named species branch); give it its own line by
                    -- promoting it to a named node wrapping that leaf.
                    row_child = { kind = "node", node = { label = row_label, sublabel = row_sublabel, children = { row_child } } }
                end
            end
            children[#children + 1] = row_child
        elseif row_sublabel ~= "" and #children > 0 then
            -- This row is the rowspan-2 continuation row for the PREVIOUS
            -- child (holding only its clade-slabel) -- attach it there
            -- instead of losing it.
            local last = children[#children]
            if last.kind == "node" and last.node.sublabel == "" then
                last.node.sublabel = row_sublabel
            end
        end
    end
    return children
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

-- Flattens a parsed clade tree. Only unnamed *single-child* pass-throughs
-- are folded into their parent: wrapper tables MediaWiki sometimes emits
-- around a lone child for layout reasons, which carry no information of
-- their own (no label, nothing to branch to). Any node with 2+ children,
-- named or not, is kept as a real branch point.
-- Returns a new node with kind="leaf"/"node" children ready to draw.
local function flattenNode(node)
    local kids = {}
    for _, child in ipairs(node.children) do
        if child.kind == "leaf" then
            kids[#kids + 1] = child
        else
            local flat = flattenNode(child.node)
            if isTransparent(flat) and #flat.children <= 1 then
                -- Unnamed pass-through (0 or 1 child): splice its child, if
                -- any, straight into this node's fan; drop it if empty.
                for _, gc in ipairs(flat.children) do
                    kids[#kids + 1] = gc
                end
            else
                kids[#kids + 1] = { kind = "node", node = flat }
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
-- A child is a leaf, a named subtree, or an unnamed branch point (a real
-- fork left unnamed by the source article). Unnamed branch points get a
-- bare connector ("├─┬" / "└─┬") and, like named nodes, have ALL of their
-- children rendered one level deeper via a single recursive call -- there
-- is no "first child inline, rest below" special case.
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
                -- Unnamed branch point (flattenNode guarantees it has 2+
                -- children, or it would have been folded away already).
                out[#out + 1] = prefix .. branch:sub(1, -2) .. "\u{252C}" -- …└─┬ / …├─┬
                renderChildren(sub.children, prefix .. cont, out)
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
        -- The outermost table has no parent row to supply it a name (a
        -- cladogram's root label, if any, is ordinary wikitext sitting
        -- before the table, not part of it), so it starts unnamed.
        local root = { label = "", sublabel = "", children = parseCladeTable(html:sub(oe + 1, cs - 1)) }
        local tree = flattenNode(root)
        local rendered = renderTree(tree)
        if rendered ~= "" then
            table.insert(out, '<pre class="wikireader-cladogram">' .. rendered .. '</pre>')
        end
        pos = ce + 1
    end
    return table.concat(out)
end

return M