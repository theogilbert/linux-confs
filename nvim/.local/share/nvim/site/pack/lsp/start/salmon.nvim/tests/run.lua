-- Headless test driver: nvim --headless -l tests/run.lua [--no-lsp]
-- `nvim -l` sets `arg` and skips user config: no LSP servers to wait for.
local use_lsp = _G.arg == nil
local root_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root_dir)
-- common.nvim (help float, pane): SALMON_COMMON, else a checkout beside this one.
local common_dir = vim.env.SALMON_COMMON or (root_dir .. "/../common.nvim")
if vim.fn.isdirectory(common_dir .. "/lua/common") == 1 then vim.opt.rtp:append(common_dir) end
-- Test this checkout, not an installed copy the user config already loaded.
for name in pairs(package.loaded) do
  if name == "salmon" or name:match("^salmon%.") then package.loaded[name] = nil end
end
local salmon = require("salmon")
local trace = require("salmon.trace")
local ui = require("salmon.ui")

local cases = {
  { "main.py", "print(result)", "result", false },
  { "main.py", "print(result)", "result", true },
  { "main.py", "total = a + b", "a", false },
  { "main.py", "print(item)", "item", false },
  { "main.py", "print(count)", "count", true },
  { "sample.lua", "print(r)", "r", true },
  { "sample.lua", "local s = x + y", "x", false },
  { "sample.ts", "console.log(r)", "r", true },
  { "frames.py", "print(df, items)", "df", false },
  { "frames.py", "print(df, items)", "df", true },
  { "frames.py", "print(df, items)", "items", false },
  { "frames.py", "count += 1", "count", false },
  { "sample.ts", "const out = n * 2", "n", false },
  { "imports.py", "print(LIMIT, h)", "LIMIT", false },
  { "imports.py", "print(LIMIT, h)", "h", false },
  { "imports.py", "return y", "y", true },
  { "uses.lua", "print(lib)", "lib", false },
  { "uses.ts", "console.log(v)", "v", true },
  { "calls.py", "return v", "v", false },
  { "calls.py", "return cap", "cap", false },
  { "members.py", "return conn.execute", "conn", false },
  { "members.py", "return conn.execute", "conn", true },
  { "members.py", "return run(self._conn)", "_conn", false },
  { "members.py", "        return conn", "conn", false },
  { "members.ts", "return conn + 1", "conn", false },
  { "members.lua", "  return conn", "conn", false },
}

local function expand_all(node, depth, done)
  local pending = 1
  local function finish()
    pending = pending - 1
    if pending == 0 then done() end
  end
  local function go(n, d)
    if d == 0 or not n.resolve then return end
    pending = pending + 1
    trace.expand(n, 0, function() end, function()
      for _, c in ipairs(n.children or {}) do go(c, d - 1) end
      finish()
    end)
  end
  go(node, depth)
  finish()
end

for _, c in ipairs(cases) do
  if os.getenv("CASE") and not (c[1] .. ":" .. c[3]):find(os.getenv("CASE"), 1, true) then goto continue end
  io.stderr:write("case " .. c[1] .. " " .. c[3] .. "\n")
  local file, line_pat, word, derive = unpack(c)
  vim.cmd.edit(root_dir .. "/tests/fixtures/" .. file)
  local buf = vim.api.nvim_get_current_buf()
  if use_lsp then
    vim.wait(8000, function()
      return #vim.lsp.get_clients({ bufnr = buf, method = "textDocument/documentHighlight" }) > 0
    end, 50)
    vim.wait(500)
  end
  local row, col
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local s = l:find(line_pat, 1, true)
    if s then
      row, col = i - 1, l:find("%f[%w_]" .. word .. "%f[^%w_]", s) - 1
      break
    end
  end
  salmon.config.derive = derive
  local root = trace.root(buf, row, col)
  local finished = false
  expand_all(root, 8, function() finished = true end)
  vim.wait(10000, function() return finished end, 20)
  local lsp_names = vim.tbl_map(function(cl) return cl.name end, vim.lsp.get_clients({ bufnr = buf }))
  print(("== %s:%d %s derive=%s lsp=[%s]%s"):format(file, row + 1, word, tostring(derive),
    table.concat(lsp_names, ","), finished and "" or " TIMEOUT"))
  for _, l in ipairs((ui.render_lines(root))) do print(l) end
  print("")
  ::continue::
end
vim.cmd("qa!")
