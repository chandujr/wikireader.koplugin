-- LaTeX-to-readable-text conversion for WikiReader.
-- Wikipedia renders formulas as hidden MathML + visible <img>. With images
-- disabled, formulas vanish. This module extracts the raw LaTeX source from
-- <math> blocks and converts it to a best-effort Unicode transcription.

local wutil = require("wikiutil")
local util = require("util")
local logger = require("logger")

local M = {}

--[[-------------------------------------------------------------------------
Unicode mapping tables
--]]

-- Unicode superscripts (all common chars)
local ltx_sup = {
    ["0"]="⁰", ["1"]="¹", ["2"]="²", ["3"]="³", ["4"]="⁴",
    ["5"]="⁵", ["6"]="⁶", ["7"]="⁷", ["8"]="⁸", ["9"]="⁹",
    ["-"]="⁻", ["+"]="⁺", ["("]="⁽", [")"]="⁾", [","]=",",
}
-- Unicode subscripts (digits and a few letters)
local ltx_sub = {
    ["0"]="₀", ["1"]="₁", ["2"]="₂", ["3"]="₃", ["4"]="₄",
    ["5"]="₅", ["6"]="₆", ["7"]="₇", ["8"]="₈", ["9"]="₉",
    ["-"]="₋", ["+"]="₊", ["("]="₍", [")"]="₎",
}

-- Symbols that are just a single Unicode character
local ltx_sym = {
    partial="∂", nabla="∇", infty="∞", cdot="·",
    pm="±", mp="∓", times="×", div="÷",
    forall="∀", exists="∃",
    ["in"]="∈", notin="∉", ni="∋",
    subset="⊂", supset="⊃", subseteq="⊆", supseteq="⊇",
    subsetneq="⊊", supsetneq="⊋",
    cup="∪", cap="∩", setminus="∖",
    emptyset="∅", varnothing="∅",
    to="→", rightarrow="→", leftarrow="←",
    leftrightarrow="↔", Rightarrow="⇒", Leftarrow="⇐",
    Leftrightarrow="⇔", longrightarrow="→",
    uparrow="↑", downarrow="↓", mapsto="↦",
    mid="|", parallel="∥", lvert="|", rvert="|", vert="|", Vert="‖",
    lVert="‖", rVert="‖", colon=":",
    star="⋆", ast="∗", bullet="•", circ="∘", odot="⊙", oplus="⊕", otimes="⊗",
    lfloor="⌊", rfloor="⌋", lceil="⌈", rceil="⌉", angle="∠",Triangle="△",
    diamond="◇", square="□", checkmark="✓", degree="°", ell="…",
    leq="≤", le="≤", geq="≥", ge="≥", neq="≠", ne="≠",
    approx="≈", sim="∼", simeq="≃", cong="≅", equiv="≡",
    propto="∝", ldots="…", dots="…", cdots="⋯", vdots="⋮", ddots="⋱",
    int="∫", iint="∬", iiint="∭", oint="∮",
    sum="∑", prod="∏", coprod="∐",
    prime="′", ell="ℓ", ellipsis="…", prime2="″",
    langle="⟨", rangle="⟩",
    neg="¬", land="∧", lor="∨", iff="⇔", implies="⇒",
    Re="ℜ", Im="ℑ", hbar="ℏ", aleph="ℵ",
    therefore="∴", because="∵",
    left="", right="", big="", Big="", bigg="", Bigg="",
    bigl="", bigr="", Bigl="", Bigr="", biggl="", biggr="", Biggl="", Biggr="",
    displaystyle="", textstyle="", scriptstyle="", scriptscriptstyle="",
    quad=" ", qquad=" ", enskip=" ", enspace=" ", thinspace=" ",
    ["not"]="¬",
}

local ltx_greek = {
    alpha="α", beta="β", gamma="γ", delta="δ",
    epsilon="ε", varepsilon="ε", zeta="ζ", eta="η",
    theta="θ", vartheta="ϑ", iota="ι", kappa="κ",
    lambda="λ", mu="μ", nu="ν", xi="ξ",
    pi="π", varpi="ϖ", rho="ρ", varrho="ϱ",
    sigma="σ", varsigma="ς", tau="τ", upsilon="υ",
    phi="φ", varphi="φ", chi="χ", psi="ψ", omega="ω",
    Gamma="Γ", Delta="Δ", Theta="Θ", Lambda="Λ",
    Xi="Ξ", Pi="Π", Sigma="Σ", Upsilon="Υ",
    Phi="Φ", Psi="Ψ", Omega="Ω",
}

--[[-------------------------------------------------------------------------
LaTeX parsing helpers
--]]

local function ltxConsumeGroup(tex, pos)
    local depth = 0
    local i = pos
    local n = #tex
    while i <= n do
        local c = tex:sub(i, i)
        if c == "{" then
            depth = depth + 1
        elseif c == "}" then
            depth = depth - 1
            if depth == 0 then
                return tex:sub(pos + 1, i - 1), i
            end
        end
        i = i + 1
    end
    return tex:sub(pos + 1), n
end

local function ltxSkipSpaces(tex, pos)
    while pos <= #tex and (tex:sub(pos, pos) == " " or tex:sub(pos, pos) == "\t") do
        pos = pos + 1
    end
    return pos
end

local function ltxReadArg(tex, pos)
    pos = ltxSkipSpaces(tex, pos)
    if tex:sub(pos, pos) == "{" then
        local inner, e = ltxConsumeGroup(tex, pos)
        return inner, e + 1
    end
    if tex:sub(pos, pos) == "\\" then
        local cs, ce = tex:find("\\[a-zA-Z]+", pos)
        if cs and cs == pos then
            return tex:sub(pos, ce), ce + 1
        end
        return tex:sub(pos, pos + 1), pos + 2
    end
    return tex:sub(pos, pos), pos + 1
end

local function ltxSup(str)
    local out, all_sup = {}, true
    for i = 1, #str do
        local c = str:sub(i, i)
        local u = ltx_sup[c]
        if u then
            out[#out+1] = u
        else
            all_sup = false
            break
        end
    end
    if all_sup and #out > 0 then
        return table.concat(out)
    end
    if #str == 0 then
        return ""
    end
    if #str == 1 then
        return "^" .. str
    end
    return "^( " .. str .. " )"
end

local function ltxSub(str)
    local out, all_sub = {}, true
    for i = 1, #str do
        local c = str:sub(i, i)
        local u = ltx_sub[c]
        if u then
            out[#out+1] = u
        else
            all_sub = false
            break
        end
    end
    if all_sub and #out > 0 then
        return table.concat(out)
    end
    if #str == 0 then
        return ""
    end
    if #str == 1 then
        return "_" .. str
    end
    return "_(" .. str .. ")"
end

--[[-------------------------------------------------------------------------
Core LaTeX-to-text converter
--]]

local function ltxToText(tex)
    local out = {}
    local pos, n = 1, #tex
    while pos <= n do
        local c = tex:sub(pos, pos)
        if c == "\\" then
            local cmd = nil
            local cmd_cs, cmd_ce = tex:find("\\[a-zA-Z]+", pos)
            if cmd_cs and cmd_cs == pos then
                cmd = tex:sub(pos + 1, cmd_ce)
                pos = cmd_ce + 1
            end
            if cmd then
                if cmd == "frac" or cmd == "dfrac" or cmd == "tfrac" then
                    local num, den
                    num, pos = ltxReadArg(tex, pos)
                    den, pos = ltxReadArg(tex, pos)
                    table.insert(out, "(" .. ltxToText(num) .. ")/(" .. ltxToText(den) .. ")")
                elseif cmd == "sqrt" then
                    pos = ltxSkipSpaces(tex, pos)
                    if tex:sub(pos, pos) == "[" then
                        local close = tex:find("]", pos)
                        pos = (close or pos) + 1
                        pos = ltxSkipSpaces(tex, pos)
                    end
                    if tex:sub(pos, pos) == "{" then
                        local e
                        local inner
                        inner, e = ltxConsumeGroup(tex, pos)
                        pos = e + 1
                        table.insert(out, "√(" .. ltxToText(inner) .. ")")
                    else
                        table.insert(out, "√")
                    end
                elseif cmd == "begin" or cmd == "end" then
                    pos = ltxSkipSpaces(tex, pos)
                    if tex:sub(pos, pos) == "{" then
                        local e
                        _, e = ltxConsumeGroup(tex, pos)
                        pos = e + 1
                    end
                elseif cmd == "text" or cmd == "mathrm" or cmd == "textnormal"
                    or cmd == "boldsymbol" or cmd == "mathbf" or cmd == "mathit"
                    or cmd == "mbox" or cmd == "hbox" then
                    pos = ltxSkipSpaces(tex, pos)
                    if tex:sub(pos, pos) == "{" then
                        local e, inner
                        inner, e = ltxConsumeGroup(tex, pos)
                        pos = e + 1
                        -- Wikipedia bolds symbols (mathbf{alpha}) but the
                        -- content is still math; transcribe recursively or the
                        -- raw \alpha would leak through as literal text.
                        -- Trim the padding Wikipedia puts inside the braces
                        -- (mathbf{psi } -> "psi "), except in text-like
                        -- commands where trailing spaces can be meaningful.
                        local trim = cmd ~= "text" and cmd ~= "mathrm"
                            and cmd ~= "textnormal" and cmd ~= "mbox" and cmd ~= "hbox"
                        table.insert(out, ltxToText(trim
                            and inner:gsub("^%s+", ""):gsub("%s+$", "")
                            or inner))
                        -- Wikipedia also pads after the group (mathbf{psi } (t,x));
                        -- real math rendering drops that space too.
                        if trim then pos = ltxSkipSpaces(tex, pos) end
                    end
                elseif cmd == "operatorname" then
                    pos = ltxSkipSpaces(tex, pos)
                    if tex:sub(pos, pos) == "{" then
                        local e, inner
                        inner, e = ltxConsumeGroup(tex, pos)
                        pos = e + 1
                        table.insert(out, ltxToText(inner))
                    end
                elseif cmd == "mathbb" or cmd == "Bbb" then
                    pos = ltxSkipSpaces(tex, pos)
                    if tex:sub(pos, pos) == "{" then
                        local e, inner
                        inner, e = ltxConsumeGroup(tex, pos)
                        pos = e + 1
                        local bb = { R="ℝ", C="ℂ", N="ℕ", Z="ℤ", Q="ℚ", H="ℍ", P="ℙ" }
                        table.insert(out, bb[inner] or inner)
                    end
                elseif cmd == "overline" or cmd == "bar" or cmd == "prime" then
                    pos = ltxSkipSpaces(tex, pos)
                    if tex:sub(pos, pos) == "{" then
                        local e, inner
                        inner, e = ltxConsumeGroup(tex, pos)
                        pos = e + 1
                        table.insert(out, ltxToText(inner))
                    end
                elseif cmd == "vec" or cmd == "hat" or cmd == "dot"
                    or cmd == "ddot" or cmd == "tilde" then
                    pos = ltxSkipSpaces(tex, pos)
                    if tex:sub(pos, pos) == "{" then
                        local e, inner
                        inner, e = ltxConsumeGroup(tex, pos)
                        pos = e + 1
                        table.insert(out, ltxToText(inner))
                    end
                elseif cmd == "pmod" or cmd == "bmod" or cmd == "mod" then
                    local arg
                    arg, pos = ltxReadArg(tex, pos)
                    if cmd == "pmod" then
                        table.insert(out, "(mod " .. ltxToText(arg) .. ")")
                    else
                        table.insert(out, "mod " .. ltxToText(arg))
                    end
                elseif cmd == "left" or cmd == "right" then
                    pos = ltxSkipSpaces(tex, pos)
                    local d = tex:sub(pos, pos)
                    if d == "\\" then
                        -- \left \lfloor etc.: the delimiter is a full command,
                        -- not one char — re-emit its symbol instead of eating
                        -- its first letter as literal text.
                        local cs2, ce2 = tex:find("\\[a-zA-Z]+", pos)
                        local d2 = cs2 == pos and tex:sub(pos + 1, ce2) or tex:sub(pos + 1, pos + 1)
                        local sym = ltx_sym[d2] or ltx_greek[d2]
                                    or ({ ["{"]="{", ["}"]="}", ["|"]="|", ["."]="" })[d2]
                        if sym ~= nil then
                            table.insert(out, sym)
                            pos = (cs2 == pos and ce2 or pos) + 1
                        else
                            pos = pos + 2
                        end
                    else
                        local m = { ["("]="(", [")"]=")", ["["]="[", ["]"]="]",
                                    ["{"]="{", ["}"]="}", ["|"]="|", ["."]="" }
                        table.insert(out, m[d] or "")
                        pos = pos + 1
                    end
                elseif cmd == "big" or cmd == "Big" or cmd == "bigg" or cmd == "Bigg"
                    or cmd == "bigl" or cmd == "bigr" or cmd == "Bigl" or cmd == "Bigr"
                    or cmd == "biggl" or cmd == "biggr" or cmd == "Biggl" or cmd == "Biggr" then
                    pos = ltxSkipSpaces(tex, pos)
                    local d = tex:sub(pos, pos)
                    if d == "\\" then
                        pos = pos + 2
                    else
                        if d ~= "" then table.insert(out, d) end
                        pos = pos + 1
                    end
                elseif ltx_sym[cmd] ~= nil then
                    table.insert(out, ltx_sym[cmd])
                    pos = ltxSkipSpaces(tex, pos)
                elseif ltx_greek[cmd] then
                    table.insert(out, ltx_greek[cmd])
                    pos = ltxSkipSpaces(tex, pos)
                else
                    table.insert(out, cmd)
                    pos = ltxSkipSpaces(tex, pos)
                end
            else
                local ch = tex:sub(pos + 1, pos + 1)
                local esc = { ["{"]="{", ["}"]="}", ["%"]="%", ["_"]="_", ["$"]="$",
                              ["#"]="#", ["&"]="&", ["|"]="|", ["("]="(", [")"]=")",
                              ["["]="[", ["]"]="]", ["/"]="/", [","]=" ", [";"]=" ",
                              [":"]="  ", ["!"]="", ["'"]="′", [" "]=" ", ["~"]=" ",
                              ["\\"]=" ; " }
                table.insert(out, esc[ch] or ch or "")
                if ch == "" then pos = pos + 1 end
                pos = pos + 2
            end
        elseif c == "^" then
            local next_c = tex:sub(pos + 1, pos + 1)
            if next_c == "{" then
                local inner, e = ltxConsumeGroup(tex, pos + 1)
                pos = e + 1
                table.insert(out, ltxSup(ltxToText(inner)))
            else
                pos = pos + 2
                table.insert(out, ltxSup(next_c))
            end
        elseif c == "_" then
            local next_c = tex:sub(pos + 1, pos + 1)
            if next_c == "{" then
                local inner, e = ltxConsumeGroup(tex, pos + 1)
                pos = e + 1
                table.insert(out, ltxSub(ltxToText(inner)))
            else
                pos = pos + 2
                table.insert(out, ltxSub(next_c))
            end
        elseif c == "&" then
            table.insert(out, " ")
            pos = pos + 1
        elseif c == "{" or c == "}" then
            pos = pos + 1
        else
            table.insert(out, c)
            pos = pos + 1
        end
    end
    return table.concat(out)
end

--[[-------------------------------------------------------------------------
Public API
--]]

local function wikireaderLatexToText(tex)
    tex = tex:gsub("^%s*{\\displaystyle%s*(.-)}$", "%1")
    tex = tex:gsub("^%s*{\\textstyle%s*(.-)}$", "%1")
    tex = tex:gsub("^%s*{\\scriptstyle%s*(.-)}$", "%1")
    tex = tex:gsub("^%s*{\\scriptscriptstyle%s*(.-)}$", "%1")
    tex = util.htmlEntitiesToUtf8(tex)
    tex = tex:gsub("%s+", " "):match("^%s*(.-)%s*$") or tex
    return ltxToText(tex)
end

local function mathBlockToText(math_html)
    local tex = math_html:match('<annotation[^>]*>%s*(.-)%s*</annotation>')
    if not tex then
        tex = math_html:match('alttext%s*=%s*"([^"]*)"')
        if tex then tex = util.htmlEntitiesToUtf8(tex) end
    end
    if not tex or tex == "" then return nil end
    return wikireaderLatexToText(tex)
end

-- Replace every <span class="mwe-math-element...">...</span> block (the
-- wrapper around every formula) with a readable text approximation of
-- the embedded LaTeX. Also handles any bare <math> tags as a fallback.
-- math_images (optional, ordered) collects fetched block-formula SVGs;
-- epub.lua stitches them in from its Archiver hooks.

-- Rendering as the real SVG preserves display layout (fractions, big
-- operators) that Unicode transcription flattens. Marker spans instead of
-- <img> because createEpub runs with with_images=false and strips every
-- img tag; only Archiver-injected files survive. The cap bounds network
-- fetches per article; overflow falls back to transcription.
local MATH_IMG_CAP = 60

local function blockSvgMarker(open_tag, block, math_images, seen)
    -- Only display math gets the SVG; inline formulas read fine as
    -- transcription and would need awkward sizing as images.
    if open_tag:find("mwe%-math%-element%-block", 1) == nil then return nil end
    local img_tag = block:match("<img[^>]-/math/render/svg/[^>]*>")
    if not img_tag then return nil end
    local src = img_tag:match('src%s*=%s*"([^"]*)"')
    local key = src and src:match('/math/render/svg/(.-)%s*$')
    if not key then return nil end
    local prior = seen[key]
    if prior ~= nil then
        if prior == 0 then return nil end -- earlier fetch failed
        return string.format('<span class="wikireader-mathimg" data-mathimgindex="%d"></span>', prior)
    end
    if #math_images >= MATH_IMG_CAP then
        if not seen.getWarned then
            seen.getWarned = true
            logger.warn("WikiReader: block-formula SVG cap of", MATH_IMG_CAP,
                "reached; remaining formulas fall back to Unicode transcription")
        end
        return nil
    end
    -- Parsoid emits both absolute ("https://wikimedia.org/...") and
    -- protocol-relative ("//upload.wikimedia.org/...") srcs; accept either.
    -- httpGetJSON is binary-safe via its table sink.
    local url = src:sub(1, 2) == "//" and "https:" .. src or src
    if src:sub(1, 8) ~= "https://" and src:sub(1, 2) ~= "//" then return nil end
    local ok, code, sink = wutil.httpGetJSON(url)
    local svg = ok and code == 200 and sink and table.concat(sink) or ""
    if svg == "" then
        seen[key] = 0
        return nil
    end
    local index = #math_images + 1
    math_images[index] = { svg = svg, style = img_tag:match('style%s*=%s*"([^"]*)"') or "" }
    seen[key] = index
    return string.format('<span class="wikireader-mathimg" data-mathimgindex="%d"></span>', index)
end

function M.replaceMathElements(html, math_images)
    local seen = math_images and {} or nil
    local out = {}
    local pos = 1
    local open_pat = '<span class="mwe%-math%-element[^>]*>'
    while true do
        local os_, oe = html:find(open_pat, pos)
        if not os_ then
            table.insert(out, html:sub(pos))
            break
        end
        local open_tag = html:sub(os_, oe)
        local _, ce = wutil.findMatchingClose(html, "span", oe)
        if not ce then
            table.insert(out, html:sub(pos))
            break
        end
        local block = html:sub(os_, ce)
        table.insert(out, html:sub(pos, os_ - 1))
        local marker = seen and blockSvgMarker(open_tag, block, math_images, seen) or nil
        if not marker then
            local text = mathBlockToText(block)
            if text then
                local is_block = open_tag:find("mwe%-math%-element%-block", 1) ~= nil
                local style = is_block
                    and 'display:block; text-align:center; margin:0.6em 0; font-style:italic;'
                    or  'white-space:nowrap; font-style:italic;'
                marker = string.format(
                    '<span class="wikireader-math" style="%s">%s</span>', style, text)
            end
        end
        if marker then
            table.insert(out, marker)
        end
        pos = ce + 1
    end
    local result = table.concat(out)
    -- Fallback: any bare <math>...</math> that wasn't inside a wrapper span
    result = result:gsub('<math[^>]*>.-</math>', function(math_block)
        local text = mathBlockToText(math_block)
        if text then
            return string.format('<span class="wikireader-math" style="font-style:italic;">%s</span>', text)
        end
        return ""
    end)
    return result
end

return M
