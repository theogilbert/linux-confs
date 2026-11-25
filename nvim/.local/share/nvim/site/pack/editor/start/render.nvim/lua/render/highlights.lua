-- The groups a page is drawn in. Every one `default`, so a colourscheme
-- or a user that has said what one looks like is heard; set again after
-- every `:colorscheme`, which clears them.

local M = {}

local function link(name, to)
  vim.api.nvim_set_hl(0, name, { link = to, default = true })
end

--- `a` moved `amount` of the way towards `b`, channel by channel.
local function mix(a, b, amount)
  local out = 0
  for _, shift in ipairs({ 65536, 256, 1 }) do
    local x = math.floor(a / shift) % 256
    local y = math.floor(b / shift) % 256
    out = out + math.floor(x + (y - x) * amount + 0.5) * shift
  end
  return out
end

-- How far a code span's chip is lifted off the page towards the text:
-- enough to be a chip, not so much that it is a highlighted word.
local CODE_LIFT = 0.12
-- ...and a heading's band towards the headings' colour: a ground the
-- title stands on, tinted so that it is the title's and not a selection.
local BAND_LIFT = 0.18

-- Where a heading's colour is looked for once the colourscheme has none
-- for its level: groups every scheme sets, in an order that runs from
-- loud to quiet in most.
local HEADING_LADDER =
  { "Title", "Function", "String", "Identifier", "Type", "Special", "Constant", "Statement" }

-- The weight of each level, on top of its colour.
local HEADING_WEIGHTS = {
  { bold = true },
  { bold = true },
  { bold = true },
  { bold = true },
  {},
  { italic = true },
}

function M.setup()
  -- The reader's mark in its winbar: loud, since it is the one thing
  -- saying the window is not the file.
  link("RenderReader", "IncSearch")
  link("RenderMeta", "Comment")
  link("RenderCitation", "Comment")
  link("RenderMath", "Constant")
  link("RenderOk", "DiagnosticOk")
  link("RenderTableHead", "Title")
  link("RenderHeading", "Title")
  -- A link is the colour of a reference and underlined: the words are
  -- the author's own sentence, and the line under them is what says
  -- they are also a door. Copied rather than linked, because a group
  -- that links somewhere takes that group's attributes entire and there
  -- is nowhere to hang the underline.
  local info = vim.api.nvim_get_hl(0, { name = "DiagnosticInfo", link = false })
  vim.api.nvim_set_hl(0, "RenderLink", {
    fg = info.fg,
    ctermfg = info.ctermfg,
    underline = true,
    cterm = { underline = true },
    default = true,
  })
  -- The six levels of heading, each in a colour of its own: bold or not
  -- is lost at a glance, a colour is not. The colourscheme's own colour
  -- for the level where it has one -- many give headings a colour each
  -- -- and where it has none, or the one a level above already took,
  -- the first colour of a ladder of groups every scheme sets that no
  -- level has yet. A scheme with too few colours for six repeats the
  -- title's. Bold down to H4, which with the band, the rules and the
  -- space above is the four levels a page has sections at.
  local used = {}
  local function colour(names)
    for _, name in ipairs(names) do
      local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
      local key = hl.fg or hl.ctermfg
      if key and not used[key] then
        used[key] = true
        return hl
      end
    end
  end
  local title = vim.api.nvim_get_hl(0, { name = "RenderHeading", link = false })
  for level, attrs in ipairs(HEADING_WEIGHTS) do
    local names = { "@markup.heading." .. level .. ".markdown", "markdownH" .. level }
    if level == 1 then
      table.insert(names, 1, "RenderHeading")
    end
    local hl = colour(vim.list_extend(names, HEADING_LADDER)) or title
    local out = { fg = hl.fg, ctermfg = hl.ctermfg, cterm = {}, default = true }
    for attr in pairs(attrs) do
      out[attr], out.cterm[attr] = true, true
    end
    vim.api.nvim_set_hl(0, "RenderHeading" .. level, out)
    -- The rule under a heading in its colour: the two are one mark.
    link("RenderHeadingRule" .. level, "RenderHeading" .. level)
  end
  title = vim.api.nvim_get_hl(0, { name = "RenderHeading1", link = false })
  -- The weight a word was written with, and no colour: extmarks
  -- compose, so these put a weight on whatever colour the word was
  -- already drawn in -- a link's, a citation's.
  local function weight(name, attr)
    vim.api.nvim_set_hl(0, name, { [attr] = true, cterm = { [attr] = true }, default = true })
  end
  weight("RenderBold", "bold")
  weight("RenderItalic", "italic")
  weight("RenderStrike", "strikethrough")
  -- A code span: the colour quoted text is drawn in, on a chip of its
  -- own where there is a colour to mix one from, since the backticks
  -- that said where it starts and stops are not drawn.
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local quoted = vim.api.nvim_get_hl(0, { name = "String", link = false })
  if vim.o.termguicolors and normal.bg and normal.fg then
    vim.api.nvim_set_hl(0, "RenderCode", {
      fg = quoted.fg,
      bg = mix(normal.bg, normal.fg, CODE_LIFT),
      default = true,
    })
  else
    link("RenderCode", "String")
  end
  if vim.o.termguicolors and normal.bg and title.fg then
    vim.api.nvim_set_hl(0, "RenderHeadingBand", {
      bg = mix(normal.bg, title.fg, BAND_LIFT),
      default = true,
    })
  else
    link("RenderHeadingBand", "CursorLine")
  end
end

return M
