-- Highlight groups and namespaces. Palette shared with grannos.nvim's results pane.
local M = {}

local EXPR_BG = "#3A3E5C"
local EXPR_FG = "#9CDCFE"
local SHAPE_FG = "#7F8490"
local PROMPT_LOADING_FG = "#555555"
local BORDER_FG = "#555555"
local HEADER_FG = "#9CDCFE"
local ERROR_FG = "#CA2722"
local TYPE_FG = "#8AA1C2"
local FILTER_FG = "#e78a4e"
local SORTED_COL_FG = "#b8bb26"
local TRUNCATED_FG = "#666666"
local NULL_FG = "#6B7280"
local THOUSANDS_FG = "#767676"
local SHOWN_FG = "#98C379"

local function build_highlights()
	return {
		DapDfBorder = { fg = BORDER_FG },
		DapDfError = { fg = ERROR_FG },
		DapDfPrompt = { fg = EXPR_FG, bg = EXPR_BG },
		DapDfPromptShape = { fg = SHAPE_FG, bg = EXPR_BG },
		DapDfPromptLoading = { fg = PROMPT_LOADING_FG, bg = EXPR_BG },
		DapDfHeaderRow = { fg = HEADER_FG, bold = true },
		DapDfTypeRow = { fg = TYPE_FG },
		DapDfFilterRow = { fg = FILTER_FG, italic = true },
		DapDfSortedColumn = { fg = SORTED_COL_FG, bold = true },
		DapDfTruncated = { fg = TRUNCATED_FG, bold = true },
		DapDfNull = { fg = NULL_FG, italic = true },
		DapDfThousandsSeparator = { fg = THOUSANDS_FG },
		DapDfColumnShown = { fg = SHOWN_FG }, -- column picker: mark beside a shown column
		DapDfColumnHidden = { fg = NULL_FG }, -- column picker: a hidden column and its mark
	}
end

local function setup_highlights()
	M.NS_ID = vim.api.nvim_create_namespace("DapDfNs")
	M.TRUNCATION_NS_ID = vim.api.nvim_create_namespace("DapDfTruncationNs")

	for group, opts in pairs(build_highlights()) do
		vim.api.nvim_set_hl(M.NS_ID, group, opts)
	end
end

-- Namespaces exist as soon as the module loads, so buffers and floats created
-- before setup() still have one to attach to.
setup_highlights()

M.setup = function()
	setup_highlights()

	vim.api.nvim_create_autocmd("ColorScheme", {
		callback = setup_highlights,
	})
end

return M
