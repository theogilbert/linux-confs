local M = {}

local EXPR_BG = "#3A3E5C"
local EXPR_FG = "#9CDCFE"
local SHAPE_FG = "#7F8490"
local PROMPT_LOADING_FG = "#555555"
local BORDER_FG = "#555555"
local ERROR_FG = "#CA2722"
local TYPE_FG = "#8AA1C2"

local function build_highlights()
	return {
		DapDfBorder = { fg = BORDER_FG },
		DapDfError = { fg = ERROR_FG },
		DapDfPrompt = { fg = EXPR_FG, bg = EXPR_BG },
		DapDfPromptShape = { fg = SHAPE_FG, bg = EXPR_BG },
		DapDfPromptLoading = { fg = PROMPT_LOADING_FG, bg = EXPR_BG },
		DapDfHeaderRow = { bold = true },
		DapDfTypeRow = { fg = TYPE_FG },
	}
end

local function setup_highlights()
	M.NS_ID = vim.api.nvim_create_namespace("DapDfNs")

	for group, opts in pairs(build_highlights()) do
		vim.api.nvim_set_hl(M.NS_ID, group, opts)
	end
end

M.setup = function()
	setup_highlights()

	vim.api.nvim_create_autocmd("ColorScheme", {
		callback = setup_highlights,
	})
end

M.setup_static_hl_rules = function(buf_id)
	vim.api.nvim_buf_call(buf_id, function()
		vim.cmd("syntax match TableBorder /[│├┼─┤]/")
	end)
	vim.cmd([[highlight link TableBorder DapDfBorder]])
end

return M
