-- A suggestion, in the colours of the language it is written in.
--
-- A suggestion is the one part of a comment that is not prose. It is
-- code -- the code that would replace the code you are looking at --
-- and until now it was drawn in one colour end to end. Green for a line
-- added and red for one taken away says what the block *is*; it says
-- nothing about what it says, and a reviewer reading it is reading the
-- one piece of code on the screen that the editor has not helped them
-- with.
--
-- Treesitter, parsed out of a string rather than out of a buffer: these
-- lines are in no buffer. The block whole rather than a line at a time,
-- because a line of code on its own is not a program -- a string that
-- opens on one line and closes on the next parses as neither of them.
--
-- Everything here comes to nothing quietly: no parser for the language,
-- no highlights query, a parse that throws. The caller then draws what
-- it always drew, which is a suggestion in one colour.

local config = require("nemeton.config")

local M = {}

-- Captures that are not colours. `@spell` covers a comment from end to
-- end and is defined by nobody, so painting it would take the comment's
-- own colour off again -- and it is the last capture over most
-- comments, which is exactly where that matters.
local NOT_A_COLOUR = { spell = true, nospell = true, conceal = true }

-- What has already been parsed, keyed by the language and the text.
--
-- The same suggestion is repainted on every redraw of the buffer it is
-- drawn into -- a scroll, a keypress, a window resize -- and a parse
-- per redraw of a file with a dozen threads on it is a parse too many.
-- Bounded rather than kept: a review is hours long, and this is a cache
-- of the code somebody else wrote, not of anything being edited.
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

-- The language of a path, once per path: `vim.filetype.match` walks a
-- table of every pattern Neovim knows, and the every-thread window
-- would ask it that once per thread on every redraw.
local by_path = {}

--- The language of a path, worked out the way Neovim works out any
--- file's: by asking `vim.filetype`. The file itself is not read --
--- what a suggestion is written in is decided by the name of the file
--- it is on, which is all this has.
function M.of_path(path)
  if not path or path == "" then
    return nil
  end
  if by_path[path] == nil then
    local ok, ft = pcall(vim.filetype.match, { filename = path })
    by_path[path] = (ok and M.lang(ft)) or false
  end
  return by_path[path] or nil
end

--- The language of an open buffer, which is better evidence than a name
--- when there is any: the filetype is what the editor settled on,
--- modeline and all. Falling back to the name where there is not --
--- an editor started with filetype detection off still has files in it,
--- and they are still written in something.
function M.of_buf(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  return M.lang(vim.bo[bufnr].filetype) or M.of_path(vim.api.nvim_buf_get_name(bufnr))
end

--- `lines` as chunks: `{ { text, hl }, ... }` per line, concatenating
--- back to exactly the line they came from. nil for a language nothing
--- here can parse, which every caller treats as "draw it plainly".
---
--- An uncoloured stretch of a line comes back with no highlight rather
--- than with a default one: what a caller puts behind it -- the green
--- of an added line -- is the caller's to decide.
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

-- The trees parsed out of a file that is not in a buffer, for the one
-- window that reads a thread with no file window open. Bounded, and
-- small: the question is asked once per thread and a conversation is
-- read one file at a time.
local trees, trees_n = {}, 0
local FEW = 8

--- The tree of a source, which is a buffer number or a list of lines.
local function tree_of(source, lang)
  if type(source) == "number" then
    local ok, parser = pcall(vim.treesitter.get_parser, source, lang)
    return ok and parser and (parser:parse() or {})[1] or nil
  end
  local src = table.concat(source, "\n")
  local key = lang .. "\0" .. src
  if trees[key] == nil then
    local ok, parser = pcall(vim.treesitter.get_string_parser, src, lang)
    if trees_n >= FEW then
      trees, trees_n = {}, 0
    end
    trees[key] = (ok and parser and (parser:parse() or {})[1]) or false
    trees_n = trees_n + 1
  end
  return trees[key] or nil
end

--- Whether line `row` (0-based) of a file is inside a string or a
--- comment -- a docstring, a here-document, a block comment.
---
--- The question a suggestion inside one raises. What this module paints
--- is a handful of lines lifted out of a file and parsed on their own,
--- with nothing around them to say what they are: the sentences of a
--- Python docstring parsed as Python are a keyword here, a function
--- call there, and a highlighted line of prose is worse than a plain
--- one -- it is confidently wrong about what the reader is looking at.
---
--- So the file itself is asked, where the lines came from and where
--- their context still is. By the type of the node the line sits in
--- rather than by a highlight capture, because the types are the
--- language's own and nearly every grammar names these two the same
--- way: `string`, `string_literal`, `raw_string_literal`,
--- `template_string`, `comment`, `line_comment`, `block_comment`.
---
--- `source` is a buffer number where the file is open and a list of its
--- lines where it is not.
function M.prose(source, row, lang)
  if not lang or not row then
    return false
  end
  local tree = tree_of(source, lang)
  if not tree then
    return false
  end
  local text = type(source) == "number"
      and (vim.api.nvim_buf_get_lines(source, row, row + 1, false) or {})[1]
    or source[row + 1]
  if not text then
    return false
  end
  -- The first thing written on the line rather than column zero: a line
  -- of an indented docstring starts inside the string either way, but a
  -- line that *opens* one does not, and the code before the quotes is
  -- not what is being asked about.
  local col = math.max((text:find("%S") or 1) - 1, 0)
  local ok, node = pcall(function()
    return tree:root():named_descendant_for_range(row, col, row, col)
  end)
  if not ok then
    return false
  end
  while node do
    local kind = node:type()
    if kind:find("string") or kind:find("comment") then
      return true
    end
    node = node:parent()
  end
  return false
end

--- The painter `threads.render` takes, for code in `lang`. nil where
--- there is nothing to paint with, which is what turns the whole thing
--- off -- including `comments.syntax = false`.
function M.painter(lang)
  if not config.comments.syntax or not lang then
    return nil
  end
  return function(lines)
    return M.paint(lines, lang)
  end
end

--- The same colours, in the buffer a suggestion is being written in.
---
--- The composer is a markdown buffer, and markdown has one colour for a
--- fenced block whose language it does not know -- which `suggestion`,
--- being GitLab's word rather than a language, always is. So the block
--- is painted over the top: extmarks above the priority the treesitter
--- highlighter draws at, redone whenever the buffer changes.
---
--- Only inside the fence. What is written around it is prose, and
--- markdown is already drawing that.
function M.attach(buf, lang)
  if not config.comments.syntax or not lang then
    return
  end
  local ns = vim.api.nvim_create_namespace("nemeton-suggestion")
  local function repaint()
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local block, first = nil, nil
    local function flush()
      for i, runs in ipairs(M.paint(block, lang) or {}) do
        local col = 0
        for _, run in ipairs(runs) do
          if run[2] then
            vim.api.nvim_buf_set_extmark(buf, ns, first + i - 2, col, {
              end_col = col + #run[1],
              hl_group = run[2],
              -- Over the markdown highlighter, which draws the whole
              -- fenced block as one raw block at 100.
              priority = 200,
            })
          end
          col = col + #run[1]
        end
      end
      block, first = nil, nil
    end
    for i, line in ipairs(lines) do
      local fence = line:match("^%s*```(.*)$")
      if block and fence then
        flush()
      elseif block then
        table.insert(block, line)
      elseif fence and fence:match("^suggestion") then
        block, first = {}, i + 1
      end
    end
    if block then
      -- A fence nobody has closed yet, which is what one looks like
      -- while it is being typed.
      flush()
    end
  end
  repaint()
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = buf,
    desc = "nemeton: the suggestion in its own colours",
    callback = repaint,
  })
end

return M
