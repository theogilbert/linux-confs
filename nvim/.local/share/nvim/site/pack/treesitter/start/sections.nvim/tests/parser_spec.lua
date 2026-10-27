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

local function with_description(section, description)
    return vim.tbl_extend("force", section, { description = description })
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

    local function build_function(name, line, params, private)
        return {
            name = name,
            type = "function",
            position = { line, 0 },
            children = {},
            parameters = params,
            private = private or false,
        }
    end

    local function build_private_function(name, line, params)
        return build_function(name, line, params, true)
    end

    it("should parse module functions as public", function()
        local buf = create_buf_with_text(
            [[
local M = {}
function M.setup(opts) end
        ]],
            "lua"
        )

        local root_nodes = parser.parse_sections(buf)

        root_nodes = drop_node_id(root_nodes)
        assert.are.same({
            build_function("M.setup", 2, { "opts" }),
        }, root_nodes)
    end)

    it("should parse non-module functions as private", function()
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
            build_private_function("function1", 1),
            build_private_function("function2", 2),
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
            build_private_function("function1", 1, { "p1", "p2" }),
            build_private_function("function2", 2, { "p3", "p4", "p5" }),
        }, root_nodes)
    end)

    it("should parse method", function()
        local buf = create_buf_with_text(
            [[
function Pane:clear_filter() end
        ]],
            "lua"
        )

        local root_nodes = parser.parse_sections(buf)

        root_nodes = drop_node_id(root_nodes)
        assert.are.same({
            build_private_function("Pane:clear_filter", 1),
        }, root_nodes)
    end)
end)

describe("parsing python sections", function()
    local parser = require("sections.parser")

    local function create_python_buf(text)
        return create_buf_with_text(text, "python")
    end

    -- Signatures are asserted by dedicated tests
    local function drop_signatures(sections)
        for _, section in ipairs(sections) do
            section.signature = nil
            section.children = drop_signatures(section.children)
        end
        return sections
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

        root_nodes = drop_node_id(drop_signatures(root_nodes))
        assert.are.same({ build_function("foo", { 1, 0 }) }, root_nodes)
    end)

    it("should parse functions with parameters", function()
        local buf = create_python_buf([[
def foo(arg1: int, arg2: str, arg3, arg4=None, arg5: int = 1):
    pass
            ]])
        local root_nodes = parser.parse_sections(buf)

        root_nodes = drop_node_id(drop_signatures(root_nodes))
        assert.are.same({ build_function("foo", { 1, 0 }, { "arg1", "arg2", "arg3", "arg4", "arg5" }) }, root_nodes)
    end)

    it("should parse simple class", function()
        local buf = create_python_buf("class SimpleClass:\n  pass")
        local root_nodes = parser.parse_sections(buf)

        root_nodes = drop_node_id(drop_signatures(root_nodes))
        assert.are.same({ build_class("SimpleClass", { 1, 0 }) }, root_nodes)
    end)

    it("should parse class with parent class", function()
        local buf = create_python_buf("class SimpleClass(Enum):\n  pass")
        local root_nodes = parser.parse_sections(buf)

        root_nodes = drop_node_id(drop_signatures(root_nodes))
        assert.are.same({ build_class("SimpleClass", { 1, 0 }, { "Enum" }) }, root_nodes)
    end)

    it("should parse class with multiple parent classes", function()
        local buf = create_python_buf("class SimpleClass(str, Enum):\n  pass")
        local root_nodes = parser.parse_sections(buf)

        root_nodes = drop_node_id(drop_signatures(root_nodes))
        assert.are.same({ build_class("SimpleClass", { 1, 0 }, { "str", "Enum" }) }, root_nodes)
    end)

    it("should parse methods of class with multiple parent classes", function()
        local buf = create_python_buf([[
class Driver(Meta, Base):
    def run(self):
        pass
        ]])
        local root_nodes = parser.parse_sections(buf)

        root_nodes = drop_node_id(drop_signatures(root_nodes))
        assert.are.same({
            build_class("Driver", { 1, 0 }, { "Meta", "Base" }, {
                build_function("run", { 2, 4 }, { "self" }),
            }),
        }, root_nodes)
    end)

    it("should parse method with multiple parameters", function()
        local buf = create_python_buf([[
class Arbiter:
    def kill_worker(self, pid, sig):
        pass
        ]])
        local root_nodes = parser.parse_sections(buf)

        root_nodes = drop_node_id(drop_signatures(root_nodes))
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

        root_nodes = drop_node_id(drop_signatures(root_nodes))
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

        root_nodes = drop_node_id(drop_signatures(root_nodes))
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

        root_nodes = drop_node_id(drop_signatures(root_nodes))
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

        root_nodes = drop_node_id(drop_signatures(root_nodes))
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

        root_nodes = drop_node_id(drop_signatures(root_nodes))
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

        root_nodes = drop_node_id(drop_signatures(root_nodes))
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

        root_nodes = drop_node_id(drop_signatures(root_nodes))
        assert.are.same({ expected_attr }, root_nodes)
    end)

    it("should expose the signature and docstring of a function", function()
        local buf = create_python_buf([[
@decorator
def foo(a: int,
        b=None) -> str:
    """Do foo.

    Longer text,
      indented.
    """
    return ""
]])
        local root_nodes = drop_node_id(parser.parse_sections(buf))

        assert.are.same("@decorator\ndef foo(a: int,\n        b=None) -> str:", root_nodes[1].signature)
        assert.are.same("Do foo.\n\nLonger text,\n  indented.", root_nodes[1].description)
    end)

    it("should expose the signature and docstring of a class", function()
        local buf = create_python_buf([[
class Foo(Base, metaclass=Meta):
    "Foo things."

    def bar(self): ...
]])
        local root_nodes = drop_node_id(parser.parse_sections(buf))

        assert.are.same("class Foo(Base, metaclass=Meta):", root_nodes[1].signature)
        assert.are.same("Foo things.", root_nodes[1].description)
        assert.are.same("def bar(self):", root_nodes[1].children[1].signature)
        assert.is_nil(root_nodes[1].children[1].description)
    end)

    it("should unindent the signature of a method", function()
        local buf = create_python_buf([[
class Foo:
    @property
    def bar(self,
            x) -> int: ...
]])
        local root_nodes = drop_node_id(parser.parse_sections(buf))

        assert.are.same("@property\ndef bar(self,\n        x) -> int:", root_nodes[1].children[1].signature)
    end)

    it("should not take a string that is not first in the body as a docstring", function()
        local buf = create_python_buf([[
def foo():
    x = 1
    "not a docstring"
]])
        local root_nodes = drop_node_id(parser.parse_sections(buf))

        assert.are.same("def foo():", root_nodes[1].signature)
        assert.is_nil(root_nodes[1].description)
    end)
end)

describe("should parse xml sections", function()
    local parser = require("sections.parser")

    local function build_xml_header(name, line, children, x_pos)
        return {
            name = name,
            type = "header",
            position = { line, x_pos or 0},
            children = children or {},
            private = false,
        }
    end

    it("parse subsequent headers", function()
        local buf = create_buf_with_text(
            [[
<first-tag>foo</first-tag>
<second-tag>bar</second-tag>
        ]],
            "xml"
        )

        local root_nodes = parser.parse_sections(buf)

        root_nodes = drop_node_id(root_nodes)
        assert.are.same({
            build_xml_header("first-tag", 1),
            build_xml_header("second-tag", 2),
        }, root_nodes)
    end)

    it("should parse nested elements", function()
        local buf = create_buf_with_text(
            [[
<parent-tag>
  <sub-tag>
  </sub-tag>
</parent-tag>
]],
            "xml"
        )

        local root_nodes = parser.parse_sections(buf)

        root_nodes = drop_node_id(root_nodes)
        assert.are.same({
            build_xml_header("parent-tag", 1, {
                build_xml_header("sub-tag", 2, {}, 2),
            }),
        }, root_nodes)
    end)

    it("should parse self-closed tags", function()
            local buf = create_buf_with_text(
                [[
<self-closed/>
    ]],
                "xml"
            )

            local root_nodes = parser.parse_sections(buf)

            root_nodes = drop_node_id(root_nodes)
            assert.are.same({
                build_xml_header("self-closed", 1),
            }, root_nodes)
        end)
end)

local function build_indented_header(name, line, column, children)
    return {
        name = name,
        type = "header",
        position = { line, column },
        children = children or {},
        private = false,
    }
end

describe("parsing yaml sections", function()
    local parser = require("sections.parser")

    before_each(function()
        assert:set_parameter("TableFormatLevel", 10)
    end)

    it("parse subsequent keys", function()
        local buf = create_buf_with_text(
            [[
foo: 123
foo2: 456
        ]],
            "yaml"
        )

        local root_nodes = parser.parse_sections(buf)

        root_nodes = drop_node_id(root_nodes)
        assert.are.same({
            build_indented_header("foo", 1, 0),
            build_indented_header("foo2", 2, 0),
        }, root_nodes)
    end)

    it("should parse nested keys", function()
        local buf = create_buf_with_text(
            [[
foo:
  bar1: 2
  bar2: 2
]],
            "yaml"
        )

        local root_nodes = parser.parse_sections(buf)

        root_nodes = drop_node_id(root_nodes)
        assert.are.same({
            build_indented_header("foo", 1, 0, {
                build_indented_header("bar1", 2, 2),
                build_indented_header("bar2", 3, 2),
            }),
        }, root_nodes)
    end)
end)


describe("should parse json headers", function()
    local parser = require("sections.parser")

    before_each(function()
        assert:set_parameter("TableFormatLevel", 10)
    end)

    it("parse subsequent keys", function()
        local buf = create_buf_with_text(
            [[
{
    "foo": 123,
    "bar": 123
}
        ]],
            "json"
        )

        local root_nodes = parser.parse_sections(buf)

        root_nodes = drop_node_id(root_nodes)
        assert.are.same({
            build_indented_header("foo", 2, 4),
            build_indented_header("bar", 3, 4),
        }, root_nodes)
    end)

    it("should parse nested keys", function()
        local buf = create_buf_with_text(
            [[
{
    "foo": {
        "bar": 123
    }
}
]],
            "json"
        )

        local root_nodes = parser.parse_sections(buf)

        root_nodes = drop_node_id(root_nodes)
        assert.are.same({
            build_indented_header("foo", 2, 4,  {
                build_indented_header("bar", 3, 8),
            }),
        }, root_nodes)
    end)
end)



describe("should parse sql sections", function()
    local parser = require("sections.parser")

    local function build_header(name, line)
        return {
            name = name,
            type = "header",
            position = { line, 0 },
            children = {},
            private = false,
        }
    end

    it("parse banner comments, keeping only the name line", function()
        local buf = create_buf_with_text(
            [[
------------------
-- First section
------------------
-- some description
SELECT 1;

-- regular comment --
SELECT 2;

---------------------
-- Second section --
---------------------
SELECT 3;
]],
            "sql"
        )

        local root_nodes = parser.parse_sections(buf)

        root_nodes = drop_node_id(root_nodes)
        assert.are.same({
            with_description(build_header("First section", 1), "some description"),
            build_header("Second section", 10),
        }, root_nodes)
    end)
end)

describe("should parse mongo sections", function()
    local parser = require("sections.parser")

    local function build_header(name, line)
        return {
            name = name,
            type = "header",
            position = { line, 0 },
            children = {},
            private = false,
        }
    end

    it("parse banner block comments, keeping only the name line", function()
        local buf = create_buf_with_text(
            [[
/******************
 * First section  *
 * some description *
 ******************/
{"find": "orders"}

/* regular comment */
// line comment
{"find": "items"}

/*******************
 * Second section
 *******************/
{"find": "users"}
]],
            "mongo"
        )

        local root_nodes = parser.parse_sections(buf)

        root_nodes = drop_node_id(root_nodes)
        assert.are.same({
            with_description(build_header("First section", 1), "some description"),
            build_header("Second section", 11),
        }, root_nodes)
    end)
end)

describe("should parse cypher sections", function()
    local parser = require("sections.parser")

    local function build_header(name, line)
        return {
            name = name,
            type = "header",
            position = { line, 0 },
            children = {},
            private = false,
        }
    end

    it("parse banner block comments, keeping only the name line", function()
        local buf = create_buf_with_text(
            [[
/******************
 * First section  *
 * some description *
 ******************/
MATCH (n:Person) RETURN n;

/* regular comment */
// line comment
MATCH (m:Movie) RETURN m;

/*******************
 * Second section
 *******************/
MATCH (n)-[r]->(m) RETURN r;
]],
            "cypher"
        )

        local root_nodes = parser.parse_sections(buf)

        root_nodes = drop_node_id(root_nodes)
        assert.are.same({
            with_description(build_header("First section", 1), "some description"),
            build_header("Second section", 11),
        }, root_nodes)
    end)
end)

describe("should parse lucene sections", function()
    local parser = require("sections.parser")

    local function build_header(name, line)
        return {
            name = name,
            type = "header",
            position = { line, 0 },
            children = {},
            private = false,
        }
    end

    it("parse banner comments, keeping only the name line", function()
        local buf = create_buf_with_text(
            [[
------------------
-- First section
------------------
-- some description
logs-* | level:error

-- regular comment --
logs-* | level:warn

---------------------
-- Second section --
---------------------
metrics | host:web01
]],
            "lucene"
        )

        local root_nodes = parser.parse_sections(buf)

        root_nodes = drop_node_id(root_nodes)
        assert.are.same({
            with_description(build_header("First section", 1), "some description"),
            build_header("Second section", 10),
        }, root_nodes)
    end)
end)

describe("should parse promql sections", function()
    local parser = require("sections.parser")

    local function build_header(name, line)
        return {
            name = name,
            type = "header",
            position = { line, 0 },
            children = {},
            private = false,
        }
    end

    it("parse banner comments, keeping only the name line", function()
        local buf = create_buf_with_text(
            [[
##################
# First section
##################
# some description
rate(http_requests_total[5m])

# regular comment #
up == 0

####################
# Second section #
####################
sum by (job) (up)
]],
            "promql"
        )

        local root_nodes = parser.parse_sections(buf)

        root_nodes = drop_node_id(root_nodes)
        assert.are.same({
            with_description(build_header("First section", 1), "some description"),
            build_header("Second section", 10),
        }, root_nodes)
    end)
end)

describe("should parse alternate banners and subsections of query languages", function()
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

    local function parse(text, lang)
        return drop_node_id(parser.parse_sections(create_buf_with_text(text, lang)))
    end

    it("parse sql block comment banners", function()
        assert.are.same(
            { with_description(build_header("Orders", 1), "Open orders only") },
            parse(
                [[
/******************
 * Orders         *
 * Open orders only *
 ******************/
SELECT 1;

/* regular comment */
SELECT 2;
]],
                "sql"
            )
        )
    end)

    for _, lang in ipairs({ "mongo", "cypher" }) do
        it("parse " .. lang .. " line comment banners", function()
            assert.are.same(
                { with_description(build_header("First section", 1), "some description"), build_header("Second section", 7) },
                parse(
                    [[
//////////////////
// First section
//////////////////
// some description

// regular comment //
//////////////////
// Second section //
//////////////////
]],
                    lang
                )
            )
        end)
    end

    local subsection_texts = {
        sql = [[
------------------
-- First --
------------------
-- ## Sub A
SELECT 1;
-- ### Sub A.1
SELECT 2;
-- ## Sub B
SELECT 3; -- # not a section
-- regular ## comment
------------------
-- Second --
------------------
-- ### Deep
]],
        lucene = [[
------------------
-- First --
------------------
-- ## Sub A
logs | a
-- ### Sub A.1
logs | b
-- ## Sub B
logs | c -- # not a section
-- regular ## comment
------------------
-- Second --
------------------
-- ### Deep
]],
        promql = [[
##################
# First #
##################
# ## Sub A
up
# ### Sub A.1
up
# ## Sub B
up # # not a section
# regular ## comment
##################
# Second #
##################
# ### Deep
]],
        mongo = [[
/******************
 * First
 ******************/
// ## Sub A
{"find": "a"}
// ### Sub A.1
{"find": "b"}
// ## Sub B
{"find": "c"} // # not a section
// regular ## comment
//////////////////
// Second //
//////////////////
// ### Deep
]],
    }
    subsection_texts.cypher = subsection_texts.mongo:gsub('{"find": "%a"}', "MATCH (n) RETURN n;")

    for lang, text in pairs(subsection_texts) do
        it("nest " .. lang .. " subsections by level under banners", function()
            assert.are.same({
                build_header("First", 1, {
                    build_header("Sub A", 4, { build_header("Sub A.1", 6) }),
                    build_header("Sub B", 8),
                }),
                -- A level 3 subsection without a level 2 parent nests directly under the banner
                build_header("Second", 11, { build_header("Deep", 14) }),
            }, parse(text, lang))
        end)
    end

    it("not open a banner on a closing rule or across blank lines", function()
        assert.are.same(
            { with_description(build_header("First", 1), "regular comment"), build_header("Second", 5) },
            parse(
                [[
------------------
-- First --
------------------
-- regular comment --
------------------
-- Second --
------------------

-- another comment --
------------------

-- Not a banner --
------------------
]],
                "sql"
            )
        )
    end)

    it("list subsections before any banner at the top level", function()
        assert.are.same(
            { build_header("Sub", 1, { build_header("Deeper", 2) }) },
            parse("-- ## Sub\n-- ### Deeper\nSELECT 1;\n", "sql")
        )
    end)
    it("require the closing rule right below the name line", function()
        assert.are.same(
            { with_description(build_header("Unboxed", 1), "description below the banner"), build_header("Boxed", 6) },
            parse(
                [[
------------------
-- Unboxed
------------------
-- description below the banner
SELECT 1;
------------------
-- Boxed --
------------------
SELECT 2;
------------------
-- Old style, not a section --
-- description inside the box --
------------------
SELECT 3;
]],
                "sql"
            )
        )
    end)

    it("strip a single trailing # box from promql names", function()
        assert.are.same(
            { build_header("Boxed", 1) },
            parse("##########\n# Boxed #\n##########\nup\n", "promql")
        )
    end)

    it("treat a single # comment alone on its line as a level 1 heading", function()
        assert.are.same({
            build_header("Banner", 1, { build_header("Sub", 4) }),
            build_header("Heading", 5, { build_header("Sub", 6) }),
            vim.tbl_extend("force", build_header("Indented", 8), { position = { 8, 2 }, description = "#1 fix, not a heading" }),
        }, parse(
            [[
------------------
-- Banner
------------------
-- ## Sub
-- # Heading
-- ## Sub
SELECT 1; -- # trailing, not a heading
  -- # Indented
-- #1 fix, not a heading
]],
            "sql"
        ))
    end)

    for lang, text in pairs({
        lucene = "-- # Heading\nlogs | a -- # trailing\n",
        promql = "# # Heading\nup # # trailing\n## double hash comment\n",
        mongo = '// # Heading\n{"find": "a"} // # trailing\n',
        cypher = "// # Heading\nMATCH (n) RETURN n; // # trailing\n",
    }) do
        it("parse " .. lang .. " level 1 headings alone on their line", function()
            assert.are.same({ build_header("Heading", 1) }, parse(text, lang))
        end)
    end

    it("collect the comment lines below a section as its description", function()
        assert.are.same({
            with_description(build_header("Banner", 1), "First line\n  indented second\n\nboxed"),
            with_description(build_header("Heading", 9, {
                with_description(build_header("Sub", 11), "sub desc"),
            }), "heading desc"),
            build_header("NoDesc", 14),
            build_header("Next", 17),
            with_description(build_header("Block", 20), "block desc\n\nmore"),
            build_header("BlockNoDesc", 26),
        }, parse(
            [[
------------------
-- Banner
------------------
-- First line
--   indented second
--
-- boxed --
SELECT 1;
-- # Heading
-- heading desc
-- ## Sub
-- sub desc
SELECT 2; -- trailing, not a description
-- # NoDesc

-- not a description, after a blank line
------------------
-- Next
------------------
/******************
 * Block
 * block desc *
 *
 * more
 ******************/
/*****
 * BlockNoDesc
 *****/
]],
            "sql"
        ))
    end)

    for lang, text in pairs({
        lucene = "------\n-- Name\n------\n-- line 1\n-- line 2\nlogs | a\n",
        promql = "######\n# Name\n######\n# line 1\n# line 2 #\nup\n",
        mongo = '/******\n * Name\n * line 1\n ******/\n// line 2\n{"find": "a"}\n',
        cypher = "// # Name\n// line 1\n// line 2\nMATCH (n) RETURN n;\n",
    }) do
        it("collect " .. lang .. " section descriptions", function()
            assert.are.same({ with_description(build_header("Name", 1), "line 1\nline 2") }, parse(text, lang))
        end)
    end
end)

describe("parsing man pages", function()
    local parser = require("sections.parser")

    local function build(name, type, line, col, children)
        return { name = name, type = type, position = { line, col }, private = false, children = children or {} }
    end

    it("nest options under subsections under sections", function()
        local text = table.concat({
            "LS(1)                  User Commands                  LS(1)",
            "",
            "NAME",
            "       ls - list directory contents",
            "",
            "DESCRIPTION",
            "       Mandatory arguments to long options are mandatory for short",
            "       options too, e.g. -a is the same as --all.",
            "",
            "       -a, --all",
            "              do not ignore entries starting with .",
            "",
            "       -c     with -lt: sort by ctime",
            "",
            "   Exit status:",
            "       --min-parents=<n>, --no-min-parents,",
            "       --no-max-parents",
            "              exit status",
            "",
            "GNU coreutils 9.10          August 2026                LS(1)",
        }, "\n")
        local buf = create_buf_with_text(text, "man")

        local sections = drop_node_id(parser.parse_sections(buf))

        assert.are.same({
            build("NAME", "header", 3, 0),
            build("DESCRIPTION", "header", 6, 0, {
                build("-a, --all", "attribute", 10, 7),
                build("-c", "attribute", 13, 7),
                build("Exit status", "header", 15, 3, {
                    build("--min-parents=<n>, --no-min-parents, --no-max-parents", "attribute", 16, 7),
                }),
            }),
        }, sections)
    end)
end)

describe("parsing help pages", function()
    local parser = require("sections.parser")

    local function build(name, line, children)
        return { name = name, type = "header", position = { line, 0 }, private = false, children = children or {} }
    end

    it("nest headings by rule and case", function()
        local text = table.concat({
            "*guide.txt*  A guide",
            "",
            "==============================================================================",
            "Introduction                                                     *guide-intro*",
            "",
            "Some text.",
            "",
            "------------------------------------------------------------------------------",
            "Some words                                                       *guide-words*",
            "",
            "CONNECTING                                                  *guide-connecting*",
            "",
            "==============================================================================",
            "Usage                                                            *guide-usage*",
            "",
            "Parameters: ~",
            "  • a",
        }, "\n")
        local buf = create_buf_with_text(text, "help")

        local sections = drop_node_id(parser.parse_sections(buf))

        assert.are.same({
            build("Introduction", 4, {
                build("Some words", 9, {
                    build("CONNECTING", 11),
                }),
            }),
            build("Usage", 14, {
                build("Parameters", 16),
            }),
        }, sections)
    end)

    it("nest tagged entries and column headings under headings", function()
        local text = table.concat({
            "==============================================================================",
            "Buffer Functions                                                  *api-buffer*",
            "",
            "Unloaded Buffers: ~",
            "",
            "nvim_buf_attach({buf}, {opts})                             *nvim_buf_attach()*",
            "    Activates events.",
            "",
            "    Parameters: ~",
            "      • {buf}",
            "",
            "\t\t\t*'allowrevins'* *'ari'*",
            "'allowrevins' 'ari'\tboolean\t(default off)",
            "\t\t\tglobal",
            "",
            "*plugin.setup({config})*",
            "    Initialize the plugin.",
            "",
            "Options:~",
            ">lua",
            "    -- Code:~",
            "<",
            "Paragraph with",
            "Text ending a paragraph with a tag                                  *not-entry*",
            "",
            "==============================================================================",
            " vim:tw=78:ts=8:ft=help:norl:",
        }, "\n")
        local buf = create_buf_with_text(text, "help")

        local sections = drop_node_id(parser.parse_sections(buf))

        assert.are.same({
            build("Buffer Functions", 2, {
                build("Unloaded Buffers", 4),
                build("nvim_buf_attach({buf}, {opts})", 6, {
                    vim.tbl_extend("force", build("Parameters", 9), { position = { 9, 4 } }),
                }),
                build("'allowrevins' 'ari' boolean (default off)", 13),
                build("plugin.setup({config})", 16, {
                    build("Options", 19),
                }),
            }),
        }, sections)
    end)
end)
