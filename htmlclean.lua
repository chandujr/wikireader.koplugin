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
Media removal inside kept infobox tables and inline flags
--]]

-- Cleans up the inside of a kept table (a kept full-width infobox). Two
-- distinct things are removed, because keeping raw media would break the
-- single-column reflowable layout:
--
--   1. Genuine media cells -- a cell whose content is basically an image
--      box (lead portrait, map, emblem/symbol stack, a <figure>, audio/
--      video, kartographer <mapframe>, ...). The caption/title text of
--      such a cell is a sibling or child of the image (e.g. a
--      "infobox-caption" div, or the ib-settlement-cols caption rows next
--      to each symbol image). The whole cell -- image and caption -- is
--      dropped, so the box keeps only its surrounding text data. This runs
--      before the QR pass, so no QR placeholder is ever generated here.
--
--   2. Small inline icons (flags) that sit *beside* real text in a cell --
--      the country flags next to combatants'/commanders' names in battle/
--      war infoboxes, or the flags next to the strength/casualties rows.
--      These are just the icon; the name/link/footnote it decorates is its
--      own text, so the cell must *not* be lost. Instead only the icon
--      bubble -- any <span> wrapping a tiny (<=24px) inline <img> flag or
--      status glyph, whether it is classed `flagicon` or an inline `mw:File`
--      span, even one with a `mw-file-description` link -- is removed and
--      the text is kept.
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

-- Removes small inline icon bubbles from `content` while keeping the text
-- they sit beside them. In a war/battle infobox a tiny inline icon (the
-- 20-24px country flags / surrender / casualty / WIA / ranking-arrow
-- glyphs) is placed *beside* a named entity or a number: it wraps only the
-- small image and none of the surrounding name/link/footnote text, so
-- removing the whole bubble strips just the icon and keeps what it
-- decorated.
--
-- Genuine media (a lead painting, a header image collage, an emblem/coat
-- of arms, a map) is displayed *large*: its <img> is rendered at 60px or
-- more (typically 120-300px), or it is a <table>/<figure>/<mapframe>/<video>
-- /<audio> box. The discriminator is therefore the <img> display width:
-- images at 24px and under are inline icons, anything larger (or non-<img>
-- media) is genuine figure media that must be left in place so the caller
-- can drop the whole image cell. Relying on the anchor's CSS class does
-- not work: the tiny flags may be wrapped in either `class="flagicon"`
-- or a plain `<span typeof="mw:File">…</span>` *whose `<a class="mw-file-
-- description">` link is identical to a real thumbnail's*. Only the
-- rendered size tells them apart.
--
-- Icon bubbles never nest another flagicon, but their inner markup can
-- contain other spans (mw-image-border / mw:File) and an optional <a>, so
-- the matching close span is found by the same depth walk used elsewhere.
-- Exposed for testing.
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

        -- A <span class="...flagicon..."> is always a small inline icon.
        -- A <span typeof="mw:File"> is a small inline icon when its inner
        -- <img> is rendered small (<=24px); genuine figure boxes carry a
        -- large <img> or a <table>/<figure>/<mapframe>/<video>/<audio> and
        -- are left intact for cellHasMedia to see.
        local iconish = false
        if lower:find("flagicon", 1, true) then
            iconish = true
        elseif lower:find('typeof%s*=%s*"mw:file', 1) then
            local _, close_end = wutil.findMatchingClose(content, "span", open_end)
            if close_end then
                local inner = content:sub(open_end + 1, close_end - 1)
                local imgw = M.imgDisplayWidth(inner)
                iconish = imgw ~= nil and imgw <= 24
            else
                -- Unclosed mw:File span: safest to treat as an icon and drop
                -- just its open tag, never swallowing following text.
                iconish = true
            end
        end

        if iconish then
            -- Inline icon bubble: drop it and keep the surrounding text.
            local _, close_end = wutil.findMatchingClose(content, "span", open_end)
            if not close_end then
                -- Unclosed bubble: drop just the open tag; never swallow
                -- the text that may follow it.
                table.insert(out, content:sub(pos, open_end))
                pos = open_end + 1
            else
                table.insert(out, content:sub(pos, open_start - 1))
                pos = close_end + 1
            end
        else
            -- Not an icon bubble (a text-only span or a genuine figure
            -- container): keep it, then ADVANCE ONLY past its open tag.
            -- This lets us still dig into nested spans (e.g. a flagicon
            -- lurking inside a <span class="nowrap">) and remove them,
            -- unlike skipping to the matching close.
            table.insert(out, content:sub(pos, open_end))
            pos = open_end + 1
        end
    end
    return table.concat(out)
end

-- Returns the rendered display width of the first <img ...> box inside
-- `s`, or nil if there is no <img> (or no width= attribute on it). Only the
-- *display* width (the `width="N"` attribute MediaWiki sets on the rendered
-- image) is meaningful; `data-file-width`/`srcset` carry the source pixel
-- size and must be ignored.
function M.imgDisplayWidth(s)
    local img = s:find("<img", 1, true)
    if not img then return nil end
    local close = s:find(">", img, true)
    if not close then return nil end
    -- limit to the tag; skip any data-file-width/ srcset embedded number by
    -- anchoring on a standalone width= before class="mw-file-element".
    local tag = s:sub(img, close)
    local _, _, w = tag:find('width%s*=%s*"(%d+)"%s+height')
    if not w then
        -- some images omit height; fall back to the first width attribute.
        _, _, w = tag:find('width%s*=%s*"(%d+)"')
    end
    return tonumber(w)
end

-- Returns true if a cell's content still holds a *genuine* media element
-- once the small inline icons have been removed: a real large image (its
-- <img> is rendered at more than 24px, i.e. a lead painting / header
-- collage / emblem / map), a <table> image box, a <figure>, a kartographer
-- <mapframe>, or <video>/<audio>. A cell still carrying one of these is a
-- real image cell and is dropped wholly; anything left is only
-- inline-icon-free text and is kept.
function M.cellHasMedia(content)
    if content:find("<video", 1, true)
        or content:find("<audio", 1, true)
        or content:find("<figure", 1, true)
        or content:find("<mapframe", 1, true) then
        return true
    end
    -- otherwise a real image box / large <img>: only when an <img> box is
    -- rendered larger than an inline icon (i.e. >24px).
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

        -- Remove any inline icon bubbles first (flags, surrender/WIA glyphs,
        -- ranking arrows): this drops the icons next to a name / number but
        -- keeps the surrounding text, unlike genuine media cells below.
        local stripped = M.removeInlineIcons(content)

        -- A cell that (still) holds a genuine image element, or that is an
        -- explicit infobox-image/infobox-caption cell, is a real media
        -- cell: drop it whole (image and its caption together, as before).
        local drop_cell = cell_class:find("infobox-image", 1, true)
            or cell_class:find("infobox-caption", 1, true)
            or M.cellHasMedia(stripped:lower())

        if drop_cell then
            -- Media-bearing cell (image + any caption): drop the whole cell.
            table.insert(out, block:sub(pos, open_start - 1))
        else
            -- The cell now holds only text (the flag icons are gone). If
            -- that left just a gap (an icon-only row), drop it too; keep
            -- the cell with its text otherwise.
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
