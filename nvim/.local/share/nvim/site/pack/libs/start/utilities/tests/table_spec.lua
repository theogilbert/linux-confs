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


end)
