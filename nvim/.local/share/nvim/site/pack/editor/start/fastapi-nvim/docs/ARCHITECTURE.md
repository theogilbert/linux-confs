# Architecture

## Modules

```
plugin/fastapi.lua          :FastAPI, <Plug> maps, autocmds; requires nothing at startup
lua/fastapi/init.lua        public API
lua/fastapi/config.lua      defaults, merge, validation
lua/fastapi/state.lua       snapshot of apps and test index; refresh coroutine
lua/fastapi/health.lua      :checkhealth fastapi
lua/fastapi/core/           pure analysis, no editor state
  paths, ts, extract        URL paths, tree-sitter parsing, one file -> facts (cached by mtime and size)
  imports, graph            import resolution, entry file -> router tree
  app                       router tree -> app (full paths, prefix hierarchy)
  rg, discovery             async ripgrep, finding apps
  testindex                 test client calls, linking calls and routes
lua/fastapi/ui/             explorer, picker, lens, jump, labels, highlights
```

## Data flow

```
 rg ──> discovery ──> graph ──> app ──> state ──> ui (explorer, picker, lens, jump)
           │            ▲                 ▲
           └─ extract ──┘                 │
                 ▲                        │
 rg ──> testindex (calls) ── link ────────┘
```

`state` runs discovery, then graph and app per discovered app, then (only if an app exists) the
test index. It computes `links` (call <-> route) and `by_file` once per snapshot, so opening a
file is a table lookup.

## Layering

- `core/*` never requires `ui/*`, `state` or `config`, and reads no editor state (cwd, buffers,
  options). Everything arrives as arguments, so core specs only need files on disk.
- `ui/*` reads data only through `state`. `state` announces changes with the
  `User FastAPIScanning` and `User FastAPIRefreshed` autocmds, and the UI listens to them. There is
  no other event system.
- Plain functions and tables: no classes, no metatables.
- UI modules require `core` lazily, so `:FastAPI` and its completion load nothing.

## Caching and refresh

- `extract.analyze` and `extract.test_calls` memoize small result tables per path, keyed by mtime
  (sec and nsec) and size. Trees and sources are dropped right after extraction.
- A refresh is a coroutine owned by `state`. `rg` runs in its own process; its callback resumes the
  coroutine. Parsing stays on the main loop (`vim.treesitter` cannot run in `vim.uv` threads), so the
  coroutine yields before each file to keep the editor responsive: one file is analyzed per tick.
- A newer refresh bumps a generation counter, and the older coroutine stops at its next resume.
- A save invalidates that file's cache entry right away. After the debounce, only the written files
  are re-parsed; the router graph is rebuilt from the cache. Discovery runs again only when a
  written file mentions `FastAPI` or is `pyproject.toml`. Nothing runs when the project has no app
  and the file does not mention `FastAPI`.
- `FocusGained` runs a debounced full refresh, which costs one `rg` run plus re-parsing changed files.
- Idle means no timer and no polling; the debounce timer exists only while a save is pending.

## Known limits

- Lenses use the saved state: unsaved edits are not analyzed.
- A test call is not tied to an app, so a route's `N tests` includes calls that also match other
  apps (see `:help fastapi-lens`).
- Prefixes and paths that depend on runtime values (`settings.API`) stay as `{settings.API}`; only
  module-level string constants of the same file are resolved.
- Mounted apps are found through `app.mount(path, other)`; a mount is attributed to the app of the
  file that makes it.
- The tag-matched group parents of fastapi-vscode's tree are not ported: they rewrite a router's
  prefix from its tag, so the explorer would stop matching the source.
- Linux only; paths are assumed to use `/`.

## Adding an edge case

1. Add a fixture under `tests/fixtures/` that shows the code layout.
2. Write the spec first: an `extract` spec for a new syntax, or a `graph` spec for a layout. Run it
   and watch it fail.
3. Fix `core/extract.lua` (what is read from a file) or `core/graph.lua` (how files are followed),
   then run `make check`.
