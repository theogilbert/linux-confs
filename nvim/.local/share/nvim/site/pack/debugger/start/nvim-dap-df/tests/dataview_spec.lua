local DataView = require("nvim-dap-df-pane.dataview")

describe("DataView", function()
	describe("get_column_names()", function()
		it("returns an empty list when no data has been evaluated", function()
			local dv = DataView:new("df", 100)
			assert.same({}, dv:get_column_names())
		end)

		it("returns the column names in display order", function()
			local dv = DataView:new("df", 100)
			dv.column_names = { "idx", "age", "name" }
			assert.same({ "idx", "age", "name" }, dv:get_column_names())
		end)

		it("returns a copy so callers cannot mutate internal state", function()
			local dv = DataView:new("df", 100)
			dv.column_names = { "idx", "age" }
			local result = dv:get_column_names()
			result[1] = "mutated"
			assert.same({ "idx", "age" }, dv:get_column_names())
		end)
	end)

	describe("get_leftcol_for_column()", function()
		local dv

		before_each(function()
			dv = DataView:new("df", 100)
			dv.column_names = { "idx", "age", "name" }
			-- columns_width = {5, 5, 5} → boundaries = {0, 6, 12, 18}
			dv.table = { columns_width = { 5, 5, 5 } }
		end)

		it("returns nil when no data has been evaluated", function()
			local empty = DataView:new("df", 100)
			assert.is_nil(empty:get_leftcol_for_column("age"))
		end)

		it("returns 0 for the leftmost (index) column", function()
			assert.equals(0, dv:get_leftcol_for_column("idx"))
		end)

		it("returns the leftcol aligned to the column's left boundary", function()
			assert.equals(6, dv:get_leftcol_for_column("age"))
			assert.equals(12, dv:get_leftcol_for_column("name"))
		end)

		it("returns nil when the column does not exist", function()
			assert.is_nil(dv:get_leftcol_for_column("missing"))
		end)
	end)
end)
