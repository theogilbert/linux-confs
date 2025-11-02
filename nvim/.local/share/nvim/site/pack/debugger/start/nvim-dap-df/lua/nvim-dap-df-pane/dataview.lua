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

--- @class DataView Generates the content of the DAP DF Pane buffer,
--- given a valid DataFrame / Series expression.
--- @field limit number The maximum number of rows to display
--- @field expr string The valid python expression which evaluates to a DataFrame or a Series
--- @field state State The current state of the data view
--- @field shape table A table containing the number of columns and rows in the data
--- @field lines table A sequence of lines to display in the data view. Represents the actual data.
function DataView:new(expr, limit)
	local self = setmetatable({}, DataView)

	self.limit = limit
	self.expr = expr
	self.state = State.EVALUATING
	self.shape = nil
	self.lines = {}

	return self
end

--- Re-evaluate the expression and signal the caller when the result is ready to be rendered.
--- @param on_ready function A callback function (no arguments) that is called when the data
---                  view is ready to be rendered.
function DataView:refresh(on_ready)
	self.state = State.EVALUATING
	on_ready()

	evaluator.evaluate_expression(self.expr, self.limit, function(data, shape, err)
		if err ~= nil then
			self.state = State.FAILED
			self.lines = { "Failed to evaluate expression:" }

			local err_lines = vim.split(vim.inspect(err), "\n")
			vim.list_extend(self.lines, err_lines)

			on_ready()
			return
		end

		local table, fmt_err = table_fmt.from_csv(data, 2)
		if fmt_err ~= nil then
			self.state = State.FAILED
			self.lines = { "Failed to format result: " .. vim.inspect(fmt_err) }
			on_ready()
			return
		end

		self.table = table
		self.lines = table.text
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
		hl_rules = vim.iter({
			build_hl_rules_for_prompt(self),
			build_hl_rules_for_columns("DapDfHeaderRow", 1, self.table),
			build_hl_rules_for_columns("DapDfTypeRow", 2, self.table),
		})
			:flatten()
			:totable()
	end

	return hl_rules
end

return DataView
