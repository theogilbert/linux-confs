vim.lsp.handlers["textDocument/publishDiagnostics"] = vim.lsp.with(vim.lsp.diagnostic.on_publish_diagnostics, {
	virtual_text = false,
	underline = true,
	signs = true,
})

local diagnosticHoverGroup = vim.api.nvim_create_augroup("DiagnosticHover", {})
vim.api.nvim_clear_autocmds({ group = diagnosticHoverGroup })
vim.api.nvim_create_autocmd({ "CursorHold" }, {
	pattern = { "*.py" },
	group = diagnosticHoverGroup,
	callback = function(_)
		vim.diagnostic.open_float()
	end,
})
vim.api.nvim_create_autocmd({ "CursorHoldI" }, {
	pattern = { "*.py" },
	group = diagnosticHoverGroup,
	callback = function(_)
		vim.lsp.buf.signature_help()
	end,
})

local capabilities = require("cmp_nvim_lsp").default_capabilities()

-- TODO update this so that it only applies on python files
require("lspconfig").basedpyright.setup({
	settings = {
		basedpyright = {
			disableOrganizeImports = true, -- Using Ruff
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

require("lspconfig").ruff.setup({
	trace = "verbose",
	capabilities = capabilities,
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
