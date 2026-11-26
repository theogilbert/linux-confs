-- What every spec file starts from: this checkout, plenary, common.nvim
-- and nothing else. `run.sh` passes `--noplugin` and an empty 'packpath', so no copy
-- of the plugin installed in the reader's site packages can stand in for
-- this one, and `helpers.lua` calls `setup()` itself since
-- `plugin/uatis.lua` is not sourced.
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local root = vim.fn.fnamemodify(here, ":h")

vim.opt.packpath = ""
vim.opt.rtp:prepend(root)
vim.opt.rtp:append(assert(os.getenv("PLENARY_DIR"), "PLENARY_DIR is not set"))
-- common.nvim, the UI library uatis shares with the author's other
-- plugins: UATIS_COMMON, else a checkout beside this one.
local common = os.getenv("UATIS_COMMON") or (root .. "/../common.nvim")
assert(vim.fn.isdirectory(common .. "/lua/common") == 1, "common.nvim not found: set UATIS_COMMON")
vim.opt.rtp:append(common)
package.path = here .. "/?.lua;" .. package.path
vim.o.swapfile = false
-- As `-u NONE` has it: no filetype detection and no syntax. Specs set
-- the filetype they mean, and an ftplugin moving the cursor under an
-- async answer is a test of the ftplugin.
vim.cmd("filetype off")
vim.cmd("syntax off")
