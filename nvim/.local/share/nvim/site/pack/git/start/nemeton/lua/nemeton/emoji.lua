-- The `:name:` a forge draws as a picture.
--
-- GitLab renders gemoji shortcodes everywhere it renders markdown, so a
-- comment arrives with `:tada:` in the middle of a sentence and the
-- page it was written on showed 🎉. Read here as it was written, that
-- sentence has a word missing and a colon on each side of it.
--
-- Two halves, and they are opposite. What is *written* stays written:
-- the composer holds the text GitLab will be given, colons and all,
-- because that is what the forge renders and what the next person to
-- edit the comment has to see. What is *read* is drawn: the character,
-- in the width of one, wherever a note is drawn as prose. A suggestion
-- is the exception on both counts -- it is code, and code that says
-- `:tada:` says `:tada:`.
--
-- The names are the shortcodes, and the shortcodes are a list somebody
-- has to keep. This one is short on purpose: the whole gemoji set is
-- eighteen hundred names and most of them have never been typed into a
-- code review. What is here is what a review is written with -- the
-- reactions, the verdicts, the dozen things a comment points at -- and
-- a name that is not here is left exactly as it was typed, which is
-- what a forge does with one it does not know either.
--
-- None of them carry U+FE0F, the variation selector that asks for the
-- coloured picture rather than the black-and-white glyph -- `❤️` is
-- written here as `❤`. Not a matter of taste: with it, Neovim counts
-- the heart as two columns and a terminal drawing it as one leaves a
-- cell nobody wrote, so every window that sizes itself to its own text
-- -- which is every float here -- comes out a column wrong and puts
-- its right-hand border through the last character. The two sides only
-- ever agree about the plain glyph. Same argument as `config.ci`, one
-- codepoint further on.

local config = require("nemeton.config")

local M = {}

--- What starts the word this completes: the sigil is part of what is
--- inserted, because `tada` on its own is a word and `:tada:` is a
--- picture.
M.sigil = ":"

-- Where GitLab parts from render.nvim's table, which is GitHub's
-- gemoji as much as GitLab's. Four names GitLab does not know -- the
-- forge prints `:hugs:` as the word, and refuses it as a reaction --
-- and four it draws as a different picture than gemoji does. Checked
-- against GitLab's own markdown API: what is offered here has to be
-- what the forge draws once the comment is posted.
local GITLAB = {
  car = false,
  red_car = "🚗",
  hugs = false,
  hugging = "🤗",
  roll_eyes = false,
  rolling_eyes = "🙄",
  medal_sports = false,
  medal = "🏅",
  cake = "🍰",
  birthday = "🎂",
  calendar = "📆",
  date = "📅",
  hourglass = "⌛",
  hourglass_flowing_sand = "⏳",
  train = "🚋",
  train2 = "🚆",
}

-- name -> the character it names: render.nvim's table, so the same
-- `:name:` is mostly the same picture in a review and in a file read
-- as a page, with GitLab's spelling over it where the two disagree.
M.by_name = vim.deepcopy(require("render.emoji").by_name)
for name, picture in pairs(GITLAB) do
  M.by_name[name] = picture or nil
end

-- The names, sorted, worked out once: the table above is a map and a
-- completion menu is a list, and the order a menu comes up in must not
-- be whatever `pairs` felt like this time.
local sorted = nil
local function names()
  if not sorted then
    sorted = vim.tbl_keys(M.by_name)
    table.sort(sorted)
  end
  return sorted
end

--- `text` with every `:name:` this knows drawn as the character it
--- names, and every one it does not left exactly as it was written.
---
--- Display only. What is sent back when a comment is rewritten is what
--- its author typed -- the same promise the commit links are drawn
--- under.
function M.render(text)
  if type(text) ~= "string" or not config.comments.emoji then
    return text
  end
  if not text:find(":", 1, true) then
    return text
  end
  return (text:gsub(":([%w_+%-]+):", M.by_name))
end

--- The names worth offering for `prefix` -- what was typed after the
--- `:`, and empty when nothing was.
---
--- What the name starts with first and what it merely contains second:
--- `:check` is reached for by somebody who wants `white_check_mark`,
--- and a menu that will not find it is a menu they stop opening.
function M.candidates(prefix)
  prefix = (prefix or ""):lower():gsub("^:", "")
  local first, second = {}, {}
  for _, name in ipairs(names()) do
    local at = name:find(prefix, 1, true)
    if prefix == "" or at == 1 then
      table.insert(first, name)
    elseif at then
      table.insert(second, name)
    end
  end
  return vim.list_extend(first, second)
end

--- The same names again, for a window whose whole line is the word.
---
--- A reaction is a name the forge is given, not a word in a sentence:
--- there is no sigil in front of it, nothing else on the line, and the
--- word therefore starts at column nought. `nemeton.prompt` is what
--- hangs this on a buffer.
---
--- A leading colon is taken all the same, since `:rocket:` is how the
--- name is written in a comment and so how it arrives pasted from one.
function M.name_omnifunc(findstart, base)
  if findstart == 1 then
    return 0
  end
  local out = {}
  for _, name in ipairs(M.candidates(base)) do
    table.insert(out, {
      word = name,
      -- The character beside the name, which is the whole reason the
      -- menu is worth putting up: nobody remembers which of `tada` and
      -- `confetti_ball` is which.
      menu = M.by_name[name],
    })
  end
  return out
end

--- Neovim's `omnifunc`, which is Vim's: asked for the start of the word
--- first and for the matches second. See `nemeton.mentions`, which
--- answers the other sigil the same way.
---
--- The word starts at the `:`, and both colons are inserted: GitLab
--- draws a picture for `:tada:` and prints the word for `:tada`.
function M.omnifunc(findstart, base)
  if findstart == 1 then
    local col = vim.api.nvim_win_get_cursor(0)[2]
    local head = vim.api.nvim_get_current_line():sub(1, col)
    -- Preceded by nothing or by whitespace. A colon in the middle of a
    -- word is a path, a Ruby symbol, a key in a table or the end of a
    -- sentence's first half -- and a menu that comes up in all four is
    -- a menu that comes up while you are writing prose.
    local at = head:match("^():[%w_+%-]*$") or head:match("[%s([{'\"]():[%w_+%-]*$")
    return at and (at - 1) or -3
  end
  local items = {}
  for _, name in ipairs(M.candidates(base)) do
    table.insert(items, {
      word = (":%s:"):format(name),
      -- The character itself, beside the name: the name is what is
      -- typed and the picture is what is meant, and nobody remembers
      -- which of `tada` and `confetti_ball` is which.
      menu = M.by_name[name],
    })
  end
  return items
end

return M
