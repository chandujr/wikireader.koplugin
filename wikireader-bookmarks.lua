-- Saved-articles list for WikiReader: articles the user bookmarked for
-- later reading, stored as {title, lang} references in G_reader_settings
-- ("wikireader_bookmarks"). Unlike history, entries never evict on their
-- own; they are only removed explicitly (long-press in the Bookmarks
-- menu, or the clear action). References only, so opening an entry goes
-- through the normal fetch/cache pipeline.

local M = {}

M.MAX_ENTRIES = 50

local SETTING_NAME = "wikireader_bookmarks"

function M.getList()
    local list = G_reader_settings:readSetting(SETTING_NAME)
    if type(list) ~= "table" then return {} end
    return list
end

-- Same normalization the cache applies (Wikipedia treats "_" and " " as
-- equivalent), so dedup matches what getCachePath would find.
local function normalizeTitle(title)
    return (title:gsub("_", " "))
end

function M.has(title, lang)
    if not title or title == "" then return false end
    lang = lang or "en"
    local norm = normalizeTitle(title)
    for _, entry in ipairs(M.getList()) do
        if normalizeTitle(entry.title) == norm and (entry.lang or "en") == lang then
            return true
        end
    end
    return false
end

-- Insert at the front (dropping any duplicate for the same lang). Returns
-- false without inserting when the list is already full.
function M.add(title, lang)
    if not title or title == "" then return false end
    lang = lang or "en"

    local list = M.getList()
    local norm = normalizeTitle(title)
    for i = #list, 1, -1 do
        if normalizeTitle(list[i].title) == norm and (list[i].lang or "en") == lang then
            table.remove(list, i)
        end
    end
    if #list >= M.MAX_ENTRIES then return false end
    table.insert(list, 1, { title = norm, lang = lang })
    G_reader_settings:saveSetting(SETTING_NAME, list)
    return true
end

function M.remove(title, lang)
    if not title then return end
    lang = lang or "en"

    local list = M.getList()
    local norm = normalizeTitle(title)
    local removed = false
    for i = #list, 1, -1 do
        if normalizeTitle(list[i].title) == norm and (list[i].lang or "en") == lang then
            table.remove(list, i)
            removed = true
        end
    end
    if removed then
        G_reader_settings:saveSetting(SETTING_NAME, list)
    end
end

function M.clear()
    G_reader_settings:delSetting(SETTING_NAME)
end

return M
