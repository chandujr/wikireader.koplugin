-- Shared utilities for WikiReader.
-- These are functions needed by multiple modules (htmlclean, latex, epub, main).

local socket_url = require("socket.url")
local logger = require("logger")

local M = {}

--[[-------------------------------------------------------------------------
Constants for HTML notice detection (used by htmlclean.lua).
--]]
M.LEADING_NOTICE_TAGS = { "div", "table" }
M.LEADING_NOTICE_PATTERNS = {
    "hatnote", "ambox", "tmbox", "cmbox", "ombox", "dmbox", "fmbox",
    "mw:transclusion",
}

--[[-------------------------------------------------------------------------
HTTP helpers
--]]

-- Minimal GET helper for small JSON API calls.
-- Mirrors the request pattern KOReader's own frontend/ui/wikipedia.lua uses
-- internally for its Wikipedia API calls.
function M.httpGetJSON(url)
    local http = require("socket.http")
    local ltn12 = require("ltn12")

    local sink = {}
    local ok, _, code = pcall(function()
        local _, response_code = http.request{
            url = url,
            method = "GET",
            sink = ltn12.sink.table(sink),
            headers = {
                ["User-Agent"] = "KOReader-WikiReader-plugin/0.1 (personal use)",
            },
        }
        return true, response_code
    end)
    return ok, code, sink
end

--[[-------------------------------------------------------------------------
Link parsing
--]]

-- Matches an in-article link like https://en.wikipedia.org/wiki/Some_Title
-- (optionally followed by #Section_Name or a ?query string) and returns
-- lang, url-escaped-title -- e.g. "en", "Some_Title" for
-- https://en.wikipedia.org/wiki/Some_Title#Some_Section. The section
-- fragment itself is intentionally discarded: we open the full article
-- from the top rather than attempt to land on that specific heading.
function M.parseWikiLink(link_url)
    if not link_url then return nil end
    return link_url:match("^https?://([%w%-]+)%.wikipedia%.org/wiki/([^/?#]+)")
end

-- Matches a category-navigation link in a featured-articles EPUB:
-- https://en.wikipedia.org/wiki/Wikipedia:Featured_articles#section_<N>
-- and returns the section index (e.g. "51").
function M.parseCategoryLink(link_url)
    if not link_url then return nil end
    local lang, title, fragment = link_url:match("^https?://([%w%-]+)%.wikipedia%.org/wiki/([^/?#]+)#(.+)$")
    if lang and title == "Wikipedia:Featured_articles" and fragment then
        local section_index = fragment:match("^section_(%d+)$")
        if section_index then
            return section_index
        end
    end
    return nil
end

--[[-------------------------------------------------------------------------
HTML tree helpers
--]]

-- Finds the close tag matching an already-found opening tag of `tag`
-- (given the position right after that opening tag), tracking nesting
-- depth so same-named descendants don't confuse the search. Returns the
-- close tag's start and end positions, or nil if unclosed/malformed.
function M.findMatchingClose(html, tag, open_end)
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

--[[-------------------------------------------------------------------------
Date helpers
--]]

-- Normalize an arbitrary date table from the date picker into the
-- "YYYY/MM/DD" string the REST API expects.
function M.formatApiDate(year, month, day)
    return string.format("%04d/%02d/%02d", year, month, day)
end

return M
