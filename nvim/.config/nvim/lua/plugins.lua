-- Plugins present here have all been personnally vetted.
--
-- They are not managed by a plugin manager by purpose:
-- I want to be sure what code gets executed on my machine, and I do not want a

-- mini.statusline sets up the vim status line
require("mini.statusline").setup({})

-- TODO add <leader>l keymaps for lsp related operations ([L]sp operations)
-- TODO add a shortcut to search not all symbols but simply classes
-- TODO configure cmp to start cmp only after 2 or 3 letters, not just one
-- TODO there exists a nvim plugin which is able to optimize linting/formatting operations
--    it works by only submitting modified regions to the linter.
--    if I ever encounter performance issues, look into it.

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
                ["ctrl-u"] = actions.file_split,
                ["ctrl-v"] = actions.file_vsplit,
                ["ctrl-t"] = actions.file_tabedit,
                ["alt-q"] = actions.file_sel_to_qf,
            }
        }
})

-- Which key
local wk = require("which-key")
wk.setup {
    trigger_blacklist = {
        n = { '"' }
    }
}
wk.add({
	{ "<leader>s", desc = "[S]earch" },
	{ "<leader>sf", desc = "[S]earch stuff in [F]ile" },
	{ "<leader>sw", desc = "[S]earch stuff in [W]orkspace" },
	{ "<leader>e", desc = "File [E]xplorer" },
	{ "<leader>o", desc = "Toggle [O]ptions" },
	{ "<leader>d", desc = "[D]ebugger actions" },
	{ "<leader>l", desc = "[L]SP actions" },
	{ "<leader>ld", desc = "[L]SP actions - [D]iagnostics" },
})

local cmp = require("cmp")
cmp.setup({
        preselect = cmp.PreselectMode.None,
	snippet = {
		-- REQUIRED - you must specify a snippet engine
		expand = function(args)
			-- vim.fn["vsnip#anonymous"](args.body) -- For `vsnip` users.
			-- require('luasnip').lsp_expand(args.body) -- For `luasnip` users.
			-- require('snippy').expand_snippet(args.body) -- For `snippy` users.
			-- vim.fn["UltiSnips#Anon"](args.body) -- For `ultisnips` users.
			vim.snippet.expand(args.body) -- For native neovim snippets (Neovim v0.10+)
		end,
	},
	window = {
		-- completion = cmp.config.window.bordered(),
		-- documentation = cmp.config.window.bordered(),
	},
	mapping = cmp.mapping.preset.insert({
		["<C-b>"] = cmp.mapping.scroll_docs(-4),
		["<C-f>"] = cmp.mapping.scroll_docs(4),
		["<C-Space>"] = cmp.mapping.complete(),
		["<C-e>"] = cmp.mapping.abort(),
		["<CR>"] = cmp.mapping.confirm({ select = false }),
	}),
	sources = cmp.config.sources({
		{ name = "nvim_lsp" },
		{ name = "nvim_lsp_signature_help" },
	}, {
		{ name = "buffer" },
		{ name = "path" },
	}),
})

-- disable netrw at the very start of your init.lua
vim.g.loaded_netrw = 1
vim.g.loaded_netrwPlugin = 1

-- optionally enable 24-bit colour
vim.opt.termguicolors = true

-- OR setup with some options
require("nvim-tree").setup({})

