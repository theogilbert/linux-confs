-- Pane follows its source window: nvim --headless -c 'luafile tests/close.lua'
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
local ui = require("salmon.ui")
vim.cmd.edit(root_dir .. "/tests/fixtures/main.py")
local other = vim.api.nvim_get_current_win()
vim.cmd("vsplit")
local src = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_cursor(src, { 5, 12 })
vim.cmd("Salmon") vim.wait(300)
print("open with 3 windows: pane open = " .. tostring(ui.is_open()))
vim.api.nvim_win_close(src, false) vim.wait(100)
print("source closed, other window left: pane open = " .. tostring(ui.is_open()) ..
  ", windows = " .. #vim.api.nvim_tabpage_list_wins(0))
vim.api.nvim_set_current_win(other)
vim.api.nvim_win_set_cursor(other, { 5, 12 })
vim.cmd("Salmon") vim.wait(300)
print("reopened from last window: pane open = " .. tostring(ui.is_open()))
print("closing last source window; nvim should exit")
vim.api.nvim_win_close(other, false)
vim.wait(500)
print("STILL RUNNING (unexpected)")
vim.cmd("qa!")
