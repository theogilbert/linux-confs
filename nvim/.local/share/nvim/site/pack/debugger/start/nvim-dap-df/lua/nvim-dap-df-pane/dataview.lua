local evaluator = require("nvim-dap-df-pane.evaluator")
local table_fmt = require("utilities.table")

local DataView = {}
DataView.__index = DataView

--- @class State The current state of the data view
local State = {
	--- The expression is being evaluated and the data view is waiting for its result
	EVALUATING = 0,
	--- The expression has been evaluated and the data view is ready to be rendered
	READY = 1,
	--- The expression failed to be evaluated
	FAILED = 2,
}

--- @class DataView Read-only component that evaluates a python DataFrame /
--- Series expression and formats the result as a table ready to be rendered.
---
--- The DataView does not own the expression nor any sort/filter state: those
--- are passed in on each refresh() call via a `spec` table. The DataView is
--- responsible for:
---   * driving the evaluator,
---   * formatting the evaluation result as a table,
---   * decorating the table with sort arrows / a filter row when the spec
---     describes them,
---   * mapping cursor position → column info.
---
--- The DataView is agnostic of nvim UI APIs (no window/buffer/cursor calls).
--- @field limit number The maximum number of rows to display
--- @field expr string The base expression shown in the prompt line
--- @field state State The current state of the data view
--- @field shape table A table containing the number of columns and rows in the data
--- @field lines table A sequence of lines to display in the data view. Represents the actual data.
function DataView:new(limit)
	local self = setmetatable({}, DataView)

	self.limit = limit
	self.expr = ""
	self.state = State.EVALUATING
	self.shape = nil
	self.lines = {}

	return self
end

--- Returns the column name at the given 1-indexed column position in the table.
--- Column 1 is the DataFrame index.
--- @param col_idx integer 1-indexed column in the formatted table
--- @return string|nil col_name The column name, or nil if invalid
function DataView:get_column_name(col_idx)
	if self.column_names == nil then
		return nil
	end
	if col_idx < 1 or col_idx > #self.column_names then
		return nil
	end
	return self.column_names[col_idx]
end

--- Returns whether the given column is the DataFrame index.
--- @param col_idx integer 1-indexed column
--- @return boolean
function DataView:is_index_column(col_idx)
	return col_idx == 1
end

--- Returns the 1-indexed column under the given virtual cursor position, or
--- nil if the cursor is on a column separator / outside the table.
--- @param virtual_col integer 1-indexed virtual (display) column of the cursor
--- @return integer|nil
function DataView:get_column_at_cursor(virtual_col)
	if self.table == nil then
		return nil
	end
	return table_fmt.get_column_at_cursor(self.table.columns_width, virtual_col)
end

--- Returns whether the last evaluation failed.
function DataView:has_failed()
	return self.state == State.FAILED
end

--- Decorate the raw display lines with the sort arrow on the sorted column's
--- header. Records the sorted column index (1-indexed) for later highlighting.
--- @param display_lines table A deep-copy of the structured CSV rows
--- @param sort table|nil { col_name, is_index, ascending }
--- @return integer|nil sort_col_idx
local function apply_sort_decoration(display_lines, sort)
	if sort == nil then
		return nil
	end

	for i, col_name in ipairs(display_lines[1]) do
		local is_index = (i == 1)
		local matches = sort.is_index == is_index
			and (is_index or col_name == sort.col_name)
		if matches then
			local arrow = sort.ascending and " ▲" or " ▼"
			display_lines[1][i] = col_name .. arrow
			return i
		end
	end
	return nil
end

--- Insert a filter row into the header (right after the type row) when there
--- are active filters. Returns the number of header lines after insertion.
--- @param display_lines table
--- @param column_names table The raw column names (header row, before decoration)
--- @param filters table|nil { [filter_key] = condition }
--- @return integer header_count
local function apply_filter_decoration(display_lines, column_names, filters)
	if filters == nil or next(filters) == nil then
		return 2
	end

	local filter_cells = {}
	for i, col_name in ipairs(column_names) do
		local filter_key = (i == 1) and "index" or col_name
		filter_cells[i] = filters[filter_key] or ""
	end
	table.insert(display_lines, 3, filter_cells)
	return 3
end

--- Re-evaluate the given expression and signal the caller when the result is
--- ready to be rendered.
---
--- The Expression object is the single source of truth: its base form drives
--- the prompt line, `build()` produces the python expression sent to the
--- evaluator, and its sort/filter state drives the display decorations.
--- @param expression Expression
--- @param on_ready function Called whenever the view should be re-rendered.
function DataView:refresh(expression, on_ready)
	self.expr = expression:get_base_expr()
	self.state = State.EVALUATING
	on_ready()

	evaluator.evaluate_expression(expression:build(), self.limit, function(data, shape, err)
		if err ~= nil then
			self.state = State.FAILED
			self.lines = { "Failed to evaluate expression:" }

			local err_repr = vim.inspect(err)
			if err.message ~= nil then
				err_repr = err.message
			end
			self.error = err_repr

			local err_lines = vim.split(err_repr, "\n")
			vim.list_extend(self.lines, err_lines)

			on_ready()
			return
		end

		local csv_table, fmt_err = table_fmt.from_csv(data, 2)
		if fmt_err ~= nil then
			self.state = State.FAILED
			self.error = "Failed to format result: " .. vim.inspect(fmt_err)
			self.lines = { self.error }
			on_ready()
			return
		end

		-- Store clean column names for lookups
		self.column_names = vim.deepcopy(csv_table.lines[1])

		-- Build display lines (copy) with sort/filter decorations
		local display_lines = vim.deepcopy(csv_table.lines)
		self.sort_col_idx = apply_sort_decoration(display_lines, expression:get_sort())
		self.header_lines = apply_filter_decoration(display_lines, self.column_names, expression:get_filters())

		csv_table = table_fmt.from_structured_data(display_lines, self.header_lines)
		self.table = csv_table
		self.lines = csv_table.text
		self.shape = shape
		self.state = State.READY

		on_ready()
	end)
end

--- Generates the data shape part of the prompt line
---
--- @param self DataView The DataView for which to generate the shape representation
--- @return string shape_repr A representation of the data shape, in the form of [num_cols,num_rows]
local function get_shape_repr(self)
	return self.shape and "[" .. self.shape[1] .. "×" .. self.shape[2] .. "]" or ""
end

--- Generates the whole prompt line for the dataview
---
--- @param self DataView The DataView for which to generate the shape representation
--- @param width number The width of the table representing the data, in characters.
--- @return string prompt A line containing:
---          - the evaluated expression
---          - the shape of its resulting data
---          - Optionally a label indicating that the data is being evaluated.
local function get_prompt_line(self, width)
	local shape_repr = get_shape_repr(self)

	local loading = ""
	if self.state == State.EVALUATING then
		loading = " Loading..."
	end

	local base_prompt = "➜ " .. self.expr .. " " .. shape_repr .. loading
	local chars_to_add = math.max(0, width - vim.api.nvim_strwidth(base_prompt))

	return base_prompt .. string.rep(" ", chars_to_add)
end

--- Generate the highlighting rules which will be applied on the prompt line.
local function build_hl_rules_for_prompt(self)
	local shape_start = 3 + #self.expr + 2
	local shape_end = shape_start + #get_shape_repr(self)

	local rules = {
		{ higroup = "DapDfPrompt", start = { 0, 0 }, finish = { 0, -1 } },
	}

	if self.shape ~= nil then
		table.insert(rules, {
			higroup = "DapDfPromptShape",
			start = { 0, shape_start },
			finish = { 0, shape_end },
		})
	end

	if self.state == State.EVALUATING then
		table.insert(rules, {
			higroup = "DapDfPromptLoading",
			start = { 0, shape_end + 1 },
			finish = { 0, -1 },
		})
	end

	return rules
end

--- Returns a render of the evaluation result of the input expression
--- @return table lines The sequence of the lines of the render
function DataView:get_lines()
	local first_line_width = vim.api.nvim_strwidth(self.lines[1] or "")
	local prompt_line = get_prompt_line(self, first_line_width)

	local lines = { prompt_line }
	return vim.list_extend(lines, self.lines)
end

local function build_hl_rules_for_columns(higroup, line, table)
	local content_rules = {}

	if table == nil then
		return content_rules
	end

	local cur_col = 1
	for i, width in ipairs(table.columns_width) do
		content_rules[i] = {
			higroup = higroup,
			start = { line, cur_col },
			finish = { line, cur_col + width + 2 },
		}

		cur_col = cur_col + width + 3
	end

	return content_rules
end

--- Returns the rules used to highlight the expression's rendered result.
function DataView:get_hl_rules()
	local hl_rules = {}
	if self.state == State.FAILED then
		hl_rules = {
			{ higroup = "DapDfError", start = { 1, 0 }, finish = { #self.lines + 1, -1 } },
		}
	else
		local column_rules = {
			build_hl_rules_for_prompt(self),
			build_hl_rules_for_columns("DapDfHeaderRow", 1, self.table),
			build_hl_rules_for_columns("DapDfTypeRow", 2, self.table),
		}
		if self.header_lines == 3 then
			table.insert(column_rules, build_hl_rules_for_columns("DapDfFilterRow", 3, self.table))
		end
		hl_rules = vim.iter(column_rules)
			:flatten()
			:totable()

		if self.sort_col_idx ~= nil and self.table ~= nil then
			local cur_col = 1
			for i, width in ipairs(self.table.columns_width) do
				if i == self.sort_col_idx then
					table.insert(hl_rules, {
						higroup = "DapDfSortedColumn",
						start = { 1, cur_col },
						finish = { 1, cur_col + width + 2 },
					})
					break
				end
				cur_col = cur_col + width + 3
			end
		end
	end

	return hl_rules
end

return DataView
