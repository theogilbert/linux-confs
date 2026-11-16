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

return M
