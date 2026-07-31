--[[--
Wikipedia Reader plugin for KOReader.

Adds a "Wikipedia" entry to the main menu. Tapping it shows a small
landing dialog with a search box and a "Today's Featured Article" button.
Whatever you pick is fetched, converted to an EPUB (reusing the same
conversion code KOReader's built-in Wikipedia lookup already uses), and
opened straight into the reader -- headings, images, and a table of
contents all render normally, because it *is* a normal EPUB.

The EPUB is written to a single reusable path under KOReader's data
directory and overwritten every time, so nothing accumulates in your
library.

Install: copy this whole wikireader.koplugin folder into your
koreader/plugins/ directory (on Kindle: .../koreader/plugins/), then
restart KOReader.
--]]--

local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")

local WikiReader = WidgetContainer:extend{
    name = "wikireader",
    -- Change this if you want a different edition of Wikipedia.
    lang = "en",
}

-- Single reusable scratch path -- overwritten on every read, so it never
-- grows into a permanent "library" of saved articles.
local function getScratchEpubPath()
    local dir = DataStorage:getFullDataDir() .. "/cache/wikireader"
    if not util.pathExists(dir) then
        util.makePath(dir)
    end
    return dir .. "/current.epub"
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

function WikiReader:init()
    self.ui.menu:registerToMainMenu(self)
end

function WikiReader:addToMainMenu(menu_items)
    menu_items.wikireader = {
        text = _("Wikipedia"),
        sorting_hint = "search",
        callback = function()
            self:showLanding()
        end,
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

-- Fetch an article by title, build it into the scratch EPUB, and open it
-- directly in the reader -- reusing KOReader's own Wikipedia-to-EPUB
-- conversion so headings, images, and TOC come out formatted normally.
function WikiReader:openArticle(title)
    NetworkMgr:runWhenOnline(function()
        local Wikipedia = require("ui/wikipedia")
        local epub_path = getScratchEpubPath()

        Wikipedia:createEpubWithUI(epub_path, title, self.lang, function(success)
            if not success then
                UIManager:show(InfoMessage:new{
                    text = _("Couldn't download that article. Check the title and your connection."),
                })
                return
            end

            local ReaderUI = require("apps/reader/readerui")
            ReaderUI:showReader(epub_path)
            -- The scratch file at epub_path is simply overwritten the next
            -- time you search or open the featured article, so nothing
            -- accumulates. If you'd rather it vanish the instant you close
            -- the article, os.remove(epub_path) can be called from an
            -- onCloseDocument handler -- worth wiring up once you've
            -- confirmed the basic flow works on your device.
        end)
    end)
end

return WikiReader
