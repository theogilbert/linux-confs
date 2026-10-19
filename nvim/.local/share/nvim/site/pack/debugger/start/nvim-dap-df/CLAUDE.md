# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

`nvim-dap-df-pane` is a Neovim plugin that displays pandas DataFrames/Series from an active nvim-dap (Python) debug session as formatted tables in split panes, with interactive sort, filter, and column navigation.

This directory lives inside a larger dotfiles repo (git root is `~/projects/confs`), installed as a native package under `pack/debugger/start/`. It is not a standalone git repo.

**The README is outdated.** It describes `position`/`default_text` options and a `toggle()` function that no longer exist. The real config is `{ size, limit, thousands_separator }` (see `init.lua`), and the public API is `setup`, `open`, `close`, `destroy`, and `inspect(expr)`.

## Commands

```bash
make test                                                      # run all specs (plenary busted, headless nvim)
nvim --headless -c "PlenaryBustedFile tests/expression_spec.lua"   # run a single spec file
make format                                                    # stylua .
```

The tests run `nvim --headless` with the user's normal config, so dependencies are resolved from sibling packs in `~/.local/share/nvim/site/pack/`:
- `plenary.nvim` (`pack/libs/start/`), used for testing
- `nvim-dap` (`pack/debugger/start/`), required at load time by `init.lua` and `evaluator.lua`
- `fzf-lua`, optional. Only the `gc` (jump to column) keymap uses it.

The table UI (formatter, buffer/help float, column picker, row detail float, hover) is ported from grannos.nvim (`~/projects/grannos/grannos.nvim`, `lua/grannos/table.lua`, `buffer.lua`, `ui/{col_picker,row_detail,hover}.lua`). It is a copy, not a dependency: the two are not kept in sync.

## Architecture

Layers, from the UI down to DAP:

- **`init.lua`**: owns plugin state (config + list of `Pane`s). Creating a pane wires up its `on_split`/`on_close` callbacks so that panes can spawn sibling panes. `setup()` registers a `dap.listeners.after.scopes` hook that calls `pane:refresh(false)` on every pane whenever the DAP context changes (step, frame change), which invalidates caches.
- **`pane.lua`**: one window plus one `Buffer`. Handles keymaps (grouped in the `g?` help via `opts.group`), window lifecycle (`WinClosed` autocmd detects external closes; `_teardown` deregisters autocmds before `close()` so `on_close` doesn't fire twice), horizontal scrolling that snaps to column boundaries, and `◂/▸` truncation extmarks. All nvim window/cursor APIs belong here.
- **`dataview.lua`**: drives evaluation, parses the CSV (`csv.lua`) and formats the result (`table.lua`) into display lines and highlight rules. Buffer layout is prompt line, blank line, then the table from `DataView.TABLE_START` (0-indexed row 2). It owns the display state (`visible`: shown raw column indices in display order, `sep_columns`: thousands-separator toggles), which survives refreshes while the column names are unchanged; `render()` rebuilds the table without re-evaluating. Cursor-based methods take a `Cursor` (`{ line = 0-indexed row, col = virtcol }`) and return nil off the table's lines. Display column indices differ from raw ones once columns are hidden or reordered (`raw_index`); raw column 1 is always the index. Missing values (`na_rep="pd.NA"`) become `vim.NIL` and render as `NA`. It is UI-agnostic (no window/buffer calls). `refresh(on_ready, on_failed, use_cache)` calls `on_ready` twice: once immediately (to render the "loading" state) and once when evaluation completes.
- **`expression.lua`**: pure string logic with no nvim APIs. Holds the base expression plus sort/filter state, and `build()` produces the effective Python expression (`.query(..., engine='python')` per filter, then `sort_values`/`sort_index`). It has the most unit tests.
- **`evaluator.lua`**: sends several async DAP `evaluate` requests in parallel (type, data as CSV via `.head(limit).to_csv()` in `clipboard` context to avoid truncation, dtypes, col count, row count), collects them in an `EvaluationState`, and fires the callback once all fields are present (or once on the first error). `EvaluationCache` reuses type/dtypes/col_count across refreshes. A base-expression change invalidates everything, a filter change invalidates only `row_count`, and a sort change invalidates nothing. Data is always refetched.
- Support modules: `buffer.lua` (scratch buffer wrapper; registers `g?`, which lists the keymaps registered through it), `col_picker.lua` (`c`), `row_detail.lua` (`<CR>`), `hover.lua` (`K`), `prompt.lua` (floating `acwrite` buffer for entering expressions; saving confirms), `hl.lua` (highlight groups `DapDf*` and namespaces, applied per window via `nvim_win_set_hl_ns`).

On a failed refresh after a new expression, `Pane:refresh` rolls back to the previous `DataView` (`rollback_dataview`).

## Conventions

- Classes use the `X.__index = X` / `X:new()` metatable pattern, and annotations use LuaLS `---@` syntax.
- Indentation is currently mixed (tabs and spaces). There is no stylua config, so `make format` uses stylua's defaults.
