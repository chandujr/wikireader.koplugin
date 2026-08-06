--[[--
WikiReader plugin for KOReader.

Adds a "WikiReader" entry to the main menu. From it you can search
Wikipedia, open a featured article (today's, a date you pick, or a random
one), set the Wikipedia language edition, and step back through articles
you've read. Whatever you pick is fetched, converted to an EPUB (reusing
the same conversion code KOReader's built-in Wikipedia lookup already
uses), and opened straight into the reader -- headings, images, and a
table of contents all render normally, because it *is* a normal EPUB.

Images are permanently disabled -- articles download and open without
ever asking, since dozens of images can otherwise take a long time to
fetch before you can start reading.

The last 10 distinct articles you've visited are kept as actual EPUB
files (not re-downloaded every time you land on them again) for up to a
day. Diving into an 11th distinct article evicts the oldest one; either
way, anything older than a day is treated as stale and re-fetched. This
cache is plain files on disk, tracked via their own timestamps rather
than an in-memory list, so it survives closing and reopening KOReader --
it's also what backs the back-history described below, so stepping back
through articles you recently read is usually instant rather than a
fresh download.

Tapping a Wikipedia link *inside* an already-open article is also hooked:
it's added as a "Read as book" option on the reader's normal external-link
dialog (replacing the stock "Read online" popup button), and follows the
link the same way -- fetch (or serve from cache), open -- via
switchDocument().

Following links keeps a back-history too: each article you navigate away
from (by tapping a link) is remembered, so "Wikipedia > Back to previous
article" in the menu (or a gesture bound to the "Wikipedia: back to
previous article" action in Settings > Gestures) steps back through
ArticleC -> ArticleB -> ArticleA.

Infobox tables, campaignbox/navbox chronology boxes, route-map (RMbox)
tables, sidebar boxes, image-caption boxes, side-boxes (this covers the
{{listen}} audio-sample box among other supplementary side content --
pointless in an epub regardless, since crengine has no audio playback
capability at all), the shortdescription hidden metadata div, and the
category list at the bottom of the page are stripped from the HTML
before conversion -- they tend to make a mess of a single-column
reflowable layout, and the caption/audio boxes in particular are
pointless once images/audio are disabled (an empty bordered box with
just a caption or description left in it). The shortdescription is
hidden metadata that would otherwise produce an empty bordered box when
misidentified as a hatnote. This handles both of Wikipedia's current
image markup conventions (it's mid-migration between the two as of
2025-2026), not just one. Links to a specific section (...#Some_Section)
are recognized the same as any other article link; the section anchor
itself is dropped, though, so the article opens from the top rather than
jumping straight to that heading.

createEpub()'s own front matter is trimmed down to just the article
title -- the "Wikipedia EN" subtitle and the "Saved on <date> / See
online version for up-to-date content" paragraph are both dropped
(meaningless here since nothing is kept around long enough to go stale).
Any hatnotes (disambiguation/redirect notices) or maintenance banners
sitting at the very start of the article are pulled into their own
bordered box, with a divider right after them, so it's visually clear
they're front matter rather than the article itself. Detecting these
correctly, confirmed against real API responses from more than one
article, means accounting for several things MediaWiki interleaves
between the actual notice elements: the whole article body is wrapped in
<div class="mw-parser-output">, which has to be looked inside rather than
treated as "not a notice, stop here"; <style>/<link> tags used for CSS
deduplication; and empty <p class="mw-empty-elt"> spacing artifacts --
any of these sitting between two notices, unhandled, makes the scan stop
after the first one and treat everything past it (remaining notices
included) as regular article text.

Install: copy this whole wikireader.koplugin folder into your
koreader/plugins/ directory (on Kindle: .../koreader/plugins/), then
restart KOReader.
--]]--

local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local DocSettings = require("docsettings")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local socket_url = require("socket.url")
local util = require("util")
local T = require("ffi/util").template
local _ = require("gettext")

local WikiReader = WidgetContainer:extend{
    name = "wikireader",
    -- Change this if you want a different edition of Wikipedia.
    lang = "en",
}

-- Back-navigation history, kept at module level rather than as a `self.`
-- instance field. KOReader loads this plugin file once (via dofile) and
-- reuses the same class table for every UI it creates -- a fresh
-- WidgetContainer instance gets built each time you enter the FileManager
-- or the Reader. A `self.history` field would reset right when it
-- mattered most: the moment you go from "opened Wikipedia from the menu"
-- to "tapped a link inside the article". Module-level locals survive
-- that jump because they belong to the one-time dofile(), not to any
-- particular instance.
local nav_history = {}  -- stack of {title=.., lang=..}, oldest first
local nav_current = nil -- {title=.., lang=..} of the article now open

local lfs = require("libs/libkoreader-lfs")

-- Article cache: up to CACHE_MAX_ENTRIES distinct articles, each valid
-- for CACHE_MAX_AGE_SECONDS. This is deliberately just files on disk,
-- named deterministically from (title, lang) and read via filesystem
-- timestamps rather than an in-memory index -- so there's nothing that
-- can be "forgotten" across a KOReader restart, or across the jump
-- between plugin instances (File Manager vs Reader): the answer is
-- always sitting right there in the directory listing.
local CACHE_MAX_ENTRIES = 10
local CACHE_MAX_AGE_SECONDS = 24 * 60 * 60 -- 1 day

local function getCacheDir()
    local dir = DataStorage:getFullDataDir() .. "/cache/wikireader"
    if not util.pathExists(dir) then
        util.makePath(dir)
    end
    return dir
end

-- Deletes a cached epub and its associated .sdr sidecar (reading
-- progress, bookmarks, highlights, etc.). KOReader creates one of these
-- alongside every document it opens; plain os.remove() on the epub
-- leaves it behind as an orphaned folder. DocSettings.updateLocation()
-- with no destination path is exactly what KOReader's own file manager
-- calls when you delete a book -- reusing it here means eviction and
-- expiry clean up after themselves the same way a manual delete would.
local function removeCachedFile(path)
    os.remove(path)
    DocSettings.updateLocation(path)
end

-- Deterministic, filesystem-safe path for a given (title, lang) pair.
-- Underscore/space are equivalent in Wikipedia titles (link hrefs use
-- underscores, search boxes and API responses tend to use spaces), so
-- normalize first to make sure both forms hit the same cached file.
local function getCachePath(title, lang)
    local dir = getCacheDir()
    local normalized = title:gsub("_", " ")
    local filename = util.getSafeFilename(string.format("%s - %s.epub", lang or "en", normalized), dir)
    return dir .. "/" .. filename
end

-- Returns the path if a still-fresh (< 1 day old) cached copy exists;
-- otherwise nil, deleting the file first if it exists but has expired.
local function getFreshCachePath(title, lang)
    local path = getCachePath(title, lang)
    local attr = lfs.attributes(path)
    if not attr then
        return nil
    end
    if os.time() - attr.modification > CACHE_MAX_AGE_SECONDS then
        removeCachedFile(path) -- stale: clean it up (epub + sidecar), report a cache miss
        return nil
    end
    return path
end

-- Keep at most CACHE_MAX_ENTRIES cached articles: delete anything
-- stale, then evict the oldest (by download time) until back under the
-- cap. A simple capped FIFO -- matching "dive more than 10 links deep
-- and the first article gets dropped" -- revisiting a cached article
-- doesn't reset its place in line.
--
-- Listing and deleting are kept as two fully separate passes on
-- purpose: mutating a directory while still iterating it (the previous
-- version called os.remove() on stale files inside the lfs.dir() loop)
-- isn't guaranteed to visit every remaining entry on every filesystem,
-- which could silently undercount files and let more than
-- CACHE_MAX_ENTRIES pile up over time -- which is exactly the clutter
-- this function exists to prevent.
local function pruneCache()
    local dir = getCacheDir()

    local names = {}
    for name in lfs.dir(dir) do
        if name:match("%.epub$") then
            table.insert(names, name)
        end
    end

    local now = os.time()
    local entries = {}
    for _, name in ipairs(names) do
        local path = dir .. "/" .. name
        local attr = lfs.attributes(path)
        if attr then
            if now - attr.modification > CACHE_MAX_AGE_SECONDS then
                removeCachedFile(path)
            else
                table.insert(entries, { path = path, mtime = attr.modification })
            end
        end
    end

    table.sort(entries, function(a, b) return a.mtime < b.mtime end)
    while #entries > CACHE_MAX_ENTRIES do
        local oldest = table.remove(entries, 1)
        removeCachedFile(oldest.path)
    end
end

-- Minimal GET helper for the small JSON "featured article of the day" call.
-- Mirrors the request pattern KOReader's own frontend/ui/wikipedia.lua uses
-- internally for its Wikipedia API calls.
local function httpGetJSON(url)
    local http = require("socket.http")
    local ltn12 = require("ltn12")

    local sink = {}
    local ok, _, code = pcall(function()
        local _, response_code = http.request{
            url = url,
            method = "GET",
            sink = ltn12.sink.table(sink),
            headers = {
                -- Wikimedia asks API consumers to identify themselves.
                ["User-Agent"] = "KOReader-WikiReader-plugin/0.1 (personal use)",
            },
        }
        return true, response_code
    end)
    return ok, code, sink
end



-- Matches an in-article link like https://en.wikipedia.org/wiki/Some_Title
-- (optionally followed by #Section_Name or a ?query string) and returns
-- lang, url-escaped-title -- e.g. "en", "Some_Title" for
-- https://en.wikipedia.org/wiki/Some_Title#Some_Section. The section
-- fragment itself is intentionally discarded: we open the full article
-- from the top rather than attempt to land on that specific heading.
local function parseWikiLink(link_url)
    if not link_url then return nil end
    return link_url:match("^https?://([%w%-]+)%.wikipedia%.org/wiki/([^/?#]+)")
end

function WikiReader:onDispatcherRegisterActions()
    Dispatcher:registerAction("wikireader_go_back", {
        category = "none",
        event = "WikiReaderGoBack",
        title = _("WikiReader: back to previous article"),
        general = true,
    })
end

function WikiReader:init()
    -- Restore the persisted Wikipedia language, if any (defaults to English).
    self.lang = G_reader_settings:readSetting("wikireader_lang") or "en"
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    -- Self-heal the cache directory on every plugin load (File Manager
    -- entry, Reader entry, app restart -- whichever happens first) so
    -- it never sits above the cap between downloads either.
    pruneCache()

    -- Hook the reader's "what do you want to do with this link" dialog so
    -- tapping a Wikipedia link inside an article reads the linked article
    -- the same way, instead of KOReader's small built-in lookup popup.
    if self.ui and self.ui.link then
        -- Replace the stock "Read online" button (the clunky popup) --
        -- comment this line out if you'd rather keep both options.
        self.ui.link:removeFromExternalLinkDialog("40_wiki_lookup")

        self.ui.link:addToExternalLinkDialog("40_wikireader", function(this, link_url)
            local lang, escaped_title = parseWikiLink(link_url)
            return {
                text = _("Read as book"),
                callback = function()
                    UIManager:close(this.external_link_dialog)
                    local title = socket_url.unescape(escaped_title)
                    self:openArticleInPlace(title, lang)
                end,
                show_in_dialog_func = function()
                    if lang and escaped_title then
                        local title = socket_url.unescape(escaped_title):gsub("_", " ")
                        return true, T(_("Wikipedia (%1) article:\n\n%2"), lang:upper(), title)
                    end
                    return false
                end,
            }
        end)
    end
end

function WikiReader:addToMainMenu(menu_items)
    menu_items.wikireader = {
        text = _("WikiReader"),
        sub_item_table = {
            {
                -- Independent search entry (decoupled from the featured article).
                text = _("Search Wikipedia"),
                keep_menu_open = true,
                callback = function()
                    self:showLanding()
                end,
            },
            {
                -- Featured article entry, now with its own submenu offering
                -- today's article, a pickable date, or a random date.
                text = _("Featured Articles"),
                keep_menu_open = true,
                sub_item_table = {
                    {
                        text = _("Today's Featured Article"),
                        callback = function()
                            self:openFeaturedArticle()
                        end,
                    },
                    {
                        text = _("Pick a Date"),
                        callback = function()
                            self:showDatePicker()
                        end,
                    },
                    {
                        text = _("Random Date"),
                        callback = function()
                            self:openRandomFeaturedArticle()
                        end,
                    },
                },
            },
            {
                -- Set the Wikipedia language code (persisted across restarts).
                text_func = function()
                    return T(_("Wikipedia language: %1"), self.lang:upper())
                end,
                callback = function()
                    self:showLanguageDialog()
                end,
            },
            {
                text_func = function()
                    if #nav_history > 0 then
                        return T(_("Back to previous article (%1)"), #nav_history)
                    end
                    return _("Back to previous article")
                end,
                enabled_func = function()
                    return #nav_history > 0
                end,
                callback = function()
                    self:onWikiReaderGoBack()
                end,
            },
        },
    }

    -- Insert ourselves into the Search menu right after the built-in
    -- Wikipedia history entry, rather than relying on sorting_hint (which
    -- appends at the very end, pushing us onto the second page). The menu
    -- order tables are require()-cached singletons, so modifying them here
    -- is visible to the MenuSorter just like insert_menu.lua does.
    local function insertAfterWikipHistory(order_tbl)
        local search_menu = order_tbl.search
        if not search_menu then return end
        for i, entry in ipairs(search_menu) do
            if entry == "wikipedia_history" then
                table.insert(search_menu, i + 1, "wikireader")
                return
            end
        end
        -- Fallback: if no wikipedia_history found, just append
        table.insert(search_menu, "wikireader")
    end
    insertAfterWikipHistory(require("ui/elements/filemanager_menu_order"))
    insertAfterWikipHistory(require("ui/elements/reader_menu_order"))
end

-- The "landing page": a search box for a topic. (Featured articles have
-- their own dedicated menu entry and are not duplicated here.)
function WikiReader:showLanding()
    local dialog
    dialog = InputDialog:new{
        title = _("WikiReader"),
        input_hint = _("Search Wikipedia…"),
        description = _("Type a topic to search for."),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local title = dialog:getInputText()
                        if title and title ~= "" then
                            UIManager:close(dialog)
                            self:openArticle(title)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Normalize an arbitrary date table from the date picker into the
-- "YYYY/MM/DD" string the REST API expects.
local function formatApiDate(year, month, day)
    return string.format("%04d/%02d/%02d", year, month, day)
end

-- Prompt for a specific date via KOReader's built-in date picker, then
-- fetch that day's featured article.
function WikiReader:showDatePicker()
    local DateTimeWidget = require("ui/widget/datetimewidget")
    local today = os.date("*t")
    local date_widget = DateTimeWidget:new{
        title_text = _("Pick a date"),
        info_text = _("Fetch the featured article for a specific date."),
        year = today.year,
        month = today.month,
        day = today.day,
        year_min = 2001, -- Wikipedia's featured-article feed effectively starts here
        year_max = today.year,
        ok_text = _("Fetch"),
        callback = function(widget)
            self:openFeaturedArticle(formatApiDate(widget.year, widget.month, widget.day))
        end,
    }
    UIManager:show(date_widget)
end

-- Pick a uniformly random date between 2001-01-01 and today and fetch the
-- featured article that ran on it.
function WikiReader:openRandomFeaturedArticle()
    -- Reseed the PRNG right before drawing, so successive sessions (and
    -- successive picks within a session) don't repeat the same sequence:
    -- math.random starts from a fixed seed unless randomseed is called, and
    -- KOReader's startup seed (os.time()) only has 1s granularity.
    local time = require("ffi/util").gettime
    math.randomseed(math.floor(time() * 1000) % 2147483647)

    local start_t = os.time{ year = 2001, month = 1, day = 1 }
    local today = os.date("*t")
    local end_t = os.time{ year = today.year, month = today.month, day = today.day }
    if end_t <= start_t then end_t = os.time() end
    local random_t = start_t + math.random(0, end_t - start_t)
    local t = os.date("*t", random_t)
    self:openFeaturedArticle(formatApiDate(t.year, t.month, t.day))
end

-- Set the Wikipedia language edition used for all lookups. The chosen code
-- is persisted in KOReader's global settings so it survives a restart.
function WikiReader:showLanguageDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Set Wikipedia language"),
        input = self.lang,
        input_hint = _("Language code"),
        description = _("Enter the code of the Wikipedia edition to read from (e.g. en, de, fr, es, hi, zh…)."),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Set"),
                    is_enter_default = true,
                    callback = function()
                        local lang = dialog:getInputText()
                        if lang and lang ~= "" then
                            lang = lang:lower():gsub("%s+", "")
                            self.lang = lang
                            G_reader_settings:saveSetting("wikireader_lang", lang)
                        end
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Look up the featured article title for a given date (defaults to today),
-- then hand off to openArticle(). Pass a "YYYY/MM/DD" string to fetch a
-- specific day's article instead of today's.
function WikiReader:openFeaturedArticle(date)
    NetworkMgr:runWhenOnline(function()
        local info = InfoMessage:new{ text = _("Fetching featured article…") }
        UIManager:show(info)

        UIManager:scheduleIn(0, function()
            local date_str = date or os.date("%Y/%m/%d")
            -- Same host pattern ("<lang>.wikipedia.org") KOReader's built-in
            -- Wikipedia lookup already talks to -- no separate API key needed.
            local url = string.format(
                "https://%s.wikipedia.org/api/rest_v1/feed/featured/%s",
                self.lang, date_str
            )
            local ok, code, sink = httpGetJSON(url)
            UIManager:close(info)

            if not ok or code ~= 200 then
                UIManager:show(InfoMessage:new{
                    text = _("Couldn't fetch the featured article. Check your connection and try again."),
                })
                return
            end

            local JSON = require("json")
            local body = table.concat(sink)
            local parse_ok, data = pcall(JSON.decode, body)
            if not parse_ok or not data or not data.tfa then
                logger.warn("WikiReader: unexpected featured-content response", body)
                UIManager:show(InfoMessage:new{ text = _("Couldn't read the featured article for that date.") })
                return
            end

            local tfa = data.tfa
            -- Field names have shifted a little across API versions; try
            -- the likely candidates in order.
            local title = (tfa.titles and tfa.titles.normalized)
                or tfa.normalizedtitle
                or tfa.title
            if not title then
                UIManager:show(InfoMessage:new{ text = _("Couldn't identify the featured article for that date.") })
                return
            end

            self:openArticle(title)
        end)
    end)
end

-- Removes <tag ...>...</tag> blocks whose `attr_name` attribute matches
-- any of `attr_patterns`, correctly handling same-tag elements nested
-- inside them (an infobox table can contain a nested table; a div can
-- nest other divs). Lua's plain string patterns can't express "find the
-- matching close tag" on their own -- %b()-style balanced matching only
-- works for single-character delimiters -- so this walks the string by
-- hand instead, tracking nesting depth.
local function stripElementsByAttr(html, tag, attr_name, attr_patterns)
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
local function stripElementsByClass(html, tag, class_patterns)
    return stripElementsByAttr(html, tag, "class", class_patterns)
end

-- Fetches and converts an article, with images permanently disabled and
-- a handful of clutter elements stripped from the HTML before it's ever
-- handed to createEpub(): infobox tables, image-caption boxes, and the
-- category list at the bottom of the article. There's no parameter or
-- hook on createEpub() for filtering its HTML, so we temporarily replace
-- the lower-level function it calls internally to fetch that HTML
-- (getFullPageHtml), run the genuine one, clean up what it returns, and
-- put the original back immediately afterwards either way.
--
-- Image captions specifically need handling two different ways: Wikipedia
-- is mid-migration (through 2025-2026) from its legacy renderer to a
-- newer one called Parsoid, and the two mark up captioned images
-- completely differently -- legacy wraps them in <div class="thumb">,
-- Parsoid wraps them in <figure typeof="mw:File/Thumb"> with a
-- <figcaption>. Since which one any given request actually gets depends
-- on that rollout (wiki by wiki, gradually) rather than anything we
-- control, both are stripped so this doesn't quietly break again when
-- the rollout reaches wherever it hasn't already.
-- What counts as a "leading notice" for extractLeadingNotices() below:
-- hatnotes (disambiguation/redirect notices) and the maintenance/cleanup
-- banner family (the various "*mbox" classes Wikipedia's templates use).
-- "mw:transclusion" is kept as a fallback signal for cases where a
-- template's output is wrapped in a Parsoid transclusion div that
-- doesn't carry the inner class itself -- real Wikipedia HTML samples
-- checked while building this didn't actually need it (hatnotes/ambox
-- carried their class directly), but it's cheap, harmless insurance for
-- article/template combinations that do wrap that way.
local LEADING_NOTICE_TAGS = { "div", "table" }
local LEADING_NOTICE_PATTERNS = {
    "hatnote", "ambox", "tmbox", "cmbox", "ombox", "dmbox", "fmbox",
    "mw:transclusion",
}

local function elementIsLeadingNotice(open_tag)
    local class_attr = open_tag:match([[class%s*=%s*"([^"]*)"]]) or ""
    local typeof_attr = open_tag:match([[typeof%s*=%s*"([^"]*)"]]) or ""
    local combined = (class_attr .. " " .. typeof_attr):lower()
    for _, pat in ipairs(LEADING_NOTICE_PATTERNS) do
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
-- <p class="mw-empty-elt"> tags as spacing artifacts around templates --
-- without skipping these, a scan that only knows how to recognize
-- notice elements themselves stops dead at the first one, missing
-- everything after it (confirmed against two different real articles:
-- one needed the style/link handling, the other needed the empty-<p>
-- handling to get past the same shape of problem in a different spot).
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

-- Finds the close tag matching an already-found opening tag of `tag`
-- (given the position right after that opening tag), tracking nesting
-- depth so same-named descendants don't confuse the search. Returns the
-- close tag's start and end positions, or nil if unclosed/malformed.
local function findMatchingClose(html, tag, open_end)
    local open_pat = "<" .. tag .. "[^>]*>"
    local close_pat = "</" .. tag .. "%s*>"
    local depth = 1
    local scan_pos = open_end + 1
    while depth > 0 do
        local next_open_start, next_open_end = html:find(open_pat, scan_pos)
        local next_close_start, next_close_end = html:find(close_pat, scan_pos)
        if not next_close_start then
            return nil
        elseif next_open_start and next_open_start < next_close_start then
            depth = depth + 1
            scan_pos = next_open_end + 1
        else
            depth = depth - 1
            if depth == 0 then
                return next_close_start, next_close_end
            end
            scan_pos = next_close_end + 1
        end
    end
end

local function extractLeadingNoticesInner(html)
    local pos = skipLeadingCruft(html, 1)
    local notices = {}
    while true do
        local matched_tag, open_start, open_end
        for _, tag in ipairs(LEADING_NOTICE_TAGS) do
            local o_start, o_end = html:find("^<" .. tag .. "[^>]*>", pos)
            if o_start and elementIsLeadingNotice(html:sub(o_start, o_end)) then
                matched_tag, open_start, open_end = tag, o_start, o_end
                break
            end
        end
        if not matched_tag then
            break -- next element isn't a notice -- this is where the real article starts
        end
        local close_start, close_end = findMatchingClose(html, matched_tag, open_end)
        if not close_end then
            return table.concat(notices), html:sub(pos) -- malformed: bail, keep the rest as-is
        end
        table.insert(notices, html:sub(pos, close_end))
        pos = skipLeadingCruft(html, close_end + 1)
    end
    return table.concat(notices), html:sub(pos)
end

-- Pulls any hatnotes/maintenance-template elements sitting right at the
-- very start of the article HTML out into their own string, leaving
-- everything from the genuine first paragraph/heading onward in a
-- second string. Only looks at the front of the document -- a
-- maintenance banner turning up mid-article (rare, but possible) is left
-- exactly where it is.
--
-- MediaWiki -- both the legacy parser and Parsoid, confirmed against a
-- real API response -- wraps the entire rendered article body in
-- <div class="mw-parser-output">...</div>. That wrapper is the actual
-- first element in the HTML, and its own class matches none of our
-- notice patterns, so without accounting for it the scan above finds
-- nothing at all and gives up immediately -- looking inside it instead
-- (while leaving its own opening/closing tags exactly where they are in
-- the final output) is what makes detection work in practice rather than
-- only in a hand-built test case.
local function extractLeadingNotices(html)
    local wrap_open_start, wrap_open_end = html:find('^<div[^>]-class="[^"]*mw%-parser%-output[^"]*"[^>]*>')
    if not wrap_open_start then
        return extractLeadingNoticesInner(html)
    end
    local wrap_close_start = findMatchingClose(html, "div", wrap_open_end)
    if not wrap_close_start then
        return extractLeadingNoticesInner(html)
    end
    local prefix = html:sub(1, wrap_open_end)
    local inner = html:sub(wrap_open_end + 1, wrap_close_start - 1)
    local suffix = html:sub(wrap_close_start)
    local notices, rest = extractLeadingNoticesInner(inner)
    return notices, prefix .. rest .. suffix
end

function WikiReader:buildEpub(epub_path, title, lang, callback)
    local Wikipedia = require("ui/wikipedia")
    local Trapper = require("ui/trapper")
    local Archiver = require("ffi/archiver")

    -- Will hold the short description extracted from HTML
    local short_description = nil
    -- Will hold the resolved article title from the API response (used to
    -- fix the epub metadata and cache filename when the search term doesn't
    -- match the canonical title, e.g. "french revolution" -> "French Revolution").
    local resolved_title = nil

    -- KOReader's wiki_phtml_params (the query for getFullPageHtml, which
    -- createEpub() calls) is the one place that's missing a `redirects`
    -- marker -- wiki_full_params and wiki_images_params both set it. Without
    -- it, a link that points at a redirect (e.g. "Upper_New_York_Bay", which
    -- Wikipedia redirects to "New_York_Harbor") fetches the redirect stub's
    -- HTML instead of following through to the real article, so the epub
    -- becomes a "middleman" page full of links rather than the article
    -- itself. The `parse` API action does support `redirects`; we just have
    -- to ask for it. Patch it in for the duration of the build and put it
    -- back afterwards, exactly like the getFullPageHtml/Archiver patches.
    local original_phtml_redirects = Wikipedia.wiki_phtml_params.redirects
    Wikipedia.wiki_phtml_params.redirects = ""

    local original_getFullPageHtml = Wikipedia.getFullPageHtml
    Wikipedia.getFullPageHtml = function(self, wiki_title, wiki_lang)
        local result = original_getFullPageHtml(self, wiki_title, wiki_lang)
        if result and result.text and result.text["*"] then
            local html = result.text["*"]

            -- Extract short description from the HTML before stripping it.
            --
            -- NOTE: this div is NOT always present in the HTML returned by
            -- the `parse` action. As Wikipedia's Parsoid rollout proceeds, the
            -- server can return a response that omits <div class="shortdescription">
            -- entirely (observed on some devices/CDN edges even for articles that
            -- do have a short description). So this is only the first attempt;
            -- if it fails we fall back to the query API's pageprops below.
            local short_desc_pat = '<div[^>]*class="[^"]*shortdescription[^"]*"[^>]*>(.-)</div>'
            local short_desc_match = html:match(short_desc_pat)
            if short_desc_match then
                -- Decode HTML entities and clean up whitespace
                short_description = short_desc_match:gsub('&[^;]+;', ' '):gsub('%s+', ' '):match('^%s*(.-)%s*$')
                if short_description == '' then
                    short_description = nil
                end
            end

            -- Fallback: the short description lives authoritatively in the
            -- query API's pageprops as "wikibase-shortdesc", independent of
            -- whatever HTML rendering the `parse` action happened to return.
            -- Reaching for it here keeps the epub working even when the HTML
            -- omits the shortdescription div.
            if not short_description then
                local JSON = require("json")
                local props_url = string.format(
                    "https://%s.wikipedia.org/w/api.php?action=query&prop=pageprops&titles=%s&format=json",
                    wiki_lang or "en", socket_url.escape(wiki_title)
                )
                local props_ok, props_code, props_sink = httpGetJSON(props_url)
                if props_ok and props_code == 200 then
                    local props_parse_ok, props_data = pcall(JSON.decode, table.concat(props_sink))
                    if props_parse_ok and props_data and props_data.query and props_data.query.pages then
                        for _, props_page in pairs(props_data.query.pages) do
                            if props_page.pageprops and props_page.pageprops["wikibase-shortdesc"] then
                                short_description = props_page.pageprops["wikibase-shortdesc"]
                                break
                            end
                        end
                    end
                end
            end

            -- Capture the resolved title from the API response so we can fix
            -- the epub metadata and cache filename later (the title passed into
            -- createEpub is the raw search term, which may differ in case etc.).
            if result.title then
                resolved_title = result.title
            end
            
            -- "navbox" also covers campaignbox (the "V·T·E ..." collapsible
            -- box for military-conflict chronologies, etc.) -- Campaignbox
            -- is itself built on top of the generic Navbox template, and
            -- despite being passed as a parameter *into* Infobox military
            -- conflict, it renders as a separate sibling table right after
            -- the infobox's own table rather than nested inside it, so it
            -- needs its own entry here to be caught. "rmbox" covers the
            -- route-map ({{Routemap}}) collapsible tables that Wikipedia's
            -- route-map templates render as huge full-width diagram boxes
            -- (e.g. river/railway course maps) -- a mess in a single-column
            -- reflowable epub layout, so strip them like the other box
            -- tables.
            html = stripElementsByClass(html, "table", { "infobox", "navbox", "sidebar", "vertical-navbox", "rmbox" })
            -- "side-box" covers the {{listen}}/audio-sample box (icon,
            -- play button, description, "Problems playing this file?"
            -- footer) among other supplementary side-content templates.
            -- Unlike hatnotes/maintenance banners, these can turn up
            -- anywhere in the article body, not just at the very start,
            -- so this needs the general strip here rather than the
            -- leading-notices handling below -- and they're doubly
            -- pointless in an epub anyway, since crengine has no audio
            -- playback capability at all. "shortdescription" is the hidden
            -- metadata div MediaWiki emits at the very top of (almost)
            -- every article; it has style="display:none" so it's never
            -- visible itself, but it *used* to be caught by the
            -- leading-notices scan as a "notice" and pulled into the
            -- front-matter box -- rendering as an empty bordered box on
            -- articles with no real hatnotes. It's metadata, not a notice,
            -- so strip it outright rather than treat it as one.
            html = stripElementsByClass(html, "div", { "thumb", "catlinks", "navbox", "vertical-navbox", "side-box", "shortdescription" })
            html = stripElementsByClass(html, "ul", { "gallery" })
            -- Coordinates rendered by {{coord}} templates (e.g. "54°44′28″N 2°06′36″W")
            -- are useless in an epub and just clutter the lead paragraph.
            html = stripElementsByClass(html, "span", { "geo-inline-hidden" })
            -- Parsoid's captioned-image markup.
            html = stripElementsByAttr(html, "figure", "typeof", { "mw:file", "mw:image", "mw:video", "mw:audio" })
            -- Belt and braces: strip any stray <audio> elements directly,
            -- in case some other template ever embeds one outside a
            -- side-box wrapper.
            html = html:gsub("<audio.-</audio%s*>", "")

            -- Pull any hatnotes/maintenance banners off the very front of
            -- the article into their own bordered box (so it's visually
            -- obvious they're not part of the article text itself), and
            -- put a divider right after them -- or, if there weren't any,
            -- right at the very start -- to separate that front section
            -- from the real lead paragraph.
            local notices, rest = extractLeadingNotices(html)
            if notices ~= "" then
                html = string.format(
                    [[<div class="wikireader-notices" style="border:1px solid #888; padding:0.6em 0.8em; margin:0 0 1em 0; font-style:italic;">%s</div><hr class="koreaderwikifrontpage"/>%s]],
                    notices, rest
                )
            else
                html = [[<hr class="koreaderwikifrontpage"/>]] .. rest
            end

            result.text["*"] = html
        end
        return result
    end

    -- createEpub() also writes its own front-matter directly into
    -- content.html at the very end -- a title, a "Wikipedia EN" subtitle,
    -- a "Saved on <date> / See online version for up-to-date content"
    -- paragraph, and a divider (all tagged class="koreaderwikifrontpage").
    -- That's not part of the article HTML at all, so the getFullPageHtml
    -- hook above can't reach it; it only exists once the epub's zip entry
    -- itself is written. We want the subtitle and paragraph gone (title
    -- stays), and the divider removed from here since the hook above
    -- already inserted its own -- positioned after any hatnote/maintenance
    -- box -- at the start of the article content instead.
    --
    -- The same hook also appends a real stylesheet rule for the notices
    -- box (in addition to its inline style) when content.html actually
    -- contains one -- belt and braces, in case inline style= ever proves
    -- less reliable here than a genuine stylesheet class.
    --
    -- We also add the short description as a subtitle paragraph after the
    -- main title if one was successfully fetched.
    local original_addFileFromMemory = Archiver.Writer.addFileFromMemory
    Archiver.Writer.addFileFromMemory = function(self, entry_path, content, mtime)
        if entry_path == "OEBPS/content.html" then
            content = stripElementsByClass(content, "p", { "koreaderwikifrontpage" })
            content = stripElementsByClass(content, "h5", { "koreaderwikifrontpage" })
            content = content:gsub('<hr class="koreaderwikifrontpage"%s*/?>', "", 1)
            -- Add short description as subtitle after the title.
            -- Use a <div> instead of a <p> to avoid the default paragraph margins
            -- and padding that crengine applies, which can throw off centering.
            if short_description and short_description ~= "" then
                -- Find the title heading and add description after it with center alignment
                content = content:gsub(
                    '(<h1[^>]*>.-</h1>)',
                    '%1\n<div style="font-style:italic; color:#666; margin-top:0.2em; margin-bottom:1em; text-align:center;">' .. short_description .. '</div>'
                )
            end
            -- Fix the HTML <title> element in the head if the API returned a
            -- canonical title that differs from the search term.
            if resolved_title then
                content = content:gsub('(<title>).-(</title>)', '%1' .. resolved_title .. '%2')
            end
        elseif entry_path == "OEBPS/content.opf" then
            -- Fix the <dc:title> metadata if the API returned a canonical title
            -- that differs from the search term.
            if resolved_title then
                content = content:gsub('(<dc:title>).-(</dc:title>)', '%1' .. resolved_title .. '%2')
            end
        elseif entry_path == "OEBPS/toc.ncx" then
            -- Fix the title in the NCX docTitle and the root navPoint label.
            if resolved_title then
                content = content:gsub('(<docTitle>%s*<text>).-(</text>%s*</docTitle>)', '%1' .. resolved_title .. '%2')
                content = content:gsub('(<navPoint[^>]*>%s*<navLabel>%s*<text>).-(</text>%s*</navLabel>%s*<content src="content%.html"/>)', '%1' .. resolved_title .. '%2')
            end
        elseif entry_path == "OEBPS/stylesheet.css" then
            content = content .. [[

.wikireader-notices {
  border: 1px solid #888;
  padding: 0.6em 0.8em;
  margin: 0 0 1em 0;
  font-style: italic;
  font-size: 80%;
}

blockquote {
  background: #f4f4f4;
  border-left: 3px solid #ccc;
  padding: 0.5em 0.8em;
  margin: 0.5em 0;
  font-style: italic;
}
]]
        end
        return original_addFileFromMemory(self, entry_path, content, mtime)
    end

    Trapper:wrap(function()
        local ok, success = pcall(Wikipedia.createEpub, Wikipedia, epub_path, title, lang, false)
        -- Always restore all patches, success or not.
        Wikipedia.wiki_phtml_params.redirects = original_phtml_redirects
        Wikipedia.getFullPageHtml = original_getFullPageHtml
        Archiver.Writer.addFileFromMemory = original_addFileFromMemory
        if ok and success then
            -- If the API resolved the title to a canonical form (e.g.
            -- "french revolution" -> "French Revolution"), rename the cache
            -- file to match so subsequent lookups hit the right cache entry.
            local used_path = epub_path
            if resolved_title and resolved_title ~= title then
                local new_path = getCachePath(resolved_title, lang)
                if new_path ~= epub_path then
                    os.rename(epub_path, new_path)
                    DocSettings.updateLocation(epub_path, new_path)
                    used_path = new_path
                end
            end
            callback(true, used_path)
        else
            Trapper:reset()
            callback(false)
        end
    end)
end

-- Shared plumbing: serve `title` from the cache if we have a fresh-enough
-- copy; otherwise fetch it, cache it, and hand the resulting path to
-- `open_fn`. `open_fn` is what differs between "open fresh" (from the
-- main menu) and "replace the article I'm already reading" (a tapped
-- link or a back-navigation step).
function WikiReader:fetchAndOpen(title, lang, open_fn)
    lang = lang or self.lang

    local cached_path = getFreshCachePath(title, lang)
    if cached_path then
        open_fn(cached_path)
        return
    end

    NetworkMgr:runWhenOnline(function()
        local epub_path = getCachePath(title, lang)
        self:buildEpub(epub_path, title, lang, function(success, used_path)
            if not success then
                UIManager:show(InfoMessage:new{
                    text = _("Couldn't download that article. Check the title and your connection."),
                })
                return
            end
            pruneCache()
            open_fn(used_path or epub_path)
        end)
    end)
end

-- Open an article as a brand new reader session (from the main menu:
-- search, or today's featured article). Safe to call whether or not
-- something else is currently open -- ReaderUI:showReader() signals any
-- existing reader to close itself first. This is a fresh starting point,
-- so it clears any earlier back-history.
function WikiReader:openArticle(title, lang)
    self:fetchAndOpen(title, lang, function(epub_path)
        nav_history = {}
        nav_current = { title = title, lang = lang or self.lang }
        local ReaderUI = require("apps/reader/readerui")
        ReaderUI:showReader(epub_path)
    end)
end

-- Open an article in place of the one currently being read (a tapped
-- in-article link). switchDocument() properly closes the current
-- document (menus, highlights, etc.) before opening the new one --
-- this is the same call KOReader's own built-in Wikipedia epub handling
-- uses for the equivalent "read this instead" action. The article we're
-- navigating away from is pushed onto the back-history stack.
function WikiReader:openArticleInPlace(title, lang)
    local from_article = nav_current
    self:fetchAndOpen(title, lang, function(epub_path)
        if from_article then
            table.insert(nav_history, from_article)
        end
        nav_current = { title = title, lang = lang or self.lang }
        self.ui:switchDocument(epub_path)
    end)
end

-- Step back to the article you were on before the last link you
-- followed. Usually instant (served from the cache above); only needs
-- a network connection if that article's cached copy has expired or
-- was itself evicted since.
function WikiReader:onWikiReaderGoBack()
    if #nav_history == 0 then
        UIManager:show(InfoMessage:new{ text = _("No previous Wikipedia article to go back to.") })
        return
    end
    local prev = nav_history[#nav_history]
    self:fetchAndOpen(prev.title, prev.lang, function(epub_path)
        table.remove(nav_history)
        nav_current = prev
        -- This menu entry/gesture is reachable from the File Manager too
        -- (e.g. you went a few articles deep, then closed the reader) --
        -- self.ui there has no switchDocument(), so fall back to opening
        -- a fresh reader session in that case.
        if self.ui and self.ui.switchDocument then
            self.ui:switchDocument(epub_path)
        else
            local ReaderUI = require("apps/reader/readerui")
            ReaderUI:showReader(epub_path)
        end
    end)
end

return WikiReader