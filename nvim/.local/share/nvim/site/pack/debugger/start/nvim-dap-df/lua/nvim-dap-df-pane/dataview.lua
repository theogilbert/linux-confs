local ExpressionEvaluator = require("nvim-dap-df-pane.evaluator")
local Expression = require("nvim-dap-df-pane.expression")
local csv = require("nvim-dap-df-pane.csv")
local table_fmt = require("nvim-dap-df-pane.table")

local DataView = {}
DataView.__index = DataView

--- @class State The current state of the data view
local State = {
	--- The expression is being evaluated and the data view is waiting for its result
	EVALUATING = 0,
	--- The expression has been evaluated and the data view is ready to be rendered
	READY = 1,
}

--- Buffer layout: the prompt line, a blank line, then the table.
--- 0-indexed buffer row of the table's first (header) line.
DataView.TABLE_START = 2

--- The value pandas writes for missing cells (see evaluator's `na_rep`).
local NA_REP = "pd.NA"

--- @class Cursor
--- @field line integer 0-indexed buffer row
--- @field col integer 1-indexed virtual (display) column

--- @class DataView Evaluates a python DataFrame / Series expression and
--- formats the result as a table ready to be rendered.
---
--- The DataView owns the Expression (and through it the sort/filter state) and
--- the display state: which columns are shown, in which order, and which ones
--- have their digits grouped. It is responsible for:
---   * driving the evaluator,
---   * formatting the evaluation result as a table,
---   * decorating the table with sort arrows / a filter row,
---   * mapping cursor position → column / row info.
---
--- The DataView is agnostic of nvim window APIs: callers pass the cursor in.
--- @field limit number The maximum number of rows to display
--- @field expression Expression The expression to evaluate
--- @field state State The current state of the data view
--- @field shape table|nil { col_count, row_count } of the evaluated data, as strings
--- @field column_names string[]|nil Raw column names (index first)
--- @field dtypes string[]|nil Raw dtype names, parallel to column_names
--- @field rows any[][]|nil Raw data rows, parallel to column_names
--- @field visible integer[]|nil Indices into column_names shown, in display order. nil shows every column.
--- @field sep_columns table<integer, true> Indices into column_names whose digits are grouped
--- @field table FormattedTable|nil

--- @param expression string The expression to evaluate and display
--- @param limit integer How many rows to display at most
--- @param thousands_separator string|nil Character grouping digits in toggled columns (`t`)
function DataView:new(expression, limit, thousands_separator)
	local self = setmetatable({}, DataView)

	self.limit = limit
	self.thousands_separator = (thousands_separator and thousands_separator ~= "") and thousands_separator or nil
	self.expression = Expression:new(expression)
	self.state = State.EVALUATING
	self.shape = nil
	self.lines = {}
	self.visible = nil
	self.sep_columns = {}
	self.evaluator = ExpressionEvaluator:new()

	return self
end

--- @return integer[] Indices into column_names, in display order
function DataView:display_columns()
	if self.visible then
		return self.visible
	end
	local all = {}
	for i = 1, #(self.column_names or {}) do
		all[i] = i
	end
	return all
end

--- Map a 1-indexed display column to its index in column_names.
--- @param col_idx integer
--- @return integer|nil
function DataView:raw_index(col_idx)
	if self.visible then
		return self.visible[col_idx]
	end
	return col_idx
end

--- Returns the 1-indexed display column under the cursor, or nil if the
--- cursor is on a column separator, outside the table, or (when `cursor.line`
--- is given) on a line that is not part of the table.
--- @param cursor Cursor
--- @return integer|nil
function DataView:get_column_at_cursor(cursor)
	if self.table == nil then
		return nil
	end
	if cursor.line ~= nil then
		local rel = cursor.line - DataView.TABLE_START
		if rel < 0 or rel >= #self.table.text then
			return nil
		end
	end
	return table_fmt.get_column_at_cursor(self.table.columns_width, cursor.col)
end

--- Returns the column name at the given 1-indexed display column.
--- @param col_idx integer
--- @return string|nil
function DataView:get_column_name(col_idx)
	if self.column_names == nil then
		return nil
	end
	local raw = self:raw_index(col_idx)
	return raw and self.column_names[raw]
end

--- Returns whether the given display column is the DataFrame index.
--- @param col_idx integer
--- @return boolean
function DataView:is_index_column(col_idx)
	return self:raw_index(col_idx) == 1
end

--- Get the name of the column under the cursor and whether it is the index,
--- or nil if the cursor is not on a data column.
--- @param cursor Cursor
--- @return string|nil col_name
--- @return boolean|nil is_index
function DataView:get_column_under_cursor(cursor)
	local col_idx = self:get_column_at_cursor(cursor)
	if col_idx == nil then
		return nil
	end
	local col_name = self:get_column_name(col_idx)
	if col_name == nil then
		return nil
	end
	return col_name, self:is_index_column(col_idx)
end

--- Change the sorting order of the column under the cursor,
--- alternating between ascending, descending or no sort.
--- @param cursor Cursor
function DataView:sort_column_under_cursor(cursor)
	local col_name, is_index = self:get_column_under_cursor(cursor)
	if col_name ~= nil then
		self.expression:toggle_sort(col_name, is_index)
	end
end

--- Retrieve the current filter for the column under the cursor, if any.
--- @param cursor Cursor
--- @return string|nil
function DataView:get_column_filter_under_cursor(cursor)
	local col_name, is_index = self:get_column_under_cursor(cursor)
	if col_name == nil then
		return nil
	end
	return self.expression:get_filter(col_name, is_index)
end

--- Set the filter applied to the column under the cursor.
--- @param cursor Cursor
--- @param condition string
function DataView:filter_column_under_cursor(cursor, condition)
	local col_name, is_index = self:get_column_under_cursor(cursor)
	if col_name ~= nil then
		self.expression:set_filter(col_name, is_index, condition)
	end
end

--- Remove any filter applied to the column under the cursor.
--- @param cursor Cursor
function DataView:clear_filter_under_cursor(cursor)
	local col_name, is_index = self:get_column_under_cursor(cursor)
	if col_name ~= nil then
		self.expression:clear_filter(col_name, is_index)
	end
end

--- Returns the names of the displayed columns, in display order. Returns an
--- empty list when no data has been evaluated.
--- @return string[]
function DataView:get_column_names()
	local names = {}
	for i, raw in ipairs(self:display_columns()) do
		names[i] = self.column_names[raw]
	end
	return names
end

--- Unique labels for every raw column, for pickers and the row detail float:
--- an unnamed index reads "(index)", and a repeated name gets a " #n" suffix.
--- @return string[]
function DataView:get_column_labels()
	local labels, seen = {}, {}
	for i, name in ipairs(self.column_names or {}) do
		local label = (i == 1 and name == "") and "(index)" or name
		if seen[label] then
			seen[label] = seen[label] + 1
			label = label .. " #" .. seen[label]
		else
			seen[label] = 1
		end
		labels[i] = label
	end
	return labels
end

--- Labels of the displayed columns, in display order.
--- @return string[]
function DataView:get_visible_labels()
	local labels, out = self:get_column_labels(), {}
	for i, raw in ipairs(self:display_columns()) do
		out[i] = labels[raw]
	end
	return out
end

--- Show the columns with the given labels (see get_column_labels), in that order.
--- @param labels string[]
function DataView:set_visible_labels(labels)
	local index_of = {}
	for i, label in ipairs(self:get_column_labels()) do
		index_of[label] = i
	end
	local visible = {}
	for _, label in ipairs(labels) do
		if index_of[label] then
			table.insert(visible, index_of[label])
		end
	end
	self.visible = visible
	self:render()
end

--- Hide the column under the cursor.
--- @param cursor Cursor
--- @return boolean hidden Whether a column was hidden
function DataView:hide_column_under_cursor(cursor)
	local col_idx = self:get_column_at_cursor(cursor)
	if col_idx == nil then
		return false
	end
	local visible = vim.list_extend({}, self:display_columns())
	table.remove(visible, col_idx)
	self.visible = visible
	self:render()
	return true
end

--- Toggle the thousands separator on the column under the cursor.
--- @param cursor Cursor
--- @return boolean toggled
function DataView:toggle_thousands_separator_under_cursor(cursor)
	local col_idx = self:get_column_at_cursor(cursor)
	if col_idx == nil or self.thousands_separator == nil then
		return false
	end
	local raw = self:raw_index(col_idx)
	self.sep_columns[raw] = (not self.sep_columns[raw]) or nil
	self:render()
	return true
end

--- Returns the leftcol values that align the view to each column boundary.
--- Returns an empty table when no table is loaded yet.
--- @return integer[]
function DataView:get_column_boundaries()
	if self.table == nil then
		return {}
	end
	return table_fmt.column_boundaries(self.table.columns_width)
end

--- Returns the leftcol value that aligns the named column to the left edge
--- of the window, or nil when the column is not displayed.
--- @param col_name string
--- @return integer|nil
function DataView:get_leftcol_for_column(col_name)
	if self.column_names == nil or self.table == nil then
		return nil
	end
	local boundaries = self:get_column_boundaries()
	for i, name in ipairs(self:get_column_names()) do
		if name == col_name then
			return boundaries[i]
		end
	end
	return nil
end

--- The data row under the cursor, for the row detail float.
--- @param cursor Cursor
--- @return { columns: string[], row: any[], selected: integer[]|nil, title: string }|nil
function DataView:row_at_cursor(cursor)
	if self.table == nil or self.rows == nil then
		return nil
	end
	-- Data row i of table.lines sits on table line i (below the ├──┤ separator).
	local i = cursor.line - DataView.TABLE_START
	local k = i - self.table.header_lines
	if k < 1 or k > #self.rows then
		return nil
	end
	return {
		columns = self:get_column_labels(),
		row = self.rows[k],
		selected = self.visible,
		title = ("Row %d of %d"):format(k, #self.rows),
	}
end

--- Describe the column under the cursor, for the hover float.
--- @param cursor Cursor
--- @return string[]|nil lines
--- @return table|nil hls  { group, row, col_start, col_end } rules
function DataView:column_info_under_cursor(cursor)
	local col_idx = self:get_column_at_cursor(cursor)
	if col_idx == nil then
		return nil
	end
	local raw = self:raw_index(col_idx)
	local name, is_index = self:get_column_name(col_idx), raw == 1
	local label = self:get_column_labels()[raw]

	local lines = { is_index and (label == "(index)" and label or label .. "  (index)") or label }
	table.insert(lines, "dtype   " .. (self.dtypes and self.dtypes[raw] or "?"))
	for priority, sort in ipairs(self.expression:get_sorts()) do
		if sort.is_index == is_index and (is_index or sort.col_name == name) then
			local order = sort.ascending and "ascending" or "descending"
			local sorts = #self.expression:get_sorts()
			table.insert(lines, "sort    " .. order .. (sorts > 1 and (" (key " .. priority .. "/" .. sorts .. ")") or ""))
		end
	end
	local filter = self.expression:get_filter(name, is_index)
	if filter then
		table.insert(lines, "filter  " .. filter)
	end
	return lines, { { "DapDfHeaderRow", 0, 0, -1 } }
end

--- Decorate the header row with sort arrows on sorted columns.
--- When multiple sorts are active, a priority number is shown (1▲, 2▼, …).
--- @param header string[] Header cells, in display order (mutated)
--- @param display_cols integer[] Raw column index of each display column
--- @param sorts table[] Ordered list of { col_name, is_index, ascending }
--- @param column_names string[] Raw column names
--- @return integer[] sort_col_indices Display columns that are sorted
local function apply_sort_decoration(header, display_cols, sorts, column_names)
	local sort_col_indices = {}
	local multi = #sorts > 1

	for priority, sort in ipairs(sorts) do
		for i, raw in ipairs(display_cols) do
			local is_index = (raw == 1)
			if sort.is_index == is_index and (is_index or column_names[raw] == sort.col_name) then
				local arrow = sort.ascending and "▲" or "▼"
				header[i] = header[i] .. (multi and (" " .. priority .. arrow) or (" " .. arrow))
				table.insert(sort_col_indices, i)
				break
			end
		end
	end

	return sort_col_indices
end

--- Rebuild the formatted table from the evaluated data and the display state,
--- without re-evaluating anything.
function DataView:render()
	if self.column_names == nil then
		return
	end
	local display_cols = self:display_columns()
	local filters = self.expression:get_filters()

	local header, dtypes, filter_row = {}, {}, {}
	for i, raw in ipairs(display_cols) do
		header[i] = self.column_names[raw]
		dtypes[i] = self.dtypes[raw] or ""
		filter_row[i] = filters[raw == 1 and "index" or self.column_names[raw]] or ""
	end
	self.sort_col_indices = apply_sort_decoration(header, display_cols, self.expression:get_sorts(), self.column_names)

	local display = { header, dtypes }
	if next(filters) ~= nil then
		table.insert(display, filter_row)
	end
	local header_lines = #display
	for _, row in ipairs(self.rows) do
		local out = {}
		for i, raw in ipairs(display_cols) do
			out[i] = row[raw]
		end
		table.insert(display, out)
	end

	local sep
	if self.thousands_separator and next(self.sep_columns) then
		sep = {}
		for i, raw in ipairs(display_cols) do
			sep[i] = self.sep_columns[raw] and self.thousands_separator or nil
		end
	end

	self.table = table_fmt.from_structured_data(display, header_lines, sep, math.floor(vim.o.columns / 2))
	self.lines = self.table.text
end

--- Store a freshly evaluated CSV result. The column selection and the
--- thousands-separator toggles survive as long as the columns are unchanged.
--- @param rows string[][] Parsed CSV: names, dtypes, then data rows
--- @param shape table
local function store_result(self, rows, shape)
	local names = rows[1] or {}
	if not vim.deep_equal(names, self.column_names) then
		self.visible = nil
		self.sep_columns = {}
	end
	self.column_names = names
	self.dtypes = rows[2] or {}
	self.rows = {}
	for i = 3, #rows do
		local row = rows[i]
		for j, cell in ipairs(row) do
			if cell == NA_REP then
				row[j] = vim.NIL
			end
		end
		table.insert(self.rows, row)
	end
	self.shape = shape
	self:render()
end

--- @alias FailureCallback fun(err: string)

--- Re-evaluate the expression and signal the caller when the result is
--- ready to be rendered.
--- @param on_ready function Called whenever the view has been refreshed and is ready to be rendered.
---        Called once immediately (loading state), then once evaluation completes.
--- @param on_failed FailureCallback Called whenever the view failed to be rendered.
--- @param use_cache boolean|nil Whether the evaluator may reuse cached values. Defaults to true.
---        Set to false when the DAP context may have changed.
function DataView:refresh(on_ready, on_failed, use_cache)
	self.state = State.EVALUATING
	on_ready()

	self.evaluator:evaluate(self.expression, self.limit, function(data, shape, err)
		if err ~= nil then
			local err_repr = type(err) == "table" and err.message or vim.inspect(err)
			on_failed("Failed to evaluate expression `" .. self.expression:build() .. "`: " .. err_repr)
		else
			local rows, parse_err = csv.parse(data)
			if parse_err ~= nil then
				on_failed("Failed to format result: " .. parse_err)
			else
				store_result(self, rows, shape)
			end
		end

		-- Failure or not, we go back to a ready state to re-render
		self.state = State.READY
		on_ready()
	end, use_cache)
end

--- Group the digits of a count string for the prompt line.
local function group_digits(n)
	local s = tostring(n)
	return (s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

--- Generates the data shape part of the prompt line: [cols×rows], plus how
--- much of it is on screen when rows are truncated or columns hidden.
--- @param self DataView
--- @return string
local function get_shape_repr(self)
	if not self.shape then
		return ""
	end
	local parts = { group_digits(self.shape[1]) .. "×" .. group_digits(self.shape[2]) }
	local rows = tonumber(self.shape[2])
	if rows and rows > self.limit then
		table.insert(parts, "first " .. group_digits(self.limit))
	end
	if self.visible and self.column_names then
		local hidden = #self.column_names - #self.visible
		if hidden > 0 then
			table.insert(parts, hidden .. " hidden")
		end
	end
	return "[" .. table.concat(parts, " · ") .. "]"
end

local LOADING_SYMBOL = "Loading... "

--- Generates the whole prompt line for the dataview: loading label, data
--- shape and the base expression, padded to `width`.
--- @param self DataView
--- @param width number The width of the table, in display columns.
--- @return string
local function get_prompt_line(self, width)
	local base_expr = string.gsub(self.expression:get_base(), "%s+", " ")
	local loading = self.state == State.EVALUATING and LOADING_SYMBOL or ""

	local base_prompt = loading .. get_shape_repr(self) .. " ➜ " .. base_expr
	local chars_to_add = math.max(0, width - vim.api.nvim_strwidth(base_prompt))

	return base_prompt .. string.rep(" ", chars_to_add)
end

--- Generate the highlighting rules applied on the prompt line.
local function build_hl_rules_for_prompt(self)
	local shape_start = self.state == State.EVALUATING and #LOADING_SYMBOL or 0
	local shape_end = shape_start + #get_shape_repr(self)

	local rules = {}
	if self.state == State.EVALUATING then
		table.insert(rules, { higroup = "DapDfPromptLoading", start = { 0, 0 }, finish = { 0, shape_start } })
	end
	if self.shape ~= nil then
		table.insert(rules, { higroup = "DapDfPromptShape", start = { 0, shape_start }, finish = { 0, shape_end } })
	end
	table.insert(rules, { higroup = "DapDfPrompt", start = { 0, shape_end }, finish = { 0, -1 } })

	return rules
end

--- Returns a render of the evaluation result of the input expression
--- @return string[] lines
function DataView:get_lines()
	local first_line_width = vim.api.nvim_strwidth(self.lines[1] or "")
	local lines = { get_prompt_line(self, first_line_width) }
	if #self.lines > 0 then
		table.insert(lines, "")
		vim.list_extend(lines, self.lines)
	end
	return lines
end

--- Returns the rules used to highlight the rendered result.
--- @return table[]
function DataView:get_hl_rules()
	local rules = build_hl_rules_for_prompt(self)
	local tbl = self.table
	if tbl == nil then
		return rules
	end

	local header_rules = table_fmt.col_hl_rules("DapDfHeaderRow", tbl, 1)
	local table_rules = vim.list_extend({}, header_rules)
	vim.list_extend(table_rules, table_fmt.col_hl_rules("DapDfTypeRow", tbl, 2))
	if tbl.header_lines == 3 then
		vim.list_extend(table_rules, table_fmt.col_hl_rules("DapDfFilterRow", tbl, 3))
	end
	for _, idx in ipairs(self.sort_col_indices or {}) do
		local base = header_rules[idx]
		if base then
			table.insert(table_rules, { higroup = "DapDfSortedColumn", start = base.start, finish = base.finish })
		end
	end
	vim.list_extend(table_rules, table_fmt.null_hl_rules("DapDfNull", tbl))
	vim.list_extend(table_rules, table_fmt.thousands_hl_rules("DapDfThousandsSeparator", tbl))

	for _, r in ipairs(table_rules) do
		table.insert(rules, {
			higroup = r.higroup,
			start = { r.start[1] + DataView.TABLE_START, r.start[2] },
			finish = { r.finish[1] + DataView.TABLE_START, r.finish[2] },
		})
	end
	return rules
end

return DataView
