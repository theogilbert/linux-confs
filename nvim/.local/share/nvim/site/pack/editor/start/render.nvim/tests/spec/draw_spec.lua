local markdown = require("render.markdown")
local draw = require("render.draw")

--- `lines` drawn at `width`, as plain strings and the lines themselves.
local function drawn(lines, opts)
  local out = draw.blocks(markdown.blocks(lines), opts or {})
  return (draw.flatten(out)), out
end

describe("draw", function()
  it("prose is wrapped to the width, and keeps its line", function()
    local text, out = drawn({ "one two three four five" }, { width = 10 })
    assert.same({ "one two", "three four", "five" }, text)
    assert.same(
      { 1, 1, 1 },
      vim.tbl_map(function(l)
        return l.row
      end, out)
    )
  end)

  it("a heading is its words, in the group for its level", function()
    local text, out = drawn({ "## Why it is" })
    assert.same({ "Why it is" }, text)
    assert.same("RenderHeading2", out[1][1][2])
    assert.same("Why it is", out[1].heading)
  end)

  it("a table is ruled, its rows on the lines they came from", function()
    local text, out = drawn({ "| a | bb |", "|---|---:|", "| 1 | 2 |" })
    assert.same({
      "┌───┬────┐",
      "│ a │ bb │",
      "├───┼────┤",
      "│ 1 │  2 │",
      "└───┴────┘",
    }, text)
    assert.same(
      { 1, 1, 1, 3, 3 },
      vim.tbl_map(function(l)
        return l.row
      end, out)
    )
  end)

  it("a list item hangs under its bullet", function()
    local text = drawn({ "- one two three", "  1. [x] done" }, { width = 11 })
    assert.same({ "• one two", "  three", "  1. ✓ done" }, text)
  end)

  it("a citation is behind a bar", function()
    local text = drawn({ "> so it was" })
    assert.same({ "▎ so it was" }, text)
  end)

  it("a fence is drawn as typed, and never folded", function()
    local long = ("x"):rep(30)
    local text = drawn({ "```", long, "```" }, { width = 10, code = false })
    assert.same({ "```", long, "```" }, text)
  end)

  it("a painter colours a fence", function()
    local _, out = drawn({ "```lua", "local x", "```" }, {
      paint = function(lines, lang)
        assert.same("lua", lang)
        return { { { "local", "Keyword" }, { " x" } } }
      end,
    })
    assert.same("Keyword", out[2][1][2])
  end)

  it("a block a caller knows is the caller's to draw", function()
    local blocks = { { kind = "box", row = 4 } }
    local out = draw.blocks(blocks, {
      custom = function(block, ctx, left)
        if block.kind == "box" then
          ctx.body(left, "[box]", "MyBox")
          return true
        end
      end,
    })
    assert.same({ { { "[box]", "MyBox" } } }, { { out[1][1] } })
    assert.same(4, out[1].row)
  end)

  it("pieces: a line cut to a room, with its colours cut to match", function()
    local cut = draw.pieces("ab cd", { { "ab", "X" }, { " cd" } }, 3)
    assert.same({ "ab", "cd" }, { cut[1].text, cut[2].text })
    assert.same({ { "ab", "X" } }, { { cut[1].runs[1][1], cut[1].runs[1][2] } })
    assert.same("cd", cut[2].runs[1][1])
    assert.is_nil(draw.pieces("ab", nil, 3)[1].runs)
  end)

  it("a band goes under the words, with their colours over it", function()
    local out = draw.blocks({ { kind = "box", row = 1 } }, {
      custom = function(_, ctx, left)
        ctx.body(left, "a", "Fg", "+ ", nil, nil, "Band")
        ctx.body(left, "b c", "Fg", nil, { { "b", "Kw" }, { " c" } }, nil, "Band")
        return true
      end,
    })
    assert.same({ "+ a", "Band" }, out[1][1])
    assert.same({ "b", { "Band", "Kw" } }, { out[2][1][1], out[2][1][2] })
    assert.same({ " c", { "Band", "Fg" } }, { out[2][2][1], out[2][2][2] })
  end)

  it("flattened, a link is where it was drawn", function()
    local _, hls, refs = draw.flatten(draw.blocks(markdown.blocks({ "go [there](a.md)" })))
    assert.same(
      { row = 0, col = 3, end_col = 8, ref = { kind = "path", text = "there", href = "a.md" } },
      refs[1]
    )
    assert.same("RenderLink", hls[1].hl)
  end)
end)
