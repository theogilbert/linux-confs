local cmp = require("cmp")
local types = require("cmp.types")

local function deprioritize_private(entry1, entry2)
    local function private_level(entry)
        if vim.bo.filetype ~= "python" then
            return 0
        end

        if string.sub(entry.completion_item.label, 1, 2) == "__" then
            return 2
        elseif string.sub(entry.completion_item.label, 1, 1) == "_" then
            return 1
        end

        return 0
    end

    local level_1 = private_level(entry1)
    local level_2 = private_level(entry2)

    if level_1 == level_2 then
        return nil
    end

    return level_1 < level_2
end

local custom_kind_priority = {
    [types.lsp.CompletionItemKind.Snippet] = 0,
    [types.lsp.CompletionItemKind.Keyword] = 0,
    [types.lsp.CompletionItemKind.EnumMember] = 1,
    [types.lsp.CompletionItemKind.Module] = 2,
    [types.lsp.CompletionItemKind.Method] = 3,
    [types.lsp.CompletionItemKind.Variable] = 3,
    [types.lsp.CompletionItemKind.Text] = 100,
}

local function custom_lsp_kind_comparator(entry1, entry2)
    local function custom_lsp_kind(kind)
        return custom_kind_priority[kind] or kind
    end

    local kind1 = custom_lsp_kind(entry1:get_kind())
    local kind2 = custom_lsp_kind(entry2:get_kind())

    if kind1 == kind2 then
        return nil
    else
        return kind1 < kind2
    end
end

-- We do not want auto-completion to propose private or protected attributes,
-- unless we started typing __ or _.
local function filter_out_private_python_attributes(entry, ctx)
    if vim.bo.filetype ~= 'python' then
        return true  -- This logic only applies to Python scripts
    end

    local typed = ctx.cursor_before_line:match("%S+$") or ""
    local label = entry:get_completion_item().label

    if label:sub(1, 2) == "__" and not typed:match("__$") then
        return false
    elseif label:sub(1, 1) == "_" and not typed:match("_$") then
        return false
    end

    return true
end

-- TODO:
-- https://www.reddit.com/r/neovim/comments/tsq4z8/completion_with_nvimcmp_for_daprepl/
-- https://github.com/rcarriga/cmp-dap/tree/master
-- setlocal completeopt=menuone,popup,noinsert
cmp.setup({
	enabled = function()
                return vim.api.nvim_buf_get_option(0, "buftype") ~= "prompt" or require("cmp_dap").is_dap_buffer()
	end,
        formatting = {
            format = function (entry, vim_item)
                vim_item.menu = nil
                return vim_item
            end
        },
	preselect = cmp.PreselectMode.None,
	snippet = {
		expand = function(args)
                    vim.snippet.expand(args.body) -- For native neovim snippets (Neovim v0.10+)
		end,
	},
	mapping = cmp.mapping.preset.insert({
		["<C-b>"] = cmp.mapping.scroll_docs(-4),
		["<C-f>"] = cmp.mapping.scroll_docs(4),
		["<C-Space>"] = cmp.mapping.complete(),
                ["<Tab>"] = cmp.mapping.select_next_item(),
                ["<S-Tab>"] = cmp.mapping.select_prev_item(),
		["<C-e>"] = cmp.mapping.abort(),
		["<CR>"] = cmp.mapping.confirm({ select = false }),
	}),
	matching = { disallow_fuzzy_matching = false },
	sources = cmp.config.sources({
		{ name = "nvim_lsp_signature_help" },
                {
                    name = "nvim_lsp",
                    entry_filter = filter_out_private_python_attributes,
                },
		{ name = "path" },
		{ name = "buffer" },
	}),
	completion = {
		autocomplete = false,
	},
	sorting = {
            comparators = {
                cmp.config.compare.exact,
                cmp.config.compare.offset,
                cmp.config.compare.score,
                cmp.config.compare.recently_used,
                deprioritize_private,
                custom_lsp_kind_comparator,
                cmp.config.compare.length,
            },
	},
	window = {
		completion = cmp.config.window.bordered({
                    max_height = 10,
                    winhighlight = 'Normal:FloatBorder'
                }),
		documentation = cmp.config.window.bordered({
                    max_height=15,
                    max_width=88,
                    winhighlight = 'Normal:FloatBorder'
                }),
	},
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
		cmp_timer:start(
			300,
			0,
			vim.schedule_wrap(function()
				cmp.complete({ reason = cmp.ContextReason.Auto })
			end)
		)
	end,
})

-- `/` cmdline setup.
cmp.setup.cmdline("/", {
	mapping = cmp.mapping.preset.cmdline(),
	sources = {
		{ name = "buffer" },
	},
})

-- `:` cmdline setup.
cmp.setup.cmdline(":", {
	mapping = cmp.mapping.preset.cmdline(),
	sources = cmp.config.sources({
            { name = "path", option = { trailing_slash = true } },
            { name = "cmdline" },
	}),
	matching = { disallow_symbol_nonprefix_matching = false },
})

cmp.setup.filetype({ "dap-repl", "dapui_watches", "dapui_hover", "dapui_dataframe" }, {
	sources = cmp.config.sources({
		{ name = "dap" },
	}, {
		{ name = "path" },
	}),
})
