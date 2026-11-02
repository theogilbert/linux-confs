describe("markdown-table", function()
    local md_table = require("utilities.markdown_table")

    it("should align columns", function()
        assert.are.same({
            "| a     | bb  |",
            "| ----- | --- |",
            "| hello | x   |",
        }, md_table.format({
            "|a|bb|",
            "|-|-|",
            "|  hello |x|",
        }))
    end)

    it("should honor column alignments", function()
        assert.are.same({
            "| left | center | right |",
            "| :--- | :----: | ----: |",
            "| a    |   b    |     c |",
        }, md_table.format({
            "| left | center | right |",
            "|:-|:-:|-:|",
            "| a | b | c |",
        }))
    end)

    it("should accept rows without outer pipes", function()
        assert.are.same({
            "| a   | b   |",
            "| --- | --- |",
            "| 1   | 2   |",
        }, md_table.format({ "a | b", "--|--", "1 | 2" }))
    end)

    it("should keep escaped pipes within their cell", function()
        assert.are.same({
            "| expr   | b   |",
            "| ------ | --- |",
            "| a \\| b | c   |",
        }, md_table.format({ "| expr | b |", "|-|-|", "| a \\| b | c |" }))
    end)

    it("should pad missing cells and use display width", function()
        assert.are.same({
            "| é   | 日本 |",
            "| --- | ---- |",
            "| x   |      |",
        }, md_table.format({ "| é | 日本 |", "|-|-|", "| x |" }))
    end)

    it("should keep the table's indentation", function()
        assert.are.same({
            "  | a   |",
            "  | --- |",
        }, md_table.format({ "  |a|", "  |-|" }))
    end)
end)
