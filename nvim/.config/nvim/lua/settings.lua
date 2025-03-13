-- This NVIM configuration file is deeply inspired from kickstart.nvim.

-- Disable Python provider for rplugins:
-- I do not use Python rplugins, and the provider takes a long time to load.
vim.g.loaded_python3_provider = 0

vim.g.markdown_fenced_languages = {'bash=sh', 'javascript', 'js=javascript', 'json=javascript', 'typescript', 'ts=typescript', 'html', 'css', 'rust', 'python', 'ini=cfg', 'cfg'}

vim.opt.shiftwidth = 4
vim.opt.smarttab = true
vim.opt.expandtab = true
vim.opt.tabstop = 8
vim.opt.softtabstop = 0

vim.opt.foldmethod = "syntax"
vim.opt.foldlevelstart = 20

vim.opt.wildmode = "list:longest"

-- Set <space> as the leader key
-- See `:help mapleader`
--  NOTE: Must happen before plugins are loaded (otherwise wrong leader will be used)
vim.g.mapleader = " "
vim.g.maplocalleader = " "

-- Set to true if you have a Nerd Font installed and selected in the terminal
vim.g.have_nerd_font = true

-- [[ Setting options ]]
-- See `:help vim.opt`
-- NOTE: You can change these options as you wish!
--  For more options, you can see `:help option-list`

-- Make line numbers default
vim.opt.number = true
-- You can also add relative line numbers, to help with jumping.
--  Experiment for yourself to see if you like it!
-- vim.opt.relativenumber = true

-- Enable mouse mode, can be useful for resizing splits for example!
vim.opt.mouse = ""

-- Don't show the mode, since it's already in the status line
vim.opt.showmode = false

-- Enable break indent
vim.opt.breakindent = true

-- Save undo history
vim.opt.undofile = true

-- Case-insensitive searching UNLESS \C or one or more capital letters in the search term
vim.opt.ignorecase = true
vim.opt.smartcase = true

-- Keep signcolumn on by default
vim.opt.signcolumn = "yes"

-- Decrease update time
vim.opt.updatetime = 250

-- Decrease mapped sequence wait time
-- Displays which-key popup sooner
-- vim.opt.timeoutlen = 300

-- Sync clipboard between OS and Neovim.
-- Schedule the setting after 'UiEnter' because it can increase startup-time.
-- Remove this option if you want your clipboard to remain independant.
-- See `:help 'clipboard'`
vim.schedule(function()
    vim.opt.clipboard = "unnamedplus"
end)

-- Configure how new splits should be opened
vim.opt.splitbelow = true

-- Sets how neovim will display certain whitespace characters in the editor.
--  See `:help 'list'`
--  and `:help 'listchars'`
-- vim.opt.list = true
-- vim.opt.listchars = { tab = "» ", trail = "·", nbsp = "␣" }

-- Preview substitutions live, as you type!
vim.opt.inccommand = "split"

-- Show which line your cursor is on
vim.opt.cursorline = true
-- vim.opt.cursorcolumn = true

vim.opt.syntax = "on"

-- Minimal number of screen lines to keep above and below the cursor.
vim.opt.scrolloff = 2
