-- EPUB building for WikiReader.
-- Wraps KOReader's built-in Wikipedia.createEpub() with HTML cleanup
-- (stripping infoboxes, navboxes, image captions, etc.; converting math
-- formulas to readable text; extracting hatnotes into bordered boxes).
-- Also provides standalone EPUB builders for search results and category
-- navigation pages.

local Archiver = require("ffi/archiver")
local DocSettings = require("docsettings")
local Trapper = require("ui/trapper")
local Wikipedia = require("ui/wikipedia")
local socket_url = require("socket.url")
local util = require("util")
local logger = require("logger")
local _ = require("gettext")

local cache = require("wikireader-cache")
local cladogram = require("cladogram")
local htmlclean = require("htmlclean")
local latex = require("latex")
local wutil = require("wikiutil")

local M = {}

--[[-------------------------------------------------------------------------
Full article EPUB builder
--]]

-- Fetches and converts an article, with images permanently disabled and
-- a handful of clutter elements stripped from the HTML before it's ever
-- handed to createEpub(): infobox tables, image-caption boxes, and the
-- category list at the bottom of the article.
--
-- See the detailed comment in the original main.lua for full rationale.
function M.buildEpub(epub_path, title, lang, callback)

    -- Will hold the short description extracted from HTML
    local short_description = nil
    -- Will hold the resolved article title from the API response
    local resolved_title = nil

    -- Patch redirects support
    local original_phtml_redirects = Wikipedia.wiki_phtml_params.redirects
    Wikipedia.wiki_phtml_params.redirects = ""

    local original_getFullPageHtml = Wikipedia.getFullPageHtml
    Wikipedia.getFullPageHtml = function(self, wiki_title, wiki_lang)
        local ok, result = pcall(original_getFullPageHtml, self, wiki_title, wiki_lang)
        if not ok or not result then
            return nil
        end
        if result and result.text and result.text["*"] then
            local html = result.text["*"]

            -- Extract short description from the HTML before stripping it.
            local short_desc_pat = '<div[^>]*class="[^"]*shortdescription[^"]*"[^>]*>(.-)</div>'
            local short_desc_match = html:match(short_desc_pat)
            if short_desc_match then
                short_description = short_desc_match:gsub('&[^;]+;', ' '):gsub('%s+', ' '):match('^%s*(.-)%s*$')
                if short_description == '' then
                    short_description = nil
                end
            end

            -- Fallback: query API's pageprops for short description
            if not short_description then
                local JSON = require("json")
                local props_url = string.format(
                    "https://%s.wikipedia.org/w/api.php?action=query&prop=pageprops&titles=%s&format=json",
                    wiki_lang or "en", socket_url.escape(wiki_title)
                )
                local props_ok, props_code, props_sink = wutil.httpGetJSON(props_url)
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

            -- Capture the resolved title from the API response
            if result.title then
                resolved_title = result.title
            end

            -- Strip clutter elements
            html = htmlclean.stripElementsByClass(html, "table", { "infobox", "navbox", "sidebar", "vertical-navbox", "rmbox" })
            html = htmlclean.cleanElementClasses(html, "table", { "wikitable" }, { "floatleft", "floatright" }, function(style)
                if style == "" then
                    return "width:100%%"
                elseif style:find('width%s*:') then
                    return style:gsub('width%s*:%s*[^;]+', 'width:100%%')
                else
                    return style .. ';width:100%%'
                end
            end)
            html = htmlclean.stripElementsByClass(html, "div", { "thumb", "catlinks", "navbox", "vertical-navbox", "side-box", "spoken-wikipedia", "shortdescription" })
            html = htmlclean.stripElementsByClass(html, "ul", { "gallery" })
            html = htmlclean.cleanElementClasses(html, "div", { "quotebox", "pullquote" }, { "floatleft", "floatright" }, true)
            html = htmlclean.stripElementsByClass(html, "span", { "geo-inline-hidden" })
            html = htmlclean.mergeQuoteCites(html)
            html = htmlclean.stripElementsByAttr(html, "figure", "typeof", { "mw:file", "mw:image", "mw:video", "mw:audio" })
            html = html:gsub("<audio.-</audio%s*>", "")
            html = latex.replaceMathElements(html)
            -- Render cladograms (Template:Clade phylogeny trees) as text
            -- diagrams, since crengine cannot draw their CSS border lines.
            html = cladogram.replaceCladograms(html)

            -- Extract hatnotes and wrap section notices
            local notices, rest = htmlclean.extractLeadingNotices(html)
            rest = htmlclean.wrapSectionNotices(rest)
            if notices ~= "" then
                html = string.format(
                    [[<div class="wikireader-notices">%s</div><hr class="koreaderwikifrontpage"/>%s]],
                    notices, rest
                )
            else
                html = [[<hr class="koreaderwikifrontpage"/>]] .. rest
            end

            result.text["*"] = html
        end
        return result
    end

    -- Patch the Archiver to fix front matter, add short description, and
    -- inject stylesheet rules.
    local original_addFileFromMemory = Archiver.Writer.addFileFromMemory
    Archiver.Writer.addFileFromMemory = function(self, entry_path, content, mtime)
        if entry_path == "OEBPS/content.html" then
            content = htmlclean.stripElementsByClass(content, "p", { "koreaderwikifrontpage" })
            content = htmlclean.stripElementsByClass(content, "h5", { "koreaderwikifrontpage" })
            content = content:gsub('<hr class="koreaderwikifrontpage"%s*/?>', "", 1)
            if short_description and short_description ~= "" then
                content = content:gsub(
                    '(<h1[^>]*>.-</h1>)',
                    '%1\n<div style="font-style:italic; color:#666; margin-top:0.2em; margin-bottom:1em; text-align:center;">' .. short_description .. '</div>'
                )
            end
            if resolved_title then
                content = content:gsub('(<title>).-(</title>)', '%1' .. resolved_title .. '%2')
            end
        elseif entry_path == "OEBPS/content.opf" then
            if resolved_title then
                content = content:gsub('(<dc:title>).-(</dc:title>)', '%1' .. resolved_title .. '%2')
            end
        elseif entry_path == "OEBPS/toc.ncx" then
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

/* Attribution line of Template:Quote, merged inside blockquote by
   htmlclean.mergeQuoteCites(). Right-aligned, normal weight and slightly
   smaller so it reads as a distinct " — who said it" trailing note. */
.wikireader-cite {
  text-align: right;
  font-style: normal;
  font-size: 85%;
  margin-top: 0.4em;
}

/* Fallback in case any templatequotecite div was not merged into a
   blockquote, so it never renders as a bare dangling line. */
.templatequotecite {
  text-align: right;
  font-style: italic;
  font-size: 85%;
  margin: 0.2em 0 0.8em 0;
}

.wikireader-math {
  white-space: nowrap;
}

/* Cladogram (phylogeny tree) diagrams, converted to box-drawing text by
   cladogram.lua. The base stylesheet already keeps <pre> left-aligned;
   shrink the monospace a touch and keep lines from stretching across the
   full page so the tree reads as one compact diagram. */
pre.wikireader-cladogram {
  font-size: 90%;
  line-height: 1.25;
  margin: 0.5em 0;
}
]]
        end
        return original_addFileFromMemory(self, entry_path, content, mtime)
    end

    Trapper:wrap(function()
        local ok, success = pcall(Wikipedia.createEpub, Wikipedia, epub_path, title, lang, false)
        -- Always restore all patches
        Wikipedia.wiki_phtml_params.redirects = original_phtml_redirects
        Wikipedia.getFullPageHtml = original_getFullPageHtml
        Archiver.Writer.addFileFromMemory = original_addFileFromMemory
        if ok and success then
            local used_path = epub_path
            if resolved_title and resolved_title ~= title then
                local new_path = cache.getCachePath(resolved_title, lang)
                if new_path ~= epub_path then
                    os.rename(epub_path, new_path)
                    DocSettings.updateLocation(epub_path, new_path)
                    used_path = new_path
                end
            end
            callback(true, used_path, resolved_title)
        else
            Trapper:reset()
            callback(false)
        end
    end)
end

--[[-------------------------------------------------------------------------
Search results EPUB builder
--]]

-- Build a minimal EPUB from a list of Wikipedia search results. Each
-- result is a clickable link the plugin's link handler can intercept.
-- If custom_title is provided, it's used as the page heading instead of
-- "Search results for...".
function M.buildSearchEpub(epub_path, query, lang, results, callback, custom_title)
    local mtime = os.time()

    local display_title = custom_title or query
    local is_search = not custom_title

    local html_parts = {}
    table.insert(html_parts, '<?xml version="1.0" encoding="utf-8"?>\n')
    table.insert(html_parts, '<!DOCTYPE html>\n')
    table.insert(html_parts, '<html xmlns="http://www.w3.org/1999/xhtml">\n')
    table.insert(html_parts, '<head>\n')
    table.insert(html_parts, '<meta charset="utf-8"/>\n')
    table.insert(html_parts, '<link rel="stylesheet" type="text/css" href="stylesheet.css"/>\n')
    table.insert(html_parts, '<title>')
    if is_search then
        table.insert(html_parts, string.format('Search results for "%s"', query))
    else
        table.insert(html_parts, display_title)
    end
    table.insert(html_parts, '</title>\n')
    table.insert(html_parts, '</head>\n')
    table.insert(html_parts, '<body>\n')
    if is_search then
        table.insert(html_parts, '<h1 class="koreaderwikifrontpage">Search results</h1>\n')
        table.insert(html_parts, '<p class="koreaderwikifrontpage">')
        table.insert(html_parts, string.format('for "%s"', query))
        table.insert(html_parts, '</p>\n')
        table.insert(html_parts, '<hr class="koreaderwikifrontpage"/>\n')
    else
        table.insert(html_parts, '<h1 class="koreaderwikifrontpage">')
        table.insert(html_parts, display_title)
        table.insert(html_parts, '</h1>\n')
        table.insert(html_parts, '<hr class="koreaderwikifrontpage"/>\n')
    end

    for _, result in ipairs(results) do
        local result_title = result.title
        local snippet = (result.snippet or ""):gsub("<[^>]*>", "")
        snippet = util.htmlEntitiesToUtf8(snippet)
        if snippet ~= "" and not snippet:match("[.!?…]$") then
            snippet = snippet .. "…"
        end
        result_title = result_title:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
        snippet = snippet:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
        local link = string.format('https://%s.wikipedia.org/wiki/%s', lang, socket_url.escape(result.title))

        if snippet == "" then
            table.insert(html_parts, string.format(
                '<p class="article-link"><a href="%s">· %s</a></p>\n',
                link, result_title))
        else
            table.insert(html_parts, string.format(
                '<p class="article-link"><a href="%s">· %s</a></p>\n<p class="snippet">%s</p>\n',
                link, result_title, snippet))
        end
    end

    table.insert(html_parts, '</body>\n')
    table.insert(html_parts, '</html>\n')
    local html_content = table.concat(html_parts)

    local css = [[
body {
  text-align: justify;
}
h1.koreaderwikifrontpage {
  text-align: center;
  margin-top: 0;
}
p.koreaderwikifrontpage {
  font-style: italic;
  text-align: center;
  margin-bottom: 1em;
  text-indent: 0;
}
hr.koreaderwikifrontpage {
  margin-left: 20%;
  margin-right: 20%;
  margin-bottom: 1.2em;
}
.search-result {
  margin-bottom: 1em;
}
p.article-link {
  margin: 0.4em 0;
}
p.snippet {
  margin: 0 0 0.8em 0;
  font-size: 80%;
}
a {
  text-decoration: underline;
  color: inherit;
}
]]

    local epub = Archiver.Writer:new{}
    local epub_path_tmp = epub_path .. ".tmp"
    if not epub:open(epub_path_tmp, "epub") then
        callback(false)
        return
    end

    epub:setZipCompression("store")
    epub:addFileFromMemory("mimetype", "application/epub+zip", mtime)
    epub:setZipCompression("deflate")

    epub:addFileFromMemory("META-INF/container.xml", [[
<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>]], mtime)

    local bookid = string.format("search_%s_%s_%d", lang, query:gsub("[^%w]", "_"), mtime)
    local opf = string.format([[
<?xml version='1.0' encoding='utf-8'?>
<package xmlns="http://www.idpf.org/2007/opf"
        xmlns:dc="http://purl.org/dc/elements/1.1/"
        unique-identifier="bookid" version="2.0">
  <metadata>
    <dc:title>Search results for "%s"</dc:title>
    <dc:identifier id="bookid">%s</dc:identifier>
    <dc:language>%s</dc:language>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="content" href="content.html" media-type="application/xhtml+xml"/>
    <item id="css" href="stylesheet.css" media-type="text/css"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="content"/>
  </spine>
</package>
]], query, bookid, lang)
    epub:addFileFromMemory("OEBPS/content.opf", opf, mtime)
    epub:addFileFromMemory("OEBPS/content.html", html_content, mtime)
    epub:addFileFromMemory("OEBPS/stylesheet.css", css, mtime)

    local ncx = string.format([[
<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head>
    <meta name="dtb:uid" content="%s"/>
    <meta name="dtb:depth" content="1"/>
    <meta name="dtb:totalPageCount" content="0"/>
    <meta name="dtb:maxPageNumber" content="0"/>
  </head>
  <docTitle>
    <text>Search results for "%s"</text>
  </docTitle>
  <navMap>
    <navPoint id="navpoint-1" playOrder="1">
      <navLabel>
        <text>Search results</text>
      </navLabel>
      <content src="content.html"/>
    </navPoint>
  </navMap>
</ncx>
]], bookid, query)
    epub:addFileFromMemory("OEBPS/toc.ncx", ncx, mtime)
    epub:close()

    os.rename(epub_path_tmp, epub_path)
    callback(true, epub_path)
end

--[[-------------------------------------------------------------------------
Category EPUB builder
--]]

-- Build an EPUB for a level of the category tree (subcategories plus any
-- leaf articles), then open it. Subcategories use a special URL format
-- that the link handler intercepts; articles use standard Wikipedia URLs.
function M.buildCategoryEpub(nodes, title, lang, direct_articles)
    local html_parts = {}
    table.insert(html_parts, '<?xml version="1.0" encoding="utf-8"?>\n')
    table.insert(html_parts, '<!DOCTYPE html>\n')
    table.insert(html_parts, '<html xmlns="http://www.w3.org/1999/xhtml">\n')
    table.insert(html_parts, '<head>\n')
    table.insert(html_parts, '<meta charset="utf-8"/>\n')
    table.insert(html_parts, '<link rel="stylesheet" type="text/css" href="stylesheet.css"/>\n')
    table.insert(html_parts, '<title>')
    table.insert(html_parts, title)
    table.insert(html_parts, '</title>\n')
    table.insert(html_parts, '</head>\n')
    table.insert(html_parts, '<body>\n')
    table.insert(html_parts, '<h1>')
    table.insert(html_parts, title)
    table.insert(html_parts, '</h1>\n')
    table.insert(html_parts, '<hr/>\n')

    -- Subcategories
    for _, node in ipairs(nodes) do
        local escaped_title = node.title:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
        local link = string.format('https://%s.wikipedia.org/wiki/Wikipedia:Featured_articles#section_%s',
            lang, node.section_index)
        table.insert(html_parts, string.format(
            '<p class="category-link"><a href="%s">▸ %s</a></p>\n',
            link, escaped_title))
    end

    -- Direct articles
    if direct_articles and #direct_articles > 0 then
        if #nodes > 0 then
            table.insert(html_parts, '<hr/>\n')
        end
        for _, article in ipairs(direct_articles) do
            local escaped_title = article.title:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
            local link = string.format('https://%s.wikipedia.org/wiki/%s', lang, socket_url.escape(article.title))
            table.insert(html_parts, string.format(
                '<p class="article-link"><a href="%s">· %s</a></p>\n',
                link, escaped_title))
        end
    end

    table.insert(html_parts, '</body>\n')
    table.insert(html_parts, '</html>\n')
    local html_content = table.concat(html_parts)

    local css = [[
body {
  text-align: justify;
}
h1 {
  text-align: center;
  margin-top: 0;
}
h2 {
  font-size: 120%;
  margin-top: 1em;
}
hr {
  margin-left: 20%;
  margin-right: 20%;
  margin-bottom: 1em;
}
p.category-link {
  margin: 0.5em 0;
}
p.article-link {
  margin: 0.3em 0;
}
a {
  text-decoration: underline;
  color: inherit;
}
]]

    local epub_path = cache.getCachePath("__category__" .. title, lang)
    local mtime = os.time()
    local epub = Archiver.Writer:new{}
    local epub_path_tmp = epub_path .. ".tmp"
    if not epub:open(epub_path_tmp, "epub") then
        return false
    end

    epub:setZipCompression("store")
    epub:addFileFromMemory("mimetype", "application/epub+zip", mtime)
    epub:setZipCompression("deflate")

    epub:addFileFromMemory("META-INF/container.xml", [[
<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>]], mtime)

    local safe_title = title:gsub("[^%w]", "_")
    local bookid = string.format("category_%s_%s_%d", lang, safe_title, mtime)
    local opf = string.format([[
<?xml version='1.0' encoding='utf-8'?>
<package xmlns="http://www.idpf.org/2007/opf"
        xmlns:dc="http://purl.org/dc/elements/1.1/"
        unique-identifier="bookid" version="2.0">
  <metadata>
    <dc:title>%s</dc:title>
    <dc:identifier id="bookid">%s</dc:identifier>
    <dc:language>%s</dc:language>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="content" href="content.html" media-type="application/xhtml+xml"/>
    <item id="css" href="stylesheet.css" media-type="text/css"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="content"/>
  </spine>
</package>
]], title, bookid, lang)
    epub:addFileFromMemory("OEBPS/content.opf", opf, mtime)
    epub:addFileFromMemory("OEBPS/content.html", html_content, mtime)
    epub:addFileFromMemory("OEBPS/stylesheet.css", css, mtime)

    local ncx = string.format([[
<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head>
    <meta name="dtb:uid" content="%s"/>
    <meta name="dtb:depth" content="1"/>
    <meta name="dtb:totalPageCount" content="0"/>
    <meta name="dtb:maxPageNumber" content="0"/>
  </head>
  <docTitle>
    <text>%s</text>
  </docTitle>
  <navMap>
    <navPoint id="navpoint-1" playOrder="1">
      <navLabel>
        <text>%s</text>
      </navLabel>
      <content src="content.html"/>
    </navPoint>
  </navMap>
</ncx>
]], bookid, title, title)
    epub:addFileFromMemory("OEBPS/toc.ncx", ncx, mtime)
    epub:close()

    os.rename(epub_path_tmp, epub_path)
    return true, epub_path
end

return M
