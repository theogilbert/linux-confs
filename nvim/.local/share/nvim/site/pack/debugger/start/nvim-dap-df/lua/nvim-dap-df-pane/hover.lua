-- Non-focusable hover float. Ported from grannos.nvim's lua/grannos/ui/hover.lua.
local hl = require("nvim-dap-df-pane.hl")

local M = {}

local state = { win = nil }
local NS    = vim.api.nvim_create_namespace("DapDfHover")

--- Close the current hover float if one is open.
function M.close()
	if state.win and vim.api.nvim_win_is_valid(state.win) then
		vim.api.nvim_win_close(state.win, true)
	end
	state.win = nil
end

--- Return true if a hover float is currently visible.
--- @return boolean
function M.is_open()
	return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

--- Open a non-focusable hover float near the cursor displaying `lines`.
--- The float closes automatically when the cursor moves or `source_bufnr` is left.
--- @param lines        string[]  lines to display
--- @param source_bufnr integer   buffer to attach the autoclose autocmd to
--- @param opts table|nil
---   .hls   { [1]: string, [2]: integer, [3]: integer, [4]: integer }[]|nil  positional highlights: { group, row, col_start, col_end }
---   .above boolean|nil         anchor the float above the cursor line (default: below)
function M.open(lines, source_bufnr, opts)
	opts = opts or {}
	M.close()

	local width = 0
	for _, l in ipairs(lines) do width = math.max(width, vim.api.nvim_strwidth(l)) end

	local float_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, lines)
	vim.bo[float_buf].modifiable = false
	if opts.hls then
		for _, h in ipairs(opts.hls) do
			vim.api.nvim_buf_add_highlight(float_buf, NS, h[1], h[2], h[3], h[4])
		end
	end

	local win_opts = {
		relative  = "cursor",
		col       = 0,
		width     = width,
		height    = #lines,
		style     = "minimal",
		border    = "rounded",
		focusable = false,
	}
	if opts.above then
		win_opts.anchor = "SW"
		win_opts.row    = 0
	else
		win_opts.row = 1
	end

	local win = vim.api.nvim_open_win(float_buf, false, win_opts)
	vim.api.nvim_win_set_hl_ns(win, hl.NS_ID)
	state.win = win

	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufLeave" }, {
		buffer   = source_bufnr,
		once     = true,
		callback = function()
			if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
			if state.win == win then state.win = nil end
		end,
	})
end

return M
