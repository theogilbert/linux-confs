local dap = require("dap")

local M = {}

--- @enum Types
local Types = {
	DataFrame = "DataFrame",
	Series = "Series",
}

--- @class EvaluationState Given an input DataFrame/Series expression, multiple expressions
--- will need to be evaluated to collect sufficient information to render the data.
--- This class represents the intermediary state of this collection.
---
--- @field callback function Function to call when all information have been collected.
---                  It will be called with the parameters `error`, `data` and `shape`.
--- @field type Types The class name of the object evaluated by the expression
--- @field sent boolean True if the state has been sent to the callback yet.
---     Prevents duplicate calls in case of multiple errors.
--- @field data table The list of CSV lines representing the column names and data
--- @field row_len number|nil The number of rows in the DataFrame/Series
--- @field col_len number|nil The number of columns in the DataFrame/Series
--- @field dtypes table|nil The CSV line representing the dtypes of the columns

local function init_evaluation_state(callback, type)
	if Types[type] == nil then
		return nil, "Expression is neither a DataFrame nor a Series, but a " .. type
	end

	return { callback = callback, type = type, sent = false }, nil
end

local function merge_data_and_dtypes(data_ret, dtypes_ret)
	local data_first_eol = data_ret:find("\n")
	return data_ret:sub(1, data_first_eol) .. dtypes_ret .. "\n" .. data_ret:sub(data_first_eol + 1)
end

local function send_if_state_ready(state)
	local attrs = { "row_len", "col_len", "data", "dtypes" }
	for _, field in ipairs(attrs) do
		if state[field] == nil then
			return
		end
	end

	state.sent = true

	local merged = merge_data_and_dtypes(state.data, state.dtypes)
	local shape = { state.col_len, state.row_len }

	state.callback(merged, shape, nil)
end

local function fail_evaluation_state(state, err)
	if state.sent then
		return
	end

	state.sent = true
	state.callback(nil, nil, err)
end

local function update_evaluation_state(state, field, value)
	if state.sent then
		return
	end

	state[field] = value

	send_if_state_ready(state)
end

local function evaluate_expression(session, expr, callback)
	local params = { expression = expr, context = "watch", frameId = session.current_frame.id }
	session:request("evaluate", params, function(err, result)
		if err ~= nil then
			callback(err, nil)
		else
			callback(nil, result.result)
		end
	end)
end

local function evaluate_expression_type(session, expr, callback)
	local type_expr = expr .. ".__class__.__name__"
	evaluate_expression(session, type_expr, function(err, result)
		if err ~= nil then
			callback(err, result)
                else
                    callback(nil, result:sub(2, -2))
		end

	end)
end

--- Evaluate an expression and updates the specified field of the given EvaluationState
--- with the result.
--- @param state EvaluationState The state to update with the evaluation result
--- @param field string The field of the state to update
--- @param expr string The expression to evaluate
--- @param str_value boolean True if the expression resolves to a string that must be properly escaped,
---                          False otherwise.
--- @param session any The DAP session object
local function evaluate_state_field(state, field, expr, str_value, session)
	evaluate_expression(session, expr, function(err, result)
		if err ~= nil then
			fail_evaluation_state(state, err)
		else
			local value = result
			if str_value then
				value = value:gsub("\\n", "\n"):sub(2, -2)
			end

			update_evaluation_state(state, field, value)
		end
	end)
end

local function evaluate_df_data(state, df_expr, limit, session)
	local limited_expr = df_expr .. ".head(" .. limit .. ").to_csv()"
	evaluate_state_field(state, "data", limited_expr, true, session)
end

local function evaluate_df_dtypes(state, df_expr, session)
	local dtypes_expr = ""
	if state.type == Types.DataFrame then
		local idx_expr = df_expr .. ".index.dtype.name"
		local cols_expr = "[" .. df_expr .. "[col].dtype.name for col in " .. df_expr .. ".columns]"

		dtypes_expr = "','.join([" .. idx_expr .. ", *" .. cols_expr .. "])"
	else
		local idx_expr = df_expr .. ".index.dtype.name"
		local col_expr = df_expr .. ".dtype.name"

		dtypes_expr = "','.join([" .. idx_expr .. ", " .. col_expr .. "])"
	end

	evaluate_state_field(state, "dtypes", dtypes_expr, true, session)
end

local function evaluate_col_count(state, df_expr, session)
	if state.type == Types.Series then
		update_evaluation_state(state, "col_len", "1")
	else
		local cols_count_expr = "len(" .. df_expr .. ".columns)"
		evaluate_state_field(state, "col_len", cols_count_expr, false, session)
	end
end

local function evaluate_row_count(state, df_expr, session)
	local row_count_expr = "len(" .. df_expr .. ")"
	evaluate_state_field(state, "row_len", row_count_expr, false, session)
end

--- @alias EvaluationCallback fun(data: table|nil, shape: table|nil, err: string|nil)

--- Evaluate and collect various information about the provided expression.
--- @param expression string A python expression resolving to a pd.DataFrame or pd.Series object
--- @param limit number The maximum number of rows to fetch
--- @param on_result EvaluationCallback The callback function called when the evaluation result is ready.
---        Accepts three parameters:
---        - data (table) - A sequence oof lines representing the data in CSV format
---        - shape (table) - A list containing two numbers: the number of columns and rows in the data.
---        - err (string|nil) - If the evaluation fails, this parameter will be set to the error message.
M.evaluate_expression = function(expression, limit, on_result)
	local session = dap.session()

	if session == nil then
		on_result(nil, nil, "No active DAP session")
		return
	end

	if not session.current_frame then
		on_result(nil, nil, "No current frame")
		return
	end

	evaluate_expression_type(session, expression, function(err, type)
		if err ~= nil then
			on_result(nil, nil, err)
			return
		end

		local state, err = init_evaluation_state(on_result, type)

		if err ~= nil then
			on_result(nil, nil, err)
		else
			evaluate_df_data(state, expression, limit, session)
			evaluate_df_dtypes(state, expression, session)
			evaluate_row_count(state, expression, session)
			evaluate_col_count(state, expression, session)
		end
	end)
end

return M
