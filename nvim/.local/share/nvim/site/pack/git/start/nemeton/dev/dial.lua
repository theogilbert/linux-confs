-- A dial for the comment colours, for tuning them in your own
-- colourscheme against your own merge request.
--
--   :Nemeton open <iid>            (a merge request has to be open)
--   :luafile dev/dial.lua
--
-- A small float takes the keys and the comments window redraws behind
-- it on every change. `p` prints a `setup{}` block for what is on the
-- screen; nothing is written anywhere, so quitting reverts all of it.
--
-- Not part of the plugin, and not on the runtime path: colour is the
-- one thing here that cannot be settled by reading the code, because
-- every number in `config.comments` means something different against
-- every colourscheme. This is how you look at it instead.
--
-- It knows one thing the plugin does not have to. Every `Nemeton*`
-- group is defined with `default = true`, so that a `:hi` of yours
-- survives a redraw -- and that is exactly what stops
-- `setup_highlights()` being called twice with different numbers. The
-- flag is stripped for the length of that one call.

local config = require("nemeton.config")
local marks = require("nemeton.marks")
local session = require("nemeton.session")

if not session.current then
  vim.notify("dial: open a merge request first -- :Nemeton", vim.log.levels.ERROR)
  return
end

local ACCENTS = { false, "Comment", "DiagnosticWarn", "String", "Title", "DiagnosticHint", "Normal", true }
local WINDOWS = { "notes", "conversation" }

local state = { accent = 1, heading_accent = 1, window = 1 }
for i, a in ipairs(ACCENTS) do
  if a == config.comments.accent then
    state.accent = i
  end
  if a == config.comments.heading_accent then
    state.heading_accent = i
  end
end

local dial = { win = nil, buf = nil }

--- The plugin's own highlight setup, made to overwrite what it wrote
--- last time round.
local function reapply()
  local real = vim.api.nvim_set_hl
  vim.api.nvim_set_hl = function(ns, name, opts)
    if opts and opts.default and type(name) == "string" and name:match("^Nemeton") then
      opts = vim.tbl_extend("force", opts, { default = false })
    end
    return real(ns, name, opts)
  end
  local ok, err = pcall(marks.setup_highlights)
  vim.api.nvim_set_hl = real
  if not ok then
    vim.notify("dial: " .. tostring(err), vim.log.levels.ERROR)
  end
end

--- A value as it would be written in a config file.
local function quoted(v)
  return type(v) == "string" and ("%q"):format(v) or tostring(v)
end

local function snippet()
  local c = config.comments
  local accent = quoted(c.accent)
  return {
    'require("nemeton").setup({',
    "  comments = {",
    ("    ground = %s,"):format(c.ground),
    ("    accent = %s,"):format(accent),
    ("    reply_ground = %s,"):format(c.reply_ground),
    ("    head_band = %s,"):format(tostring(c.head_band)),
    ("    heading_accent = %s,"):format(quoted(c.heading_accent)),
    ("    heading = %s,"):format(c.heading),
    "  },",
    "})",
  }
end

local function draw_dial()
  if not (dial.buf and vim.api.nvim_buf_is_valid(dial.buf)) then
    return
  end
  local c = config.comments
  local function named(v)
    if v == false then
      return "false (no lean)"
    elseif v == true then
      return "true (by state)"
    end
    return tostring(v)
  end
  local lines = {
    ("  window          %-22s w"):format(WINDOWS[state.window]),
    "",
    ("  accent          %-22s a"):format(named(c.accent)),
    ("  ground          %-22s g / G"):format(("%.2f"):format(c.ground)),
    ("  reply_ground    %-22s r / R"):format(("%.2f"):format(c.reply_ground)),
    "",
    ("  head_band       %-22s h"):format(tostring(c.head_band)),
    ("  heading_accent  %-22s A"):format(named(c.heading_accent)),
    ("  heading         %-22s t / T"):format(("%.2f"):format(c.heading)),
    "",
    "  p print setup{}      q quit",
  }
  vim.bo[dial.buf].modifiable = true
  vim.api.nvim_buf_set_lines(dial.buf, 0, -1, false, lines)
  vim.bo[dial.buf].modifiable = false
end

local function redraw()
  reapply()
  for _, name in ipairs(WINDOWS) do
    pcall(require("nemeton." .. name).close)
  end
  require("nemeton." .. WINDOWS[state.window]).open()
  draw_dial()
  if dial.win and vim.api.nvim_win_is_valid(dial.win) then
    vim.api.nvim_set_current_win(dial.win)
  end
  vim.cmd("redraw")
end

local function step(key, by, lo, hi)
  local at = math.max(lo, math.min(hi, (config.comments[key] or 0) + by))
  -- Rounded, or a tenth added to a tenth prints as 0.30000000000000004
  -- in the block this is here to hand you.
  config.comments[key] = math.floor(at * 100 + 0.5) / 100
  redraw()
end

local function close()
  if dial.win and vim.api.nvim_win_is_valid(dial.win) then
    vim.api.nvim_win_close(dial.win, true)
  end
  dial.win, dial.buf = nil, nil
end

dial.buf = vim.api.nvim_create_buf(false, true)
vim.bo[dial.buf].bufhidden = "wipe"
vim.bo[dial.buf].modifiable = false
dial.win = vim.api.nvim_open_win(dial.buf, true, {
  relative = "editor",
  width = 54,
  height = 11,
  row = math.max(0, vim.o.lines - 15),
  col = math.max(0, vim.o.columns - 58),
  style = "minimal",
  border = "rounded",
  title = " comment colours ",
  title_pos = "center",
})
-- The same background the windows being tuned are on, or the dial is
-- lying about what it is showing you.
vim.wo[dial.win].winhighlight = "NormalFloat:Normal"

local keys = {
  q = close,
  a = function()
    state.accent = state.accent % #ACCENTS + 1
    config.comments.accent = ACCENTS[state.accent]
    redraw()
  end,
  A = function()
    state.heading_accent = state.heading_accent % #ACCENTS + 1
    config.comments.heading_accent = ACCENTS[state.heading_accent]
    redraw()
  end,
  w = function()
    state.window = state.window % #WINDOWS + 1
    redraw()
  end,
  h = function()
    config.comments.head_band = not config.comments.head_band
    redraw()
  end,
  g = function()
    step("ground", -0.02, 0, 1)
  end,
  G = function()
    step("ground", 0.02, 0, 1)
  end,
  r = function()
    step("reply_ground", -0.1, 0, 5)
  end,
  R = function()
    step("reply_ground", 0.1, 0, 5)
  end,
  t = function()
    step("heading", -0.02, 0, 1)
  end,
  T = function()
    step("heading", 0.02, 0, 1)
  end,
  p = function()
    local out = snippet()
    local text = table.concat(out, "\n")
    vim.fn.setreg('"', text)
    pcall(vim.fn.setreg, "+", text)
    close()
    vim.schedule(function()
      for _, l in ipairs(out) do
        vim.api.nvim_echo({ { l, "Normal" } }, true, {})
      end
      vim.api.nvim_echo({ { '(also yanked to " and +)', "Comment" } }, true, {})
    end)
  end,
}
for lhs, fn in pairs(keys) do
  vim.keymap.set("n", lhs, fn, { buffer = dial.buf, nowait = true })
end

redraw()
