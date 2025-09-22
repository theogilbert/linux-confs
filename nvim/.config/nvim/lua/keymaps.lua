-- [[ Basic Keymaps ]]
--  See `:help vim.keymap.set()`

-- Clear highlights on search when pressing <Esc> in normal mode
--  See `:help hlsearch`
vim.keymap.set("n", "<Esc>", "<cmd>nohlsearch<CR>")

vim.keymap.set("n", "<leader>f", function()
    win_list = vim.api.nvim_list_wins()
    for idx = #win_list, 1, -1 do
        win_handle = win_list[idx]
        win_cfg = vim.api.nvim_win_get_config(win_handle)
        if win_cfg.relative ~= '' then
            vim.api.nvim_set_current_win(win_handle)
            break
        end
    end

end, { desc = "[F]ocus floating window" })

-- If the number column is displayed, hide it and hide the sign column
-- Otherwise, display both.
function toggleGutter()
	isGutterDisplayed = vim.opt.number:get()

	vim.opt.number = not isGutterDisplayed
	vim.opt.signcolumn = isGutterDisplayed and "no" or "yes"
end
vim.keymap.set("n", "<Leader>On", toggleGutter, { desc = "Toggle [O]ption [N]umber" })

function toggleMouse()
	toggledSettings = vim.opt.mouse:get().a and "" or "a"
	vim.opt.mouse = toggledSettings
end
vim.keymap.set("n", "<Leader>Om", toggleMouse, { desc = "Toggle [O]ption [M]ouse" })

vim.keymap.set("n", "<Leader>m", function()
	vim.cmd("MaximizerToggle!")
end, { desc = "Toggle [M]aximize the window" })
-- Diagnostic keymaps
--

local fzflua = require("fzf-lua")

vim.keymap.set("n", "<leader>svh", fzflua.helptags, { desc = "[S]earch [V]im [H]elp" })
vim.keymap.set("n", "<leader>svk", fzflua.keymaps, { desc = "[S]earch [V]im [K]eymaps" })

vim.keymap.set("n", "<leader>sW", fzflua.grep_cWORD, { desc = "[S]earch current [W]ord" })
vim.keymap.set("n", "<leader>sg", fzflua.live_grep, { desc = "[S]earch by [G]rep" })
vim.keymap.set("n", "<leader>sr", fzflua.oldfiles, { desc = '[S]earch Recent Files ("." for repeat)' })
vim.keymap.set("n", "<leader>sb", fzflua.buffers, { desc = "[S]earch [O]pen buffers" })

vim.keymap.set("n", "<leader>sli", fzflua.lsp_incoming_calls, { desc = "[S]earch [L]SP [I]ncoming files" })


local lsp_settings = require("lsps")

vim.keymap.set("n", "<leader>q", lsp_settings.run_code_actions, { desc = "Open diagnostic [Q]uickfix list" })

vim.keymap.set("n", "<leader>sfd", fzflua.lsp_document_diagnostics, { desc = "[S]earch [F]ile [D]iagnostics" })
vim.keymap.set("n", "<leader>sfs", fzflua.lsp_document_symbols, { desc = "[S]earch [F]ile [S]ymbols" })

vim.keymap.set("n", "<leader>swd", fzflua.lsp_workspace_diagnostics, { desc = "[S]earch [W]orkspace [D]iagnostics" })
vim.keymap.set("n", "<leader>sws", fzflua.lsp_live_workspace_symbols, { desc = "[S]earch [W]orkspace [S]ymbols" })
vim.keymap.set("n", "<leader>k", fzflua.lsp_live_workspace_symbols, { desc = "Search Workspace Symbols" })
vim.keymap.set("n", "<leader>swf", fzflua.files, { desc = "[S]earch [W]orkspace [F]iles" })
vim.keymap.set("n", "<leader>o", fzflua.files, { desc = "Search Workspace Files" })

vim.keymap.set("n", "<leader>sGc", fzflua.git_bcommits, { desc = "[S]earch [G]it buffer [C]ommits" })
vim.keymap.set("n", "<leader>sGb", fzflua.git_blame, { desc = "[S]earch [G]it buffer [B]lame" })

local session = require("session")
vim.keymap.set("n", "<leader>vsl", session.try_load_session, { desc = "[v]im [s]ession - [l]oad" })
vim.keymap.set("n", "<leader>vsc", session.reset_session, { desc = "[v]im [s]ession - [c]lear session" })

vim.keymap.set("v", "<leader>vS", function()
  -- Substitute selected text in the whole buffer
  vim.cmd('normal! "vy')
  local escaped = vim.fn.escape(vim.fn.getreg("v"), [[\/]])
  vim.api.nvim_feedkeys(":%s/" .. escaped .. "/", "t", false)
end, { desc = "[v]im [s]ubstitute selection" })

local neotest = require("neotest")

vim.keymap.set("n", "<leader>tr", function()
	neotest.run.run({ extra_args = { "-vv" } })
end, { desc = "[T]ests - [R]un Nearest" })
vim.keymap.set("n", "<leader>tl", function()
	neotest.run.run_last()
end, { desc = "[T]ests - Run [L]ast" })
vim.keymap.set("n", "<leader>ta", function()
	neotest.run.run(vim.fn.expand("%"))
end, { desc = "[t]ests - run [a]ll in file" })
vim.keymap.set("n", "<leader>tw", function()
	neotest.run.run({ suite = true })
	neotest.summary.open()
end, { desc = "[t]ests - run all in [w]orkspace" })
vim.keymap.set("n", "<leader>td", function()
	neotest.run.run({ strategy = "dap" })
end, { desc = "[T]ests - [D]ebug Nearest" })
vim.keymap.set("n", "<leader>to", function()
	neotest.output_panel.toggle()
end, { desc = "[T]ests - Toggle [O]utput" })
vim.keymap.set("n", "<leader>ts", function()
    neotest.summary.toggle()
end, { desc = "[T]ests - Toggle [S]ummary" })
vim.keymap.set("n", "<leader>tp", function()
	neotest.jump.prev({ status = "failed" })
end, { desc = "[T]ests - [P]revious failed test" })
vim.keymap.set("n", "<leader>tn", function()
	neotest.jump.next({ status = "failed" })
end, { desc = "[T]ests - [N]ext failed test" })
vim.keymap.set("n", "<leader>tT", function()
	neotest.run.stop()
end, { desc = "[T]ests - [T]erminate test session" })

local api = require("nvim-tree.api")

function focus_current_file()
	api.tree.open({ find_file = true })
end

vim.keymap.set("n", "<leader>et", function()
    api.tree.toggle({ find_file = true })
end, { desc = "File [E]xplorer - [T]oggle" })
vim.keymap.set("n", "<leader>ef", api.tree.open, { desc = "File [E]xplorer - [F]ocus" })
vim.keymap.set("n", "<leader>er", api.tree.reload, { desc = "File [E]xplorer - [R]eload" })
vim.keymap.set("n", "<leader>ec", focus_current_file, { desc = "File [E]xplorer - Focus [C]urrent file" })

vim.keymap.set("n", "<leader>lR", function()
	vim.cmd("LspRestart")
end, { desc = "[L]SP - [R]estart" })
vim.keymap.set("n", "<leader>lr", vim.lsp.buf.rename, { desc = "[L]SP - [R]ename symbol under cursor" })

local dap = require("dap")
local dapui = require("dapui")
local dap_settings = require("dap-plugins")
vim.keymap.set("n", "<leader>db", dap.toggle_breakpoint, { desc = "Toggle [B]reakpoint" })
vim.keymap.set("n", "<leader>do", function()
	vim.ui.input({ prompt = "Break condition: " }, function(input)
		dap.toggle_breakpoint(input)
	end)
end, { desc = "Toggle C[o]nditional breakpoint" })
vim.keymap.set("n", "<leader>dU", dapui.toggle, { desc = "Toggle DAP [U]I" })
vim.keymap.set("n", "<leader>dr", dap.continue, { desc = "[R]un / continue" })
vim.keymap.set("n", "<leader>dR", dap.restart, { desc = "[R]estart" })
vim.keymap.set("n", "<leader>dl", dap.run_last, { desc = "[R]un last" })
vim.keymap.set("n", "<leader>dT", dap.terminate, { desc = "[T]erminate" })
vim.keymap.set("n", "<leader>dE", dap.clear_breakpoints, { desc = "[E]rase breakpoints" })
vim.keymap.set("n", "<leader>dn", dap.step_over, { desc = "[N]ext line (step over)" })
vim.keymap.set("n", "<leader>di", dap.step_into, { desc = "[S]tep [i]nto" })
vim.keymap.set("n", "<leader>do", dap.step_out, { desc = "[S]tep [o]ut" })
vim.keymap.set("n", "<leader>dt", dap.run_to_cursor, { desc = "Run [t]o cursor" })
vim.keymap.set("n", "<leader>du", dap.up, { desc = "Move [U]p the stack" })
vim.keymap.set("n", "<leader>dd", dap.down, { desc = "Move [D]own the stack" })
vim.keymap.set({"n", "v"}, "<leader>de", dapui.eval, { desc = "[E]valuate expression" })
vim.keymap.set("n", "<leader>dc", dap.focus_frame, { desc = "Focus [c]urrent frame" })

vim.keymap.set("n", "<leader>dpv", dap_settings.show_scopes_pane, { desc = "Show [D]AP [p]ane - [v]ariables" })
vim.keymap.set("n", "<leader>dpw", dap_settings.show_watches_pane, { desc = "Show [D]AP [p]ane - [w]atches" })
vim.keymap.set("n", "<leader>dps", dap_settings.show_stacks_pane, { desc = "Show [D]AP [p]ane - [s]tack" })
vim.keymap.set("n", "<leader>dpr", dap_settings.show_repl_pane, { desc = "Show [D]AP [p]ane - [r]epl" })
vim.keymap.set("n", "<leader>dpb", dap_settings.show_breakpoints_pane, { desc = "Show [D]AP [p]ane - [b]reakpoints" })
vim.keymap.set("n", "<leader>dpd", function() require('nvim-dap-df-pane').toggle() end, { desc = "Toggle [D]AP [p]ane - [d]ataframe" })

local gitsigns = require('gitsigns')
vim.keymap.set({ "n", "v" }, "<leader>gd", gitsigns.preview_hunk_inline, { desc = "[G]it - View chunk [d]ifference" })
vim.keymap.set({ "n", "v" }, "<leader>gD", ":DiffviewOpen ", { noremap = true, silent = false, desc = "[G]it - Open [d]iffview" })
vim.keymap.set({ "n", "v" }, "<leader>gH", ":DiffviewFileHistory ", { noremap = true, silent = false, desc = "[G]it - Open file [h]istory" })
vim.keymap.set({ "n", "v" }, "<leader>gs", gitsigns.stage_hunk, { desc = "[G]it - [s]tage chunk" })
vim.keymap.set({ "n", "v" }, "<leader>gr", gitsigns.reset_hunk, { desc = "[G]it - [r]eset chunk" })
vim.keymap.set({ "n", "v" }, "<leader>gb", function()
    gitsigns.blame_line({ full  = true })
end, { desc = "[G]it - View line [b]lame" })

vim.keymap.set("n", "]c", function()
    if vim.wo.diff then
        vim.cmd.normal({']c', bang = true})
    else
        gitsigns.nav_hunk('next')
    end
end, { desc = "Go to next [c]hunk" })
vim.keymap.set("n", "[c", function()
    if vim.wo.diff then
        vim.cmd.normal({'[c', bang = true})
    else
        gitsigns.nav_hunk('prev')
    end
end, { desc = "Go to previous [c]hunk" })

local terminal_utils = require("utilities.terminal")
vim.keymap.set({ "v" }, "<leader>p", terminal_utils.send_sel_to_terminal, { desc = "[P]ush selection to terminal" })

local scratch_utils = require("utilities.scratch")
vim.keymap.set({ "n" }, "<leader>Sn", scratch_utils.prompt_new_file, { desc = "Open [p]rompt to create a new scratch file" })
vim.keymap.set({ "n" }, "<leader>So", scratch_utils.search_scratches, { desc = "[O]pen a new scratch file" })

local sections = require("sections")
vim.keymap.set({ "n" }, "<leader>n", sections.toggle, { desc = "Toggle file sections pane" })
vim.keymap.set({ "n" }, "<leader>N", sections.focus, { desc = "Focus sections pane" })
