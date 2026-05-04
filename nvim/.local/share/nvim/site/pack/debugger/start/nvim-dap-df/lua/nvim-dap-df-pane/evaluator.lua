local dap = require("dap")

--- @enum Types
local Types = {
	DataFrame = "DataFrame",
	Series = "Series",
}

--- @class EvaluationCache Evaluating an expression involves multiple different DAP
--- requests. When re-evaluating an expression that has already been evaluated from
--- the same DAP context, a lot of the requests should return the same value.
--- @field type Types The type of the object represented by the expression
--- @field dtypes table|nil The dtypes of the columns
--- @field row_count integer The number of rows present in the table
--- @field col_count integer The number of columns present in the table

--- Serialize the filters table to a stable string, for cache key comparison.
local function filters_signature(filters)
	local keys = {}
	for k in pairs(filters) do
		table.insert(keys, k)
	end
	table.sort(keys)
	local parts = {}
	for _, k in ipairs(keys) do
		table.insert(parts, k .. "\1" .. filters[k])
	end
	return table.concat(parts, "\2")
end

local EvaluationCache = {}
EvaluationCache.__index = EvaluationCache

function EvaluationCache:new()
	local self = setmetatable({}, EvaluationCache)
	self:clear()
	return self
end

--- Drop all cached values. Used when the DAP context may have changed and none
--- of the cached values can be trusted anymore.
function EvaluationCache:clear()
	self.base_expr = nil
	self.filters_sig = nil
	self.type = nil
	self.dtypes = nil
	self.col_count = nil
	self.row_count = nil
end

--- Update the cache's keys based on the current expression, invalidating the
--- fields whose key changed.
--- - A change in the base expression invalidates every field.
--- - A change in filters (for the same base expression) only invalidates row_count.
--- - Sort changes never invalidate anything.
--- @param base_expr string
--- @param filters table
function EvaluationCache:update_keys(base_expr, filters)
	local new_filters_sig = filters_signature(filters)
	if self.base_expr ~= base_expr then
		self.type = nil
		self.dtypes = nil
		self.col_count = nil
		self.row_count = nil
	elseif self.filters_sig ~= new_filters_sig then
		self.row_count = nil
	end
	self.base_expr = base_expr
	self.filters_sig = new_filters_sig
end

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
	if data_first_eol == nil then
		return data_ret .. "\n" .. dtypes_ret .. "\n"
	end
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

--- Send a request to DAP.
--- @param context string The DAP context to use for the request
local function evaluate_expression(session, expr, context, callback)
	local params = { expression = expr, context = context, frameId = session.current_frame.id }
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
	evaluate_expression(session, type_expr, "watch", function(err, result)
		if err ~= nil then
			callback(err, result)
		else
			callback(nil, result:sub(2, -2))
		end
	end)
end

--- Evaluate an expression and update the specified field of the given state
--- with the result. If `on_cache` is provided, it is called with the parsed
--- value before the state is updated, so the caller can persist it in a cache.
--- @param state EvaluationState
--- @param field string The field of the state to update
--- @param expr string The expression to evaluate
--- @param str_value boolean True if the expression resolves to a string that must be properly escaped
--- @param session any The DAP session object
--- @param context string The DAP context to use for the request
--- @param on_cache function|nil Optional callback that receives the parsed value
local function evaluate_state_field(state, field, expr, str_value, session, context, on_cache)
	evaluate_expression(session, expr, context, function(err, result)
		if err ~= nil then
			fail_evaluation_state(state, err)
		else
			local value = result
			if str_value then
				value = value:gsub("\\n", "\n"):sub(2, -2)
			end

			if on_cache then
				on_cache(value)
			end

			update_evaluation_state(state, field, value)
		end
	end)
end

local function evaluate_df_data(state, df_expr, limit, session)
	local limited_expr = df_expr .. ".head(" .. limit .. ").to_csv(na_rep=\"pd.NA\")"
        -- clipboard context to make sure not to have data truncated.
	evaluate_state_field(state, "data", limited_expr, true, session, "clipboard")
end

local function evaluate_df_dtypes(state, df_expr, session, on_cache)
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

	evaluate_state_field(state, "dtypes", dtypes_expr, true, session, "watch", on_cache)
end

local function evaluate_col_count(state, df_expr, session, on_cache)
	if state.type == Types.Series then
		if on_cache then
			on_cache("1")
		end
		update_evaluation_state(state, "col_len", "1")
	else
		local cols_count_expr = "len(" .. df_expr .. ".columns)"
		evaluate_state_field(state, "col_len", cols_count_expr, false, session, "watch", on_cache)
	end
end

local function evaluate_row_count(state, df_expr, session, on_cache)
	local row_count_expr = "len(" .. df_expr .. ")"
	evaluate_state_field(state, "row_len", row_count_expr, false, session, "watch", on_cache)
end

--- @class ExpressionEvaluator Evaluates a python DataFrame/Series expression by
--- collecting data, dtypes, and shape through multiple DAP evaluations.
--- @field state EvaluationState|nil The in-flight evaluation state
--- @field cache EvaluationCache Cached values reused across evaluations
local ExpressionEvaluator = {}
ExpressionEvaluator.__index = ExpressionEvaluator

function ExpressionEvaluator:new()
	local self = setmetatable({}, ExpressionEvaluator)
	self.state = nil
	self.cache = EvaluationCache:new()
	return self
end

--- @alias EvaluationCallback fun(data: table|nil, shape: table|nil, err: string|nil)

--- Evaluate and collect various information about the provided expression.
--- @param expression Expression A python expression resolving to a pd.DataFrame or pd.Series object
--- @param limit number The maximum number of rows to fetch
--- @param on_result EvaluationCallback The callback function called when the evaluation result is ready.
---        Accepts three parameters:
---        - data (table) - A sequence oof lines representing the data in CSV format
---        - shape (table) - A list containing two numbers: the number of columns and rows in the data.
---        - err (string|nil) - If the evaluation fails, this parameter will be set to the error message.
--- @param use_cache boolean|nil Whether to reuse previously cached values. Defaults to true.
---        Set to false when the DAP context may have changed (e.g. step, stack navigation).
function ExpressionEvaluator:evaluate(expression, limit, on_result, use_cache)
	if use_cache == nil then
		use_cache = true
	end

	local expr = expression:build()
	local base_expr = expression:get_base()
	local filters = expression:get_filters()

	local session = dap.session()

	if session == nil then
		on_result(nil, nil, "No active DAP session")
		return
	end

	if not session.current_frame then
		on_result(nil, nil, "No current frame")
		return
	end

	if not use_cache then
		self.cache:clear()
	end
	self.cache:update_keys(base_expr, filters)

	local cache = self.cache

	local function proceed(type)
                -- Once the evaluated object's type is validated, collect all other data
		local state, init_err = init_evaluation_state(on_result, type)
		if init_err ~= nil then
			on_result(nil, nil, init_err)
			return
		end

		self.state = state

		-- Data depends on sort, filter, and limit, so it's always fetched fresh.
		evaluate_df_data(state, expr, limit, session)

		-- dtypes and col_count depend only on the base expression.
		if cache.dtypes ~= nil then
			update_evaluation_state(state, "dtypes", cache.dtypes)
		else
			evaluate_df_dtypes(state, base_expr, session, function(v)
				cache.dtypes = v
			end)
		end

		if cache.col_count ~= nil then
			update_evaluation_state(state, "col_len", cache.col_count)
		else
			evaluate_col_count(state, base_expr, session, function(v)
				cache.col_count = v
			end)
		end

		-- row_count depends on the base expression and filters, but not sort.
		if cache.row_count ~= nil then
			update_evaluation_state(state, "row_len", cache.row_count)
		else
			evaluate_row_count(state, expr, session, function(v)
				cache.row_count = v
			end)
		end
	end

	if cache.type ~= nil then
		proceed(cache.type)
	else
		evaluate_expression_type(session, base_expr, function(err, type)
			if err ~= nil then
				on_result(nil, nil, err)
				return
			end
			cache.type = type
			proceed(type)
		end)
	end
end

return ExpressionEvaluator
