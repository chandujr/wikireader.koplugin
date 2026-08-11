-- LaTeX-to-readable-text conversion for WikiReader.
-- Wikipedia renders formulas as hidden MathML + visible <img>. With images
-- disabled, formulas vanish. This module extracts the raw LaTeX source from
-- <math> blocks and converts it to a best-effort Unicode transcription.

local wutil = require("wikiutil")
local util = require("util")

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
    mid="|", parallel="∥",
    leq="≤", le="≤", geq="≥", ge="≥", neq="≠", ne="≠",
    approx="≈", sim="∼", simeq="≃", cong="≅", equiv="≡",
    propto="∝", ldots="…", dots="…", cdots="⋯", vdots="⋮", ddots="⋱",
    int="∫", iint="∬", iiint="∭", oint="∮",
    sum="∑", prod="∏", coprod="∐",
    prime="′", ell="ℓ",
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
                        table.insert(out, inner)
                    end
                elseif cmd == "operatorname" then
                    pos = ltxSkipSpaces(tex, pos)
                    if tex:sub(pos, pos) == "{" then
                        local e, inner
                        inner, e = ltxConsumeGroup(tex, pos)
                        pos = e + 1
                        table.insert(out, inner)
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
                        table.insert(out, inner)
                    end
                elseif cmd == "vec" or cmd == "hat" or cmd == "dot"
                    or cmd == "ddot" or cmd == "tilde" then
                    pos = ltxSkipSpaces(tex, pos)
                    if tex:sub(pos, pos) == "{" then
                        local e, inner
                        inner, e = ltxConsumeGroup(tex, pos)
                        pos = e + 1
                        table.insert(out, inner)
                    end
                elseif cmd == "left" or cmd == "right" then
                    pos = ltxSkipSpaces(tex, pos)
                    local d = tex:sub(pos, pos)
                    if d == "\\" then
                        local d2 = tex:sub(pos + 1, pos + 1)
                        local mm = { ["{"]="{", ["}"]="}", ["|"]="|", ["."]="" }
                        if mm[d2] ~= nil then table.insert(out, mm[d2]) end
                        pos = pos + 2
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
                              ["\\"]="" }
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
function M.replaceMathElements(html)
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
        local cs, ce = wutil.findMatchingClose(html, "span", oe)
        if not ce then
            table.insert(out, html:sub(pos))
            break
        end
        local block = html:sub(os_, ce)
        table.insert(out, html:sub(pos, os_ - 1))
        local text = mathBlockToText(block)
        if text then
            local is_block = open_tag:find("mwe%-math%-element%-block", 1) ~= nil
            local style = is_block
                and 'display:block; text-align:center; margin:0.6em 0; font-style:italic;'
                or  'white-space:nowrap; font-style:italic;'
            table.insert(out, string.format(
                '<span class="wikireader-math" style="%s">%s</span>', style, text))
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
