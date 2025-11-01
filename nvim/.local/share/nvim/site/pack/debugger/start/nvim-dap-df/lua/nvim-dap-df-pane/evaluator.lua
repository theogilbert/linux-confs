local dap = require("dap")

local M = {}

local Types = {
    DataFrame = "DataFrame",
    Series = "Series"
}

local function evaluate_expression(session, expr, callback)
	local params = { expression = expr, context = "watch", frameId = session.current_frame.id }
	session:request("evaluate", params, function(err, result)
		if err ~= nil then
			callback(err, nil)
		else
			local lines = result.result:gsub("\\n", "\n"):sub(2, -2)
			callback(nil, { type = result.type, result = lines })
		end
	end)
end

local function check_expression_type(session, expr, callback)
	evaluate_expression(session, expr, function(err, result)
		if err ~= nil then
			callback(err)
		elseif Types[result.type] == nil then
			callback(result.type, "Expression is neither a DataFrame nor a Series, but a " .. result.type)
		else
			callback(result.type, nil)
		end
	end)
end

local function evaluate_df_expression(session, df_expr, callback)
	local limited_expr = df_expr .. ".head(500).to_csv()"
	evaluate_expression(session, limited_expr, callback)
end

local function evaluate_df_dtypes(session, df_expr, type, callback)
    local dtypes_expr = ""
    if type == Types.DataFrame then
	local idx_expr = df_expr .. ".index.dtype.name"
	local cols_expr = "[" .. df_expr .. "[col].dtype.name for col in " .. df_expr .. ".columns]"

	dtypes_expr = "','.join([" .. idx_expr .. ", *" .. cols_expr .. "])"
    else
	local idx_expr = df_expr .. ".index.dtype.name"
	local col_expr = df_expr .. ".dtype.name"

	dtypes_expr = "','.join([" .. idx_expr .. ", " .. col_expr .. "])"
    end

    evaluate_expression(session, dtypes_expr, callback)
end

local function merge_data_and_dtypes(data_ret, dtypes_ret)
	local data_first_eol = data_ret:find("\n")
	return data_ret:sub(1, data_first_eol) .. dtypes_ret .. "\n" .. data_ret:sub(data_first_eol + 1)
end

--- Parses TSNode objects matching queries present in queries/<filetype>/sections.scm
--- @param expression string A python expression resolving to a pd.DataFrame or pd.Series object
--- @param on_result function The callback function called when the evaluation result is ready.
---        Accepts two parameters: err and result. Result will be a string representing the result
---        of the expression in CSV format.
M.evaluate_expression = function(expression, on_result)
	local session = dap.session()

	if session == nil then
		on_result("No active DAP session", nil)
		return
	end

	if not session.current_frame then
		on_result("No current frame", nil)
		return
	end

	check_expression_type(session, expression, function(type, err)
                -- TODO : send type in callback, and use that type to evaluate df_types (currently fails in case of Series as no columns)
		if err ~= nil then
			on_result(err, nil)
			return
		end

		evaluate_df_expression(session, expression, function(err, data_ret)
			if err ~= nil then
				on_result(err, nil)
				return
			end

			evaluate_df_dtypes(session, expression, type, function(err, dtypes_ret)
				if err ~= nil then
					on_result(err, nil)
					return
				end

				local merged = merge_data_and_dtypes(data_ret.result, dtypes_ret.result)
				on_result(nil, merged)
			end)
		end)
	end)
end

return M
