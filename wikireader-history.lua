-- Reading history for WikiReader: a most-recently-used list of the last
-- 10 articles the user actually opened, stored as {title, lang}
-- references in G_reader_settings ("wikireader_history"). Only
-- references are kept, never EPUB files: opening an entry goes through
-- the normal fetch/cache pipeline, so it reuses the cached EPUB when
-- fresh and re-downloads otherwise. Being in G_reader_settings, the list
-- survives KOReader restarts and the FileManager↔Reader instance jump.

local M = {}

M.MAX_ENTRIES = 10

local SETTING_NAME = "wikireader_history"

function M.getList()
    local list = G_reader_settings:readSetting(SETTING_NAME)
    if type(list) ~= "table" then return {} end
    return list
end

-- Wikipedia treats "_" and " " in titles as equivalent (and the cache
-- normalizes the same way in getCachePath), so normalize here too for
-- dedup, and store the space form that the rest of the plugin displays.
local function normalizeTitle(title)
    return (title:gsub("_", " "))
end

-- Drop every entry matching title+lang and persist.
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

-- Move `title` to the front of the list, trim to MAX_ENTRIES and persist.
function M.record(title, lang)
    if not title or title == "" then return end
    lang = lang or "en"

    M.remove(title, lang)
    local list = M.getList()
    table.insert(list, 1, { title = normalizeTitle(title), lang = lang })
    while #list > M.MAX_ENTRIES do
        table.remove(list)
    end
    G_reader_settings:saveSetting(SETTING_NAME, list)
end

function M.clear()
    G_reader_settings:delSetting(SETTING_NAME)
end

return M
