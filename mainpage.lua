-- "Wikipedia main page" menu entry, from the Wikimedia featured-feed
-- API (the structured JSON behind the official mobile apps):
-- https://api.wikimedia.org/feed/v1/wikipedia/{lang}/featured/{Y}/{M}/{D}
-- Serves In the news, Most read, Did you know, On this day and Picture of
-- the day as data for any language whose wiki populates the feed; missing
-- sections are omitted (feed coverage varies per wiki).

local logger = require("logger")

local qrimage = require("qrimage")
local wutil = require("wikiutil")

local M = {}

local FEED_URL = "https://api.wikimedia.org/feed/v1/wikipedia/%s/featured/%s"

local function escapeHtml(s)
    if not s then return "" end
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

-- Feed HTML is Parsoid output: wiki links are relative ("./Title") and
-- media URLs are protocol-relative. Unwraps every anchor that doesn't
-- point at an article (external/interwiki/special — keep its label, the
-- target is noise), rewrites the rest to absolute wiki URLs the link
-- handler recognises, and normalizes <img> srcs for the lazy pipeline.
local function cleanFeedHtml(html, lang, image_transform)
    html = html:gsub("<style[^>]*>.-</style>", "")
    html = html:gsub("<link[^>]*>", "")
    html = html:gsub("<!%-%-.-%-%->", "")
    html = html:gsub('<a[^>]-href="([^"]*)"[^>]->(.-)</a>', function(href, label)
        if href:sub(1, 2) == "./"
            or href:match('^https?://%w+%.wikipedia%.org/wiki/') then
            return nil
        end
        return label
    end)
    html = html:gsub('href="./', 'href="https://' .. lang .. '.wikipedia.org/wiki/')
    html = html:gsub('src="//', 'src="https://')
    -- Thumb URLs come with an ?utm_source=... tail that would ride along
    -- into qrimage's px-rewrite and lazyfetch's fallback matching.
    html = html:gsub('src="(https://[^"%?]*)%?[^"]*"', 'src="%1"')

    if image_transform then
        -- Captions must be collected before the <img> tags are replaced.
        qrimage.collectImageCaptions(html, image_transform.captions)
        html = qrimage.replaceImagesWithLazy(html, image_transform.lazy)
    end
    return html
end

-- The pictured page is identified structurally, any language: its name
-- directly followed by a short parenthetical note ("(pictured)",
-- "(Bild)", ...), or -- where the aggregator stripped the note entirely
-- (en ITN/DYK) -- by an empty <i> wrapper. Its lead-image thumbnail
-- (links[].thumbnail / pages[].thumbnail) is the picture.
local function escapePattern(s)
    return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

local function thumbFigure(entry)
    local thumb = entry.thumbnail
    if not (thumb and thumb.source and thumb.width and thumb.height) then
        return nil
    end
    -- Link titles are dbkeys (underscores); captions read better spaced.
    return string.format(
        '<figure typeof="mw:File/Thumb"><img src="%s" width="%d" height="%d" alt=""/><figcaption>%s</figcaption></figure>',
        thumb.source, thumb.width, thumb.height,
        escapeHtml(entry.title:gsub("_", " ")))
end

local function picturedFigure(items, text_of, entries_of)
    for _, item in ipairs(items) do
        local text = text_of(item) or ""
        local entries = entries_of(item)
        if #entries > 0 then
            -- Tags stripped so a name inside an anchor stays adjacent to
            -- its note; soft hyphens (the feed sprinkles them through
            -- words) would break the name match.
            local lower_text = text:gsub("<[^>]*>", " "):gsub("\194\173", ""):lower()
            for _, entry in ipairs(entries) do
                if entry.thumbnail then
                    local name = escapePattern(entry.title:gsub("_", " "):lower())
                    -- A leading digit would be a year range, not a note.
                    if lower_text:find(name .. "%s*%([^%d%)][^%)]*%)") then
                        local figure = thumbFigure(entry)
                        if figure then return figure end
                    end
                end
            end
            -- Note and its link adjacency stripped: any thumbnailed entry
            -- of the marked item is the best the feed can offer.
            if text:find("<i[^>]*>%s*</i>") then
                for _, entry in ipairs(entries) do
                    local figure = thumbFigure(entry)
                    if figure then return figure end
                end
            end
        end
    end
end

local function buildItn(data, lang, image_transform)
    local news = data.news
    if not news or #news == 0 then return nil end
    -- Figure outside the <ul>: a figure can't be a list child.
    local figure = picturedFigure(news, function(item) return item.story end,
        function(item) return item.links or {} end)
    local items = {}
    for _, item in ipairs(news) do
        local story = item.story
        if story and story ~= "" then
            table.insert(items, "<li>" .. story .. "</li>")
        end
    end
    if #items == 0 and not figure then return nil end
    local html = figure and figure .. "\n" or ""
    if #items > 0 then
        html = html .. "<ul>\n" .. table.concat(items, "\n") .. "\n</ul>"
    end
    return cleanFeedHtml(html, lang, image_transform)
end

-- Trailing-24h pageview ranking (the feed's own date field lags a day);
-- capped: the full 44-entry ranking would swamp the news boxes.
local MOSTREAD_LIMIT = 5

local function buildMostread(data)
    local mostread = data.mostread
    if not mostread or not mostread.articles then return nil end
    local parts = {}
    for _, article in ipairs(mostread.articles) do
        if #parts >= MOSTREAD_LIMIT then break end
        local page_url = article.content_urls
            and article.content_urls.desktop
            and article.content_urls.desktop.page
        local title = article.normalizedtitle
        if page_url and title and article.extract and article.extract ~= "" then
            table.insert(parts, string.format(
                '<li><a href="%s">%s</a> &mdash; %s</li>',
                page_url, escapeHtml(title), escapeHtml(article.extract)))
        end
    end
    if #parts == 0 then return nil end
    return "<ul>" .. table.concat(parts) .. "</ul>"
end

local function buildDyk(data, lang, image_transform)
    local dyk = data.dyk
    if not dyk or #dyk == 0 then return nil end
    local parts = {}
    for _, item in ipairs(dyk) do
        local html = type(item) == "table" and item.html or item
        if html and html ~= "" then
            table.insert(parts, "<li>" .. html .. "</li>")
        end
    end
    if #parts == 0 then return nil end
    return "<ul>" .. cleanFeedHtml(table.concat(parts, "\n"), lang, image_transform) .. "</ul>"
end

local function buildOtd(data, lang, image_transform)
    local events = data.onthisday
    if not events or #events == 0 then return nil end
    -- Figure outside the <ul>: a figure can't be a list child.
    local figure = picturedFigure(events, function(item) return item.text end,
        function(item) return item.pages or {} end)
    local items = {}
    for _, event in ipairs(events) do
        local text = event.text
        if text and text ~= "" then
            -- The feed's event text omits the year the en main page shows.
            local html = event.year
                and ("<b>" .. event.year .. "</b> &ndash; " .. text)
                or text
            table.insert(items, "<li>" .. html .. "</li>")
        end
    end
    if #items == 0 and not figure then return nil end
    local html = figure and figure .. "\n" or ""
    if #items > 0 then
        html = html .. "<ul>\n" .. table.concat(items, "\n") .. "\n</ul>"
    end
    return cleanFeedHtml(html, lang, image_transform)
end

local function buildPotd(data, lang, image_transform)
    local image = data.image
    if not image then return nil end
    local thumb = image.thumbnail and image.thumbnail.source
    local caption = image.description and image.description.text or ""
    if caption == "" and not thumb then return nil end
    if thumb and image_transform then
        -- Feed thumbnail dims reserve the placeholder's real footprint
        -- (the lazy tag only carries dims it finds on the <img>).
        local dims = image.thumbnail
        local dim_attrs = dims and dims.width and dims.height
            and string.format(' width="%d" height="%d"', dims.width, dims.height)
            or ""
        local html = string.format(
            '<figure typeof="mw:File/Thumb"><img src="%s"%s alt=""/><figcaption>%s</figcaption></figure>',
            thumb, dim_attrs, escapeHtml(caption))
        return cleanFeedHtml(html, lang, image_transform)
    end
    return "<p>" .. escapeHtml(caption) .. "</p>"
end

local BUILDERS = {
    itn = buildItn,
    mostread = buildMostread,
    dyk = buildDyk,
    otd = buildOtd,
    potd = buildPotd,
}

-- Fetches today's feed for `lang` (UTC date: a local-time "today" can
-- be a future UTC date the feed answers without the news sections).
-- Returns section HTML keyed itn/mostread/dyk/otd/potd — unavailable
-- sections omitted — or nil with an error kind like
-- categories.fetchSections().
function M.fetchSections(lang, show_images, opts)
    lang = lang or "en"
    opts = opts or {}
    local image_transform
    if show_images then
        image_transform = {
            lazy = opts.lazy_images or {},
            captions = opts.image_captions or {},
        }
    end

    local url = string.format(FEED_URL, lang, os.date("!%Y/%m/%d"))
    local ok, code, sink = wutil.httpGetJSON(url)
    if not ok or code ~= 200 then return nil, "network" end
    local JSON = require("json")
    local parse_ok, data = pcall(JSON.decode, table.concat(sink))
    if not parse_ok or type(data) ~= "table" then
        return nil, "parse"
    end

    local sections = {}
    for key in pairs(BUILDERS) do
        local ok_build, section_html = pcall(BUILDERS[key], data, lang, image_transform)
        if not ok_build then
            logger.warn("wikireader: main page section failed:", key, section_html)
        elseif section_html and section_html ~= "" then
            sections[key] = section_html
        end
    end
    if next(sections) == nil then
        return nil, "empty"
    end
    return sections
end

return M
