-- Code, in the colours of the language it is written in.
--
-- A fenced block in a markdown file is somebody's code lifted out of
-- whatever file it was in, and drawn in one colour end to end it is the
-- one piece of the page the editor has not helped with. Treesitter,
-- parsed out of a string rather than out of a buffer: these lines are
-- in no buffer. The block whole rather than a line at a time, because a
-- line of code on its own is not a program -- a string that opens on
-- one line and closes on the next parses as neither of them.
--
-- Everything here comes to nothing quietly: no parser for the language,
-- no highlights query, a parse that throws. The caller then draws what
-- it always drew, which is the code in one colour.

local M = {}

-- Captures that are not colours. `@spell` covers a comment from end to
-- end and is defined by nobody, so painting it would take the comment's
-- own colour off again -- and it is the last capture over most
-- comments, which is exactly where that matters.
local NOT_A_COLOUR = { spell = true, nospell = true, conceal = true }

-- What has already been parsed, keyed by the language and the text.
--
-- The same block is painted again on every redraw of the view it is
-- in -- a resize, a save -- and a parse per redraw of a file with a
-- dozen fences in it is a dozen parses too many. Bounded rather than
-- kept: an editor stays up for days.
local painted, painted_n = {}, 0
local MOST = 256

--- Whether a language can be parsed here at all.
---
--- `language.add` is the question asked, because it is the one that
--- answers "is the parser installed": `get_lang` answers only that the
--- filetype has a name in treesitter's vocabulary, and every filetype
--- does.
local known = {}
local function parseable(lang)
  if known[lang] == nil then
    known[lang] = lang ~= nil and pcall(vim.treesitter.language.add, lang) or false
  end
  return known[lang]
end

--- The treesitter language of a filetype, or nil where there is none
--- installed.
function M.lang(ft)
  if not ft or ft == "" then
    return nil
  end
  local ok, lang = pcall(vim.treesitter.language.get_lang, ft)
  lang = ok and lang or ft
  return parseable(lang) and lang or nil
end

-- The language of a fence's word, once per word: `vim.filetype.match`
-- walks a table of every pattern Neovim knows.
local by_word = {}

--- The language a fence names: ```lua, ```python, and the short
--- spellings a filetype does not answer to but an extension does --
--- ```js, ```py, ```sh -- by asking what a file of that extension
--- would be.
function M.of_fence(word)
  if not word or word == "" then
    return nil
  end
  if by_word[word] == nil then
    local lang = M.lang(word)
    if not lang then
      local ok, ft = pcall(vim.filetype.match, { filename = "fence." .. word })
      lang = ok and M.lang(ft) or nil
    end
    by_word[word] = lang or false
  end
  return by_word[word] or nil
end

--- `lines` as chunks: `{ { text, hl }, ... }` per line, concatenating
--- back to exactly the line they came from. nil for a language nothing
--- here can parse, which every caller treats as "draw it plainly".
---
--- An uncoloured stretch of a line comes back with no highlight rather
--- than with a default one: what a caller puts behind it -- the ground
--- under a fence -- is the caller's to decide.
function M.paint(lines, lang)
  if not lang or #lines == 0 then
    return nil
  end
  local src = table.concat(lines, "\n")
  local key = lang .. "\0" .. src
  if painted[key] ~= nil then
    return painted[key] or nil
  end

  local ok, chunks = pcall(function()
    local parser = vim.treesitter.get_string_parser(src, lang)
    local query = vim.treesitter.query.get(lang, "highlights")
    local tree = query and (parser:parse() or {})[1]
    if not tree then
      return nil
    end
    -- One highlight per byte while the captures are being read, because
    -- they overlap: `@function.call` sits inside `@variable`, and which
    -- of the two wins is decided by which came last -- the same rule
    -- Neovim's own highlighter goes by.
    local at = {}
    for i = 1, #lines do
      at[i] = {}
    end
    for id, node in query:iter_captures(tree:root(), src) do
      local name = query.captures[id]
      if not NOT_A_COLOUR[name] then
        -- `@keyword.lua` rather than `@keyword`: Neovim falls the first
        -- back to the second on its own, and a colourscheme that says
        -- something about this language in particular is then heard.
        local hl = ("@%s.%s"):format(name, lang)
        local first_row, first_col, last_row, last_col = node:range()
        for row = first_row, math.min(last_row, #lines - 1) do
          local text = lines[row + 1]
          local from = row == first_row and first_col or 0
          local to = math.min(row == last_row and last_col or #text, #text)
          for byte = from, to - 1 do
            at[row + 1][byte] = hl
          end
        end
      end
    end

    local out = {}
    for i, line in ipairs(lines) do
      local runs, cursor = {}, 0
      while cursor < #line do
        local hl = at[i][cursor]
        local stop = cursor + 1
        while stop < #line and at[i][stop] == hl do
          stop = stop + 1
        end
        table.insert(runs, { line:sub(cursor + 1, stop), hl })
        cursor = stop
      end
      out[i] = runs
    end
    return out
  end)

  local answer = (ok and chunks) or false
  if painted_n >= MOST then
    painted, painted_n = {}, 0
  end
  painted[key], painted_n = answer, painted_n + 1
  return answer or nil
end

return M
