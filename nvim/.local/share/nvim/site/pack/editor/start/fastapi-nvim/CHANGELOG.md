# Changelog

All notable changes to this project are documented in this file. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-10-29

### Added

- Route graph from `include_router`, `mount`, imports, prefixes, aliases, subclasses and factories,
  checked against the fastapi-vscode fixtures.
- App discovery from a `[tool.fastapi]` entrypoint, else a ripgrep search plus tree-sitter.
- Route explorer, with search through `vim.ui.select`.
- Test lenses and `:FastAPI jump` between routes and the tests that call them.
- Auto-refresh on save and on `FocusGained`; one file is analyzed per event-loop tick.
- `:checkhealth fastapi`, `:help fastapi`, `<Plug>` mappings.

[Unreleased]: https://github.com/theogilbert/fastapi.nvim/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/theogilbert/fastapi.nvim/releases/tag/v0.1.0
