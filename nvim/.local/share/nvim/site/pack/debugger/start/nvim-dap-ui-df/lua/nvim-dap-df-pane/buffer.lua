local Buffer = {}
Buffer.__index = Buffer

-- Constructor
function Buffer:new()
	local self = setmetatable({}, Buffer)

	-- Create a new buffer
	self.buf_id = vim.api.nvim_create_buf(false, true)

	-- Configure the buffer
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = self.buf_id })
	vim.api.nvim_set_option_value("bufhidden", "hide", { buf = self.buf_id })
	vim.api.nvim_set_option_value("swapfile", false, { buf = self.buf_id })
	vim.api.nvim_set_option_value("modifiable", false, { buf = self.buf_id })
	vim.api.nvim_buf_set_name(self.buf_id, "[DAP DF Pane]")

	return self
end

function Buffer:close()
	if self:is_valid() then
		vim.api.nvim_buf_delete(self.buf_id, { force = true })
	end
end

--- Set the buffer content
---
---@param lines table The list of lines to write to the buffer
function Buffer:set_content(lines)
	if type(lines) == "string" then
		lines = vim.split(lines, "\n")
	end
	-- Temporarily make the buffer modifiable
	vim.api.nvim_set_option_value("modifiable", true, { buf = self.buf_id })

	-- Set the lines
	vim.api.nvim_buf_set_lines(self.buf_id, 0, -1, false, lines)

	-- Make it non-modifiable again
	vim.api.nvim_set_option_value("modifiable", false, { buf = self.buf_id })
end

-- Get the buffer content
function Buffer:get_content()
	return vim.api.nvim_buf_get_lines(self.buf_id, 0, -1, false)
end

-- Check if the buffer is valid
function Buffer:is_valid()
	return vim.api.nvim_buf_is_valid(self.buf_id)
end

-- Set a keymap for the buffer
function Buffer:set_keymap(mode, key, callback, opts)
	opts = opts or {}
	opts.buffer = self.buf_id
	vim.keymap.set(mode, key, callback, opts)
end

return Buffer
