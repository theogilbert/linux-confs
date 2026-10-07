-- A formula as the characters it would be printed with.
--
-- GitLab draws `$$ \frac{a}{b} $$` with KaTeX, and a terminal has no
-- KaTeX: what it has is Unicode, which already holds most of what a
-- formula in a review is made of -- the Greek, the relations, the
-- arrows, a superscript two. So this is a substitution and not a
-- typesetter: `\alpha \le x^2` comes out `α ≤ x²`, a fraction comes out
-- on one line as `a/b`, a script with no Unicode form of its own stays
-- `x^(…)`. What it does not know -- an environment it has no rule for,
-- a command nobody taught it -- it leaves as it was written, which is
-- half-raw rather than wrong.
--
-- Pure, like `markdown.lua`: a string in, a string out.

local M = {}

-- stylua: ignore
local SYMBOLS = {
  -- Greek
  alpha = "α", beta = "β", gamma = "γ", delta = "δ", epsilon = "ϵ", varepsilon = "ε",
  zeta = "ζ", eta = "η", theta = "θ", vartheta = "ϑ", iota = "ι", kappa = "κ",
  lambda = "λ", mu = "μ", nu = "ν", xi = "ξ", pi = "π", varpi = "ϖ", rho = "ρ",
  varrho = "ϱ", sigma = "σ", varsigma = "ς", tau = "τ", upsilon = "υ", phi = "ϕ",
  varphi = "φ", chi = "χ", psi = "ψ", omega = "ω",
  Gamma = "Γ", Delta = "Δ", Theta = "Θ", Lambda = "Λ", Xi = "Ξ", Pi = "Π",
  Sigma = "Σ", Upsilon = "Υ", Phi = "Φ", Psi = "Ψ", Omega = "Ω",
  -- Operators and relations
  cdot = "·", times = "×", div = "÷", pm = "±", mp = "∓", ast = "∗", star = "⋆",
  circ = "∘", bullet = "∙", oplus = "⊕", otimes = "⊗",
  le = "≤", leq = "≤", ge = "≥", geq = "≥", ne = "≠", neq = "≠", ll = "≪", gg = "≫",
  approx = "≈", equiv = "≡", sim = "∼", simeq = "≃", cong = "≅", propto = "∝",
  ["in"] = "∈", notin = "∉", ni = "∋", subset = "⊂", subseteq = "⊆", supset = "⊃",
  supseteq = "⊇", cup = "∪", cap = "∩", setminus = "∖", emptyset = "∅", varnothing = "∅",
  forall = "∀", exists = "∃", nexists = "∄", neg = "¬", lnot = "¬", land = "∧",
  wedge = "∧", lor = "∨", vee = "∨", top = "⊤", bot = "⊥", perp = "⊥",
  parallel = "∥", mid = "∣", vdash = "⊢", models = "⊨",
  -- Big operators
  sum = "∑", prod = "∏", coprod = "∐", int = "∫", iint = "∬", iiint = "∭",
  oint = "∮", bigcup = "⋃", bigcap = "⋂",
  -- Arrows
  to = "→", rightarrow = "→", leftarrow = "←", gets = "←", leftrightarrow = "↔",
  Rightarrow = "⇒", Leftarrow = "⇐", Leftrightarrow = "⇔", iff = "⇔", implies = "⇒",
  mapsto = "↦", uparrow = "↑", downarrow = "↓", longrightarrow = "⟶",
  longleftarrow = "⟵", hookrightarrow = "↪",
  -- Everything else
  infty = "∞", partial = "∂", nabla = "∇", ell = "ℓ", hbar = "ℏ", Re = "ℜ", Im = "ℑ",
  aleph = "ℵ", angle = "∠", degree = "°", prime = "′", ldots = "…", dots = "…",
  cdots = "⋯", vdots = "⋮", ddots = "⋱", langle = "⟨", rangle = "⟩", lfloor = "⌊",
  rfloor = "⌋", lceil = "⌈", rceil = "⌉", lvert = "|", rvert = "|", vert = "|",
  Vert = "‖", lVert = "‖", rVert = "‖", therefore = "∴", because = "∵",
  -- Space: TeX's widths, as the nearest whole number of columns.
  quad = "  ", qquad = "    ", [","] = " ", [";"] = " ", [":"] = " ", ["!"] = "",
  [" "] = " ",
  -- Sizing, which a line of text has none of: `\left(` is a `(`.
  left = "", right = "", big = "", Big = "", bigg = "", Bigg = "", bigl = "", bigr = "",
  Bigl = "", Bigr = "", displaystyle = "", textstyle = "", limits = "", nolimits = "",
  -- Escapes
  ["{"] = "{", ["}"] = "}", ["%"] = "%", ["$"] = "$", ["&"] = "&", ["#"] = "#",
  ["_"] = "_",
}

-- Named functions are upright words in print, and a word is what they
-- are drawn as.
-- stylua: ignore
for _, name in ipairs({
  "sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan", "sinh",
  "cosh", "tanh", "log", "ln", "lg", "exp", "lim", "liminf", "limsup", "max", "min",
  "sup", "inf", "det", "dim", "ker", "gcd", "deg", "arg", "Pr", "mod", "bmod",
}) do
  SYMBOLS[name] = name
end

-- What only changes how its argument looks, which a terminal cannot:
-- the argument is drawn as it is.
-- stylua: ignore
local PLAIN = {
  text = true, textrm = true, textit = true, textbf = true, mathrm = true, mathit = true,
  mathbf = true, mathsf = true, mathtt = true, boldsymbol = true, operatorname = true,
  mbox = true, mathcal = true, mathfrak = true, mathscr = true,
}

-- An accent is a combining character after the letter it sits on.
-- stylua: ignore
local ACCENTS = {
  hat = "\204\130", widehat = "\204\130", bar = "\204\132", overline = "\204\133",
  vec = "\226\131\151", dot = "\204\135", ddot = "\204\136", tilde = "\204\131",
  widetilde = "\204\131",
}

-- stylua: ignore
local DOUBLE = {
  R = "ℝ", N = "ℕ", Z = "ℤ", Q = "ℚ", C = "ℂ", P = "ℙ", H = "ℍ", E = "𝔼", ["1"] = "𝟙",
}

-- stylua: ignore
local SUPER = {
  ["0"] = "⁰", ["1"] = "¹", ["2"] = "²", ["3"] = "³", ["4"] = "⁴", ["5"] = "⁵",
  ["6"] = "⁶", ["7"] = "⁷", ["8"] = "⁸", ["9"] = "⁹", ["+"] = "⁺", ["-"] = "⁻",
  ["="] = "⁼", ["("] = "⁽", [")"] = "⁾", a = "ᵃ", b = "ᵇ", c = "ᶜ", d = "ᵈ",
  e = "ᵉ", f = "ᶠ", g = "ᵍ", h = "ʰ", i = "ⁱ", j = "ʲ", k = "ᵏ", l = "ˡ", m = "ᵐ",
  n = "ⁿ", o = "ᵒ", p = "ᵖ", r = "ʳ", s = "ˢ", t = "ᵗ", u = "ᵘ", v = "ᵛ", w = "ʷ",
  x = "ˣ", y = "ʸ", z = "ᶻ", T = "ᵀ", ["′"] = "′", ["∗"] = "*", ["*"] = "*",
}

-- stylua: ignore
local SUB = {
  ["0"] = "₀", ["1"] = "₁", ["2"] = "₂", ["3"] = "₃", ["4"] = "₄", ["5"] = "₅",
  ["6"] = "₆", ["7"] = "₇", ["8"] = "₈", ["9"] = "₉", ["+"] = "₊", ["-"] = "₋",
  ["="] = "₌", ["("] = "₍", [")"] = "₎", a = "ₐ", e = "ₑ", h = "ₕ", i = "ᵢ", j = "ⱼ",
  k = "ₖ", l = "ₗ", m = "ₘ", n = "ₙ", o = "ₒ", p = "ₚ", r = "ᵣ", s = "ₛ", t = "ₜ",
  u = "ᵤ", v = "ᵥ", x = "ₓ",
}

--- `text` in the script `map` holds, or nil where any character of it
--- has no form there: `x^{n+1}` is `xⁿ⁺¹`, and `x^{\alpha}` is
--- `x^α` rather than a superscript that is half of one.
local function scripted(text, map)
  local out = {}
  for _, ch in ipairs(vim.fn.split(text, "\\zs")) do
    if ch ~= " " then
      if not map[ch] then
        return nil
      end
      table.insert(out, map[ch])
    end
  end
  return table.concat(out)
end

--- Whether `text` is one thing to a reader -- a letter, a number, a
--- symbol -- and not a sum that `/` or `^` would cut in half.
local function atom(text)
  if text:match("^%b()$") then
    return true
  end
  -- What is inside brackets is already held together: `n(n+1)` is one
  -- thing over two, and `n+1` is not.
  local flat = text:gsub("%b()", "x")
  return not flat:find("[%s%+%-=<>,/]") and not flat:find("[·×±∓≤≥≠≈→]")
end

local function wrapped(text)
  return atom(text) and text or ("(" .. text .. ")")
end

--- The parser: `s` read from `i`, until the end or the `}` that closes
--- the group it was called for. Returns what was read and where it
--- stopped.
local parse

--- One argument of a command: a group, a command, or one character.
local function argument(s, i)
  while s:sub(i, i) == " " do
    i = i + 1
  end
  local ch = s:sub(i, i)
  if ch == "{" then
    local inner, j = parse(s, i + 1, true)
    return inner, j
  end
  if ch == "\\" then
    local name = s:match("^%a+", i + 1) or s:sub(i + 1, i + 1)
    local inner = parse("\\" .. name, 1)
    return inner, i + 1 + #name
  end
  if ch == "" then
    return "", i
  end
  local len = vim.str_utf_end(s, i) + 1
  return s:sub(i, i + len - 1), i + len
end

--- An optional `[…]` argument, as `\sqrt[3]{x}` has.
local function optional(s, i)
  local from, to = s:find("^%s*%b[]", i)
  if not from then
    return nil, i
  end
  local inside = s:sub(from, to):match("%[(.*)%]")
  return parse(inside, 1), to + 1
end

parse = function(s, i, group)
  local out = {}
  while i <= #s do
    local ch = s:sub(i, i)
    if ch == "}" and group then
      return table.concat(out), i + 1
    elseif ch == "{" then
      local inner, j = parse(s, i + 1, true)
      table.insert(out, inner)
      i = j
    elseif ch == "^" or ch == "_" then
      local arg, j = argument(s, i + 1)
      local map = ch == "^" and SUPER or SUB
      local small = scripted(arg, map)
      -- Bracketed unless it is one character: `e^iπ` reads as `e^i`
      -- times π, and what was raised was both.
      if not small and vim.fn.strchars(arg) > 1 and not arg:match("^%b()$") then
        arg = "(" .. arg .. ")"
      end
      table.insert(out, small or (ch .. arg))
      i = j
    elseif ch == "&" then
      -- A column of an alignment. Not lined up -- that is the
      -- typesetter this is not -- but set apart by more than a space.
      table.insert(out, "\1")
      i = i + 1
    elseif ch == "~" then
      table.insert(out, " ")
      i = i + 1
    elseif ch == "\\" then
      local name = s:match("^%a+", i + 1)
      if not name then
        name = s:sub(i + 1, i + 1)
      end
      local j = i + 1 + #name
      if name == "\\" then
        -- A line break: the caller splits on it.
        table.insert(out, "\n")
      elseif name == "frac" or name == "dfrac" or name == "tfrac" then
        local top, k = argument(s, j)
        local bottom, l = argument(s, k)
        table.insert(out, wrapped(top) .. "/" .. wrapped(bottom))
        j = l
      elseif name == "binom" then
        local top, k = argument(s, j)
        local bottom, l = argument(s, k)
        table.insert(out, ("C(%s, %s)"):format(top, bottom))
        j = l
      elseif name == "sqrt" then
        local index, k = optional(s, j)
        local radicand, l = argument(s, k)
        local root = index and (scripted(index, SUPER) or index) or ""
        table.insert(out, root .. "√" .. wrapped(radicand))
        j = l
      elseif name == "mathbb" then
        local arg, k = argument(s, j)
        table.insert(out, (arg:gsub("[%w]", DOUBLE)))
        j = k
      elseif ACCENTS[name] then
        local arg, k = argument(s, j)
        table.insert(out, arg .. ACCENTS[name])
        j = k
      elseif PLAIN[name] then
        local arg, k = argument(s, j)
        table.insert(out, arg)
        j = k
      elseif name == "begin" or name == "end" then
        -- The environment's name goes with it, and an array's column
        -- spec; what is inside is read like anything else, its rows
        -- on lines of their own.
        local _, k = argument(s, j)
        if name == "begin" then
          _, k = optional(s, k)
        end
        j = k
      elseif SYMBOLS[name] then
        table.insert(out, SYMBOLS[name])
      else
        table.insert(out, "\\" .. name)
      end
      i = j
    else
      local len = vim.str_utf_end(s, i) + 1
      table.insert(out, s:sub(i, i + len - 1))
      i = i + len
    end
  end
  return table.concat(out), i
end

--- `src` as the lines it is drawn as: one for an inline formula, one
--- per `\\` row of a display one. Runs of space are one space -- TeX
--- ignores them, and what is left of them after the commands have
--- gone is the author's own spacing, which is what is wanted.
function M.lines(src)
  local drawn = parse(src, 1)
  local out = {}
  for _, line in ipairs(vim.split(drawn, "\n", { plain = true })) do
    line = vim.trim((line:gsub("%s+", " "):gsub("%s*\1%s*", "  ")))
    if line ~= "" then
      table.insert(out, line)
    end
  end
  return out
end

--- `src` on one line, for a formula in the middle of a sentence.
function M.render(src)
  return table.concat(M.lines(src), "  ")
end

return M
