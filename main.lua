--[[--
WikiReader plugin for KOReader.

Adds a "WikiReader" entry to the main menu. From it you can search
Wikipedia, open a featured article (today's, a date you pick, or a random
one), set the Wikipedia language edition, and step back through articles
you've read. Whatever you pick is fetched, converted to an EPUB (reusing
the same conversion code KOReader's built-in Wikipedia lookup already
uses), and opened straight into the reader -- headings and a table of
contents all render normally, because it *is* a normal EPUB.

Images are never downloaded -- an article can contain dozens of them,
each several hundred KB, so fetching them all before reading would be
slow. Instead, each image inside an image box is replaced by a small QR
code pointing at the image's File: description page (generated on the fly
and embedded in the EPUB): the box and its caption stay in the document,
and scanning the QR code with a phone opens that page -- where the real
image, its description and its attribution live. This can be turned off in
the menu (Image boxes are then removed entirely, the old behaviour).

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
tables, sidebar boxes, side-boxes (this covers the
{{listen}} audio-sample box among other supplementary side content --
pointless in an epub regardless, since crengine has no audio playback
capability at all), the shortdescription hidden metadata div, and the
category list at the bottom of the page are stripped from the HTML
before conversion -- they tend to make a mess of a single-column
reflowable layout. Image boxes are kept but their images are replaced by
QR codes of the image URLs (see above). The shortdescription is
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

-- WikiReader modules
local cache = require("wikireader-cache")
local categories = require("categories")
local epub = require("epub")
local wutil = require("wikiutil")

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
    -- Self-heal the cache directory on every plugin load
    cache.pruneCache()

    -- Hook the reader's "what do you want to do with this link" dialog so
    -- tapping a Wikipedia link inside an article reads the linked article
    -- the same way, instead of KOReader's small built-in lookup popup.
    if self.ui and self.ui.link then
        -- Replace the stock "Read online" button (the clunky popup)
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
        -- setting is enabled, Wikipedia links open directly without showing
        -- the external-link dialog.
        local wiki_reader_self = self
        local original_onGoToExternalLink = self.ui.link.onGoToExternalLink
        self.ui.link.onGoToExternalLink = function(link_self, link_url)
            -- Check for category navigation links first
            local cat_section_index = wutil.parseCategoryLink(link_url)
            if cat_section_index then
                local cat_title = categories.category_section_titles[cat_section_index]
                if cat_title then
                    wiki_reader_self:fetchFeaturedCategoryArticles(cat_section_index, cat_title)
                end
                return true
            end

            -- Then check for regular Wikipedia article links
            local lang, escaped_title = wutil.parseWikiLink(link_url)
            if lang and escaped_title and G_reader_settings:nilOrTrue("wikireader_skip_link_dialog") then
                local title = socket_url.unescape(escaped_title)
                wiki_reader_self:openArticleInPlace(title, lang)
                return true
            end
            return original_onGoToExternalLink(link_self, link_url)
        end
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
                    {
                        text = _("Browse by category"),
                        callback = function()
                            self:showFeaturedCategories()
                        end,
                    },
                },
            },
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
                help_text = _("When enabled, tapping a Wikipedia link inside an article opens the linked article directly without showing the external-link dialog box first."),
            },
            {
                text = _("Show media as QR codes"),
                keep_menu_open = true,
                checked_func = function()
                    return G_reader_settings:nilOrTrue("wikireader_qr_images")
                end,
                callback = function()
                    G_reader_settings:flipNilOrTrue("wikireader_qr_images")
                end,
                help_text = _("When enabled, each article image (and video/audio figure) is replaced by a small QR code pointing at the media's File: description page -- the box and its caption stay, and scanning the code with a phone opens that page (showing the image, or the transcoded player for video/audio, instead of the full-size original download; nothing is fetched by the reader). When disabled, image boxes are removed completely as before. "),
            },
            {
                text = _("Clear cache"),
                keep_menu_open = true,
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = _("Delete all cached WikiReader articles?"),
                        ok_text = _("Delete"),
                        ok_callback = function()
                            self:clearCache()
                        end,
                    })
                end,
                help_text = _("Remove all cached Wikipedia EPUB files and their reading progress."),
            },
            {
                text = _("Save current article"),
                keep_menu_open = true,
                enabled_func = function()
                    return nav_current ~= nil and nav_current.path ~= nil
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
                    return nav_current ~= nil and nav_current.title ~= nil
                end,
                callback = function()
                    self:shareCurrentArticleLink()
                end,
                help_text = _("Copy the current article's Wikipedia link to the clipboard and show a QR code of it that you can scan from another device."),
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

-- Search box (landing page).
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

-- Date picker for a specific day's featured article.
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

-- Random featured article.
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

-- Language code dialog.
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

-- Open featured article for a given date (defaults to today).
function WikiReader:openFeaturedArticle(date)
    NetworkMgr:runWhenOnline(function()
        local info = InfoMessage:new{ text = _("Fetching featured article…") }
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

-- Shared plumbing: serve `title` from the cache if we have a fresh-enough
-- copy; otherwise fetch it, cache it, and hand the resulting path to
-- `open_fn`. `open_fn` is called with (path, resolved_title) where
-- resolved_title is the actual article title from the API response
-- (preserving correct casing), or nil if the title couldn't be resolved.
function WikiReader:fetchAndOpen(title, lang, open_fn)
    lang = lang or self.lang

    local cached_path = cache.getFreshCachePath(title, lang)
    if cached_path then
        -- Cache hit: the cached file was already renamed to the resolved
        -- title (by buildEpub on first fetch), so `title` already has the
        -- correct casing, otherwise the cache would have been missed.
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

-- Open an article as a brand new reader session (from the main menu).
function WikiReader:openArticle(title, lang)
    self:fetchAndOpen(title, lang, function(epub_path, resolved_title)
        nav_history = {}
        nav_current = { title = resolved_title or title, lang = lang or self.lang, path = epub_path }
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

            -- No exact match: search Wikipedia for matching pages
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

-- Open an article in place of the one currently being read (a tapped link).
function WikiReader:openArticleInPlace(title, lang)
    local from_article = nav_current
    self:fetchAndOpen(title, lang, function(epub_path, resolved_title)
        if from_article then
            table.insert(nav_history, from_article)
        end
        nav_current = { title = resolved_title or title, lang = lang or self.lang, path = epub_path }
        self.ui:switchDocument(epub_path)
    end)
end

-- Step back to the previous article in the back-history.
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

-- Save the currently reading article to the built-in Wikipedia save folder.
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

-- Actually performs the file copy and sidecar relocation.
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

-- Share the currently open article: copy its Wikipedia URL to the clipboard
-- and display a QR code of that URL for scanning from another device.
function WikiReader:shareCurrentArticleLink()
    if not nav_current or not nav_current.title then
        UIManager:show(InfoMessage:new{
            text = _("No article is currently open."),
        })
        return
    end

    local lang = nav_current.lang or self.lang or "en"
    -- Build the canonical Wikipedia URL for this article: spaces become
    -- underscores, other special characters are percent-encoded (Wikipedia
    -- accepts %-encoding in the path).
    local article = socket_url.escape(nav_current.title):gsub("%%20", "_")
    local url = string.format("https://%s.wikipedia.org/wiki/%s", lang, article)

    if Device and Device.input then
        Device.input.setClipboardText(url)
    end

    self:showShareQR(url)
end

-- Show a dismissable fullscreen QR code for `url`, with a caption noting the
-- link was copied to the clipboard. Dismisses on tap or any key press.
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

-- Delete every cached article from the cache directory.
-- Walks the entire cache dir and removes everything: epub files, leftover
-- sidecar (.sdr) directories, and any orphaned files.
function WikiReader:clearCache()
    local dir = cache.getCacheDir()
    local count = 0

    -- First pass: remove all files (use removeCachedFile for epubs so
    -- DocSettings.updateLocation can clean up the associated .sdr dir).
    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." then
            local path = dir .. "/" .. name
            local attr = lfs.attributes(path)
            if attr and attr.mode == "file" then
                if name:match("%.epub$") then
                    cache.removeCachedFile(path)
                else
                    os.remove(path)
                end
                count = count + 1
            end
        end
    end

    -- Second pass: remove any remaining directories (e.g., .sdr sidecars
    -- that weren't cleaned up by the first pass, or orphaned dirs).
    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." then
            local path = dir .. "/" .. name
            local attr = lfs.attributes(path)
            if attr and attr.mode == "directory" then
                -- Recursively delete everything inside the directory.
                for f in lfs.dir(path) do
                    if f ~= "." and f ~= ".." then
                        local fpath = path .. "/" .. f
                        local fattr = lfs.attributes(fpath)
                        if fattr and fattr.mode == "file" then
                            os.remove(fpath)
                            count = count + 1
                        end
                    end
                end
                lfs.rmdir(path)
            end
        end
    end

    UIManager:show(InfoMessage:new{
        text = T(_("Cache cleared (%1 file(s) deleted)."), count),
    })
end

-- Show the top-level featured-article categories.
function WikiReader:showFeaturedCategories()
    NetworkMgr:runWhenOnline(function()
        local info = InfoMessage:new{ text = _("Loading categories…") }
        UIManager:show(info)

        UIManager:scheduleIn(0, function()
            local sections_url = string.format(
                "https://%s.wikipedia.org/w/api.php?action=parse&page=Wikipedia:Featured_articles&prop=sections&format=json",
                self.lang
            )
            local ok, code, sink = wutil.httpGetJSON(sections_url)
            UIManager:close(info)

            if not ok or code ~= 200 then
                UIManager:show(InfoMessage:new{
                    text = _("Couldn't load featured article categories."),
                })
                return
            end

            local JSON = require("json")
            local body = table.concat(sink)
            local parse_ok, data = pcall(JSON.decode, body)
            if not parse_ok or not data or not data.parse or not data.parse.sections then
                UIManager:show(InfoMessage:new{
                    text = _("Couldn't parse featured article categories."),
                })
                return
            end

            local tree = categories.buildCategoryTree(data.parse.sections)
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

-- Fetch articles from a specific featured-article category section.
function WikiReader:fetchFeaturedCategoryArticles(section_index, section_title)
    local node = categories.findNode(categories.category_tree, section_index)

    NetworkMgr:runWhenOnline(function()
        local info = InfoMessage:new{ text = T(_("Loading %1…"), section_title) }
        UIManager:show(info)
        UIManager:forceRePaint()

        UIManager:scheduleIn(0, function()
            -- Fetch links for a section, from cache if already fetched this session
            local function getCachedLinks(sindex)
                if categories.section_links_cache[sindex] then
                    return categories.section_links_cache[sindex].titles
                end
                local url = string.format(
                    "https://%s.wikipedia.org/w/api.php?action=parse&page=Wikipedia:Featured_articles&section=%s&prop=links&format=json",
                    self.lang, sindex
                )
                local ok, code, sink = wutil.httpGetJSON(url)
                if not ok or code ~= 200 then return nil end
                local JSON = require("json")
                local body = table.concat(sink)
                local parse_ok, data = pcall(JSON.decode, body)
                if not parse_ok or not data or not data.parse or not data.parse.links then return nil end
                local titles = {}
                for _, link in ipairs(data.parse.links) do
                    if link.ns == 0 then
                        table.insert(titles, link["*"])
                    end
                end
                categories.section_links_cache[sindex] = { titles = titles }
                return titles
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
