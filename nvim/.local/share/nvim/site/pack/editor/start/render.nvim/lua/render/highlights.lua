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
  -- The six levels of heading, told apart the only way a terminal can:
  -- loud at the top and quiet at the bottom. Underlined and bold is a
  -- title with a rule under it; bold is a section; plain is the colour
  -- alone; and the three below that are the same fall in the quiet
  -- colour.
  local title = vim.api.nvim_get_hl(0, { name = "RenderHeading", link = false })
  local quiet = vim.api.nvim_get_hl(0, { name = "RenderMeta", link = false })
  local LEVELS = {
    { title, { bold = true, underline = true } },
    { title, { bold = true } },
    { title, {} },
    { title, { italic = true } },
    { quiet, { bold = true } },
    { quiet, { italic = true } },
  }
  for level, want in ipairs(LEVELS) do
    local hl = { fg = want[1].fg, ctermfg = want[1].ctermfg, cterm = {}, default = true }
    for attr in pairs(want[2]) do
      hl[attr], hl.cterm[attr] = true, true
    end
    vim.api.nvim_set_hl(0, "RenderHeading" .. level, hl)
  end
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
end

return M
