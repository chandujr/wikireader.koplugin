-- LaTeX formula rendering for WikiReader. Wikipedia renders every formula
-- (display and inline) as hidden MathML plus a visible <img> of its
-- rendered SVG; with images disabled the formulas would vanish. This pass
-- rewrites each mwe-math-element wrapper into a marker span for the
-- formula's real /math/render/svg/ file. Nothing is downloaded at build
-- time: epub.lua lists the URLs in OEBPS/wikireader-pending.json (ahead
-- of the photographs, so lazyfetch fills its download slots with formulas
-- first) and lazyfetch.lua fetches them after the article opens and
-- rewrites the zip. A URL that never downloads leaves its marker blank;
-- the surrounding text keeps flowing.

local wutil = require("wikiutil")

local M = {}

-- Wikipedia's own sizing style on the formula <img> (vertical-align /
-- width / height in ex) scales with the body font and reserves the right
-- footprint while the file is still missing. Display formulas sit on
-- their own line (the inline sizing style would otherwise let body text
-- wrap around the wide formula); inline formulas keep the ex sizing and
-- get max-width as an overflow guard for display-style equations
-- embedded in a lead paragraph.
local function mathImgStyle(is_block, wiki_style)
    wiki_style = wiki_style:gsub(";%s*$", "")
    if is_block then
        return "display:block; margin:0.6em auto; " .. wiki_style
    elseif wiki_style ~= "" then
        return wiki_style .. "; max-width:100%"
    else
        return "max-width:100%"
    end
end

-- Replace every <span class="mwe-math-element...">...</span> block (the
-- wrapper around every formula, display or inline) with a marker span
-- registered in math_images: one {src, imgpath, mimetype, style} record
-- per distinct SVG (deduped by SVG hash; identical formulas re-point at
-- the same entry). epub.lua swaps the markers for real <img> tags in its
-- Archiver hooks.
function M.replaceMathElements(html, math_images)
    local seen = {}
    local out = {}
    local pos = 1
    local open_pat = '<span class="mwe%-math%-element[^>]*>'
    while true do
        local s, e = html:find(open_pat, pos)
        if not s then
            table.insert(out, html:sub(pos))
            break
        end
        local open_tag = html:sub(s, e)
        local _, ce = wutil.findMatchingClose(html, "span", e)
        if not ce then
            table.insert(out, html:sub(pos))
            break
        end
        local img_tag = html:sub(s, ce):match("<img[^>]-/math/render/svg/[^>]*>")
        local src = img_tag and img_tag:match('src%s*=%s*"([^"]*)"')
        local key = src and src:match("/math/render/svg/(.-)%s*$")
        if key then
            local is_block = open_tag:find("mwe%-math%-element%-block", 1) ~= nil
            local index = seen[key]
            if not index then
                index = #math_images + 1
                seen[key] = index
                -- Parsoid emits both absolute ("https://upload...") and
                -- protocol-relative ("//upload...") srcs; the downloader
                -- wants an absolute URL.
                math_images[index] = {
                    math = true,
                    imgpath = string.format("images/math%05d.svg", index),
                    mimetype = "image/svg+xml",
                    src = src:sub(1, 2) == "//" and "https:" .. src or src,
                    inline = not is_block,
                    style = mathImgStyle(is_block,
                        img_tag:match('style%s*=%s*"([^"]*)"') or ""),
                }
            end
            table.insert(out, html:sub(pos, s - 1))
            table.insert(out, string.format(
                '<span class="wikireader-mathimg" data-mathimgindex="%d"></span>', index))
            pos = ce + 1
        else
            -- No SVG URL (unusual wrapper): keep the span as-is; the
            -- MathML inside is styled display:none, so nothing dangles.
            table.insert(out, html:sub(pos, ce))
            pos = ce + 1
        end
    end
    return table.concat(out)
end

return M
