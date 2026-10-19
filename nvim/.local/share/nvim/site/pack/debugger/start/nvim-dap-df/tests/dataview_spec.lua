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

	describe("with evaluated data", function()
		-- Index, dtypes row (merged in by the evaluator), then data.
		local CSV = ",name,amount\nint64,object,int64\n0,alice,1234567\n1,bob,pd.NA\n2,\"multi\nline\",42\n"
		local dv

		--- Cursor on the first character of display column `col_idx`, on table line `line` (0 = header).
		local function cursor_on(col_idx, line)
			local b = dv:get_column_boundaries()
			return { line = dv.TABLE_START + (line or 0), col = b[col_idx] + 2 }
		end

		before_each(function()
			dv = DataView:new("df", 100, "_")
			dv.evaluator = {
				evaluate = function(_, _, _, cb)
					cb(CSV, { "2", "3" }, nil)
				end,
			}
			dv:refresh(function() end, function(err)
				error(err)
			end)
		end)

		it("renders the prompt, a blank line, then the table", function()
			local lines = dv:get_lines()
			assert.matches("^%[2×3%] ➜ df", lines[1])
			assert.equals("", lines[2])
			assert.matches("name", lines[3])
			assert.matches("object", lines[4])
			assert.matches("^├", lines[5])
			assert.matches("alice", lines[6])
		end)

		it("maps NA cells to vim.NIL and escapes newlines", function()
			assert.equals(vim.NIL, dv.rows[2][3])
			assert.matches("multi\\nline", dv:get_lines()[8], 1, true)
			assert.equals("multi\nline", dv.rows[3][2])
		end)

		it("only resolves columns on table lines", function()
			assert.equals("name", (dv:get_column_under_cursor(cursor_on(2))))
			assert.is_nil(dv:get_column_under_cursor({ line = 0, col = cursor_on(2).col }))
		end)

		it("returns the row under the cursor, nil on header lines", function()
			assert.is_nil(dv:row_at_cursor(cursor_on(2, 1)))
			local r = dv:row_at_cursor(cursor_on(2, 3))
			assert.same({ "0", "alice", "1234567" }, r.row)
			assert.same({ "(index)", "name", "amount" }, r.columns)
			assert.equals("Row 1 of 3", r.title)
		end)

		it("hides a column and keeps the selection across refreshes", function()
			assert.is_true(dv:hide_column_under_cursor(cursor_on(2)))
			assert.same({ "", "amount" }, dv:get_column_names())
			assert.matches("1 hidden", dv:get_lines()[1])
			dv:refresh(function() end, function() end)
			assert.same({ "", "amount" }, dv:get_column_names())
			-- the hidden column no longer maps the cursor onto its data
			assert.equals("amount", (dv:get_column_under_cursor(cursor_on(2))))
		end)

		it("reorders columns from picker labels", function()
			dv:set_visible_labels({ "amount", "(index)" })
			assert.same({ "amount", "" }, dv:get_column_names())
			local _, is_index = dv:get_column_under_cursor(cursor_on(2))
			assert.is_true(is_index)
		end)

		it("toggles the thousands separator on the column under the cursor", function()
			dv:toggle_thousands_separator_under_cursor(cursor_on(3))
			assert.matches("1_234_567", dv:get_lines()[6], 1, true)
			dv:toggle_thousands_separator_under_cursor(cursor_on(3))
			assert.matches("1234567", dv:get_lines()[6], 1, true)
		end)

		it("decorates sorted columns and adds a filter row", function()
			dv:sort_column_under_cursor(cursor_on(3))
			dv:filter_column_under_cursor(cursor_on(2), "== 'bob'")
			dv:render()
			local lines = dv:get_lines()
			assert.matches("amount ▲", lines[3], 1, true)
			assert.matches("== 'bob'", lines[5], 1, true)
			assert.matches("^├", lines[6])
			local info = dv:column_info_under_cursor(cursor_on(3))
			assert.same({ "amount", "dtype   int64", "sort    ascending" }, info)
		end)

		it("produces highlight rules within the buffer lines", function()
			local lines = dv:get_lines()
			for _, r in ipairs(dv:get_hl_rules()) do
				assert.is_true(r.start[1] < #lines)
				if r.finish[2] ~= -1 then
					assert.is_true(r.finish[2] <= #lines[r.finish[1] + 1])
				end
			end
		end)
	end)
end)
