---The sections' node_id attributes are randomly generated and cannot be
---known ahead of time.
---To be able to assert equality on section objects, we drop this attribute.
---@param sections table
---@return table sections
local function drop_node_id(sections)
    for _, section in ipairs(sections) do
        section.node_id = nil
        section.children = drop_node_id(section.children)
    end

    return sections
end

local function create_buf_with_text(text, lang)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("filetype", lang, { buf = buf })
    local lines = vim.split(text, "\n")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    return buf
end

describe("should parse markdown sections", function()
    local parser = require("sections.parser")

    local function build_header(name, line, children)
        return {
            name = name,
            type = "header",
            position = { line, 0 },
            children = children or {},
            private = false,
        }
    end

    it("parse subsequent headers", function()
        local buf = create_buf_with_text(
            [[
# First header

Foo

# Second header

Bar
        ]],
            "markdown"
        )

        local root_nodes = parser.parse_sections(buf)

        root_nodes = drop_node_id(root_nodes)
        assert.are.same({
            build_header("First header", 1),
            build_header("Second header", 5),
        }, root_nodes)
    end)

    it("should parse nested headers", function()
        local buf = create_buf_with_text(
            [[
# Parent header
## Sub header
]],
            "markdown"
        )

        local root_nodes = parser.parse_sections(buf)

        root_nodes = drop_node_id(root_nodes)
        assert.are.same({
            build_header("Parent header", 1, {
                build_header("Sub header", 2),
            }),
        }, root_nodes)
    end)

    it("should associate child section to correct parent", function()
        local buf = create_buf_with_text(
            [[
# Parent header
## Sub header
### Sub sub header
## Sub header 2
]],
            "markdown"
        )

        local root_nodes = parser.parse_sections(buf)

        root_nodes = drop_node_id(root_nodes)
        assert.are.same({
            build_header("Parent header", 1, {
                build_header("Sub header", 2, {
                    build_header("Sub sub header", 3),
                }),
                build_header("Sub header 2", 4),
            }),
        }, root_nodes)
    end)
end)

describe("parsing lua sections", function()
    local parser = require("sections.parser")

    local function build_function(name, line, params)
        return {
            name = name,
            type = "function",
            position = { line, 0 },
            children = {},
            parameters = params,
            private = false,
        }
    end

    it("should parse subsequent functions", function()
        local buf = create_buf_with_text(
            [[
function1 = function() end
function function2() end
        ]],
            "lua"
        )

        local root_nodes = parser.parse_sections(buf)

        root_nodes = drop_node_id(root_nodes)
        assert.are.same({
            build_function("function1", 1),
            build_function("function2", 2),
        }, root_nodes)
    end)

    it("should not parse non-function assignments", function()
        local buf = create_buf_with_text(
            [[
local text = "abcd"
number = 123
        ]],
            "lua"
        )

        local root_nodes = parser.parse_sections(buf)

        assert.are.same(root_nodes, {})
    end)

    it("should parse functions parameters", function()
        local buf = create_buf_with_text(
            [[
function1 = function(p1, p2) end
function function2(p3, p4, p5) end
        ]],
            "lua"
        )

        local root_nodes = parser.parse_sections(buf)

        root_nodes = drop_node_id(root_nodes)
        assert.are.same({
            build_function("function1", 1, { "p1", "p2" }),
            build_function("function2", 2, { "p3", "p4", "p5" }),
        }, root_nodes)
    end)
end)

describe("parsing python sections", function()
    local parser = require("sections.parser")

    local function create_python_buf(text)
        return create_buf_with_text(text, "python")
    end

    local function build_function(name, pos, params)
        return {
            name = name,
            type = "function",
            position = pos,
            children = {},
            parameters = params,
            private = false,
        }
    end

    local function build_class(name, pos, params, children)
        return {
            name = name,
            type = "class",
            position = pos,
            children = children or {},
            parameters = params,
            private = false,
        }
    end

    local function build_attribute(name, annotation, pos)
        return {
            name = name,
            type = "attribute",
            position = pos,
            children = {},
            type_annotation = annotation,
            private = false,
        }
    end

    it("should parse function", function()
        local buf = create_python_buf("def foo():\n  pass")
        local root_nodes = parser.parse_sections(buf)

        root_nodes = drop_node_id(root_nodes)
        assert.are.same({ build_function("foo", { 1, 0 }) }, root_nodes)
    end)

    it("should parse functions with parameters", function()
        local buf = create_python_buf([[
def foo(arg1: int, arg2: str, arg3, arg4=None, arg5: int = 1):
    pass
            ]])
        local root_nodes = parser.parse_sections(buf)

        root_nodes = drop_node_id(root_nodes)
        assert.are.same({ build_function("foo", { 1, 0 }, { "arg1", "arg2", "arg3", "arg4", "arg5" }) }, root_nodes)
    end)

    it("should parse simple class", function()
        local buf = create_python_buf("class SimpleClass:\n  pass")
        local root_nodes = parser.parse_sections(buf)

        root_nodes = drop_node_id(root_nodes)
        assert.are.same({ build_class("SimpleClass", { 1, 0 }) }, root_nodes)
    end)

    it("should parse class with parent class", function()
        local buf = create_python_buf("class SimpleClass(Enum):\n  pass")
        local root_nodes = parser.parse_sections(buf)

        root_nodes = drop_node_id(root_nodes)
        assert.are.same({ build_class("SimpleClass", { 1, 0 }, { "Enum" }) }, root_nodes)
    end)

    it("should parse class with multiple parent classes", function()
        local buf = create_python_buf("class SimpleClass(str, Enum):\n  pass")
        local root_nodes = parser.parse_sections(buf)

        root_nodes = drop_node_id(root_nodes)
        assert.are.same({ build_class("SimpleClass", { 1, 0 }, { "str", "Enum" }) }, root_nodes)
    end)

    it("should parse method with multiple parameters", function()
        local buf = create_python_buf([[
class Arbiter:
    def kill_worker(self, pid, sig):
        pass
        ]])
        local root_nodes = parser.parse_sections(buf)

        root_nodes = drop_node_id(root_nodes)
        assert.are.same({
            build_class("Arbiter", { 1, 0 }, nil, {
                build_function("kill_worker", { 2, 4 }, { "self", "pid", "sig" }),
            }),
        }, root_nodes)
    end)

    it("should parse class attributes", function()
        local buf = create_python_buf([[
class SimpleClass:
    FOO1: str
    FOO2 = 2
    FOO3: int = 2
]])
        local root_nodes = parser.parse_sections(buf)

        root_nodes = drop_node_id(root_nodes)
        assert.are.same({
            build_class("SimpleClass", { 1, 0 }, nil, {
                build_attribute("FOO1", "str", { 2, 4 }),
                build_attribute("FOO2", nil, { 3, 4 }),
                build_attribute("FOO3", "int", { 4, 4 }),
            }),
        }, root_nodes)
    end)

    it("should parse module attributes", function()
        local buf = create_python_buf([[
FOO1: str
FOO2 = 2
FOO3: int = 2
]])
        local root_nodes = parser.parse_sections(buf)

        root_nodes = drop_node_id(root_nodes)
        assert.are.same({
            build_attribute("FOO1", "str", { 1, 0 }),
            build_attribute("FOO2", nil, { 2, 0 }),
            build_attribute("FOO3", "int", { 3, 0 }),
        }, root_nodes)
    end)

    it("should not parse function attributes", function()
        local buf = create_python_buf([[
def foo():
    FOO1: str
    FOO2 = 2
    FOO3: int = 2
]])

        local root_nodes = parser.parse_sections(buf)

        root_nodes = drop_node_id(root_nodes)
        assert.are.same({ build_function("foo", { 1, 0 }) }, root_nodes)
    end)

    it("should parse private function", function()
        local buf = create_python_buf([[
def _foo():
    pass
]])
        local root_nodes = parser.parse_sections(buf)
        local expected_fn = build_function("_foo", { 1, 0 })
        expected_fn.private = true

        root_nodes = drop_node_id(root_nodes)
        assert.are.same({ expected_fn }, root_nodes)
    end)

    it("should parse private class", function()
        local buf = create_python_buf([[
class _Foo:
    pass
]])
        local root_nodes = parser.parse_sections(buf)
        local expected_cls = build_class("_Foo", { 1, 0 })
        expected_cls.private = true

        root_nodes = drop_node_id(root_nodes)
        assert.are.same({ expected_cls }, root_nodes)
    end)

    it("should parse private class attribute", function()
        local buf = create_python_buf([[
class Foo:
    _BAR: int
]])
        local root_nodes = parser.parse_sections(buf)
        local expected_attr = build_attribute("_BAR", "int", { 2, 4 })
        expected_attr.private = true

        root_nodes = drop_node_id(root_nodes)
        assert.are.same({
            build_class("Foo", { 1, 0 }, nil, { expected_attr }),
        }, root_nodes)
    end)

    it("should parse private module attribute", function()
        local buf = create_python_buf([[
_BAR = 123
]])
        local root_nodes = parser.parse_sections(buf)
        local expected_attr = build_attribute("_BAR", nil, { 1, 0 })
        expected_attr.private = true

        root_nodes = drop_node_id(root_nodes)
        assert.are.same({ expected_attr }, root_nodes)
    end)
end)
