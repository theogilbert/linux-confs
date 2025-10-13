# sections.nvim

A Neovim plugin that displays code sections (functions, classes, headers, etc.) in a sidebar panel using Tree-sitter queries.

## Features

- **Hierarchical Section Display** - View functions, classes, and other code structures in a tree format
- **Collapsible Sections** - Expand/collapse sections to focus on what matters
- **Private Section Filtering** - Toggle visibility of private functions and classes
- **Quick Navigation** - Jump directly to any section in your code
- **Customizable Icons** - Configure icons for different section types
- **Multi-language Support** - Works with Lua, Python, Markdown, and extensible to other languages
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

## Configuration

```lua
require("sections").setup({
    indent = 2,                    -- Indentation per level
    icons = {                      -- Icons for different section types
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

### Lua

- Function declarations
- Function assignments (`local func = function() end`)

### Python  

- Functions (public and private with `_` prefix)
- Classes (public and private with `_` prefix)
- Class attributes with type annotations
- Module-level variables

### Markdown

- Headers (all levels using `#` syntax)

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
