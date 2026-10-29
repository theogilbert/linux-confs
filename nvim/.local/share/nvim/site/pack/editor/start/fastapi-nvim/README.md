# fastapi.nvim

See the routes of your FastAPI apps, and the tests that call them, without leaving Neovim.

A Neovim port of the non-cloud features of the
[fastapi-vscode](https://github.com/fastapi/fastapi-vscode) extension.

## Features

- Route explorer: a sidebar tree of apps, routers and routes, with the router prefixes resolved.
- Route search and jumps with colored entries in fzf-lua, or through `vim.ui.select` otherwise.
- Test lenses: `3 tests` above a route, `→ GET /items/{item_id}` above a test client call.
- `:FastAPI jump` between a route and its tests.
- Auto-refresh on save, and when files change outside Neovim.
- Static analysis only: no Python is run, nothing leaves your machine.

## Requirements

- Neovim 0.12 or newer, on Linux.
- The `python` tree-sitter parser.
- [ripgrep](https://github.com/BurntSushi/ripgrep) (`rg`) in `$PATH`.

There are no Lua dependencies. The plugin never downloads or installs anything: if something is
missing it tells you, and `:checkhealth fastapi` says what to do.

## Install

With `vim.pack`:

```lua
vim.pack.add({ "https://github.com/theogilbert/fastapi.nvim" })
```

With lazy.nvim:

```lua
{ "theogilbert/fastapi.nvim", ft = "python", cmd = "FastAPI", opts = {} }
```

`setup()` is optional.

### The Python parser

Neovim does not ship it. Install it with
[nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) (`:TSInstall python`), or
build [tree-sitter-python](https://github.com/tree-sitter/tree-sitter-python) and put `python.so`
in a `parser/` directory of your `runtimepath`. `:checkhealth fastapi` confirms that it loads.

## Quickstart

1. Open a project that has a FastAPI app, and a Python file in it.
2. Run `:FastAPI explorer`.
3. Press `<CR>` on a route to open it, `K` for its docstring, `s` to search.

## Commands

| Command | Action |
|---|---|
| `:FastAPI explorer` | Open or close the route explorer |
| `:FastAPI search` | Search all routes |
| `:FastAPI refresh` | Scan the workspace again |
| `:FastAPI jump` | Jump between a route and its tests |

Suggested mappings (the plugin defines none):

```lua
vim.keymap.set("n", "<leader>fe", "<Plug>(fastapi-explorer)", { desc = "FastAPI explorer" })
vim.keymap.set("n", "<leader>fs", "<Plug>(fastapi-search)", { desc = "FastAPI search" })
vim.keymap.set("n", "<leader>fr", "<Plug>(fastapi-refresh)", { desc = "FastAPI refresh" })
vim.keymap.set("n", "<leader>fj", "<Plug>(fastapi-jump)", { desc = "FastAPI jump" })
```

Options, explorer keys and highlights are in `:help fastapi`. How it works is in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Development

```sh
make deps        # clone plenary and tree-sitter-python into .deps/, build the parser
                 # (TS_PYTHON_REF=<tag or commit> builds and tests another parser)
make check       # lint, typecheck, specs and the 90% coverage threshold
make test        # specs only
make fmt         # format with stylua
make bench       # overhead budgets (not part of check)
```

`make check` needs `stylua`, `luacheck`, `luacov`, `lua-language-server`, `rg` and `cc`;
`scripts/ci-setup.sh` installs them for CI. Linux only.

## License

MIT. The test fixtures are from fastapi-vscode (MIT, © FastAPI Labs).
