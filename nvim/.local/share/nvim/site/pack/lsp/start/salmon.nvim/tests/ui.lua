-- UI smoke test: nvim --headless -c 'luafile tests/ui.lua'
local root_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root_dir)
-- common.nvim (help float, pane): SALMON_COMMON, else a checkout beside this one.
local common_dir = vim.env.SALMON_COMMON or (root_dir .. "/../common.nvim")
if vim.fn.isdirectory(common_dir .. "/lua/common") == 1 then vim.opt.rtp:append(common_dir) end
-- Test this checkout, not an installed copy the user config already loaded.
for name in pairs(package.loaded) do
  if name == "salmon" or name:match("^salmon%.") then package.loaded[name] = nil end
end
vim.cmd("runtime plugin/salmon.lua")
vim.cmd.edit(root_dir .. "/tests/fixtures/main.py")
vim.wait(8000, function() return #vim.lsp.get_clients({ bufnr = 0, method = "textDocument/documentHighlight" }) > 0 end)
vim.wait(800)
local src_win = vim.api.nvim_get_current_win()
local function pane() for _, l in ipairs(vim.api.nvim_buf_get_lines(require("salmon.ui").state.buf, 0, -1, false)) do print(l) end end
local function feed(keys) vim.api.nvim_feedkeys(vim.keycode(keys), "mx", false); vim.wait(1500) end
-- Put the pane cursor on the step whose text starts with `pat`.
local function select(pat)
  local ui = require("salmon.ui")
  for n, row in pairs(ui.state.rows) do
    if n.text:find(pat, 1, true) == 1 then
      vim.api.nvim_win_set_cursor(ui.state.win, { row, 0 })
      return
    end
  end
  print("no step " .. pat)
end
local function where() return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t") .. ":" .. vim.api.nvim_win_get_cursor(0)[1] end

vim.keymap.set("n", "]s", "<cmd>echo 'orig'<cr>")
print("[s before open -> " .. vim.inspect(vim.fn.maparg("]s", "n")))
vim.api.nvim_win_set_cursor(0, { 5, 12 }) -- `a` in total = a + b
vim.cmd("Salmon")
vim.wait(2000)
pane()
vim.api.nvim_set_current_win(src_win)
feed("[s") print("[s -> " .. where())
feed("[s") print("[s -> " .. where())
feed("[s") print("[s -> " .. where())
feed("]s") print("]s -> " .. where())
print("focus stayed in source: " .. tostring(vim.api.nvim_get_current_win() == src_win))
vim.cmd("Salmon close")
print("]s after close -> " .. vim.inspect(vim.fn.maparg("]s", "n")))
-- Source highlights
do
  local buf = vim.fn.bufnr(vim.fn.fnamemodify(root_dir .. "/tests/fixtures/main.py", ":p"))
  vim.api.nvim_win_set_cursor(0, { 5, 12 })
  vim.cmd("Salmon") vim.wait(1500)
  local ns = vim.api.nvim_create_namespace("salmon_positions")
  local function marks()
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
      if m[4].sign_text then goto skip end
      out[#out + 1] = ("row%d col%d-%s %s"):format(m[2] + 1, m[3], tostring(m[4].end_col), m[4].line_hl_group or m[4].hl_group)
      ::skip::
    end
    return table.concat(out, " | ")
  end
  local function gutter()
    local s = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
      if m[4].sign_text then s[#s + 1] = ("%d:%s"):format(m[2] + 1, vim.trim(m[4].sign_text)) end
    end
    return table.concat(s, " ")
  end
  print("marks at open: " .. marks())
  print("gutter at open: " .. gutter())
  select("result = compute") vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0 })
  print("marks on result = compute: " .. marks())
  print("gutter on result = compute: " .. gutter())
  vim.cmd("Salmon close")
  print("marks after close: " .. marks())
end
-- Hover
do
  vim.api.nvim_win_set_cursor(0, { 5, 12 })
  vim.cmd("Salmon") vim.wait(1500)
  select("base = 20")
  feed("K")
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      print("-- hover float:")
      for _, l in ipairs(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)) do print(l) end
    end
  end
  vim.cmd("Salmon close")
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then vim.api.nvim_win_close(w, true) end
  end
  vim.api.nvim_win_set_cursor(0, { 15, 10 }) -- print(result)
  vim.cmd("Salmon") vim.wait(1500)
  select("result = compute")
  feed("K")
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      for _, l in ipairs(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)) do
        if l:match("Upstream") then print("result hover: " .. l) end
      end
    end
  end
  vim.cmd("Salmon close")
end
-- Folds
do
  require("salmon").config.derive = true
  vim.api.nvim_win_set_cursor(0, { 15, 10 }) -- print(result)
  vim.cmd("Salmon") vim.wait(1500)
  local function rows(label) print(("-- %s (%d rows, cursor %d)"):format(label, vim.api.nvim_buf_line_count(0), vim.api.nvim_win_get_cursor(0)[1])) end
  rows("open")
  feed("zR") rows("zR")
  feed("zM") rows("zM")
  pane()
  feed("zr") rows("zr")
  feed("zr") rows("zr")
  feed("zm") rows("zm")
  select("compute")
  feed("zO") rows("zO on compute")
  feed("zj") rows("zj")
  feed("]z") rows("]z")
  feed("[z") rows("[z")
  feed("zc") rows("zc")
  feed("za") rows("za")
  feed("zA") rows("zA")
  feed("zC") rows("zC")
  feed("zi") rows("zi")
  feed("zi") rows("zi")
  pane()
  vim.cmd("Salmon close")
  require("salmon").config.derive = false
end
-- Help float
do
  local ui = require("salmon.ui")
  local function floats()
    return vim.tbl_filter(function(w) return vim.api.nvim_win_get_config(w).relative ~= "" end, vim.api.nvim_tabpage_list_wins(0))
  end
  vim.api.nvim_set_current_win(src_win)
  vim.api.nvim_win_set_cursor(0, { 5, 12 })
  vim.cmd("Salmon") vim.wait(1500)
  vim.api.nvim_set_current_win(ui.state.win)
  feed("g?")
  local f = floats()
  print("-- help float: " .. #f)
  if f[1] then
    for _, l in ipairs(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(f[1]), 0, -1, false)) do print(l) end
  end
  print("help is focused: " .. tostring(vim.api.nvim_get_current_win() == f[1]))
  for _, k in ipairs({ "q", "<Esc>", "g?" }) do
    feed(k)
    print(("help %s: floats %d, back in pane %s"):format(k, #floats(), tostring(vim.api.nvim_get_current_win() == ui.state.win)))
    feed("g?")
  end
  vim.api.nvim_set_current_win(src_win) vim.wait(100)
  print("help after leaving: floats " .. #floats())
  vim.cmd("Salmon close")
end
-- Parallel inputs: top priority closest to the traced symbol
do
  local ui = require("salmon.ui")
  vim.cmd.edit(root_dir .. "/tests/fixtures/calls.py")
  vim.api.nvim_win_set_cursor(0, { 2, 11 })
  vim.cmd("Salmon") vim.wait(2000)
  print("-- parallel inputs:")
  pane()
  local path = ui.current_path()
  print("\nactive path starts at: " .. path[1].text .. " line " .. (path[1].row + 1))
  vim.api.nvim_set_current_win(ui.state.win)
  select("work(2)")
  feed("[z")
  print("\n[z from work(2) -> " .. ui.state.lines[vim.api.nvim_win_get_cursor(0)[1]].text)
  vim.cmd("Salmon close")
end
-- Stepping keeps the steps around the current one in view, known and on screen
do
  local ui = require("salmon.ui")
  local salmon = require("salmon")
  local auto, lines = salmon.config.auto_expand, vim.o.lines
  salmon.config.auto_expand = 0
  vim.cmd.edit(root_dir .. "/tests/fixtures/across.py")
  vim.api.nvim_win_set_cursor(0, { 3, 11 })
  vim.cmd("Salmon") vim.wait(1500)
  vim.o.lines = 8
  local function report(label)
    local path, sel = ui.current_path(), ui.state.lines[vim.api.nvim_win_get_cursor(ui.state.win)[1]]
    local top, bot = vim.fn.line("w0", ui.state.win), vim.fn.line("w$", ui.state.win)
    local shown = {}
    for i, n in ipairs(path) do
      if n == sel then
        for d, name in pairs({ [-1] = "up", [1] = "down" }) do
          local r = path[i + d] and ui.state.rows[path[i + d]]
          if r then shown[#shown + 1] = name .. ((r >= top and r <= bot) and " visible" or " HIDDEN") end
        end
      end
    end
    table.sort(shown, function(a, b) return a > b end)
    print(("\n%s: on %q, rows %d-%d of %d, %s"):format(label, sel.text, top, bot, vim.api.nvim_buf_line_count(ui.state.buf), table.concat(shown, ", ")))
  end
  report("open")
  for i = 1, 5 do
    ui.step(-1) vim.wait(800)
    report("[s " .. i)
  end
  for i = 1, 2 do
    ui.step(1) vim.wait(300)
    report("]s " .. i)
  end
  vim.cmd("Salmon close")
  -- Rapid presses, then other paths far from the selected step
  vim.cmd.edit(root_dir .. "/tests/fixtures/across.py")
  vim.api.nvim_win_set_cursor(0, { 3, 11 })
  vim.cmd("Salmon") vim.wait(1500)
  ui.step(-1) ui.step(-1) ui.step(-1) vim.wait(1500)
  report("[s x3 at once")
  vim.cmd("Salmon close")
  vim.cmd.edit(root_dir .. "/tests/fixtures/calls.py")
  vim.api.nvim_win_set_cursor(0, { 2, 11 })
  vim.cmd("Salmon") vim.wait(2000)
  ui.step(-1) vim.wait(800)
  report("calls [s")
  for i = 1, 4 do
    ui.cycle_path(1) vim.wait(100)
    report("]r " .. i)
  end
  vim.o.lines = lines
  vim.cmd("Salmon close")
  -- Two presses while a step is loading: no second resolve, children intact.
  local trace = require("salmon.trace")
  local resolved, finish = 0, nil
  local node = { resolve = function(_, cb) resolved = resolved + 1; finish = cb end, expanded = false, loading = false, tags = {} }
  local waited = 0
  local function done() waited = waited + 1 end
  trace.expand(node, 0, function() end, done)
  trace.expand(node, 0, function() end, done)
  finish({})
  print(("\nwhile loading: resolved %d time(s), %d callbacks ran"):format(resolved, waited))
  salmon.config.auto_expand = auto
end
-- Occurrences of the variable followed into another function of the same file
do
  local ui = require("salmon.ui")
  local lsp = require("salmon.lsp")
  local ns = vim.api.nvim_create_namespace("salmon_positions")
  local function occurrences(buf)
    local rows = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
      if m[4].hl_group == "SalmonSymbol" then rows[#rows + 1] = m[2] + 1 end
    end
    return table.concat(rows, ",")
  end
  local function check(label)
    vim.cmd.edit(root_dir .. "/tests/fixtures/across.py")
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_win_set_cursor(0, { 3, 11 })
    vim.cmd("Salmon") vim.wait(1500)
    select("amount = 3")
    ui.update_positions() vim.wait(500)
    print(("\n%s: occurrences on lines %s (want 1,2,3 and 7,8,9,10)"):format(label, occurrences(buf)))
    vim.cmd("Salmon close")
  end
  check("across functions")
  local highlights = lsp.highlights
  lsp.highlights = function(_, _, _, cb) vim.schedule(function() cb({}) end) end
  check("server answers empty")
  lsp.highlights = highlights
end
print("errors: " .. ((vim.v.errmsg ~= "" and not vim.v.errmsg:match("FileExplorer")) and vim.v.errmsg or "none"))
vim.cmd("qa!")
