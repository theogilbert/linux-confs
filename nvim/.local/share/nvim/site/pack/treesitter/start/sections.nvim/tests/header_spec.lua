describe("should get header text", function()
    local header = require("sections.header")

    it("should state that private sections are displayed", function()
        local header_lines = header.get_lines(true)

        assert.is.same(1, #header_lines)
        assert.matches("Private sections are visible", header_lines[1])
    end)

    it("should state that private sections are hidden", function()
        local header_lines = header.get_lines(false)

        assert.is.same(1, #header_lines)
        assert.matches("Private sections are hidden", header_lines[1])
    end)
end)

describe("should highlight header text", function()
    local header = require("sections.header")

    it("should dim header when private sections are displayed", function()
        local rules = header.get_hl_rules(true)

        assert.is.same({
            { higroup = "SectionsPaneHeaderDim", start = { 0, 0 }, finish = { 0, -1 } },
        }, rules)
    end)

    it("should highlight header in red when private sections are hidden", function()
        local rules = header.get_hl_rules(false)

        assert.is.same({
            { higroup = "SectionsPaneHeaderWarn", start = { 0, 0 }, finish = { 0, -1 } },
        }, rules)
    end)
end)
