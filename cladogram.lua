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

-- Tags whose boundaries are a word break; every other tag (<i>, <b>, <a>,
-- <span>, <sup>...) is dropped without leaving a space behind, so that
-- "<i>Calymmanthium</i>)" stays "Calymmanthium)" and does not gain a
-- stray space before the bracket.
local BLOCK_TAGS = {
    p = true, div = true, br = true, hr = true, li = true, ul = true,
    ol = true, dl = true, dd = true, dt = true, tr = true, td = true,
    th = true, table = true, tbody = true, thead = true, caption = true,
}

-- Invisible or exotic spacing characters MediaWiki sprinkles into clade
-- labels. They must go: Lua's "%s" does not match them (so they survive
-- whitespace collapsing and show up as double spaces), and a monospace
-- font that lacks the glyph makes crengine borrow a differently sized one
-- from a fallback font, which shifts everything after it on the line.
local ODD_SPACING = {
    ["\u{00A0}"] = " ",  -- no-break space
    ["\u{2009}"] = " ",  -- thin space
    ["\u{202F}"] = " ",  -- narrow no-break space
    ["\u{2007}"] = " ",  -- figure space
    ["\u{2060}"] = "",   -- word joiner
    ["\u{200B}"] = "",   -- zero-width space
    ["\u{200E}"] = "",   -- left-to-right mark
    ["\u{200F}"] = "",   -- right-to-left mark
    ["\u{00AD}"] = "",   -- soft hyphen
    ["\u{2011}"] = "-",  -- no-break hyphen (missing from most mono fonts)
}

-- Removes every tag from an HTML fragment, keeping only the text.
--
-- This cannot be a simple "<[^>]*>" gsub: Parsoid hangs JSON on elements in
-- data-mw attributes, and that JSON contains raw ">" characters (as in
-- data-mw='{"caption":"&lt;i id=\"mwAWw\">Ornithorhynchus anatinus&lt;/i>"}'),
-- so a pattern would end the tag in the middle of the attribute and spill
-- its tail into the diagram. Walk the tag instead, skipping over anything
-- inside quotes.
local function stripTags(frag)
    local out = {}
    local len = #frag
    local pos = 1
    while true do
        local lt = frag:find("<", pos, true)
        if not lt then
            out[#out + 1] = frag:sub(pos)
            break
        end
        out[#out + 1] = frag:sub(pos, lt - 1)
        local i = lt + 1
        while i <= len do
            local s, _, c = frag:find("([>\"'])", i)
            if not s then
                i = len + 1
            elseif c == ">" then
                i = s
                break
            else
                local qe = frag:find(c, s + 1, true)
                i = qe and (qe + 1) or (len + 1)
            end
        end
        local tag = frag:match("^</?(%a[%w]*)", lt)
        -- Tag boundaries that are a word break become a space, all the
        -- others vanish without a trace.
        out[#out + 1] = (tag and BLOCK_TAGS[tag:lower()]) and " " or ""
        pos = i + 1
        if i > len then break end
    end
    return table.concat(out)
end

-- Converts an HTML fragment to plain text: strips tags (and useless
-- <style> blocks), decodes entities and collapses whitespace.
local function plainText(frag)
    local text = frag
    text = text:gsub("<style[^>]*>.-</style%s*>", " ")
    text = text:gsub("<!%-%-.-%-%->", "")
    text = stripTags(text)
    text = util.htmlEntitiesToUtf8(text)
    for char, replacement in pairs(ODD_SPACING) do
        text = text:gsub(char, replacement)
    end
    text = text:gsub("%s+", " ")
    text = text:match("^%s*(.-)%s*$") or text
    return text
end

--[[-------------------------------------------------------------------------
Clade table -> tree parsing

MediaWiki lays out {{clade}} as one table per branch point, and gives every
child of that branch point a pair of rows:

    <tr><td class="clade-label">NAME</td>
        <td class="clade-leaf" rowspan="2">CONTENT</td></tr>
    <tr><td class="clade-slabel">SUBNAME</td></tr>

CONTENT is either the child's own text (a leaf) or a whole nested clade
table (a sub-clade). NAME/SUBNAME come from the wikitext's |labelN= and
|sublabelN= and are usually empty. The important subtlety: although the
label cell sits in the *parent's* table, it names the *child's* clade -- it
is drawn on the branch leading down to it. Attaching it to the parent (as
an earlier version of this module did) both loses labels, when a parent has
two labelled children, and hangs whole sub-clades off the wrong node.

So a parsed node is:

    { name     = "Cactoideae",  -- "" for the very common unnamed node
      double   = false,         -- |stateN=double, i.e. "not a real clade"
      text     = "Blossfeldia", -- leaves only
      children = { <node>, ... }, -- internal nodes only (may be empty)
    }

`children` being non-nil is what makes a node internal rather than a leaf.
--]]

local parseCladeTable -- forward declaration (mutual recursion)

-- Parses one clade-leaf cell into a node: a nested clade table becomes an
-- internal node, anything else the text of a leaf.
local function parseLeafCell(cell_inner)
    local tos, toe = findCladeTable(cell_inner, 1)
    if tos then
        local tcs = wutil.findMatchingClose(cell_inner, "table", toe)
        if tcs then
            return { children = parseCladeTable(cell_inner:sub(toe + 1, tcs - 1)) }
        end
    end
    return { text = plainText(cell_inner) }
end

-- Parses the inner HTML of a <table class="clade"> (everything between the
-- open tag and </table>) into the list of children of the branch point that
-- table represents.
parseCladeTable = function(inner)
    local children = {}
    local rows = findTopLevel(inner, "tr", 1, #inner + 1)
    for _, row in ipairs(rows) do
        local row_inner = inner:sub(row[2] + 1, row[3] - 1)
        local cells = findTopLevel(row_inner, "td", 1, #row_inner + 1)
        local name, double, leaf_html, slabel
        for _, cell in ipairs(cells) do
            local open_tag = row_inner:sub(cell[1], cell[2])
            local cls = open_tag:match('class%s*=%s*"([^"]*)"') or ""
            local style = open_tag:match('style%s*=%s*"([^"]*)"') or ""
            local cell_inner = row_inner:sub(cell[2] + 1, cell[3] - 1)
            if cls:find("clade%-slabel") then
                slabel = plainText(cell_inner)
            elseif cls:find("clade%-label") then
                name = plainText(cell_inner)
                -- |stateN=double is drawn as a doubled branch line, the
                -- convention for "this group is not a clade".
                double = style:find("border%-bottom%s*:[^;]*double") ~= nil
            elseif cls:find("clade%-leaf") then
                -- clade-leaf, and clade-leafR in mirrored diagrams
                leaf_html = cell_inner
            end
            -- clade-bar cells only carry Template:Barlabel's colour bars
        end
        if leaf_html then
            local child = parseLeafCell(leaf_html)
            child.name = name or ""
            child.double = double or false
            children[#children + 1] = child
        elseif slabel and slabel ~= "" and #children > 0 then
            -- Second row of a pair: an extra name drawn under the branch
            -- of the child the previous row introduced.
            local prev = children[#children]
            prev.name = prev.name ~= "" and (prev.name .. " " .. slabel) or slabel
        end
    end
    return children
end

--[[-------------------------------------------------------------------------
Tree normalisation
--]]

-- Folds away the nodes that carry no information, so the drawing does not
-- waste a line (and a level of indentation) on them:
--
--   * an unnamed node with a single child is a pure pass-through wrapper --
--     MediaWiki emits one whenever a clade template is nested for layout
--     reasons -- so its child is hoisted into its place. This is always
--     safe: no branching, hence no structure, is lost.
--   * a node whose single child is an unnamed branch point *is* that branch
--     point (a clade with one member is not a split), so the two are merged.
--     Without this, an extra layer of {{clade}} nesting in the wikitext --
--     which Wikipedia draws identically -- would push a whole diagram one
--     level deeper than the same diagram written without it.
--   * a completely empty node or leaf is dropped.
--
-- Note what is deliberately *not* folded: an unnamed node with two or more
-- children. It is a real, unresolved branch point (extremely common: most
-- of a phylogeny's internal nodes have no name) and its children are
-- siblings of each other, not of their uncles. Guessing which of those are
-- "genuine" forks and which are just editors chaining templates to get a
-- third sibling is what made the previous version mangle nested clades.
--
-- Two leaf shapes are also normalised here so the renderer only ever sees
-- "internal node with a name" or "leaf with text":
--
--   * a labelled leaf ("|label1=core Cactoideae I|1=some taxa") becomes a
--     named node holding that one leaf, i.e. the label is drawn as the name
--     of the clade the leaf sits in, exactly as Wikipedia draws it;
--   * a labelled but empty leaf is just a leaf whose text is the label.
local function foldNode(node)
    if not node.children then return node end
    local kids = {}
    for _, child in ipairs(node.children) do
        child = foldNode(child)
        if not child.children then
            if child.text ~= "" and child.name ~= "" then
                child = { name = child.name, double = child.double,
                          children = { { name = "", text = child.text, double = false } } }
            elseif child.text == "" and child.name ~= "" then
                child = { name = "", text = child.name, double = child.double }
            end
        end
        local n = child.children and #child.children or 0
        if child.children and child.name == "" and n == 1 then
            -- Pass-through wrapper: hoist its only child, keeping the
            -- doubled branch line if the wrapper carried one.
            local only = child.children[1]
            only.double = only.double or child.double
            kids[#kids + 1] = only
        elseif child.children and child.name == "" and n == 0 then
            -- nothing at all to draw
        elseif not child.children and child.text == "" then
            -- empty cell
        else
            kids[#kids + 1] = child
        end
    end
    node.children = kids
    -- This node has a single unnamed branch point under it: the two are
    -- one and the same node, so take over its children.
    while #node.children == 1 and node.children[1].children
            and node.children[1].name == "" do
        local only = node.children[1]
        node.double = node.double or only.double
        node.children = only.children
    end
    return node
end

--[[-------------------------------------------------------------------------
Tree -> box-drawing text rendering
--]]

-- Box-drawing glyphs, single-line for an ordinary branch and double-line
-- for a |state=double one ("this taxon is not a clade").
--
-- Set USE_ASCII if the diagrams come out ragged on your device: KOReader's
-- bundled monospace font (Droid Sans Mono) has no U+25xx glyphs, so
-- crengine borrows them from a fallback font, whose advance width need not
-- match the monospace one -- and then the columns drift apart. Plain
-- "|-+" always sit on the monospace grid.
local USE_ASCII = false

local GLYPHS = USE_ASCII and {
    vert = "|",
    single = { branch = "+", last = "\\", dash = "-", tee = "+" },
    double = { branch = "+", last = "\\", dash = "=", tee = "+" },
} or {
    vert = "\u{2502}", -- │
    single = { branch = "\u{251C}", last = "\u{2514}", dash = "\u{2500}", tee = "\u{252C}" }, -- ├ └ ─ ┬
    double = { branch = "\u{255E}", last = "\u{2558}", dash = "\u{2550}", tee = "\u{2564}" }, -- ╞ ╘ ═ ╤
}

-- Maximum width of a rendered line, in characters. <pre> does not wrap in
-- crengine, so long species lists would run off the page; keep lines within
-- this bound and fold the overflow onto indented continuation lines. 55 is
-- narrow enough to fit comfortably on a 6" e-ink reader's page width in a
-- monospace face, while still wide enough to avoid excessive wrapping.
local MAX_LINE_WIDTH = 55
-- ...but a deep enough tree eats all of that in indentation alone, so never
-- squeeze the text itself below this many characters (such lines overflow
-- the page rather than wrap into a one-word-per-line column).
local MIN_TEXT_WIDTH = 18

-- Number of characters (not bytes) in a UTF-8 string: everything we draw is
-- single-width, so this is also the column count.
local function utf8Len(s)
    local n = 0
    for i = 1, #s do
        local b = s:byte(i)
        if b < 0x80 or b > 0xBF then n = n + 1 end -- skip continuation bytes
    end
    return n
end

-- Splits `s` after its first `n` characters, never mid-sequence.
local function utf8Cut(s, n)
    local i, count = 1, 0
    while i <= #s and count < n do
        local b = s:byte(i)
        i = i + (b < 0x80 and 1 or b < 0xE0 and 2 or b < 0xF0 and 3 or 4)
        count = count + 1
    end
    return s:sub(1, i - 1), s:sub(i)
end

-- Wraps `text` on spaces so no line is longer than `width` characters, and
-- returns the list of lines.
local function wrapText(text, width, hard_width)
    local lines = {}
    local line, line_len = "", 0
    local function flush()
        -- A word too long for its line is left to stick out rather than
        -- chopped in half ("Ornithocheiromorph|a" helps nobody), unless it
        -- would not fit on a line of its own either -- then it has to be
        -- cut somewhere, and it is cut on a character boundary so the
        -- UTF-8 stays valid.
        while line_len > hard_width do
            local head, tail = utf8Cut(line, width)
            lines[#lines + 1] = head
            line, line_len = tail, utf8Len(tail)
        end
    end
    for word in text:gmatch("%S+") do
        local wlen = utf8Len(word)
        if line == "" then
            line, line_len = word, wlen
        elseif line_len + 1 + wlen <= width then
            line, line_len = line .. " " .. word, line_len + 1 + wlen
        else
            lines[#lines + 1] = line
            line, line_len = word, wlen
        end
        flush()
    end
    if line ~= "" then lines[#lines + 1] = line end
    return lines
end

-- Emits a (possibly wrapped) line of text: the first chunk goes on the line
-- starting with `lead`, every overflow chunk on the next line(s) indented by
-- `cont`. Both are always the same width, so wrapped text stays aligned
-- under the first chunk.
local function emitLines(out, lead, text, cont)
    local width = MAX_LINE_WIDTH - utf8Len(lead)
    if width < MIN_TEXT_WIDTH then width = MIN_TEXT_WIDTH end
    local lines = wrapText(text, width, MAX_LINE_WIDTH)
    if #lines == 0 then
        out[#out + 1] = (lead:gsub("%s+$", ""))
        return
    end
    for i, line in ipairs(lines) do
        out[#out + 1] = (i == 1 and lead or cont) .. line
    end
end

-- The text drawn for a node: an internal node shows the name of its clade
-- (empty for an unnamed branch point), a leaf its own text.
local function nodeText(node)
    return node.children and node.name or node.text
end

-- An unnamed branch point has nothing to write on a line of its own, so it
-- is drawn as a fork instead of a labelled node.
local function isFork(node)
    return node.children ~= nil and node.name == "" and #node.children >= 2
end

local renderChildren, renderChild, renderFork

-- Draws every child of one node, each hanging off the `prefix` column run.
renderChildren = function(kids, prefix, out)
    for i, kid in ipairs(kids) do
        renderChild(kid, prefix, i == #kids, out)
    end
end

-- Draws one child.
--   prefix : the guide run drawn for all the ancestors, e.g. "│  │  "
--   last   : true when this is its parent's last child (└ rather than ├)
--
-- The child's own descendants are drawn under `guide`, two columns wider
-- than `prefix`: that is the column its branch corner sits in, so a fork's
-- ┬ and the corners of the children hanging below it line up exactly.
renderChild = function(node, prefix, last, out)
    local g = node.double and GLYPHS.double or GLYPHS.single
    local corner = last and g.last or g.branch
    local guide = prefix .. (last and " " or GLYPHS.vert) .. " "
    if isFork(node) then
        renderFork(node, prefix .. corner .. g.dash, guide, out)
    elseif node.children and node.name == "" then
        -- Degenerate; foldNode() normally removes these.
        if node.children[1] then renderChild(node.children[1], prefix, last, out) end
    else
        emitLines(out, prefix .. corner .. g.dash .. " ", nodeText(node), guide .. " ")
        if node.children then
            renderChildren(node.children, guide .. " ", out)
        end
    end
end

-- Draws an unnamed branch point. Having no name to put on a line of its
-- own, it takes its first child onto the connector line behind a ┬ and
-- hangs its remaining children below that ┬:
--
--     ├─┬─ Cacteae               the fork, first child drawn inline
--     │ │  └─ Some genus         ...that first child's own descendants
--     │ └─ core Cactoideae       ...the fork's second child
--
-- Everything that belongs to the fork therefore starts in the ┬'s column,
-- which is what tells siblings apart from descendants: the previous
-- version reused the *parent's* indentation for the inlined child's
-- descendants, which is why grandchildren surfaced as siblings.
--
--   lead  : everything to draw before the ┬ (e.g. "│  ├─")
--   guide : the column run the fork's children hang from; the same width as
--           `lead`, so their corners land right under the ┬
renderFork = function(node, lead, guide, out)
    local kids = node.children
    local first = kids[1]
    -- The line to the right of the ┬ is the *first child's* branch, so it
    -- is that child's state, not the fork's, that decides whether it is
    -- drawn doubled.
    local g = first.double and GLYPHS.double or GLYPHS.single
    local sub_guide = guide .. GLYPHS.vert .. " " -- first child is never last
    if isFork(first) then
        renderFork(first, lead .. g.tee .. g.dash, sub_guide, out)
    else
        emitLines(out, lead .. g.tee .. g.dash .. " ", nodeText(first), sub_guide .. " ")
        if first.children then
            renderChildren(first.children, sub_guide .. " ", out)
        end
    end
    for i = 2, #kids do
        renderChild(kids[i], guide, i == #kids, out)
    end
end

-- Escapes a string so it is safe to embed in the generated HTML.
local function escapeHtml(text)
    text = text:gsub("&", "&amp;")
    text = text:gsub("<", "&lt;")
    text = text:gsub(">", "&gt;")
    return text
end

-- Renders a whole parsed clade tree as one <pre>-ready string.
local function renderTree(root)
    root = foldNode(root)
    -- The outermost table is usually just the diagram's stem: a single
    -- unnamed child holding everything. Start from the first node that
    -- actually has something to say.
    while root.children and root.name == "" and #root.children == 1 do
        root = root.children[1]
    end
    local out = {}
    local title = nodeText(root)
    if title ~= "" then
        emitLines(out, "", title, "")
    end
    if root.children then
        renderChildren(root.children, "", out)
    end
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
        local root = { name = "", double = false,
                       children = parseCladeTable(html:sub(oe + 1, cs - 1)) }
        local rendered = renderTree(root)
        if rendered ~= "" then
            table.insert(out, '<pre class="wikireader-cladogram">' .. rendered .. '</pre>')
        end
        pos = ce + 1
    end
    return table.concat(out)
end

return M
