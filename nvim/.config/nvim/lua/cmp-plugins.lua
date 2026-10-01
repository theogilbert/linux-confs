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
                return vim.bo[0].buftype ~= "prompt" or require("cmp_dap").is_dap_buffer()
	end,
        formatting = {
            format = function (entry, vim_item)
                -- grannos puts the column type and its owning alias in the menu
                -- column, which is the point of the entry -- keep it.
                if entry.source.name == "grannos" then
                    return vim_item
                end
                if vim_item.menu ~= nil and not vim_item.menu:match('^ *%(import .*') then
                    vim_item.menu = nil
                end
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
                    max_item_count = 20,
                },
		{ name = "path", max_item_count = 10 },
		{ name = "grannos" },
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
                    winhighlight = 'Normal:FloatBorder,CursorLine:Visual'
                }),
		documentation = cmp.config.window.bordered({
                    max_height=15,
                    max_width=88,
                    winhighlight = 'Normal:FloatBorder'
                }),
	},
})


local function text_before_cursor()
	if vim.fn.mode() == "c" then
		return vim.fn.getcmdline():sub(1, vim.fn.getcmdpos() - 1)
	end
	return vim.api.nvim_get_current_line():sub(1, vim.api.nvim_win_get_cursor(0)[2])
end

-- Confirming an entry edits the buffer, which fires TextChangedI. The timer below
-- would then re-open the menu on the word just accepted, with nothing selected,
-- making the confirm look like it did nothing. Remember where the confirm left
-- the cursor so that this one auto-complete is skipped.
local confirmed_before_cursor = nil
cmp.event:on("confirm_done", function()
	confirmed_before_cursor = text_before_cursor()
end)

-- define a timer to activate delayed auto-complete after 300ms
local cmp_timer = vim.uv.new_timer()
vim.api.nvim_create_autocmd({ "TextChangedI", "CmdlineChanged" }, {
	pattern = "*",
	callback = function()
		cmp_timer:stop()
		cmp_timer:start(
			300,
			0,
			vim.schedule_wrap(function()
				-- Selecting an entry inserts its text, which fires TextChangedI.
				-- Re-triggering completion then would reset the menu and drop the
				-- selection, making <CR> do nothing. cmp already filters an open menu.
				local just_confirmed = text_before_cursor() == confirmed_before_cursor
				confirmed_before_cursor = nil
				if just_confirmed or cmp.visible() then
					return
				end
				cmp.complete({ reason = cmp.ContextReason.Auto })
			end)
		)
	end,
})

-- `/` cmdline setup.
cmp.setup.cmdline("/", {
	mapping = cmp.mapping.preset.cmdline(),
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
	sources = cmp.config.sources({ { name = "dap" } })
})

cmp.event:on("confirm_done", function(evt)
    if vim.bo.filetype ~= "python" then return end
    local item = evt.entry:get_completion_item()
    if item.additionalTextEdits and #item.additionalTextEdits > 0 then
        vim.defer_fn(function() require("lsps").sort_imports() end, 100)
    end
end)
