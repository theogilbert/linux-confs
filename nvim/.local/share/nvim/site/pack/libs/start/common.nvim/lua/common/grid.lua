-- A table drawn with box rules, and moving about one a column at a
-- time.
--
--   │ id │   name   │ created_at │
--   ├────┼──────────┼────────────┤
--   │ 1  │  alice   │ 2024-01-01 │
--
-- Knows nothing about what a cell holds: it lays out strings. A caller
-- with values to show (a NULL, a number with separators) turns them
-- into the strings it wants seen first, and keeps them -- `spans`
-- needs the same strings to say where a cell is on its line.
--
-- Wider than its window, a table is scrolled sideways rather than
-- wrapped, and `scroll` does it by whole columns: `H`/`L` in every
-- table here. `indicators` marks the edges that have more past them.

local hl = require("common.hl")

local M = {}

M.SEP = "│"
local SEP_BYTES = #M.SEP

hl.define({
  CommonGridBorder = { link = "FloatBorder" },
  CommonGridHeader = { link = "Title" },
  CommonGridTruncated = { link = "NonText" },
})

M.ns = vim.api.nvim_create_namespace("common_grid")

-- Rows between yields when laid out inside a coroutine -- an export of
-- a million rows, say. Outside one, `isyieldable` is false and this is
-- never reached.
local CHUNK = 1000

local function maybe_yield(i)
  if i % CHUNK == 0 and coroutine.isyieldable() then
    coroutine.yield()
  end
end

local ESCAPES = { ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

--- `s` with its control characters written as escapes, so a cell
--- holding a newline is still one line of one row. Done before the
--- width is measured, so the measure and the drawing agree.
function M.escape(s)
  if not s:find("%c") then
    return s
  end
  return (s:gsub("%c", function(c)
    return ESCAPES[c] or ("\\x%02X"):format(c:byte())
  end))
end

local function width_of(s)
  return vim.api.nvim_strwidth(s)
end

local function center(text, width)
  local space = (width - width_of(text)) / 2
  return (" "):rep(math.floor(space)) .. text .. (" "):rep(math.ceil(space))
end

local function left(text, width)
  return " " .. text .. (" "):rep(width - width_of(text) - 1)
end

--- `text` padded to a cell `width` wide, as `layout` draws it: left
--- with a cell of padding, or centred. For a caller drawing a table in
--- coloured pieces that has to match the layout's text.
function M.pad(text, width, is_left)
  return (is_left and left or center)(text, width)
end

--- Where `text` starts within a cell `width` wide: one cell of padding
--- when left-aligned, half the slack when centred.
function M.offset(text, width, is_left)
  if is_left then
    return 1
  end
  return math.floor((width - width_of(text)) / 2)
end

--- The ├──┼──┤ rule under the header.
function M.rule(widths)
  local parts = {}
  for i, w in ipairs(widths) do
    parts[i] = ("─"):rep(w)
  end
  return "├" .. table.concat(parts, "┼") .. "┤"
end

--- Lays out `rows` -- lists of strings, the header first -- and returns
--- `{ text, widths, left, header }`: the lines to set in a buffer, each
--- column's width (its padding counted), which columns are
--- left-aligned, and how many rows the header is.
---
--- Every row is as many columns as the widest: a row short of a
--- trailing cell draws it empty rather than stopping short of the
--- header above it.
---
--- `opts.header`     -- rows of header, 1 by default; the rule goes
---                      under them (0 for no header and no rule)
--- `opts.left_align` -- a column wider than this many cells is
---                      left-aligned, so a short value does not float
---                      in the middle of a wide one; nil centres all
--- `opts.align`      -- { [col] = "left" | "center" }, which wins
function M.layout(rows, opts)
  opts = opts or {}
  local header = opts.header or 1
  local ncols = 0
  for _, row in ipairs(rows) do
    ncols = math.max(ncols, #row)
  end
  local widths = {}
  for i, row in ipairs(rows) do
    for j = 1, ncols do
      widths[j] = math.max(widths[j] or 2, width_of(row[j] or "") + 2)
    end
    maybe_yield(i)
  end

  local is_left = {}
  for j = 1, ncols do
    local a = opts.align and opts.align[j]
    if a then
      is_left[j] = a == "left" or nil
    elseif opts.left_align then
      is_left[j] = widths[j] > opts.left_align or nil
    end
  end

  local text = {}
  for i, row in ipairs(rows) do
    local cells = {}
    for j = 1, ncols do
      cells[j] = M.pad(row[j] or "", widths[j], is_left[j])
    end
    text[i] = M.SEP .. table.concat(cells, M.SEP) .. M.SEP
    maybe_yield(i)
  end
  if header > 0 and header <= #text then
    table.insert(text, header + 1, M.rule(widths))
  end
  return { text = text, widths = widths, left = is_left, header = header }
end

--- The display column of each column's edges: 0, then the separator
--- after each column. The last is the table's right edge.
function M.boundaries(widths)
  local out, pos = { 0 }, 0
  for _, w in ipairs(widths) do
    pos = pos + w + 1
    out[#out + 1] = pos
  end
  return out
end

--- The column at 1-based display column `vcol`, or nil on a separator
--- or past the edge.
function M.column_at(widths, vcol)
  local pos = 2
  for i, w in ipairs(widths) do
    if vcol >= pos and vcol < pos + w then
      return i
    end
    pos = pos + w + 1
  end
  return nil
end

--- The byte `{ start, finish }` of each cell of a drawn line, `cells`
--- being the strings it was laid out from, or nil to count every cell
--- as its width in single-byte characters (blanks). Right for
--- multi-byte text, which is what an extmark needs.
function M.spans(cells, widths)
  local out, at = {}, SEP_BYTES
  for i, w in ipairs(widths) do
    local bytes = w
    if cells then
      local s = cells[i] or ""
      bytes = w - width_of(s) + #s
    end
    out[i] = { at, at + bytes }
    at = at + bytes + SEP_BYTES
  end
  return out
end

local function leftcol_of(win)
  return vim.api.nvim_win_call(win, function()
    return vim.fn.winsaveview().leftcol
  end)
end

--- Scrolls `win` one column right (`dir` > 0) or left, the table being
--- one of `widths` -- so that a column comes whole into view at the
--- right edge, or starts at the left one. The cursor goes with the
--- page, keeping its place in it.
---
--- `opts.row` is a row to carry the cursor to when the line it is on
--- does not reach the new column -- a label above the table, a blank
--- -- where Neovim would otherwise scroll back to wherever it landed.
--- True when it moved.
function M.scroll(win, widths, dir, opts)
  opts = opts or {}
  win = (win == nil or win == 0) and vim.api.nvim_get_current_win() or win
  local edges = M.boundaries(widths)
  local leftcol = leftcol_of(win)
  local textoff = (vim.fn.getwininfo(win)[1] or {}).textoff or 0
  local room = vim.api.nvim_win_get_width(win) - textoff

  local target = leftcol
  if dir > 0 then
    for i, b in ipairs(edges) do
      if i == #edges then
        break
      end
      if b > leftcol then
        local t = math.max(0, edges[i + 1] - room + 1)
        if t > leftcol then
          target = t
          break
        end
      end
    end
  else
    target = 0
    for _, b in ipairs(edges) do
      if b < leftcol then
        target = b
      end
    end
  end
  if target == leftcol then
    return false
  end

  vim.api.nvim_win_call(win, function()
    local vcol = math.max(1, target + vim.fn.virtcol(".") - leftcol)
    local row = vim.fn.line(".")
    if opts.row and vim.fn.virtcol({ row, "$" }) <= vcol then
      row = opts.row
    end
    local byte = math.max(0, vim.fn.virtcol2col(0, row, vcol) - 1)
    vim.api.nvim_win_set_cursor(0, { row, byte })
    vim.fn.winrestview({ leftcol = target })
  end)
  return true
end

--- Marks the edges of `win` that have more of the table past them: ◂
--- at the left, ▸ at the right, on every line of `buf`. Call it again
--- after each scroll and redraw; it clears its own first.
---
--- `opts.ns`     -- the namespace, `grid.ns` by default
--- `opts.hl`     -- `CommonGridTruncated` by default
--- `opts.glyphs` -- { left = "◂", right = "▸" }
function M.indicators(buf, win, widths, opts)
  opts = opts or {}
  local ns = opts.ns or M.ns
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if not (widths and vim.api.nvim_win_is_valid(win)) then
    return
  end
  local edges = M.boundaries(widths)
  local leftcol = leftcol_of(win)
  local textoff = (vim.fn.getwininfo(win)[1] or {}).textoff or 0
  local room = vim.api.nvim_win_get_width(win) - textoff
  local right = edges[#edges] >= leftcol + room
  local leftward = leftcol > 0
  if not (right or leftward) then
    return
  end
  local group = opts.hl or "CommonGridTruncated"
  local glyphs = vim.tbl_extend("force", { left = "◂", right = "▸" }, opts.glyphs or {})
  for row = 0, vim.api.nvim_buf_line_count(buf) - 1 do
    if right then
      vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
        virt_text = { { glyphs.right, group } },
        virt_text_pos = "right_align",
      })
    end
    if leftward then
      vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
        virt_text = { { glyphs.left, group } },
        virt_text_win_col = 0,
      })
    end
  end
end

--- The keys every table here answers, as `common.help.bind` takes
--- them: `L`/`H` a column right/left, `x` hide the column under the
--- cursor, `c` the column picker. Each is a key of `t.keys`, any of
--- them `false`. `t` is the table's state, read when a key is pressed
--- since a redraw changes it:
---
--- `t.win()`      -- the window, the current one if not given
--- `t.widths()`   -- the drawn columns' widths
--- `t.row()`      -- the row `scroll` carries the cursor to, if any
--- `t.column()`   -- the name of the column under the cursor, or nil
--- `t.all()`, `t.visible()` -- every column, and those shown in order
--- `t.set_visible(list)`    -- shows `list`, in that order, and redraws
--- `t.after()`    -- called after a scroll (to redraw `indicators`)
--- `t.picker`     -- opts for `common.columns.open`
--- `t.group`      -- the help heading the keys go under
function M.bindings(t)
  local keys =
    vim.tbl_extend("force", { right = "L", left = "H", hide = "x", pick = "c" }, t.keys or {})
  local function win()
    return t.win and t.win() or vim.api.nvim_get_current_win()
  end
  local function scroll(dir)
    return function()
      local widths = t.widths()
      if widths and M.scroll(win(), widths, dir, { row = t.row and t.row() }) and t.after then
        t.after()
      end
    end
  end
  local out = {
    { keys.right, scroll(1), "next column into view", group = t.group },
    { keys.left, scroll(-1), "previous column into view", group = t.group },
  }
  if t.set_visible then
    local columns = require("common.columns")
    table.insert(out, {
      keys.hide,
      function()
        local name = t.column()
        if name then
          t.set_visible(columns.without(t.visible(), name))
        end
      end,
      "hide the column under the cursor",
      group = t.group,
    })
    table.insert(out, {
      keys.pick,
      function()
        columns.open(t.all(), t.visible(), t.set_visible, t.picker)
      end,
      "choose and order the columns shown",
      group = t.group,
    })
  end
  return out
end

return M
