-- Scratch buffer wrapper. Ported from grannos.nvim's lua/grannos/buffer.lua.
local hl = require("nvim-dap-df-pane.hl")

local Buffer = {}
Buffer.__index = Buffer

--- Create a new buffer. A `g?` keymap listing every described keymap is registered.
--- @param name string The name of the buffer
--- @param filetype string The filetype associated with the buffer. See 'filetype' option
--- @param modifiable boolean Whether the buffer is modifiable or not. See 'modifiable' option.
--- @param buftype string The type of the buffer. See 'buftype' option.
--- @param bufhidden string|nil Defaults to "hide"
function Buffer:new(name, filetype, modifiable, buftype, bufhidden)
	local self = setmetatable({}, Buffer)
	self.keymaps = {}
	self.modifiable = modifiable
	self.buf_id = vim.api.nvim_create_buf(false, true)

	vim.api.nvim_set_option_value("buftype", buftype, { buf = self.buf_id })
	vim.api.nvim_set_option_value("filetype", filetype, { buf = self.buf_id })
	vim.api.nvim_set_option_value("bufhidden", bufhidden or "hide", { buf = self.buf_id })
	vim.api.nvim_set_option_value("swapfile", false, { buf = self.buf_id })
	vim.api.nvim_set_option_value("modifiable", modifiable, { buf = self.buf_id })
	vim.api.nvim_buf_set_name(self.buf_id, name)
	self:set_keymap("n", "g?", function()
		self:show_help()
	end, { silent = true, desc = "Show keymaps" })
	return self
end

function Buffer:from_id(bufid)
	local self = setmetatable({}, Buffer)
	self.keymaps = {}
	self.buf_id = bufid
	self.modifiable = vim.api.nvim_get_option_value("modifiable", { buf = self.buf_id })
	return self
end

--- Delete the underlying buffer (force=true), if valid.
function Buffer:close()
	if self:is_valid() then
		vim.api.nvim_buf_delete(self.buf_id, { force = true })
	end
end

--- Replace the buffer content.
--- @param lines string[]|string
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

--- @return string[]
function Buffer:get_content()
	return vim.api.nvim_buf_get_lines(self.buf_id, 0, -1, false)
end

--- Apply highlight rules, clearing any previous ones.
--- Each rule: { higroup, start = {line, col}, finish = {line, col} }
function Buffer:apply_highlight(rules)
	vim.api.nvim_buf_clear_namespace(self.buf_id, hl.NS_ID, 0, -1)
	for _, rule in ipairs(rules) do
		vim.hl.range(self.buf_id, hl.NS_ID, rule.higroup, rule.start, rule.finish)
	end
end

--- @return boolean
function Buffer:is_valid()
	return vim.api.nvim_buf_is_valid(self.buf_id)
end

--- Open a floating window listing `keymaps`. Keymaps with a non-empty `group`
--- are rendered under section headers. Closes on q/<Esc>/g?.
--- @param keymaps { lhs: string, desc: string, group: string }[]
--- @return integer|nil win  the help float's window id, or nil if there was nothing to show
function Buffer.render_help_float(keymaps)
	if #keymaps == 0 then
		return nil
	end

	local key_w = 0
	for _, km in ipairs(keymaps) do
		key_w = math.max(key_w, vim.fn.strdisplaywidth(km.lhs))
	end

	local function entry(km)
		local pad = string.rep(" ", key_w - vim.fn.strdisplaywidth(km.lhs))
		return ("  %s%s  %s"):format(km.lhs, pad, km.desc)
	end

	local group_order, buckets = {}, {}
	for _, km in ipairs(keymaps) do
		local g = km.group ~= "" and km.group or "\0ungrouped"
		if not buckets[g] then
			buckets[g] = {}
			table.insert(group_order, g)
		end
		table.insert(buckets[g], km)
	end

	local lines, header_lnums = {}, {}
	for i, g in ipairs(group_order) do
		if i > 1 then
			table.insert(lines, "")
		end
		if g ~= "\0ungrouped" then
			table.insert(lines, g)
			header_lnums[#lines] = true
		end
		for _, km in ipairs(buckets[g]) do
			table.insert(lines, entry(km))
		end
	end

	local width = 1
	for _, l in ipairs(lines) do
		width = math.max(width, vim.fn.strdisplaywidth(l))
	end

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].bufhidden = "wipe"

	for lnum in pairs(header_lnums) do
		vim.hl.range(buf, hl.NS_ID, "DapDfHeaderRow", { lnum - 1, 0 }, { lnum - 1, -1 })
	end

	vim.cmd("stopinsert")

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "cursor",
		row = 1,
		col = 0,
		width = width,
		height = #lines,
		style = "minimal",
		border = "rounded",
		title = " keymaps ",
		title_pos = "center",
		zindex = 200,
	})
	vim.api.nvim_win_set_hl_ns(win, hl.NS_ID)

	for _, key in ipairs({ "q", "<Esc>", "g?" }) do
		vim.keymap.set("n", key, function()
			pcall(vim.api.nvim_win_close, win, true)
		end, { buffer = buf, silent = true })
	end

	return win
end

--- Open a floating window listing all keymaps that have a desc.
function Buffer:show_help()
	local keymaps = {}
	for _, km in ipairs(self.keymaps) do
		local opts = km[3] or {}
		local desc = opts.desc or ""
		if desc ~= "" then
			table.insert(keymaps, { lhs = km[2], desc = desc, group = opts.group or "" })
		end
	end
	Buffer.render_help_float(keymaps)
end

--- Register a buffer-local keymap and record it so it appears in the `g?` help float.
--- `opts.group` (string) groups the key under a named section header in the help float.
--- @param mode     string
--- @param key      string
--- @param callback fun()
--- @param opts     table|nil
function Buffer:set_keymap(mode, key, callback, opts)
	opts = opts or {}
	local group = opts.group
	opts.group = nil
	opts.buffer = self.buf_id
	vim.keymap.set(mode, key, callback, opts)
	table.insert(self.keymaps, { mode, key, vim.tbl_extend("force", opts, { group = group }) })
end

return Buffer
