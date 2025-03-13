# NVIM configuration

This directory contains my Neovim configuration.

It includes some plugin which have been personnally vetted and in some cases, cleaned-up to remove unneeded features.

## Requirements

- nvim 0.10.2 or later

## Installation

To install this configuration:

```bash
# clone this repository in a stable directory
# To easily apply configuration updates, the nvim configuration
# directories will link to the cloned repository.
git clone https://github.com/theogilbert/linux-confs
ln -s $(pwd)/linux-confs/nvim/.config/nvim ~/.config/nvim
ln -s $(pwd)/linux-confs/nvim/.local/share/nvim ~/.local/share/nvim
```

## Included plugins

### Colorschemes

#### Sonokai

The `sainnhe/sonokai` plugin adds an improved colorscheme.

### UI

#### mini.statusline

The `echasnovski/mini.nvim` repository includes a `mini.statusline` plugin.

This plugin customizes the statusline.

### UX

#### which-keys

It can be difficult to remember all defined shortcuts.

This plugin displays possible completions for initiated the initiated keymap sequence.

#### fzf-lua

This plugin provides various shortcuts to search for text, files, symbols, ... in the current workspace and file.

#### nvim-tree

nvim-tree is a file explorer within nvim.

#### nvim-cmp

This plugin provides an improved auto-completion UX.

#### cmp-buffer

cmp-buffer provides an additional source for nvim-cmp, using words present in the current buffer.

#### cmp-path

cmp-path provides an additional source for nvim-cmp, using files present in the filesystem.

### Language support

#### nvim-lspconfig

This official nvim plugin provides default configuration for most LSP servers.

#### cmp-nvim-lsp

This nvim-cmp source provides completion candidate from LSP symbols.

#### cmp-nvim-lsp-signature-help

This nvim-cmp source displays the current function's signature in insert mode.

#### basedpyright

#### ruff

#### yaml-language-server

#### typescript-language-server

### Debugger

#### nvim-dap

The nvim-dap plugin allows nvim to communicate with various debuggers through the DAP protocol.

#### nvim-dap-ui

Provides an improved interface on top of nvim-dap.

#### debugpy

An implementation of the Debug Adapter Protocol for Python 3.

### Treesitter parsers

- Python

### Additional libraries

#### nvim-nio

This library is required by nvim-dap-ui.
