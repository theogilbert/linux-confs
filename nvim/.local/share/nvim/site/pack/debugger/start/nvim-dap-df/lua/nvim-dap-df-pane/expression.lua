--- @class Expression A user-provided DataFrame / Series expression plus the
--- sort and filter instructions layered on top of it.
---
--- Owns the mutable sort/filter state. Callers manipulate that state through
--- small, intent-revealing methods (toggle_sort, set_filter, ...) and read
--- back the effective python expression to evaluate via `build()`.
---
--- This module is deliberately agnostic of nvim APIs and of the DataView: it
--- only deals with strings and plain tables.
local Expression = {}
Expression.__index = Expression

--- @param base_expr string The user-provided DataFrame / Series expression
function Expression:new(base_expr)
	local self = setmetatable({}, Expression)
	self.base_expr = base_expr
	--- sorts = ordered list of { col_name = string, is_index = bool, ascending = bool }
	--- sorts[1] is the primary sort key, sorts[2] secondary, etc.
	self.sorts = {}
	--- filters = { [filter_key] = condition_string }
	--- filter_key is "index" for the index column, column name otherwise.
	self.filters = {}
	return self
end

--- @return string base_expr The user-provided expression (as entered)
function Expression:get_base_expr()
	return self.base_expr
end

--- Private helper: maps a (col_name, is_index) pair to the filter key used
--- internally. The index column is stored under the fixed key "index" because
--- its display name depends on pandas and may be empty.
local function filter_key_for(col_name, is_index)
	return is_index and "index" or col_name
end

--- Set a filter on the given column. An empty condition clears the filter.
--- @param col_name string
--- @param is_index boolean Whether the column is the DataFrame index
--- @param condition string
function Expression:set_filter(col_name, is_index, condition)
	local key = filter_key_for(col_name, is_index)
	if condition == "" then
		self.filters[key] = nil
	else
		self.filters[key] = condition
	end
end

--- @param col_name string
--- @param is_index boolean
--- @return string|nil condition The active filter condition on the column, or nil
function Expression:get_filter(col_name, is_index)
	return self.filters[filter_key_for(col_name, is_index)]
end

--- @param col_name string
--- @param is_index boolean
function Expression:clear_filter(col_name, is_index)
	self.filters[filter_key_for(col_name, is_index)] = nil
end

--- @return table filters A map { [filter_key] = condition }. Keys follow the
---         same convention as filter_key_for (index col uses "index").
function Expression:get_filters()
	return self.filters
end

--- Find the sort entry for the given column. Returns index and entry, or nil.
--- @param col_name string
--- @param is_index boolean
--- @return integer|nil, table|nil
local function find_sort(sorts, col_name, is_index)
	for i, s in ipairs(sorts) do
		if s.is_index == is_index and (is_index or s.col_name == col_name) then
			return i, s
		end
	end
	return nil, nil
end

--- Toggle the sort state on the given column.
--- If not currently sorted: add as lowest-priority sort (ascending).
--- If ascending: flip to descending.
--- If descending: remove from sort list.
--- @param col_name string
--- @param is_index boolean
function Expression:toggle_sort(col_name, is_index)
	local idx, existing = find_sort(self.sorts, col_name, is_index)
	if existing == nil then
		table.insert(self.sorts, { col_name = col_name, is_index = is_index, ascending = true })
	elseif existing.ascending then
		existing.ascending = false
	else
		table.remove(self.sorts, idx)
	end
end

--- @return table sorts The ordered list of active sorts (primary first). May be empty.
function Expression:get_sorts()
	return self.sorts
end

--- @return table|nil sort The primary (highest-priority) sort, or nil if none.
function Expression:get_sort()
	return self.sorts[1]
end

--- Normalizes a user-entered filter condition into a full pandas .query() clause
--- on the given column reference.
--- @param col_ref string The back-tick quoted column reference (e.g. "`age`")
--- @param condition string The user-entered condition
--- @return string query_clause The full clause (e.g. "`age` > 5")
local function build_query_clause(col_ref, condition)
	-- Allow "= value" as shorthand for "== value"
	if condition:match("^=") and not condition:match("^==") then
		condition = "=" .. condition
	end
	-- If no operator prefix, default to ==
	local has_operator = condition:match("^[=!<>]")
		or condition:match("^%.")
		or condition:match("^in ")
		or condition:match("^not ")
	local query_condition = has_operator and condition or ("== " .. condition)
	-- Expand bare comparisons after and/or/( (e.g. "and < 20" -> "and `col` < 20")
	query_condition = query_condition:gsub("(and%s+)([=!<>])", "%1" .. col_ref .. " %2")
	query_condition = query_condition:gsub("(or%s+)([=!<>])", "%1" .. col_ref .. " %2")
	query_condition = query_condition:gsub("((%()%s*)([=!<>])", "%1" .. col_ref .. " %3")
        query_condition = query_condition:gsub("\"", "'")
	return col_ref .. " " .. query_condition
end

--- Build the effective expression to evaluate. The base expression is wrapped
--- with .query(...) calls for every active filter, and optionally with a
--- sort_values / sort_index call.
--- @return string expr
function Expression:build()
	local expr = self.base_expr

	for col_name, condition in pairs(self.filters) do
		local col_ref = "`" .. col_name .. "`"
		local clause = build_query_clause(col_ref, condition)
		expr = "(" .. expr .. ").query(\"" .. clause .. "\", engine='python')"
	end

	if #self.sorts == 1 then
		local s = self.sorts[1]
		local dir = s.ascending and "True" or "False"
		if s.is_index then
			expr = "(" .. expr .. ").sort_index(ascending=" .. dir .. ")"
		else
			expr = "(" .. expr .. ").sort_values(\"" .. s.col_name .. "\", ascending=" .. dir .. ")"
		end
	elseif #self.sorts > 1 then
		local all_columns = true
		for _, s in ipairs(self.sorts) do
			if s.is_index then
				all_columns = false
				break
			end
		end

		if all_columns then
			local cols, dirs = {}, {}
			for _, s in ipairs(self.sorts) do
				table.insert(cols, "\"" .. s.col_name .. "\"")
				table.insert(dirs, s.ascending and "True" or "False")
			end
			expr = "(" .. expr .. ").sort_values(["
				.. table.concat(cols, ", ")
				.. "], ascending=["
				.. table.concat(dirs, ", ")
				.. "])"
		else
			-- Mixed index + column sorts: apply in reverse priority order so that
			-- the primary sort (sorts[1]) is applied last and becomes dominant.
			for i = #self.sorts, 1, -1 do
				local s = self.sorts[i]
				local dir = s.ascending and "True" or "False"
				if s.is_index then
					expr = "(" .. expr .. ").sort_index(ascending=" .. dir .. ")"
				else
					expr = "(" .. expr .. ").sort_values(\"" .. s.col_name .. "\", ascending=" .. dir .. ")"
				end
			end
		end
	end

	return expr
end

return Expression
