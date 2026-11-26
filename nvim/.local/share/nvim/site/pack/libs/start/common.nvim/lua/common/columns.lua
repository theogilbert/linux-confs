-- A floating checklist of a table's columns: which are shown, and in
-- what order.
--
-- One line per column, in display order; the buffer holds nothing but
-- the names, so the line under the cursor is the column acted on and
-- every native motion and search works unchanged: j/k, gg/G, counts,
-- / ? n N *, 'hlsearch'. Whether a column is shown is drawn beside it
-- in the sign column, never in the text, so `/` matches names alone
-- and `/^user_` or `/_at$` mean what they say.
--
-- Space/Tab/Enter toggle the column under the cursor; in visual mode,
--     every selected column (shown when any of them was hidden, else
--     hidden).
-- g/  toggle every column the last search matches, by the same rule,
--     so `/^event\.` then `g/` acts on a whole family.
-- J/K move the column under the cursor down/up (takes a count).
-- >/< show/hide every column.
-- u   undo the last change; Ctrl-R redo. Every change reaches the
--     table live (on_change), so an accidental `<` already has --
--     undo is what takes it back. Vim's own undo can't: the buffer is
--     rewritten, not edited.
-- r   reset to the selection the picker was opened with.
-- Esc clears the search highlight; it never closes, so a stray Esc
--     after a search keeps the picker open.
-- q   close.

local hl = require("common.hl")

local M = {}

hl.define({
  CommonColumnShown = { link = "DiagnosticOk" },
  CommonColumnHidden = { link = "Comment" },
})

local default_ns = vim.api.nvim_create_namespace("common_columns")

local HISTORY_MAX = 100

-- One picker at a time.
local p = {}

local function selection()
  local out = {}
  for _, c in ipairs(p.order) do
    if p.shown[c] then
      out[#out + 1] = c
    end
  end
  return out
end

local function title()
  return (" %s  %d of %d shown "):format(p.opts.title, #selection(), #p.order)
end

local function render()
  if not (p.buf and vim.api.nvim_buf_is_valid(p.buf)) then
    return
  end
  vim.bo[p.buf].modifiable = true
  vim.api.nvim_buf_set_lines(p.buf, 0, -1, false, p.order)
  vim.bo[p.buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(p.buf, p.ns, 0, -1)
  for i, c in ipairs(p.order) do
    if p.shown[c] then
      vim.api.nvim_buf_set_extmark(p.buf, p.ns, i - 1, 0, {
        sign_text = p.opts.signs.shown,
        sign_hl_group = p.opts.hl.shown,
      })
    else
      vim.api.nvim_buf_set_extmark(p.buf, p.ns, i - 1, 0, {
        sign_text = p.opts.signs.hidden,
        sign_hl_group = p.opts.hl.hidden,
        end_col = #c,
        hl_group = p.opts.hl.hidden,
      })
    end
  end
  if p.win and vim.api.nvim_win_is_valid(p.win) then
    vim.api.nvim_win_set_config(p.win, { title = title(), title_pos = "center" })
  end
end

local function snapshot()
  return { order = vim.list_extend({}, p.order), shown = vim.deepcopy(p.shown) }
end

--- `fn` applied as one undoable change; one that alters nothing leaves
--- no empty undo step and no redundant on_change.
local function change(fn)
  local before = snapshot()
  fn()
  if vim.deep_equal(before, snapshot()) then
    return
  end
  table.insert(p.history, before)
  if #p.history > HISTORY_MAX then
    table.remove(p.history, 1)
  end
  p.redo = {}
  render()
  if p.on_change then
    p.on_change(selection())
  end
end

local function restore(snap)
  p.order, p.shown = snap.order, snap.shown
  render()
  if p.on_change then
    p.on_change(selection())
  end
end

local function undo()
  local snap = table.remove(p.history)
  if snap then
    table.insert(p.redo, snapshot())
    restore(snap)
  end
end

local function redo()
  local snap = table.remove(p.redo)
  if snap then
    table.insert(p.history, snapshot())
    restore(snap)
  end
end

--- Shows `cols` all when any is hidden, else hides them all: a mixed
--- set ends up uniformly shown, the less destructive choice.
local function toggle(cols)
  if #cols == 0 then
    return
  end
  local all_shown = true
  for _, c in ipairs(cols) do
    if not p.shown[c] then
      all_shown = false
      break
    end
  end
  change(function()
    for _, c in ipairs(cols) do
      p.shown[c] = not all_shown or nil
    end
  end)
end

local function toggle_current()
  toggle({ p.order[vim.fn.line(".")] })
end

local function toggle_visual()
  local a, b = vim.fn.line("v"), vim.fn.line(".")
  if a > b then
    a, b = b, a
  end
  vim.cmd("normal! \27")
  toggle(vim.list_slice(p.order, a, b))
end

local function toggle_matches()
  local pat = vim.fn.getreg("/")
  local who = p.opts.name
  if pat == "" then
    vim.notify(who .. ": no search pattern — search with / first", vim.log.levels.WARN)
    return
  end
  local cols = {}
  for _, c in ipairs(p.order) do
    local ok, idx = pcall(vim.fn.match, c, pat)
    if ok and idx >= 0 then
      cols[#cols + 1] = c
    end
  end
  if #cols == 0 then
    vim.notify(who .. ": no column matches /" .. pat, vim.log.levels.WARN)
    return
  end
  toggle(cols)
end

local function move(delta)
  local from = vim.fn.line(".")
  local to = math.max(1, math.min(#p.order, from + delta * vim.v.count1))
  if to == from then
    return
  end
  change(function()
    table.insert(p.order, to, table.remove(p.order, from))
  end)
  vim.api.nvim_win_set_cursor(p.win, { to, 0 })
end

local function set_all(on)
  change(function()
    for _, c in ipairs(p.order) do
      p.shown[c] = on or nil
    end
  end)
end

local function reset()
  change(function()
    p.order = vim.list_extend({}, p.init.order)
    p.shown = vim.deepcopy(p.init.shown)
  end)
end

local function close()
  if p.win and vim.api.nvim_win_is_valid(p.win) then
    vim.api.nvim_win_close(p.win, true)
  end
end

--- The order the picker opens with: the visible columns in display
--- order, each hidden one slotted in after the column it follows in
--- `all` -- so an untouched order reads as the table's own, and a
--- hidden column sits beside its neighbour.
function M.initial_order(all, visible)
  local order, placed = vim.list_extend({}, visible), {}
  for _, c in ipairs(visible) do
    placed[c] = true
  end
  for i, c in ipairs(all) do
    if not placed[c] then
      local at = 1
      if i > 1 then
        for k, o in ipairs(order) do
          if o == all[i - 1] then
            at = k + 1
            break
          end
        end
      end
      table.insert(order, at, c)
      placed[c] = true
    end
  end
  return order
end

--- `visible` less `name`: what `x` on a column leaves.
function M.without(visible, name)
  local out = {}
  for _, c in ipairs(visible) do
    if c ~= name then
      out[#out + 1] = c
    end
  end
  return out
end

--- Opens the picker over `all` (every column, in the table's order),
--- `visible` (those shown, in display order) ticked, and calls
--- `on_change(selected)` on every change, live. A second call while it
--- is open goes to it instead.
---
--- `opts.title`  -- "Columns"
--- `opts.name`   -- the plugin's name, for its warnings ("common")
--- `opts.hl`     -- { shown, hidden }: CommonColumnShown/Hidden
--- `opts.signs`  -- { shown = "󰄲", hidden = "󰄱" }
--- `opts.ns`     -- the namespace its signs go in
--- `opts.win_ns` -- a highlight namespace for its window, for a plugin
---                  whose groups live in one
--- Returns the window.
function M.open(all, visible, on_change, opts)
  if p.win and vim.api.nvim_win_is_valid(p.win) then
    vim.api.nvim_set_current_win(p.win)
    return p.win
  end
  opts = opts or {}
  opts = {
    title = opts.title or "Columns",
    name = opts.name or "common",
    hl = vim.tbl_extend(
      "force",
      { shown = "CommonColumnShown", hidden = "CommonColumnHidden" },
      opts.hl or {}
    ),
    signs = vim.tbl_extend("force", { shown = "󰄲", hidden = "󰄱" }, opts.signs or {}),
    ns = opts.ns,
    win_ns = opts.win_ns,
  }

  local shown = {}
  for _, c in ipairs(visible) do
    shown[c] = true
  end
  local order = M.initial_order(all, visible)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"

  p = {
    buf = buf,
    order = order,
    shown = shown,
    init = { order = vim.list_extend({}, order), shown = vim.deepcopy(shown) },
    on_change = on_change,
    history = {},
    redo = {},
    opts = opts,
    ns = opts.ns or default_ns,
  }
  render()

  local name_w = 0
  for _, c in ipairs(all) do
    name_w = math.max(name_w, vim.api.nvim_strwidth(c))
  end
  local digits = #tostring(#all)
  local title_w = #(" %s  %s of %s shown "):format(opts.title, ("9"):rep(digits), ("9"):rep(digits))
  -- The sign column's two cells, the gap after them, the name, and a
  -- cell of padding.
  local width = math.min(math.max(name_w + 4, title_w), vim.o.columns - 4)
  local height = math.max(1, math.min(#all, vim.o.lines - 8))

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height - 2) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = title(),
    title_pos = "center",
  })
  p.win = win
  if opts.win_ns then
    vim.api.nvim_win_set_hl_ns(win, opts.win_ns)
  end
  vim.wo[win].signcolumn = "yes:1"
  -- A space after the sign, so a name never sits flush against it.
  vim.wo[win].statuscolumn = "%s "
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false

  local function map(mode, key, fn, desc)
    vim.keymap.set(mode, key, fn, { buffer = buf, silent = true, nowait = true, desc = desc })
  end
  map("n", "q", close, "Close")
  map("n", "<Esc>", function()
    vim.cmd("nohlsearch")
  end, "Clear the search highlight")
  map("n", "<Space>", toggle_current, "Show/hide the column")
  map("n", "<Tab>", toggle_current, "")
  map("n", "<CR>", toggle_current, "")
  map("x", "<Space>", toggle_visual, "Show/hide the selected columns")
  map("x", "<Tab>", toggle_visual, "")
  map("x", "<CR>", toggle_visual, "")
  map("n", "g/", toggle_matches, "Show/hide every column the last search matches")
  map("n", "J", function()
    move(1)
  end, "Move the column down")
  map("n", "K", function()
    move(-1)
  end, "Move the column up")
  map("n", ">", function()
    set_all(true)
  end, "Show every column")
  map("n", "<", function()
    set_all(false)
  end, "Hide every column")
  map("n", "r", reset, "Reset to the initial selection")
  map("n", "u", undo, "Undo the last change")
  map("n", "<C-r>", redo, "Redo")
  map("n", "g?", function()
    local rows = require("common.help").of_buffer(buf, { "n", "x" })
    table.insert(rows, { key = "/ ? n N *", desc = "Search columns (native)" })
    require("common.help").float(rows, { at = "cursor", close = "g?" })
  end, "Show keymaps")

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      p = {}
    end,
  })
  return win
end

return M
