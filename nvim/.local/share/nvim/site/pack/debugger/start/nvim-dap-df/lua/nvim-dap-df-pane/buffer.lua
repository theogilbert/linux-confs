local hl = require("nvim-dap-df-pane.hl")

local Buffer = {}
Buffer.__index = Buffer

--- Create a new buffer
--- @param name string The name of the buffer
--- @param filetype string The filetype associated with the buffer. See 'filetype' option
--- @param modifiable boolean Whether the buffer is modifiable or not. See 'modifiable' option.
--- @param buftype string The type of the buffer. See 'buftype' option.
function Buffer:new(name, filetype, modifiable, buftype)
	local self = setmetatable({}, Buffer)
        self.keymaps = {}

	-- Create a new buffer
	self.buf_id = vim.api.nvim_create_buf(false, true)
        self.modifiable = modifiable

	-- Configure the buffer
	vim.api.nvim_set_option_value("buftype", buftype, { buf = self.buf_id })
	vim.api.nvim_set_option_value("filetype", filetype, { buf = self.buf_id })
	vim.api.nvim_set_option_value("bufhidden", "hide", { buf = self.buf_id })
	vim.api.nvim_set_option_value("swapfile", false, { buf = self.buf_id })
	vim.api.nvim_set_option_value("modifiable", modifiable, { buf = self.buf_id })
	vim.api.nvim_buf_set_name(self.buf_id, name)
	hl.setup_static_hl_rules(self.buf_id)

	return self
end

function Buffer:from_id(bufid)
    local self = setmetatable({}, Buffer)
    self.keymaps = {}
    self.buf_id = bufid
    self.modifiable = vim.api.nvim_get_option_value("modifiable", { buf = self.buf_id })
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

        for i, line in ipairs(lines) do
            lines[i] = line:gsub("\n", "")
        end

	vim.bo[self.buf_id].modifiable = true
	vim.api.nvim_buf_set_lines(self.buf_id, 0, -1, false, lines)
	vim.bo[self.buf_id].modifiable = self.modifiable
end

-- Get the buffer content
function Buffer:get_content()
	return vim.api.nvim_buf_get_lines(self.buf_id, 0, -1, false)
end

--- @param hl_rules table[] List of highlight rules to apply to the buffer, where each rule has:
---   - `higroup` (string): The name of the highlight group to apply
---   - `start` (string|integer[]): Start of region as a (line, column) tuple
---     or string accepted by |getpos()|
---   - `finish` (string|integer[]): End of region as a (line, column) tuple
---     or string accepted by |getpos()|
function Buffer:apply_highlight(hl_rules)
	vim.api.nvim_buf_clear_namespace(self.buf_id, hl.NS_ID, 0, -1)

	for _, rule in ipairs(hl_rules) do
		vim.hl.range(self.buf_id, hl.NS_ID, rule.higroup, rule.start, rule.finish)
	end
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
        table.insert(self.keymaps, {mode, key, opts})
end


return Buffer
