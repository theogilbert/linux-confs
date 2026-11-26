-- Plugins present here have all been personnally vetted.
--
-- They are not managed by a plugin manager by purpose:
-- I want to be sure what code gets executed on my machine, and I do not want a
-- plugin manager to pull in updates behind my back.

local mini_ai = require('mini.ai')
mini_ai.setup({
    n_lines = 500,
    search_method = 'cover_or_nearest',
    custom_textobjects = {
        c = mini_ai.gen_spec.treesitter({
            a = "@call.outer",
            i = "@call.outer",
        }, {}),
        f = mini_ai.gen_spec.treesitter({
            a = "@function.outer",
            i = "@function.inner",
        }, {}),
        C = mini_ai.gen_spec.treesitter({
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

require("mini.surround").setup({
  mappings = {
    add = 'ma', -- Add surrounding in Normal and Visual modes
    delete = 'md', -- Delete surrounding
    replace = 'ms', -- Replace surrounding
    find = 'mf', -- Find surrounding (to the right)
    find_left = '', -- Disable Find surrounding (to the left)
    highlight = '', -- Disable Highlight surrounding
    update_n_lines = '', -- Disable Update `n_lines`
  },
  search_method = 'cover_or_nearest',
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
vim.g.sonokai_colors_override = { bg0 = { '#262626', '235' } }
vim.g.sonokai_disable_terminal_colors = 1 -- keep the terminal emulator palette in :terminal (e.g. lazygit)
vim.cmd.colorscheme("sonokai")

-- fzf-lua
require("fzf-lua").setup({
	desc = "Custom FZF profile",
	manpages = { previewer = "man_native" },
	helptags = { previewer = "help_native" },
	winopts = {
		-- sonokai terminal colors are disabled globally (for lazygit), but fzf-lua
		-- renders git icons etc. with plain ANSI colors: give its buffer the sonokai palette.
		on_create = function(e)
			local p = vim.fn["sonokai#get_palette"](vim.g.sonokai_style, vim.g.sonokai_colors_override)
			local ansi = { "black", "red", "green", "yellow", "blue", "purple", "orange", "fg" }
			for i, name in ipairs(ansi) do
				vim.b[e.bufnr]["terminal_color_" .. (i - 1)] = p[name][1]
				vim.b[e.bufnr]["terminal_color_" .. (i + 7)] = p[name][1]
			end
			vim.b[e.bufnr].terminal_color_8 = p.grey[1]
		end,
	},
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
})
require('suit').setup({
    input = {
        border = 'rounded'
    },
    select = {
        border = 'rounded',
        max_width = 90,
    }
})

-- Which key
local wk = require("which-key")
wk.setup({
    preset = "helix",
})
-- Group names. A group without `mode` is a normal-mode one only, so the
-- prefixes that also have visual-mode keys say so.
wk.add({
	{ "<leader>s", group = "[S]earch", mode = { "n", "v" } },
	{ "<leader>sv", group = "[S]earch in [V]im" },
	{ "<leader>sf", group = "[S]earch in [F]ile" },
	{ "<leader>sl", group = "[S]earch in [L]SP" },
	{ "<leader>sw", group = "[S]earch in [W]orkspace" },
	{ "<leader>sG", group = "[S]earch in [G]it" },
	{ "<leader>sd", group = "[S]earch in [D]ebugger" },
	{ "<leader>g", group = "[G]it", mode = { "n", "v" } },
	{ "<leader>e", group = "File [E]xplorer" },
	{ "<leader>O", group = "Toggle [O]ptions" },
	{ "<leader>d", group = "[D]ebugger", mode = { "n", "v" } },
	{ "<leader>dp", group = "[D]ebugger [P]anes" },
	{ "<leader>l", group = "[L]SP" },
	{ "<leader>t", group = "[T]ests" },
	{ "<leader>v", group = "[V]im", mode = { "n", "v" } },
	{ "<leader>vs", group = "[V]im [S]essions" },
	{ "<leader>S", group = "[S]cratch files" },
	{ "<leader>b", group = "Data[b]ase", mode = { "n", "v" } },
	{ "<leader>m", group = "[M]erge requests and issues", mode = { "n", "v" } },
	{ "<leader>mo", group = "[O]pen by number" },
	{ "<leader>F", group = "[F]astAPI" },
})
-- uatis binds <leader>x… in a conflicted file while its conflict review
-- is on, and nowhere else. The group is added per buffer as one joins
-- the review (which-key reads `cond` once at load, not when the popup
-- opens); once the keys are gone a group with nothing under it is not
-- shown, so there is nothing to take back.
vim.api.nvim_create_autocmd("User", {
	pattern = "UatisConflictAttach",
	callback = function(ev)
		if not vim.b[ev.data.buf].uatis_wk_group then
			vim.b[ev.data.buf].uatis_wk_group = true
			wk.add({ { "<leader>x", desc = "Conflict resolution operations", buffer = ev.data.buf } })
		end
	end,
})

-- Dotfiles hidden by default (toggle with H).
-- Git-ignored files are shown (toggle with I), their names colored (see highlights.lua).
require("nvim-tree").setup({
    -- Default mappings, plus fold-style zo/zc/zO/zC/zR/zM on directories.
    on_attach = function(bufnr)
        local api = require("nvim-tree.api")
        api.config.mappings.default_on_attach(bufnr)

        local function map(lhs, fn, desc)
            vim.keymap.set("n", lhs, fn, { buffer = bufnr, nowait = true, silent = true, desc = "nvim-tree: " .. desc })
        end
        local function is_dir(node) return node and node.nodes ~= nil end

        map("zo", function()
            local node = api.tree.get_node_under_cursor()
            if is_dir(node) and not node.open then api.node.open.edit(node) end
        end, "Open directory")
        map("zc", function()
            local node = api.tree.get_node_under_cursor()
            if not node or node.name == ".." then return end -- root line: don't cd up
            if is_dir(node) and node.open then
                api.node.open.edit(node)
            else
                api.node.navigate.parent_close(node)
            end
        end, "Close directory")
        map("zO", function() api.node.expand() end, "Open directory recursively")
        map("zC", function() api.node.collapse() end, "Close directory recursively")
        map("zR", function() api.tree.expand_all() end, "Open all")
        map("zM", function() api.tree.collapse_all() end, "Close all")
    end,
    filters = { dotfiles = true, git_ignored = false },
    renderer = {
        highlight_git = "name",
        highlight_hidden = "name",
        -- New and staged files are already identified by their name color.
        icons = { glyphs = { git = { untracked = "", staged = "" } } },
    },
})


require("neotest").setup({
	adapters = {
		require("neotest-python")({
			dap = { justMyCode = false },
		}),
	},
})


require("sections").setup({})
require("utilities.scratch").setup()
require("utilities.tabs").setup()

require("flash").setup({
    modes = { char = { enabled = false } }
})

require("grannos").setup({
    server_cmd = "grannos --log -v"
})

-- The reader: the current file as it reads (markdown today), on and off.
-- The reader's winbar says READER while it is up.
require("render").setup({
    keys = { toggle = "<leader>Or" },
})

local uatis = require("uatis")

require("nemeton").setup({
    -- Over OSC 52 rather than into `+`: a link is copied to be pasted
    -- somewhere on the physical machine, whichever backend `+` is on.
    -- Every link nemeton copies -- <leader>mL, and what <C-]> falls
    -- back to on a page, an issue, a merge request -- goes this way.
    clipboard = function(text)
        require("utilities.clipboard").osc52_send({ text })
    end,
    comments = {
        follow = {
            commit = uatis.show_commit,
        },
        -- Where the two plugins meet, and the only place that knows
        -- both are installed. uatis says which buffer is showing which
        -- side of the comparison; nemeton wants that for the one thing
        -- it cannot do on its own -- commenting on a line the branch
        -- deleted, which exists in no buffer but the old-revision
        -- window.
        old_side = function(bufnr)
            local at = uatis.showing(bufnr)
            if at and at.side == "old" then
                return { path = at.path, sha = at.rev }
            end
        end,
    }
})

require("fastapi").setup({
    lens = { position = "eol" }
})
