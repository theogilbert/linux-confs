-- What every spec file starts from: this checkout and plenary on the
-- runtime path, and nothing else. `packpath=` so it is this checkout
-- under test rather than whatever copy of the plugin is installed, and
-- no filetype or syntax, which `-u NONE` would have left off too: a
-- spec that wants a filetype sets one.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local plenary = assert(vim.env.RENDER_PLENARY, "RENDER_PLENARY: run the suite with tests/run.sh")

vim.o.packpath = ""
vim.opt.rtp:prepend(root)
vim.opt.rtp:append(plenary)
vim.cmd("filetype plugin indent off")
vim.cmd("syntax off")
vim.o.swapfile = false
vim.o.shadafile = "NONE"

package.path = root .. "/tests/?.lua;" .. package.path
