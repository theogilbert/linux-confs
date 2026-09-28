# sections.nvim

A Neovim plugin that displays code sections (functions, classes, headers, etc.) in a sidebar panel using Tree-sitter queries.

## Features

- **Hierarchical Section Display** - View functions, classes, and other code structures in a tree format
- **Collapsible Sections** - Expand/collapse sections to focus on what matters
- **Private Section Filtering** - Toggle visibility of private functions and classes
- **Quick Navigation** - Jump directly to any section in your code
- **Customizable Icons** - Configure icons for different section types
- **Multi-language Support** - Works with Lua, Python, Markdown, JSON, YAML, XML, SQL, Lucene, MongoDB and Cypher, and extensible to other languages
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
        toggle_section_collapse = "<cr>", -- Collapse/expand section
        select_section = "<C-]>",         -- Jump to section in code
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
| `keymaps.toggle_section_collapse` | string | `"<cr>"` | Key to expand/collapse sections |
| `keymaps.select_section` | string | `"<C-]>"` | Key to jump to section |

## Keymaps (within sections panel)

| Key | Action |
|-----|--------|
| `<C-]>` | Jump to section in source code |
| `<cr>` | Collapse/expand section |
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
| SQL, Lucene | Banner comments (see below) | header |
| MongoDB, Cypher | Banner block comments (see below) | header |

SQL and Lucene (`.lucene`) sections are declared with a banner comment. Only the first inner line
is used as the section name; any following lines can hold a description:

```sql
------------------
-- Customers --
-- Active customers only --
------------------
```

MongoDB (`.mongo`) and Cypher (`.cypher`, `.cyp`) sections use the same idea with a block comment:

```
/******************
 * Orders         *
 * Open orders only *
 ******************/
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

### Query Metadata

- `(#set! type "function"|"class"|"attribute"|"header")` - Section type
- `(#set! private "true")` - Mark section as private

## License

MIT License
