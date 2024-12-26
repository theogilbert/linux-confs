-- Plugins present here have all been personnally vetted.
--
-- They are not managed by a plugin manager by purpose:
-- I want to be sure what code gets executed on my machine, and I do not want a

-- mini.statusline sets up the vim status line
require("mini.statusline").setup({})

vim.cmd("packadd! sonokai")
vim.g.sonokai_style = "atlantis"
vim.cmd.colorscheme("sonokai")

