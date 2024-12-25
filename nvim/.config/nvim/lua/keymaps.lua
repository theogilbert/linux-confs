-- [[ Basic Keymaps ]]
--  See `:help vim.keymap.set()`

-- Clear highlights on search when pressing <Esc> in normal mode
--  See `:help hlsearch`
vim.keymap.set("n", "<Esc>", "<cmd>nohlsearch<CR>")

-- Diagnostic keymaps
--
vim.keymap.set("n", "<leader>q", function()
	vim.lsp.buf.code_action({ only = { "quickfix" } })
end, { desc = "Open diagnostic [Q]uickfix list" })

local fzflua = require("fzf-lua")

vim.keymap.set("n", "<leader>sh", fzflua.helptags, { desc = "[S]earch [H]elp" })
vim.keymap.set("n", "<leader>sk", fzflua.keymaps, { desc = "[S]earch [K]eymaps" })
vim.keymap.set("n", "<leader>sf", fzflua.files, { desc = "[S]earch [F]iles" })
vim.keymap.set("n", "<leader>sW", fzflua.grep_cWORD, { desc = "[S]earch current [W]ord" })
vim.keymap.set("n", "<leader>sg", fzflua.live_grep, { desc = "[S]earch by [G]rep" })
vim.keymap.set("n", "<leader>sr", fzflua.oldfiles, { desc = '[S]earch Recent Files ("." for repeat)' })
vim.keymap.set("n", "<leader>so", fzflua.buffers, { desc = "[S]earch [O]pen buffers" })
vim.keymap.set("n", "<leader>ss", fzflua.lsp_live_workspace_symbols, { desc = "[S]earch [S]ymbols" })
vim.keymap.set("n", "<leader>sc", function()
	fzflua.lsp_live_workspace_symbols({ fzf_opts = { ["--query"] = "!Class" } })
end, { desc = "[S]earch [C]lasses" })

vim.keymap.set("n", "<leader>sli", fzflua.lsp_incoming_calls, { desc = "[S]earch [L]SP [I]ncoming files" })

vim.keymap.set("n", "<leader>sfd", fzflua.lsp_document_diagnostics, { desc = "[S]earch [F]ile [D]iagnostics" })
vim.keymap.set("n", "<leader>sfs", fzflua.lsp_document_symbols, { desc = "[S]earch [F]ile [S]ymbols" })

vim.keymap.set("n", "<leader>swd", fzflua.lsp_workspace_diagnostics, { desc = "[S]earch [W]orkspace [D]iagnostics" })
