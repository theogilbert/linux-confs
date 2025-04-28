-- Plugins present here have all been personnally vetted.
--
-- They are not managed by a plugin manager by purpose:
-- I want to be sure what code gets executed on my machine, and I do not want a

-- mini.statusline sets up the vim status line
require("mini.statusline").setup({})

-- TODO add <leader>l keymaps for lsp related operations ([L]sp operations)
-- TODO add a shortcut to search not all symbols but simply classes
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
                ["ctrl-b"] = actions.file_split,
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
	{ "<leader>sv", desc = "[S]earch stuff in [V]im" },
	{ "<leader>sf", desc = "[S]earch stuff in [F]ile" },
	{ "<leader>sl", desc = "[S]earch stuff in [L]SP" },
	{ "<leader>sw", desc = "[S]earch stuff in [W]orkspace" },
	{ "<leader>sG", desc = "[S]earch stuff in [G]it" },
	{ "<leader>e", desc = "File [E]xplorer" },
	{ "<leader>O", desc = "Toggle [O]ptions" },
	{ "<leader>d", desc = "[D]ebugger actions" },
	{ "<leader>l", desc = "[L]SP actions" },
	{ "<leader>t", desc = "[T]ests actions" },
	{ "<leader>ld", desc = "[L]SP actions - [D]iagnostics" },
})

-- https://www.reddit.com/r/neovim/comments/tsq4z8/completion_with_nvimcmp_for_daprepl/
local cmp = require("cmp")
cmp.setup({
        enabled = function()
          return vim.api.nvim_buf_get_option(0, "buftype") ~= "prompt"
              or require("cmp_dap").is_dap_buffer()
        end,
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
		{ name = "nvim_lsp_signature_help" },
		{ name = "nvim_lsp" },
		{ name = "path" },
		{ name = "buffer" },
	}),
        completion = {
            autocomplete = false
        },
        experimental = {
            ghost_text = true
        }
})


-- define a timer to activate delayed auto-complete after 300ms
local cmp_timer = nil
vim.api.nvim_create_autocmd({ "TextChangedI", "CmdlineChanged" }, {
    pattern = "*",
    callback = function()
        if cmp_timer then
            vim.loop.timer_stop(cmp_timer)
            cmp_timer = nil
        end

        cmp_timer = vim.loop.new_timer()
        cmp_timer:start(300, 0, vim.schedule_wrap(function()
            cmp.complete({ reason = cmp.ContextReason.Auto })
        end))
    end
})

-- `/` cmdline setup.
cmp.setup.cmdline('/', {
  mapping = cmp.mapping.preset.cmdline(),
  sources = {
    { name = 'buffer' }
  }
})

-- `:` cmdline setup.
cmp.setup.cmdline(':', {
  mapping = cmp.mapping.preset.cmdline(),
  sources = cmp.config.sources({
    { name = 'path' }
  }, {
    { name = 'cmdline' }
  }),
  matching = { disallow_symbol_nonprefix_matching = false }
})

cmp.setup.filetype({ "dap-repl", "dapui_watches", "dapui_hover" }, {
  sources = cmp.config.sources({
    { name = 'dap' }
  }, {
    { name = 'path' }
  }),
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
    })
  }
})

-- Change the definition of a WORD in vim-wordmotion plugin
vim.g.wordmotion_uppercase_spaces = '[,(){}\\[\\]]'

