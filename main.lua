--[[--
WikiReader: read Wikipedia articles as formatted EPUBs inside KOReader.

Adds a "WikiReader" entry to the main menu and to the Search menu (right
after the built-in Wikipedia history). From it you can search Wikipedia,
open a featured article (today's, a picked date, or a random one), browse
featured articles by category, read today's English Wikipedia main page
("In the news", "Did you know", "On this day"), view history, set the
Wikipedia language, and step back through articles you've read.

Articles are fetched and converted to EPUBs with KOReader's own built-in
Wikipedia conversion (ui/wikipedia.lua), so headings and the table of
contents render normally. The last 10 distinct articles are cached on disk
(for up to a day) as real EPUB files, which also backs the back-history.

Media (images, audio/video) is never downloaded. Instead each media box is
replaced by a small QR code pointing at its File: description page, which
you can scan with a phone (toggleable; off removes the boxes entirely).

Infoboxes, navboxes, sidebars, route-map tables, the short-description
metadata, the category list, hatnotes/maintenance banners, and quote
attribution are cleaned from the HTML before conversion. Cladograms and
math formulas are rendered as text, since crengine can't draw their CSS/JS.

Tapping a Wikipedia link inside an open article is hooked to "Read as book"
(the plugin's link handler), and keeps a back-history.

Install: copy this wikireader.koplugin folder into koreader/plugins/ and
restart KOReader.
--]]--

local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
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
local BD = require("ui/bidi")
local _ = require("gettext")

local cache = require("wikireader-cache")
local categories = require("categories")
local epub = require("epub")
local history = require("wikireader-history")
local mainpage = require("mainpage")
local wutil = require("wikiutil")

local WikiReader = WidgetContainer:extend{
    name = "wikireader",
    lang = "en",
}

-- Back-navigation history, kept at module level rather than as a
-- `self.` field: KOReader builds a fresh WidgetContainer instance per UI
-- (FileManager, Reader), so instance fields reset right when it matters --
-- going from "opened from the menu" to "tapped a link inside the article".
-- Module-level locals survive that jump.
local nav_history = {}  -- stack of {title=.., lang=..}, oldest first
local nav_current = nil -- {title=.., lang=..} of the article now open

local lfs = require("libs/libkoreader-lfs")

function WikiReader:onDispatcherRegisterActions()
    Dispatcher:registerAction("wikireader_go_back", {
        category = "none",
        event = "WikiReaderGoBack",
        title = _("WikiReader: back to previous article"),
        general = true,
    })
    Dispatcher:registerAction("wikireader_open_menu", {
        category = "none",
        event = "ShowWikiReaderMenu",
        title = _("WikiReader: open WikiReader menu"),
        general = true,
    })
end

function WikiReader:init()
    self.lang = G_reader_settings:readSetting("wikireader_lang") or "en"
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    cache.pruneCache()

    -- Hook the reader's "what do you want to do with this link" dialog so
    -- tapping a Wikipedia link inside an article reads the linked article
    -- the same way, instead of KOReader's small built-in lookup popup.
    if self.ui and self.ui.link then
        -- Replace the stock "Read online" button
        self.ui.link:removeFromExternalLinkDialog("40_wiki_lookup")

        self.ui.link:addToExternalLinkDialog("40_wikireader", function(this, link_url)
            local lang, escaped_title = wutil.parseWikiLink(link_url)
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

        -- Also patch onGoToExternalLink so that, when the "skip link dialog"
        -- setting is enabled, Wikipedia links show a short preview popup
        -- (instead of the external-link dialog or a full download right away).
        local wiki_reader_self = self
        local original_onGoToExternalLink = self.ui.link.onGoToExternalLink
        self.ui.link.onGoToExternalLink = function(link_self, link_url)
            local cat_section_index = wutil.parseCategoryLink(link_url)
            if cat_section_index then
                local cat_title = categories.category_section_titles[cat_section_index]
                if cat_title then
                    wiki_reader_self:fetchFeaturedCategoryArticles(cat_section_index, cat_title)
                end
                return true
            end

            local lang, escaped_title = wutil.parseWikiLink(link_url)
            if lang and escaped_title and G_reader_settings:nilOrTrue("wikireader_skip_link_dialog") then
                local title = socket_url.unescape(escaped_title)
                wiki_reader_self:showLinkPreview(title, lang)
                return true
            end
            return original_onGoToExternalLink(link_self, link_url)
        end
    end
end

-- KOReader can open a cached article EPUB directly (last-document restore,
-- file manager, history) without any WikiReader code path running, leaving
-- nav_current nil and menu actions like "Refetch current article" greyed
-- out. Our EPUBs are self-describing (dc:title/dc:language written by
-- createEpub()), so recognise them here and rebuild nav_current. Reading
-- position is untouched: KOReader restores it from the .sdr sidecar.
function WikiReader:onReaderReady()
    local file = self.ui.document and self.ui.document.file
    if not file then return end

    -- Ignore documents outside our cache dir; also drop the stale
    -- reference when a regular book is opened afterwards.
    local cache_dir = cache.getCacheDir()
    if file:sub(1, #cache_dir + 1) ~= cache_dir .. "/" then
        nav_current = nil
        return
    end

    local filename = file:match("([^/]+)$")
    -- The main page has no single article behind it to refetch. Its
    -- "__mainpage__" sentinel survives verbatim into the filename
    -- (see cache.getHelperCachePath), unlike the getCachePath() keys.
    if filename:find("__mainpage__", 1, true) then
        return
    end

    -- Filename fallback ("<lang> - <title>.epub") for missing metadata.
    local fn_lang, fn_title = filename:match("^(.-) %- (.+)%.epub$")
    local props = self.ui.document:getProps() or {}
    local title = props.title
    if not title or title == "" then
        title = fn_title
    end
    local lang = props.language
    if not lang or lang == "" then
        lang = fn_lang
    end

    if title and title ~= "" then
        nav_current = { title = title, lang = lang or self.lang, path = file }
    end
end

function WikiReader:addToMainMenu(menu_items)
    menu_items.wikireader = {
        text = _("WikiReader"),
        sub_item_table = {
            {
                text = _("Search Wikipedia"),
                keep_menu_open = true,
                callback = function()
                    self:showLanding()
                end,
            },
            {
                text = _("Wikipedia main page"),
                callback = function()
                    self:openMainPage()
                end,
                help_text = _("Today's English Wikipedia main page with its \"In the news\", \"Did you know\" and \"On this day\" sections, as a readable book. Tapping an article opens it like any other WikiReader article."),
            },
            {
                text = _("Featured Articles"),
                keep_menu_open = true,
                separator = true,
                help_text = _("Read Wikipedia's featured article for today or a past date, or browse featured articles by category. This relies on the \"featured article of the day\" feed, which may be missing or unreliable for languages other than English."),
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
                    {
                        text = _("Browse by category"),
                        callback = function()
                            self:showFeaturedCategories()
                        end,
                    },
                },
            },
            {
                text = _("Settings"),
                sub_item_table = {
                    {
                        text_func = function()
                            return T(_("Wikipedia language: %1"), self.lang:upper())
                        end,
                        callback = function()
                            self:showLanguageDialog()
                        end,
                    },
                    {
                        text = _("Skip Wikipedia links dialog box"),
                        keep_menu_open = true,
                        checked_func = function()
                            return G_reader_settings:nilOrTrue("wikireader_skip_link_dialog")
                        end,
                        callback = function()
                            G_reader_settings:flipNilOrTrue("wikireader_skip_link_dialog")
                        end,
                        help_text = _("Whenever you tap a Wikipedia link inside an article, show a short preview of that article instead of the intermediate dialog box, with a button to open it fully."),
                    },
                    {
                        text = _("Show media as QR codes"),
                        keep_menu_open = true,
                        checked_func = function()
                            return G_reader_settings:isTrue("wikireader_qr_media")
                        end,
                        callback = function()
                            G_reader_settings:flipNilOrFalse("wikireader_qr_media")
                        end,
                        help_text = _("Replace images and other media in an article with small QR codes you can scan with your phone. Turn this off to remove the media boxes entirely."),
                    },
                    {
                        text = _("Show infoboxes"),
                        keep_menu_open = true,
                        checked_func = function()
                            return G_reader_settings:isTrue("wikireader_show_infoboxes")
                        end,
                        callback = function()
                            G_reader_settings:flipNilOrFalse("wikireader_show_infoboxes")
                        end,
                        help_text = _("Keep the summary tables (infoboxes) that appear at the top of many articles. Their images are still removed for a cleaner reading view."),
                    },
                    {
                        text = _("Disable hyperlinks"),
                        keep_menu_open = true,
                        separator = true,
                        checked_func = function()
                            return G_reader_settings:isTrue("wikireader_disable_hyperlinks")
                        end,
                        callback = function()
                            G_reader_settings:flipNilOrFalse("wikireader_disable_hyperlinks")
                        end,
                        help_text = _("Remove links to other Wikipedia articles from downloaded EPUBs, keeping their text. Links to references, footnotes and external sites are kept."),
                    },
                    {
                        text = _("Clear history"),
                        enabled_func = function()
                            return #history.getList() > 0
                        end,
                        callback = function()
                            UIManager:show(ConfirmBox:new{
                                text = _("Forget all articles in the WikiReader history?"),
                                ok_text = _("Clear"),
                                ok_callback = function()
                                    history.clear()
                                    UIManager:show(InfoMessage:new{
                                        text = T("History cleared."),
                                    })
                                end,
                            })
                        end,
                        help_text = _("Forget the list of the last 10 articles shown in the History menu. Cached EPUB files are not deleted."),
                    },
                    {
                        text = _("Clear cache"),
                        separator = true,
                        enabled_func = function()
                            return not cache.isEmpty()
                        end,
                        callback = function()
                            UIManager:show(ConfirmBox:new{
                                text = _("Delete all cached WikiReader articles?\nIf an article is currently open, it will be closed."),
                                ok_text = _("Delete"),
                                ok_callback = function()
                                    self:clearCache()
                                end,
                            })
                        end,
                        help_text = _("Remove all cached WikiReader EPUB files and their reading progress. Closes the current article if one is open, so no leftover files remain."),
                    },
                    {
                        text = _("Gestures"),
                        keep_menu_open = true,
                        callback = function()
                            UIManager:show(InfoMessage:new{
                                text = _("You can bind gestures to WikiReader actions through the Gesture manager:\n\n• Back to previous article\n  \"General > WikiReader: back to previous article\"\n\n• Open WikiReader menu\n  \"General > WikiReader: open WikiReader menu\""),
                            })
                        end,
                    },
                    {
                        text = _("About"),
                        keep_menu_open = true,
                        callback = function()
                            self:showAbout()
                        end,
                        help_text = _("Show plugin name, description and version."),
                    },
                },
                separator = true,
            },
            {
                text = _("History"),
                enabled_func = function()
                    return #history.getList() > 0
                end,
                sub_item_table_func = function()
                    -- Built when the menu is opened, so it reflects opens
                    -- that happened after the main menu was registered.
                    return self:buildHistoryMenu()
                end,
            },
            {
                text = _("Save current article"),
                keep_menu_open = true,
                enabled_func = function()
                    return nav_current ~= nil and nav_current.path ~= nil and not nav_current.helper
                end,
                callback = function()
                    self:saveCurrentArticle()
                end,
                help_text = _("Save the currently reading article to the built-in Wikipedia save folder."),
            },
            {
                text = _("Share current article link"),
                keep_menu_open = true,
                enabled_func = function()
                    return nav_current ~= nil and nav_current.title ~= nil and not nav_current.helper
                end,
                callback = function()
                    self:shareCurrentArticleLink()
                end,
                help_text = _("Copies the current article's Wikipedia link to the clipboard and shows a QR code of it that you can scan from another device."),
            },
            {
                text = _("Refetch current article"),
                keep_menu_open = true,
                enabled_func = function()
                    return nav_current ~= nil and nav_current.title ~= nil and not nav_current.helper
                end,
                callback = function()
                    self:refetchCurrentArticle()
                end,
                help_text = _("Delete the cached copy of the article you are reading and download it again, so the media, infobox and hyperlink settings in \"Settings\" also apply to it. Your reading position is kept."),
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
    -- Wikipedia history entry.
    local function insertAfterWikipHistory(order_tbl)
        local search_menu = order_tbl.search
        if not search_menu then return end
        for i, entry in ipairs(search_menu) do
            if entry == "wikipedia_history" then
                table.insert(search_menu, i + 1, "wikireader")
                return
            end
        end
        table.insert(search_menu, "wikireader")
    end
    insertAfterWikipHistory(require("ui/elements/filemanager_menu_order"))
    insertAfterWikipHistory(require("ui/elements/reader_menu_order"))
end

-- Opens a history entry in the current reader (switching, and keeping
-- back-history continuity) when one is open, otherwise starts a fresh
-- article nav, which also works from the FileManager.
function WikiReader:openHistoryEntry(entry)
    if self.ui and self.ui.switchDocument then
        self:openArticleInPlace(entry.title, entry.lang)
    else
        self:openArticle(entry.title, entry.lang)
    end
end

-- The last 10 opened articles, newest first. Titles are shown with the
-- language edition only when it differs from the current default, to keep
-- the common (default-lang) entries readable.
function WikiReader:buildHistoryMenu()
    local list = history.getList()
    local items = {}
    for _, entry in ipairs(list) do
        local text = entry.title
        if entry.lang and entry.lang ~= self.lang then
            text = T("%1 (%2)", text, entry.lang:upper())
        end
        table.insert(items, {
            text = text,
            callback = function()
                self:openHistoryEntry(entry)
            end,
        })
    end

    return items
end

-- Resolve the path ("tab.item") of our top-level menu entry. Done by hand
-- rather than TouchMenu:search because "WikiReader" is not a unique title (the
-- same one exists under Plugin management > User plugins, and walking to that
-- leaf would disable the plugin): match by menu id, or by title substring
-- (orphaned plugins get a "NEW: " prefix) plus a "Search Wikipedia" child as
-- signature. Tab items live in the tab table's array part, the only level
-- scanned.
local function findWikiReaderMenuPath(tab_item_table)
    local title = _("WikiReader")
    local signature = _("Search Wikipedia")

    local function matchEntry(v, entry_path)
        if type(v) ~= "table" or v.ignored_by_menu_search then
            return nil
        end
        local sub = v.sub_item_table_func and v.sub_item_table_func() or v.sub_item_table
        if type(sub) ~= "table" then
            return nil
        end
        if v.id == "wikireader" then
            return entry_path
        end
        local text = v.text_func and v.text_func() or v.text
        if type(text) == "string" and text:find(title, 1, true) then
            for _, child in ipairs(sub) do
                local child_text = child.text_func and child.text_func() or child.text
                if type(child_text) == "string" and child_text:find(signature, 1, true) then
                    return entry_path
                end
            end
        end
        return nil
    end

    for tab_num, tab in ipairs(tab_item_table) do
        if type(tab) == "table" then
            for i, v in ipairs(tab) do
                local found = matchEntry(v, tab_num .. "." .. i)
                if found then
                    return found
                end
            end
        end
    end
end

function WikiReader:onShowWikiReaderMenu()
    local menu = self.ui.menu
    if not menu or not menu.onShowMenu then
        return false
    end
    menu:onShowMenu(nil, true)
    local touch_menu = menu.menu_container and menu.menu_container[1]
    if not touch_menu then
        return false
    end
    local path = findWikiReaderMenuPath(touch_menu.tab_item_table)
    if not path then
        logger.warn("wikireader: menu entry not found")
        return false
    end
    -- Walk to the entry by hand instead of TouchMenu:openMenu(): openMenu()
    -- never un-highlights its final path element, and since the path has to
    -- be extended one level (".1") to actually enter the submenu, that
    -- stuck highlight would land on the first item ("Search Wikipedia")
    -- when the menu is opened via a gesture. Switching tab and selecting
    -- the entry directly is what openMenu()'s walk ends up doing anyway,
    -- minus the highlight.
    local tab, entry = path:match("^(%d+)%.(%d+)$")
    if not tab then
        touch_menu:openMenu(path .. ".1")
        return true
    end
    tab, entry = tonumber(tab), tonumber(entry)
    if touch_menu.not_shown then
        UIManager:show(touch_menu.show_parent)
    end
    touch_menu:switchMenuTab(tab)
    touch_menu.bar:switchToTab(tab)
    touch_menu:onMenuSelect(touch_menu.item_table[entry])
    return true
end

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
                            self:searchArticle(title)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function WikiReader:showDatePicker()
    local DateTimeWidget = require("ui/widget/datetimewidget")
    local today = os.date("*t")
    local date_widget = DateTimeWidget:new{
        title_text = _("Pick a date"),
        info_text = _("Fetch the featured article for a specific date."),
        year = today.year,
        month = today.month,
        day = today.day,
        year_min = 2016,
        year_max = today.year,
        ok_text = _("Fetch"),
        callback = function(widget)
            self:openFeaturedArticle(wutil.formatApiDate(widget.year, widget.month, widget.day))
        end,
    }
    UIManager:show(date_widget)
end

function WikiReader:openRandomFeaturedArticle()
    local time = require("ffi/util").gettime
    math.randomseed(math.floor(time() * 1000) % 2147483647)

    local start_t = os.time{ year = 2016, month = 1, day = 1 }
    local today = os.date("*t")
    local end_t = os.time{ year = today.year, month = today.month, day = today.day }
    if end_t <= start_t then end_t = os.time() end
    local random_t = start_t + math.random(0, end_t - start_t)
    local t = os.date("*t", random_t)
    self:openFeaturedArticle(wutil.formatApiDate(t.year, t.month, t.day))
end

function WikiReader:showAbout()
    local version = self.version and (" v" .. self.version) or ""
    UIManager:show(InfoMessage:new{
        text = (self.fullname or _("WikiReader")) .. version .. "\n\n" .. (self.description or ""),
    })
end

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

function WikiReader:openFeaturedArticle(date)
    NetworkMgr:runWhenOnline(function()
        -- The explicit date comes from the date picker or the random pick,
        -- so showing it confirms what was actually chosen.
        local info = InfoMessage:new{
            text = date
                and T(_("Fetching featured article for %1…"), date)
                or _("Fetching featured article…"),
        }
        UIManager:show(info)

        UIManager:scheduleIn(0, function()
            local date_str = date or os.date("%Y/%m/%d")
            local url = string.format(
                "https://%s.wikipedia.org/api/rest_v1/feed/featured/%s",
                self.lang, date_str
            )
            local ok, code, sink = wutil.httpGetJSON(url)
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

function WikiReader:openMainPage()
    NetworkMgr:runWhenOnline(function()
        local info = InfoMessage:new{ text = _("Fetching Wikipedia main page…") }
        UIManager:show(info)

        UIManager:scheduleIn(0, function()
            local sections, err = mainpage.fetchSections()
            UIManager:close(info)

            if not sections then
                UIManager:show(InfoMessage:new{
                    text = err == "layout"
                        and _("Couldn't find the news sections on the Wikipedia main page (its layout may have changed).")
                        or _("Couldn't fetch the Wikipedia main page. Check your connection and try again."),
                })
                return
            end

            local ok_build, epub_path = epub.buildMainPageEpub(os.date("%Y-%m-%d"), "en", sections)
            if not ok_build then
                UIManager:show(InfoMessage:new{
                    text = _("Couldn't build the main page."),
                })
                return
            end
            cache.pruneCache()
            nav_history = {}
            nav_current = { title = _("Wikipedia main page"), lang = "en", path = epub_path, helper = true }
            local ReaderUI = require("apps/reader/readerui")
            ReaderUI:showReader(epub_path)
        end)
    end)
end

-- Serve `title` from cache if fresh; otherwise fetch and cache it, then
-- call open_fn(path, resolved_title) with the casing-correct title from
-- the API response (or nil if it couldn't be resolved).
function WikiReader:fetchAndOpen(title, lang, open_fn)
    lang = lang or self.lang

    local cached_path = cache.getFreshCachePath(title, lang)
    if cached_path then
        -- Cache hit: buildEpub() renamed the file to the resolved title on
        -- first fetch, so `title` is already casing-correct.
        open_fn(cached_path, title)
        return
    end

    NetworkMgr:runWhenOnline(function()
        local epub_path = cache.getCachePath(title, lang)
        epub.buildEpub(epub_path, title, lang, function(success, used_path, resolved_title)
            if not success then
                UIManager:show(InfoMessage:new{
                    text = _("Couldn't download that article. Check the title and your connection."),
                })
                return
            end
            cache.pruneCache()
            open_fn(used_path or epub_path, resolved_title)
        end)
    end)
end

function WikiReader:openArticle(title, lang)
    self:fetchAndOpen(title, lang, function(epub_path, resolved_title)
        nav_history = {}
        nav_current = { title = resolved_title or title, lang = lang or self.lang, path = epub_path }
        -- Record with the resolved title: that's the one later fetches will
        -- find in the cache without a redirect round-trip.
        history.record(nav_current.title, nav_current.lang)
        local ReaderUI = require("apps/reader/readerui")
        ReaderUI:showReader(epub_path)
    end)
end

-- Search for an article by title, with fallback to a search results page.
function WikiReader:searchArticle(title, lang)
    lang = lang or self.lang

    NetworkMgr:runWhenOnline(function()
        local info = InfoMessage:new{ text = _("Searching Wikipedia…") }
        UIManager:show(info)

        UIManager:scheduleIn(0, function()
            local check_url = string.format(
                "https://%s.wikipedia.org/w/api.php?action=query&titles=%s&format=json&redirects=",
                lang, socket_url.escape(title)
            )
            local ok, code, sink = wutil.httpGetJSON(check_url)
            UIManager:close(info)

            if ok and code == 200 then
                local JSON = require("json")
                local body = table.concat(sink)
                local parse_ok, data = pcall(JSON.decode, body)
                if parse_ok and data and data.query and data.query.pages then
                    for _, page in pairs(data.query.pages) do
                        if not page.missing then
                            self:openArticle(title, lang)
                            return
                        end
                    end
                end
            else
                self:openArticle(title, lang)
                return
            end

            -- No exact match: fall back to a search results page
            local search_url = string.format(
                "https://%s.wikipedia.org/w/api.php?action=query&list=search&srsearch=%s&format=json&srlimit=20&srprop=snippet",
                lang, socket_url.escape(title)
            )
            local search_ok, search_code, search_sink = wutil.httpGetJSON(search_url)
            if not search_ok or search_code ~= 200 then
                UIManager:show(InfoMessage:new{
                    text = _("Couldn't search Wikipedia. Check your connection and try again."),
                })
                return
            end

            local JSON = require("json")
            local search_body = table.concat(search_sink)
            local search_parse_ok, search_data = pcall(JSON.decode, search_body)
            if not search_parse_ok or not search_data or not search_data.query or not search_data.query.search then
                UIManager:show(InfoMessage:new{
                    text = T(_("No results found for \"%1\"."), title),
                })
                return
            end

            local results = search_data.query.search
            if #results == 0 then
                UIManager:show(InfoMessage:new{
                    text = T(_("No results found for \"%1\"."), title),
                })
                return
            end

            local epub_path = cache.getCachePath("__search__" .. title, lang)
            epub.buildSearchEpub(epub_path, title, lang, results, function(success, used_path)
                if not success then
                    UIManager:show(InfoMessage:new{
                        text = _("Couldn't build search results page."),
                    })
                    return
                end
                cache.pruneCache()
                nav_history = {}
                nav_current = { title = title, lang = lang, path = used_path }
                local ReaderUI = require("apps/reader/readerui")
                ReaderUI:showReader(used_path)
            end)
        end)
    end)
end

function WikiReader:openArticleInPlace(title, lang)
    local from_article = nav_current
    self:fetchAndOpen(title, lang, function(epub_path, resolved_title)
        if from_article then
            table.insert(nav_history, from_article)
        end
        nav_current = { title = resolved_title or title, lang = lang or self.lang, path = epub_path }
        history.record(nav_current.title, nav_current.lang)
        self.ui:switchDocument(epub_path)
    end)
end

-- Lightweight alternative to opening the full article: fetch the linked
-- page's lead extract (TextExtracts API) and offer it in a scrollable
-- preview box, so a stray tap doesn't cost a full article download.
function WikiReader:showLinkPreview(title, lang)
    NetworkMgr:runWhenOnline(function()
        local info = InfoMessage:new{ text = _("Fetching preview…") }
        UIManager:show(info)
        UIManager:forceRePaint()
        UIManager:yieldToEPDC()

        local url = string.format(
            "https://%s.wikipedia.org/w/api.php?action=query&prop=extracts&exintro&explaintext&format=json&formatversion=2&redirects=1&titles=%s",
            lang, socket_url.escape(title)
        )
        local ok, code, sink = wutil.httpGetJSON(url)
        UIManager:close(info)

        -- TextExtracts can come back empty (e.g. pages whose lead is just
        -- an infobox), and the response carries the redirect-resolved title.
        local extract, resolved_title
        if ok and code == 200 then
            local JSON = require("json")
            local parse_ok, data = pcall(JSON.decode, table.concat(sink))
            if parse_ok and data and data.query and data.query.pages then
                local page = data.query.pages[1]
                if page and not page.missing then
                    extract = page.extract
                    resolved_title = page.title
                end
            end
        end
        if not extract or extract == "" then
            extract = _("No preview available for this article.")
        end

        local Screen = require("device").screen
        local TextViewer = require("ui/widget/textviewer")
        local preview
        preview = TextViewer:new{
            title = (resolved_title or title):gsub("_", " "),
            title_multilines = true,
            show_menu = false,
            width = math.floor(Screen:getWidth() * 0.8),
            height = math.floor(Screen:getHeight() * 0.6),
            text = extract,
            lang = lang,
            buttons_table = {
                {
                    {
                        text = _("Read more"),
                        callback = function()
                            preview:onClose()
                            self:openArticleInPlace(resolved_title or title, lang)
                        end,
                    },
                    {
                        text = _("Close"),
                        callback = function()
                            preview:onClose()
                        end,
                    },
                },
            },
        }
        UIManager:show(preview)
    end)
end

-- Rebuild the currently open article with the current settings: toggling
-- the media/infobox/hyperlink options only affects future fetches, so
-- this is how they get applied to an already-built EPUB.
function WikiReader:refetchCurrentArticle()
    if not nav_current or not nav_current.title then
        UIManager:show(InfoMessage:new{ text = _("No article is currently open.") })
        return
    end

    local title = nav_current.title
    local lang = nav_current.lang or self.lang

    -- Remove only the cached EPUB, keeping its .sdr sidecar so the
    -- reading position (and bookmarks) survive the rebuild. A plain
    -- os.remove() also stops the fetch below short-circuiting on a
    -- cache hit.
    local cached_path = cache.getCachePath(title, lang)
    os.remove(cached_path)
    -- The file on disk may be keyed by the resolved title (different
    -- casing) rather than the title we have here; remove that one too.
    if nav_current.path and nav_current.path ~= cached_path
        and lfs.attributes(nav_current.path) then
        os.remove(nav_current.path)
    end

    NetworkMgr:runWhenOnline(function()
        local info = InfoMessage:new{ text = _("Re-fetching current article…") }
        UIManager:show(info)

        local epub_path = cache.getCachePath(title, lang)
        epub.buildEpub(epub_path, title, lang, function(success, used_path, resolved_title)
            UIManager:close(info)
            if not success then
                UIManager:show(InfoMessage:new{
                    text = _("Couldn't re-download that article. Check your connection and try again."),
                })
                return
            end
            cache.pruneCache()

            used_path = used_path or epub_path
            nav_current = { title = resolved_title or title, lang = lang, path = used_path }
            if self.ui and self.ui.switchDocument then
                self.ui:switchDocument(used_path)
            else
                local ReaderUI = require("apps/reader/readerui")
                ReaderUI:showReader(used_path)
            end
        end)
    end)
end

function WikiReader:onWikiReaderGoBack()
    if #nav_history == 0 then
        UIManager:show(InfoMessage:new{ text = _("No previous Wikipedia article to go back to.") })
        return
    end
    local prev = nav_history[#nav_history]

    if prev.path and lfs.attributes(prev.path) then
        table.remove(nav_history)
        nav_current = prev
        if self.ui and self.ui.switchDocument then
            self.ui:switchDocument(prev.path)
        else
            local ReaderUI = require("apps/reader/readerui")
            ReaderUI:showReader(prev.path)
        end
        return
    end

    self:fetchAndOpen(prev.title, prev.lang, function(epub_path, resolved_title)
        table.remove(nav_history)
        nav_current = { title = resolved_title or prev.title, lang = prev.lang, path = epub_path }
        if self.ui and self.ui.switchDocument then
            self.ui:switchDocument(epub_path)
        else
            local ReaderUI = require("apps/reader/readerui")
            ReaderUI:showReader(epub_path)
        end
    end)
end

-- Returns the directory where the built-in Wikipedia feature saves its EPUBs.
function WikiReader:getWikipediaSaveDir()
    local filemanagerutil = require("apps/filemanager/filemanagerutil")
    local DictQuickLookup = require("ui/widget/dictquicklookup")
    local dir = G_reader_settings:readSetting("wikipedia_save_dir")
        or DictQuickLookup.getWikiSaveEpubDefaultDir()
    if not util.pathExists(dir) then
        util.makePath(dir)
    end
    return dir
end

function WikiReader:saveCurrentArticle()
    if not nav_current or not nav_current.path then
        UIManager:show(InfoMessage:new{
            text = _("No article is currently open."),
        })
        return
    end

    local src_path = nav_current.path
    if not lfs.attributes(src_path) then
        UIManager:show(InfoMessage:new{
            text = _("The article file no longer exists (may have been evicted from cache)."),
        })
        return
    end

    local wiki_dir = self:getWikipediaSaveDir()
    local save_dir = wiki_dir .. "/wikireader"
    if not util.pathExists(save_dir) then
        util.makePath(save_dir)
    end

    local lang = (nav_current.lang or self.lang or "en"):upper()
    local filename = nav_current.title .. "." .. lang .. ".epub"
    filename = util.getSafeFilename(filename, save_dir):gsub("_", " ")
    local dest_path = save_dir .. "/" .. filename

    if lfs.attributes(dest_path) then
        UIManager:show(ConfirmBox:new{
            text = T(_("%1 already exists. Overwrite?"), BD.filename(filename)),
            ok_text = _("Overwrite"),
            ok_callback = function()
                self:doSaveArticle(src_path, dest_path, filename)
            end,
        })
        return
    end

    self:doSaveArticle(src_path, dest_path, filename)
end

function WikiReader:doSaveArticle(src_path, dest_path, display_filename)
    local ffiutil = require("ffi/util")
    local err = ffiutil.copyFile(src_path, dest_path)
    if err then
        UIManager:show(InfoMessage:new{
            text = T(_("Failed to save article: %1"), err),
        })
        return
    end

    DocSettings.updateLocation(src_path, dest_path, true)

    UIManager:show(InfoMessage:new{
        text = T(_("Article saved as %1"), BD.filename(display_filename)),
    })
end

function WikiReader:shareCurrentArticleLink()
    if not nav_current or not nav_current.title then
        UIManager:show(InfoMessage:new{
            text = _("No article is currently open."),
        })
        return
    end

    local lang = nav_current.lang or self.lang or "en"
    -- Canonical URL: escaped title with spaces as underscores.
    local article = socket_url.escape(nav_current.title):gsub("%%20", "_")
    local url = string.format("https://%s.wikipedia.org/wiki/%s", lang, article)

    if Device and Device.input then
        Device.input.setClipboardText(url)
    end

    self:showShareQR(url)
end

function WikiReader:showShareQR(url)
    local Blitbuffer = require("ffi/blitbuffer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Font = require("ui/font")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local Geom = require("ui/geometry")
    local GestureRange = require("ui/gesturerange")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local QRWidget = require("ui/widget/qrwidget")
    local Size = require("ui/size")
    local TextWidget = require("ui/widget/textwidget")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local Screen = Device.screen
    local Input = Device.input

    local ShareBox = InputContainer:extend{
        modal = true,
    }

    function ShareBox:init()
        if Device:hasKeys() then
            self.key_events.AnyKeyPressed = { { Input.group.Any } }
        end
        if Device:isTouchDevice() then
            self.ges_events.TapClose = {
                GestureRange:new{
                    ges = "tap",
                    range = Geom:new{
                        x = 0, y = 0,
                        w = Screen:getWidth(),
                        h = Screen:getHeight(),
                    },
                },
            }
        end

        local padding = Size.padding.fullscreen
        local caption_face = Font:getFace("x_smallinfofont")
        local caption1 = TextWidget:new{
            text = _("Link copied to clipboard."),
            face = caption_face,
        }
        local caption2 = TextWidget:new{
            text = _("Scan the QR code to open it on another device."),
            face = caption_face,
        }
        local qr_size = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.75)
        local qr_image = QRWidget:new{
            text = url,
            width = qr_size,
            height = qr_size,
            alpha = true,
            scale_factor = 1,
        }
        local vgroup = VerticalGroup:new{
            align = "center",
            caption1,
            caption2,
            VerticalSpan:new{ width = Size.span.vertical_default },
            qr_image,
        }
        local frame = FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            padding = padding,
            vgroup,
        }

        self[1] = CenterContainer:new{
            dimen = Screen:getSize(),
            frame,
        }
    end

    function ShareBox:onShow()
        UIManager:setDirty(self, function() return "ui", self[1][1].dimen end)
        return true
    end

    function ShareBox:onCloseWidget()
        UIManager:setDirty(nil, function() return "ui", self[1][1].dimen end)
    end

    function ShareBox:onTapClose()
        UIManager:close(self)
        return true
    end

    ShareBox.onAnyKeyPressed = ShareBox.onTapClose

    UIManager:show(ShareBox:new{})
end

-- Delete every cached article; the file walking and history cleanup live
-- in cache.wipeAll(). What remains here is closing our own open article
-- first, so KOReader can't flush its .sdr sidecar back after deletion.
function WikiReader:clearCache()
    local dir = cache.getCacheDir()

    -- Close one of our own open articles first: KOReader flushes the .sdr
    -- sidecar when a book closes, so deleting while it is open would leave
    -- a freshly regenerated orphaned sidecar behind. Never close a regular
    -- book the user is reading.
    if self.ui and self.ui.document and self.ui.document.file then
        local file = self.ui.document.file
        if file == dir or file:sub(1, #dir + 1) == dir .. "/" then
            nav_history = {}
            nav_current = nil
            -- Close any open menu first: it lives on the UIManager window
            -- stack independently of the reader, and its callbacks would
            -- point at a torn-down ReaderUI (crashes on tap).
            if self.ui.menu and self.ui.menu.onCloseReaderMenu then
                self.ui.menu:onCloseReaderMenu()
            end
            self.ui:onClose()
            -- If KOReader started directly into the document, closing the
            -- reader would empty the window stack and exit KOReader; open
            -- the FileManager explicitly (on home, not the stale cache
            -- listing) to avoid that.
            local FileManager = require("apps/filemanager/filemanager")
            local home_dir = require("apps/filemanager/filemanagerutil").getHomeFolder()
            if not FileManager.instance then
                FileManager:showFiles(home_dir)
            else
                FileManager.instance.file_chooser:changeToPath(home_dir)
            end
        end
    end

    local count = cache.wipeAll()

    UIManager:show(InfoMessage:new{
        text = T(_("Cache cleared (%1 file(s) deleted)."), count),
    })
end

function WikiReader:showFeaturedCategories()
    NetworkMgr:runWhenOnline(function()
        local info = InfoMessage:new{ text = _("Loading categories…") }
        UIManager:show(info)

        UIManager:scheduleIn(0, function()
            local sections, err = categories.fetchSections(self.lang)
            UIManager:close(info)

            if not sections then
                UIManager:show(InfoMessage:new{
                    text = err == "parse"
                        and _("Couldn't parse featured article categories.")
                        or _("Couldn't load featured article categories."),
                })
                return
            end

            local tree = categories.buildCategoryTree(sections)
            if #tree == 0 then
                UIManager:show(InfoMessage:new{
                    text = _("No categories found."),
                })
                return
            end

            categories.fillLookup(tree)
            categories.category_tree = tree

            local ok_build, cat_epub_path = epub.buildCategoryEpub(tree, _("Featured article categories"), self.lang)
            if not ok_build then
                UIManager:show(InfoMessage:new{
                    text = _("Couldn't build category page."),
                })
                return
            end
            cache.pruneCache()
            nav_history = {}
            nav_current = { title = _("Featured article categories"), lang = self.lang, path = cat_epub_path }
            local ReaderUI = require("apps/reader/readerui")
            ReaderUI:showReader(cat_epub_path)
        end)
    end)
end

function WikiReader:fetchFeaturedCategoryArticles(section_index, section_title)
    local node = categories.findNode(categories.category_tree, section_index)

    NetworkMgr:runWhenOnline(function()
        local info = InfoMessage:new{ text = T(_("Loading %1…"), section_title) }
        UIManager:show(info)
        UIManager:forceRePaint()

        UIManager:scheduleIn(0, function()
            local function getCachedLinks(sindex)
                return categories.fetchSectionLinks(self.lang, sindex)
            end

            local all_links = getCachedLinks(section_index)
            if not all_links then
                UIManager:close(info)
                UIManager:show(InfoMessage:new{
                    text = _("Couldn't load articles for that category."),
                })
                return
            end

            if node and #node.children > 0 then
                -- Has subcategories: fetch each child's links and compute direct articles
                local child_links_set = {}
                for _, child in ipairs(node.children) do
                    local child_links = getCachedLinks(child.section_index)
                    if child_links then
                        for _, title in ipairs(child_links) do
                            child_links_set[title] = true
                        end
                    end
                end

                local direct_articles = {}
                for _, title in ipairs(all_links) do
                    if not child_links_set[title] then
                        table.insert(direct_articles, { title = title })
                    end
                end

                UIManager:close(info)

                local ok_build, cat_epub_path = epub.buildCategoryEpub(node.children, section_title, self.lang, direct_articles)
                if not ok_build then
                    UIManager:show(InfoMessage:new{
                        text = _("Couldn't build category page."),
                    })
                    return
                end
                cache.pruneCache()
                local from_article = nav_current
                if from_article then
                    table.insert(nav_history, from_article)
                end
                nav_current = { title = section_title, lang = self.lang, path = cat_epub_path }
                if self.ui and self.ui.switchDocument then
                    self.ui:switchDocument(cat_epub_path)
                else
                    local ReaderUI = require("apps/reader/readerui")
                    ReaderUI:showReader(cat_epub_path)
                end
            else
                -- Leaf node: all links are articles
                UIManager:close(info)

                local articles = {}
                for _, title in ipairs(all_links) do
                    table.insert(articles, { title = title })
                end

                if #articles == 0 then
                    UIManager:show(InfoMessage:new{
                        text = _("No articles found in that category."),
                    })
                    return
                end

                local epub_path = cache.getCachePath("__featured__" .. section_title, self.lang)
                epub.buildSearchEpub(epub_path, section_title, self.lang, articles, function(success, used_path)
                    if not success then
                        UIManager:show(InfoMessage:new{
                            text = _("Couldn't build category page."),
                        })
                        return
                    end
                    cache.pruneCache()
                    local from_article = nav_current
                    if from_article then
                        table.insert(nav_history, from_article)
                    end
                    nav_current = { title = section_title, lang = self.lang, path = used_path }
                    if self.ui and self.ui.switchDocument then
                        self.ui:switchDocument(used_path)
                    else
                        local ReaderUI = require("apps/reader/readerui")
                        ReaderUI:showReader(used_path)
                    end
                end, section_title)
            end
        end)
    end)
end

return WikiReader
