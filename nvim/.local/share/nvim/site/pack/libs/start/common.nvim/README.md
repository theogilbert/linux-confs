# common.nvim

The UI pieces the author's plugins (grannos, nemeton, render.nvim,
uatis, salmon) share, so that each is written once and behaves the same
everywhere. A library: no `plugin/` file, no setup, nothing runs until
a module is required.

Needs Neovim 0.10 or newer.

## Modules

### `common.help` -- the `g?` float

```lua
local help = require("common.help")

-- Bind keys on a buffer and a `g?` that lists them, in the order bound.
help.bind(buf, {
  { "<CR>", open, "open the row" },
  { cfg.keys.refresh, refresh, "re-read" },   -- false/"" = unbound, skipped
  { { "[s", "]s" }, step, "step back / forward" },
  { "x", hide, "hide the column", group = "Columns" },
}, { help = "g?", title = " myplugin ", prefix = "myplugin: ", extra = legend_rows })

-- Or open the float on rows of your own.
help.float({
  { head = "in this list" },
  { "q", "close" },
  { text = "a line of prose" },
  { chunks = { { "DEF", "MyDef" }, { "  a definition" } } },
  "",
}, { title = " keys ", at = "cursor", close = "g?", hl = { key = "MyKey" } })

help.of_buffer(buf, { "n", "x" })  -- rows out of a buffer's described maps
```

Highlights: `CommonHelpKey`, `CommonHelpDesc`, `CommonHelpHead`,
`CommonHelpText` (each overridable per call through `opts.hl`).

### `common.grid` -- box-ruled tables, scrolled a column at a time

```lua
local grid = require("common.grid")

local t = grid.layout({ { "id", "name" }, { "1", "alice" } }, { left_align = 40 })
-- t.text   : lines to set in a buffer   t.widths : each column's width
-- t.left   : left-aligned columns       t.header : header rows (rule under them)

grid.column_at(t.widths, vim.fn.virtcol("."))  -- column under the cursor
grid.spans(cells, t.widths)                    -- byte ranges of a line's cells
grid.scroll(win, t.widths, 1)                  -- L: next column whole into view
grid.indicators(buf, win, t.widths)            -- ◂ ▸ where more is off-screen
grid.escape(s)                                 -- "\n" -> "\\n", for one-line cells

-- The keys every table answers (L/H, x hide, c picker), for help.bind:
help.bind(buf, grid.bindings({
  widths = function() return state.widths end,
  column = function() return name_under_cursor() end,
  all = ..., visible = ..., set_visible = function(list) ... redraw end,
  after = function() grid.indicators(buf, 0, state.widths) end,
}))
```

Cells are strings: format values before laying them out, and keep the
strings for `spans`. Highlights: `CommonGridBorder`, `CommonGridHeader`,
`CommonGridTruncated`.

### `common.columns` -- the column picker

```lua
local columns = require("common.columns")

columns.open(all, visible, function(selected) ... end, {
  title = "Columns", name = "myplugin",
  hl = { shown = "MyShown", hidden = "MyHidden" },
})
columns.without(visible, name)   -- what `x` on a column leaves
```

A float with one column name per line: `<Space>`/`<Tab>`/`<CR>` toggle
(the visual selection too), `g/` toggles every column the last search
matches, `J`/`K` reorder, `>`/`<` show/hide all, `u`/`<C-r>` undo/redo,
`r` reset, `q` close, `g?` help. Every change reaches `on_change` live.
Highlights: `CommonColumnShown`, `CommonColumnHidden`.

### `common.csv` -- delimited text into records

```lua
local csv = require("common.csv")
local sep = csv.sniff(lines)              -- ",", "\t", ";" or "|"
for _, r in ipairs(csv.parse(lines, { sep = sep })) do
  -- r.cells : the fields   r.row : the line the record starts on
end
```

RFC 4180 quoting, quoted fields over several lines, `\r\n` endings.

### `common.pane` -- a side split

```lua
local pane = require("common.pane")
local back = pane.came_from()        -- call after closing, to return
local win = pane.open({ buf = buf, side = "right", size = 60, edge = "editor" })
pane.splittable(win)                 -- a non-float window to split from
```

No number/sign/fold column, no wrap, `winfixwidth`/`winfixheight`, at
most half the editor; `opts.wo` overrides any of it.

### `common.keys` -- keys lent to a buffer you do not own

```lua
local saved = require("common.keys").apply(buf, "n", { { lhs = "]c", rhs = next } })
require("common.keys").restore(buf, "n", saved)  -- the buffer's own maps back
```

### `common.hl` -- colours that survive `:colorscheme`

```lua
local hl = require("common.hl")
hl.define({ MyKey = { link = "Special" } })   -- default links, set again after :colorscheme
hl.watch("myplugin", function()               -- now and after every :colorscheme
  local bg = hl.get("Normal", "bg")
  vim.api.nvim_set_hl(0, "MyBand", { bg = hl.mix(bg, 0x98c379, 0.1), default = true })
end)
hl.lum(0x808080)                              -- how light, 0-255
```

### `common.spinner` -- a glyph that turns while waiting

```lua
local s = require("common.spinner").new(function() redraw_title() end, { interval = 80 })
s:start()            -- counted: one per wait
s:glyph()            -- the frame it is on, for a title or virtual text
s:stop()             -- the last stop stops the timer
```

### `common.hover` -- a float under the cursor, gone on the next move

```lua
local hover = require("common.hover").new()   -- one float at a time
function M.show()
  if hover:enter(thing) then return end        -- the same key again goes into it
  hover:open(lines, { key = thing, title = " row ", marks = { { 0, 0, 4, "Title" } } })
end
hover:close()
require("common.hover").enter(win, autocmd, close)  -- the same, for a float of your own
```

Sized to its text (wrapped, at most half the editor tall); inside it, `q`
and `<Esc>` close it and go back.

### `common.prompt` -- one line asked for, with a menu as it is typed

```lua
local prompt = require("common.prompt")
prompt.open({
  title = "base revision",
  items = { "main", { word = "a1b2c3d", menu = "fix the pane", kind = "commit" } },
  -- or items = function(line) return items, col end, with live = true to re-ask on every key
  on_cancel = function() ... end,     -- dismissed: <Esc>, <C-c>, q, or the cursor leaving
}, function(text) ... end)            -- answered: <CR>, trimmed, after the float has gone
prompt.refresh()                      -- the menu again, for candidates that just arrived
prompt.over(function() open_help() end) -- a window over it that is not the prompt left
```

Its own window rather than `vim.ui.input`, whose replacements are free to
drop `completion`. Completion engines are told to keep out of it.

### `common.pick` -- one of a list

```lua
local pick = require("common.pick")
pick.select(files, {
  prompt = "Changed files",
  format = function(f) return { { f.dir, "Directory" }, { f.name } } end,  -- or a string
}, function(file, index) ... end)
pick.confirm("Delete the query?", function() ... end, { yes = "Delete" })  -- No first
```

fzf-lua where it is installed, coloured; `vim.ui.select` otherwise.

### `common.bar` -- key hints for a winbar

```lua
vim.wo[win].winbar = require("common.bar").hints(
  { { "a", "approve" }, { cfg.keys.comments, "comments" } },
  { help = "g?", key = "MyKey", desc = "MyHint", width = vim.api.nvim_win_get_width(win) })
require("common.bar").escape("100%")   -- safe in a statusline
```

### `common.store` -- small JSON files kept between sessions

```lua
local store = require("common.store")
local path = store.path("myplugin", "seen.json", "state")  -- stdpath("state")/myplugin/seen.json
local seen = store.read(path)          -- {} when missing or unreadable
seen[key] = true
store.write(path, seen)                -- mkdir -p, 0600, written aside then renamed
```

### `common.notify` -- messages that say whose they are

```lua
local log = require("common.notify").new("myplugin")
log.warn("nothing here")      -- "myplugin: nothing here", title = "myplugin"
log.error(err); log.info(msg); log(msg, vim.log.levels.WARN)
```

### `common.yank` -- copy, over ssh too

```lua
require("common.yank").copy(url, { notify = url })   -- " register, + if there is a clipboard
require("common.yank").copy(lines, { osc52 = true })  -- and the terminal's, by OSC 52
vim.g.common_yank_osc52 = "auto"  -- default: OSC 52 only where Neovim has no clipboard
```
