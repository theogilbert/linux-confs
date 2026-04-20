local Expression = require("nvim-dap-df-pane.expression")

describe("Expression", function()
	describe("new()", function()
		it("stores the base expression", function()
			local b = Expression:new("df")
			assert.equals("df", b:get_base_expr())
		end)

		it("starts with no sort and no filters", function()
			local b = Expression:new("df")
			assert.same({}, b:get_sorts())
			assert.same({}, b:get_filters())
		end)
	end)

	describe("build()", function()
		it("returns the base expression when no sort or filter is set", function()
			local b = Expression:new("df.head(100)")
			assert.equals("df.head(100)", b:build())
		end)
	end)

	describe("set_filter()", function()
		it("stores a filter under the column name for regular columns", function()
			local b = Expression:new("df")
			b:set_filter("age", false, "> 5")
			assert.equals("> 5", b:get_filter("age", false))
		end)

		it("stores a filter under 'index' for the index column", function()
			local b = Expression:new("df")
			b:set_filter("my_index", true, "> 0")
			-- Retrieval must use is_index=true regardless of the column's display name
			assert.equals("> 0", b:get_filter("my_index", true))
			assert.equals("> 0", b:get_filter("anything", true))
		end)

		it("treats regular and index columns as distinct", function()
			local b = Expression:new("df")
			b:set_filter("age", false, "> 5")
			b:set_filter("age", true, "> 10")
			assert.equals("> 5", b:get_filter("age", false))
			assert.equals("> 10", b:get_filter("age", true))
		end)

		it("clears the filter when given an empty condition", function()
			local b = Expression:new("df")
			b:set_filter("age", false, "> 5")
			b:set_filter("age", false, "")
			assert.is_nil(b:get_filter("age", false))
		end)

		it("build() wraps the expression with a .query() call", function()
			local b = Expression:new("df")
			b:set_filter("age", false, "> 5")
			assert.equals([[(df).query("`age` > 5", engine='python')]], b:build())
		end)

		it("build() accepts shorthand '= value' as ==", function()
			local b = Expression:new("df")
			b:set_filter("name", false, "= 'foo'")
			assert.equals([[(df).query("`name` == 'foo'", engine='python')]], b:build())
		end)

		it("build() defaults to == when the condition has no operator prefix", function()
			local b = Expression:new("df")
			b:set_filter("name", false, "'foo'")
			assert.equals([[(df).query("`name` == 'foo'", engine='python')]], b:build())
		end)

		it("build() leaves method-style conditions untouched", function()
			local b = Expression:new("df")
			b:set_filter("name", false, ".str.contains('foo')")
			assert.equals(
				[[(df).query("`name` .str.contains('foo')", engine='python')]],
				b:build()
			)
		end)

		it("build() expands bare comparisons after and/or", function()
			local b = Expression:new("df")
			b:set_filter("age", false, "> 5 and < 20")
			assert.equals(
				[[(df).query("`age` > 5 and `age` < 20", engine='python')]],
				b:build()
			)
		end)

		it("build() replaces double quotes by single quotes", function()
			local b = Expression:new("df")
			b:set_filter("name", false, "= \"foo\"")
			assert.equals([[(df).query("`name` == 'foo'", engine='python')]], b:build())
		end)
	end)

	describe("clear_filter()", function()
		it("removes the filter on a column", function()
			local b = Expression:new("df")
			b:set_filter("age", false, "> 5")
			b:clear_filter("age", false)
			assert.is_nil(b:get_filter("age", false))
		end)

		it("is a no-op when no filter is set", function()
			local b = Expression:new("df")
			assert.has_no.errors(function()
				b:clear_filter("age", false)
			end)
		end)
	end)

	describe("toggle_sort()", function()
		it("first toggle sets ascending sort", function()
			local b = Expression:new("df")
			b:toggle_sort("age", false)
			local sorts = b:get_sorts()
			assert.equals(1, #sorts)
			assert.equals("age", sorts[1].col_name)
			assert.is_false(sorts[1].is_index)
			assert.is_true(sorts[1].ascending)
		end)

		it("second toggle on the same column flips to descending", function()
			local b = Expression:new("df")
			b:toggle_sort("age", false)
			b:toggle_sort("age", false)
			assert.is_false(b:get_sorts()[1].ascending)
		end)

		it("third toggle on the same column removes it", function()
			local b = Expression:new("df")
			b:toggle_sort("age", false)
			b:toggle_sort("age", false)
			b:toggle_sort("age", false)
			assert.same({}, b:get_sorts())
		end)

		it("toggling a different column adds it as secondary sort", function()
			local b = Expression:new("df")
			b:toggle_sort("age", false)
			b:toggle_sort("age", false) -- now descending
			b:toggle_sort("name", false)
			local sorts = b:get_sorts()
			assert.equals(2, #sorts)
			assert.equals("age", sorts[1].col_name)
			assert.is_false(sorts[1].ascending)
			assert.equals("name", sorts[2].col_name)
			assert.is_true(sorts[2].ascending)
		end)

		it("cycling removes the secondary sort, leaving primary", function()
			local b = Expression:new("df")
			b:toggle_sort("age", false)
			b:toggle_sort("name", false)
			b:toggle_sort("name", false) -- desc
			b:toggle_sort("name", false) -- removed
			local sorts = b:get_sorts()
			assert.equals(1, #sorts)
			assert.equals("age", sorts[1].col_name)
		end)

		it("regular and index columns are treated as distinct sorts", function()
			local b = Expression:new("df")
			b:toggle_sort("age", false)
			b:toggle_sort("age", true)
			local sorts = b:get_sorts()
			assert.equals(2, #sorts)
			assert.is_false(sorts[1].is_index)
			assert.is_true(sorts[2].is_index)
		end)

		it("build() appends sort_values for a single regular column", function()
			local b = Expression:new("df")
			b:toggle_sort("age", false)
			assert.equals([[(df).sort_values("age", ascending=True)]], b:build())
		end)

		it("build() uses sort_index for the index column", function()
			local b = Expression:new("df")
			b:toggle_sort("any_name", true)
			assert.equals("(df).sort_index(ascending=True)", b:build())
		end)

		it("build() encodes descending as ascending=False", function()
			local b = Expression:new("df")
			b:toggle_sort("age", false)
			b:toggle_sort("age", false)
			assert.equals([[(df).sort_values("age", ascending=False)]], b:build())
		end)

		it("build() uses list form for multiple column sorts", function()
			local b = Expression:new("df")
			b:toggle_sort("age", false)
			b:toggle_sort("name", false)
			assert.equals(
				[[(df).sort_values(["age", "name"], ascending=[True, True])]],
				b:build()
			)
		end)

		it("build() encodes mixed directions in multi-column sort", function()
			local b = Expression:new("df")
			b:toggle_sort("age", false)
			b:toggle_sort("name", false)
			b:toggle_sort("name", false) -- flip name to descending
			assert.equals(
				[[(df).sort_values(["age", "name"], ascending=[True, False])]],
				b:build()
			)
		end)

		it("build() chains calls for mixed index + column sorts (index primary)", function()
			local b = Expression:new("df")
			b:toggle_sort("idx", true)   -- index, primary
			b:toggle_sort("age", false)  -- column, secondary
			-- Applied in reverse: age first, then index (stable → index dominant)
			assert.equals(
				[[((df).sort_values("age", ascending=True)).sort_index(ascending=True)]],
				b:build()
			)
		end)
	end)

	describe("build() with combined filters and sort", function()
		it("applies filter(s) before sort", function()
			local b = Expression:new("df")
			b:set_filter("age", false, "> 5")
			b:toggle_sort("name", false)
			assert.equals(
				[[((df).query("`age` > 5", engine='python')).sort_values("name", ascending=True)]],
				b:build()
			)
		end)
	end)
end)
