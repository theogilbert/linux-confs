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

end)
