-- Writes the pictures a `UATIS_ACCEPT` run recorded back into the spec
-- files: each in place of the next `h.TODO` in its file, in the order
-- they ran, or of the expected picture it differed from. For writing an
-- engine test -- state the pair, leave the picture `h.TODO`, run -- and
-- for taking a deliberate change of drawing. READ what came back before
-- keeping it: it is what the code does, not what it should.
--
--   UATIS_ACCEPT=/tmp/pics tests/run.sh tests/uatis/x_spec.lua
--   nvim -l tests/accept.lua /tmp/pics
local function dedent(text)
  local lines = vim.split(text, "\n", { plain = true })
  local indent
  for _, l in ipairs(lines) do
    if l:match("%S") then
      local n = #l:match("^%s*")
      indent = indent and math.min(indent, n) or n
    end
  end
  for i, l in ipairs(lines) do
    lines[i] = (l:sub((indent or 0) + 1):gsub("%s+$", ""))
  end
  if lines[#lines] == "" then
    table.remove(lines)
  end
  return table.concat(lines, "\n")
end

--- `pic` as a long string whose lines sit two in from `indent`.
local function literal(pic, indent)
  local eqs = ""
  while pic:find("]" .. eqs .. "]", 1, true) do
    eqs = eqs .. "="
  end
  local body = {}
  for _, l in ipairs(vim.split(pic, "\n", { plain = true })) do
    table.insert(body, indent .. "  " .. l)
  end
  return "[" .. eqs .. "[\n" .. table.concat(body, "\n") .. "\n" .. indent .. "]" .. eqs .. "]"
end

local function indent_at(src, pos)
  local line_start = src:sub(1, pos):match(".*\n()") or 1
  return src:sub(line_start, pos):match("^%s*")
end

local by_file, order = {}, {}
for line in io.lines(arg[1]) do
  local rec = vim.json.decode(line)
  if not by_file[rec.file] then
    by_file[rec.file] = {}
    table.insert(order, rec.file)
  end
  table.insert(by_file[rec.file], rec)
end

for _, file in ipairs(order) do
  local src = table.concat(vim.fn.readfile(file), "\n")
  local todo, replaced = {}, 0
  for _, rec in ipairs(by_file[file]) do
    if rec.was then
      -- The long string holding the picture this one differed from.
      local done = false
      src = src:gsub("%[(=*)%[\n(.-)\n([ \t]*)%]%1%]", function(eqs, body, close)
        if not done and dedent(body) == rec.was then
          done = true
          replaced = replaced + 1
          return literal(rec.picture, close)
        end
      end)
    else
      table.insert(todo, rec.picture)
    end
  end
  local n = 0
  src = src:gsub("()h%.TODO", function(pos)
    n = n + 1
    if todo[n] then
      replaced = replaced + 1
      return literal(todo[n], indent_at(src, pos))
    end
  end)
  vim.fn.writefile(vim.split(src, "\n", { plain = true }), file)
  print(file .. ": " .. replaced .. " picture(s)")
end
