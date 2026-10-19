local csv = require("nvim-dap-df-pane.csv")

describe("csv.parse", function()
	it("parses plain rows, keeping empty cells", function()
		local rows = csv.parse(",a,b\n0,1,\n1,,3\n")
		assert.same({ { "", "a", "b" }, { "0", "1", "" }, { "1", "", "3" } }, rows)
	end)

	it("keeps commas, escaped quotes and newlines inside quoted cells", function()
		local rows = csv.parse('a,b\n"x, y","say ""hi""\nbye"\n')
		assert.same({ { "a", "b" }, { "x, y", 'say "hi"\nbye' } }, rows)
	end)

	it("handles CRLF line endings and skips empty lines", function()
		local rows = csv.parse("a,b\r\n\r\n1,2\r\n")
		assert.same({ { "a", "b" }, { "1", "2" } }, rows)
	end)

	it("reports an unclosed quote", function()
		local rows, err = csv.parse('a\n"oops\n')
		assert.same({}, rows)
		assert.is_not_nil(err)
	end)
end)
