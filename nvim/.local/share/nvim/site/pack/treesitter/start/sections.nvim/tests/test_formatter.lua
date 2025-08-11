describe("should display sections", function()
    local formatter = require("sections.formatter")
    local config = require("sections.config")

    config.init({
        icons = {
            ["function"] = "f",
            header = "#",
            attribute = "󰠲",
        },
    })

    it("should format sequential sections", function()
        local sections = {
            {
                name = "First header",
                type = "header",
                position = { 1, 1 },
                children = {},
            },
            {
                name = "Second header",
                type = "header",
                position = { 5, 1 },
                children = {},
            },
        }

        assert.are.same({ "# First header", "# Second header" }, formatter.format(sections, true))
    end)

    it("should format nested sections", function()
        local sections = {
            {
                name = "Parent header",
                type = "header",
                position = { 1, 1 },
                children = {
                    {
                        name = "Sub header",
                        type = "header",
                        position = { 1, 1 },
                        children = {},
                    },
                },
            },
        }

        assert.are.same({ "# Parent header", "  # Sub header" }, formatter.format(sections, true))
    end)

    it("should format header section", function()
        local sections = {
            {
                name = "First header",
                type = "header",
                children = {},
            },
        }

        local lines = formatter.format(sections, true)

        assert.are.same({ "# First header" }, lines)
    end)

    it("should format function section", function()
        local sections = {
            {
                name = "foo",
                type = "function",
                children = {},
            },
        }

        local lines = formatter.format(sections, true)

        assert.are.same({ "f foo()" }, lines)
    end)

    it("should format function section with parameters", function()
        local sections = {
            {
                name = "foo",
                type = "function",
                children = {},
                parameters = { "abc", "bar" },
            },
        }

        local lines = formatter.format(sections, true)

        assert.are.same({ "f foo(abc, bar)" }, lines)
    end)

    it("should format class section with parameters", function()
        local sections = {
            {
                name = "Foo",
                type = "class",
                children = {},
                parameters = { "str" },
            },
        }

        local lines = formatter.format(sections, true)

        assert.are.same({ " Foo(str)" }, lines)
    end)

    it("should format attribute section", function()
        local sections = {
            {
                name = "bar",
                type = "attribute",
                children = {},
            },
        }

        local lines = formatter.format(sections, true)

        assert.are.same({ "󰠲 bar" }, lines)
    end)

    it("should format attribute section with type annotation", function()
        local sections = {
            {
                name = "bar",
                type = "attribute",
                type_annotation = "int",
                children = {},
            },
        }

        local lines = formatter.format(sections, true)

        assert.are.same({ "󰠲 bar: int" }, lines)
    end)

    it("should not collapse section when it has no child", function()
        local sections = {
            {
                name = "foo",
                type = "function",
                children = {},
                parameters = { "abc", "bar" },
            },
        }

        formatter.toggle_collapse(sections, 1)
        local lines = formatter.format(sections, true)

        assert.are.same({ "f foo(abc, bar)" }, lines)
    end)

    it("should collapse section", function()
        local sections = {
            {
                name = "foo",
                type = "function",
                children = {
                    {
                        name = "foo",
                        type = "function",
                        children = {},
                    },
                },
            },
        }

        formatter.toggle_collapse(sections, 1)
        assert.are.same({ "f foo() ..." }, formatter.format(sections, true))

        formatter.toggle_collapse(sections, 1)
        assert.are.same({ "f foo()", "  f foo()" }, formatter.format(sections, true))
    end)

    it("should hide private section", function()
        local sections = {
            {
                name = "foo",
                type = "function",
                private = false,
                children = {},
            },
            {
                name = "_foo",
                type = "function",
                private = true,
                children = {},
            },
        }

        assert.are.same({ "f foo()", "f _foo()" }, formatter.format(sections, true))
        assert.are.same({ "f foo()" }, formatter.format(sections, false))
    end)
end)

describe("should get section pos", function()
    local formatter = require("sections.formatter")

    it("should retrieve position of sequential sections", function()
        local sections = {
            {
                name = "First header",
                type = "header",
                position = { 1, 1 },
                children = {},
            },
            {
                name = "Second header",
                type = "header",
                position = { 5, 1 },
                children = {},
            },
        }

        local section_pos = formatter.get_section_pos(sections, 2)

        assert.are.same({ 5, 1 }, section_pos)
    end)
    it("should retrieve position of nested sections", function()
        local sections = {
            {
                name = "First header",
                type = "header",
                position = { 1, 1 },
                children = {
                    {
                        name = "Sub header",
                        type = "header",
                        position = { 3, 1 },
                        children = {},
                    },
                },
            },
            {
                name = "Second header",
                type = "header",
                position = { 5, 1 },
                children = {},
            },
        }

        local section_pos = formatter.get_section_pos(sections, 2)

        assert.are.same({ 3, 1 }, section_pos)
    end)
end)
