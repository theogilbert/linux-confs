-- Lines folded into one reach the renderer as a pure deletion of the rows
-- that did not survive, anchored like every rowless deletion after the
-- last new row there was: the removed parameters BELOW the one-line
-- signature, as though taken from between it and its body, and nothing
-- on the one line that changed (`collapsed_span`).
local h = require("helpers")

describe("a fold", function()
  if not h.difft then
    pending("difftastic is not installed")
    return
  end

  -- The whole signature -- an opening bracket nobody closes is not the
  -- code that was there -- with the rows that came through stepped back.
  it("draws a signature pulled onto one line above it, whole", function()
    h.drawn({ lang = "python",
      old = "def place(\n    nodes: list[GraphNode],\n    edges: list[GraphEdge],\n"
        .. "    layout: Layout,\n) -> PlaceResult:\n    return None\n",
      new = "def place(nodes: list[GraphNode]) -> PlaceResult:\n    return None\n",
    }, [[
      - ⟨def place(⟩
      - ⟨    nodes: list[GraphNode]⟩,
      -     edges: list[GraphEdge],
      -     layout: Layout,
      - ⟨) -> PlaceResult:⟩
      | def place(nodes: list[GraphNode]) -> PlaceResult:
      |     return None
    ]])
  end)

  it("leaves an ordinary deletion below the row it was removed after", function()
    h.drawn({ lang = "python",
      old = "def f():\n    a = 1\n    b = 2\n    c = 3\n    return a\n",
      new = "def f():\n    a = 1\n    return a\n",
    }, [[
      | def f():
      |     a = 1
      -     b = 2
      -     c = 3
      |     return a
    ]])
  end)
end)
