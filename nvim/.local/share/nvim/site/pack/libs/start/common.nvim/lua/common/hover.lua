-- A float under the cursor that is gone on the next move: what `K` shows
-- over an LSP symbol, for whatever a plugin has to say about the thing
-- under the cursor.
--
-- Not focusable, and closed by moving rather than by a key: there is
-- nothing to remember about it, and a float that has to be closed by
-- hand is one left open over the code. The same key pressed again goes
-- into it instead (`enter`) -- a hover that goes on the next move
-- cannot be scrolled, searched or yanked from, and pressing again is the
-- reader asking to do one of those.
--
--   local hover = require("common.hover").new()
--   function M.show()
--     if hover:enter() then return end          -- the second press
--     hover:open(lines, { title = " row ", marks = ... })
--   end

local pane = require("common.pane")

local M = {}

local ns = vim.api.nvim_create_namespace("common_hover")

--- Takes the cursor into `float`, a hover until now. `dismiss` is the
--- autocmd that would close it on the cursor moving -- which going in
--- fires -- and goes first. Inside, `q` and `<Esc>` close it and go back
--- to the window it was over; leaving it any other way closes it behind
--- you. `close()` closes it.
function M.enter(float, dismiss, close)
  if dismiss then
    pcall(vim.api.nvim_del_autocmd, dismiss)
  end
  local back = pane.came_from()
  local buf = vim.api.nvim_win_get_buf(float)
  local function done()
    close()
    back()
  end
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, done, { buffer = buf, nowait = true, silent = true, desc = "close" })
  end
  -- Scheduled: the layout cannot change inside `WinLeave`. And only
  -- this float, which may have been replaced by the next one by then.
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    once = true,
    callback = vim.schedule_wrap(function()
      if vim.api.nvim_win_is_valid(float) and vim.api.nvim_get_current_win() ~= float then
        close()
      end
    end),
  })
  vim.api.nvim_win_set_config(float, { focusable = true })
  vim.api.nvim_set_current_win(float)
end

local Hover = {}
Hover.__index = Hover

--- A hover: one float at a time, the next replacing it.
function M.new()
  return setmetatable({ win = nil, buf = nil, key = nil, dismiss = nil }, Hover)
end

--- Whether it is up.
function Hover:is_open()
  return self.win ~= nil and vim.api.nvim_win_is_valid(self.win)
end

function Hover:close()
  if self.dismiss then
    pcall(vim.api.nvim_del_autocmd, self.dismiss)
  end
  if self:is_open() then
    pcall(vim.api.nvim_win_close, self.win, true)
  end
  self.win, self.buf, self.key, self.dismiss = nil, nil, nil, nil
end

--- The second press: into the float if it is up and the cursor is not
--- already in it. `key`, where given, has to be what it was opened for
--- -- a hover over something else is a new one, not this one again.
--- True when it went in.
function Hover:enter(key)
  if not self:is_open() or vim.api.nvim_get_current_win() == self.win then
    return false
  end
  if key ~= nil and key ~= self.key then
    return false
  end
  local win = self.win
  M.enter(win, self.dismiss, function()
    if self.win == win then
      self:close()
    elseif vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end)
  self.dismiss = nil
  return true
end

--- How many screen lines `lines` take in a window `width` wide.
local function wrapped_height(lines, width, wrap)
  if not wrap then
    return #lines
  end
  local h = 0
  for _, l in ipairs(lines) do
    h = h + math.max(1, math.ceil(vim.fn.strdisplaywidth(l) / width))
  end
  return h
end

--- Opens `lines` under the cursor, replacing any float it had up, and
--- returns the window and its buffer.
---
--- `opts.key`        -- what it is about, for `enter(key)`
--- `opts.marks`      -- `{ { row, col, end_col, hl } }`, 0-based; with
---                      no `col` the whole line is coloured
--- `opts.paint`      -- `f(buf)`, colours of the caller's own, before
---                      the buffer is made read-only
--- `opts.title`      -- the border's title
--- `opts.above`      -- over the cursor's line rather than under it
--- `opts.width`      -- fixed; otherwise the widest line, between
---                      `opts.min_width` (1) and `opts.max_width` (the
---                      editor less 6)
--- `opts.max_height` -- half the editor by default: `enter` is the way
---                      to read the rest
--- `opts.wrap`       -- true by default
--- `opts.winhighlight`, `opts.zindex`, `opts.border` ("rounded"),
--- `opts.filetype`
--- `opts.events`     -- what closes it, on the buffer it is over
--- `opts.buf`        -- that buffer, the current one by default
function Hover:open(lines, opts)
  opts = opts or {}
  self:close()
  if #lines == 0 then
    return nil
  end
  local from = opts.buf or vim.api.nvim_get_current_buf()
  local wrap = opts.wrap ~= false

  local widest = 1
  for _, l in ipairs(lines) do
    widest = math.max(widest, vim.fn.strdisplaywidth(l))
  end
  local most = math.max(opts.max_width or (vim.o.columns - 6), 1)
  local width = opts.width or math.min(math.max(widest, opts.min_width or 1), most)
  local cap = opts.max_height or math.max(1, math.floor(vim.o.lines / 2))
  local height = math.max(1, math.min(wrapped_height(lines, width, wrap), cap))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  for _, m in ipairs(opts.marks or {}) do
    local row, col, end_col, group = m[1] or m.row, m[2] or m.col, m[3] or m.end_col, m[4] or m.hl
    if col then
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, col, {
        end_col = end_col or #(lines[row + 1] or ""),
        hl_group = group,
      })
    else
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, 0, { line_hl_group = group })
    end
  end
  if opts.paint then
    opts.paint(buf)
  end
  if opts.filetype then
    vim.bo[buf].filetype = opts.filetype
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  local config = {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = opts.border or "rounded",
    focusable = false,
    zindex = opts.zindex,
  }
  if opts.above then
    config.anchor, config.row = "SW", 0
  end
  if opts.title then
    config.title, config.title_pos = opts.title, "center"
  end
  local win = vim.api.nvim_open_win(buf, false, config)
  vim.wo[win].wrap = wrap
  if opts.winhighlight then
    vim.wo[win].winhighlight = opts.winhighlight
  end
  self.win, self.buf, self.key = win, buf, opts.key

  self.dismiss = vim.api.nvim_create_autocmd(
    opts.events or { "CursorMoved", "CursorMovedI", "InsertEnter", "BufLeave" },
    {
      buffer = from,
      once = true,
      callback = function()
        if self.win == win then
          self.dismiss = nil
          self:close()
        end
      end,
    }
  )
  return win, buf
end

return M
