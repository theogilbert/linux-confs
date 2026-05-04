local ExpressionEvaluator = require("nvim-dap-df-pane.evaluator")
local Expression = require("nvim-dap-df-pane.expression")
local table_fmt = require("utilities.table")

local DataView = {}
DataView.__index = DataView

--- @class State The current state of the data view
local State = {
	--- The expression is being evaluated and the data view is waiting for its result
	EVALUATING = 0,
	--- The expression has been evaluated and the data view is ready to be rendered
	READY = 1,
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
--- @field expression Expression The expression to evaluate
--- @field state State The current state of the data view
--- @field shape table A table containing the number of columns and rows in the data
--- @field lines table A sequence of lines to display in the data view. Represents the actual data.

--- @param expression string The expression to evaluate and display
--- @param limit integer How many rows to display at most
function DataView:new(expression, limit)
	local self = setmetatable({}, DataView)

	self.limit = limit
	self.expression = Expression:new(expression)
	self.state = State.EVALUATING
	self.shape = nil
	self.lines = {}
	self.evaluator = ExpressionEvaluator:new()

	return self
end

--- Get column info under the cursor (1-indexed column, column name, is_index),
--- or nil if the cursor is not on a data column.
--- @return string|nil col_name
--- @return boolean|nil is_index
function DataView:get_column_under_cursor(cursor_col)
	local col_idx = self:get_column_at_cursor(cursor_col)
	if col_idx == nil then
		return nil
	end
	local col_name = self:get_column_name(col_idx)
	if col_name == nil then
		return nil
	end
	return col_name, self:is_index_column(col_idx)
end

function DataView:sort_column_under_cursor(virtual_col)
	local col_name, is_index = self:get_column_under_cursor(virtual_col)
	if col_name ~= nil then
            self.expression:toggle_sort(col_name, is_index)
	end
end

function DataView:get_column_filter_under_cursor(virtual_col)
	local col_name, is_index = self:get_column_under_cursor(virtual_col)
	if col_name == nil then
            return nil
	end

        return self.expression:get_filter(col_name, is_index)
end

function DataView:filter_column_under_cursor(virtual_col, condition)
        if self.expression == nil then
		return
	end

	local col_name, is_index = self:get_column_under_cursor(virtual_col)
	if col_name ~= nil then
                self.expression:set_filter(col_name, is_index, condition)
	end
end

function DataView:clear_filter_under_cursor(virtual_col)
	local col_name, is_index = self:get_column_under_cursor(virtual_col)
	if col_name ~= nil then
            self.expression:clear_filter(col_name, is_index)
	end
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


--- Decorate the raw display lines with sort arrows on sorted column headers.
--- When multiple sorts are active, a priority number is shown (1▲, 2▼, …).
--- @param display_lines table A deep-copy of the structured CSV rows
--- @param sorts table[] Ordered list of { col_name, is_index, ascending }
--- @return integer[] sort_col_indices 1-indexed column positions of sorted columns
local function apply_sort_decoration(display_lines, sorts)
	if sorts == nil or #sorts == 0 then
		return {}
	end

	local sort_col_indices = {}
	local multi = #sorts > 1

	for priority, sort in ipairs(sorts) do
		for i, col_name in ipairs(display_lines[1]) do
			local is_index = (i == 1)
			local matches = sort.is_index == is_index
				and (is_index or col_name == sort.col_name)
			if matches then
				local arrow = sort.ascending and "▲" or "▼"
				local label = multi and (" " .. priority .. arrow) or (" " .. arrow)
				display_lines[1][i] = col_name .. label
				table.insert(sort_col_indices, i)
				break
			end
		end
	end

	return sort_col_indices
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

--- @alias FailureCallback fun(err: string)

--- Re-evaluate the given expression and signal the caller when the result is
--- ready to be rendered.
---
--- The Expression object is the single source of truth: its base form drives
--- the prompt line, `build()` produces the python expression sent to the
--- evaluator, and its sort/filter state drives the display decorations.
--- @param on_ready function Called whenever the view has been refreshed and is ready to be rendered.
--- @param on_failed FailureCallback Called whenever the view failed to be rendered.
--- @param use_cache boolean|nil Whether the evaluator may reuse cached values. Defaults to true.
---        Set to false when the DAP context may have changed.
function DataView:refresh(on_ready, on_failed, use_cache)
	self.state = State.EVALUATING
	on_ready()

	self.evaluator:evaluate(self.expression, self.limit, function(data, shape, err)
            local csv_table = nil
		if err ~= nil then
			local err_repr = vim.inspect(err)
			if err.message ~= nil then
				err_repr = err.message
			end
                        on_failed("Failed to evaluate expression `" .. self.expression:build() .. "`: " .. err_repr)
                else
                        csv_table, fmt_err = table_fmt.from_csv(data, 2)
                        if fmt_err ~= nil then
                                on_failed("Failed to format result: " .. vim.inspect(fmt_err))
                        end
		end

                if err == nil and fmt_err == nil then
                    -- Store clean column names for lookups
                    self.column_names = vim.deepcopy(csv_table.lines[1])

                    -- Build display lines (copy) with sort/filter decorations
                    local display_lines = vim.deepcopy(csv_table.lines)
                    self.sort_col_indices = apply_sort_decoration(display_lines, self.expression:get_sorts())
                    self.header_lines = apply_filter_decoration(display_lines, self.column_names, self.expression:get_filters())

                    csv_table = table_fmt.from_structured_data(display_lines, self.header_lines)
                    self.table = csv_table
                    self.lines = csv_table.text
                    self.shape = shape
                end

                -- Failure or not, we go back to a ready state to re-render
		self.state = State.READY
		on_ready()
	end, use_cache)
end

--- Generates the data shape part of the prompt line
---
--- @param self DataView The DataView for which to generate the shape representation
--- @return string shape_repr A representation of the data shape, in the form of [num_cols,num_rows]
local function get_shape_repr(self)
	return self.shape and "[" .. self.shape[1] .. "×" .. self.shape[2] .. "]" or ""
end

local LOADING_SYMBOL = "Loading... "

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
        local base_expr = self.expression:get_base()
        base_expr = string.gsub(base_expr, '%s+', ' ')

	local loading = ""
	if self.state == State.EVALUATING then
		loading = LOADING_SYMBOL
	end

	local base_prompt = loading .. shape_repr .. " ➜ " .. base_expr
	local chars_to_add = math.max(0, width - vim.api.nvim_strwidth(base_prompt))

	return base_prompt .. string.rep(" ", chars_to_add)
end



--- Generate the highlighting rules which will be applied on the prompt line.
local function build_hl_rules_for_prompt(self)
	local shape_start = self.state == State.EVALUATING and #LOADING_SYMBOL or 0
	local shape_end = shape_start + #get_shape_repr(self)

	local rules = {}

	if self.state == State.EVALUATING then
		table.insert(rules, {
			higroup = "DapDfPromptLoading",
			start = { 0, 0 },
			finish = { 0, shape_start },
		})
	end

	if self.shape ~= nil then
		table.insert(rules, {
			higroup = "DapDfPromptShape",
			start = { 0, shape_start },
			finish = { 0, shape_end },
		})
	end

        table.insert(rules, { higroup = "DapDfPrompt", start = { 0, shape_end }, finish = { 0, -1 } })

	return rules
end

--- Returns the leftcol values that align the view to each column boundary.
--- boundary[i] is the leftcol needed to show column i at the left edge.
--- Returns an empty table when no table is loaded yet.
--- @return integer[]
function DataView:get_column_boundaries()
	if self.table == nil then
		return {}
	end
	local boundaries = { 0 }
	local pos = 0
	for _, w in ipairs(self.table.columns_width) do
		pos = pos + w + 1
		table.insert(boundaries, pos)
	end
	return boundaries
end

--- Returns a render of the evaluation result of the input expression
--- @return table lines The sequence of the lines of the render
function DataView:get_lines()
	local first_line_width = vim.api.nvim_strwidth(self.lines[1] or "")
	local prompt_line = get_prompt_line(self, first_line_width)

	local lines = { prompt_line }
	return vim.list_extend(lines, self.lines)
end

--- Byte length of the │ separator character (U+2502, 3 UTF-8 bytes, 1 display col).
local SEP_BYTES = #table_fmt.COL_SEPARATOR

--- Compute the byte start/finish (0-indexed, finish exclusive) of each column
--- cell in a formatted table line. Accounts for multi-byte characters in the
--- cell text so the positions are usable directly as vim.hl.range byte offsets.
--- @param row table|nil The structured row (array of cell strings) for this line.
--- @param cols_width integer[] Display widths from FormattedTable.columns_width.
--- @return {[1]:integer,[2]:integer}[] Byte {start, finish} pairs, one per column.
local function column_byte_positions(row, cols_width)
	local positions = {}
	local byte_pos = SEP_BYTES  -- skip leading │
	for i, width in ipairs(cols_width) do
		local cell_bytes
		if row and row[i] then
			local text = row[i]
			-- Padding is all ASCII spaces: total_bytes = padding_chars + byte_len(text)
			local padding = width - vim.api.nvim_strwidth(text)
			cell_bytes = padding + #text
		else
			cell_bytes = width  -- fallback: assume ASCII
		end
		positions[i] = { byte_pos, byte_pos + cell_bytes }
		byte_pos = byte_pos + cell_bytes + SEP_BYTES
	end
	return positions
end

--- Build per-column highlight rules for one line of the buffer.
--- @param higroup string
--- @param line integer 0-indexed buffer row (also the 1-indexed index into table.lines for header rows)
--- @param table_data table|nil FormattedTable returned by table_fmt
--- @return table[]
local function build_hl_rules_for_columns(higroup, line, table_data)
	local content_rules = {}
	if table_data == nil then
		return content_rules
	end

	local row = table_data.lines[line]
	local positions = column_byte_positions(row, table_data.columns_width)

	for i, pos in ipairs(positions) do
		content_rules[i] = {
			higroup = higroup,
			start = { line, pos[1] },
			finish = { line, pos[2] },
		}
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
		local header_col_rules = build_hl_rules_for_columns("DapDfHeaderRow", 1, self.table)
		local column_rules = {
			build_hl_rules_for_prompt(self),
			header_col_rules,
			build_hl_rules_for_columns("DapDfTypeRow", 2, self.table),
		}
		if self.header_lines == 3 then
			table.insert(column_rules, build_hl_rules_for_columns("DapDfFilterRow", 3, self.table))
		end
		hl_rules = vim.iter(column_rules)
			:flatten()
			:totable()

		-- Reuse the byte positions already computed for the header row.
		if self.sort_col_indices ~= nil and #self.sort_col_indices > 0 then
			for _, sort_idx in ipairs(self.sort_col_indices) do
				local base = header_col_rules[sort_idx]
				if base then
					table.insert(hl_rules, {
						higroup = "DapDfSortedColumn",
						start = base.start,
						finish = base.finish,
					})
				end
			end
		end
	end

	return hl_rules
end

return DataView
