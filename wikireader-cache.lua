-- Cache management for WikiReader.
-- Handles deterministic file paths, expiry, FIFO eviction, and full-cache
-- wipes for cached Wikipedia article EPUBs. All state is on-disk
-- (filesystem timestamps),
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

-- Path for internally-keyed helper pages (search results, category
-- lists, main page). Unlike getCachePath(), the "__kind__" sentinel
-- survives into the filename so onReaderReady() can recognise reopened
-- helper pages (getCachePath()'s "_"→" " normalisation would erase it).
function M.getHelperCachePath(kind, name, lang)
    local dir = M.getCacheDir()
    local filename = util.getSafeFilename(string.format("%s - %s%s.epub", lang or "en", kind, name), dir)
    return dir .. "/" .. filename
end

-- Returns the path if a still-fresh (< 1 day old) cached copy exists;
-- otherwise nil, deleting the file first if it exists but has expired.
-- keep_path (the file the open reader is displaying) is exempt: the
-- refetch that follows the cache miss overwrites it in place, so it must
-- survive -- with its .sdr sidecar and while crengine still has it open.
function M.getFreshCachePath(title, lang, keep_path)
    local path = M.getCachePath(title, lang)
    local attr = lfs.attributes(path)
    if not attr then
        return nil
    end
    if os.time() - attr.modification > M.CACHE_MAX_AGE_SECONDS then
        if path ~= keep_path then
            M.removeCachedFile(path)
        end
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
-- keep_path is never deleted or evicted. It is the file the active
-- reader is displaying; during KOReader's last-file restore, plugins are
-- initialised before the post-init callback that makes crengine parse
-- the document, so deleting an expired last-file here used to make
-- loadDocument() hit a vanished file and KOReader fatal-exit with
-- "unsupported or invalid document".
--
-- Listing and deleting are kept as two fully separate passes on
-- purpose: mutating a directory while still iterating it isn't
-- guaranteed to visit every remaining entry on every filesystem,
-- which could silently undercount files and let more than
-- CACHE_MAX_ENTRIES pile up over time.
function M.pruneCache(keep_path)
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
            if now - attr.modification > M.CACHE_MAX_AGE_SECONDS and path ~= keep_path then
                M.removeCachedFile(path)
            else
                table.insert(entries, { path = path, mtime = attr.modification })
            end
        end
    end

    table.sort(entries, function(a, b) return a.mtime < b.mtime end)
    while #entries > M.CACHE_MAX_ENTRIES do
        local oldest = table.remove(entries, 1)
        if oldest.path ~= keep_path then
            M.removeCachedFile(oldest.path)
        end
    end
end

-- Any .epub counts, even an expired one: it is still visible in the
-- FileManager and still deleted by wipeAll(), so it should keep the
-- "Clear cache" menu entry enabled.
function M.isEmpty()
    for name in lfs.dir(M.getCacheDir()) do
        if name:match("%.epub$") then
            return false
        end
    end
    return true
end

-- Delete every cached article: epub files (via removeCachedFile so their
-- .sdr sidecars go too), any other leftover files, and then the remaining
-- directories (sidecars/orphans). Also drops the deleted epubs from
-- KOReader's reading history, like deleting the files in the FileManager
-- would: otherwise stale entries (and "lastfile") trigger a "Cannot open
-- last file" popup on startup. Returns the number of files deleted.
-- Two separate listing/deleting passes, for the same reason as
-- pruneCache(): mutating a directory while iterating it can silently
-- skip entries on some filesystems.
function M.wipeAll()
    local dir = M.getCacheDir()
    local count = 0
    local deleted_epubs = {}

    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." then
            local path = dir .. "/" .. name
            local attr = lfs.attributes(path)
            if attr and attr.mode == "file" then
                if name:match("%.epub$") then
                    M.removeCachedFile(path)
                    deleted_epubs[path] = true
                else
                    os.remove(path)
                end
                count = count + 1
            end
        end
    end

    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." then
            local path = dir .. "/" .. name
            local attr = lfs.attributes(path)
            if attr and attr.mode == "directory" then
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

    if next(deleted_epubs) then
        local ReadHistory = require("readhistory")
        ReadHistory:removeItems(deleted_epubs)
        -- removeItems calls this only for some settings; do it
        -- unconditionally so "lastfile" is always fixed up.
        ReadHistory:ensureLastFile()
    end

    return count
end

return M
