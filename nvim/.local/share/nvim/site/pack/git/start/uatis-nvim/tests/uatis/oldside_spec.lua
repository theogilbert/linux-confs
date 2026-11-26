-- The side-by-side left window: a real, read-only buffer of the old
-- revision. Pictures of it come from `h.draw_old` (see helpers.lua).
local h = require("helpers")

describe("the old window steps back too", function()
  if not h.difft then
    pending("difftastic is not installed")
    return
  end

  -- A reworded docstring reports every word of itself changed on BOTH
  -- sides, so the old window answered a two-word edit with a solid red
  -- block -- the very thing the new side stopped doing.

  -- Nothing was taken out of the old sentence, so none of it is a
  -- removal. The row-by-row rule read no removal as "all of it went".
  it("steps back a docstring that only gained words, with nothing red", function()
    h.expect(h.draw_old({
      old = 'class C:\n    """Bundles a driver and a semaphore."""\n    pass',
      new = 'class C:\n    """Bundles a driver and a fresh semaphore."""\n    pass',
    }), [[
      | class C:
      ~     """Bundles a driver and a semaphore."""
      |     pass
    ]])
  end)

  it("keeps the words a docstring lost red, the sentence stepped back", function()
    h.expect(h.draw_old({
      old = 'class C:\n    """Bundles a driver and concurrency semaphore for one connection."""\n    pass',
      new = 'class C:\n    """Bundles a driver and one connection."""\n    pass',
    }), [[
      | class C:
      ~     """Bundles a driver and ⟦concurrency semaphore for ⟧one connection."""
      |     pass
    ]])
  end)

  -- The atom is the NODE, so every row of the docstring comes back
  -- reported as removed when one was reworded. It is the same edit the
  -- new side draws, in the other layout, and has to read the same way.
  it("leaves the rows of a docstring that did not change alone", function()
    local old = [[
      def f(t):
          """Drop a modifier.

          The diagram is a structural overview.
          It widens every box that carries one.
          """
          return t
    ]]
    h.expect(h.draw_old({ old = old, new = (old:gsub("carries one", "carries two")) }), [[
      | def f(t):
      |     """Drop a modifier.
      |
      |     The diagram is a structural overview.
      ~     It widens every box that carries ⟦one⟧.
      |     """
      |     return t
    ]])
  end)

  it("keeps a docstring that was simply deleted red end to end", function()
    h.expect(h.draw_old({
      old = 'def f():\n    """The old sentence."""\n    return 1',
      new = "def f():\n    return 1",
    }), [[
      | def f():
      -     """The old sentence."""
      |     return 1
    ]])
  end)

  -- difftastic covers the paragraph break with an empty span. That once
  -- fell through every branch and left the one unmarked row of the old
  -- window the blank line in the middle of the change; it is unmarked
  -- now because it is the same blank line it always was.
  it("marks only the row of a docstring that grew, its blank line included", function()
    h.expect(h.draw_old({ old = [[
      def f():
          """Draw it.

          Raises:
              DiagramError: If path does not resolve.
          """
          return 1
    ]], new = [[
      def f():
          """Draw it.

          Raises:
              DiagramError: If path does not resolve to a table, or if no
                  spacing lets every relationship be drawn.
          """
          return 1
    ]] }), [[
      | def f():
      |     """Draw it.
      |
      |     Raises:
      ~         DiagramError: If path does not resolve.
      |     """
      |     return 1
    ]])
  end)
end)

-- The side window stepped a reworded sentence back with the word that
-- went at full strength; the INLINE before-image did not -- the
-- backend's spans cover the whole atom, `rewritten` throws them out, and
-- it drew the sentence solid red. Both read `del_fine` now, consulted
-- LAST, being the coarsest of the four sources.
describe("one edit in two layouts", function()
  if not h.difft then
    pending("difftastic is not installed")
    return
  end

  local old = [[
    def f(t):
        """Drop a modifier.

        It widens every box that carries a modifier.
        """
        return t

  ]]
  local new = old:gsub("carries a modifier%.", "carries two modifiers.")

  it("reds only the word that went inline", function()
    h.drawn({ lang = "python", old = old, new = new }, [[
      | def f(t):
      |     """Drop a modifier.
      |
      - ⟨    It widens every box that carries ⟩a⟨ modifier.⟩
      ~     It widens every box that carries ⟦two⟧ modifier⟦s⟧.
      |     """
      |     return t
      |
    ]])
  end)

  it("and picks out the same word in the other window", function()
    h.expect(h.draw_old({ old = old, new = new }), [[
      | def f(t):
      |     """Drop a modifier.
      |
      ~     It widens every box that carries ⟦a⟧ modifier.
      |     """
      |     return t
      |
    ]])
  end)
end)

-- A call renamed and emptied is atoms to difftastic: the old name gone
-- whole, a new one added. The new side, narrowed by the line-against-
-- line comparison, lights nothing on `sync_relations` -- every character
-- of it is in the old name -- and the before-image reds only what went.
-- The old window drew difftastic's atoms instead: the whole old name
-- red beside a new row with nothing new on it, a name replaced by
-- nothing.
describe("a name that only lost characters", function()
  if not h.difft then
    pending("difftastic is not installed")
    return
  end

  local o = {
    lang = "python",
    old = "class A:\n    def f(self, x):\n        y = 1\n        self.sync_csafe_relations(x, y)\n        return y\n",
    new = "class A:\n    def f(self, x):\n        y = 1\n        self.sync_relations()\n        return y\n",
  }

  it("reds what went inline, and nothing new on the row", function()
    h.drawn(o, [[
      | class A:
      |     def f(self, x):
      |         y = 1
      - ⟨        self.sync_⟩csafe_⟨relations(⟩x, y⟨)⟩
      ~         self.sync_relations()
      |         return y
    ]])
  end)

  it("and the same characters in the other window", function()
    h.expect(h.draw_old(o), [[
      | class A:
      |     def f(self, x):
      |         y = 1
      |         self.sync_⟦csafe_⟧relations(⟦x, y⟧)
      |         return y
    ]])
  end)
end)
