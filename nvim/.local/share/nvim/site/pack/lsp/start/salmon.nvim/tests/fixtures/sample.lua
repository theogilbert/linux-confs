local function add(x, y)
  local s = x + y
  return s
end

local base = 1
if base > 0 then
  base = 2
end
local alias = base
local r = add(alias, 3)
print(r)
