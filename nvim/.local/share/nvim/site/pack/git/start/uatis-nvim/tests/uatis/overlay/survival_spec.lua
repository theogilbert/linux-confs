-- Structural mode draws no before-image for code that merely moved: a red
-- copy of a line still on screen below reads as a much bigger change.
-- But "still on screen" has to mean the reader can SEE it unchanged
-- (`intact` / `moved_to`). Hand-built results throughout, so the hunk
-- shape is stated rather than hoped for.
local h = require("helpers")

describe("code that moved", function()
  local old = {
    "import pytest",
    "",
    "def test_area():",
    "    widget = Widget()",
    "    assert widget.area() == 6.0",
    "",
    "def test_normalise():",
    "    assert normalise(1.0) == 1.0",
  }
  local new = {
    "import pytest",
    "",
    "class TestWidget:",
    "    def test_area(self):",
    "        widget = Widget()",
    "        assert widget.area() == 6.0",
  }

  --- Spans covering every token of `rows`: a line difftastic calls new.
  local function cover(rows)
    return vim.tbl_map(function(row)
      return { line = row, col_start = 0, col_end = #new[row], kind = "add" }
    end, rows)
  end

  -- difftastic's own pairing: the old body against the class line, and
  -- the deleted test against the moved body. The rows the body moved
  -- into are painted added, so it is nowhere to be seen unchanged.
  it("is drawn where the rows it moved into are painted as added", function()
    h.expect(h.draw({ lang = "python", old = old, new = new, result = {
      hunks = {
        { start_a = 3, count_a = 3, start_b = 3, count_b = 1 },
        { start_a = 7, count_a = 2, start_b = 4, count_b = 3 },
      },
      spans = cover({ 3, 4, 5, 6 }),
    } }), [[
      | import pytest
      |
      - def test_area():
      -     widget = Widget()
      -     assert widget.area() == 6.0
      + class TestWidget:
      - ⟨def test_⟩normalise⟨():⟩
      -     assert normalise(1.0) == 1.0
      +     def test_area(self):
      +         widget = Widget()
      +         assert widget.area() == 6.0
    ]])
  end)

  it("reads as moved where the rows below are left alone", function()
    h.expect(h.draw({ lang = "python", old = old, new = new, result = {
      hunks = { { start_a = 3, count_a = 3, start_b = 3, count_b = 1 } },
      spans = cover({ 3 }),
    } }), [[
      | import pytest
      |
      + class TestWidget:
      |     def test_area(self):
      |         widget = Widget()
      |         assert widget.area() == 6.0
    ]])
  end)
end)

-- Asked of CHARACTERS, "still there" says yes to near-misses: `importos`
-- is a subsequence of `import json` + `import sys`. Read as a move, the
-- removal was drawn nowhere while the side window went on showing it.
-- (`content_survives` on tokens is in diff_spec.lua.)
describe("a line that looks like its neighbours", function()
  it("is drawn where it was", function()
    local old = { "import json", "import os", "import sys", "", "", "def run(a):", "    return a" }
    h.expect(h.draw({ lang = "python", old = old,
      new = { "import json", "import sys", "", "", "def run(a):", "    return a" },
      result = { hunks = { { start_a = 2, count_a = 1, start_b = 2, count_b = 0 } } },
    }), [[
      | import json
      | import sys
      - import os
      |
      |
      | def run(a):
      |     return a
    ]])
  end)
end)

-- Two deletions with nothing between them on the new side anchor on the
-- same row, and Neovim stacks one extmark each in no promised order --
-- swapped, they read as code having moved. A structural backend splits
-- a removed region into one hunk per top-level form, so this is routine.
describe("before-images", function()
  it("stay in old-file order", function()
    h.expect(h.draw({ lang = "python", new = { "def total(xs):", "    raise ValueError(message)" },
      old = {
        "def total(xs):",
        "    return sum(xs)",
        "",
        "def first_removed():",
        "    return 1",
        "",
        "def second_removed():",
        "    return 2",
      }, result = { hunks = {
        { start_a = 2, count_a = 1, start_b = 2, count_b = 1 },
        { start_a = 4, count_a = 2, start_b = 2, count_b = 0 },
        { start_a = 7, count_a = 2, start_b = 2, count_b = 0 },
      } } }), [[
        | def total(xs):
        -     return sum(xs)
        ~     raise ValueError(message)
        - def first_removed():
        -     return 1
        - def second_removed():
        -     return 2
      ]])
  end)
end)
