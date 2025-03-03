-- [[ Basic Keymaps ]]
--  See `:help vim.keymap.set()`

-- Clear highlights on search when pressing <Esc> in normal mode
--  See `:help hlsearch`
vim.keymap.set("n", "<Esc>", "<cmd>nohlsearch<CR>")

-- If the number column is displayed, hide it and hide the sign column
-- Otherwise, display both.
function toggleGutter()
    isGutterDisplayed = vim.opt.number:get()

    vim.opt.number = not isGutterDisplayed
    vim.opt.signcolumn = isGutterDisplayed and "no" or "yes"
end
vim.keymap.set("n", "<Leader>on", toggleGutter, { desc = "Toggle [O]ption [N]umber" })

function toggleMouse()
    toggledSettings = vim.opt.mouse:get().a and "" or "a"
    vim.opt.mouse = toggledSettings
end
vim.keymap.set("n", "<Leader>om", toggleMouse, { desc = "Toggle [O]ption [M]ouse" })

-- Diagnostic keymaps
--

local fzflua = require("fzf-lua")

vim.keymap.set("n", "<leader>sh", fzflua.helptags, { desc = "[S]earch [H]elp" })
vim.keymap.set("n", "<leader>sk", fzflua.keymaps, { desc = "[S]earch [K]eymaps" })
vim.keymap.set("n", "<leader>sW", fzflua.grep_cWORD, { desc = "[S]earch current [W]ord" })
vim.keymap.set("n", "<leader>sg", fzflua.live_grep, { desc = "[S]earch by [G]rep" })
vim.keymap.set("n", "<leader>sr", fzflua.oldfiles, { desc = '[S]earch Recent Files ("." for repeat)' })
vim.keymap.set("n", "<leader>sb", fzflua.buffers, { desc = "[S]earch [O]pen buffers" })
vim.keymap.set("n", "<leader>ss", fzflua.lsp_live_workspace_symbols, { desc = "[S]earch [S]ymbols" })
vim.keymap.set("n", "<leader>sc", function()
	fzflua.lsp_live_workspace_symbols({ fzf_opts = { ["--query"] = "!Class" } })
end, { desc = "[S]earch [C]lasses" })

vim.keymap.set("n", "<leader>sli", fzflua.lsp_incoming_calls, { desc = "[S]earch [L]SP [I]ncoming files" })
vim.keymap.set("n", "<leader>sla", fzflua.lsp_code_actions, { desc = "[S]earch [L]SP code [A]ctions" })
vim.keymap.set("n", "<leader>q", fzflua.lsp_code_actions, { desc = "Open diagnostic [Q]uickfix list" })

vim.keymap.set("n", "<leader>sfd", fzflua.lsp_document_diagnostics, { desc = "[S]earch [F]ile [D]iagnostics" })
vim.keymap.set("n", "<leader>sfs", fzflua.lsp_document_symbols, { desc = "[S]earch [F]ile [S]ymbols" })

vim.keymap.set("n", "<leader>swd", fzflua.lsp_workspace_diagnostics, { desc = "[S]earch [W]orkspace [D]iagnostics" })
vim.keymap.set("n", "<leader>swf", fzflua.files, { desc = "[S]earch [Workspace] [F]iles" })

local api = require("nvim-tree.api")

function focus_current_file()
	api.tree.open({ find_file = true })
end

vim.keymap.set("n", "<leader>et", api.tree.toggle, { desc = "File [E]xplorer - [T]oggle" })
vim.keymap.set("n", "<leader>ef", api.tree.open, { desc = "File [E]xplorer - [F]ocus" })
vim.keymap.set("n", "<leader>er", api.tree.reload, { desc = "File [E]xplorer - [R]eload" })
vim.keymap.set("n", "<leader>ec", focus_current_file, { desc = "File [E]xplorer - Focus [C]urrent file" })

local dap = require("dap")
vim.keymap.set("n", "<leader>db", dap.toggle_breakpoint, { desc = "Toggle [B]reakpoint" })
vim.keymap.set("n", "<leader>dc", dap.continue, { desc = "[C]ontinue" })
vim.keymap.set("n", "<leader>dT", dap.terminate, { desc = "[T]erminate" })
vim.keymap.set("n", "<leader>dl", dap.list_breakpoints, { desc = "[L]ist breakpoints" })
vim.keymap.set("n", "<leader>dC", dap.clear_breakpoints, { desc = "[C]lear breakpoints" })
vim.keymap.set("n", "<leader>ds", dap.step_over, { desc = "[S]tep over" })
vim.keymap.set("n", "<leader>di", dap.step_into, { desc = "[S]tep into" })
vim.keymap.set("n", "<leader>dr", dap.repl.toggle, { desc = "Toggle [R]EPL" })
vim.keymap.set("n", "<leader>dt", dap.run_to_cursor, { desc = "Run [t]o cursor" })
vim.keymap.set("n", "<leader>du", dap.up, { desc = "Move [U]p the stack" })
vim.keymap.set("n", "<leader>dd", dap.down, { desc = "Move [D]own the stack" })
vim.keymap.set({'n', 'v'}, '<Leader>dh', function()
  require('dap.ui.widgets').hover()
end, { desc = "[H]over variable" })
vim.keymap.set({'n', 'v'}, '<Leader>dp', function()
  require('dap.ui.widgets').preview()
end, { desc = "[P]review expression" })
vim.keymap.set('n', '<Leader>df', function()
  local widgets = require('dap.ui.widgets')
  widgets.centered_float(widgets.frames)
end, { desc = "View Stack[F]rame" })
vim.keymap.set('n', '<Leader>ds', function()
  local widgets = require('dap.ui.widgets')
  widgets.centered_float(widgets.scopes)
end, { desc = "View variables in [S]cope" })
