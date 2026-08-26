-- Cache management for WikiReader.
-- Handles deterministic file paths, expiry, and FIFO eviction for cached
-- Wikipedia article EPUBs. All state is on-disk (filesystem timestamps),
-- so it survives KOReader restarts and the FileManager↔Reader instance jump.

local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")

local M = {}

M.CACHE_MAX_ENTRIES = 10
M.CACHE_MAX_AGE_SECONDS = 24 * 60 * 60 -- 1 day

function M.getCacheDir()
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
-- calls when you delete a book.
function M.removeCachedFile(path)
    os.remove(path)
    DocSettings.updateLocation(path)
end

-- Deterministic, filesystem-safe path for a given (title, lang) pair.
-- Underscore/space are equivalent in Wikipedia titles, so normalize first
-- to make sure both forms hit the same cached file.
function M.getCachePath(title, lang)
    local dir = M.getCacheDir()
    local normalized = title:gsub("_", " ")
    local filename = util.getSafeFilename(string.format("%s - %s.epub", lang or "en", normalized), dir)
    return dir .. "/" .. filename
end

-- Returns the path if a still-fresh (< 1 day old) cached copy exists;
-- otherwise nil, deleting the file first if it exists but has expired.
function M.getFreshCachePath(title, lang)
    local path = M.getCachePath(title, lang)
    local attr = lfs.attributes(path)
    if not attr then
        return nil
    end
    if os.time() - attr.modification > M.CACHE_MAX_AGE_SECONDS then
        M.removeCachedFile(path)
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
-- purpose: mutating a directory while still iterating it isn't
-- guaranteed to visit every remaining entry on every filesystem,
-- which could silently undercount files and let more than
-- CACHE_MAX_ENTRIES pile up over time.
function M.pruneCache()
    local dir = M.getCacheDir()

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
            if now - attr.modification > M.CACHE_MAX_AGE_SECONDS then
                M.removeCachedFile(path)
            else
                table.insert(entries, { path = path, mtime = attr.modification })
            end
        end
    end

    table.sort(entries, function(a, b) return a.mtime < b.mtime end)
    while #entries > M.CACHE_MAX_ENTRIES do
        local oldest = table.remove(entries, 1)
        M.removeCachedFile(oldest.path)
    end
end

return M
