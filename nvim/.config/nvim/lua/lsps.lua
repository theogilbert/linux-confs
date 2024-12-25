local capabilities = require("cmp_nvim_lsp").default_capabilities()

-- TODO update this so that it only applies on python files
require("lspconfig").pyright.setup({
	settings = {
		pyright = {
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
