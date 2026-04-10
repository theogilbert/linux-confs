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
	self.is_open_flag = false
	self.dataview = DataView:new(config.limit)
	self.expression = nil
	opts = opts or {}
	self.on_split = opts.on_split
	self.on_close = opts.on_close
	return self
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

	-- Set up keymaps for the buffer
	self:setup_keymaps()

	self.is_open_flag = true
	self:refresh()
end

-- Close the pane window
function Pane:close()
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

	self.buffer:set_keymap("n", "g?", function()
		help.show(self.buffer.keymaps)
	end, { desc = "Show help" })
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
function Pane:refresh()
    if not self:is_open() then
        return
    end

    if self.expression == nil then
        self.buffer:set_content("Press 'e' to enter an expression")
        return
    end

    self.dataview:refresh(self.expression, function()
        self.buffer:set_content(self.dataview:get_lines())
        self.buffer:apply_highlight(self.dataview:get_hl_rules())
    end)
end

return Pane
