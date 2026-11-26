-- Highlight at the granularity the backend actually knows: full-width
-- bands for vim.diff, which only knows lines; individual tokens for
-- difftastic, which knows them. Pictures are explained in helpers.lua.
local h = require("helpers")
local overlay = require("uatis.overlay")

local one_old = "local M = {}\nfunction M.run(a, b)\n  return a + b\nend"
local one_new = "local M = {}\nfunction M.run(a, b)\n  return a * b\nend"

describe("granularity", function()
  -- A row carrying a mark already carries a colour, so a bare space
  -- between two marks is the other half of the comparison showing
  -- through, and the row comes out striped. Asserted on `paint_row`
  -- itself: which backend hands it two ranges a space apart is not the
  -- point.
  it("joins two marks laid over a row with only a space between them", function()
    local buf = h.scratch({ "the widget holds a value", "" })
    overlay.paint_row(buf, overlay.ns, 0, "UatisAddDim",
      { { col_start = 4, col_end = 10 }, { col_start = 11, col_end = 16 } },
      "the widget holds a value", 2, "UatisAdd")
    h.expect(h.picture(buf), [[
      ~ the ⟦widget holds⟧ a value
      |
    ]])
  end)

  -- Drawn in line mode, where the rows of a 1:1 hunk pair by position.
  it("marks the columns a row was pulled right by, then its edit", function()
    h.drawn({ backend = "line", lang = "python", old = [[
      def f():
          log(query)
          resp = q(query=query)
          return resp
    ]], new = [[
      def f():
          log(effective)
              resp = q(query=effective)
          return resp
    ]] }, [[
      | def f():
      - ⟨    log(⟩query⟨)⟩
      - ⟨    resp = q(query=⟩query⟨)⟩
      |     log(⟦effective⟧)
      |     ⟦    ⟧resp = q(query=⟦effective⟧)
      |     return resp
    ]])
  end)

  -- A 1:1 line pair is compared directly whichever backend produced the
  -- hunk; the backends only differ where lines do not pair up.
  it("marks a paired line by its changed character in line mode too", function()
    h.drawn({ backend = "line", old = one_old, new = one_new }, [[
      | local M = {}
      | function M.run(a, b)
      - ⟨  return a ⟩+⟨ b⟩
      |   return a ⟦*⟧ b
      | end
    ]])
  end)

  -- The line backend has no prose atom to refine, so it marks the words.
  it("marks the new words of a docstring in line mode", function()
    h.drawn({ backend = "line", lang = "python", old = [[
      class C:
          """Bundles a driver and concurrency semaphore for one connection."""
          pass
    ]], new = [[
      class C:
          """Bundles a driver and concurrency updated semaphores for one connection."""
          pass
    ]] }, [[
      | class C:
      - ⟨    """Bundles a driver and concurrency semaphore for one connection."""⟩
      |     """Bundles a driver and concurrency ⟦updated ⟧semaphore⟦s⟧ for one connection."""
      |     pass
    ]])
  end)
end)

describe("granularity, structurally", function()
  if not h.difft then
    pending("difftastic is not installed")
    return
  end

  -- vim.diff calls a body wrapped in `if` two lines deleted and four
  -- added; difftastic knows it is the same code one level in. The body
  -- is not banded -- it moved -- and what DID change about it, where it
  -- starts, is marked and nothing else.
  it("bands what a wrapping added and marks only the indent it pushed", function()
    h.drawn({ old = [[
      local M = {}
      function M.run(a)
        local t = a * 2
        return t
      end
      return M
    ]], new = [[
      local M = {}
      function M.run(a)
        if a then
          local t = a * 2
          return t
        end
      end
      return M
    ]] }, [[
      | local M = {}
      | function M.run(a)
      +   if a then
      |   ⟦  ⟧local t = a * 2
      |   ⟦  ⟧return t
      +   end
      | end
      | return M
    ]])
  end)

  it("tints the one token that changed, with no band", function()
    h.drawn({ old = one_old, new = one_new }, [[
      | local M = {}
      | function M.run(a, b)
      - ⟨  return a ⟩+⟨ b⟩
      |   return a ⟦*⟧ b
      | end
    ]])
  end)

  -- difftastic reports the comma and the argument as two ranges and says
  -- nothing about the space; it colours foregrounds, where that costs
  -- nothing. Backgrounds with a gap are the most deliberate-looking
  -- thing on the row.
  it("tints an added argument as one run, the space inside included", function()
    h.drawn({
      old = "local M = {}\nfunction M.run(a)\n  return f(a)\nend",
      new = "local M = {}\nfunction M.run(a)\n  return f(a, opts.pad)\nend",
    }, [[
      | local M = {}
      | function M.run(a)
      |   return f(a⟦, opts.pad⟧)
      | end
    ]])
  end)

  -- Past `emphasis_ratio` of an atom the step-back is not offered: what
  -- is left is whatever the old block happened to contain, like an
  -- `install` greyed in a new sentence because the old one was a pip
  -- command.
  it("bands a rewritten paragraph whole, with nothing stepped back", function()
    h.drawn({ lang = "markdown",
      old = "# grannos\n\n## Install\n\npip install grannos-py from the package index\n",
      new = "# grannos\n\n## Install\n\n`grannos` is a command-line server, so install it as a tool\n",
    }, [[
      | # grannos
      |
      | ## Install
      |
      - pip install grannos-py from the package index
      + `grannos` is a command-line server, so install it as a tool
    ]])
  end)

  -- difftastic's JSON reports every word of a changed docstring as
  -- changed; the emphasis is worked out here and drawn as its inverse.
  -- The atom is the whole row, so the whole row steps back, quotes and
  -- indentation with it, rather than a stripe of quieter words.
  it("steps a docstring back whole and lights only its new words", function()
    h.drawn({ lang = "python", old = [[
      class C:
          """Bundles a driver and concurrency semaphore for one connection."""
          pass
    ]], new = [[
      class C:
          """Bundles a driver and concurrency updated semaphores for one connection."""
          pass
    ]] }, [[
      | class C:
      - ⟨    """Bundles a driver and concurrency semaphore for one connection."""⟩
      ~     """Bundles a driver and concurrency ⟦updated ⟧semaphore⟦s⟧ for one connection."""
      |     pass
    ]])
  end)

  -- Not prose end to end, so stepping the row back would step back the
  -- renamed variable beside the string too, a change of its own.
  it("steps back inside a string alone where the row holds code too", function()
    h.drawn({
      old = 'local M = {}\nlocal msg = "the quick brown fox"\nreturn M',
      new = 'local M = {}\nlocal note = "the quick brown lazy fox"\nreturn M',
    }, [[
      | local M = {}
      - ⟨local ⟩msg⟨ = "the quick brown fox"⟩
      | local ⟦note = ⟧⟨"the quick brown ⟩⟦lazy ⟧⟨fox"⟩
      | return M
    ]])
  end)

  -- difftastic has no parser for it (or it does not parse halfway
  -- through an edit), and says so: every word of the line is a change.
  -- Read as tokens that is a band and nothing else.
  it("steps a changed line of prose back whole, lighting the added word", function()
    h.drawn({ lang = "text",
      old = "INTRO\n\nThis plugin annotates the buffer you are editing.\nIt shows no patch.",
      new = "INTRO\n\nThis plugin annotates the buffer you are already editing.\nIt shows no patch.",
    }, [[
      | INTRO
      |
      ~ This plugin annotates the buffer you are ⟦already ⟧editing.
      | It shows no patch.
    ]])
  end)

  -- The emphasis is a block comparison and the block holds an old
  -- closing `"""`, so the quotes that arrived were found there and
  -- nothing was lit. difftastic paired the new row with the old opening
  -- row; measured against that, the `"""` is what is new.
  it("lights the closing quotes a docstring folded onto one row gained", function()
    h.drawn({ lang = "python", old = [[
      class T:
          def test_scale(self):
              """A test about scale widget.

              Args:
                  self: own class.
              """
              widget = Widget(2.0)
              scaled = scale_widget(widget, 2.0)
              assert scaled.width == 4.0
    ]], new = [[
      class T:
          def test_scale(self):
              """A test about scale widget."""
              assert scaled.width == 4.0
    ]] }, [[
      | class T:
      |     def test_scale(self):
      - ⟨        """A test about scale widget.⟩
      -
      -         Args:
      -             self: own class.
      -         """
      ~         """A test about scale widget.⟦"""⟧
      -         widget = Widget(2.0)
      -         scaled = scale_widget(widget, 2.0)
      |         assert scaled.width == 4.0
    ]])
  end)
end)
