# salmon.nvim

Swim upstream: trace where the value of the variable under the cursor comes from.

`:Salmon` opens a side pane showing the chain of points the value passed through
on its way to the cursor: assignments, aliases, parameters and the arguments
callers pass to them, loop variables, imports, and optionally the expressions it
was derived from. Nodes expand lazily, so deep or branching chains stay cheap.

The chain reads top to bottom, in the order the value travels: where it starts
at the top, the traced symbol (`╋`) at the bottom, joined by one unbroken line. Above each step, a line says
how the value got there.

```
╷ defined
╪ base = 10                      main.py:10
│ maybe defined (in a branch)
╪ base = 20                      main.py:12
│ copied from another variable
┿ offset = base                  main.py:13
│ passed as argument
┿ result = compute(offset, b=5)  main.py:14
│ function parameter
┿ def compute(a, b):             main.py:4
│ traced
╋ a                              main.py:5
```

Markers: `╪` end of the chain (nothing further upstream), `┼` more upstream
hidden (expand it), `┿` expanded. They are box-drawing characters, so they line
up in any font that has box drawing; change them with the `icons` option. A
step that may not happen (inside a branch) says "maybe". When a step has several
inputs, the extra ones branch off to the right and merge back in (derive mode, `count += offset`).
Parallel inputs (call sites, several definitions) are ordered by closeness to
the traced symbol: same file first (nearest line first), then other files,
non-test before test files (a `test`/`tests` word in the path), nearest
directory first. The closest one is drawn right above the step it feeds into,
and is the one `[s` follows; the others go further up, the furthest on the left
line. Here `offset` is an extra input of `count`:

```
╷ defined
╪ count = 0        main.py:18
│ ╷ defined
│ ╪ base = 10      main.py:10
│ │ maybe defined (in a branch)
│ ╪ base = 20      main.py:12
│ │ copied from another variable
│ ┿ offset = base  main.py:13
│ │ uses variable
│ ┿ offset         main.py:19
├─╯
│ updated from its previous value
┿ count += offset  main.py:19
│ traced
╋ count            main.py:20
```

The pane closes with the source window it was opened from.

## Labels

Each step has a label, shown in words in the pane and as a short code in the
hover (`K`) and help (`g?`):

| Label | Meaning |
|-------|---------|
| `SYM` | the symbol being traced (root) |
| `DEF` | defined here: end of the chain |
| `CND` | conditionally assigned (inside a branch/loop that does not enclose the use); prefixes another label |
| `ALS` | alias: assigned straight from another variable (`a = b`), always followed |
| `DRV` | derived from an expression (`c = f(a, b)`); only in derive mode, otherwise shown as `DEF` |
| `UPD` | update: a new value computed from the variable's own previous value (`df = df.dropna()`, `x += 1`) |
| `MUT` | mutated in place (`x[k] = v`, `x.a = v`, `x.append(y)`: a method call whose result is discarded) |
| `RD`  | read on the way to the traced use (`f(x)` says "passed to a function", `y = x + 1` says "read"); end of chain. Hidden with `reads = false` (`r`) |
| `PRM` | function parameter; expands to the call sites |
| `ARG` | argument passed for that parameter at a call site |
| `FOR` | loop variable; expands to the iterated value |
| `IMP` | import line (`from m import x`, `import { x }`, `x = require("m")`); expands to the definition in the other module |
| `SRC` | a variable a derived expression depends on (derive mode) |
| `FN`  | a function a derived expression calls (derive mode); expands to its `RET`s |
| `RET` | a return statement of that function |

A variable's history reads as a timeline on one line: its base `DEF`, then
each `UPD`/`MUT`, and each place it is read (`RD`), in source order. The other inputs of an update branch off to
the side. Under `UPD`/`MUT` nodes, the variable itself and the methods called
on it are hidden; only the other inputs are shown.

```
╷ defined
╪ df = pd.read_csv(path)           frames.py:5
│ updated from its previous value
╪ df = df.dropna()                 frames.py:6
│ updated from its previous value
╪ df = df.rename(columns=mapping)  frames.py:7
│ mutated in place
╪ df["total"] = df.a + df.b        frames.py:8
│ maybe updated from its previous value (in a branch)
╪ df = pd.concat([df, extra])      frames.py:10
│ passed to a function
╪ items.append(len(df))            frames.py:12
│ traced
╋ df                               frames.py:14
```

Rule of thumb: a bare identifier flowing into something (`a = b`, `f(b)`,
`for x in b`, `return b`) is a *passage* and is always followed. Any other
expression is a *transformation* and is only followed in derive mode.

A member of the current object (`self.x`, `this.x`) counts as a bare
identifier: it leads to every assignment to that member in the class (the whole
file in languages without classes, like Lua), such as `self.x = ...` in
`__init__`. When the class has none, the LSP's definition is used (e.g. a base
class). The object itself (`self`) is shown last, as another input: it leads to
the method's callers, where `self` is the object the method is called on
(`store` in `store.query()`).

## Requirements

- Neovim 0.11+ (tested on 0.12)
- A tree-sitter parser for the language (required)
- An LSP server (optional but recommended). Used for `documentHighlight`
  (precise read/write occurrences), `definition` (imports, cross-file
  functions, globals) and `references` (call sites). Without one, salmon falls
  back to same-file, name-based tree-sitter heuristics, and follows imports by
  resolving relative module paths (Python, JS/TS, Lua `require`).

No language-specific tables: salmon relies on conventions shared by tree-sitter
grammars (node type names such as `if_statement` / `call_expression`, and
fields such as `left`/`right`, `name`/`value`, `function`, `arguments`,
`parameters`). Tested on Python (ty), Lua (lua_ls) and TypeScript.

## Install

Any plugin manager, or natively:

```sh
git clone <repo> ~/.local/share/nvim/site/pack/editor/start/salmon.nvim
```

## Usage

```lua
local salmon = require("salmon")
salmon.setup({}) -- optional

vim.keymap.set("n", "<leader>ls", salmon.trace, { desc = "Trace symbol origin" })
vim.keymap.set("n", "<leader>lS", function() salmon.trace({ derive = true }) end)
-- or: vim.keymap.set("n", "<leader>ls", "<Plug>(salmon-trace)")
```

Lua API: `trace(opts)`, `trace_at(buf, row, col, opts)`, `toggle(opts)`,
`close()`, `is_open()`, `refresh()`, `next()`, `prev()`, `next_path()`, `prev_path()`, `derive()`,
`set_derive(bool)`, `toggle_derive()`, `reads()`, `set_reads(bool)`, `toggle_reads()`.
`opts` takes `{ derive = bool, reads = bool, focus = bool }`;
with `focus = false` you stay in the source window and step with `]s`/`[s`.

`<Plug>` mappings: `(salmon-trace)`, `(salmon-toggle)`, `(salmon-close)`,
`(salmon-refresh)`, `(salmon-derive)`, `(salmon-reads)`, `(salmon-next)`, `(salmon-prev)`,
`(salmon-next-path)`, `(salmon-prev-path)`.

Commands: `:Salmon [trace|toggle|close|derive|reads|refresh|next|prev|next_path|prev_path]` (default `trace`).

The pane's header line shows whether derive mode and reads are on.

Pane keymaps:

| Key | Action |
|-----|--------|
| `[s` / `]s` | step back (towards the definition) / forward (towards the traced symbol) along the path shown in the sign column, showing each step in the source window (centered when it lands in another file or near the window's edge). Global while the pane is open. The top of the path is expanded on landing and the pane scrolls to keep the steps before and after in view, so it shows where the next press leads; repeating `[s` swims up the whole chain |
| `[r` / `]r` | previous / next path leading to the selected step: changes the path in the sign column and where `[s` leads. Global while the pane is open |
| `<CR>` | jump to the node (jumplist-friendly) |
| `p` | preview: jump but keep focus in the pane |
| `o` `<Tab>` `l` | expand / collapse |
| `h` | collapse, or go to the step it flows into |
| `t` | track symbol under cursor: start a new trace from this step |
| `d` | toggle derive mode |
| `r` | toggle reads: show or hide the `RD` steps |
| `R` | refresh |
| `q` | close |
| `g?` | help / legend |
| `zo` `zO` `zc` `zC` `za` `zA` `zR` `zM` `zr` `zm` `zn` `zN` `zi` `zx` `zX` `zj` `zk` `[z` `]z` | standard fold commands, acting on the chain. Recursive ones stop at `fold_depth` (see `:h salmon-folds`) |
| `K` | hover: label meanings, location, path from the traced symbol, upstream status, full source statement |

## Configuration

```lua
require("salmon").setup({
  derive = false,      -- follow derivations (DRV/SRC/FN/RET)
  reads = true,        -- show where the variable is read on the way (RD)
  auto_expand = 4,     -- auto-expand single-child chains this many levels
  fold_depth = 6,      -- depth limit for zO, zA, zR, zn
  width = 60,
  position = "left",  -- or "right"
  max_text = 60,       -- truncate source snippets
  icons = { traced = "╋", expanded = "┿", collapsed = "┼", done = "╪", loading = "╂" },
  keymaps = { jump = { "<CR>" }, preview = { "p" }, toggle = { "o", "<Tab>", "l" },
              collapse = { "h" }, track = { "t" }, derive = { "d" },
              reads = { "r" }, refresh = { "R" }, close = { "q" }, help = { "g?" },
              hover = { "K" }, next = { "]s" }, prev = { "[s" },
              next_path = { "]r" }, prev_path = { "[r" } },
})
```

Highlight groups (`SalmonDEF`, `SalmonCND`, …, `SalmonLocation`, `SalmonGraph`) are linked to
standard groups by default and can be overridden.

While the pane is open, the traced symbol's line gets a dim background
(`SalmonOrigin`, linked to `CursorLine`). Every occurrence of the traced
variable is highlighted (`SalmonSymbol`, linked to `Search`), and the one you
traced from stands out (`SalmonSymbolOrigin`, linked to `IncSearch`). The
occurrences of the selected step's variable, in another function or file, are
highlighted the same way. The node selected in the pane is
highlighted in its source buffer (`SalmonSelected`, linked to `Visual`). When
it is a derivation source (`SRC`) or upstream of one, every occurrence of that
source's variable is highlighted too (`SalmonSource`, linked to `DiffText`).

The sign column shows one path through the selected node, from the top of the
chain down to the traced symbol; `[s`/`]s` walk along it. It is kept while the
selection stays on it; selecting a step off it switches to the main line
through that step. Each step is numbered (`SalmonFlowStep`, linked to `Title`; `4+` when
more steps share the line), with a
line between consecutive steps in the same file, ending in a heavy half
(`╽`/`╿`) that points at the next one (`SalmonFlow`, linked to `Special`). Where the
path continues in another file, the line turns off to the left below the step
(`─╯`); where it arrives from another file, it comes in from the left above the
step (`─╮`). In the pane, steps off that path (other paths, see `]r`) are
dimmed (`SalmonOffPath`, linked to `Comment`).

## Limitations

These are heuristics, not a data-flow analysis:

- Reaching definitions are positional: the last unconditional write before the
  use, plus any conditional writes after it. Writes later in an enclosing loop
  body are not considered.
- Mutation detection is syntactic: a method call used as a statement counts as
  a mutation (so `df.head()` on its own line does too). Mutation through
  another reference, or by passing the object to a function, is not tracked.
  Neither is dynamic dispatch.
- Argument matching handles positional and keyword arguments and skips an
  implicit `self`/`cls`. `*args`/`**kwargs` show as unmatched.

## Tests

```sh
nvim --headless -l tests/run.lua               # tree-sitter only
nvim --headless -c 'luafile tests/run.lua'     # with your config's LSP servers
```
