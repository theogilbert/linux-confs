-- Plugins present here have all been personnally vetted.
--
-- They are not managed by a plugin manager by purpose:
-- I want to be sure what code gets executed on my machine, and I do not want a

-- mini.statusline sets up the vim status line
require("mini.statusline").setup({})
mini_ai = require('mini.ai')
mini_ai.setup({
    n_lines = 9999,
    custom_textobjects = {
        f = mini_ai.gen_spec.treesitter({
            a = "@function.outer",
            i = "@function.inner",
        }, {}),
        c = mini_ai.gen_spec.treesitter({
            a = "@class.outer",
            i = "@class.inner",
        }, {}),
        B = mini_ai.gen_spec.treesitter({
            a = "@block.outer",
            i = "@block.inner",
        }, {}),
        e = {
        {
            "%u[%l%d]+%f[^%l%d]",
            "%f[%S][%l%d]+%f[^%l%d]",
            "%f[%P][%l%d]+%f[^%l%d]",
            "^[%l%d]+%f[^%l%d]",
            "%f[%S][%w]+%f[^%w]",
            "%f[%P][%w]+%f[^%w]",
            "^%w+%f[^%w]",
        },
        "^().*()$",
    },
    }
})

require('gitsigns').setup()

-- nvim-cmp has a big configuration. To improve explorability of this file, cmp's config
-- has been moved to cmp-plugins.lua
require("cmp-plugins")

-- TODO add <leader>l keymaps for lsp related operations ([L]sp operations)
-- TODO add a shortcut to search not all symbols but simply classes
-- TODO there exists a nvim plugin which is able to optimize linting/formatting operations
--    it works by only submitting modified regions to the linter.
--    if I ever encounter performance issues, look into it.
-- TODO https://github.com/rcarriga/cmp-dap
-- TODO https://github.com/hrsh7th/nvim-cmp/issues/1092

vim.cmd("packadd! sonokai")
vim.g.sonokai_style = "shusia"
vim.cmd.colorscheme("sonokai")

-- fzf-lua
local actions = require("fzf-lua").actions

require("fzf-lua").setup({
	desc = "Custom FZF profile",
	winopts = { preview = { default = "bat" } },
	manpages = { previewer = "man_native" },
	helptags = { previewer = "help_native" },
	lsp = { code_actions = { previewer = "codeaction_native" } },
	tags = { previewer = "bat" },
	btags = { previewer = "bat" },
	keymap = {
		builtin = {
			true,
			["<C-d>"] = "preview-half-page-down",
			["<C-u>"] = "preview-half-page-up",
		},
		fzf = {
			true,
			["ctrl-d"] = "preview-half-page-down",
			["ctrl-u"] = "preview-half-page-up",
			["ctrl-q"] = "select-all+accept",
		},
	},
	actions = {
		files = {
			["enter"] = actions.file_edit_or_qf,
			["ctrl-b"] = actions.file_split,
			["ctrl-v"] = actions.file_vsplit,
			["ctrl-t"] = actions.file_tabedit,
			["alt-q"] = actions.file_sel_to_qf,
		},
	},
})

-- Which key
local wk = require("which-key")
wk.setup({
	trigger_blacklist = {
		n = { '"' },
	},
})
wk.add({
	{ "<leader>s", desc = "[S]earch" },
	{ "<leader>sv", desc = "[S]earch stuff in [V]im" },
	{ "<leader>sf", desc = "[S]earch stuff in [F]ile" },
	{ "<leader>sl", desc = "[S]earch stuff in [L]SP" },
	{ "<leader>sw", desc = "[S]earch stuff in [W]orkspace" },
	{ "<leader>sG", desc = "[S]earch stuff in [G]it" },
	{ "<leader>g", desc = "[g]it related actions" },
	{ "<leader>e", desc = "File [E]xplorer" },
	{ "<leader>O", desc = "Toggle [O]ptions" },
	{ "<leader>d", desc = "[D]ebugger actions" },
	{ "<leader>l", desc = "[L]SP actions" },
	{ "<leader>t", desc = "[T]ests actions" },
	{ "<leader>ld", desc = "[L]SP actions - [D]iagnostics" },
	{ "<leader>M", desc = "[M]arkdown actions" },
})

-- disable netrw at the very start of your init.lua
vim.g.loaded_netrw = 1
vim.g.loaded_netrwPlugin = 1

-- optionally enable 24-bit colour
vim.opt.termguicolors = true

-- Default nvim-tree config.
-- Options can be provided to the plugin.
require("nvim-tree").setup()

require("neotest").setup({
	adapters = {
		require("neotest-python")({
			dap = { justMyCode = false },
			pytest_discover_instances = true,
		}),
	},
})

