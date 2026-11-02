# Changelog

All notable changes to this project are documented in this file. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.0] - 2026-10-30

### Added

- `:FastAPI search` and the `:FastAPI jump` choices use fzf-lua when it is installed: colored
  entries, in a window sized to them. `vim.ui.select` remains the fallback.
- The `:FastAPI jump` picker names the tests that call a route.
- Fold keymaps in the explorer: `za`, `zo`, `zO`, `zc`, `zC`, `zR`, `zM`.
- `lens.position`: lenses above the line (default) or at its end (`"eol"`).
- Websocket routes show with a `WS` prefix in the explorer and the pickers.
- The `K` float highlights the route like the explorer does.
- `*fastapi*` help tag, and demo GIFs in the README.

### Changed

- The explorer opens on the right by default.

### Fixed

- `websocket_connect` test calls link to websocket routes.
- Docstrings are read with newer tree-sitter-python parsers.
- End-of-line lenses keep the line background, such as the cursorline.

## [0.1.0] - 2026-10-29

### Added

- Route graph from `include_router`, `mount`, imports, prefixes, aliases, subclasses and factories,
  checked against the fastapi-vscode fixtures.
- App discovery from a `[tool.fastapi]` entrypoint, else a ripgrep search plus tree-sitter.
- Route explorer, with search through `vim.ui.select`.
- Test lenses and `:FastAPI jump` between routes and the tests that call them.
- Auto-refresh on save and on `FocusGained`; one file is analyzed per event-loop tick.
- `:checkhealth fastapi`, `:help fastapi`, `<Plug>` mappings.

[Unreleased]: https://github.com/theogilbert/fastapi.nvim/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/theogilbert/fastapi.nvim/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/theogilbert/fastapi.nvim/releases/tag/v0.1.0
