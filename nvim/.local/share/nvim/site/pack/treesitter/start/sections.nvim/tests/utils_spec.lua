local utils = require("sections.utils")

describe("should merge tables", function()
    it("should keep values from both tables", function()
        local tbl1 = { 1, 2, 3 }
        local tbl2 = { 4, 5, 6 }

        local merged = utils.merge_tables(tbl1, tbl2)

        assert.are.same({ 1, 2, 3, 4, 5, 6 }, merged)
    end)
end)
