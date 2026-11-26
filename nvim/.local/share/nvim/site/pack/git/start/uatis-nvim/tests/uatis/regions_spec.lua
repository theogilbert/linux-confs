-- `regions.lua`: a file difftastic will not take whole, read in pieces.
--
-- difftastic bounds its own work and past the bound compares words --
-- on exactly the file a reviewer most wanted read as code, the one
-- mostly rewritten. The class alone is under the bound; the file it
-- sits in is not. So the file is cut where tree-sitter says one
-- top-level thing ends and the next begins, each piece is asked about
-- on its own, and the answers are sewn back together on the rows the
-- line diff already matched.
local h = require("helpers")
local regions = require("uatis.regions")
local config = require("uatis.config")

-- Units are 0-based row ranges of the top-level nodes; hunks are the
-- line diff's, 1-based.
local units_a = { { first = 0, last = 0 }, { first = 3, last = 5 }, { first = 8, last = 15 } }
local units_b = { { first = 0, last = 0 }, { first = 1, last = 1 }, { first = 4, last = 8 },
  { first = 11, last = 18 } }

local function hunk(start_a, count_a, start_b, count_b)
  return { start_a = start_a, count_a = count_a, start_b = start_b, count_b = count_b }
end

local function piece(lo_a, hi_a, lo_b, hi_b)
  return { lo_a = lo_a, hi_a = hi_a, lo_b = lo_b, hi_b = hi_b }
end

describe("regions.pieces", function()
  it("cuts three hunks in three units into three pieces, each widened to its unit", function()
    assert.are.same({
      piece(1, 0, 1, 1),   -- an insertion: nothing on the old side
      piece(3, 5, 4, 8),   -- inside alpha: the function, on both sides alike
      piece(8, 15, 11, 18), -- inside beta
    }, regions.pieces({
      hunk(1, 0, 2, 1),   -- `import sys` added
      hunk(5, 1, 6, 3),   -- inside alpha
      hunk(15, 1, 18, 1), -- inside beta
    }, units_a, units_b, 16, 19))
  end)

  -- Widening that runs into the piece above folds the two together.
  it("makes two hunks in one function one piece", function()
    assert.are.same({ piece(3, 5, 4, 8) },
      regions.pieces({ hunk(4, 1, 5, 1), hunk(6, 1, 7, 3) }, units_a, units_b, 16, 19))
  end)

  -- Where a unit on one side takes in rows the line diff matched to rows
  -- OUTSIDE the unit on the other, the other side takes those in too:
  -- the rows between two pieces are sewn as pairs, so they had better be
  -- pairs.
  it("keeps a piece in step with the matching on both sides", function()
    local short_b = { { first = 0, last = 0 }, { first = 1, last = 1 }, { first = 4, last = 6 } }
    assert.are.same({ piece(3, 5, 4, 6) },
      regions.pieces({ hunk(4, 1, 5, 1) }, units_a, short_b, 16, 19))
  end)
end)

-- Pieces' rows offset to the file's, and the rows between pieces paired
-- as the unchanged rows they are.
describe("regions.stitch", function()
  local sewn = regions.stitch({
    piece(1, 0, 1, 1),
    { lo_a = 3, hi_a = 3, lo_b = 4, hi_b = 4, data = {
      aligned_lines = { { 0, 0 } },
      chunks = { { { lhs = { line_number = 0, changes = { { start = 0, ["end"] = 1 } } },
        rhs = { line_number = 0, changes = { { start = 0, ["end"] = 1 } } } } } },
    } },
  }, { "a", "b", "c", "d", "e" }, { "a", "X", "b", "c", "D", "e" })

  it("aligns every row of the file, the gaps as pairs", function()
    assert.are.same({ { 0, 0 }, { nil, 1 }, { 1, 2 }, { 2, 3 }, { 3, 4 }, { 4, 5 } }, sewn.aligned_lines)
  end)

  it("reports an inserted row whole, at its row", function()
    assert.are.equal(2, #sewn.chunks)
    assert.are.equal(1, sewn.chunks[1][1].rhs.line_number)
  end)

  it("moves a piece's rows to where the piece sits", function()
    assert.are.same({ 3, 4 }, { sewn.chunks[2][1].lhs.line_number, sewn.chunks[2][1].rhs.line_number })
  end)
end)

-- Live, with difftastic's bound pulled down to where a small file trips
-- it whole and one of its functions does not.
describe("a file past difftastic's bound", function()
  if not (h.difft and require("uatis.syntax").lang_of("python")) then
    pending("difftastic or the python parser is not installed")
    return
  end

  local got
  local new = h.source([[
    import os
    import sys


    def alpha(a, b, c):
        total = a + b + c
        if total < 0:
            raise ValueError(total)
        return total


    def beta(x):
        """Beta does a thing.

        Notes at column zero
        """
        if x:
            return x * 3
        return 0


    def gamma():
        return 1
  ]])

  it("is read in three pieces, as code", function()
    config.diff.struct.graph_limit = 700
    got = h.compute({ lang = "python", path = "pieces_probe.py", old = [[
      import os


      def alpha(a, b):
          total = a + b
          return total


      def beta(x):
          """Beta does a thing.

          Notes at column zero
          """
          if x:
              return x * 2
          return 0


      def gamma():
          return 1
    ]], new = new })
    config.diff.struct.graph_limit = nil
    assert.are.equal(3, got.pieces)
    assert.is_falsy(got.prose)
    assert.is_falsy(got.fallback)
  end)

  it("reads beta's change as one token of Python", function()
    local on_beta = {}
    for _, sp in ipairs(got.spans) do
      if sp.kind == "add" and sp.line == 18 then
        table.insert(on_beta, new[18]:sub(sp.col_start + 1, sp.col_end))
      end
    end
    assert.are.same({ "3" }, on_beta)
  end)

  it("puts the hunks where the file changed", function()
    assert.are.same({ "2+1", "5+4", "18+1" },
      vim.tbl_map(function(k) return k.start_b .. "+" .. k.count_b end, got.hunks))
  end)
end)
