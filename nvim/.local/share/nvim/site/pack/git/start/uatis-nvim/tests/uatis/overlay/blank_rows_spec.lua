-- A blank line has no atoms, so a token-precise backend reports nothing
-- for it -- and a row the backend did not mention is code that only
-- moved, the rule that keeps reindented bodies unpainted. Between two
-- rows that ARE new it is the wrong rule: an added function with a
-- blank line inside came out as two green blocks with a gap through it.
local h = require("helpers")

local function drawn(backend, old, new, expected)
  if backend == "struct" and not h.difft then
    return pending("difftastic is not installed")
  end
  h.drawn({ backend = backend, old = old, new = new }, expected)
end

describe("a blank line inside an added block", function()
  for _, case in ipairs({ { "line", [[
    | local M = {}
    |
    | function M.one()
    |   return 1
    | end
    |
    + function M.two()
    +   local a = 1
    +
    +   return a
    + end
    +
    | return M
  ]] }, { "struct", [[
    | local M = {}
    |
    | function M.one()
    |   return 1
    | end
    |
    + function M.two()
    +   local a = 1
    +
    +   return a
    + end
    |
    | return M
  ]] } }) do
    it("is painted with it, in " .. case[1] .. " mode", function()
      drawn(case[1], "local M = {}\n\nfunction M.one()\n  return 1\nend\n\nreturn M\n",
        "local M = {}\n\nfunction M.one()\n  return 1\nend\n\n"
          .. "function M.two()\n  local a = 1\n\n  return a\nend\n\nreturn M\n", case[2])
    end)
  end
end)

describe("a blank line", function()
  -- It was always there, and painting it would claim it is new.
  it("between two edited lines is not painted", function()
    drawn("struct", "local M = {}\n\nfunction M.one()\n  local a = 1\n\n  return a\nend\n",
      "local M = {}\n\nfunction M.one()\n  local a = 2\n\n  return a * 2\nend\n", [[
        | local M = {}
        |
        | function M.one()
        - ⟨  local a = ⟩1
        |   local a = ⟦2⟧
        |
        |   return a ⟦* 2⟧
        | end
      ]])
  end)

  it("inside a body an `if` wrapped only moved, with the body", function()
    drawn("struct", "local M = {}\nfunction M.run(a)\n  local t = a * 2\n\n  return t\nend\n",
      "local M = {}\nfunction M.run(a)\n  if a then\n    local t = a * 2\n\n"
        .. "    return t\n  end\nend\n", [[
          | local M = {}
          | function M.run(a)
          +   if a then
          |   ⟦  ⟧local t = a * 2
          |
          |   ⟦  ⟧return t
          +   end
          | end
        ]])
  end)
end)
