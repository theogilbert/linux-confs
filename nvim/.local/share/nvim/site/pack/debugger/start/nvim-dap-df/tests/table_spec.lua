local table_fmt = require("nvim-dap-df-pane.table")

describe("table.from_structured_data", function()
	it("inserts a separator below the header lines", function()
		local tbl = table_fmt.from_structured_data({ { "a", "b" }, { "int64", "object" }, { "1", "x" } }, 2)
		assert.same({
			"│   a   │   b    │",
			"│ int64 │ object │",
			"├───────┼────────┤",
			"│   1   │   x    │",
		}, tbl.text)
	end)

	it("renders vim.NIL cells as NA and flags them via null_hl_rules", function()
		local tbl = table_fmt.from_structured_data({ { "a", "b" }, { vim.NIL, "x" } }, 1)
		assert.matches("NA", tbl.text[3])
		local rules = table_fmt.null_hl_rules("DapDfNull", tbl)
		assert.equals(1, #rules)
		assert.equals(2, rules[1].start[1])
	end)

	it("renders embedded newlines and tabs as escapes so the row stays one line", function()
		local tbl = table_fmt.from_structured_data({ { "a" }, { "x\ny\tz" } }, 1)
		assert.matches("x\\ny\\tz", tbl.text[3], 1, true)
		assert.equals(vim.api.nvim_strwidth(tbl.text[1]), vim.api.nvim_strwidth(tbl.text[3]))
	end)

	it("pads ragged rows to the widest row", function()
		local tbl = table_fmt.from_structured_data({ { "a", "b" }, { "1" } }, 1)
		assert.equals(vim.api.nvim_strwidth(tbl.text[1]), vim.api.nvim_strwidth(tbl.text[3]))
	end)

	it("groups digits of numeric cells only in columns with a separator", function()
		local tbl = table_fmt.from_structured_data({ { "a", "b" }, { "1234567", "1234567" } }, 1, { "_" })
		assert.matches("1_234_567", tbl.text[3], 1, true)
		assert.matches("│ 1234567 │", tbl.text[3], 1, true)
		local rules = table_fmt.thousands_hl_rules("Sep", tbl)
		assert.equals(2, #rules)
	end)

	it("keeps the fraction and sign of grouped numbers, and leaves text alone", function()
		local tbl = table_fmt.from_structured_data({ { "a" }, { "-12345.678" }, { "12345abc" } }, 1, "_")
		assert.matches("-12_345.678", tbl.text[3], 1, true)
		assert.matches("12345abc", tbl.text[4], 1, true)
	end)

	it("never groups digits in header rows", function()
		local tbl = table_fmt.from_structured_data({ { "2024" }, { "12345" } }, 1, "_")
		assert.matches("2024", tbl.text[1], 1, true)
	end)

	it("left-aligns only the columns wider than the threshold", function()
		local tbl = table_fmt.from_structured_data({ { "a", "b" }, { "x", string.rep("y", 20) }, { "x", "z" } }, 1, nil, 10)
		assert.is_nil(tbl.left_aligned[1])
		assert.is_true(tbl.left_aligned[2])
		assert.matches("│ z  ", tbl.text[4], 1, true)
	end)

	it("computes byte positions across multi-byte cells", function()
		local tbl = table_fmt.from_structured_data({ { "é", "b" } }, 0)
		local rules = table_fmt.col_hl_rules("H", tbl, 1)
		local line = tbl.text[1]
		assert.equals("b", vim.trim(line:sub(rules[2].start[2] + 1, rules[2].finish[2])))
	end)
end)

describe("table.get_column_at_cursor", function()
	it("resolves the column at a virtual cursor position, and nil on separators", function()
		local widths = { 3, 4 }
		assert.is_nil(table_fmt.get_column_at_cursor(widths, 1))
		assert.equals(1, table_fmt.get_column_at_cursor(widths, 2))
		assert.equals(1, table_fmt.get_column_at_cursor(widths, 4))
		assert.is_nil(table_fmt.get_column_at_cursor(widths, 5))
		assert.equals(2, table_fmt.get_column_at_cursor(widths, 6))
	end)
end)
