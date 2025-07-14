local lspconfig = require("lspconfig")

vim.lsp.handlers["textDocument/publishDiagnostics"] = vim.lsp.with(vim.lsp.diagnostic.on_publish_diagnostics, {
	virtual_text = true,
	underline = true,
	signs = true,
})
vim.lsp.handlers["textDocument/hover"] = vim.lsp.with(vim.lsp.handlers.hover, { focusable = false })

local cursorHoverGroup = vim.api.nvim_create_augroup("CursorHover", {})

vim.api.nvim_clear_autocmds({ group = cursorHoverGroup })
vim.api.nvim_create_autocmd({ "CursorHoldI" }, {
	pattern = { "*.py" },
	group = cursorHoverGroup,
	callback = function(_)
            vim.lsp.buf.signature_help({focusable= false, anchor_bias= "above"})
	end,
})

vim.keymap.set("n", "K", function()
    local buf = vim.api.nvim_get_current_buf()
    local diagnostics = vim.diagnostic.get(buf, { lnum = vim.api.nvim_win_get_cursor(0)[1] - 1 })

    if vim.tbl_isempty(diagnostics) then
        -- No diagnostics, just show hover
        vim.lsp.buf.hover()
    else
        -- Capture LSP hover text
        vim.lsp.buf_request(buf, "textDocument/hover", vim.lsp.util.make_position_params(), function(_, result)
            -- Show both hover and diagnostics in one window
            local contents = {}

            if result and result.contents then
                local hover_text = vim.lsp.util.convert_input_to_markdown_lines(result.contents)
                vim.list_extend(contents, hover_text)
            end

            -- Add a separator
            table.insert(contents, " ")

            -- Add diagnostics
            for _, diag in ipairs(diagnostics) do
                table.insert(contents, " " .. diag.message) -- Add a warning icon (nerdfont required)
            end

            -- Show everything in a floating window
            vim.lsp.util.open_floating_preview(contents, "markdown", { border = "rounded" })
        end)
    end
end, { silent = true })

local capabilities = require("cmp_nvim_lsp").default_capabilities()

lspconfig.basedpyright.setup({
	settings = {
		basedpyright = {
			disableOrganizeImports = true, -- Using Ruff
                        typeCheckingMode = "strict",
		},
		python = {
			analysis = {
				ignore = { "*" }, -- Using Ruff
				typeCheckingMode = "on",
			},
		},
	},
	capabilities = capabilities,
})

local augroup = vim.api.nvim_create_augroup("LspFormatting", {})

lspconfig.ruff.setup({
	capabilities = capabilities,
        init_options = {
            settings = {
                ruff = {
                    { codeAction = { disableRuleComment = { enable = false}}}
                }
            }
        },
	on_attach = function(client, bufnr)
		if client.supports_method("textDocument/formatting") then
			vim.api.nvim_clear_autocmds({ group = augroup, buffer = bufnr })
			vim.api.nvim_create_autocmd("BufWritePre", {
				group = augroup,
				buffer = bufnr,
				callback = function()
					vim.lsp.buf.format()
				end,
			})
		end
	end,
})

require('lspconfig')['yamlls'].setup{
    on_attach = on_attach,
    filetypes = { "yaml", "yml" },
    flags = { debounce_test_changes = 150 },
    settings = {
        yaml = {
            format = {
                enable = true,
                singleQuote = true,
                printWidth = 120,
            },
            hover = true,
            completion = true,
            validate = true,
            schemas = {
                [vim.fn.stdpath("data") .. "/schemas/yaml/gitlab-ci.json"] = {
                    "/.gitlab-ci.yml",
                    "/.gitlab-ci.yaml",
                }
            },
        },
    }
}

lspconfig.ts_ls.setup{}
