-- The highlight groups are derived from the colourscheme, never invented.
require("helpers")
local overlay = require("uatis.overlay")
local config = require("uatis.config")

local function hl(n)
  return vim.api.nvim_get_hl(0, { name = n, link = false })
end

-- How far a group's background is from the buffer's, on the channel
-- furthest apart.
local function distance(name)
  local bg, nb = hl(name).bg, hl("Normal").bg
  if not (bg and nb) then
    return 0
  end
  local far = 0
  for _, shift in ipairs({ 65536, 256, 1 }) do
    far = math.max(far, math.abs(math.floor(bg / shift) % 256 - math.floor(nb / shift) % 256))
  end
  return far
end

-- HSL saturation of a 0xRRGGBB colour.
local function saturation(c)
  local function ch(shift) return (math.floor(c / shift) % 256) / 255 end
  local r, g, b = ch(65536), ch(256), ch(1)
  local hi, lo = math.max(r, g, b), math.min(r, g, b)
  if hi == lo then
    return 0
  end
  local l = (hi + lo) / 2
  return l > 0.5 and (hi - lo) / (2 - hi - lo) or (hi - lo) / (hi + lo)
end

-- Most colourschemes give the built-in diff groups a foreground as well as
-- a background. Applied over a code buffer that replaces the syntax
-- colouring, which is the one thing this plugin exists to preserve.
describe("highlight derivation, under the default colourscheme", function()
  it("is tested under a scheme that puts a foreground on the diff groups", function()
    assert.is_not_nil(hl("DiffAdd").fg)
  end)

  it("gives UatisAdd, drawn over code, the background only", function()
    assert.is_nil(hl("UatisAdd").fg)
    assert.is_not_nil(hl("UatisAdd").bg)
  end)

  -- The dim says the same thing from the other end: the part of a
  -- changed prose atom that is not the edit. Quieter in COLOUR, which is
  -- where the two are told apart: they sit a few columns from each other
  -- on one line -- a string literal that gained three characters is the
  -- tint on those and the dim on the rest of it -- and a step back taken
  -- in brightness alone leaves a green under a green, one shade with a
  -- seam in it.
  --
  -- So it is NOT the fainter of the two. It is the paler one, and it is
  -- further from the buffer than the tint rather than nearer: with the
  -- colour taken out, lightness is all it has left to be seen by. The
  -- same shape the removed side has, where the ground is the scheme's
  -- own muted red and what actually went is drawn on it deeper.
  it("makes the dim a visible colour, with the colour taken out rather than the light", function()
    local dim = hl("UatisAddDim").bg
    assert.is_not_nil(dim)
    assert.is_true(distance("UatisAddDim") > 0)
    assert.is_true(saturation(dim) <= config.highlight.dim_saturation + 0.01)
    assert.is_true(saturation(dim) < saturation(hl("UatisAdd").bg))
  end)

  -- On virtual lines there is no syntax underneath.
  it("gives UatisDelete a foreground", function()
    assert.is_not_nil(hl("UatisDelete").fg)
  end)

  -- The band says they are gone.
  it("does not strike removed lines through", function()
    for _, group in ipairs({ "UatisDelete", "UatisDeleteBg", "UatisDeleteDim" }) do
      assert.is_falsy(hl(group).strikethrough)
    end
  end)

  -- The default scheme gives `DiffDelete` a foreground and no
  -- background, so every old-side group fell back to a link on it and the
  -- old side had no tint at all -- a flat red line inline and a grey dim
  -- beside it. The scheme's red is in the foreground; it just had to be
  -- read from there.
  it("bands the old side though DiffDelete has a foreground alone", function()
    assert.is_not_nil(hl("UatisDeleteBand").bg)
  end)

  -- A foreground reads as fully saturated in HSL whatever it looks like,
  -- so putting it at background lightness with that kept turns a pale
  -- pink into pillar-box red.
  it("caps the saturation of a band read off a foreground", function()
    assert.is_true(saturation(hl("UatisDeleteBand").bg) <= config.highlight.foreground_saturation + 0.01)
  end)

  -- The part of a removed atom that was not what went away.
  it("makes the old side's dim quieter than its band, but still a band", function()
    assert.is_not_nil(hl("UatisDeleteBandDim").bg)
    assert.is_true(distance("UatisDeleteBandDim") > 0)
    assert.is_true(distance("UatisDeleteBandDim") < distance("UatisDeleteBand"))
  end)

  -- A churn count is three characters wide. The diff tints are built to
  -- sit under a whole line of code, and `+12` wearing one is a coloured
  -- block rather than a number -- so the counts are the same colour read
  -- as a foreground, in the list as well as in the winbar, and they get
  -- one from whichever field the scheme wrote its red in.
  it("draws the counts as foregrounds", function()
    for _, group in ipairs({ "UatisStatAdd", "UatisStatDel", "UatisPlus", "UatisMinus" }) do
      assert.is_not_nil(hl(group).fg)
      assert.is_nil(hl(group).bg)
    end
  end)

  -- The one in the winbar stands beside a filename.
  it("bolds the count in the winbar, not the column of them down the list", function()
    assert.is_nil(hl("UatisStatAdd").bold)
    assert.is_true(hl("UatisPlus").bold)
  end)
end)

-- A scheme that sets the background says what it means: the band is that
-- colour deepened, not the foreground's.
describe("highlight derivation, from a scheme's DiffDelete background", function()
  local saved = hl("DiffDelete")

  local function scheme(spec)
    vim.api.nvim_set_hl(0, "DiffDelete", spec)
    overlay.setup_highlights()
  end

  -- `UatisSign` links `DiffDelete`, so the `-` in the gutter of a
  -- before-image is already in it: a body in any other colour is a row
  -- that changes colour a few columns in.
  it("draws a removed row on the scheme's own removal colour, in both windows", function()
    scheme({ bg = 0x4a1f1f, fg = 0x00ff00 })
    assert.are.equal(0x4a1f1f, hl("UatisDeleteDim").bg)
    assert.are.equal(0x4a1f1f, hl("UatisDeleteBandDim").bg)
  end)

  it("pushes what actually went further out of it", function()
    assert.are_not.equal(0x4a1f1f, hl("UatisDeleteBg").bg)
  end)

  -- DiffDelete copied as written put the scheme's own background under
  -- it, which is the dim, so a row that went and a row that survived
  -- differed only in their text -- and a removed blank line, having
  -- none, read as one that survived.
  it("stands a removed row without syntax colours on the band, in DiffDelete's foreground", function()
    assert.are.equal(hl("UatisDeleteBg").bg, hl("UatisDelete").bg)
    assert.are.equal(0x00ff00, hl("UatisDelete").fg)
  end)

  it("prefers the background over the foreground where the scheme sets one", function()
    local from_bg = hl("UatisDeleteBand").bg
    scheme({ fg = 0x00ff00 })
    assert.are_not.equal(from_bg, hl("UatisDeleteBand").bg)
  end)

  -- For a reader who would rather not tune a derivation.
  it("uses a dim background named outright as given, in both windows", function()
    config.highlight.delete_dim_bg = 0x55393d
    overlay.setup_highlights()
    config.highlight.delete_dim_bg = nil
    assert.are.equal(0x55393d, hl("UatisDeleteDim").bg)
    assert.are.equal(0x55393d, hl("UatisDeleteBandDim").bg)
  end)

  it("leaves the scheme's own groups as they were found", function()
    scheme(saved)
    assert.are.same(hl("DiffDelete"), hl("UatisSign"))
  end)
end)
