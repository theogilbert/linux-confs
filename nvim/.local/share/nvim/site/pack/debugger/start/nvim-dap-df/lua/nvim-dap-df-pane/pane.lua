local DataView = require("nvim-dap-df-pane.dataview")
local Buffer = require("nvim-dap-df-pane.buffer")
local hl = require("nvim-dap-df-pane.hl")

local Pane = {}
Pane.__index = Pane

-- Constructor
function Pane:new(config)
	local self = setmetatable({}, Pane)
	self.config = config
	self.win_id = nil
	self.buffer = Buffer:new()
	self.is_open_flag = false
        self.dataview = nil
	return self
end

-- Open the pane window
function Pane:open()
	if self:is_open() then
		return
	end

	-- Create the split based on position
	local cmd = string.format("botright %dsplit", self.config.size)
	vim.cmd(cmd)
	self.win_id = vim.api.nvim_get_current_win()

	-- Set the buffer in the window
	vim.api.nvim_win_set_buf(self.win_id, self.buffer.buf_id)

	-- Configure the window
	vim.api.nvim_win_set_option(self.win_id, "number", false)
	vim.api.nvim_win_set_option(self.win_id, "signcolumn", "no")
	vim.api.nvim_win_set_option(self.win_id, "winfixheight", true)
	vim.api.nvim_win_set_option(self.win_id, "winfixwidth", true)
	vim.api.nvim_win_set_option(self.win_id, "wrap", false)
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
end



-- Prompt for new expression
function Pane:prompt_expression()
	vim.ui.input({
		prompt = "DataFrame expression: ",
		default = self.expression or "",
	}, function(input)
		if input and input ~= "" then
                    self.dataview = DataView:new(input)
                    self:refresh()
		end
	end)
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
