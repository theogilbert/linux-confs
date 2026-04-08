local DataView = require("nvim-dap-df-pane.dataview")
local Buffer = require("nvim-dap-df-pane.buffer")
local prompt = require("nvim-dap-df-pane.prompt")
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
	self.dataview = nil
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
		self.dataview = nil
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
end

-- Prompt for new expression
function Pane:prompt_expression()
        local current_expr = self.dataview and self.dataview.expr or ""
        prompt.open({
            title = "DataFrame / Series expression",
            expression = current_expr,
            on_confirm = function(expr)
                if expr ~= "" then
                    self.dataview = DataView:new(expr, self.config.limit)
                    self:refresh()
                else
                    self.dataview = nil
                    self:refresh()
                end
            end,
            on_cancel = function()
                print("DataFrame prompt cancelled")
            end
        })
end

-- Set expression directly (without prompt) and refresh
function Pane:set_expression(expr)
	self.dataview = DataView:new(expr, self.config.limit)
	self:refresh()
end

-- Refresh the pane content
function Pane:refresh()
    if not self:is_open() then
        return
    end

    if self.dataview == nil then
        self.buffer:set_content("Press 'e' to enter an expression")
        return
    else
        self.dataview:refresh(function()
            self.buffer:set_content(self.dataview:get_lines())
            self.buffer:apply_highlight(self.dataview:get_hl_rules())
        end)
    end
end

return Pane
