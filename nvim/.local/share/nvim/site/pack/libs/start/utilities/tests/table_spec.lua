describe("table-from-csv", function()
    local table_fmt = require("utilities.table")

    it("should properly format table", function()
        local result = table_fmt.from_csv(",\"a\"\",as\",b\n0,1,1")

        assert.are.same({
            "│   │ a\",as │ b │",
            "├───┼───────┼───┤",
            "│ 0 │   1   │ 1 │"
        }, result.text)
    end)

    it("should properly handle empty last column", function()
        local result = table_fmt.from_csv(",filled,empty\n0,foo,")
        assert.are.same({
            "│   │ filled │ empty │",
            "├───┼────────┼───────┤",
            "│ 0 │  foo   │       │"
        }, result.text)
    end)

    it("should properly handle trailing line", function()
        local result = table_fmt.from_csv(",col\n0,\"value\"\n\n")
        assert.are.same({
            "│   │  col  │",
            "├───┼───────┤",
            "│ 0 │ value │"
        }, result.text)
    end)

    it("should handle CRLF line endings without leaking \\r into cells", function()
        local result = table_fmt.from_csv("a,b\r\n1,2\r\n")
        assert.are.same({ { "a", "b" }, { "1", "2" } }, result.lines)
        assert.are.same({
            "│ a │ b │",
            "├───┼───┤",
            "│ 1 │ 2 │"
        }, result.text)
    end)

    it("should reject a bare quote in an unquoted cell at end of line", function()
        local result, err = table_fmt.from_csv("a\"")
        assert.are.same({}, result)
        assert.is_not_nil(err)
    end)

    it("should reject a bare quote in an unquoted cell mid-line", function()
        local result, err = table_fmt.from_csv("a\"b")
        assert.are.same({}, result)
        assert.is_not_nil(err)
    end)

    it("should reject an unclosed quoted cell", function()
        local result, err = table_fmt.from_csv("\"unclosed")
        assert.are.same({}, result)
        assert.is_not_nil(err)
    end)

    it("should not crash on empty input", function()
        local result = table_fmt.from_csv("")
        assert.are.same({}, result.lines)
        assert.are.same({}, result.text)
    end)

    it("should not crash when header_lines exceeds row count", function()
        local result = table_fmt.from_structured_data({ { "a", "b" } }, 5)
        assert.are.same({ "│ a │ b │" }, result.text)
    end)

    it("should escape doubled quotes inside a quoted cell", function()
        local result = table_fmt.from_csv("\"a\"\"b\"")
        assert.are.same({ { "a\"b" } }, result.lines)
    end)
end)
