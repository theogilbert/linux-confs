# nvim-dap-df-pane

A Neovim plugin that provides a dedicated pane window for displaying DAP (Debug Adapter Protocol) evaluation results.

## Features

- Dedicated pane window for DAP-related content
- Automatic detection of DAP session status
- Configurable pane position and size
- Non-modifiable buffer to prevent accidental edits
- Clean API for future extensibility

## Requirements

- Neovim 0.8.0 or later
- [nvim-dap](https://github.com/mfussenegger/nvim-dap) (optional, but recommended)

## Installation

Using [packer.nvim](https://github.com/wbthomason/packer.nvim):

```lua
use {
  'nvim-dap-df-pane',
  requires = 'mfussenegger/nvim-dap',
  config = function()
    require('nvim-dap-df-pane').setup()
  end
}
```

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  'nvim-dap-df-pane',
  dependencies = { 'mfussenegger/nvim-dap' },
  config = function()
    require('nvim-dap-df-pane').setup()
  end
}
```

## Configuration

```lua
require('nvim-dap-df-pane').setup({
  -- Position of the pane window
  -- Options: "bottom", "top", "left", "right"
  position = "bottom",
  
  -- Size of the pane window
  -- For horizontal splits (top/bottom): height in lines
  -- For vertical splits (left/right): width in columns
  size = 10,
  
  -- Default text shown when no DAP session is running
  default_text = "No DAP session is currently running",
})
```

## Usage

### Basic Commands

```lua
-- Open the pane
require('nvim-dap-df-pane').open()

-- Close the pane
require('nvim-dap-df-pane').close()

-- Toggle the pane
require('nvim-dap-df-pane').toggle()
```

### Example Keybindings

```lua
vim.keymap.set('n', '<leader>dp', function() require('nvim-dap-df-pane').toggle() end, { desc = "Toggle DAP Pane" })
```

## API

### `setup(opts)`

Initialize the plugin with the given options.

- `opts` (table, optional): Configuration options
  - `position` (string): Window position ("bottom", "top", "left", "right")
  - `size` (number): Window size
  - `default_text` (string): Text shown when no DAP session is active

### `open()`

Opens the DAP pane window. If already open, this is a no-op.

### `close()`

Closes the DAP pane window.

### `toggle()`

Toggles the DAP pane window open/closed.

## Future Features

The following features are planned for future releases:

- Expression evaluation and result display
- Custom keymaps for the pane buffer
- Highlight groups for syntax highlighting
- Interactive features within the pane
- Multiple content views
- History of evaluated expressions

## Development

### Project Structure

```
.
├── lua/
│   └── nvim-dap-df-pane/
│       ├── init.lua      # Main plugin module
│       ├── pane.lua      # Pane window management
│       └── buffer.lua    # Buffer management
├── tests/               # Test files
├── doc/                # Vim documentation
└── README.md           # This file
```

### Running Tests

Tests are written using the busted framework:

```bash
busted tests/
```

## License

MIT License - see LICENSE file for details.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.