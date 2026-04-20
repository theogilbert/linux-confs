local DataView = require("nvim-dap-df-pane.dataview")
local Expression = require("nvim-dap-df-pane.expression")
local Buffer = require("nvim-dap-df-pane.buffer")
local prompt = require("nvim-dap-df-pane.prompt")
local help = require("nvim-dap-df-pane.help")
local hl = require("nvim-dap-df-pane.hl")

local Pane = {}
Pane.__index = Pane

-- Constructor
-- @param config table Plugin configuration
-- @param pane_idx number Index used in the buffer name
-- @param opts table|nil Optional callbacks:
--   - on_split: function(pane) called when the user presses 'v' to split
--   - on_close: function(pane) called when the user presses 'q' to close
function Pane:new(config, pane_idx, opts)
	local self = setmetatable({}, Pane)
	self.config = config
	self.win_id = nil
	self.buffer = Buffer:new("[DAP DF Pane " .. pane_idx .. "]", "dap-df", false, "nofile")
	-- Set up keymaps for the buffer
	self:setup_keymaps()

	self.is_open_flag = false
	self.dataview = DataView:new(config.limit)
	self.expression = nil
	opts = opts or {}
	self.on_split = opts.on_split
	self.on_close = opts.on_close
	return self
end

--- Update the ◂/▸ truncation indicators.
--- Shows ◂/▸ on the edge of every buffer line when the table extends beyond
--- the edge of the window.
function Pane:update_truncation_indicator()
	vim.api.nvim_buf_clear_namespace(self.buffer.buf_id, hl.TRUNCATION_NS_ID, 0, -1)

	local boundaries = self.dataview:get_column_boundaries()
	if #boundaries == 0 then return end

	local win_width = vim.api.nvim_win_get_width(self.win_id)
	local leftcol = 0
	vim.api.nvim_win_call(self.win_id, function()
		leftcol = vim.fn.winsaveview().leftcol
	end)

	-- boundaries[#boundaries] is the display column of the trailing │.
	local truncated_right = boundaries[#boundaries] >= leftcol + win_width
	local truncated_left = leftcol > 0

	if not truncated_right and not truncated_left then return end

	local line_count = vim.api.nvim_buf_line_count(self.buffer.buf_id)
	for row = 0, line_count - 1 do
		if truncated_right then
			vim.api.nvim_buf_set_extmark(self.buffer.buf_id, hl.TRUNCATION_NS_ID, row, 0, {
				virt_text = { { "▸", "DapDfTruncated" } },
				virt_text_pos = "right_align",
			})
		end
		if truncated_left then
			-- virt_text_win_col pins the text to a fixed window column (not a line
			-- byte offset), so ◂ always appears at the visible left edge regardless
			-- of how far the user has scrolled horizontally.
			vim.api.nvim_buf_set_extmark(self.buffer.buf_id, hl.TRUNCATION_NS_ID, row, 0, {
				virt_text = { { "◂", "DapDfTruncated" } },
				virt_text_win_col = 0,
			})
		end
	end
end

-- Open the pane window
-- @param split_from number|nil If provided, create a horizontal split from this window
function Pane:open(split_from)
	if self:is_open() then
		return
	end

	if split_from and vim.api.nvim_win_is_valid(split_from) then
		vim.api.nvim_set_current_win(split_from)
		vim.cmd("split")
	else
		local cmd = string.format("botright %dsplit", self.config.size)
		vim.cmd(cmd)
	end
	self.win_id = vim.api.nvim_get_current_win()

	-- Set the buffer in the window
	vim.api.nvim_win_set_buf(self.win_id, self.buffer.buf_id)

	-- Configure the window
        vim.api.nvim_set_option_value("number", false, {win = self.win_id})
        vim.api.nvim_set_option_value("signcolumn", "no", {win = self.win_id})
        vim.api.nvim_set_option_value("winfixheight", true, {win = self.win_id})
        vim.api.nvim_set_option_value("winfixwidth", true, {win = self.win_id})
        vim.api.nvim_set_option_value("wrap", false, {win = self.win_id})
	vim.api.nvim_win_set_hl_ns(self.win_id, hl.NS_ID)

	self.is_open_flag = true

	self.scroll_autocmd_id = vim.api.nvim_create_autocmd("WinScrolled", {
		pattern = tostring(self.win_id),
		callback = function()
			self:update_truncation_indicator()
		end,
	})

	self:refresh()
end

-- Close the pane window
function Pane:close()
	if self.scroll_autocmd_id then
		vim.api.nvim_del_autocmd(self.scroll_autocmd_id)
		self.scroll_autocmd_id = nil
	end
	if self.win_id and vim.api.nvim_win_is_valid(self.win_id) then
		vim.api.nvim_win_close(self.win_id, true)
	end
	self.win_id = nil
	self.is_open_flag = false
end

-- Check if the pane is open
function Pane:is_open()
	return self.is_open_flag and self.win_id and vim.api.nvim_win_is_valid(self.win_id)
end

function Pane:buf_id()
	return self.buffer.buf_id
end

-- Set up keymaps for the buffer
function Pane:setup_keymaps()
	self.buffer:set_keymap("n", "e", function()
		self:prompt_expression()
	end, { desc = "Enter DataFrame expression" })

	self.buffer:set_keymap("n", "r", function()
		self:refresh()
	end, { desc = "Refresh DataFrame display" })

	self.buffer:set_keymap("n", "d", function()
		self.expression = nil
		self:refresh()
	end, { desc = "Clear DataFrame expression" })

	self.buffer:set_keymap("n", "v", function()
		if self.on_split then
			self.on_split(self)
		end
	end, { desc = "Split pane" })

	self.buffer:set_keymap("n", "q", function()
		if self.on_close then
			self.on_close(self)
		end
                self:close()
	end, { desc = "Close this pane" })

	self.buffer:set_keymap("n", "s", function()
		self:sort_column()
	end, { desc = "Sort by column under cursor" })

	self.buffer:set_keymap("n", "f", function()
		self:filter_column()
	end, { desc = "Filter column under cursor" })

	self.buffer:set_keymap("n", "F", function()
		self:clear_filter()
	end, { desc = "Clear filter on column under cursor" })

	self.buffer:set_keymap("n", "L", function()
		self:scroll_columns(1)
	end, { desc = "Scroll right by one column" })

	self.buffer:set_keymap("n", "H", function()
		self:scroll_columns(-1)
	end, { desc = "Scroll left by one column" })

	self.buffer:set_keymap("n", "+", function()
		self:resize(vim.v.count1)
	end, { desc = "Grow pane height" })

	self.buffer:set_keymap("n", "-", function()
		self:resize(-vim.v.count1)
	end, { desc = "Shrink pane height" })

	self.buffer:set_keymap("n", "g?", function()
		help.show(self.buffer.keymaps)
	end, { desc = "Show help" })
end

-- Grow or shrink the pane by delta lines (positive = taller, negative = shorter).
function Pane:resize(delta)
	if not self:is_open() then return end
	local current = vim.api.nvim_win_get_height(self.win_id)
	vim.api.nvim_win_set_height(self.win_id, math.max(1, current + delta))
end

-- Scroll the pane window left or right, snapping to column boundaries.
-- @param direction number  1 = right, -1 = left
function Pane:scroll_columns(direction)
	if not self:is_open() then
		return
	end
	local boundaries = self.dataview:get_column_boundaries()
	if #boundaries == 0 then
		return
	end

	local leftcol
	vim.api.nvim_win_call(self.win_id, function()
		leftcol = vim.fn.winsaveview().leftcol
	end)

	local target = leftcol
	if direction > 0 then
		local win_width = vim.api.nvim_win_get_width(self.win_id)
		for i, b in ipairs(boundaries) do
			if i == #boundaries then break end  -- skip past-end marker
			if b > leftcol then
				-- Align the right edge of this column to the right edge of the window.
				-- Last char of column i is at boundaries[i+1] - 2 (separator is at -1).
				local new_target = math.max(0, boundaries[i + 1] - win_width + 1)
				if new_target > leftcol then
					target = new_target
					break
				end
				-- Column already right-aligned or past it; try the next one.
			end
		end
	else
		target = 0
		for _, b in ipairs(boundaries) do
			if b < leftcol then
				target = b
			end
		end
	end

	if target ~= leftcol then
		-- Move the cursor before changing leftcol; otherwise Neovim
		-- overrides leftcol to keep the cursor visible.
		-- Preserve the cursor's visual offset from the left edge of the window.
		-- virtcol2col converts a 1-indexed screen column to a 1-indexed byte
		-- offset; nvim_win_set_cursor wants a 0-indexed byte offset.
		vim.api.nvim_win_call(self.win_id, function()
			local cursor_virtcol = vim.fn.virtcol('.')  -- 1-indexed screen col
			local new_virtcol = math.max(1, target + cursor_virtcol - leftcol)
			local row = vim.fn.line('.')
			local byte_col = vim.fn.virtcol2col(0, row, new_virtcol) - 1
			vim.api.nvim_win_set_cursor(0, { row, byte_col })
			vim.fn.winrestview({ leftcol = target })
		end)
	end
end

--- Get column info under the cursor (1-indexed column, column name, is_index),
--- or nil if the cursor is not on a data column.
--- @return integer|nil col_idx
--- @return string|nil col_name
--- @return boolean|nil is_index
function Pane:get_column_under_cursor()
	local virtual_col = vim.fn.virtcol(".")
	local col_idx = self.dataview:get_column_at_cursor(virtual_col)
	if col_idx == nil then
		return nil
	end
	local col_name = self.dataview:get_column_name(col_idx)
	if col_name == nil then
		return nil
	end
	return col_idx, col_name, self.dataview:is_index_column(col_idx)
end

-- Prompt for new expression
function Pane:prompt_expression()
        local current_expr = self.expression and self.expression:get_base_expr() or ""
        prompt.open({
            title = "DataFrame / Series expression",
            expression = current_expr,
            on_confirm = function(expr)
                if expr ~= "" then
                    self.expression = Expression:new(expr)
                else
                    self.expression = nil
                end
                self:refresh()
            end,
            on_cancel = function()
                print("DataFrame prompt cancelled")
            end
        })
end

-- Set expression directly (without prompt) and refresh
function Pane:set_expression(expr)
	self.expression = Expression:new(expr)
	self:refresh()
end

-- Sort by the column under cursor (toggles asc -> desc -> none)
function Pane:sort_column()
	if self.expression == nil then
		return
	end
	local _, col_name, is_index = self:get_column_under_cursor()
	if col_name == nil then
		return
	end

	self.expression:toggle_sort(col_name, is_index)
	self:refresh()
end

-- Filter the column under cursor
function Pane:filter_column()
	if self.expression == nil then
		return
	end
	local _, col_name, is_index = self:get_column_under_cursor()
	if col_name == nil then
		return
	end

	local current = self.expression:get_filter(col_name, is_index) or ""

	vim.ui.input({ prompt = "Filter " .. col_name .. ": ", default = current }, function(condition)
		if condition == nil then
			return
		end
		self.expression:set_filter(col_name, is_index, condition)
		self:refresh()
	end)
end

-- Clear the filter on the column under cursor
function Pane:clear_filter()
	if self.expression == nil then
		return
	end
	local _, col_name, is_index = self:get_column_under_cursor()
	if col_name == nil then
		return
	end

	self.expression:clear_filter(col_name, is_index)
	self:refresh()
end

-- Refresh the pane content
-- @param use_cache boolean|nil Whether the evaluator may reuse cached values. Defaults to true.
--        Set to false when the DAP context may have changed.
function Pane:refresh(use_cache)
    if not self:is_open() then
        return
    end

    if self.expression == nil then
        self.buffer:set_content("Press 'e' to enter an expression")
        return
    end

    self.dataview:refresh(
        self.expression,
        function() -- on success
            self.buffer:set_content(self.dataview:get_lines())
            self.buffer:apply_highlight(self.dataview:get_hl_rules())
            self:update_truncation_indicator()
        end,
        function(err) -- on failure
            vim.notify(err, vim.log.levels.ERROR)
        end,
        use_cache
    )
end

return Pane
