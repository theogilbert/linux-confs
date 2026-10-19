-- Formats a sequence of row arrays into a box-drawing-character table.
-- Ported from grannos.nvim's lua/grannos/table.lua.
local M = {}

--- @class FormattedTable
--- @field lines         any[][]    raw row arrays (the first `header_lines` rows are the header)
--- @field header_lines  integer    how many rows of `lines` are header rows
--- @field columns_width integer[]  display-column widths per column
--- @field text          string[]   rendered lines ready to set into a buffer
--- @field sep           string[]|nil per-column thousands-separator used for numeric cells, if any
--- @field left_aligned  table<integer, boolean> columns whose cells are left-aligned rather than centered

M.COL_SEPARATOR = "│"

-- Display string for missing values (vim.NIL sentinel).
M.NULL_TEXT = "NA"

--- Whether `cell` is a numeric string the thousands separator applies to.
--- Cells are kept as the strings pandas printed (a Lua number would lose
--- precision past 2^53), so numbers are recognised by their shape.
--- @param cell any
--- @return boolean
local function is_numeric(cell)
	return type(cell) == "string" and cell:match("^%-?%d+%.?%d*$") ~= nil
end

--- Insert `sep` between digit groups in the integer part of a numeric string.
--- @param s   string
--- @param sep string|nil  separator to insert between digit groups (e.g. "_"), or nil to disable
--- @return string display  the formatted number
--- @return integer int_len  byte length of the sign + grouped integer part (excludes the fraction)
local function format_number(s, sep)
	local sign, rest = s:match("^(%-?)(.*)$")
	local int_part, frac = rest:match("^(%d+)(.*)$")
	if not int_part then
		return s, #s
	end

	local grouped = int_part
	if sep and #int_part > 3 then
		local sep_rev = sep:reverse()
		local sep_repl = sep_rev:gsub("%%", "%%%%")
		grouped = int_part:reverse():gsub("(%d%d%d)", "%1" .. sep_repl)
		if grouped:sub(-#sep_rev) == sep_rev then
			grouped = grouped:sub(1, -#sep_rev - 1)
		end
		grouped = grouped:reverse()
	end

	local int_str = sign .. grouped
	return int_str .. frac, #int_str
end

--- Printable stand-ins for the control characters that turn up in real cell
--- values (a traceback, a JSON blob, an indented text column).
local CONTROL_ESCAPES = { ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

--- Replace control characters in `s` with their source-literal escapes, so a
--- multi-line value renders as one line of one row. Escaping happens ahead of
--- both the width measurement and the render, so the two always agree.
--- @param s string
--- @return string
local function escape_control(s)
	if not s:find("%c") then
		return s
	end
	return (s:gsub("%c", function(c)
		return CONTROL_ESCAPES[c] or ("\\x%02X"):format(c:byte())
	end))
end

--- Return the display string for a cell value, mapping vim.NIL → NULL_TEXT and
--- grouping the digits of numeric cells when a separator is given.
--- @param cell any
--- @param sep  string|nil
--- @return string
local function cell_display(cell, sep)
	if cell == vim.NIL then
		return M.NULL_TEXT
	end
	if cell == nil then
		return ""
	end
	if sep and is_numeric(cell) then
		return (format_number(cell, sep))
	end
	return escape_control(tostring(cell))
end

--- Center `text` within `width` display columns using space padding.
local function center(text, width)
	local space = (width - vim.api.nvim_strwidth(text)) / 2
	return string.rep(" ", math.floor(space)) .. text .. string.rep(" ", math.ceil(space))
end

--- Left-align `text` within `width` display columns, keeping the 1-space padding on the left.
local function left(text, width)
	return " " .. text .. string.rep(" ", width - vim.api.nvim_strwidth(text) - 1)
end

--- Display-column offset of `text` from the start of its cell.
local function text_offset(text, width, is_left)
	if is_left then
		return 1
	end
	return math.floor((width - vim.api.nvim_strwidth(text)) / 2)
end

--- Normalize a `sep` argument into a per-column array (or nil when disabled everywhere).
--- Accepts a single string (applied to every column) or a sparse per-column array.
--- @param sep   string|table|boolean|nil
--- @param ncols integer
--- @return string[]|nil
local function normalize_sep(sep, ncols)
	if not sep or sep == "" then
		return nil
	end
	local arr, any = {}, false
	if type(sep) == "table" then
		for i = 1, ncols do
			if sep[i] and sep[i] ~= "" then
				arr[i] = sep[i]
				any = true
			end
		end
	else
		for i = 1, ncols do
			arr[i] = sep
		end
		any = ncols > 0
	end
	return any and arr or nil
end

--- Build the ├──┼──┤ separator row for the given column widths.
local function build_separator(widths)
	local parts = {}
	for i, w in ipairs(widths) do
		parts[i] = string.rep("─", w)
	end
	return "├" .. table.concat(parts, "┼") .. "┤"
end

--- Build a FormattedTable from a list of row arrays.
--- @param lines table  rows, each an array of cell values
--- @param header_lines integer|nil  rows to treat as header (default 1). Header
---   cells never get a thousands separator.
--- @param sep string|table|boolean|nil  thousands-separator for numeric cells: a single string applies to
---   every column, a per-column array (sparse) applies selectively, nil/false/"" disables it
--- @param left_align_width integer|nil  a column wider than this many display columns is left-aligned
---   instead of centered; nil centers every column
--- @return FormattedTable
function M.from_structured_data(lines, header_lines, sep, left_align_width)
	header_lines = header_lines or 1
	-- Every row renders as many columns as the widest one, so a short or long
	-- row still lines up with the header. Missing cells render empty.
	local ncols = 0
	for _, row in ipairs(lines) do
		ncols = math.max(ncols, #row)
	end
	sep = normalize_sep(sep, ncols)

	local display = {}
	local widths = {}
	for i, row in ipairs(lines) do
		local cells = {}
		for j = 1, ncols do
			cells[j] = cell_display(row[j], i > header_lines and sep and sep[j] or nil)
			widths[j] = math.max(widths[j] or 2, vim.api.nvim_strwidth(cells[j]) + 2)
		end
		display[i] = cells
	end

	local left_aligned = {}
	if left_align_width then
		for j = 1, ncols do
			left_aligned[j] = widths[j] > left_align_width or nil
		end
	end

	local formatted = {}
	for i, cells in ipairs(display) do
		local out = {}
		for j = 1, ncols do
			local align = left_aligned[j] and left or center
			out[j] = align(cells[j], widths[j])
		end
		formatted[i] = M.COL_SEPARATOR .. table.concat(out, M.COL_SEPARATOR) .. M.COL_SEPARATOR
	end

	if header_lines > 0 and header_lines <= #formatted then
		table.insert(formatted, header_lines + 1, build_separator(widths))
	end

	return {
		lines = lines,
		header_lines = header_lines,
		display = display,
		columns_width = widths,
		text = formatted,
		sep = sep,
		left_aligned = left_aligned,
	}
end

--- Return the 1-indexed column at a virtual cursor position,
--- or nil when the cursor is on a separator.
--- @param cols_width integer[]
--- @param virtual_col integer  1-indexed
--- @return integer|nil
function M.get_column_at_cursor(cols_width, virtual_col)
	local pos = 2 -- skip leading │
	for i, w in ipairs(cols_width) do
		if virtual_col >= pos and virtual_col < pos + w then
			return i
		end
		pos = pos + w + 1
	end
	return nil
end

local SEP_BYTES = #M.COL_SEPARATOR

--- Return the leftcol values that align the view to each column boundary.
--- boundaries[i] is the leftcol showing column i at the left edge; the last
--- entry is the display column of the trailing │.
--- @param cols_width integer[]
--- @return integer[]
function M.column_boundaries(cols_width)
	local boundaries, pos = { 0 }, 0
	for _, w in ipairs(cols_width) do
		pos = pos + w + 1 -- cell width + │
		boundaries[#boundaries + 1] = pos
	end
	return boundaries
end

--- Compute the byte {start, finish} of each column cell of a row of `tbl`.
--- Accounts for multi-byte cell content so positions are valid for vim.hl.range.
--- @param tbl FormattedTable
--- @param data_line integer  1-indexed into tbl.lines
--- @return table  list of {byte_start, byte_end} per column
function M.column_byte_positions(tbl, data_line)
	local positions = {}
	local cells = tbl.display[data_line]
	local byte_pos = SEP_BYTES -- skip leading │
	for i, width in ipairs(tbl.columns_width) do
		local cell_bytes = width
		if cells then
			local s = cells[i]
			cell_bytes = width - vim.api.nvim_strwidth(s) + #s
		end
		positions[i] = { byte_pos, byte_pos + cell_bytes }
		byte_pos = byte_pos + cell_bytes + SEP_BYTES
	end
	return positions
end

--- 0-indexed buffer line (relative to the table's first line) of tbl.lines[i]:
--- rows past the header sit one line lower, below the ├──┤ separator.
--- @param tbl FormattedTable
--- @param i integer
--- @return integer
local function buf_line_of(tbl, i)
	return i > tbl.header_lines and i or i - 1
end

--- Build per-column highlight rules for one row of the table.
--- @param higroup string
--- @param tbl FormattedTable|nil
--- @param data_line integer  1-indexed into tbl.lines
--- @return table  list of { higroup, start, finish } rules, one per column, relative to the table's first line
function M.col_hl_rules(higroup, tbl, data_line)
	if not tbl then
		return {}
	end
	local line = buf_line_of(tbl, data_line)
	local rules = {}
	for i, pos in ipairs(M.column_byte_positions(tbl, data_line)) do
		rules[i] = { higroup = higroup, start = { line, pos[1] }, finish = { line, pos[2] } }
	end
	return rules
end

--- Return highlight rules for all missing (vim.NIL) cells in the data rows.
--- @param higroup string
--- @param tbl FormattedTable
--- @return table
function M.null_hl_rules(higroup, tbl)
	local rules = {}
	for i = tbl.header_lines + 1, #tbl.lines do
		local positions = M.column_byte_positions(tbl, i)
		for j, cell in ipairs(tbl.lines[i]) do
			if cell == vim.NIL then
				rules[#rules + 1] = { higroup = higroup, start = { i, positions[j][1] }, finish = { i, positions[j][2] } }
			end
		end
	end
	return rules
end

--- Return highlight rules for the thousands-separator characters within numeric cells.
--- @param higroup string
--- @param tbl FormattedTable
--- @return table
function M.thousands_hl_rules(higroup, tbl)
	local rules = {}
	if not tbl.sep then
		return rules
	end
	for i = tbl.header_lines + 1, #tbl.lines do
		local positions = M.column_byte_positions(tbl, i)
		for j, cell in ipairs(tbl.lines[i]) do
			local sep_char = tbl.sep[j]
			if sep_char and is_numeric(cell) then
				local s, int_len = format_number(cell, sep_char)
				local base = positions[j][1] + text_offset(s, tbl.columns_width[j], tbl.left_aligned[j] or false)
				local int_s = s:sub(1, int_len)
				local from = 1
				while true do
					local a, b = int_s:find(sep_char, from, true)
					if not a then
						break
					end
					rules[#rules + 1] = { higroup = higroup, start = { i, base + a - 1 }, finish = { i, base + b } }
					from = b + 1
				end
			end
		end
	end
	return rules
end

--- Set up box-drawing character highlighting for a buffer that shows a table.
--- 'synmaxcol' is lifted: every box-drawing glyph is 3 bytes, so a wide
--- table's borders would otherwise lose their colour past 3000 bytes.
--- @param buf_id integer
--- @param higroup string  group the borders link to
function M.setup_buf_hl(buf_id, higroup)
	vim.bo[buf_id].synmaxcol = 0
	vim.api.nvim_buf_call(buf_id, function()
		vim.cmd("syntax match DapDfTableBorder /[│├┼─┤]/")
	end)
	vim.cmd("highlight link DapDfTableBorder " .. higroup)
end

return M
