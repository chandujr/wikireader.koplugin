-- HTML cleaning utilities for WikiReader.
-- Strips/reorganises Wikipedia HTML elements that don't work well in a
-- reflowable EPUB (infoboxes, navboxes, image captions, hatnote boxes, etc.).

local wutil = require("wikiutil")

local M = {}

--[[-------------------------------------------------------------------------
Generic element stripping
--]]

-- Removes <tag ...>...</tag> blocks whose `attr_name` attribute matches
-- any of `attr_patterns`, handling same-tag elements nested inside them
-- (Lua patterns can't do balanced matching, so nesting depth is walked
-- by hand).
function M.stripElementsByAttr(html, tag, attr_name, attr_patterns)
    local open_pat = "<" .. tag .. "[^>]*>"
    local close_pat = "</" .. tag .. "%s*>"
    local attr_capture_pat = attr_name .. [[%s*=%s*"([^"]*)"]]
    local out = {}
    local pos = 1
    while true do
        local open_start, open_end = html:find(open_pat, pos)
        if not open_start then
            table.insert(out, html:sub(pos))
            break
        end
        local attr_value = html:sub(open_start, open_end):match(attr_capture_pat) or ""
        local matches = false
        for _, pat in ipairs(attr_patterns) do
            if attr_value:lower():find(pat, 1, true) then
                matches = true
                break
            end
        end
        if not matches then
            table.insert(out, html:sub(pos, open_end))
            pos = open_end + 1
        else
            table.insert(out, html:sub(pos, open_start - 1)) -- text before this element
            local depth = 1
            local scan_pos = open_end + 1
            while depth > 0 do
                local next_open_start, next_open_end = html:find(open_pat, scan_pos)
                local next_close_start, next_close_end = html:find(close_pat, scan_pos)
                if not next_close_start then
                    scan_pos = #html + 1 -- malformed: bail, drop the rest
                    break
                elseif next_open_start and next_open_start < next_close_start then
                    depth = depth + 1
                    scan_pos = next_open_end + 1
                else
                    depth = depth - 1
                    scan_pos = next_close_end + 1
                end
            end
            pos = scan_pos
        end
    end
    return table.concat(out)
end

-- Thin wrapper for the common case (matching on `class`).
function M.stripElementsByClass(html, tag, class_patterns)
    return M.stripElementsByAttr(html, tag, "class", class_patterns)
end

--[[-------------------------------------------------------------------------
Wikipedia article hyperlink removal ("Disable hyperlinks" option)
--]]

-- Returns true when an <a ...> open tag's href points at another Wikipedia
-- article (in this or any other language edition), or at a nonexistent one.
-- The raw Parsoid HTML handed to us by action=parse uses:
--   <a href="/wiki/Some_Title">          internal article links
--   <a href="https://xx.wikipedia.org/wiki/...">  cross-edition links
--   <a href="/w/index.php?title=X&action=edit&redlink=1"> dead (red) links
-- Everything else -- <a href="#cite_note-..."> reference/footnote anchors,
-- and genuine external http(s) links -- is deliberately NOT matched.
local function anchorIsWikiArticleLink(open_tag)
    local href = open_tag:match([[href%s*=%s*"([^"]*)"]])
    if not href then
        return false
    end
    if href:sub(1, 6) == "/wiki/" then
        return true
    end
    if href:find("^https?://%w+%.wikipedia%.org/wiki/") then
        return true
    end
    if href:find("redlink=1", 1, true) then
        return true
    end
    return false
end

-- Unwraps every <a> whose href points at another Wikipedia article,
-- keeping the anchor's inner content (the visible text, footnote marks,
-- images, ...) while dropping the clickable link itself. Reference and
-- footnote anchors (<a href="#cite_note-...">) and real external links
-- are left untouched. Valid HTML never nests <a> elements, but the same
-- depth walk used elsewhere guards against malformed markup anyway.
function M.stripArticleLinks(html)
    local out = {}
    local pos = 1
    while true do
        local open_start, open_end = html:find("<a%s[^>]*>", pos)
        if not open_start then
            table.insert(out, html:sub(pos))
            break
        end
        if anchorIsWikiArticleLink(html:sub(open_start, open_end)) then
            local close_start, close_end = wutil.findMatchingClose(html, "a", open_end)
            if not close_end then
                -- Unclosed anchor: drop just the open tag, keep what follows.
                table.insert(out, html:sub(pos, open_start - 1))
                pos = open_end + 1
            else
                -- Unwrap: emit everything except the <a ...> ... </a> tags.
                table.insert(out, html:sub(pos, open_start - 1))
                table.insert(out, html:sub(open_end + 1, close_start - 1))
                pos = close_end + 1
            end
        else
            -- Kept anchor: advance only past its open tag.
            table.insert(out, html:sub(pos, open_end))
            pos = open_end + 1
        end
    end
    return table.concat(out)
end

--[[-------------------------------------------------------------------------
Element class cleaning (keep element, remove/modify classes)
--]]

-- Removes specific classes and optionally transforms the style attribute on
-- elements whose class matches any of `class_patterns`, while keeping the
-- element and its content intact. This is useful for things like quote boxes
-- that have float classes (floatleft/floatright) and inline width styles that
-- break the reflowable layout.
--
-- `remove_style` can be:
--   - true: remove the entire style attribute
--   - a function: called with the current style value, returns the replacement
--   - false/nil: leave the style attribute untouched
function M.cleanElementClasses(html, tag, class_patterns, classes_to_remove, remove_style)
    local open_pat = "<" .. tag .. "[^>]*>"
    local out = {}
    local pos = 1
    while true do
        local open_start, open_end = html:find(open_pat, pos)
        if not open_start then
            table.insert(out, html:sub(pos))
            break
        end

        local open_tag = html:sub(open_start, open_end)
        local class_attr = open_tag:match([[class%s*=%s*"([^"]*)"]]) or ""
        local matches = false
        for _, pat in ipairs(class_patterns) do
            if class_attr:lower():find(pat, 1, true) then
                matches = true
                break
            end
        end

        if not matches then
            table.insert(out, html:sub(pos, open_end))
            pos = open_end + 1
        else
            local modified_tag = open_tag

            for _, cls in ipairs(classes_to_remove) do
                -- class="... cls ..." (middle of class list)
                modified_tag = modified_tag:gsub('(class%s*=%s*"[^"]*)%s' .. cls .. '(%s[^"]*")', '%1%2')
                -- class="cls ..." (start of class list)
                modified_tag = modified_tag:gsub('(class%s*=%s*")' .. cls .. '(%s[^"]*")', '%1%2')
                -- class="... cls" (end of class list)
                modified_tag = modified_tag:gsub('(class%s*=%s*"[^"]*)%s' .. cls .. '(")', '%1%2')
                -- class="cls" (only class)
                modified_tag = modified_tag:gsub('(class%s*=%s*")' .. cls .. '(")', '%1%2')
            end

            -- Handle the style attribute
            if remove_style == true then
                modified_tag = modified_tag:gsub('%s*style%s*=%s*"[^"]*"', '')
            elseif type(remove_style) == "function" then
                local style_attr = modified_tag:match('style%s*=%s*"[^"]*"')
                local style_val = style_attr and style_attr:match('style%s*=%s*"([^"]*)"') or ""
                local new_style = remove_style(style_val)
                if new_style and new_style ~= "" then
                -- Replace an existing style attribute in place, otherwise insert one.
                    if style_attr then
                        modified_tag = modified_tag:gsub('style%s*=%s*"[^"]*"', 'style="' .. new_style .. '"')
                    else
                        modified_tag = modified_tag:gsub('^(<[^>]+)', '%1 style="' .. new_style .. '"')
                    end
                end
            end

            modified_tag = modified_tag:gsub('%s+', ' ')
            modified_tag = modified_tag:gsub(' %s*>', '>')

            table.insert(out, html:sub(pos, open_start - 1))
            table.insert(out, modified_tag)
            pos = open_end + 1
        end
    end
    return table.concat(out)
end

--[[-------------------------------------------------------------------------
Media removal inside kept infobox tables and inline flags
--]]

-- Cleans the inside of a kept infobox table so it shows text only,
-- running before the QR pass. For each cell it:
--   * drops genuine media cells (image/figure/audio/video/kartographer
--     mapframe) along with their caption, so the box keeps only text data;
--   * removes small inline icon bubbles (flagicon spans and tiny <=24px
--     mw:File image icons, plus conservation-status badge banners) while
--     keeping the name/link/footnote text they sit beside;
--   * drops a standalone caption row that directly follows a dropped media
--     cell (Speciesbox/Autotaxobox render the image and its caption as two
--     separate full-width rows).
-- Nested tables are handled by a depth walk, so whole media-bearing
-- sub-regions (nested maps, symbol stacks) go away as one unit. Cells with
-- class "infobox-image"/"infobox-caption" are dropped even without media.
-- Only tables matching class_patterns are touched; everything else is
-- returned unchanged.
function M.stripImageCells(html, class_patterns)
    class_patterns = class_patterns or { "infobox" }
    local out = {}
    local pos = 1
    while true do
        local t_start, t_open_end = html:find("<table[^>]*>", pos)
        if not t_start then
            table.insert(out, html:sub(pos))
            break
        end
        local open_tag = html:sub(t_start, t_open_end)
        local class_attr = open_tag:match([[class%s*=%s*"([^"]*)"]]) or ""
        local matches = false
        for _, pat in ipairs(class_patterns) do
            if class_attr:lower():find(pat, 1, true) then
                matches = true
                break
            end
        end
        if not matches then
            table.insert(out, html:sub(pos, t_open_end))
            pos = t_open_end + 1
        else
            local close_start, close_end = wutil.findMatchingClose(html, "table", t_open_end)
            if not close_start then
                table.insert(out, html:sub(pos))
                break
            end
            table.insert(out, html:sub(pos, t_start - 1))
            table.insert(out, open_tag)
            table.insert(out, M.stripImageCellsInBlock(html:sub(t_open_end + 1, close_start - 1)))
            table.insert(out, html:sub(close_start, close_end))
            pos = close_end + 1
        end
    end
    return table.concat(out)
end

-- Removes small inline icon bubbles (flagicon spans, tiny mw:File images,
-- conservation-status badges) from `content` while keeping the name/link/
-- footnote text they sit beside. The discriminator is the <img> display
-- width: icons render at <=24px while genuine media (lead images, maps,
-- emblems) renders much larger or is a <table>/<figure>/<mapframe>/<video>
-- /<audio> box. CSS classes can't tell them apart: a flag's
-- <span typeof="mw:File"> wraps the same mw-file-description link as a
-- real thumbnail. Exposed for testing.
function M.removeInlineIcons(content)
    local out = {}
    local pos = 1
    while true do
        local open_start = content:find("<span", pos, true)
        if not open_start then
            table.insert(out, content:sub(pos))
            break
        end
        local open_end = content:find(">", open_start, true)
        if not open_end then
            table.insert(out, content:sub(pos))
            break
        end
        local lower = content:sub(open_start, open_end):lower()

        -- flagicon spans are always icons; mw:File spans are icons only
        -- when their <img> renders small (<=24px); genuine figure boxes are
        -- left intact for cellHasMedia to see.
        local iconish = false
        if lower:find("flagicon", 1, true) then
            iconish = true
        elseif lower:find('typeof%s*=%s*"mw:file', 1) then
            local _, close_end = wutil.findMatchingClose(content, "span", open_end)
            if close_end then
                local inner = content:sub(open_end + 1, close_end - 1)
                local imgw = M.imgDisplayWidth(inner)
                iconish = (imgw ~= nil and imgw <= 24)
                    or M.isStatusBadgeImg(inner)
            else
                -- Unclosed: treat as an icon, drop just the open tag.
                iconish = true
            end
        end

        if iconish then
            local _, close_end = wutil.findMatchingClose(content, "span", open_end)
            if not close_end then
                -- Unclosed: drop just the open tag.
                table.insert(out, content:sub(pos, open_end))
                pos = open_end + 1
            else
                table.insert(out, content:sub(pos, open_start - 1))
                pos = close_end + 1
            end
        else
            -- Not an icon: keep it, advancing only past the open tag so
            -- nested icons (e.g. a flagicon inside <span class="nowrap">)
            -- are still found.
            table.insert(out, content:sub(pos, open_end))
            pos = open_end + 1
        end
    end
    return table.concat(out)
end

-- Rendered display width of the first <img ...> box in `s`, or nil if
-- there is no <img> or no width= attribute on it. Only the width=
-- attribute (set by MediaWiki on the rendered image) counts;
-- data-file-width/srcset carry the source pixel size.
function M.imgDisplayWidth(s)
    local img = s:find("<img", 1, true)
    if not img then return nil end
    local close = s:find(">", img, true)
    if not close then return nil end
    local tag = s:sub(img, close)
    local _, _, w = tag:find('width%s*=%s*"(%d+)"%s+height')
    if not w then
        -- some images omit height
        _, _, w = tag:find('width%s*=%s*"(%d+)"')
    end
    return tonumber(w)
end

-- True when `s` holds a conservation-status badge banner (a wide colored
-- "Status_*.svg" bar that {{Conservation status}} puts above each status
-- line in Speciesbox/Taxobox rows). It duplicates the status text link
-- right below it, so it is dropped like an inline icon; matched by image
-- path, not size (it renders at 250px, beyond the <=24px heuristic).
-- Exposed for testing.
function M.isStatusBadgeImg(s)
    local src = s:lower():match('src%s*=%s*"([^"]*)"')
    return src ~= nil and src:find("/status_", 1, true) ~= nil
end

-- True when the HTML `gap` between two cells holds only whitespace and
-- row/table-section boundaries, i.e. the cells are adjacent. A <th> is
-- never crossed: a section-header row breaks the caption relationship.
-- Exposed for testing.
function M.directlyFollowsCell(gap)
    local bare = gap:gsub("</?t[rb][a-z]*[^<>]*>", ""):gsub("%s", "")
    return bare == ""
end

-- True when `open_tag` / `content` describe a Speciesbox/Taxobox-style
-- standalone caption cell: the full-width <td> that Module:Taxobox puts in
-- its own row directly below an image row, styled either inline
-- ("text-align:center" at a reduced font size) or, in newer renderings,
-- via class="image-section". Requires: colspan (never fires on label/value
-- cells), that caption styling, no nested table inside (war infoboxes wrap
-- their data table in such a full-width cell -- those must stay), and no
-- media left (a real image cell keeps its own caption). Matched by
-- style/class because Taxobox gives the cell no infobox-image/-caption
-- class. Exposed for testing.
function M.isCaptionOnlyCell(open_tag, content)
    open_tag = open_tag:lower()
    if not open_tag:find("colspan") then
        return false
    end
    local style = open_tag:match([[style%s*=%s*"([^"]*)"]]) or ""
    local size = style:match("font%-size%s*:%s*(%d+)%%")
    local styled_caption = size ~= nil
        and tonumber(size) < 100
        and style:find("text%-align%s*:%s*center") ~= nil
    if not styled_caption and not open_tag:find("image%-section") then
        return false
    end
    content = content:lower()
    if content:find("<table", 1, true) or M.cellHasMedia(content) then
        return false
    end
    return true
end

-- True when a cell (after inline icons were removed) still holds genuine
-- media: a large (>24px) <img>, a <table> image box, <figure>, a
-- kartographer <mapframe>, or <video>/<audio>. Such cells are dropped
-- whole; anything else is inline-icon-free text and is kept.
function M.cellHasMedia(content)
    if content:find("<video", 1, true)
        or content:find("<audio", 1, true)
        or content:find("<figure", 1, true)
        or content:find("<mapframe", 1, true) then
        return true
    end
    local pos = 1
    while true do
        local img = content:find("<img", pos, true)
        if not img then break end
        local close = content:find(">", img, true)
        if close then
            local w = content:sub(img, close):match('width%s*=%s*"(%d+)"')
            if not w then
                -- MediaWiki always sets width on a rendered image; a bare
                -- <img ...> without it is unusual -- treat as media.
                return true
            end
            if tonumber(w) > 24 then
                return true
            end
        end
        pos = (close or img) + 1
    end
    return false
end
-- Inner helper: given the content between the <table ...> and </table> of
-- a matching table, drop the media from genuine image/caption cells, but
-- keep the text (names, links, footnotes, ...) of cells that merely carry
-- a small inline flag beside their real content. Exposed for testing.
function M.stripImageCellsInBlock(block)
    local out = {}
    local pos = 1
    -- Set when a genuine media cell has just been dropped: a Speciesbox-style
    -- standalone caption cell directly following it describes that lost
    -- image, so it is dropped with it.
    local media_dropped = false
    while true do
        local open_start, open_end = block:find("<td[^>]*>", pos)
        if not open_start then
            table.insert(out, block:sub(pos))
            break
        end
        local close_start, close_end = wutil.findMatchingClose(block, "td", open_end)
        if not close_start then
            table.insert(out, block:sub(pos))
            break
        end
        local open_tag = block:sub(open_start, open_end)
        local cell_class = (open_tag:match([[class%s*=%s*"([^"]*)"]]) or ""):lower()
        local content = block:sub(open_end + 1, close_start - 1)

        -- Remove inline icon bubbles first (flags, status badges, ...):
        -- the surrounding name/number/status text stays.
        local stripped = M.removeInlineIcons(content)
        -- Removing a leading icon can strand the <br /> that separated it
        -- from the following text. Drop ONLY those stranded breaks: bare
        -- wrapper tags (<div>/<span>/<p>/<center>) are crossed but kept,
        -- any other tag (media elements especially) stops the scan, so
        -- genuine media cells are untouched.
        if stripped ~= content then
            local pos = 1
            while true do
                local _, ws_end = stripped:find("^%s*", pos)
                pos = ws_end + 1
                -- The () position capture is the second (and last) value
                -- returned, right behind the captured tag text.
                local inner, after_tag = stripped:match("^<([^<>]*)>()", pos)
                if not inner then break end
                local name = inner:lower():match("^%s*(%a+)")
                if name == "br" then
                    -- Drop just this break; rescan from the same position.
                    stripped = stripped:sub(1, pos - 1) .. stripped:sub(after_tag)
                elseif name == "div" or name == "span" or name == "p"
                    or name == "center" then
                    pos = after_tag -- cross the bare wrapper tag, keep it
                else
                    break -- anything else (media, close tags, text): stop
                end
            end
        end

        local drop_cell = cell_class:find("infobox-image", 1, true)
            or cell_class:find("infobox-caption", 1, true)
            or M.cellHasMedia(stripped:lower())

        if drop_cell then
            table.insert(out, block:sub(pos, open_start - 1))
            media_dropped = true
        elseif media_dropped
            and M.directlyFollowsCell(block:sub(pos, open_start - 1))
            and M.isCaptionOnlyCell(open_tag, stripped) then
            -- Orphaned standalone caption of the image cell just dropped
            -- (Speciesbox/Autotaxobox image rows): gone with its image.
            table.insert(out, block:sub(pos, open_start - 1))
            media_dropped = false
        else
            media_dropped = false
            -- Icon-only row: drop the empty cell; keep the text cell otherwise.
            local plain = stripped:gsub("<[^>]*>", ""):gsub("&[^;]+;", ""):gsub("%s", "")
            if plain == "" then
                table.insert(out, block:sub(pos, open_start - 1))
            else
                table.insert(out, block:sub(pos, open_start - 1))
                table.insert(out, open_tag)
                table.insert(out, stripped)
                table.insert(out, block:sub(close_start, close_end))
            end
        end
        pos = close_end + 1
    end
    -- Dropped cells leave empty <tr></tr> rows behind; remove them so
    -- they don't add stray spacing in the reflowed layout.
    local result = table.concat(out)
    return (result:gsub("<tr[^>]*>%s*</tr%s*>", ""))
end

--[[-------------------------------------------------------------------------
Element infobox periodic-table diagram
--]]

-- The {{Infobox element}} "X in the periodic table" block is a
-- TemplateStyles-styled diagram: a 32-column "micro" table of 6px-wide
-- colored cells plus symbol/neighbor divs, laid out entirely with CSS
-- (border-spacing, empty-cells, floats) that crengine ignores. In the
-- reflowed EPUB it collapses into ~120 unstyled cells in an overflowing
-- row. Removed together with the infobox-header row introducing it, so no
-- dangling "X in the periodic table" header stays behind. Header detection
-- is structural (the single .infobox-header row directly above), never
-- textual, so it works on non-English wikis too.
function M.stripElementPeriodicTable(html)
    local out = {}
    local pos = 1
    while true do
        local d_start, d_end = html:find("<div[^>]*>", pos)
        if not d_start then
            table.insert(out, html:sub(pos))
            break
        end
        local class_attr = html:sub(d_start, d_end):match([[class%s*=%s*"([^"]*)"]]) or ""
        local d_close_start, d_close_end
        if class_attr:lower():find("ib-element-periodic-table", 1, true) then
            d_close_start, d_close_end = wutil.findMatchingClose(html, "div", d_end)
        end
        if not d_close_start then
            table.insert(out, html:sub(pos, d_end))
            pos = d_end + 1
        else
            local remove_start, remove_end = d_start, d_close_end
            -- Row holding the diagram: the last <tr> opened before the div.
            -- Requiring a <td> (and no </tr>) in that span rules out stray
            -- "<tr..."-prefixed tags and ensures the div sits in that row.
            local before = html:sub(pos, d_start - 1)
            local row_rel = before:match(".*()<tr[^>]*>")
            local row_text = row_rel and before:sub(row_rel)
            if row_text and row_text:find("<td", 1, true)
                and not row_text:find("</tr", 1, true) then
                -- Header row introducing the diagram: must close right
                -- before this row (only whitespace between) and hold a
                -- single .infobox-header <th>.
                local prev_close_rel = before:sub(1, row_rel - 1):match(".*()</tr%s*>%s*$")
                local prev_open_rel = prev_close_rel
                    and before:sub(1, prev_close_rel):match(".*()<tr[^>]*>")
                local th_open = prev_open_rel
                    and before:sub(prev_open_rel):match("^<tr[^>]*>%s*(<th[^>]*>)")
                local prev_row = prev_open_rel
                    and before:sub(prev_open_rel, prev_close_rel - 1)
                if th_open and th_open:lower():find("infobox-header", 1, true)
                    and prev_row and not prev_row:find("<td", 1, true) then
                    remove_start = pos + prev_open_rel - 1
                end
            end
            -- Removal ends at the </tr> closing the diagram's row.
            local row_close_start, row_close_end = html:find("</tr%s*>", d_close_end + 1)
            if row_close_start then
                remove_end = row_close_end
            end
            table.insert(out, html:sub(pos, remove_start - 1))
            pos = remove_end + 1
        end
    end
    return table.concat(out)
end

--[[-------------------------------------------------------------------------
Infobox cell alignment
--]]

-- Appends a CSS declaration to a tag's inline style attribute, inserting
-- the attribute when missing. Returns the modified tag. Function-based
-- gsub replacement on purpose: the existing style text may contain %
-- (e.g. font-size:80%) and gsub function results are never %-re-parsed.
function M.addInlineStyle(tag, decl)
    if tag:match('style%s*=%s*"[^"]*"') then
        return (tag:gsub('(style%s*=%s*")([^"]*)(")', function(prefix, value, suffix)
            if value == "" or value:match(';%s*$') then
                return prefix .. value .. decl .. suffix
            end
            return prefix .. value .. ";" .. decl .. suffix
        end))
    end
    -- No style attribute: insert one right after the tag name. decl must
    -- not contain % (plain gsub replacement would eat % escapes).
    return (tag:gsub('^(<[^%s>]+)', '%1 style="' .. decl .. '"'))
end

-- Centers the full-width cells of kept infoboxes (.infobox-title/above/
-- header/subheader/image/full-data/below), mirroring Wikipedia's own
-- stylesheet. Done as an inline style because that reliably applies in
-- crengine: the base EPUB stylesheet has no .infobox rules at all, and
-- crengine ignores descendant selectors in the EPUB stylesheet, so a
-- ".infobox .infobox-title" rule never matches. Cells already carrying
-- an explicit text-align declaration are left alone.
function M.centerInfoboxCells(html)
    return (html:gsub('(<t[dh][^>]*class%s*=%s*"([^"]*)"[^>]*>)', function(tag, classes)
        if not (classes:find("infobox%-title", 1)
            or classes:find("infobox%-above", 1)
            or classes:find("infobox%-header", 1)
            or classes:find("infobox%-subheader", 1)
            or classes:find("infobox%-image", 1)
            or classes:find("infobox%-full%-data", 1)
            or classes:find("infobox%-below", 1)) then
            return tag
        end
        local style_attr = tag:match('style%s*=%s*"[^"]*"')
        if style_attr and style_attr:find('text%-align%s*:') then
            return tag -- explicit alignment wins
        end
        return M.addInlineStyle(tag, "text-align:center")
    end))
end

-- Tables that render as bordered grids: kept infoboxes and wikitables
-- (Wikipedia's own bordered data tables). Other tables in article HTML are
-- layout or message boxes and are left alone.
local function isBorderedTableClass(class_attr)
    local lower = class_attr:lower()
    return lower:find("infobox", 1, true) ~= nil
        or lower:find("wikitable", 1, true) ~= nil
end

-- Borders kept infobox and wikitable tables as grids: outer edge
-- (#a2a9b1, Wikipedia's infobox/table gray) + border-collapse on the
-- <table>, thin #ccc separators on every cell. All inline, because
-- crengine ignores descendant selectors in the EPUB stylesheet (the same
-- reason centerInfoboxCells works inline): a CSS ".wikitable td" rule
-- never matches, and injected stylesheet rules vanish entirely when the
-- user disables "Embedded Style". Nested-table cells are included:
-- embedded layout/data tables read as part of the grid. Exposed for testing.
function M.borderTableCells(html)
    local out = {}
    local pos = 1
    while true do
        local t_start, t_open_end = html:find("<table[^>]*>", pos)
        if not t_start then
            table.insert(out, html:sub(pos))
            break
        end
        local open_tag = html:sub(t_start, t_open_end)
        local class_attr = open_tag:match([[class%s*=%s*"([^"]*)"]]) or ""
        local close_start, close_end
        if isBorderedTableClass(class_attr) then
            close_start, close_end = wutil.findMatchingClose(html, "table", t_open_end)
        end
        if not close_start then
            table.insert(out, html:sub(pos, t_open_end))
            pos = t_open_end + 1
        else
            table.insert(out, html:sub(pos, t_start - 1))
            table.insert(out, M.addInlineStyle(open_tag,
                "border:1px solid #a2a9b1;border-collapse:collapse"))
            table.insert(out, (html:sub(t_open_end + 1, close_start - 1):gsub(
                '(<t[dh][^>]*>)', function(tag)
                    return M.addInlineStyle(tag, "border:1px solid #ccc")
                end)))
            table.insert(out, html:sub(close_start, close_end))
            pos = close_end + 1
        end
    end
    return table.concat(out)
end

--[[-------------------------------------------------------------------------
Quote attribution (Template:Quote) merging
--]]

-- MediaWiki renders Template:Quote / Template:Blockquote as a <blockquote>
-- immediately followed by a sibling <div class="templatequotecite"> holding
-- the attribution line. Left outside the blockquote, that line dangles
-- unstyled below the quote box in the reflowed EPUB, so this moves it
-- *inside* the blockquote as a trailing <div class="wikireader-cite">
-- (right-aligned attribution line, styled by the EPUB stylesheet).
--
-- MediaWiki output handled here looks like:
--   <blockquote class="templatequote"><p>...</p></blockquote>
--   <div class="templatequotecite"><p style="display:inline;padding-left:2.3em;">— Person</p></div>
function M.mergeQuoteCites(html)
    local function skipWs(pos)
        local _, e = html:find('^%s*', pos)
        return (e or pos - 1) + 1
    end

    local out = {}
    local pos = 1
    while true do
        local bq_start, bq_open_end = html:find('<blockquote[^>]*>', pos)
        if not bq_start then
            table.insert(out, html:sub(pos))
            break
        end
        local bq_close_start, bq_close_end = wutil.findMatchingClose(html, "blockquote", bq_open_end)
        if not bq_close_start then
            table.insert(out, html:sub(pos))
            break
        end

        -- The attribution div must directly follow </blockquote> for it to
        -- belong to this quote.
        local after_close = skipWs(bq_close_end + 1)
        local cite_open_start, cite_open_end = html:find('<div class="templatequotecite">', after_close)
        if cite_open_start ~= after_close then
            table.insert(out, html:sub(pos, bq_close_end))
            pos = bq_close_end + 1
        else
            local cite_close_start, cite_close_end = wutil.findMatchingClose(html, "div", cite_open_end)
            if not cite_close_end then
                table.insert(out, html:sub(pos, bq_close_end))
                pos = bq_close_end + 1
            else
                local cite_content = html:sub(cite_open_end + 1, cite_close_start - 1)
                -- Drop the web-layout inline style on the inner <p>.
                cite_content = cite_content:gsub('(<p[^>]*%s)style%s*=%s*"[^"]*"', '%1')
                cite_content = cite_content:gsub('<p style="[^"]*">', '<p>')
                cite_content = cite_content:gsub('<p%s+>', '<p>')

                table.insert(out, html:sub(pos, bq_start - 1))
                table.insert(out, html:sub(bq_start, bq_open_end))
                table.insert(out, html:sub(bq_open_end + 1, bq_close_start - 1))
                table.insert(out, '<div class="wikireader-cite">' .. cite_content .. '</div>')
                table.insert(out, '</blockquote>')
                pos = cite_close_end + 1
            end
        end
    end
    return table.concat(out)
end

--[[-------------------------------------------------------------------------
Leading notice (hatnote / maintenance banner) extraction
--]]

local function elementIsLeadingNotice(open_tag)
    local class_attr = open_tag:match([[class%s*=%s*"([^"]*)"]]) or ""
    local typeof_attr = open_tag:match([[typeof%s*=%s*"([^"]*)"]]) or ""
    local combined = (class_attr .. " " .. typeof_attr):lower()
    for _, pat in ipairs(wutil.LEADING_NOTICE_PATTERNS) do
        if combined:find(pat, 1, true) then
            return true
        end
    end
    return false
end

-- Skips whitespace, HTML comments, <style>/<link>/<meta> tags and empty
-- <p></p> elements sitting at `pos`: real Wikipedia HTML interleaves
-- <style>/<link> between sibling hatnotes for CSS deduplication, and
-- MediaWiki emits empty <p class="mw-empty-elt"> spacing artifacts
-- around templates.
local function skipLeadingCruft(html, pos)
    while true do
        local start_pos = pos
        local _, ws_end = html:find("^%s*", pos)
        pos = (ws_end or pos - 1) + 1
        local c_start, c_end = html:find("^<!%-%-.-%-%->", pos)
        if c_start then pos = c_end + 1 end
        local s_start, s_end = html:find("^<style[^>]*>.-</style%s*>", pos)
        if s_start then pos = s_end + 1 end
        local l_start, l_end = html:find("^<link[^>]*/?>", pos)
        if l_start then pos = l_end + 1 end
        local m_start, m_end = html:find("^<meta[^>]*/?>", pos)
        if m_start then pos = m_end + 1 end
        local p_start, p_end = html:find("^<p[^>]*>%s*</p%s*>", pos)
        if p_start then pos = p_end + 1 end
        if pos == start_pos then
            return pos
        end
    end
end

local function extractLeadingNoticesInner(html)
    local pos = skipLeadingCruft(html, 1)
    local notices = {}
    while true do
        local matched_tag, open_start, open_end
        for _, tag in ipairs(wutil.LEADING_NOTICE_TAGS) do
            local o_start, o_end = html:find("^<" .. tag .. "[^>]*>", pos)
            if o_start and elementIsLeadingNotice(html:sub(o_start, o_end)) then
                matched_tag, open_start, open_end = tag, o_start, o_end
                break
            end
        end
        if not matched_tag then
            break
        end
        local close_start, close_end = wutil.findMatchingClose(html, matched_tag, open_end)
        if not close_end then
            return table.concat(notices), html:sub(pos)
        end
        table.insert(notices, html:sub(pos, close_end))
        pos = skipLeadingCruft(html, close_end + 1)
    end
    return table.concat(notices), html:sub(pos)
end

-- Pulls any hatnotes/maintenance-template elements sitting right at the
-- very start of the article HTML out into their own string, leaving
-- everything from the genuine first paragraph/heading onward in a
-- second string. Only looks at the front of the document.
--
-- Both MediaWiki parsers wrap the entire article body in
-- <div class="mw-parser-output">, whose class matches none of our notice
-- patterns -- so the scan must look inside that wrapper (leaving its
-- opening/closing tags in the output) to find anything at all.
function M.extractLeadingNotices(html)
    local wrap_open_start, wrap_open_end = html:find('^<div[^>]-class="[^"]*mw%-parser%-output[^"]*"[^>]*>')
    if not wrap_open_start then
        return extractLeadingNoticesInner(html)
    end
    local wrap_close_start = wutil.findMatchingClose(html, "div", wrap_open_end)
    if not wrap_close_start then
        return extractLeadingNoticesInner(html)
    end
    local prefix = html:sub(1, wrap_open_end)
    local inner = html:sub(wrap_open_end + 1, wrap_close_start - 1)
    local suffix = html:sub(wrap_close_start)
    local notices, rest = extractLeadingNoticesInner(inner)
    return notices, prefix .. rest .. suffix
end

-- Wraps section-level notices (hatnotes, maintenance banners) not caught
-- by extractLeadingNotices() -- e.g. "This section needs more citations..."
-- in <div class="wikireader-notices"> boxes. Deliberately a second pass
-- on the "rest" HTML, so front-of-article notices aren't double-wrapped.
function M.wrapSectionNotices(html)
    local pos = 1
    local out = {}
    while true do
        local matched_tag, open_start, open_end
        for _, tag in ipairs(wutil.LEADING_NOTICE_TAGS) do
            local o_start, o_end = html:find("<" .. tag .. "[^>]*>", pos)
            if o_start and (not open_start or o_start < open_start) then
                open_start, open_end = o_start, o_end
                matched_tag = tag
            end
        end
        if not open_start then
            table.insert(out, html:sub(pos))
            break
        end
        local open_tag = html:sub(open_start, open_end)
        if elementIsLeadingNotice(open_tag) then
            table.insert(out, html:sub(pos, open_start - 1))
            local close_start, close_end = wutil.findMatchingClose(html, matched_tag, open_end)
            if not close_end then
                table.insert(out, html:sub(open_start))
                break
            end
            local notice_content = html:sub(open_start, close_end)
            table.insert(out, string.format(
                [[<div class="wikireader-notices">%s</div>]],
                notice_content
            ))
            pos = close_end + 1
        else
            table.insert(out, html:sub(pos, open_end))
            pos = open_end + 1
        end
    end
    return table.concat(out)
end

--[[-------------------------------------------------------------------------
Template:Multiple image restructuring
--]]

-- Wikipedia's {{Multiple image}} lays its images out side-by-side with CSS
-- flexbox (.trow { display:flex; flex-direction:row } in a TemplateStyles
-- <style> block). crengine (KOReader's EPUB engine) has no flexbox, so in
-- the reflowed EPUB the images stack into a single left-aligned column --
-- even though the box is a fixed narrow width (e.g. 492px) with plenty of
-- room to its right. Real <table> markup IS first-class in crengine, so we
-- rewrite the box into a table: the .thumbinner container becomes the
-- <table>, each .trow a <tr>, each .tsingle a <td>, and the optional
-- .theader / overall .thumbcaption rows become full-width cells.
-- See M.restructureMultiImages.

local function tokenInClass(cls, token)
    for w in cls:gmatch("[^%s]+") do
        if w == token then
            return true
        end
    end
    return false
end

-- Lowercased value of the tag's class attribute, or "".
local function openTagClass(open_tag)
    return (open_tag:match([[class%s*=%s*"([^"]*)"]]) or ""):lower()
end

-- Appends `prop` (e.g. "vertical-align:top") to the tag's style attribute,
-- creating one if the tag has none. Uses a function replacement so any %
-- inside the existing style value is never re-parsed as a gsub pattern.
local function addStyleProp(tag, prop)
    local style_attr = tag:match('style%s*=%s*"[^"]*"')
    if style_attr then
        local out = tag:gsub('(style%s*=%s*")([^"]*)(")', function(prefix, value, suffix)
            if value == "" then
                return prefix .. prop .. suffix
            end
            return prefix .. value .. ";" .. prop .. suffix
        end)
        return out
    end
    local out = tag:gsub('^(<[^%s>]+)', "%1 style=\"" .. prop .. "\"")
    return out
end

-- Column count of the widest .trow inside a multi-image box: the colspan
-- the full-width rows (.theader, optional overall .thumbcaption) need.
local function multiImageColumnCount(inner)
    local max_cols = 1
    local pos = 1
    while true do
        local o_start, o_end = inner:find('<div[^>]*>', pos)
        if not o_start then break end
        local cls = openTagClass(inner:sub(o_start, o_end))
        local c_start = wutil.findMatchingClose(inner, "div", o_end)
        if tokenInClass(cls, "trow") and c_start then
            local n = 0
            for _ in inner:sub(o_start, c_start):gmatch('class%s*=%s*"[^"]*tsingle[^"]*"') do
                n = n + 1
            end
            if n > max_cols then max_cols = n end
            pos = c_start + 1
        elseif c_start then
            pos = c_start + 1
        else
            break
        end
    end
    return max_cols
end

-- Rewrites the inside of one <tr> (the content of a .trow div): every
-- tsingle div becomes <td> (keeping its inline width), every theader div a
-- full-width centered <td colspan=N>. Everything else -- the
-- thumbimage/thumbcaption divs nested inside a tsingle, QR markers, links,
-- text -- passes through untouched.
local function multiImageTransformRow(content, n_cols)
    local out = {}
    local pos = 1
    while true do
        local o_start, o_end = content:find("<div[^>]*>", pos)
        if not o_start then
            table.insert(out, content:sub(pos))
            break
        end
        table.insert(out, content:sub(pos, o_start - 1))
        local open_tag = content:sub(o_start, o_end)
        local cls = openTagClass(open_tag)
        local c_start, c_end = wutil.findMatchingClose(content, "div", o_end)
        if not c_start then
            table.insert(out, content:sub(o_start))
            break
        end
        local inner = content:sub(o_end + 1, c_start - 1)
        if tokenInClass(cls, "tsingle") then
            local td = open_tag:gsub("^<div([ >])", "<td%1")
                -- The template's embedded TemplateStyles (which crengine
                -- applies) floats .tsingle boxes left and, in its small-
                -- screen media query, left-aligns their .thumbcaption --
                -- the rewrite already provides the alignment via the
                -- table's text-align:center, so the class must not survive.
                :gsub('%s*class%s*=%s*"[^"]*"', '')
            table.insert(out, addStyleProp(td, "vertical-align:top"))
            table.insert(out, inner)
            table.insert(out, "</td>")
        elseif tokenInClass(cls, "theader") then
            local td_open = '<td colspan="' .. n_cols .. '"'
            local cell_style = open_tag:match('style%s*=%s*"([^"]*)"')
            if cell_style and cell_style ~= "" then
                td_open = td_open .. ' style="' .. cell_style .. ";text-align:center;font-weight:bold\""
            else
                td_open = td_open .. ' style="text-align:center;font-weight:bold"'
            end
            table.insert(out, td_open .. ">")
            table.insert(out, inner)
            table.insert(out, "</td>")
        elseif tokenInClass(cls, "thumbcaption") then
            -- The box's overall caption, emitted in its own .trow div:
            -- span the whole row (a bare <div> in a <tr> is invalid HTML).
            local td_open = '<td colspan="' .. n_cols .. '"'
            local cell_style = open_tag:match('style%s*=%s*"([^"]*)"')
            if cell_style and cell_style ~= "" then
                td_open = td_open .. ' style="' .. cell_style .. ";text-align:center\""
            else
                td_open = td_open .. ' style="text-align:center"'
            end
            table.insert(out, td_open .. ">")
            table.insert(out, inner)
            table.insert(out, "</td>")
        else
            -- Unknown div directly inside a row (shouldn't happen): keep intact.
            table.insert(out, content:sub(o_start, c_end))
        end
        pos = c_end + 1
    end
    return table.concat(out)
end

-- Rewrites the content of a multi-image box's .thumbinner (now a <table>):
-- each top-level .trow div becomes <tr>, the optional overall
-- .thumbcaption becomes a full-width footer row, everything else passes
-- through.
local function multiImageTransformRows(inner, n_cols)
    local out = {}
    local pos = 1
    while true do
        local _, ws_end = inner:find("^%s*", pos)
        pos = (ws_end or pos - 1) + 1
        local o_start, o_end = inner:find("<div[^>]*>", pos)
        if not o_start then
            table.insert(out, inner:sub(pos))
            break
        end
        table.insert(out, inner:sub(pos, o_start - 1))
        local cls = openTagClass(inner:sub(o_start, o_end))
        local c_start, c_end = wutil.findMatchingClose(inner, "div", o_end)
        if not c_start then
            table.insert(out, inner:sub(o_start))
            break
        end
        local content = inner:sub(o_end + 1, c_start - 1)
        if tokenInClass(cls, "trow") then
            table.insert(out, "<tr>")
            table.insert(out, multiImageTransformRow(content, n_cols))
            table.insert(out, "</tr>")
        elseif tokenInClass(cls, "thumbcaption") then
            -- Overall caption of the whole box: a full-width footer row.
            table.insert(out, '<tr><td colspan="' .. n_cols .. '">')
            table.insert(out, content)
            table.insert(out, "</td></tr>")
        else
            table.insert(out, inner:sub(o_start, c_end))
        end
        pos = c_end + 1
    end
    return table.concat(out)
end

-- Rewrites one <div class="thumb tmulti ...">...</div> block into the same
-- wrapper div holding a <table> built from its .thumbinner content. Returns
-- the block unchanged (but harmless) if the structure isn't what we expect.
local function multiImageToTable(wrapper)
    local o_start, o_end = wrapper:find("^<div[^>]*>")
    if not o_start then
        return wrapper
    end
    local wrapper_open = wrapper:sub(o_start, o_end)
    local ti_start, ti_end = wrapper:find("<div[^>]*>", o_end)
    if not ti_start
        or not tokenInClass(openTagClass(wrapper:sub(ti_start, ti_end)), "thumbinner") then
        return wrapper
    end
    local ti_close_start, ti_close_end = wutil.findMatchingClose(wrapper, "div", ti_end)
    if not ti_close_start then
        return wrapper
    end
    local ti_open = wrapper:sub(ti_start, ti_end)
    local table_open = ti_open:gsub("^<div([ >])", "<table%1")
        :gsub([[class%s*=%s*"[^"]*"]], 'class="wikireader-tmulti"', 1)
    local inner = wrapper:sub(ti_end + 1, ti_close_start - 1)
    local n_cols = multiImageColumnCount(inner)
    local rows = multiImageTransformRows(inner, n_cols)
    return wrapper_open
        .. wrapper:sub(o_end + 1, ti_start - 1)
        .. table_open
        .. rows
        .. "</table>"
        .. wrapper:sub(ti_close_end + 1)
end

-- Rewrites every {{Multiple image}} box (recognised by the container
-- div's "tmulti" class token) into a <table> (see the section comment
-- above). Unexpected structures are returned unchanged, so it degrades
-- gracefully.
-- Removes the mw-halign-left/right/center alignment classes from <figure>
-- elements. The base stylesheet targets left/right-aligned figures with
-- class-carrying selectors that float them (web render mode) and gives
-- centered ones wide margins -- rules that outrank the injected
-- attribute-only selectors in the cascade, so the full-width figure box
-- (which makes the article's own alignment meaningless in a single-column
-- reflowable layout) could not be styled reliably.
function M.stripFigureHalign(html)
    return html:gsub('(<figure[^>]-class%s*=%s*")([^"]*)(")', function(prefix, cls, suffix)
        return prefix .. cls:gsub('%s*mw%-halign%-%a+', '') .. suffix
    end)
end

function M.restructureMultiImages(html)
    local out = {}
    local pos = 1
    while true do
        local o_start, o_end = html:find("<div[^>]*>", pos)
        if not o_start then
            table.insert(out, html:sub(pos))
            break
        end
        local open_tag = html:sub(o_start, o_end)
        local cls = openTagClass(open_tag)
        if tokenInClass(cls, "tmulti") then
            local c_start, c_end = wutil.findMatchingClose(html, "div", o_end)
            if c_start then
                table.insert(out, html:sub(pos, o_start - 1))
                table.insert(out, multiImageToTable(html:sub(o_start, c_end)))
                pos = c_end + 1
            else
                table.insert(out, html:sub(pos, o_end))
                pos = o_end + 1
            end
        else
            table.insert(out, html:sub(pos, o_end))
            pos = o_end + 1
        end
    end
    return table.concat(out)
end

return M
