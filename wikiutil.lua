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
-- internally for its Wikipedia API calls, including socketutil-based
-- timeouts (10 s per block / 30 s total, same as getUrlContent defaults)
-- so a stalled connection fails instead of blocking the UI forever.
-- Callers already treat `not ok or code ~= 200` as a network failure, so a
-- timeout flows through that same path — no caller changes needed.
function M.httpGetJSON(url)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socketutil = require("socketutil")

    local sink = {}
    local ok, code
    socketutil:set_timeout(10, 30)
    -- socketutil's table_sink also enforces the total timeout across chunks,
    -- which a plain ltn12.sink.table would not.
    local pcall_ok = pcall(function()
        local request_ok, request_code_or_err = http.request{
            url = url,
            method = "GET",
            sink = socketutil.table_sink(sink),
            headers = {
                ["User-Agent"] = "KOReader-WikiReader-plugin/0.1 (personal use)",
            },
        }
        if not request_ok then
            -- Timeouts surface here as socketutil.TIMEOUT_CODE /
            -- SINK_TIMEOUT_CODE / SSL_HANDSHAKE_CODE, never as raises.
            ok = false
            logger.warn("WikiReader API request failed:", request_code_or_err, url)
        else
            ok = true
            code = request_code_or_err
        end
    end)
    -- Must run even after a pcall'd error, or all later LuaSocket traffic in
    -- KOReader keeps the patched (tight) timeouts.
    socketutil:reset_timeout()
    if not pcall_ok then
        ok = false
    end
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
