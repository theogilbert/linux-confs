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

describe("should get current section pane line", function()
    local formatter = require("sections.formatter")

    local function current_pane_line(sections, cursor_line, collapsed, show_private)
        local sequence = formatter.build_sequence(sections, collapsed, show_private)
        return formatter.get_current_section_pane_line(sequence, cursor_line)
    end

    it("should return nil when no sections", function()
        assert.is_nil(current_pane_line({}, 5, {}, true))
    end)

    it("should return nil when cursor is before all sections", function()
        local sections = {
            { name = "foo", type = "function", position = { 5, 0 }, node_id = "1", children = {} },
        }
        assert.is_nil(current_pane_line(sections, 3, {}, true))
    end)

    it("should return pane line of the section the cursor is on", function()
        local sections = {
            { name = "foo", type = "function", position = { 1, 0 }, node_id = "1", children = {} },
            { name = "bar", type = "function", position = { 10, 0 }, node_id = "2", children = {} },
        }
        assert.are.equal(1, current_pane_line(sections, 1, {}, true))
        assert.are.equal(1, current_pane_line(sections, 5, {}, true))
        assert.are.equal(2, current_pane_line(sections, 10, {}, true))
        assert.are.equal(2, current_pane_line(sections, 99, {}, true))
    end)

    it("should prefer the deepest section when cursor is inside a nested section", function()
        local sections = {
            {
                name = "MyClass",
                type = "class",
                position = { 1, 0 },
                node_id = "1",
                children = {
                    { name = "foo", type = "function", position = { 5, 0 }, node_id = "2", children = {} },
                    { name = "bar", type = "function", position = { 15, 0 }, node_id = "3", children = {} },
                },
            },
        }
        assert.are.equal(1, current_pane_line(sections, 3, {}, true))
        assert.are.equal(2, current_pane_line(sections, 5, {}, true))
        assert.are.equal(2, current_pane_line(sections, 12, {}, true))
        assert.are.equal(3, current_pane_line(sections, 15, {}, true))
    end)

    it("should fall back to the parent section when children are collapsed", function()
        local sections = {
            {
                name = "MyClass",
                type = "class",
                position = { 1, 0 },
                node_id = "1",
                children = {
                    { name = "foo", type = "function", position = { 5, 0 }, node_id = "2", children = {} },
                },
            },
        }
        assert.are.equal(1, current_pane_line(sections, 7, { ["1"] = true }, true))
    end)

    it("should fall back to the previous visible section when current section is hidden as private", function()
        local sections = {
            { name = "foo", type = "function", position = { 1, 0 }, node_id = "1", children = {}, private = false },
            { name = "_bar", type = "function", position = { 5, 0 }, node_id = "2", children = {}, private = true },
        }
        assert.are.equal(1, current_pane_line(sections, 7, {}, false))
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
