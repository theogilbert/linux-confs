-- Minimal init.lua for testing
vim.opt.runtimepath:append(".")
vim.opt.runtimepath:append("../plenary.nvim")

-- Set up the plugin path
vim.opt.packpath:append(".")

-- Load the plugin
require("nvim-dap-df-pane")
