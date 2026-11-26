-- `]c` stops where there is something to look at. A multi-line atom is
-- ONE changed node to difftastic, so the hunk covers every row of it
-- while the marks sit on the rows that differ; anchored at the hunk, the
-- cursor landed on a docstring's opening `"""` with the edit three rows
-- below.
local h = require("helpers")

describe("]c", function()
  if not h.difft then
    pending("difftastic is not installed")
    return
  end

  it("stops on the row that changed, not the node it is in", function()
    local old = [[
      def f(t):
          """Drop a modifier.

          The diagram is a structural overview.
          It widens every box that carries one.
          """
          return t

    ]]
    local pic, stops = h.draw({ lang = "python", old = old, new = (old:gsub("carries one", "carries two")) })
    h.expect(pic, [[
      | def f(t):
      |     """Drop a modifier.
      |
      |     The diagram is a structural overview.
      - ⟨    It widens every box that carries ⟩one⟨.⟩
      ~     It widens every box that carries ⟦two⟧.
      |     """
      |     return t
      |
    ]])
    assert.are.same({ 5 }, stops)
  end)

  -- Nothing drawn on it anywhere: anchored where the before-image hangs.
  it("still stops on a pure deletion", function()
    local _, stops = h.draw({ lang = "python", old = "def f(t):\n    a = 1\n    b = 2\n    return t\n",
      new = "def f(t):\n    a = 1\n    return t\n" })
    assert.are.equal(1, #stops)
  end)
end)
