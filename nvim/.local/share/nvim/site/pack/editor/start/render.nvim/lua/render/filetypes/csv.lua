-- A delimited file -- CSV, TSV and their cousins -- as the table it
-- is: ruled, its columns lined up, the header set apart.
--
-- A table wider than the window scrolls sideways a column at a time
-- (`L`, `H`) rather than wrapping, and columns can be hidden (`x`) and
-- chosen and ordered in a picker (`c`) -- the keys every table of the
-- author's plugins answers, from common.nvim, which this reader needs.
-- Which columns are shown is the reader's, not the file's: it lasts as
-- long as the reader and never touches the file.

local config = require("render.config")

local M = {}

local ns = vim.api.nvim_create_namespace("render_csv")

local function common()
  local ok, grid = pcall(require, "common.grid")
  if not ok then
    return nil
  end
  return grid, require("common.csv")
end

--- Column names out of a header row: an empty one is called by its
--- number and a repeated one numbered, since a name is how a column is
--- hidden and picked, and two of the same name would be one column.
local function names_of(header, ncols)
  local names, seen = {}, {}
  for j = 1, ncols do
    local name = vim.trim(header and header[j] or "")
    if name == "" then
      name = ("column %d"):format(j)
    end
    local base, n = name, 1
    while seen[name] do
      n = n + 1
      name = ("%s (%d)"):format(base, n)
    end
    seen[name] = true
    names[j] = name
  end
  return names
end

--- The columns to show: the ones shown last time that are still there,
--- in the order they were in, then any the file has grown since --
--- so an edit to the file keeps the choice made over it.
local function visible_of(state, names)
  if not state.visible then
    return vim.list_extend({}, names)
  end
  local exists, known = {}, {}
  for _, n in ipairs(names) do
    exists[n] = true
  end
  for _, n in ipairs(state.all or {}) do
    known[n] = true
  end
  local out = {}
  for _, n in ipairs(state.visible) do
    if exists[n] then
      table.insert(out, n)
    end
  end
  for _, n in ipairs(names) do
    if not known[n] then
      table.insert(out, n)
    end
  end
  return out
end

--- A reader of files delimited by `sep`, or by whatever they look
--- delimited by where `sep` is nil.
function M.reader(sep)
  local R = {}

  function R.render(lines, opts)
    local state = opts and opts.state or {}
    local grid, csv = common()
    if not grid then
      return { { { "render: reading a table needs common.nvim", "ErrorMsg" }, row = 1 } }
    end
    local c = config.csv
    local delimiter = sep or c.delimiter or csv.sniff(lines)
    local records = csv.parse(lines, { sep = delimiter })
    if #records == 0 then
      state.widths = nil
      return { { { "(no rows)", "RenderMeta" }, row = 1 } }
    end

    local ncols = 0
    for _, r in ipairs(records) do
      ncols = math.max(ncols, #r.cells)
    end
    local header, data = nil, records
    if c.header then
      header, data = records[1], vim.list_slice(records, 2)
    end
    local names = names_of(header and header.cells, ncols)
    local visible = visible_of(state, names)
    state.all, state.visible = names, visible
    local index = {}
    for j, n in ipairs(names) do
      index[n] = j
    end

    local rows = { visible }
    for k, r in ipairs(data) do
      local row = {}
      for j, n in ipairs(visible) do
        row[j] = grid.escape(r.cells[index[n]] or "")
      end
      rows[k + 1] = row
    end
    local laid = grid.layout(rows, { header = 1, left_align = c.left_align })

    local hidden = #names - #visible
    local summary = ("%d row%s · %d column%s"):format(
      #data,
      #data == 1 and "" or "s",
      #names,
      #names == 1 and "" or "s"
    )
    if hidden > 0 then
      summary = summary .. (" · %d hidden"):format(hidden)
    end
    local first = records[1].row
    local out = { { { summary, "RenderMeta" }, row = first }, { row = first } }

    local function line_of(cells, group, row)
      local chunks = { { grid.SEP, "RenderMeta" }, row = row }
      for j, w in ipairs(laid.widths) do
        table.insert(chunks, { grid.pad(cells[j] or "", w, laid.left[j]), group })
        table.insert(chunks, { grid.SEP, "RenderMeta" })
      end
      return chunks
    end
    state.top = #out + 1
    table.insert(out, line_of(visible, "RenderTableHead", header and header.row or first))
    table.insert(out, { { laid.text[2], "RenderMeta" }, row = header and header.row or first })
    for k, r in ipairs(data) do
      table.insert(out, line_of(rows[k + 1], nil, r.row))
    end
    state.bottom = #out
    state.widths = laid.widths
    return out
  end

  --- The edges with more of the table past them, marked in every window
  --- the reader is in.
  local function mark(ctx)
    local grid = common()
    if not (grid and vim.api.nvim_buf_is_valid(ctx.buf)) then
      return
    end
    for _, win in ipairs(vim.fn.win_findbuf(ctx.buf)) do
      grid.indicators(ctx.buf, win, ctx.state.widths, { ns = ns, hl = "RenderMeta" })
    end
  end

  R.drawn = mark

  function R.keys(ctx)
    local grid = common()
    if not grid then
      return {}
    end
    -- Scrolled some other way -- `zl`, `zL`, a mouse -- the marks are
    -- drawn again too.
    vim.api.nvim_create_autocmd("WinScrolled", {
      group = vim.api.nvim_create_augroup("RenderCsv" .. ctx.buf, { clear = true }),
      callback = function()
        if not vim.api.nvim_buf_is_valid(ctx.buf) then
          return true
        end
        mark(ctx)
      end,
    })
    local k = config.keys
    local s = ctx.state
    return grid.bindings({
      keys = { right = k.column_next, left = k.column_prev, hide = k.column_hide, pick = k.columns },
      widths = function()
        return s.widths
      end,
      row = function()
        return s.top
      end,
      column = function()
        local line = vim.fn.line(".")
        if not s.widths or not s.top or line < s.top or line > s.bottom then
          return nil
        end
        local j = grid.column_at(s.widths, vim.fn.virtcol("."))
        return j and s.visible[j]
      end,
      all = function()
        return s.all or {}
      end,
      visible = function()
        return s.visible or {}
      end,
      set_visible = function(list)
        s.visible = list
        ctx.redraw()
      end,
      after = function()
        mark(ctx)
      end,
      picker = { name = "render" },
    })
  end

  return R
end

local csv = M.reader(nil)
M.render, M.drawn, M.keys = csv.render, csv.drawn, csv.keys

return M
