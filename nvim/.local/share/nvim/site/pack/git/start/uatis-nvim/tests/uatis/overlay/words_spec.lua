-- Whether a replaced word is taken apart character by character
-- (`worth_char_diff`: `word_similarity`, `word_affix`). Each case is drawn
-- in both backends, the line under test between `local M = {}` and
-- `return M` -- with a trailing newline, so the file's last row is not
-- reported changed.
local h = require("helpers")

local function drawn(backend, old, new, expected)
  if backend == "struct" and not h.difft then
    return pending("difftastic is not installed")
  end
  h.drawn({ backend = backend,
    old = "local M = {}\n" .. old .. "\nreturn M\n",
    new = "local M = {}\n" .. new .. "\nreturn M\n" }, expected)
end

-- `and` -> `ad` shares too little at either end for the affix test, and
-- was marked as one word becoming another, though every character of
-- `ad` is the old word's own. One side having no marks is what makes the
-- character diff honest: no fragments of two words to be misled by.
-- (Structurally the row is still tinted quietly, as the answer to the
-- red row above.)
describe("a word that only lost a letter", function()
  for _, case in ipairs({ { "line", [[
    | local M = {}
    - ⟨  if enabled a⟩n⟨d ready then⟩
    |   if enabled ad ready then
    | return M
  ]] }, { "struct", [[
    | local M = {}
    - ⟨  if enabled a⟩n⟨d ready then⟩
    ~   if enabled ad ready then
    | return M
  ]] } }) do
    it("has the letter picked out, and nothing marked new, in " .. case[1] .. " mode", function()
      drawn(case[1], "  if enabled and ready then", "  if enabled ad ready then", case[2])
    end)
  end
end)

-- Nothing was taken out, so nothing inside the row above is drawn gone:
-- drawn red, it said the whole line went while the row under it said one
-- letter arrived, and the old window stepped it back.
describe("a word that gained a letter", function()
  for _, case in ipairs({ { "line", [[
    | local M = {}
    - ⟨  if enabled and ready then⟩
    |   if enabled ⟦l⟧and ready then
    | return M
  ]] }, { "struct", [[
    | local M = {}
    - ⟨  if enabled and ready then⟩
    ~   if enabled ⟦l⟧and ready then
    | return M
  ]] } }) do
    it("marks the letter, the old line stepped back whole, in " .. case[1] .. " mode", function()
      drawn(case[1], "  if enabled and ready then", "  if enabled land ready then", case[2])
    end)
  end
end)

-- Character marks between words that merely share letters land on
-- whichever they have in common and point at nothing.
describe("a word unrelated to the one it replaced", function()
  for _, case in ipairs({ { "line", [[
    | local M = {}
    - ⟨  local ⟩closer⟨ = 1⟩
    |   local ⟦whose⟧ = 1
    | return M
  ]] }, { "struct", [[
    | local M = {}
    - ⟨  local ⟩closer⟨ = 1⟩
    |   local ⟦whose⟧ = 1
    | return M
  ]] } }) do
    it("is marked whole on both sides, in " .. case[1] .. " mode", function()
      drawn(case[1], "  local closer = 1", "  local whose = 1", case[2])
    end)
  end
end)

-- A shared suffix says the character diff is worth drawing; it says
-- nothing about the part in FRONT of the stem, which came out as `a` and
-- `sed` marked inside `parsed`.
describe("a word replaced in front of a shared stem", function()
  for _, case in ipairs({ { "line", [[
    | local M = {}
    - ⟨  local ⟩report⟨_flags = 1⟩
    |   local ⟦parsed⟧_flags = 1
    | return M
  ]] }, { "struct", [[
    | local M = {}
    - ⟨  local ⟩report⟨_flags = 1⟩
    |   local ⟦parsed⟧_flags = 1
    | return M
  ]] } }) do
    it("is one mark, in " .. case[1] .. " mode", function()
      drawn(case[1], "  local report_flags = 1", "  local parsed_flags = 1", case[2])
    end)
  end
end)

-- difftastic reports ATOMS, and a number is one however many digits
-- changed: `50_000` -> `20_000` came back as the whole `20_000` added,
-- reading as though `5` had been replaced by `20_000`.
local function number(backend, old, new, expected)
  if backend == "struct" and not h.difft then
    return pending("difftastic is not installed")
  end
  h.drawn({ backend = backend, lang = "python",
    old = "def f():\n" .. old .. "\n    return 1\n",
    new = "def f():\n" .. new .. "\n    return 1\n" }, expected)
end

describe("a digit of a number", function()
  for _, case in ipairs({ { "line", [[
    | def f():
    - ⟨    limit = ⟩5⟨0_000⟩
    |     limit = ⟦2⟧0_000
    |     return 1
  ]] }, { "struct", [[
    | def f():
    - ⟨    limit = ⟩5⟨0_000⟩
    |     limit = ⟦2⟧0_000
    |     return 1
  ]] } }) do
    it("is marked alone, in " .. case[1] .. " mode", function()
      number(case[1], "    limit = 50_000", "    limit = 20_000", case[2])
    end)
  end
end)

describe("a number really replaced", function()
  for _, case in ipairs({ { "line", [[
    | def f():
    - ⟨    limit = ⟩50_000
    |     limit = ⟦71⟧
    |     return 1
  ]] }, { "struct", [[
    | def f():
    - ⟨    limit = ⟩50_000
    |     limit = ⟦71⟧
    |     return 1
  ]] } }) do
    it("is marked whole, in " .. case[1] .. " mode", function()
      number(case[1], "    limit = 50_000", "    limit = 71", case[2])
    end)
  end
end)

-- The prose treatment it is meant to have: tinted whole, what did not
-- change stepped back rather than narrowed away.
describe("a changed string", function()
  it("is tinted whole with the rest stepped back", function()
    number("struct", "    name = 'alpha'", "    name = 'alpha2'", [[
      | def f():
      - ⟨    name = ⟩'alpha'
      |     name = ⟨'alpha⟩⟦2⟧⟨'⟩
      |     return 1
    ]])
  end)
end)
