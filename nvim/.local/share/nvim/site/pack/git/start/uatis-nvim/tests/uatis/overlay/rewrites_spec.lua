-- One changed line: when it is marked in parts and when it is one band
-- on each side, and that every removal gets a row of its own, above.
local h = require("helpers")

--- A one-line file pair under `local M = {}`, in line mode.
local function line(old, new, expected)
  h.drawn({ backend = "line", old = "local M = {}\n" .. old, new = "local M = {}\n" .. new }, expected)
end

describe("a rewritten line", function()
  -- Marking around the brackets, comma and `=` it kept left green round
  -- islands of punctuation, reading as "unchanged" -- true of the
  -- character, false of the line: nothing a reader could name came through.
  it("is added whole where only punctuation survived", function()
    line("x = handle(a, b)", "y = manage(c, d)", [[
      | local M = {}
      - x = handle(a, b)
      + y = manage(c, d)
    ]])
  end)

  -- The test is what survived, not how much: one name coming through is
  -- something the reader navigates by.
  it("is marked in parts where it kept a name", function()
    line("x = handle(a, b)", "x = manage(a, b)", [[
      | local M = {}
      - ⟨x = ⟩handle⟨(a, b)⟩
      | x = ⟦manage⟧(a, b)
    ]])
  end)

  it("keeps its marks having changed nearly end to end", function()
    line("  return compute_everything(x)", "  return recalculate_all_of_it(x)", [[
      | local M = {}
      - ⟨  return ⟩compute_everything⟨(x)⟩
      |   return ⟦recalculate_all_of_it⟧(x)
    ]])
  end)
end)

describe("every removal", function()
  -- Small removals were once folded into the line that replaced them,
  -- `_closed` drawn beside `_shutdown`. Then "removed" has two shapes on
  -- one screen, and which you get turns on a byte count the reader
  -- cannot see. One shape always: the row above.
  for _, case in ipairs({
    { "  self._closed = True", "  self._shutdown = True", [[
      | local M = {}
      - ⟨  self.⟩_closed⟨ = True⟩
      |   self.⟦_shutdown⟧ = True
    ]] },
    { "  return a - b", "  return b - a", [[
      | local M = {}
      - ⟨  return ⟩a - b
      |   return ⟦b - a⟧
    ]] },
    { "  call(a, b)", "  call(a)", [[
      | local M = {}
      - ⟨  call(a⟩, b⟨)⟩
      |   call(a)
    ]] },
    { "  local n = f(50_000)", "  local n = f(20_000)", [[
      | local M = {}
      - ⟨  local n = f(⟩5⟨0_000)⟩
      |   local n = f(⟦2⟧0_000)
    ]] },
    { "  send(alpha, bravo, buffer)", "  send(delta, gamma, buffer)", [[
      | local M = {}
      - ⟨  send(⟩alpha, bravo⟨, buffer)⟩
      |   send(⟦delta, gamma⟧, buffer)
    ]] },
    { "  return alpha - bravo", "  return omega - kilo", [[
      | local M = {}
      - ⟨  return ⟩alpha - bravo
      |   return ⟦omega - kilo⟧
    ]] },
    { "  x = 1", "  x = " .. string.rep("y", 40), [[
      | local M = {}
      -   x = 1
      +   x = yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy
    ]] },
  }) do
    it("gets a row of its own above `" .. vim.trim(case[2]) .. "`", function()
      line(case[1], case[2], case[3])
    end)
  end
end)

describe("a sub-token swap", function()
  -- The old row and the new line are two halves of one reading and must
  -- agree on which characters are the edit: the row marked the `5` and
  -- the `6` while the line under it marked all of `20_000`.
  it("marks the same digits on both sides", function()
    if not h.difft then
      return pending("difftastic is not installed")
    end
    h.drawn({ lang = "python",
      old = "def f():\n    n = g(50_000, 60_000)\n    return n",
      new = "def f():\n    n = g(20_000, 30_000)\n    return n",
    }, [[
      | def f():
      - ⟨    n = g(⟩5⟨0_000, ⟩6⟨0_000)⟩
      |     n = g(⟦2⟧0_000, ⟦3⟧0_000)
      |     return n
    ]])
  end)
end)
