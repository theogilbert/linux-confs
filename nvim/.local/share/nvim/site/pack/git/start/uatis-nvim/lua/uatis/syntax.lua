-- Syntax colours for text that has no buffer to be coloured in.
--
-- Removed code is drawn as virtual lines, and nothing highlights virtual
-- text: Neovim's syntax engine and its tree-sitter highlighter both run
-- over real buffer lines. A before-image therefore arrives flat -- one
-- foreground for the whole line -- which is exactly the thing this plugin
-- exists to avoid, only on the old side: the reviewer is asked to read
-- code with the colouring taken away at the moment they most need to
-- compare it against the coloured line below.
--
-- So the old side is parsed here, on its own, and the highlight query is
-- run against the resulting tree. That gives the same `@capture.lang`
-- groups the real highlighter would have used, which means the removed
-- line is coloured by whatever colourscheme is in use, without the plugin
-- knowing anything about the language.
--
--   syntax.spans(text, filetype, rows) -> { [row] = { {s,e,hl} } }
--
-- Rows are 1-based, columns 0-based and end-exclusive, which is what
-- extmarks and `string.sub` want between them.

local config = require("uatis.config")

local M = {}

-- Captures that mark a region for something other than colour. Painting
-- them would tint whole lines with a group that has no attributes at all
-- (`@spell` is empty in every colourscheme), overwriting the real capture
-- underneath.
local IGNORED = { spell = true, nospell = true, conceal = true }

--- One entry, keyed by the text itself. A redraw in the in-place view
--- re-renders the same old side on every keystroke, so remembering the
--- last parse is the difference between one parse per file and one per
--- keypress. Anything more would be caching a whole file's tree against a
--- gain that has already been had.
local cache = {}

local function parser_for(text, lang)
  if cache.text == text and cache.lang == lang then
    return cache.parser
  end
  local ok, parser = pcall(vim.treesitter.get_string_parser, text, lang)
  if not ok or not parser then
    return nil
  end
  if not pcall(parser.parse, parser, true) then
    return nil
  end
  cache = { text = text, lang = lang, parser = parser }
  return parser
end

--- The tree-sitter language for a filetype, or nil when there is no
--- parser installed for it. `language.add` is what actually loads the
--- shared object, so a filetype whose parser is missing is only found out
--- here, not from the name lookup.
local function lang_of(filetype)
  if not filetype or filetype == "" then
    return nil
  end
  local ok, lang = pcall(vim.treesitter.language.get_lang, filetype)
  if not ok or not lang then
    return nil
  end
  if not pcall(vim.treesitter.language.add, lang) then
    return nil
  end
  return lang
end

--- Highlight spans for `rows` (1-based line numbers) of `text`, or nil
--- when the text cannot be parsed -- no parser for the filetype, or a
--- file big enough that parsing it costs more than the colour is worth.
---
--- Only the rows asked for are filled in, and the query is bounded to the
--- range they span. A before-image covers a handful of lines out of a
--- file that may be thousands long, and paying per column for the rest of
--- it would make the colour cost more than it is worth.
function M.spans(text, filetype, rows)
  if #rows == 0 or #text > config.syntax.max_bytes then
    return nil
  end
  local lang = lang_of(filetype)
  if not lang then
    return nil
  end
  local parser = parser_for(text, lang)
  if not parser then
    return nil
  end

  -- Per-row, per-column group. Later captures win, which is the rule the
  -- real highlighter follows: a query lists general patterns before the
  -- specific ones that refine them.
  local cover, first, last = {}, math.huge, 0
  for _, row in ipairs(rows) do
    cover[row] = cover[row] or {}
    first = math.min(first, row)
    last = math.max(last, row)
  end

  local ok = pcall(function()
    parser:for_each_tree(function(tree, ltree)
      local l = ltree:lang()
      local query = vim.treesitter.query.get(l, "highlights")
      if not query then
        return
      end
      for id, node, meta in query:iter_captures(tree:root(), text, first - 1, last) do
        local name = query.captures[id]
        if not IGNORED[name] then
          local range = meta.range or { node:range() }
          local sr, sc, er, ec = range[1], range[2], range[3], range[4]
          local group = "@" .. name .. "." .. l
          for row = sr + 1, er + 1 do
            local cols = cover[row]
            if cols then
              local from = (row == sr + 1) and sc or 0
              local to = (row == er + 1) and ec or math.huge
              -- A capture can end at column 0 of the row after the one it
              -- covers; that row gets nothing from it.
              for col = from, math.min(to, #text) - 1 do
                cols[col] = group
              end
            end
          end
        end
      end
    end)
  end)
  if not ok then
    return nil
  end

  -- Runs, not columns: one chunk per stretch of the same group.
  local spans = {}
  for row, cols in pairs(cover) do
    local runs, start, group = {}, nil, nil
    local col, n = 0, 0
    for c in pairs(cols) do
      n = math.max(n, c + 1)
    end
    while col <= n do
      local g = cols[col]
      if g ~= group then
        if group and start then
          table.insert(runs, { start, col, group })
        end
        start, group = g and col or nil, g
      end
      col = col + 1
    end
    spans[row] = runs
  end
  return spans
end

--- Splits `line` into `{ text, hl }` chunks along `runs`, giving each
--- chunk the syntax group it fell in plus `overlay_hl` on top. Text no
--- capture claimed keeps `overlay_hl` alone.
---
--- The overlay group goes LAST so its background and its strikethrough
--- win over anything the colourscheme put on the syntax group, while the
--- foreground the syntax group carries -- which is the whole point --
--- comes through untouched.
function M.chunks(line, runs, overlay_hl)
  local out, at = {}, 0
  for _, run in ipairs(runs or {}) do
    local s = math.min(run[1], #line)
    local e = math.min(run[2], #line)
    if e > s then
      if s > at then
        table.insert(out, { line:sub(at + 1, s), overlay_hl })
      end
      table.insert(out, { line:sub(s + 1, e), { run[3], overlay_hl } })
      at = e
    end
  end
  if at < #line then
    table.insert(out, { line:sub(at + 1), overlay_hl })
  end
  return out
end

return M
