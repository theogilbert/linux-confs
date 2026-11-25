# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Neovim plugin (Lua, no build step) that reads a file as it would be
read rather than as it was typed: a reader buffer swapped into the
window in the file's place, and back. Markdown today; other filetypes
are a reader each (`config.filetypes`). It is also the markdown engine
nemeton.nvim draws its comments with, so `render.markdown` and
`render.draw` are an API: change their options and shapes deliberately.

`README.md` and `doc/render.txt` document every command, key, config
option and highlight group; update **both** when you change one.

## Commands

```sh
./tests/run.sh                           # headless nvim
./tests/run.sh tests/spec/view_spec.lua  # one spec file
./tests/check.sh                         # luacheck, stylua, suite here and on the CI floor
```

Same house rules as nemeton.nvim: stylua at 100 columns, comments wrapped
by hand at about 72, luacheck's 120 a wall rather than a target. The
floor is 0.10.4 (CI's matrix). plenary specs under `tests/spec/`, one file
per module, each file a sequence of `it`s that may lean on the ones above.

## Architecture

- `plugin/render.lua` registers `:Render` and the toggle key and loads
  nothing else.
- `render.markdown` is pure: blocks and inline runs, with hooks (`link`,
  `url`, `claims`, `fence`, `groups`) for callers that know more.
- `render.draw` turns blocks into lines of `{ text, hl }` chunks (plus
  `row`, the source line, and `heading`), and `flatten` into lines,
  extmark highlights and link positions.
- `render.view` is the reader: one scratch buffer per source buffer,
  redrawn on change and resize, cursor mapped through `row`, `<C-]>`
  through the link positions and `config.follow`.
- `render.filetypes.<ft>` is a reader: `render(lines, opts)` to chunk
  lines.
- `tex`, `emoji`, `syntax` are pure helpers lifted from nemeton.nvim.

## Conventions

- Comments explain the decision, not the code.
- Every key in `config.keys` can be `false`.
- Commit messages are `scope: lowercase sentence`.
