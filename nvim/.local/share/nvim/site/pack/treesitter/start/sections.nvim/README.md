# sections.nvim

A Neovim plugin that displays code sections (functions, classes, headers, etc.) in a sidebar panel using Tree-sitter queries.

## Features

- **Hierarchical Section Display** - View functions, classes, and other code structures in a tree format
- **Collapsible Sections** - Expand/collapse sections to focus on what matters
- **Private Section Filtering** - Toggle visibility of private functions and classes
- **Quick Navigation** - Jump directly to any section in your code
- **Customizable Icons** - Configure icons for different section types
- **Multi-language Support** - Works with Lua, Python, Markdown, JSON, YAML, XML, SQL, Lucene, PromQL, MongoDB and Cypher, and extensible to other languages
- **Auto-refresh** - Automatically updates when you save files or switch buffers

## Requirements

- Neovim 0.11.3+ with Tree-sitter support.\
  Previous versions have not been tested.
- Tree-sitter parsers for the languages you want to use.
- A Nerd Font to properly display icons.

## Installation

### Manual Installation

To install **sections.nvim** manually, clone or download the plugin repository and place it inside your Neovim runtime path under `pack`:

```sh
git clone https://github.com/yourusername/sections.nvim.git \
  ~/.config/nvim/pack/plugins/start/sections.nvim
```

## Usage

Toggle the sections panel:
```lua
require("sections").toggle()
```

Or create a keymap:
```lua
vim.keymap.set("n", "<leader>s", function() require("sections").toggle() end, { desc = "Toggle sections" })
```

Jump to a section by name, without opening the panel. With no argument, the
name is asked for on the command line with `<Tab>` completion over the
buffer's sections:
```lua
require("sections").jump()            -- prompt, e.g. "Section: Foo.ru<Tab>"
require("sections").jump("Foo.run")   -- qualified name
require("sections").jump("run")       -- bare name, if unambiguous
```
The `:SectionsJump [name]` command does the same.

## Configuration

```lua
require("sections").setup({
    indent = 2,                           -- Indentation per level
    width = 40,                           -- Default width of the pane
    icons = {                             -- Icons for different section types
        ["function"] = "󰊕",
        class = "",
        attribute = "󰠲",
        header = "",
    },
    keymaps = {                           -- Keymaps within the sections panel
        toggle_private = "p",             -- Toggle private sections visibility
        select_section = "<cr>",          -- Jump to section in code
        collapse_section = "zc",          -- Collapse section
        expand_section = "zo",            -- Expand section
        toggle_section_collapse = "za",   -- Collapse/expand section
        show_description = "K",           -- Show section description
        close = "q",                      -- Close the pane
    },
})
```

### Configuration Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `indent` | number | `2` | Number of spaces to indent nested sections |
| `width` | number | `40` | Width of the section pane (in characters) |
| `icons.function` | string | `"󰊕"` | Icon for functions |
| `icons.class` | string | `""` | Icon for classes |
| `icons.attribute` | string | `"󰠲"` | Icon for attributes/variables |
| `icons.header` | string | `""` | Icon for headers/headings |
| `keymaps.toggle_private` | string | `"p"` | Key to toggle private sections |
| `keymaps.select_section` | string | `"<cr>"` | Key to jump to section |
| `keymaps.collapse_section` | string | `"zc"` | Key to collapse a section |
| `keymaps.expand_section` | string | `"zo"` | Key to expand a section |
| `keymaps.toggle_section_collapse` | string | `"za"` | Key to collapse/expand a section |
| `keymaps.show_description` | string | `"K"` | Key to show a section's description |
| `keymaps.close` | string | `"q"` | Key to close the pane |

## Keymaps (within sections panel)

| Key | Action |
|-----|--------|
| `<cr>` | Jump to section in source code |
| `zc` / `zo` | Collapse / expand section |
| `za` | Toggle section collapse |
| `K` | Show section description |
| `q` | Close the pane |
| `p` | Toggle private sections visibility |

## Supported Languages

See `:help sections-languages` for an example of each.

| Language | Sections | Type |
|----------|----------|------|
| Lua | `function M.name()` (public); `function M:name()`, `function name()`, `local function name()`, `name = function()` (private) | function |
| Python | Functions and methods (private if named `_*`) | function |
| | Classes, with base classes (private if named `_*`) | class |
| | Class and module attributes, with type annotation (private if named `_*`) | attribute |
| Markdown | ATX headers (`#`), nested by level | header |
| JSON | Object keys, nested | header |
| YAML | Mapping keys, nested | header |
| XML | Elements, including self-closing, nested | header |
| SQL, Lucene | Banner comments, block comment banners in SQL (see below) | header |
| PromQL | Banner `#` comments (see below) | header |
| MongoDB, Cypher | Banner block or `//` comments (see below) | header |
| SQL, Lucene, PromQL, MongoDB, Cypher | Subsections, nested by level (see below) | header |

SQL and Lucene (`.lucene`) sections are declared with a banner comment: the name line between two
lines of dashes. Boxing the name (`-- Customers --`) is optional; a description can follow below:

```sql
------------------
-- Customers
------------------
-- Active customers only
```

PromQL (`.promql`) uses the same banner, written with `#`:

```
##################
# Errors
##################
```

MongoDB (`.mongo`) and Cypher (`.cypher`, `.cyp`) sections use the same idea with a block comment
(also accepted in SQL), or with `//` comments:

```
/******************
 * Orders         *
 * Open orders only *
 ******************/

//////////////////
// Orders
//////////////////
```

A line comment alone on its line and starting with `#` is a heading whose level is the number
of `#`, as in Markdown: `-- # name` is a level 1 section, like a banner, and `-- ## name` nests
under it. The comment marker is the language's own: `--` (SQL, Lucene), `#` (PromQL, so
`# # name`), `//` (MongoDB, Cypher). Comments trailing code are never headings.

The comment lines right below a banner or heading are its description, shown with `K` in the
pane. It ends at a blank line, code, or the next section. In a block comment banner, the lines
after the name are part of it too.

```sql
------------------
-- Customers
------------------
-- ## Active
SELECT * FROM customers WHERE active;
-- ### By region
SELECT region, count(*) FROM customers WHERE active GROUP BY region;
```

## Extending Language Support

To add support for new languages, create Tree-sitter query files in `queries/<language>/sections.scm`. 

Example query for functions:
```query
(function_definition
  name: (identifier) @section.name
  parameters: (parameters (identifier) @section.param)*
) @section
(#set! type "function")
```

### Query Captures

- `@section` - The entire section node
- `@section.name` - The section name
- `@section.param` - Function parameters (optional)
- `@section.type_annotation` - Type annotations (optional)
- `@section.level` - Section level, from the length of its (usually `#gsub!`-rewritten) text (optional)
- `@section.description` - Section description, shown with `K` (optional)

### Query Metadata

- `(#set! type "function"|"class"|"attribute"|"header")` - Section type
- `(#set! private "true")` - Mark section as private
- `(#set! level "1")` - Section level: nest under the closest preceding section of a lower level
- `(#set! description_prefix "<pattern>")` - The comment lines right below the section are its description, stripped of this Lua pattern
- `(#sections-banner? @rule @name @close)` - `@rule` opens a banner of line comments, with `@name` on the next line and `@close` on the one after
- `(#sections-own-line? @node)` - `@node` is alone on its line, not trailing code

## License

MIT License
