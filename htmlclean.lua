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
-- Matches hrefs in both raw and entity-encoded form: Parsoid escapes
-- "&" as "&amp;" (e.g. "action=edit&redlink=1" -> "action=edit&amp;redlink=1").
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
    if href:find("redlink=1", 1, true) or href:find("action=edit", 1, true) then
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

-- Unwraps every <a> inside "noprint" sups: the inline maintenance
-- markers ([citation needed], [unreliable medical source], ...), all
-- <sup class="noprint Inline-Template ...">, whose links lead to editor
-- pages (Wikipedia:Citation_needed, action=edit URLs) that are
-- meaningless for readers. Always unwrapped, regardless of the
-- hyperlinks setting; the visible text stays.
function M.stripMaintenanceLinks(html)
    local out = {}
    local pos = 1
    while true do
        local open_start, open_end = html:find("<sup[^>]*>", pos)
        if not open_start then
            table.insert(out, html:sub(pos))
            break
        end
        local open_tag = html:sub(open_start, open_end)
        local class = open_tag:match([[class%s*=%s*"([^"]*)"]]) or ""
        if class:find("noprint", 1, true) then
            local close_start, close_end = wutil.findMatchingClose(html, "sup", open_end)
            if not close_end then
                table.insert(out, html:sub(pos, open_end))
                pos = open_end + 1
            else
                table.insert(out, html:sub(pos, open_start - 1))
                table.insert(out, open_tag)
                table.insert(out, M.stripArticleLinks(html:sub(open_end + 1, close_start - 1)))
                table.insert(out, html:sub(close_start, close_end))
                pos = close_end + 1
            end
        else
            table.insert(out, html:sub(pos, open_end))
            pos = open_end + 1
        end
    end
    return table.concat(out)
end

-- Unwraps the "[edit]" links MediaWiki puts in <span class="mw-editsection">
-- beside every heading. The span and brackets/text are kept (the anchor
-- itself is unwrapped by stripArticleLinks' action=edit/redlink match),
-- so headings keep their normal shape.
function M.stripEditSectionLinks(html)
    local out = {}
    local pos = 1
    while true do
        local open_start, open_end = html:find('<span[^>]*class="mw%-editsection"[^>]*>', pos)
        if not open_start then
            table.insert(out, html:sub(pos))
            break
        end
        local close_start, close_end = wutil.findMatchingClose(html, "span", open_end)
        if not close_end then
            table.insert(out, html:sub(pos, open_end))
            pos = open_end + 1
        else
            table.insert(out, html:sub(pos, open_start - 1))
            table.insert(out, M.stripArticleLinks(html:sub(open_end + 1, close_start - 1)))
            table.insert(out, html:sub(close_start, close_end))
            pos = close_end + 1
        end
    end
    return table.concat(out)
end

--[[-------------------------------------------------------------------------
Absolute-positioned overlay divs
--]]

-- {{Image label}} overlays (the "BC / AB / ..." province tags on infobox
-- locator maps and similar positioned labels) are inline
-- style="position: absolute" divs; crengine ignores absolute positioning,
-- so they stack into a text column above the orphaned base map. They are
-- children of the position:relative wrapper and siblings of the map <img>,
-- so dropping them keeps just the map. Marker overlays of the compositable
-- Template:Location map (handled by locmap.lua) always carry a class
-- attribute ("od"), so the class-less requirement leaves those untouched.
function M.stripPositionedOverlays(html)
    local out = {}
    local pos = 1
    while true do
        local open_start, open_end = html:find("<div[^>]*>", pos)
        if not open_start then
            table.insert(out, html:sub(pos))
            break
        end
        local open_tag = html:sub(open_start, open_end):lower()
        local style = open_tag:match([[style%s*=%s*"([^"]*)"]]) or ""
        local is_overlay = not open_tag:find("class%s*=", 1, false)
            and style:find("position%s*:%s*absolute")
        if not is_overlay then
            table.insert(out, html:sub(pos, open_end))
            pos = open_end + 1
        else
            local _, close_end = wutil.findMatchingClose(html, "div", open_end)
            if not close_end then
                table.insert(out, html:sub(pos))
                break
            end
            table.insert(out, html:sub(pos, open_start - 1))
            pos = close_end + 1
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

-- Nested sub-boxes inside a kept infobox (e.g. {{Collapsed infobox
-- section begin}}'s .cisb-table) span it only via their own
-- TemplateStyles, which crengine ignores, so they'd shrink-to-fit at the
-- cell's left edge. Width-treat every table chained under a table
-- matching `class_patterns`; styleFn returns the %% splice escapes.
function M.forceNestedTableWidth(html, class_patterns, styleFn)
    local function matches(tag)
        local class_attr = (tag:match([[class%s*=%s*"([^"]*)"]] ) or ""):lower()
        for _, pat in ipairs(class_patterns) do
            if class_attr:find(pat, 1, true) then
                return true
            end
        end
        return false
    end
    -- Per open table: whether the chain open above it (or itself) matched.
    local stack = {}
    local out, pos = {}, 1
    while true do
        local o_start, o_end = html:find("<table[^>]*>", pos)
        local c_start, c_end = html:find("</table%s*>", pos)
        if not o_start and not c_start then
            table.insert(out, html:sub(pos))
            break
        end
        if c_start and (not o_start or c_start < o_start) then
            if #stack > 0 then stack[#stack] = nil end
            table.insert(out, html:sub(pos, c_end))
            pos = c_end + 1
        else
            local open_tag = html:sub(o_start, o_end)
            local chain = (#stack > 0 and stack[#stack]) or matches(open_tag)
            if chain then
                local style = open_tag:match('style%s*=%s*"([^"]*)"')
                local new_style = styleFn(style or "")
                if style then
                    open_tag = open_tag:gsub('style%s*=%s*"[^"]*"',
                        'style="' .. new_style .. '"')
                else
                    open_tag = open_tag:gsub('^(<[^>]+)',
                        '%1 style="' .. new_style .. '"')
                end
            end
            table.insert(out, html:sub(pos, o_start - 1))
            table.insert(out, open_tag)
            pos = o_end + 1
            stack[#stack + 1] = chain
        end
    end
    return table.concat(out)
end

-- TemplateStyles tables carry the same layout-killing inline width/float
-- as wikitables but no class to match ({{Historical populations}} emits
-- <table class="table-pale" style="width:15em;...;float:right">).
-- Idempotent over already-normalized tables. Same %%-escape discipline as
-- cleanElementClasses' splice (see forceFullWidthStyle in epub.lua).
function M.forceFullWidthStyledTables(html, styleFn)
    return html:gsub("<table[^>]*>", function(tag)
        local style = tag:match('style%s*=%s*"([^"]*)"')
        if not style or not (style:find("width%s*:") or style:find("float%s*:")) then
            return tag
        end
        return (tag:gsub('style%s*=%s*"[^"]*"', 'style="' .. styleFn(style) .. '"'))
    end)
end

-- {{Rating}} stars (tiny Star full/half/empty.svg <img> icons) end up blank
-- otherwise: removeInlineIcons() drops them in kept infoboxes and
-- createEpub() strips unembeddable remote <img>s. Replacing just the <img>
-- empties the mw:File wrapper, so the text survives later passes. Matched
-- by filename anywhere in the tag: Parsoid REST output anchors it in
-- resource=, the action=parse output we fetch only in the thumb src path.
-- Half uses "½" because the exact glyph (U+2BE8) is missing from most
-- device fonts.
local STAR_ICONS = {
    ["Star_full.svg"] = "★",
    ["Star_half.svg"] = "½",
    ["Star_empty.svg"] = "☆",
}

function M.ratingStarsToText(html)
    return (html:gsub("<img[^>]->", function(tag)
        for file, star in pairs(STAR_ICONS) do
            if tag:find(file, 1, true) then
                return star
            end
        end
    end))
end

--[[-------------------------------------------------------------------------
Media removal inside kept infobox tables and inline flags
--]]

-- Cleans the inside of a kept infobox table so it shows text only,
-- running before the image pass. For each cell it:
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
-- opts.keep_images: lazy mode with kept infoboxes routes their media into
-- the lazy-image pipeline instead: only non-image media (video/audio/
-- mapframe) drops the cell; large <img>s and image/caption cells stay for
-- the qrimage walker to turn into lazy placeholders. Inline icons are
-- still removed, so only genuine media survives inside the box.
function M.stripImageCells(html, class_patterns, opts)
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
            table.insert(out, M.stripImageCellsInBlock(html:sub(t_open_end + 1, close_start - 1), opts))
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
-- real thumbnail.
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
function M.isStatusBadgeImg(s)
    local src = s:lower():match('src%s*=%s*"([^"]*)"')
    return src ~= nil and src:find("/status_", 1, true) ~= nil
end

-- True when the HTML `gap` between two cells holds only whitespace and
-- row/table-section boundaries, i.e. the cells are adjacent. A <th> is
-- never crossed: a section-header row breaks the caption relationship.
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
-- class.
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
-- kartographer mapframe, or <video>/<audio>. Such cells are dropped
-- whole; anything else is inline-icon-free text and is kept. Content is
-- matched case-insensitively (lowered here), as callers may or may not
-- have lowered it.
function M.cellHasMedia(content)
    content = content:lower()
    if content:find("<video", 1, true)
        or content:find("<audio", 1, true)
        or content:find("<figure", 1, true)
        or content:find("<mapframe", 1, true) then
        return true
    end
    -- Kartographer's static frame: modern Parsoid wraps the OSM snapshot
    -- <img> in an <a data-mw-kartographer="mapframe"> instead of emitting
    -- a literal <mapframe> element (which only the snapshot itself sees).
    if content:find('mw:extension/mapframe', 1, true)
        or content:find('data-mw-kartographer="mapframe"', 1, true) then
        return true
    end
    local pos = 1
    while true do
        local img = content:find("<img", pos, true)
        if not img then break end
        local close = content:find(">", img, true)
        if close then
            local w = content:sub(img, close):match('[%s]width%s*=%s*"(%d+)"')
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
-- a small inline flag beside their real content. With opts.keep_images,
-- non-image media only; image cells stay for the lazy walker.
function M.stripImageCellsInBlock(block, opts)
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
            local p = 1
            while true do
                local _, ws_end = stripped:find("^%s*", p)
                p = ws_end + 1
                -- The () position capture is the second (and last) value
                -- returned, right behind the captured tag text.
                local inner, after_tag = stripped:match("^<([^<>]*)>()", p)
                if not inner then break end
                local name = inner:lower():match("^%s*(%a+)")
                if name == "br" then
                    -- Drop just this break; rescan from the same position.
                    stripped = stripped:sub(1, p - 1) .. stripped:sub(after_tag)
                elseif name == "div" or name == "span" or name == "p"
                    or name == "center" then
                    p = after_tag -- cross the bare wrapper tag, keep it
                else
                    break         -- anything else (media, close tags, text): stop
                end
            end
        end

        local keep_images = opts and opts.keep_images
        local drop_cell = not keep_images
            and (cell_class:find("infobox-image", 1, true)
                or cell_class:find("infobox-caption", 1, true)
                or M.cellHasMedia(stripped:lower()))
        if not drop_cell and keep_images then
            local lower = stripped:lower()
            drop_cell = lower:find("<video", 1, true) ~= nil
                or lower:find("<audio", 1, true) ~= nil
                or lower:find("<mapframe", 1, true) ~= nil
                -- Interactive maps serve a static snapshot; without
                -- touch interaction it is just a wrong-resolution render.
                or lower:find('data-mw-kartographer="mapframe"', 1, true) ~= nil
                or lower:find('mw:extension/mapframe', 1, true) ~= nil
        end

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
            -- Icon-only row: drop the empty cell (unless lazy mode kept a
            -- media img in it, which the walker still turns into a
            -- placeholder); keep the text cell otherwise.
            local plain = stripped:gsub("<[^>]*>", ""):gsub("&[^;]+;", ""):gsub("%s", "")
            if plain == "" and not (keep_images and stripped:find("<img", 1, true)) then
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

-- {{Infobox settlement}} wraps label/header footnote markers (often the
-- whole "(Jan 2026[4])" qualifier) in a block-level div.ib-settlement-fn;
-- crengine honors the block display, so refs drop onto their own line
-- below the label. Wikipedia's stylesheet lines the div up inline, so
-- unwrap it.
function M.unwrapSettlementFnDivs(html)
    local out = {}
    local pos = 1
    while true do
        local open_start, open_end = html:find(
            [[<div[^>]-class%s*=%s*"[^"]*ib%-settlement%-fn[^" ]*"[^>]*>]], pos)
        if not open_start then
            table.insert(out, html:sub(pos))
            break
        end
        local close_start, close_end = wutil.findMatchingClose(html, "div", open_end)
        if not close_start then
            -- Unclosed stray: drop just the open tag.
            table.insert(out, html:sub(pos, open_start - 1))
            pos = open_end + 1
        else
            table.insert(out, html:sub(pos, open_start - 1))
            -- Markers stay; only the wrapper goes.
            table.insert(out, html:sub(open_end + 1, close_start - 1))
            pos = close_end + 1
        end
    end
    return table.concat(out)
end

-- Sizes Template:Legend color chips (<span class="legend-color">) inline.
-- Their box comes from a TemplateStyles <style> block crengine never
-- applies, so the chip's inline background-color renders as a one-space-
-- wide strip the height of a text line instead of a small square.
function M.styleLegendChips(html)
    return (html:gsub('(<span[^>]*class%s*=%s*"[^"]*legend%-color[^"]*"[^>]*>)', function(tag)
        return M.addInlineStyle(tag,
            "display:inline-block; width:1.25em; height:1.25em; border:1px solid black")
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

-- Borders kept infobox and wikitable tables as grids: outer edge and
-- border-collapse on the <table>, thin dashed separators on every cell,
-- plus the cell padding of Wikipedia's own .wikitable rule (0.2em 0.4em)
-- -- crengine has no default cell padding, so text would otherwise sit
-- flush against the borders. All inline, because
-- crengine ignores descendant selectors in the EPUB stylesheet (the same
-- reason centerInfoboxCells works inline): a CSS ".wikitable td" rule
-- never matches, and injected stylesheet rules vanish entirely when the
-- user disables "Embedded Style". Nested-table cells are included:
-- embedded layout/data tables read as part of the grid.
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
                "border:1px solid rgba(0,0,0,0.33);border-collapse:collapse"))
            table.insert(out, (html:sub(t_open_end + 1, close_start - 1):gsub(
                '(<t[dh][^>]*>)', function(tag)
                    return M.addInlineStyle(tag, "border:1px dashed rgba(0,0,0,0.33);padding:0.2em 0.4em")
                end)))
            table.insert(out, html:sub(close_start, close_end))
            pos = close_end + 1
        end
    end
    return table.concat(out)
end

--[[-------------------------------------------------------------------------
Table rotate hints
--]]

-- The hint line above/below each data table; sentinel URLs handled by
-- main.lua. Inline-styled so it survives "Embedded Style" off (same as
-- borderTableCells); margin only on the prose side, with the table's own
-- margin zeroed inline, so the bar hugs the table edge. The page-break
-- avoid (a preference: huge tables still split inside) binds each bar to
-- its neighboring block, else it gets orphaned alone on the previous page
-- when the table doesn't fit.
local function rotateHint(is_top)
    return '<p style="text-align:center; text-indent:0; font-size:75%;'
        .. ' color:rgba(0,0,0,0.47); background:rgba(0,0,0,0.04);'
        .. ' border:1px solid rgba(0,0,0,0.2); padding:0.2em 0; '
        .. (is_top
            and 'page-break-after:avoid; margin:0.6em 0 0 0'
            or 'page-break-before:avoid; margin:0 0 0.6em 0') .. '">'
        -- Absolute URIs are required: crengine resolves any href whose
        -- scheme it doesn't know (e.g. "wikireader:foo") as a path relative
        -- to the document base, mangling it before Lua sees it. The reserved
        -- .invalid host is unresolvable by definition, so these are local
        -- markers that never result in a fetch.
        .. '<a href="https://wikireader.invalid/rotate-ccw">Counterclockwise</a>'
        .. ' &lt; Tap to Rotate Screen &gt; '
        .. '<a href="https://wikireader.invalid/rotate-cw">Clockwise</a>'
        .. '</p>'
end

-- Above and below each top-level non-infobox table. Tables nested inside
-- another table (a kept infobox's inner markup, a notice's internals)
-- are skipped via `nested`: they rotate with their enclosing table, so
-- their own bars would be clutter.
function M.addRotateHints(html, nested)
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
        local lower = class_attr:lower()
        -- mbox tables are notices (dropped/wrapped later, and never wide
        -- enough to need rotation); hinting then dropping them would leave
        -- orphaned bars.
        local is_notice_table = false
        for _, pat in ipairs(wutil.LEADING_NOTICE_PATTERNS) do
            if lower:find(pat, 1, true) then
                is_notice_table = true
                break
            end
        end
        local is_data_table = not (is_notice_table or lower:find("infobox", 1, true))
        local hinted = is_data_table and not nested
        local close_start, close_end
        if hinted or not is_data_table then
            close_start, close_end = wutil.findMatchingClose(html, "table", t_open_end)
        end
        if not close_start then
            table.insert(out, html:sub(pos, t_open_end))
            pos = t_open_end + 1
        else
            table.insert(out, html:sub(pos, t_start - 1))
            if hinted then
                open_tag = M.addInlineStyle(open_tag, "margin:0")
                table.insert(out, rotateHint(true))
            end
            table.insert(out, open_tag)
            table.insert(out, M.addRotateHints(html:sub(t_open_end + 1, close_start - 1),
                nested or not is_data_table))
            table.insert(out, html:sub(close_start, close_end))
            if hinted then
                table.insert(out, rotateHint(false))
            end
            pos = close_end + 1
        end
    end
    return table.concat(out)
end

--[[-------------------------------------------------------------------------
Column layout scaffolds ({{col-begin}} + {{col-2}}/{{col-break}}/{{col-end}})
--]]

-- Drops the tbody/tr/td scaffold of a column-layout table, keeping the
-- cells' content in order: at scaffold level every element that isn't
-- tr/td/tbody is a whole content element (section, table, ...) copied
-- balanced, so the real tables' own rows survive untouched.
local function unwrapColumnScaffold(inner)
    local out = {}
    local pos = 1
    while true do
        local tag_start, tag_end, name = inner:find("<([a-zA-Z]+)[^>]*>", pos)
        if not tag_start then
            table.insert(out, inner:sub(pos))
            break
        end
        table.insert(out, inner:sub(pos, tag_start - 1))
        if name:lower():find("^t[drb]") then
            pos = tag_end + 1
        else
            local close_start, close_end = wutil.findMatchingClose(inner, name, tag_end)
            if close_start then
                table.insert(out, inner:sub(tag_start, close_end))
                pos = close_end + 1
            else
                table.insert(out, inner:sub(tag_start, tag_end))
                pos = tag_end + 1
            end
        end
    end
    return table.concat(out)
end

-- {{col-begin}} column layouts render as a role=presentation layout table
-- whose cells hold real content tables; crengine honours the columns and
-- squishes each into half the page. Dissolve the scaffold so the content
-- stacks in normal flow at full width. Non-matching tables are copied
-- verbatim (nested col-begin inside a table cell is not handled).
function M.unwrapColumnLayouts(html)
    local out = {}
    local pos = 1
    while true do
        local t_start, t_open_end = html:find("<table[^>]*>", pos)
        if not t_start then
            table.insert(out, html:sub(pos))
            break
        end
        local open_tag = html:sub(t_start, t_open_end)
        local class_attr = (open_tag:match([[class%s*=%s*"([^"]*)"]]) or ""):lower()
        local is_col_layout = class_attr:find("col-begin", 1, true) ~= nil
        local close_start, close_end
        if is_col_layout then
            close_start, close_end = wutil.findMatchingClose(html, "table", t_open_end)
        end
        if not close_start then
            table.insert(out, html:sub(pos, t_open_end))
            pos = t_open_end + 1
        elseif is_col_layout then
            table.insert(out, html:sub(pos, t_start - 1))
            table.insert(out, unwrapColumnScaffold(html:sub(t_open_end + 1, close_start - 1)))
            pos = close_end + 1
        else
            table.insert(out, html:sub(pos, close_end))
            pos = close_end + 1
        end
    end
     return table.concat(out)
end

-- {{Indented plainlist}} and friends hang "margin-left:1em;text-indent:-1em"
-- on a plainlist div; on the site the template's own bullet-hiding
-- TemplateStyles makes that safe, but crengine never applies them, so the
-- negative indent pulls each <li>'s first line onto its bullet disc. The
-- indent doesn't survive the reflow anyway; expect addRotateHints' own
-- text-indent:0 to arrive after this pass.
function M.stripTextIndent(html)
    return html:gsub('%s*style%s*=%s*"([^"]*)"', function(style)
        if not style:find("text%-indent") then
            return nil
        end
        style = style:gsub("text%-indent%s*:%s*[^;]+;?", "")
        style = style:gsub("^%s*;?%s*", ""):gsub(";;*%s*$", "")
        if style == "" then
            return ""
        end
        return ' style="' .. style .. '"'
    end)
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
-- Template:Quote box renders the same <cite> attribution as a plain <div>
-- sibling of the box's inner <blockquote>: the div sits inside the outer
-- .quotebox, but ours styles the box on <blockquote>, so the name would
-- hang below it. Same fix applies: merge into wikireader-cite.
--
-- MediaWiki output handled here looks like:
--   <blockquote class="templatequote"><p>...</p></blockquote>
--   <div class="templatequotecite"><p style="display:inline;padding-left:2.3em;">— Person</p></div>
-- or:
--   <blockquote class="quotebox-quote"><p>...</p></blockquote>
--   <div style="padding-bottom: 0; ..."><cite>— Person</cite></div>
function M.mergeQuoteCites(html)
    local function skipWs(pos)
        local _, e = html:find('^%s*', pos)
        return (e or pos - 1) + 1
    end

    -- Attribution <div> directly following </blockquote>: either the known
    -- templatequotecite form or any div holding a <cite> line (the Quote box
    -- wrapper). Returns the div's span and content, or nothing.
    local function findCiteDiv(after_close)
        local div_open_start, div_open_end = html:find('<div[^>]*>', after_close)
        if div_open_start ~= after_close then return end
        local div_close_start, div_close_end = wutil.findMatchingClose(html, "div", div_open_end)
        if not div_close_end then return end
        local open_tag = html:sub(div_open_start, div_open_end)
        local content = html:sub(div_open_end + 1, div_close_start - 1)
        -- templatequotecite may carry extra attrs (about/id) besides the class.
        if open_tag:find('"templatequotecite', 1, true)
            or content:find('^%s*<cite[%s>]') then
            return div_open_start, div_close_end, content
        end
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
        local _, cite_close_end, cite_content = findCiteDiv(after_close)
        if not cite_content then
            table.insert(out, html:sub(pos, bq_close_end))
            pos = bq_close_end + 1
        else
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

-- True when a matched notice is addressed to editors (asking someone to
-- fix, expand, move or delete the article) instead of informing readers.
-- Module:Message box's type class is the language-independent
-- discriminator; the box-* keep list spares the reader-relevant
-- "current event"-family banners whose text also contains editor-facing
-- sentences; English phrases catch the remaining ambox-notice leftovers
-- ({{Under construction}}, {{In use}}, untyped protection tags).
-- Second return: true when the banner was kept via the keep list
-- (those banners carry their editor-facing sentences in hide-when-compact
-- spans, which stripEditingSpans then removes).
local function noticeInvitesEditing(open_tag, content)
    local class_attr = (open_tag:match([[class%s*=%s*"([^"]*)"]]) or "")
        :gsub("&#95;", "_"):lower()
    for _, pat in ipairs(wutil.NOTICE_KEEP_BOX_CLASSES) do
        if class_attr:find(pat, 1, true) then
            return false, true
        end
    end
    for _, pat in ipairs(wutil.EDITING_MBOX_CLASSES) do
        if class_attr:find(pat, 1, true) then
            return true
        end
    end
    local text = content:gsub("<style[^>]*>.-</style%s*>", " ")
        :gsub("<[^>]*>", " "):lower()
    for _, phrase in ipairs(wutil.EDITING_NOTICE_PHRASES) do
        if text:find(phrase, 1, true) then
            return true
        end
    end
    return false
end

-- Drops the hide-when-compact spans holding the editor-facing sentences
-- of a kept current-event-family banner (the "Please update ..." call to
-- action and the "Learn how and when to remove this message" tail) so
-- only the reader-relevant text stays. Matched conservatively by link
-- target/text: those spans may in principle carry reader content too.
local function stripEditingSpans(content)
    local out, pos = {}, 1
    while true do
        local open_s, open_e = content:find(
            '<span[^>]-class="[^"]*hide%-when%-compact[^"]*"[^>]*>', pos)
        if not open_s then break end
        local close_s, close_e = content:find("</span>", open_e + 1)
        if not close_s then break end
        -- the span itself may wrap <i>/<small>/<a> but never another span
        local span = content:sub(open_s, close_e):lower()
        if span:find("action=edit", 1, true)
            or span:find("maintenance_template_removal", 1, true)
            or span:find("remove this template", 1, true) then
            table.insert(out, content:sub(pos, open_s - 1))
        else
            table.insert(out, content:sub(pos, close_e))
        end
        pos = close_e + 1
    end
    table.insert(out, content:sub(pos))
    return table.concat(out)
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
        -- Editor-facing banners (expansion/citation/... requests) are
        -- dropped, not extracted into the notices block.
        local invites, is_fluid = noticeInvitesEditing(
            html:sub(open_start, open_end),
            html:sub(open_end + 1, close_start - 1))
        if not invites then
            local kept = html:sub(pos, close_end)
            if is_fluid then
                kept = stripEditingSpans(kept)
            end
            table.insert(notices, kept)
        end
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
-- in <div class="wikireader-notices"> boxes. Editor-facing banners are
-- dropped outright instead, and kept current-event banners lose their
-- editor-facing spans (see noticeInvitesEditing / stripEditingSpans).
-- Deliberately a second pass on the "rest" HTML, so front-of-article
-- notices aren't double-wrapped.
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
            local invites, is_fluid = noticeInvitesEditing(
                open_tag, html:sub(open_end + 1, close_start - 1))
            if not invites then
                local kept = html:sub(open_start, close_end)
                if is_fluid then
                    kept = stripEditingSpans(kept)
                end
                table.insert(out, string.format(
                    [[<div class="wikireader-notices">%s</div>]],
                    kept
                ))
            end
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
-- room to its right. Real <table> markup IS first-class in crengine, so
-- we rewrite each image into its own tiny table so the box splits between
-- images instead of jumping pages as one block. See M.restructureMultiImages.

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
    local out = tag:gsub('^(<[^%s>]+)', function(prefix)
        return prefix .. " style=\"" .. prop .. "\""
    end)
    return out
end

-- Multi-image (tmulti) grid transform: the template's side-by-side cell
-- layout, used for boxes inside kept infoboxes
-- (see M.restructureMultiImages).

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

-- Width (px) declared on a tsingle open tag, or nil. Matches the
-- "width" declaration specifically, so "max-width" (or other -width
-- neighbors) can't yield the wrong value.
local function tsingleWidth(open_tag)
    local style = open_tag:match('style%s*=%s*"([^"]*)"') or ""
    for decl in style:gmatch("[^;]+") do
        local w = decl:match("^%s*width%s*:%s*(%d+)px")
        if w then
            return tonumber(w)
        end
    end
end

-- Rewrites the inside of one <tr> (the content of a .trow div): every
-- tsingle div becomes one proportional display:inline-block <div>, all
-- enclosed in a single full-width <td colspan=N>; every theader div keeps
-- its own full-width <td colspan=N>. Everything else -- the
-- thumbimage/thumbcaption divs nested inside a tsingle, lazy markers,
-- links, text -- passes through untouched.
-- Proportional (not equal) shares: the browser scales a row's images to
-- one shared height, so their widths are aspect-proportional -- equal
-- cells left the narrow images floating with dead space between them.
-- One colspan cell per row also keeps crengine's whole-table column
-- merging (its widest percentage per column wins) from fighting rows
-- whose proportions differ. Needs KOReader's default "web" block-
-- rendering mode; older modes degrade to stacked full-width items.

-- Re-footprints one grid item's media to fill its cell: width:100%,
-- aspect kept, capped like lazyfetch's 33vh page-height bound so tall
-- originals can't bloat the cell. The template's height:NNpx;overflow:
-- hidden clip crops a 1px rounding overshoot in the browser -- kept, it
-- would slice the upscaled image. The walker rewrites <img>s before
-- this pass, so raw imgs are only test-fixture/pre-placeholder builds.
local function fillItemMedia(inner, lazy_images)
    local fillStyle = function(px_w, px_h)
        if px_w and px_h and px_h > 0 then
            return string.format("width:100%%; max-width:%.2fvh", 33 * px_w / px_h)
        end
        return "width:100%"
    end
    inner = inner:gsub('<span class="wikireader%-lazyimg" data%-lazyindex="([%d]+)"([^>]*)>',
        function(idx, rest)
            local w = tonumber(rest:match('width%s*:%s*(%d+)px'))
            local h = tonumber(rest:match('height%s*:%s*(%d+)px'))
            local style = fillStyle(w, h)
            if lazy_images then
                local img = lazy_images[tonumber(idx)]
                if img then
                    img.style = style
                end
            end
            return '<span class="wikireader-lazyimg" data-lazyindex="'
                .. idx .. '" style="' .. style .. '"></span>'
        end)
    inner = inner:gsub("<img([^>]*)>", function(attrs)
        local w = tonumber(attrs:match('%swidth%s*=%s*"(%d+)"'))
        local h = tonumber(attrs:match('%sheight%s*=%s*"(%d+)"'))
        -- The captured attrs may end in the self-closing slash: keep it,
        -- style goes before it.
        local self_closing = attrs:sub(-1) == "/"
        attrs = attrs:gsub('/%s*$', '')
            :gsub('%s+width%s*=%s*"[^"]*"', '')
            :gsub('%s+height%s*=%s*"[^"]*"', '')
        return '<img' .. attrs .. ' style="' .. fillStyle(w, h) .. '"'
            .. (self_closing and "/" or "") .. ">"
    end)
    inner = inner:gsub("<div([^>]*)>", function(a)
        if a:match('overflow%s*:%s*hidden') and a:match('height%s*:%s*%d+px') then
            return '<div' .. a:gsub('%s*style%s*=%s*"[^"]*"', '') .. '>'
        end
    end)
    return inner
end

local function multiImageTransformRow(content, n_cols, lazy_images)
    local items = {}
    local n_grid, row_w = 0, 0
    local missing = false
    local pos = 1
    while true do
        local o_start, o_end = content:find("<div[^>]*>", pos)
        if not o_start then
            table.insert(items, { raw = content:sub(pos) })
            break
        end
        local open_tag = content:sub(o_start, o_end)
        local cls = openTagClass(open_tag)
        local c_start, c_end = wutil.findMatchingClose(content, "div", o_end)
        if not c_start then
            table.insert(items, { raw = content:sub(o_start) })
            break
        end
        local inner = content:sub(o_end + 1, c_start - 1)
        if tokenInClass(cls, "tsingle") then
            local w = tsingleWidth(open_tag)
            if not w then
                missing = true
            else
                row_w = row_w + w
            end
            n_grid = n_grid + 1
            items[#items + 1] = { tsingle = true, w = w, inner = fillItemMedia(inner, lazy_images) }
        else
            items[#items + 1] = { tag = open_tag, cls = cls, inner = inner }
        end
        pos = c_end + 1
    end
    -- Width shares: the template's px proportions (equal if px widths
    -- are missing). Floored so the row total can't exceed 100% -- the
    -- last inline-block would wrap below the first one.
    local cell_open = '<td colspan="' .. n_cols
        .. '" style="vertical-align:top;padding-left:6px;padding-right:6px;text-align:center">'
    local out = {}
    local buf = {}
    local function flushGrid()
        if next(buf) then
            table.insert(out, cell_open .. table.concat(buf) .. "</td>")
            buf = {}
        end
    end
    for _, item in ipairs(items) do
        if item.tsingle then
            local share = (missing or row_w == 0) and 100 / n_grid
                or 100 * item.w / row_w
            table.insert(buf,
                '<div style="display:inline-block;width:'
                .. string.format("%.2f", math.floor(share * 100) / 100)
                -- vertical-align:top aligns uneven item heights; padding
                -- lives on an inner auto-width div (on the fixed-width
                -- item it would add to the width and overflow the row).
                .. '%;vertical-align:top"><div style="padding:0 6px">'
                .. item.inner
                .. "</div></div>")
        else
            flushGrid()
            if item.raw then
                table.insert(out, item.raw)
            elseif tokenInClass(item.cls, "theader") then
                local cell_style = item.tag:match('style%s*=%s*"([^"]*)"')
                local style = cell_style and cell_style ~= ""
                    and cell_style .. ";text-align:center;font-weight:bold"
                    or "text-align:center;font-weight:bold"
                table.insert(out, '<td colspan="' .. n_cols .. '" style="'
                    .. style .. '">' .. item.inner .. "</td>")
            elseif tokenInClass(item.cls, "thumbcaption") then
                -- The box's overall caption, emitted in its own full-width
                -- cell (a bare <div> in a <tr> is invalid HTML).
                local cell_style = item.tag:match('style%s*=%s*"([^"]*)"')
                local style = cell_style and cell_style ~= ""
                    and cell_style .. ";text-align:center"
                    or "text-align:center"
                table.insert(out, '<td colspan="' .. n_cols .. '" style="'
                    .. style .. '">' .. item.inner .. "</td>")
            else
                -- Unknown div directly inside a row (shouldn't happen): keep intact.
                table.insert(out, item.tag .. item.inner .. "</div>")
            end
        end
    end
    flushGrid()
    return table.concat(out)
end

-- Rewrites the content of a multi-image box's .thumbinner (now a <table>):
-- each top-level .trow div becomes <tr>, the optional overall
-- .thumbcaption becomes a full-width footer row, everything else passes
-- through.
local function multiImageTransformRows(inner, n_cols, lazy_images)
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
            table.insert(out, multiImageTransformRow(content, n_cols, lazy_images))
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

-- Extracts a multi-image box's transformable rows from its wrapper div:
--   rows    the box's content as `<tr>...</tr>` strings (grid form)
--   lead    content between the wrapper div and the inner box (usually
--           whitespace)
--   trail   content between the inner box and the wrapper's close (usually
--           empty; the wrapper's own `</div>` is NOT part of it)
--   close   the wrapper's closing tag text (multiImageToTable re-appends it)
--   inner   the raw .thumbinner/.multiimageinner content
-- Returns nil if the structure isn't what we expect.
local function multiImageRowContent(wrapper, lazy_images)
    local o_start, o_end = wrapper:find("^<div[^>]*>")
    if not o_start then
        return nil
    end
    local ti_start, ti_end = wrapper:find("<div[^>]*>", o_end)
    -- Modern Infobox settlement uses .multiimageinner instead of the
    -- legacy .thumbinner for the same inner-box role.
    local inner_cls = ti_start and openTagClass(wrapper:sub(ti_start, ti_end)) or ""
    if not ti_start
        or not (tokenInClass(inner_cls, "thumbinner")
            or tokenInClass(inner_cls, "multiimageinner")) then
        return nil
    end
    local ti_close_start, ti_close_end = wutil.findMatchingClose(wrapper, "div", ti_end)
    if not ti_close_start then
        return nil
    end
    local inner = wrapper:sub(ti_end + 1, ti_close_start - 1)
    local n_cols = multiImageColumnCount(inner)
    local w_close_start = wutil.findMatchingClose(wrapper, "div", o_end)
    if not w_close_start then
        return nil
    end
    return multiImageTransformRows(inner, n_cols, lazy_images),
        wrapper:sub(o_end + 1, ti_start - 1),
        wrapper:sub(ti_close_end + 1, w_close_start - 1),
        wrapper:sub(w_close_start),
        n_cols,
        inner
end

-- Builds the per-image <table> rows: one .tsingle per row, so each image
-- lands in its own small atomic standalone table (see multiImageToTable).
-- Nested tables are NOT usable here: crengine never fragments a table
-- nested inside another table's cell (the whole nested block is one
-- unsplittable slice), and rows of one small single-column table glue
-- together (each row under half the page width gets split-avoid flags),
-- so the whole box would jump pages as one block.
local function multiImageStackedRows(inner, table_open)
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
            local spos = 1
            while true do
                local t_s, t_e = content:find("<div[^>]*>", spos)
                if not t_s then
                    break
                end
                local tcls = openTagClass(content:sub(t_s, t_e))
                local tc_s, tc_e = wutil.findMatchingClose(content, "div", t_e)
                if not tc_s then
                    break
                end
                if tokenInClass(tcls, "tsingle") then
                    -- Class strip and width decls dropped: each row is
                    -- full-width, the image centers itself. No colspan -- a
                    -- lone cell spanning the row would register a phantom
                    -- column and rescale every other row's cells.
                    local td = content:sub(t_s, t_e):gsub("^<div([ >])", "<td%1")
                        :gsub('%s*class%s*=%s*"[^"]*"', '')
                    -- Drop the width decls inside the style value only
                    -- (a bare [^;]+ would run past the closing quote when
                    -- width is the attribute's last declaration).
                    td = td:gsub('(style%s*=%s*")([^"]*)(")', function(p, v, s)
                        return p
                            .. v:gsub('%s*max%-width%s*:[^;"]+;?', '')
                            :gsub('%s*width%s*:[^;"]+;?', '')
                            .. s
                    end, 1)
                    td = addStyleProp(td, "text-align:center;vertical-align:top;padding-left:6px;padding-right:6px")
                    local row = "<tr>" .. td .. content:sub(t_e + 1, tc_s - 1) .. "</td></tr>"
                    if table_open then
                        table.insert(out, table_open .. row .. "</table>")
                    else
                        table.insert(out, row)
                    end
                elseif tokenInClass(tcls, "theader") then
                    local cell_style = content:sub(t_s, t_e):match('style%s*=%s*"([^"]*)"')
                    local style = cell_style and cell_style ~= ""
                        and cell_style .. ";text-align:center;font-weight:bold"
                        or "text-align:center;font-weight:bold"
                    local row = '<tr><td style="' .. style .. '">'
                        .. content:sub(t_e + 1, tc_s - 1) .. "</td></tr>"
                    if table_open then
                        table.insert(out, table_open .. row .. "</table>")
                    else
                        table.insert(out, row)
                    end
                end
                spos = tc_e + 1
            end
        elseif tokenInClass(cls, "thumbcaption") then
            local row = '<tr><td style="text-align:center">' .. content .. "</td></tr>"
            if table_open then
                table.insert(out, table_open .. row .. "</table>")
            else
                table.insert(out, row)
            end
        end
        pos = c_end + 1
    end
    return table.concat(out)
end

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

-- Gallery boxes: each gallerybox's div.thumb carries Parsoid's inline
-- "width:NNNpx;height:NNNpx". The box itself is forced to the page width
-- by the injected stylesheet, and a fixed-width block inside it always
-- sits flush left (text-align:center only positions inline content, never
-- the block). Drop the inline footprint so the thumb spans the box and
-- the placeholder image centers inside it. Modern Parsoid uses div.thumb
-- only for gallery thumbs (single thumbs are <figure>, multi-image cells
-- are .thumbimage), so a bare class="thumb" match is gallery-only in
-- practice; a stray legacy thumb just loses its outer footprint to its
-- own .thumbinner's width, which is what sized it anyway.
function M.centerGalleryThumbs(html)
    return (html:gsub('(<div[^>]*class%s*=%s*"thumb")%s+style%s*=%s*"[^"]*"', "%1"))
end

-- Rewrites one <div class="thumb tmulti ...">...</div> block into the same
-- wrapper div holding one tiny <table> per image (plus per .theader and
-- the overall caption); unchanged wrapper if the structure isn't what we
-- expect. Why per-image tables: rows under half the page width get
-- split-avoid flags and glue together, and crengine never fragments a
-- table nested inside another element's flow — a multi-image box would
-- jump pages as one block. One-row tables are independent blocks the
-- splitter breaks between freely, so the current page fills with as many
-- images as fit.
local function multiImageToTable(wrapper)
    local _, lead, trail, close, _, inner = multiImageRowContent(wrapper)
    if not inner then
        return wrapper
    end
    local o_start, o_end = wrapper:find("^<div[^>]*>")
    local wrapper_open = wrapper:sub(o_start, o_end)
    local ti_start, ti_end = wrapper:find("<div[^>]*>", o_end)
    local ti_open = wrapper:sub(ti_start, ti_end)
    local table_open = ti_open:gsub("^<div([ >])", "<table%1")
        :gsub([[class%s*=%s*"[^"]*"]], 'class="wikireader-tmulti"', 1)
    return wrapper_open
        .. lead
        .. multiImageStackedRows(inner, table_open)
        .. trail
        .. close
end

-- Innermost enclosing <tag>...</tag> around a position, via a forward walk
-- of that tag's open/close tokens up to the position. nil when the position
-- sits outside every open of that tag (or the walk hits malformed markup).
local function enclosingTag(html, tag, pos)
    local open_pat = "<" .. tag .. "[^>]*>"
    local close_pat = "</" .. tag .. "%s*>"
    local stack = {}
    local scan = 1
    while true do
        local o_start, o_end = html:find(open_pat, scan)
        local c_start, c_end = html:find(close_pat, scan)
        if o_start and o_start < pos and (not c_start or o_start < c_start) then
            stack[#stack + 1] = { o_start, o_end }
            scan = o_end + 1
        elseif c_start and c_start < pos then
            stack[#stack] = nil
            scan = c_end + 1
        else
            local top = stack[#stack]
            if top then
                return top[1], top[2]
            end
            return nil
        end
    end
end

-- Sums a row's <td>/<th> colspan values (nested-table cells included;
-- grid-row cells carry no nested tables in practice).
local function rowColumnSpan(row)
    local total = 0
    for tag in row:gmatch("<t[dh][^>]*>") do
        total = total + (tonumber(tag:match('colspan%s*=%s*"(%d+)"')) or 1)
    end
    return total
end

-- Pads each grid row's cells with colspan so the row's total column span
-- matches target: a narrower box row (a lone image, or a .theader/
-- overall-caption in a box with fewer columns than the infobox) would
-- otherwise claim only the first infobox column -- its width:100% cell
-- centered inside a partial column sits far off-center in a 2-column
-- infobox. The extra span goes to the first colspan-less cell, or widens
-- the first spanned one.
local function padGridRowSpans(rows, target)
    local out = {}
    local pos = 1
    while true do
        local r_s, r_e = rows:find("<tr[^>]*>", pos)
        if not r_s then
            table.insert(out, rows:sub(pos))
            break
        end
        local close_s, close_e = wutil.findMatchingClose(rows, "tr", r_e)
        if not close_s then
            table.insert(out, rows:sub(pos))
            break
        end
        table.insert(out, rows:sub(pos, r_e))
        local row = rows:sub(r_e + 1, close_s - 1)
        local short = target - rowColumnSpan(row)
        if short < 0 then short = 0 end
        if short ~= 0 then
            local i = 1
            while true do
                local cs, ce = row:find("<t[dh][^>]*>", i)
                if not cs then break end
                local tag = row:sub(cs, ce)
                local span = tonumber(tag:match('colspan%s*=%s*"(%d+)"'))
                if not span then
                    -- Implicit span was 1; make the total target.
                    row = row:sub(1, ce - 1) .. ' colspan="' .. (short + 1)
                        .. '"' .. row:sub(ce)
                    break
                elseif span + short > 0 then
                    -- No colspan-less cell: widen the first spanned one.
                    row = row:sub(1, cs)
                        .. tag:gsub('colspan%s*=%s*"%d+"', 'colspan="'
                            .. tostring(span + short) .. '"', 1)
                        .. row:sub(ce + 1)
                    break
                end
                i = ce + 1
            end
        end
        table.insert(out, row)
        table.insert(out, rows:sub(close_s, close_e))
        pos = close_e + 1
    end
    return table.concat(out)
end

-- Replaces a multi-image box's host row inside a kept infobox: instead of
-- a nested <table> (the multiImageToTable form), the box's image rows are
-- emitted as rows of the infobox table itself, one <tr> per image row:
--       <tr><td[host cell]>lead-in (TemplateStyles etc.)</td></tr>
--       (the box's image rows, as emitted by multiImageTransformRow)
--       <tr><td[host cell]>trailing cell content</td></tr>
-- Why hoisting: crengine treats every table row as one unsplittable slice
-- and never splits between a table's first and second row (it could be
-- column headers). An infobox's second row is the image grid -- the title
-- row sticks to it and both get pushed to page 2, leaving page 1 almost
-- empty. As the infobox's own rows, each image row stays small and the
-- grid keeps the template's side-by-side layout.
-- If the box doesn't live directly inside an infobox table (or its host
-- row isn't recognisable), returns nil and the caller keeps the
-- nested-table form.
local function hoistMultiImageRows(html, o_start, w_close_end, lazy_images)
    -- The innermost table containing the wrapper decides the treatment:
    -- a box nested one table deeper keeps its nested-table form (hoisting
    -- there would still be inside the outer table's atomic row).
    local t_s, t_e = enclosingTag(html, "table", o_start)
    if not t_s or not tokenInClass(openTagClass(html:sub(t_s, t_e)), "infobox") then
        return nil
    end
    local td_s, td_e = enclosingTag(html, "td", o_start)
    if not td_s then
        return nil
    end
    local td_close_s, td_close_e = wutil.findMatchingClose(html, "td", td_e)
    if not td_close_s or td_close_s < w_close_end then
        return nil
    end
    local tr_s, tr_e = enclosingTag(html, "tr", o_start)
    if not tr_s then
        return nil
    end
    local tr_close_s, tr_close_e = wutil.findMatchingClose(html, "tr", tr_e)
    if not tr_close_s or tr_close_s < td_close_s then
        return nil
    end
    local rows, lead, trail = multiImageRowContent(html:sub(o_start, w_close_end), lazy_images)
    if not rows then
        return nil
    end
    local td_open = html:sub(td_s, td_e)
    -- Column budget of the host row: its own colspan plus the other
    -- cells' spans in the same <tr> (a labeled row contributes its <th>).
    local function cellsSpan(s)
        local total = 0
        for tag in s:gmatch("<t[dh][^>]*>") do
            total = total + (tonumber(tag:match('colspan%s*=%s*"(%d+)"')) or 1)
        end
        return total
    end
    local target = (tonumber(td_open:match('colspan%s*=%s*"(%d+)"')) or 1)
        + cellsSpan(html:sub(tr_s, td_s - 1))
        + cellsSpan(html:sub(td_close_e + 1, tr_close_s - 1))
    if target > 1 then
        rows = padGridRowSpans(rows, target)
    end
    local pre = lead .. html:sub(td_e + 1, o_start - 1)
    local post = html:sub(w_close_end + 1, td_close_s - 1) .. trail
    -- The host row may hold cells besides the host one (a lower, labeled
    -- row: <tr><th>label</th><td>grid</td></tr>); the hoisted rows must
    -- carry them or the label would be silently dropped.
    local pre_cells = html:sub(tr_s, td_s - 1):gsub("^<tr[^>]*>", "")
    local post_cells = html:sub(td_close_e + 1, tr_close_s - 1)
    local out = {}
    if pre:find("%S") or pre_cells:find("%S") then
        table.insert(out, "<tr>" .. pre_cells .. td_open .. pre .. "</td></tr>")
    end
    -- The nested-table form centers text via the surrounding cell; hoisted
    -- rows are the infobox's own cells, so center them inline. Appended so
    -- the centering wins over any alignment the template itself declared
    -- (a later declaration wins in the cascade).
    table.insert(out, (rows:gsub("<td[^>]*>", function(tag)
        return addStyleProp(tag, "text-align:center")
    end)))
    if post:find("%S") or post_cells:find("%S") then
        table.insert(out, "<tr>" .. td_open .. post .. "</td>"
            .. post_cells .. "</tr>")
    end
    -- Consumed range starts at the host row, so the caller must not re-emit
    -- the row's own <tr>/<td> opens.
    return table.concat(out), tr_s, tr_close_e + 1
end

-- {{Infobox settlement/columns}} lays its columns out on CSS
-- display:table/table-row/table-cell (its own TemplateStyles), which
-- crengine ignores: the flag/coat-of-arms cells of settlement infoboxes
-- stack one per line. Rewrite the scaffold into one real table nested
-- inside its host cell, with the per-cell vertical-alignment classes
-- carried over as inline styles: .ib-settlement-cols -> <table
-- class="wikireader-ibcols", -cols-row -> <tr>, -cols-cell[-t] -> <td>.
local function settlementColsConvert(inner, in_row)
    local items = {}
    local pos = 1
    while true do
        local d_start, d_end = inner:find("<div[^>]*>", pos)
        if not d_start then
            table.insert(items, { s = inner:sub(pos) })
            break
        end
        table.insert(items, { s = inner:sub(pos, d_start - 1) })
        local open_tag = inner:sub(d_start, d_end)
        local cls = openTagClass(open_tag)
        local c_start, c_end = wutil.findMatchingClose(inner, "div", d_end)
        local wrap = function(cell_cls)
            local td = open_tag:gsub("^<div([ >])", "<td%1")
            local cell = addStyleProp(td, cell_cls)
                .. settlementColsConvert(inner:sub(d_end + 1, c_start - 1), true)
                .. "</td>"
            return { kind = "cell", s = cell }
        end
        if not c_start then
            table.insert(items, { s = open_tag })
            pos = d_end + 1
        elseif tokenInClass(cls, "ib-settlement-cols-cellt") then
            table.insert(items, wrap("vertical-align:top"))
            pos = c_end + 1
        elseif tokenInClass(cls, "ib-settlement-cols-cell") then
            table.insert(items, wrap("vertical-align:middle"))
            pos = c_end + 1
        elseif tokenInClass(cls, "ib-settlement-cols-row") then
            table.insert(items, {
                s = "<tr>"
                    .. settlementColsConvert(inner:sub(d_end + 1, c_start - 1), true)
                    .. "</tr>"
            })
            pos = c_end + 1
        else
            -- Caption links etc. pass through verbatim.
            table.insert(items, { s = open_tag })
            pos = d_end + 1
        end
    end
    -- Cells converted at row level are consecutive siblings without a
    -- -cols-row wrapper: gather runs of them into one shared <tr> so they
    -- render side by side (a real -cols-row child already carried one).
    local out = {}
    local i = 1
    while i <= #items do
        if not in_row and not items[i].kind
            and not items[i].s:find("%S") then
            -- Whitespace between converted siblings would split cell runs.
            i = i + 1
        elseif not in_row and items[i].kind == "cell" then
            local buf = {}
            while i <= #items and (items[i].kind == "cell"
                    or (not items[i].kind and not items[i].s:find("%S"))) do
                if items[i].kind then
                    buf[#buf + 1] = items[i].s
                end
                i = i + 1
            end
            table.insert(out, "<tr>" .. table.concat(buf) .. "</tr>")
        else
            table.insert(out, items[i].s)
            i = i + 1
        end
    end
    return table.concat(out)
end

function M.settlementColsToTable(html)
    local out = {}
    local pos = 1
    while true do
        local d_start, d_end = html:find("<div[^>]*>", pos)
        if not d_start then
            table.insert(out, html:sub(pos))
            break
        end
        local open_tag = html:sub(d_start, d_end)
        local cls = openTagClass(open_tag)
        local c_start, c_end = wutil.findMatchingClose(html, "div", d_end)
        if c_start and tokenInClass(cls, "ib-settlement-cols") then
            local table_open = open_tag:gsub("^<div([ >])", "<table%1")
                :gsub('%s*class%s*="[^"]*"', ' class="wikireader-ibcols"')
            table.insert(out, html:sub(pos, d_start - 1))
            -- Inline centering + width: the template's own TemplateStyles
            -- only apply with "Embedded Style" on.
            table.insert(out, addStyleProp(table_open, "width:100%;text-align:center"))
            table.insert(out, settlementColsConvert(html:sub(d_end + 1, c_start - 1), false))
            table.insert(out, "</table>")
            pos = c_end + 1
        else
            table.insert(out, html:sub(pos, d_end))
            pos = d_end + 1
        end
    end
    return table.concat(out)
end

-- Rewrites each {{Multiple image}} box (container div class token
-- "tmulti"): inside a kept infobox the box's grid rows are hoisted out as
-- rows of the infobox table itself (see hoistMultiImageRows), anywhere
-- else the box becomes one tiny per-image stacked table
-- (see multiImageToTable). Unexpected structures are returned unchanged,
-- so it degrades gracefully.
function M.restructureMultiImages(html, lazy_images)
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
                local hoisted, emit_start, next_pos =
                    hoistMultiImageRows(html, o_start, c_end, lazy_images)
                if hoisted then
                    table.insert(out, html:sub(pos, emit_start - 1))
                    table.insert(out, hoisted)
                    pos = next_pos or (c_end + 1)
                else
                    table.insert(out, html:sub(pos, o_start - 1))
                    table.insert(out, multiImageToTable(html:sub(o_start, c_end)))
                    pos = c_end + 1
                end
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
