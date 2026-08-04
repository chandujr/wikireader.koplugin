--[[--
Wikipedia Reader plugin for KOReader.

Adds a "Wikipedia" entry to the main menu. Tapping it shows a small
landing dialog with a search box and a "Today's Featured Article" button.
Whatever you pick is fetched, converted to an EPUB (reusing the same
conversion code KOReader's built-in Wikipedia lookup already uses), and
opened straight into the reader -- headings, images, and a table of
contents all render normally, because it *is* a normal EPUB.

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
-- and returns lang, url-escaped-title (e.g. "en", "Some_Title").
local function parseWikiLink(link_url)
    if not link_url then return nil end
    return link_url:match("^https?://([%w%-]+)%.wikipedia%.org/wiki/([^/?#]+)$")
end

function WikiReader:onDispatcherRegisterActions()
    Dispatcher:registerAction("wikireader_go_back", {
        category = "none",
        event = "WikiReaderGoBack",
        title = _("Wikipedia: back to previous article"),
        general = true,
    })
end

function WikiReader:init()
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
        text = _("Wikipedia"),
        sorting_hint = "search",
        sub_item_table = {
            {
                text = _("Search / today's featured article"),
                keep_menu_open = true,
                callback = function()
                    self:showLanding()
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
end

-- The "landing page": a search box plus a button for today's featured article.
function WikiReader:showLanding()
    local dialog
    dialog = InputDialog:new{
        title = _("Wikipedia"),
        input_hint = _("Search Wikipedia…"),
        description = _("Type a topic, or open today's featured article."),
        buttons = {
            {
                {
                    text = _("Today's Featured Article"),
                    callback = function()
                        UIManager:close(dialog)
                        self:openFeaturedArticle()
                    end,
                },
            },
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

-- Look up today's featured article title, then hand off to openArticle().
function WikiReader:openFeaturedArticle()
    NetworkMgr:runWhenOnline(function()
        local info = InfoMessage:new{ text = _("Fetching today's featured article…") }
        UIManager:show(info)

        UIManager:scheduleIn(0, function()
            local today = os.date("%Y/%m/%d")
            -- Same host pattern ("<lang>.wikipedia.org") KOReader's built-in
            -- Wikipedia lookup already talks to -- no separate API key needed.
            local url = string.format(
                "https://%s.wikipedia.org/api/rest_v1/feed/featured/%s",
                self.lang, today
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
                UIManager:show(InfoMessage:new{ text = _("Couldn't read today's featured article.") })
                return
            end

            local tfa = data.tfa
            -- Field names have shifted a little across API versions; try
            -- the likely candidates in order.
            local title = (tfa.titles and tfa.titles.normalized)
                or tfa.normalizedtitle
                or tfa.title
            if not title then
                UIManager:show(InfoMessage:new{ text = _("Couldn't identify today's featured article.") })
                return
            end

            self:openArticle(title)
        end)
    end)
end

-- Fetches and converts an article, with images permanently disabled.
-- We call createEpub() directly rather than the createEpubWithUI()
-- wrapper (which always passes with_images=true and would prompt about
-- them) -- Trapper:wrap() here is the same progress-UI plumbing that
-- wrapper uses internally, just with `false` hardcoded for with_images.
function WikiReader:buildEpub(epub_path, title, lang, callback)
    local Wikipedia = require("ui/wikipedia")
    local Trapper = require("ui/trapper")
    Trapper:wrap(function()
        local ok, success = pcall(Wikipedia.createEpub, Wikipedia, epub_path, title, lang, false)
        if ok and success then
            callback(true)
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
        self:buildEpub(epub_path, title, lang, function(success)
            if not success then
                UIManager:show(InfoMessage:new{
                    text = _("Couldn't download that article. Check the title and your connection."),
                })
                return
            end
            pruneCache()
            open_fn(epub_path)
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