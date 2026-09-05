-- A dial for the diff colours, for tuning them against your own
-- colourscheme and your own branch.
--
--   :UatisColors            (with a review on screen, ideally)
--
-- A small float takes the keys and everything already drawn redraws
-- behind it on every change. `p` prints a `setup{}` block for what is on
-- the screen; nothing is written anywhere, so the numbers last as long
-- as the session and no longer.
--
-- Here rather than in a `dev/` script because colour is the one thing in
-- this plugin that cannot be settled by reading the code. Every number
-- in `config.highlight` is a statement about a colourscheme this
-- repository has never seen -- how quiet its `DiffAdd` is, whether it
-- wrote a `DiffDelete` background at all, how much light there is
-- between its tints and its buffer -- so the answer is not a better
-- default, it is a way to look at yours. That is a reader's tool, not a
-- contributor's.
--
-- It needs nothing of its own to redraw. Every group is set by name, and
-- an extmark carries the name rather than the colour, so re-deriving the
-- groups repaints every mark already on screen -- inline, in the old
-- window, in the list and in the winbar -- without a single view being
-- rendered again.

local config = require("uatis.config")
local overlay = require("uatis.overlay")
local pane = require("uatis.pane")
local view = require("uatis.view")

local M = {}

local ns = vim.api.nvim_create_namespace("uatis_colors")

--- What the dial turns: one row per number in `config.highlight`,
--- grouped the way the colours are read rather than the way the table is
--- written.
---
--- `swatch` is the group the number governs, drawn beside it. A dial
--- that only prints numbers is a worse version of the config file; the
--- point of this one is that the answer is next to the question -- and
--- with no review on screen the swatches are the whole of what it can
--- show.
---
--- `note` is what the number is, in the three words that fit: which way
--- it goes. A floor and a cap are opposite instructions and the file
--- says so at length; here there is room for the word alone.
local ROWS = {
  { head = "the tint under changed code" },
  { key = "saturation", swatch = "UatisAdd", note = "floor" },
  { key = "add_lightness", swatch = "UatisAdd" },
  { head = "the edit inside a tinted line" },
  { key = "emphasis_saturation", swatch = "UatisAddText" },
  { key = "emphasis_lightness", swatch = "UatisAddText" },
  { head = "the half of an atom that is not the edit" },
  { key = "dim_saturation", swatch = "UatisAddDim", note = "cap" },
  { key = "dim_lightness", swatch = "UatisAddDim" },
  { head = "removals" },
  { key = "delete_lightness", swatch = "UatisDeleteBand" },
  { key = "foreground_saturation", swatch = "UatisDeleteBand", note = "cap, off a foreground" },
  { key = "delete_dim_contrast", swatch = "UatisDeleteBandDim", note = "no DiffDelete bg only" },
  { head = "bars, hints and counts" },
  { key = "hint_contrast", swatch = "UatisHint", step = 0.05 },
  { key = "signal_saturation", swatch = "UatisPlus" },
  { key = "signal_lightness", swatch = "UatisPlus", note = "on a dark bar" },
  { key = "signal_lightness_dark", swatch = "UatisMinus", note = "...and on a light one" },
}

-- The colours a reader can name outright instead of deriving. Not
-- dialled -- there is no colour to pick from here, only numbers to turn
-- -- but shown, because each one switches off the derivation above it
-- and a dial that went on offering those numbers would be lying about
-- what the screen is doing.
local FIXED = {
  { key = "delete_bg", of = "delete_lightness" },
  { key = "delete_dim_bg", of = "delete_dim_contrast" },
  { key = "add_dim_bg", of = "dim_lightness" },
}

local STEP = 0.01
local BIG = 5

local dial = { win = nil, buf = nil, row = nil, opened = nil }

--- The settable rows, in the order they are drawn.
local function turnable()
  local out = {}
  for i, r in ipairs(ROWS) do
    if r.key then
      table.insert(out, i)
    end
  end
  return out
end

--- Which derivations are switched off by a colour named outright.
local function overridden()
  local out = {}
  for _, f in ipairs(FIXED) do
    if config.highlight[f.key] ~= nil then
      out[f.of] = true
    end
  end
  return out
end

local function draw()
  if not (dial.buf and vim.api.nvim_buf_is_valid(dial.buf)) then
    return
  end
  local off = overridden()
  local lines, swatches = {}, {}
  for _, r in ipairs(ROWS) do
    if r.head then
      table.insert(lines, "")
      table.insert(lines, " " .. r.head)
    else
      local note = r.note or ""
      if off[r.key] then
        note = "overridden below"
      end
      local text = ("   %-22s %5s   "):format(r.key, ("%.2f"):format(config.highlight[r.key]))
      -- The swatch sits at a fixed column so the blocks make one strip
      -- down the dial: three tints that differ by a hair are told apart
      -- by being beside each other, and not at all by being read out as
      -- numbers.
      swatches[#lines + 1] = { col = #text, hl = r.swatch }
      table.insert(lines, ((text .. "██████  " .. note):gsub("%s+$", "")))
    end
  end

  local fixed = {}
  for _, f in ipairs(FIXED) do
    local v = config.highlight[f.key]
    if v ~= nil then
      table.insert(fixed, ("%s #%06x"):format(f.key, v))
    end
  end
  if #fixed > 0 then
    table.insert(lines, "")
    table.insert(lines, " named outright: " .. table.concat(fixed, ", "))
  end

  table.insert(lines, "")
  table.insert(lines, " h/l  -/+     H/L  by five     r  as it was")
  table.insert(lines, " p  print setup{}              q  close")

  vim.bo[dial.buf].modifiable = true
  vim.api.nvim_buf_set_lines(dial.buf, 0, -1, false, lines)
  vim.bo[dial.buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(dial.buf, ns, 0, -1)
  for row, s in pairs(swatches) do
    if s.hl then
      vim.api.nvim_buf_set_extmark(dial.buf, ns, row - 1, s.col, {
        end_col = s.col + #"██████",
        hl_group = s.hl,
        priority = 200,
      })
    end
  end
end

--- The plugin's own derivation, run again over the numbers as they now
--- are, and the screen told to catch up.
---
--- This is the whole of the live half. `setup_highlights` writes every
--- group by name and every mark on screen carries a name, so a redraw
--- after it is a repaint of a review that was never re-rendered: no git,
--- no difftastic, no extmarks touched.
local function reapply()
  local ok, err = pcall(overlay.setup_highlights)
  if not ok then
    vim.notify("uatis: " .. tostring(err), vim.log.levels.ERROR)
  end
  draw()
  vim.cmd("redraw")
end

--- Rounded to the hundredth, or a hundredth added to a tenth prints as
--- 0.30000000000000004 in the block this is here to hand you.
local function round(v)
  return math.floor(v * 100 + 0.5) / 100
end

local function current()
  return ROWS[dial.row]
end

local function step(by)
  local r = current()
  if not r then
    return
  end
  config.highlight[r.key] = round(math.min(math.max(config.highlight[r.key] + by, 0), 1))
  reapply()
end

--- Puts the cursor on a settable row, `by` rows along from this one.
local function move(by)
  local rows = turnable()
  local at = 1
  for i, idx in ipairs(rows) do
    if idx == dial.row then
      at = i
    end
  end
  at = math.min(math.max(at + by, 1), #rows)
  dial.row = rows[at]
  -- The buffer row and the ROWS index are not the same number -- a
  -- heading costs two lines and a blank one -- so the line is found by
  -- the name written on it rather than counted.
  local want = ROWS[dial.row].key
  for i, line in ipairs(vim.api.nvim_buf_get_lines(dial.buf, 0, -1, false)) do
    if line:match("^%s+" .. want .. "%s") then
      pcall(vim.api.nvim_win_set_cursor, dial.win, { i, 0 })
      return
    end
  end
end

--- A `setup{}` block for what is on the screen.
---
--- Every number, not only the ones this dial moved. The block is meant
--- to be pasted into a config and kept, and a partial one drifts the
--- moment a default here changes -- which is the one thing a reader who
--- has tuned their colours by hand does not want to happen quietly.
local function snippet()
  local out = { 'require("uatis").setup({', "  highlight = {" }
  for _, r in ipairs(ROWS) do
    if r.key then
      table.insert(out, ("    %s = %s,"):format(r.key, ("%.2f"):format(config.highlight[r.key])))
    end
  end
  for _, f in ipairs(FIXED) do
    local v = config.highlight[f.key]
    if v ~= nil then
      table.insert(out, ("    %s = 0x%06x,"):format(f.key, v))
    end
  end
  table.insert(out, "  },")
  table.insert(out, "})")
  return out
end

function M.close()
  if dial.win and vim.api.nvim_win_is_valid(dial.win) then
    vim.api.nvim_win_close(dial.win, true)
  end
  dial.win, dial.buf, dial.row = nil, nil, nil
end

--- True while the dial is up. For the tests, and for a second `:UatisColors`.
function M.get()
  if dial.win and vim.api.nvim_win_is_valid(dial.win) then
    return dial
  end
  return nil
end

--- Opens the dial.
---
--- With nothing being compared it still opens, and says so once: the
--- swatches are real colours either way, and a reader who has just
--- installed this and wants to see what the tints look like against
--- their scheme should not have to open a review first. It is only that
--- a strip of blocks is a poorer question than a screen of their own
--- code with the branch drawn on it.
function M.open()
  if M.get() then
    vim.api.nvim_set_current_win(dial.win)
    return dial
  end
  if not (view.get(vim.api.nvim_get_current_buf()) or next(pane.all())) then
    vim.notify("uatis: nothing is being compared -- the dial shows its own swatches; "
      .. config.keys.global.toggle_diff .. " puts them under real code",
      vim.log.levels.WARN)
  end

  -- What the numbers were before any of this, so `r` has somewhere to
  -- put one back. Not the shipped defaults: a reader who set these in
  -- their own `setup{}` meant them, and "as it was" means as they left
  -- it, not as this repository would have had it.
  dial.opened = {}
  for _, r in ipairs(ROWS) do
    if r.key then
      dial.opened[r.key] = config.highlight[r.key]
    end
  end

  dial.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[dial.buf].bufhidden = "wipe"
  vim.bo[dial.buf].modifiable = false
  dial.row = turnable()[1]

  local width = 58
  local height = math.min(#ROWS + 8, math.max(vim.o.lines - 4, 10))
  dial.win = vim.api.nvim_open_win(dial.buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, vim.o.lines - height - 4),
    col = math.max(0, vim.o.columns - width - 2),
    style = "minimal",
    border = "rounded",
    title = " uatis colours ",
    title_pos = "center",
  })
  -- The same background the code being tuned is on, or the swatches are
  -- being read against a surface nothing else here uses.
  vim.wo[dial.win].winhighlight = "NormalFloat:Normal"
  vim.wo[dial.win].cursorline = true
  vim.wo[dial.win].wrap = false

  local keys = {
    q = M.close,
    j = function() move(1) end,
    k = function() move(-1) end,
    ["<Down>"] = function() move(1) end,
    ["<Up>"] = function() move(-1) end,
    l = function() step(current().step or STEP) end,
    h = function() step(-(current().step or STEP)) end,
    ["<Right>"] = function() step(current().step or STEP) end,
    ["<Left>"] = function() step(-(current().step or STEP)) end,
    L = function() step((current().step or STEP) * BIG) end,
    H = function() step(-(current().step or STEP) * BIG) end,
    r = function()
      local c = current()
      if c then
        config.highlight[c.key] = dial.opened[c.key]
        reapply()
      end
    end,
    R = function()
      for key, v in pairs(dial.opened) do
        config.highlight[key] = v
      end
      reapply()
    end,
    p = function()
      local out = snippet()
      local text = table.concat(out, "\n")
      vim.fn.setreg('"', text)
      pcall(vim.fn.setreg, "+", text)
      M.close()
      vim.schedule(function()
        for _, l in ipairs(out) do
          vim.api.nvim_echo({ { l, "Normal" } }, true, {})
        end
        vim.api.nvim_echo({ { '(also yanked to " and +)', "Comment" } }, true, {})
      end)
    end,
  }
  for lhs, fn in pairs(keys) do
    vim.keymap.set("n", lhs, fn, { buffer = dial.buf, nowait = true, silent = true })
  end

  draw()
  move(0)
  return dial
end

--- For the tests, and for anyone driving the dial from a mapping.
M.snippet = snippet
M.rows = ROWS

return M
