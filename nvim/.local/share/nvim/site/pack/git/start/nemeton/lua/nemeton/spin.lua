-- A glyph that turns while a window waits on the forge.
--
-- The lists say they are fetching in words, and words that sit still
-- are what a hung call looks like too: a list of every merge request
-- you are in is six calls, and the fourth that has not come back reads
-- the same as the fourth that never will. Something moving says the
-- editor is still waiting rather than stuck. Kept to the title, where
-- every one of these windows says what it is: redrawing a border is
-- cheap, and redrawing the rows ten times a second would move the
-- cursor of whoever is reading them.
--
-- The windows that are asked for again rather than filled -- a review,
-- its pane, an issue -- turn one in a corner instead (`M.busy`).

local config = require("nemeton.config")

local M = {}

-- name -> { timer, step, redraw }
local running = {}

--- Starts turning `name`, calling `redraw` each step; a second start
--- while it turns only swaps the redraw. Nothing where `config.spinner`
--- is `false`.
function M.start(name, redraw)
  local s = config.spinner
  if not (s and s.frames and #s.frames > 0) then
    return
  end
  if running[name] then
    running[name].redraw = redraw
    return
  end
  local r = { timer = vim.uv.new_timer(), step = 1, redraw = redraw }
  running[name] = r
  r.timer:start(
    s.interval or 100,
    s.interval or 100,
    vim.schedule_wrap(function()
      if running[name] ~= r then
        return
      end
      r.step = r.step % #s.frames + 1
      r.redraw()
    end)
  )
end

--- Stops turning `name`. Safe on one that is not turning.
function M.stop(name)
  local r = running[name]
  if not r then
    return
  end
  running[name] = nil
  r.timer:stop()
  r.timer:close()
end

--- The glyph `name` is on with a space after it, or "" while it is not
--- turning -- so a title can put it in front of itself either way.
function M.glyph(name)
  local r = running[name]
  if not r then
    return ""
  end
  return config.spinner.frames[r.step] .. " "
end

--- Whether `name` is turning.
function M.on(name)
  return running[name] ~= nil
end

-- What `M.busy` turns over: buffer -> how many refreshes of it are out,
-- and window -> the float turning in its corner.
local busy, corners = {}, {}

-- A refresh that never reports -- a session closed under it, a window
-- gone before its answer -- would leave a glyph turning for good, and
-- one that turns forever says the opposite of what it is there for.
local LONGEST = 60000

local ns = vim.api.nvim_create_namespace("nemeton-spin")

--- The group a window's ground is drawn in, so the glyph sits on it
--- rather than on a patch of `NormalFloat`.
local function ground(win)
  local float = vim.api.nvim_win_get_config(win).relative ~= ""
  local base = float and "NormalFloat" or "Normal"
  for pair in vim.gsplit(vim.wo[win].winhighlight, ",", { plain = true }) do
    local from, to = pair:match("^(.-):(.*)$")
    if from == base then
      return to
    end
  end
  return base
end

local function drop(win)
  local c = corners[win]
  corners[win] = nil
  if c and vim.api.nvim_win_is_valid(c) then
    vim.api.nvim_win_close(c, true)
  end
end

--- Every window showing a busy buffer gets a corner, and every corner
--- whose window shows none any more goes.
local function turn()
  local want, tab = {}, vim.api.nvim_get_current_tabpage()
  for buf in pairs(busy) do
    if vim.api.nvim_buf_is_valid(buf) then
      -- This tab's: a float cannot be put over a window of another.
      for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        if vim.api.nvim_win_get_tabpage(win) == tab then
          want[win] = true
        end
      end
    else
      busy[buf] = nil
    end
  end
  for win in pairs(corners) do
    if not want[win] then
      drop(win)
    end
  end
  if next(want) == nil then
    M.stop("busy")
    return
  end
  local frame = " " .. config.spinner.frames[running.busy and running.busy.step or 1]
  for win in pairs(want) do
    local zindex = (vim.api.nvim_win_get_config(win).zindex or 49) + 1
    local at = {
      relative = "win",
      win = win,
      row = 0,
      col = math.max(0, vim.api.nvim_win_get_width(win) - 2),
      width = 2,
      height = 1,
      zindex = zindex,
    }
    local c = corners[win]
    if c and vim.api.nvim_win_is_valid(c) then
      vim.api.nvim_win_set_config(c, at)
    else
      local b = vim.api.nvim_create_buf(false, true)
      vim.bo[b].bufhidden = "wipe"
      at.style, at.focusable, at.noautocmd = "minimal", false, true
      c = vim.api.nvim_open_win(b, false, at)
      vim.wo[c].winhighlight = "NormalFloat:" .. ground(win)
      corners[win] = c
    end
    local b = vim.api.nvim_win_get_buf(c)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { frame })
    vim.api.nvim_buf_set_extmark(b, ns, 0, 0, { end_col = #frame, hl_group = "NemetonKey" })
  end
end

--- `fn()` on the `n`th call of the function handed back: one refresh
--- that is several calls to the forge, done when the last is.
function M.after(n, fn)
  return function()
    n = n - 1
    if n == 0 then
      fn()
    end
  end
end

--- Turns a glyph in the top right corner of every window showing `buf`
--- until the function handed back is called: what a window shows while
--- it is asked for again. A corner of the window of its own rather than
--- its title or its winbar, since the windows that refresh are floats
--- with a title, splits with a winbar and a tab with neither, and each
--- of them rewrites its own chrome as it redraws.
---
--- Counted, so two refreshes of one buffer turn one glyph until both
--- are back; the function handed back is safe to call more than once.
function M.busy(buf)
  local s = config.spinner
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  if not (s and s.frames and #s.frames > 0 and vim.api.nvim_buf_is_valid(buf)) then
    return function() end
  end
  busy[buf] = (busy[buf] or 0) + 1
  M.start("busy", turn)
  turn()
  local done = false
  local function finish()
    if done then
      return
    end
    done = true
    if busy[buf] then
      busy[buf] = busy[buf] - 1
      if busy[buf] <= 0 then
        busy[buf] = nil
      end
    end
    turn()
  end
  vim.defer_fn(finish, LONGEST)
  return finish
end

return M
