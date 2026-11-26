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
-- its pane, an issue -- turn one at the end of their winbar, or in a
-- corner when they have none (`M.busy`).

local config = require("nemeton.config")

local M = {}

local spinner = require("common.spinner")

-- name -> { spinner, redraw }
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
  local r = { redraw = redraw }
  -- The first frame a whole interval in: a wait shorter than that never
  -- turns at all (common.spinner).
  r.spinner = spinner.new(function()
    if running[name] == r then
      r.redraw()
    end
  end, { frames = s.frames, interval = s.interval or 100, delay = s.interval or 100 })
  running[name] = r
  r.spinner:start()
end

--- Stops turning `name`. Safe on one that is not turning.
function M.stop(name)
  local r = running[name]
  if not r then
    return
  end
  running[name] = nil
  r.spinner:reset()
end

--- The frame `name` is on, or nil while it is not turning.
local function frame(name)
  local r = running[name]
  return r and r.spinner:glyph() or nil
end

--- The glyph `name` is on with a space after it, or "" while it is not
--- turning -- so a title can put it in front of itself either way.
function M.glyph(name)
  local f = frame(name)
  return f and (f .. " ") or ""
end

--- Whether `name` is turning.
function M.on(name)
  return running[name] ~= nil
end

-- What `M.busy` turns over: buffer -> how many refreshes of it are out,
-- window -> the float turning in its corner, and window -> what was
-- added to the end of its winbar.
local busy, corners, barred = {}, {}, {}

-- Asked for by the winbar itself, of the window it is drawing: a
-- window redraws its own winbar on a refresh, and a glyph written into
-- the string would be gone with it or, put back once the refresh is
-- in, put back over the new one.
local MARK = "%{%v:lua.require'nemeton.spin'.bar()%}"

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

--- Takes the glyph back off the end of a winbar, if the winbar still
--- ends in it: one drawn again since never had it.
local function unbar(win)
  local tail = barred[win]
  barred[win] = nil
  if tail and vim.api.nvim_win_is_valid(win) then
    local wb = vim.wo[win].winbar
    if wb:sub(-#tail) == tail then
      vim.wo[win].winbar = wb:sub(1, -#tail - 1)
    end
  end
end

--- Puts the glyph at the end of `win`'s winbar, right-aligned: after
--- what is already on the right, or pushed there when nothing is.
local function enbar(win)
  local wb = vim.wo[win].winbar
  if wb:find(MARK, 1, true) then
    return
  end
  local tail = (wb:find("%=", 1, true) and "" or "%=") .. MARK
  vim.wo[win].winbar = wb .. tail
  barred[win] = tail
end

--- The glyph, for the winbar of the window it is drawing.
function M.bar()
  local win = vim.g.statusline_winid
  local ok, buf = pcall(vim.api.nvim_win_get_buf, win)
  if not (ok and busy[buf] and config.spinner) then
    return ""
  end
  return "%#NemetonKey# " .. (frame("busy") or config.spinner.frames[1]) .. " %*"
end

local function drop(win)
  local c = corners[win]
  corners[win] = nil
  if c and vim.api.nvim_win_is_valid(c) then
    vim.api.nvim_win_close(c, true)
  end
end

--- The glyph in a float over the top right corner of `win`, for a
--- window with no winbar to put it in.
local function corner(win)
  local glyph = " " .. (frame("busy") or config.spinner.frames[1])
  local at = {
    relative = "win",
    win = win,
    row = 0,
    col = math.max(0, vim.api.nvim_win_get_width(win) - 2),
    width = 2,
    height = 1,
    zindex = (vim.api.nvim_win_get_config(win).zindex or 49) + 1,
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
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { glyph })
  vim.api.nvim_buf_set_extmark(b, ns, 0, 0, { end_col = #glyph, hl_group = "NemetonKey" })
end

--- Every window showing a busy buffer gets the glyph -- in its winbar,
--- or in a corner when it has none -- and every window that shows none
--- any more loses it.
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
  local function has_bar(win)
    return vim.api.nvim_win_is_valid(win) and vim.wo[win].winbar ~= ""
  end
  for win in pairs(corners) do
    if not want[win] or has_bar(win) then
      drop(win)
    end
  end
  for win in pairs(barred) do
    if not want[win] then
      unbar(win)
    end
  end
  for win in pairs(want) do
    if has_bar(win) then
      enbar(win)
    else
      corner(win)
    end
  end
  -- The winbars ask for their glyph as they are drawn, and a winbar is
  -- drawn when something changes, not when a frame does.
  vim.cmd("redrawstatus!")
  if next(want) == nil then
    M.stop("busy")
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

--- Turns a glyph at the end of the winbar of every window showing
--- `buf` until the function handed back is called: what a window shows
--- while it is asked for again. On the winbar's own ground, where it
--- covers nothing of what is being read; a window with no winbar -- a
--- tab of a merge request has none -- gets it in its top right corner
--- instead, in a float of its own. Asked for by the winbar rather than
--- written into it, since each of these windows rewrites its own chrome
--- as it redraws.
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
