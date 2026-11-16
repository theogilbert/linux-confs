-- A float of choices ticked on and off, applied as they are ticked.
--
-- One line per choice and nothing else on it: whether it is ticked is
-- drawn beside it, in the sign column, so the line under the cursor is
-- the choice acted on and `/` finds a word rather than a box. A choice
-- is either a box of its own or one of a group -- `group` -- of which
-- exactly one is ticked, the way "newest first" and "oldest first"
-- are; a blank line stands between one group and the next, and before
-- a box that says `gap`, where boxes are answers to two questions.
--
-- Applied live rather than on a key that says done: the window behind
-- it redraws on every tick, which is what says whether the tick was
-- the one wanted, and closing is then only closing.

local config = require("nemeton.config")
local marks = require("nemeton.marks")
local win = require("nemeton.win")

local M = {}

M.win = nil
M.buf = nil
-- The one open: its choices, line by line (nil on a blank one), what
-- is ticked, what was ticked when it opened, and whom to tell.
local p = {}

local function valid()
  return M.win ~= nil and vim.api.nvim_win_is_valid(M.win)
end

local function draw()
  if not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) then
    return
  end
  local g = config.checklist
  local lines = {}
  for i = 1, p.count do
    local c = p.rows[i]
    lines[i] = c and c.label or ""
  end
  vim.bo[M.buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.bo[M.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(M.buf, marks.ui_ns, 0, -1)
  for i = 1, p.count do
    local c = p.rows[i]
    if c then
      local on = p.on[c.key] and true or false
      local glyph = c.group and (on and g.chosen or g.other) or (on and g.on or g.off)
      vim.api.nvim_buf_set_extmark(M.buf, marks.ui_ns, i - 1, 0, {
        sign_text = glyph,
        sign_hl_group = on and "NemetonKey" or "NemetonMeta",
        end_col = not on and #c.label or nil,
        hl_group = not on and "NemetonMeta" or nil,
      })
    end
  end
end

local function changed()
  draw()
  if p.on_change then
    p.on_change(vim.deepcopy(p.on))
  end
end

--- Ticks `chosen` (a list of choices): one of a group is ticked and
--- the rest of it let go; boxes are all ticked when any of them was
--- not, and all let go otherwise -- so a mixed set comes out ticked,
--- which is the change easier to take back.
local function tick(chosen)
  local boxes, all = {}, true
  for _, c in ipairs(chosen) do
    if c.group then
      for _, other in ipairs(p.items) do
        if other.group == c.group then
          p.on[other.key] = nil
        end
      end
      p.on[c.key] = true
    else
      table.insert(boxes, c)
      all = all and p.on[c.key] or false
    end
  end
  for _, c in ipairs(boxes) do
    p.on[c.key] = (not all) or nil
  end
  changed()
end

local function at_cursor()
  return { p.rows[vim.api.nvim_win_get_cursor(M.win)[1]] }
end

local function in_selection()
  local a, b = vim.fn.line("v"), vim.fn.line(".")
  if a > b then
    a, b = b, a
  end
  vim.cmd("normal! \27")
  local out = {}
  for i = a, b do
    -- Only the boxes: a run of lines across a group would tick each
    -- of it in turn, and leave whichever came last.
    if p.rows[i] and not p.rows[i].group then
      table.insert(out, p.rows[i])
    end
  end
  return out
end

local function every_box(on)
  for _, c in ipairs(p.items) do
    if not c.group then
      p.on[c.key] = on or nil
    end
  end
  changed()
end

function M.close()
  if valid() then
    vim.api.nvim_win_close(M.win, true)
  end
  M.win, M.buf, p = nil, nil, {}
end

--- Opens one over the editor.
---
--- `opts.title`     -- what it is a choice of
--- `opts.items`     -- `{ { key =, label =, group =, gap = }, ... }`, in
---                     order; `group` for one of several of which one is
---                     ticked, `gap` for a blank line above a box
--- `opts.on`        -- `{ [key] = true }`: what is ticked to begin with
--- `opts.on_change` -- `fn(on)`, on every change, with what is ticked
---                     now in the same shape
function M.open(opts)
  M.close()
  local back = win.came_from()
  p = {
    items = opts.items,
    on = vim.deepcopy(opts.on or {}),
    was = vim.deepcopy(opts.on or {}),
    on_change = opts.on_change,
    rows = {},
    count = 0,
  }
  local widest = vim.fn.strdisplaywidth(opts.title) + 2
  local last = false
  for _, c in ipairs(opts.items) do
    if p.count > 0 and (c.group ~= last or c.gap) then
      p.count = p.count + 1
    end
    p.count = p.count + 1
    p.rows[p.count] = c
    last = c.group
    widest = math.max(widest, vim.fn.strdisplaywidth(c.label) + 4)
  end

  M.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[M.buf].bufhidden = "wipe"
  local width = math.min(widest, vim.o.columns - 4)
  local height = math.max(1, math.min(p.count, vim.o.lines - 8))
  M.win = vim.api.nvim_open_win(M.buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height - 2) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
    style = "minimal",
    border = "rounded",
    title = " " .. opts.title .. " ",
    title_pos = "center",
  })
  vim.wo[M.win].signcolumn = "yes:1"
  -- The mark, then a space, so a word never sits against its box.
  vim.wo[M.win].statuscolumn = "%s "
  vim.wo[M.win].cursorline = true
  vim.wo[M.win].wrap = false
  draw()
  -- On the first choice ticked, which is where a change is likeliest
  -- to start from.
  for i = 1, p.count do
    if p.rows[i] and p.on[p.rows[i].key] then
      vim.api.nvim_win_set_cursor(M.win, { i, 0 })
      break
    end
  end

  local k = config.keys.checklist
  local function close()
    M.close()
    back()
  end
  local bindings = {
    {
      k.toggle,
      function()
        tick(at_cursor())
      end,
      "tick the line under the cursor, or untick it",
    },
    {
      k.all,
      function()
        every_box(true)
      end,
      "tick every box",
    },
    {
      k.none,
      function()
        every_box(false)
      end,
      "untick every box",
    },
    {
      k.reset,
      function()
        p.on = vim.deepcopy(p.was)
        changed()
      end,
      "back to what was ticked when this opened",
    },
    { k.quit, close, "close" },
  }
  require("nemeton.detail").bind(M.buf, bindings, k.help, " " .. opts.title .. " ")
  for _, key in ipairs({ k.toggle, k.toggle_alt }) do
    if key and key ~= "" then
      vim.keymap.set("x", key, function()
        tick(in_selection())
      end, { buffer = M.buf, nowait = true, desc = "nemeton: tick every line selected" })
    end
  end
  if k.toggle_alt and k.toggle_alt ~= "" then
    vim.keymap.set("n", k.toggle_alt, function()
      tick(at_cursor())
    end, { buffer = M.buf, nowait = true })
  end
  vim.keymap.set("n", "<Esc>", close, { buffer = M.buf, nowait = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(M.win),
    once = true,
    callback = function()
      M.win, M.buf, p = nil, nil, {}
    end,
  })
  return M.win
end

return M
