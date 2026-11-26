-- Marks inside a line say "these characters changed and the rest did
-- not", which needs a line for "the rest" to have come through from.
-- Moving `def test_area():` into a class is a six-into-three replacement
-- in which difftastic marks `test_area` and `self` on the new line: drawn
-- as marks that says `def`, the brackets and the colon came through
-- unchanged, from a line nowhere on screen.
--
-- Hand-built results, so each test states the hunk shape it is about and
-- runs without difftastic.
local h = require("helpers")
local overlay = require("uatis.overlay")

local old = {
  "import pytest",
  "",
  "def test_area():",
  "    widget = Widget()",
  "",
  "",
  "def test_other():",
  "    pass",
}
local new = {
  "import pytest",
  "",
  "class TestWidget:",
  "    def test_area(self):",
  "        widget = Widget()",
}

local function draw(result)
  return h.draw({ old = old, new = new, lang = "python", result = result })
end

describe("a token mark", function()
  local six_into_three = {
    { start_a = 3, count_a = 1, start_b = 3, count_b = 1 },
    { start_a = 4, count_a = 4, start_b = 4, count_b = 2 },
  }
  local two_tokens = {
    { line = 4, col_start = 8, col_end = 17, kind = "add" },
    { line = 4, col_start = 18, col_end = 22, kind = "add" },
  }

  it("is dropped for a line in a hunk whose sides do not pair up", function()
    h.expect(draw({ hunks = six_into_three, spans = two_tokens }), [[
      | import pytest
      |
      - def test_area():
      ~ class TestWidget:
      -     widget = Widget()
      -
      -
      - def test_other():
      +     def test_area(self):
      |         widget = Widget()
    ]])
  end)

  it("is kept in a hunk that does pair up", function()
    h.expect(draw({
      hunks = { { start_a = 3, count_a = 2, start_b = 3, count_b = 2 } },
      spans = { { line = 4, col_start = 18, col_end = 22, kind = "add" } },
    }), [[
      | import pytest
      |
      | class TestWidget:
      |     def test_area(⟦self⟧):
      |         widget = Widget()
    ]])
  end)

  -- difftastic aligns row by row and paired these anyway; taking its word
  -- restores the precision it reported, and its `anchor` puts the row it
  -- named directly above, so the mark can be checked. The lone `(`
  -- between the two tokens is covered.
  it("is kept where the backend paired the row, whatever the counts say", function()
    h.expect(draw({
      hunks = six_into_three,
      spans = two_tokens,
      pairs = { [3] = 3, [4] = 4, [5] = 5 },
      anchor = { [3] = 3, [4] = 4, [5] = 5, [6] = nil },
    }), [[
      | import pytest
      |
      - def test_area():
      ~ class TestWidget:
      -     widget = Widget()
      -
      -
      - def test_other():
      |     def ⟦test_area(self⟧):
      |         widget = Widget()
    ]])
  end)
end)

describe("joined", function()
  local function runs(text, a, b, c, d)
    return #overlay.joined({ { col_start = a, col_end = b }, { col_start = c, col_end = d } }, text)
  end

  -- A single punctuation mark is not a correspondence worth drawing.
  it("covers a lone dot between two marks", function()
    assert.are.equal(1, runs("local at = uatis.showing(bufnr)", 0, 16, 17, 31))
  end)

  it("does not cover two characters of punctuation", function()
    assert.are.equal(2, runs("x = a .. b", 0, 5, 9, 10))
  end)

  it("does not cover a word", function()
    assert.are.equal(2, runs("f(a, b)", 0, 2, 5, 6))
  end)
end)

-- Hoisting `"|".join(col.types)` into a variable leaves difftastic
-- nothing to mark on the new side: the surviving `types` matches the one
-- in `col.types`, so it calls the row unchanged and reports the edit as
-- removals from the left. Nothing is invented for that row. The old line
-- goes above the row difftastic paired it with, and the row is tinted
-- quietly: a red row over an unmarked line reads as a deletion, and the
-- quiet tint says what is true -- this is what the row above became.
describe("a changed line the backend reports nothing added on", function()
  it("is the answer to the row above it, tinted quietly", function()
    local new_lines = {
      "def render(cols):",
      "    for col in cols:",
      '        types = "|".join(col.types)',
      "        rows.append((col.name, types))",
      "    return rows",
    }
    h.expect(h.draw({ lang = "python", exact = true, new = new_lines, old = {
      "def render(cols):",
      "    for col in cols:",
      '        rows.append((col.name, "|".join(col.types)))',
      "    return rows",
    }, result = {
      -- One old row replaced by two, paired with the SECOND of them: the
      -- shape the counts alone cannot give. Spans as difftastic reports
      -- them, nothing against the row the tokens came out of.
      hunks = { { start_a = 3, count_a = 1, start_b = 3, count_b = 2 } },
      spans = {
        { line = 3, col_start = 8, col_end = #new_lines[3], kind = "add" },
        { line = 3, col_start = 31, col_end = 44, kind = "delete" },
        { line = 3, col_start = 49, col_end = 50, kind = "delete" },
      },
      pairs = { [4] = 3 },
      anchor = { [3] = 4 },
    } }), [[
      | def render(cols):
      |     for col in cols:
      +         types = "|".join(col.types)
      - ⟨        rows.append((col.name, ⟩"|".join(col.⟨types⟩)⟨))⟩
      ~         rows.append((col.name, types))
      |     return rows
    ]])
  end)
end)
