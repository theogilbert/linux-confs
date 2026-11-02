# salmon.nvim

Swim upstream: trace where the value of the variable under the cursor comes from.

`:Salmon` opens a side pane showing the chain of points the value passed through
on its way to the cursor: assignments, aliases, parameters and the arguments
callers pass to them, loop variables, imports, and optionally the expressions it
was derived from. Nodes expand lazily, so deep or branching chains stay cheap.

```
▾ SYM a  main.py:5
  ▾ PRM def compute(a, b):  main.py:4
    ▾ ARG result = compute(offset, b=5)  main.py:14
      ▾ ALS offset = base  main.py:13
        · DEF base = 10  main.py:10
        · CND DEF base = 20  main.py:12
```

The pane closes with the source window it was opened from.

## Labels

| Label | Meaning |
|-------|---------|
| `SYM` | the symbol being traced (root) |
| `DEF` | defined here: end of the chain |
| `CND` | conditionally assigned (inside a branch/loop that does not enclose the use); prefixes another label |
| `ALS` | alias: assigned straight from another variable (`a = b`), always followed |
| `DRV` | derived from an expression (`c = f(a, b)`); only in derive mode, otherwise shown as `DEF` |
| `UPD` | update: a new value computed from the variable's own previous value (`df = df.dropna()`, `x += 1`) |
| `MUT` | mutated in place (`x[k] = v`, `x.a = v`, `x.append(y)`: a method call whose result is discarded) |
| `PRM` | function parameter; expands to the call sites |
| `ARG` | argument passed for that parameter at a call site |
| `FOR` | loop variable; expands to the iterated value |
| `IMP` | imported name; expands to its definition in the other module |
| `SRC` | a variable a derived expression depends on (derive mode) |
| `FN`  | a function a derived expression calls (derive mode); expands to its `RET`s |
| `RET` | a return statement of that function |

A variable's history reads as a flat timeline: its base `DEF`, then each
`UPD`/`MUT` in source order. A chain like `df = df.foo(); df = df.bar()` does
not nest one level per step. Under `UPD`/`MUT` nodes, the variable itself and
the methods called on it are hidden; only the other inputs are shown.

```
▾ SYM df  frames.py:14
  · DEF df = pd.read_csv(path)  frames.py:5
  · UPD df = df.dropna()  frames.py:6
  ▸ UPD df = df.rename(columns=mapping)  frames.py:7
  · MUT df["total"] = df.a + df.b  frames.py:8
  ▸ CND UPD df = pd.concat([df, extra])  frames.py:10
```

Rule of thumb: a bare identifier flowing into something (`a = b`, `f(b)`,
`for x in b`, `return b`) is a *passage* and is always followed. Any other
expression is a *transformation* and is only followed in derive mode.

## Requirements

- Neovim 0.11+ (tested on 0.12)
- A tree-sitter parser for the language (required)
- An LSP server (optional but recommended). Used for `documentHighlight`
  (precise read/write occurrences), `definition` (imports, cross-file
  functions, globals) and `references` (call sites). Without one, salmon falls
  back to same-file, name-based tree-sitter heuristics.

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
`close()`, `is_open()`, `refresh()`, `next()`, `prev()`, `derive()`,
`set_derive(bool)`, `toggle_derive()`. `opts` takes `{ derive = bool, focus = bool }`;
with `focus = false` you stay in the source window and step with `]s`/`[s`.

`<Plug>` mappings: `(salmon-trace)`, `(salmon-toggle)`, `(salmon-close)`,
`(salmon-refresh)`, `(salmon-derive)`, `(salmon-next)`, `(salmon-prev)`.

Commands: `:Salmon [trace|toggle|close|derive|refresh|next|prev]` (default `trace`).

Pane keymaps:

| Key | Action |
|-----|--------|
| `]s` / `[s` | step along the chain, showing each node in the source window. Global while the pane is open; expands collapsed nodes when stepping down |
| `<CR>` | jump to the node (jumplist-friendly) |
| `p` | preview: jump but keep focus in the pane |
| `o` `<Tab>` `l` | expand / collapse |
| `h` | collapse, or go to parent |
| `R` | re-root the trace at this node |
| `d` | toggle derive mode |
| `r` | refresh |
| `q` | close |
| `g?` | help / legend |
| `zo` `zO` `zc` `zC` `za` `zA` `zR` `zM` `zr` `zm` `zn` `zN` `zi` `zx` `zX` `zj` `zk` `[z` `]z` | standard fold commands, acting on the tree. Recursive ones stop at `fold_depth` (see `:h salmon-folds`) |
| `K` | hover: label meanings, location, path from the root, upstream status, full source statement |

## Configuration

```lua
require("salmon").setup({
  derive = false,      -- follow derivations (DRV/SRC/FN/RET)
  auto_expand = 4,     -- auto-expand single-child chains this many levels
  fold_depth = 6,      -- depth limit for zO, zA, zR, zn
  width = 60,
  position = "right",  -- or "left"
  max_text = 60,       -- truncate source snippets
  keymaps = { jump = { "<CR>" }, preview = { "p" }, toggle = { "o", "<Tab>", "l" },
              collapse = { "h" }, reroot = { "R" }, derive = { "d" },
              refresh = { "r" }, close = { "q" }, help = { "g?" },
              hover = { "K" }, next = { "]s" }, prev = { "[s" } },
})
```

Highlight groups (`SalmonDEF`, `SalmonCND`, …, `SalmonLocation`) are linked to
standard groups by default and can be overridden.

While the pane is open, the traced symbol's line gets a dim background
(`SalmonOrigin`, linked to `CursorLine`). Every occurrence of the traced
variable is highlighted, including the one you traced from (`SalmonSymbol`,
linked to `LspReferenceText`). The node selected in the pane is
highlighted in its source buffer (`SalmonSelected`, linked to `Visual`).

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
