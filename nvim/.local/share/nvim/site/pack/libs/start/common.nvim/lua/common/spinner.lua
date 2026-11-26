-- A glyph that turns while something is being waited on.
--
-- Words that sit still -- "loading..." -- are what a hung call looks
-- like too; something moving says the editor is still waiting rather
-- than stuck. This is the turning: where the glyph is drawn (a title,
-- virtual text, a winbar) is the caller's, told by `on_tick`.
--
-- Counted: every `start` is matched by a `stop`, and it turns while any
-- is outstanding -- one spinner for several loads at once, or one per
-- item, either way.

local M = {}

M.FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local Spinner = {}
Spinner.__index = Spinner

--- A spinner that calls `on_tick()` on the main loop at every frame.
---
--- `opts.frames`   -- the glyphs, `M.FRAMES` by default
--- `opts.interval` -- ms between frames, 80 by default
--- `opts.delay`    -- ms before the first, 0 by default: a wait shorter
---                    than it never turns at all
function M.new(on_tick, opts)
  opts = opts or {}
  return setmetatable({
    frames = opts.frames or M.FRAMES,
    interval = opts.interval or 80,
    delay = opts.delay or 0,
    step = 1,
    refs = 0,
    timer = nil,
    on_tick = on_tick or function() end,
  }, Spinner)
end

--- The glyph it is on.
function Spinner:glyph()
  return self.frames[self.step] or ""
end

--- Whether it is turning.
function Spinner:running()
  return self.refs > 0
end

local function dispose(self)
  if self.timer then
    self.timer:stop()
    self.timer:close()
    self.timer = nil
  end
end

--- One more wait: the first starts it turning.
function Spinner:start()
  self.refs = self.refs + 1
  if self.timer or #self.frames == 0 then
    return
  end
  local timer = (vim.uv or vim.loop).new_timer()
  self.timer = timer
  timer:start(
    self.delay,
    self.interval,
    vim.schedule_wrap(function()
      -- A frame queued before the timer was stopped.
      if self.timer ~= timer then
        return
      end
      self.step = self.step % #self.frames + 1
      self.on_tick()
    end)
  )
end

--- One wait over: the last stops it.
function Spinner:stop()
  self.refs = math.max(0, self.refs - 1)
  if self.refs == 0 then
    dispose(self)
  end
end

--- Stops it whatever is outstanding: for tearing down.
function Spinner:reset()
  self.refs = 0
  dispose(self)
end

return M
