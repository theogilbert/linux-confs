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
                node_id = "1",
                children = {},
            },
            {
                name = "Second header",
                type = "header",
                position = { 5, 1 },
                node_id = "2",
                children = {},
            },
        }

        assert.are.same({ "# First header", "# Second header" }, formatter.format(sections, {}, true))
    end)

    it("should format nested sections", function()
        local sections = {
            {
                name = "Parent header",
                type = "header",
                position = { 1, 1 },
                node_id = "1",
                children = {
                    {
                        name = "Sub header",
                        type = "header",
                        position = { 1, 1 },
                        node_id = "2",
                        children = {},
                    },
                },
            },
        }

        assert.are.same({ "# Parent header", "  # Sub header" }, formatter.format(sections, {}, true))
    end)

    it("should format header section", function()
        local sections = {
            {
                name = "First header",
                type = "header",
                node_id = "1",
                children = {},
            },
        }

        local lines = formatter.format(sections, {}, true)

        assert.are.same({ "# First header" }, lines)
    end)

    it("should format function section", function()
        local sections = {
            {
                name = "foo",
                type = "function",
                node_id = "1",
                children = {},
            },
        }

        local lines = formatter.format(sections, {}, true)

        assert.are.same({ "f foo()" }, lines)
    end)

    it("should format function section with parameters", function()
        local sections = {
            {
                name = "foo",
                type = "function",
                node_id = "1",
                children = {},
                parameters = { "abc", "bar" },
            },
        }

        local lines = formatter.format(sections, {}, true)

        assert.are.same({ "f foo(abc, bar)" }, lines)
    end)

    it("should format class section with parameters", function()
        local sections = {
            {
                name = "Foo",
                type = "class",
                node_id = "1",
                children = {},
                parameters = { "str" },
            },
        }

        local lines = formatter.format(sections, {}, true)

        assert.are.same({ " Foo(str)" }, lines)
    end)

    it("should format attribute section", function()
        local sections = {
            {
                name = "bar",
                type = "attribute",
                node_id = "1",
                children = {},
            },
        }

        local lines = formatter.format(sections, {}, true)

        assert.are.same({ "󰠲 bar" }, lines)
    end)

    it("should format attribute section with type annotation", function()
        local sections = {
            {
                name = "bar",
                type = "attribute",
                type_annotation = "int",
                node_id = "1",
                children = {},
            },
        }

        local lines = formatter.format(sections, {}, true)

        assert.are.same({ "󰠲 bar: int" }, lines)
    end)

    it("should not collapse section when it has no child", function()
        local sections = {
            {
                name = "foo",
                type = "function",
                children = {},
                parameters = { "abc", "bar" },
                node_id = "1",
            },
        }

        local lines = formatter.format(sections, { ["1"] = true }, true)

        assert.are.same({ "f foo(abc, bar)" }, lines)
    end)

    it("should collapse section", function()
        local sections = {
            {
                name = "foo",
                type = "function",
                node_id = "1",
                children = {
                    {
                        name = "foo",
                        type = "function",
                        children = {},
                        node_id = "2",
                    },
                },
            },
        }

        local text = formatter.format(sections, { ["1"] = true }, true)

        assert.are.same({ "f foo() ..." }, text)
    end)

    it("should hide private section", function()
        local sections = {
            {
                name = "foo",
                type = "function",
                private = false,
                node_id = "1",
                children = {},
            },
            {
                name = "_foo",
                type = "function",
                private = true,
                node_id = "2",
                children = {},
            },
        }

        assert.are.same({ "f foo()", "f _foo()" }, formatter.format(sections, {}, true))
        assert.are.same({ "f foo()" }, formatter.format(sections, {}, false))
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
                node_id = "1",
                children = {},
            },
            {
                name = "Second header",
                type = "header",
                position = { 5, 1 },
                node_id = "2",
                children = {},
            },
        }

        local section_pos = formatter.get_section_pos(sections, 2, {}, true)

        assert.are.same({ 5, 1 }, section_pos)
    end)

    it("should retrieve position of nested sections", function()
        local sections = {
            {
                name = "First header",
                type = "header",
                position = { 1, 1 },
                node_id = "1",
                children = {
                    {
                        name = "Sub header",
                        type = "header",
                        position = { 3, 1 },
                        node_id = "2",
                        children = {},
                    },
                },
            },
            {
                name = "Second header",
                type = "header",
                position = { 5, 1 },
                node_id = "3",
                children = {},
            },
        }

        local section_pos = formatter.get_section_pos(sections, 2, {}, true)

        assert.are.same({ 3, 1 }, section_pos)
    end)

    it("should retrieve position when sections are collapsed", function()
        local sections = {
            {
                name = "First header",
                type = "header",
                position = { 1, 1 },
                node_id = "1",
                children = {
                    {
                        name = "Sub header",
                        type = "header",
                        position = { 3, 1 },
                        children = {},
                        node_id = "2",
                    },
                },
            },
            {
                name = "Second header",
                type = "header",
                position = { 5, 1 },
                children = {},
                node_id = "3",
            },
        }

        local section_pos = formatter.get_section_pos(sections, 2, { ["2"] = true }, true)

        assert.are.same({ 3, 1 }, section_pos)
    end)

    it("should retrieve correct position of section when private section hidden", function()
        local sections = {
            {
                name = "First header",
                type = "header",
                position = { 1, 1 },
                private = true,
                node_id = "1",
                children = {},
            },
            {
                name = "Second header",
                type = "header",
                position = { 2, 1 },
                node_id = "2",
                children = {},
            },
        }

        local section_pos = formatter.get_section_pos(sections, 1, {}, false)

        assert.are.same({ 2, 1 }, section_pos)
    end)
end)
