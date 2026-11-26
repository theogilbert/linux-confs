-- `colors.lua`: the :UatisColors dial.
--
-- Colour is the one thing here that cannot be settled by reading the
-- code: every number in `config.highlight` is a statement about a
-- colourscheme this repository has never seen. The dial is how a reader
-- looks at theirs -- so what is asserted is that it turns the numbers,
-- that the screen follows, and that it offers every number there is.
local h = require("helpers")
local colors = require("uatis.colors")
local hl = require("uatis.config").highlight

local function bg(name)
  return vim.api.nvim_get_hl(0, { name = name, link = false }).bg
end

local function dial_text()
  return table.concat(vim.api.nvim_buf_get_lines(colors.get().buf, 0, -1, false), "\n")
end

describe("the colour dial", function()
  local wins

  it("opens", function()
    vim.cmd("silent! only")
    wins = #vim.api.nvim_list_wins()
    colors.open()
    assert.is_not_nil(colors.get())
  end)

  -- Every number in the table, not the ones somebody remembered. A
  -- setting added to `config.highlight` and left out of here is a
  -- colour with no way to look at it, which is the one thing this is
  -- for.
  it("offers every number config.highlight has", function()
    local text, missing = dial_text(), {}
    for key, v in pairs(hl) do
      if type(v) == "number" and not text:find(key, 1, true) then
        table.insert(missing, key)
      end
    end
    assert.are.same({}, missing)
  end)

  it("steps to the next setting on j", function()
    h.press("j")
    assert.are.equal("add_lightness", vim.api.nvim_get_current_line():match("^%s+([%w_]+)"))
  end)

  -- `setup_highlights` writes each group by name and every mark on
  -- screen carries the name rather than the colour, so re-deriving is a
  -- repaint of a review that was never re-rendered.
  it("turns a number up on L, the tint re-derived with it", function()
    local was, before = hl.add_lightness, bg("UatisAdd")
    h.press("L")
    assert.is_true(hl.add_lightness > was)
    assert.are_not.equal(before, bg("UatisAdd"))

    h.press("r")
    assert.are.equal(was, hl.add_lightness)
    assert.are.equal(before, bg("UatisAdd"))
  end)

  -- A colour named outright switches off the derivation above it, and
  -- the dial says so rather than going on offering a number that now
  -- decides nothing.
  it("lists a colour set by hand, and marks the derivation it replaces", function()
    hl.delete_bg = 0x402020
    h.press("j")
    h.press("l")
    h.press("h")
    local text = dial_text()
    hl.delete_bg = nil
    assert.matches("named outright", text, 1, true)
    assert.matches("delete_lightness%s+[%d.]+%s+[^\n]*overridden", text)
  end)

  it("closes on q, leaving the windows it found", function()
    h.press("q")
    assert.is_nil(colors.get())
    assert.are.equal(wins, #vim.api.nvim_list_wins())
  end)

  -- The block is what a reader keeps: every number, so that a default
  -- moving here cannot quietly move a palette somebody tuned by hand.
  it("prints a setup block of Lua carrying the numbers as they now are", function()
    local saturation = hl.saturation
    colors.open()
    h.press("l")
    local snippet, now = colors.snippet(), hl.saturation
    hl.saturation = saturation
    assert.is_not_nil(load(table.concat(snippet, "\n")))
    assert.matches("saturation = " .. ("%.2f"):format(now), snippet[3], 1, true)
  end)

  it("yanks the block on p, and closes", function()
    h.press("p")
    assert.matches("highlight = {", vim.fn.getreg('"'), 1, true)
    assert.is_nil(colors.get())
  end)
end)
