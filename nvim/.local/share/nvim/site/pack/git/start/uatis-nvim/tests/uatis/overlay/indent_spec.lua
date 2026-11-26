-- A block wrapped in a guard is reindented and the backend rightly
-- reports nothing for it -- but where the language counts the column,
-- that IS what the wrapping did, so the columns a row GAINED at its front
-- are marked and nothing else on it is (`diff.indent_marks`). Gated on
-- the rest of the row being byte-identical and on a hunk directly ABOVE
-- the run: a wrapper opens above what it wraps.
local h = require("helpers")

local function drawn(old, new, expected)
  h.drawn({ lang = "python", old = old, new = new }, expected)
end

describe("the indentation a wrapping pushed a block by", function()
  if not h.difft then
    pending("difftastic is not installed")
    return
  end

  it("is marked on every row of the block, not on the guard", function()
    drawn("def f(a):\n    x = a * 2\n    y = x + 1\n    return y\n",
      "def f(a):\n    if a:\n        x = a * 2\n        y = x + 1\n"
        .. "        return y\n    return 0\n", [[
          | def f(a):
          +     if a:
          |     ⟦    ⟧x = a * 2
          |     ⟦    ⟧y = x + 1
          |     ⟦    ⟧return y
          +     return 0
        ]])
  end)

  -- A file reindented throughout reports no hunks at all.
  it("is not marked on a file that was only reindented", function()
    drawn("def f(a):\n  x = a * 2\n  y = x + 1\n  return y\n",
      "def f(a):\n    x = a * 2\n    y = x + 1\n    return y\n", [[
        | def f(a):
        |     x = a * 2
        |     y = x + 1
        |     return y
      ]])
  end)

  -- Reindented throughout AND edited once, it would light up every row
  -- and bury the edit under the reformat.
  it("is not marked on a reformat beside one edit", function()
    local old, new = { "def f(a):" }, { "def f(a):" }
    for i = 1, 12 do
      table.insert(old, ("  step%d = a + %d"):format(i, i))
      table.insert(new, ("    step%d = a + %d"):format(i, i))
    end
    table.insert(old, "  return step1")
    table.insert(new, "    return step12")
    table.insert(old, "")
    table.insert(new, "")
    drawn(old, new, [[
      | def f(a):
      |     step1 = a + 1
      |     step2 = a + 2
      |     step3 = a + 3
      |     step4 = a + 4
      |     step5 = a + 5
      |     step6 = a + 6
      |     step7 = a + 7
      |     step8 = a + 8
      |     step9 = a + 9
      |     step10 = a + 10
      |     step11 = a + 11
      |     step12 = a + 12
      - ⟨  return ⟩step1
      |     return ⟦step12⟧
      |
    ]])
  end)

  it("is marked past the blank lines between the block's paragraphs", function()
    drawn("def f(a):\n    x = a * 2\n    y = x + 1\n\n    z = y - 3\n    w = z * z\n"
        .. "\n    return w\n",
      "def f(a):\n    try:\n        x = a * 2\n        y = x + 1\n\n        z = y - 3\n"
        .. "        w = z * z\n\n        return w\n    except ValueError:\n        return 0\n", [[
          | def f(a):
          +     try:
          |     ⟦    ⟧x = a * 2
          |     ⟦    ⟧y = x + 1
          |
          |     ⟦    ⟧z = y - 3
          |     ⟦    ⟧w = z * z
          |
          |     ⟦    ⟧return w
          +     except ValueError:
          +         return 0
        ]])
  end)

  it("is marked below a blank line under the wrapper", function()
    drawn("def f(a):\n    x = a * 2\n    y = x + 1\n    return y\n",
      "def f(a):\n    with lock:\n\n        x = a * 2\n        y = x + 1\n        return y\n", [[
        | def f(a):
        +     with lock:
        |
        |     ⟦    ⟧x = a * 2
        |     ⟦    ⟧y = x + 1
        |     ⟦    ⟧return y
      ]])
  end)

  it("is nothing on a block that moved LEFT, which gained no columns", function()
    drawn("def f(a):\n    if a:\n        x = a * 2\n        return x\n    return 0\n",
      "def f(a):\n    x = a * 2\n    return x\n", [[
        | def f(a):
        -     if a:
        |     x = a * 2
        |     return x
        -     return 0
      ]])
  end)
end)
