-- HTML cleaning utilities for WikiReader.
-- Strips/reorganises Wikipedia HTML elements that don't work well in a
-- reflowable EPUB (infoboxes, navboxes, image captions, hatnote boxes, etc.).

local wutil = require("wikiutil")

local M = {}

--[[-------------------------------------------------------------------------
Generic element stripping
--]]

-- Removes <tag ...>...</tag> blocks whose `attr_name` attribute matches
-- any of `attr_patterns`, correctly handling same-tag elements nested
-- inside them (an infobox table can contain a nested table; a div can
-- nest other divs). Lua's plain string patterns can't express "find the
-- matching close tag" on their own -- %b()-style balanced matching only
-- works for single-character delimiters -- so this walks the string by
-- hand instead, tracking nesting depth.
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

            -- Remove each specified class from the class attribute
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

            -- Handle the style attribute: remove, transform, or leave as-is
            if remove_style == true then
                modified_tag = modified_tag:gsub('%s*style%s*=%s*"[^"]*"', '')
            elseif type(remove_style) == "function" then
                local style_attr = modified_tag:match('style%s*=%s*"[^"]*"')
                local style_val = style_attr and style_attr:match('style%s*=%s*"([^"]*)"') or ""
                local new_style = remove_style(style_val)
                if new_style and new_style ~= "" then
                    -- Distinguish "no style attribute" from an explicitly
                    -- empty one (style=""): replace in place if present,
                    -- otherwise insert a new attribute.
                    if style_attr then
                        modified_tag = modified_tag:gsub('style%s*=%s*"[^"]*"', 'style="' .. new_style .. '"')
                    else
                        modified_tag = modified_tag:gsub('^(<[^>]+)', '%1 style="' .. new_style .. '"')
                    end
                end
            end

            -- Tidy up any leftover double spaces
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
Media removal inside kept infobox tables
--]]

-- Removes, wholesale, every <td>...</td> cell inside a table matching
-- `class_patterns` whose content contains an image/media element (<img>,
-- <video>, <audio>, <figure>, a <span typeof="mw:File..."> wrapper or a
-- kartographer <mapframe>). The caption/title text of such a cell is a
-- sibling or child of the image (e.g. a "infobox-caption" div, or the
-- ib-settlement-cols caption rows next to each symbol image), so dropping
-- the whole cell removes the image AND its caption together -- exactly
-- what we want for a kept full-width infobox: the box keeps its text data
-- but shows no media and no captions (QR codes included, since this runs
-- before the QR replacement pass).
--
-- Nesting is handled the same way as stripElementsByAttr: a nested table
-- inside a cell contributes its own <td> opens/closes, and the depth walk
-- over <td>/</td> still finds the matching close of the outer cell, so
-- whole media-bearing sub-regions (nested maps, symbol stacks) go away as
-- one unit.
--
-- Cells with class "infobox-image" or "infobox-caption" are dropped even
-- without media content, for legacy layouts where the caption sits in its
-- own row.
--
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

-- Inner helper: given the content between the <table ...> and </table> of
-- a matching table, drop every <td>...</td> block that contains media (or
-- is an infobox-image/infobox-caption cell). Exposed for testing.
function M.stripImageCellsInBlock(block)
    local out = {}
    local pos = 1
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
        local content = block:sub(open_end + 1, close_start - 1):lower()
        local has_media = content:find("<img", 1, true)
            or content:find("<video", 1, true)
            or content:find("<audio", 1, true)
            or content:find("<figure", 1, true)
            or content:find("<mapframe", 1, true)
            or content:find('typeof="mw:file', 1, true)
        if has_media or cell_class:find("infobox-image", 1, true) or cell_class:find("infobox-caption", 1, true) then
            -- Media-bearing cell (image + any caption): drop the whole cell.
            table.insert(out, block:sub(pos, open_start - 1))
        else
            table.insert(out, block:sub(pos, close_end))
        end
        pos = close_end + 1
    end
    -- Dropped cells leave empty <tr></tr> rows behind; remove them so
    -- they don't add stray spacing in the reflowed layout.
    local result = table.concat(out)
    return (result:gsub("<tr[^>]*>%s*</tr%s*>", ""))
end

--[[-------------------------------------------------------------------------
Infobox cell alignment
--]]

-- Centers the full-width cells of kept infoboxes (.infobox-title/above/
-- header/subheader/image/full-data/below) by putting text-align:center
-- directly on each cell as an inline style, mirroring Wikipedia's own
-- stylesheet (MediaWiki:Common.css centers exactly these classes).
--
-- This is done as an inline style -- not (only) a stylesheet rule --
-- because Wikipedia itself emits style="text-align:left" inline on the
-- .infobox-label/.infobox-data pairs, and the same inline mechanism is
-- what reliably applies in crengine: the base EPUB stylesheet has no
-- .infobox rules at all, so those full-width rows would otherwise fall
-- back to the cell's default left alignment.
--
-- Cells already carrying an explicit text-align declaration are left
-- alone; everything else gets the alignment appended to its existing
-- style attribute (or a new one). Only cells inside infobox tables are
-- touched -- the class names are distinctive enough that scoping is done
-- by matching them directly.
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
        if style_attr then
            if style_attr:find('text%-align%s*:') then
                return tag -- explicit alignment wins
            end
            -- Append inside the existing style="..." (function replacement:
            -- the style text may contain % (e.g. font-size:80%) and gsub
            -- function replacements never re-parse % in their result).
            return (tag:gsub('(style%s*=%s*")([^"]*)(")', function(prefix, value, suffix)
                if value == "" then
                    return prefix .. "text-align:center" .. suffix
                end
                if value:match(';%s*$') then
                    return prefix .. value .. "text-align:center" .. suffix
                end
                return prefix .. value .. ";text-align:center" .. suffix
            end))
        end
        -- No style attribute: insert one right after the tag name.
        return (tag:gsub('^(<[^%s>]+)', '%1 style="text-align:center"'))
    end))
end

--[[-------------------------------------------------------------------------
Quote attribution (Template:Quote) merging
--]]

-- MediaWiki renders Template:Quote / Template:Blockquote as a <blockquote>
-- immediately followed by a sibling <div class="templatequotecite"> holding
-- the attribution line (the name / source of the person who said it). Left
-- outside the blockquote, that line dangles below the styled quote box as an
-- unstyled, disconnected afterthought, which looks bad in the reflowed EPUB.
-- This moves the attribution *inside* the blockquote -- as a trailing
-- <div class="wikireader-cite"> that the stylesheet styles as a
-- right-aligned attribution line -- so each quote renders as a single,
-- self-contained box.
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

        -- The attribution div must directly follow </blockquote> (only
        -- whitespace in between) for it to belong to this quote.
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
                -- Drop the inline style on the inner <p> (a fixed left padding
                -- and display override meant for the web layout).
                cite_content = cite_content:gsub('(<p[^>]*%s)style%s*=%s*"[^"]*"', '%1')
                cite_content = cite_content:gsub('<p style="[^"]*">', '<p>')
                cite_content = cite_content:gsub('<p%s+>', '<p>')

                table.insert(out, html:sub(pos, bq_start - 1))  -- text before this quote
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

-- Skips whitespace, HTML comments, <style>...</style> blocks,
-- self-closing <link .../> / <meta .../> tags, and empty <p></p>
-- elements sitting at `pos`. Real Wikipedia HTML interleaves
-- <style>/<link> between sibling elements for CSS deduplication (one
-- per hatnote/banner, in between them), and MediaWiki emits empty
-- <p class="mw-empty-elt"> tags as spacing artifacts around templates.
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
-- MediaWiki -- both the legacy parser and Parsoid -- wraps the entire
-- rendered article body in <div class="mw-parser-output">...</div>.
-- That wrapper is the actual first element in the HTML, and its own
-- class matches none of our notice patterns, so without accounting for
-- it the scan above finds nothing at all and gives up immediately --
-- looking inside it instead (while leaving its own opening/closing tags
-- exactly where they are in the final output) is what makes detection
-- work in practice.
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

-- Scans the full HTML for any notice elements (hatnotes, maintenance banners
-- such as ambox/tmbox/cmbox/ombox/dmbox/fmbox) that were NOT caught by
-- extractLeadingNotices() -- i.e. section-level notices like "This section
-- has multiple issues...", "This section needs more citations..." -- and
-- wraps each one in a <div class="wikireader-notices"> box.
--
-- This is deliberately a second pass applied to the "rest" HTML after
-- extractLeadingNotices() has already handled the front-of-article notices,
-- to avoid double-wrapping them.
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

return M
