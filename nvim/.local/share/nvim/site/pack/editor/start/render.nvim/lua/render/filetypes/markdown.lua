-- A markdown file, as it reads.

local config = require("render.config")
local markdown = require("render.markdown")
local draw = require("render.draw")

local M = {}

--- `lines` as lines of chunks (`render.draw.blocks`). `opts.width` is
--- the most a line of prose may reach.
function M.render(lines, opts)
  local c = config.markdown
  local read = {
    links = c.links,
    styles = c.styles,
    math = c.math,
    headings = c.headings,
    tables = c.tables,
    citations = c.citations,
    lists = c.lists,
  }
  local emoji = c.emoji and require("render.emoji").render or function(text)
    return text
  end
  -- A file's paragraphs are wrapped by hand, and read here at the
  -- window's width.
  read.join = true
  read.definitions = markdown.definitions(lines)
  local syntax = require("render.syntax")
  return draw.blocks(markdown.blocks(lines, read), {
    width = opts.width,
    -- A window scrolls sideways; a fence folded at its edge is not the
    -- code any more.
    code = false,
    glyphs = { bullets = c.bullets, tasks = c.tasks, citation = c.citation },
    headings = c.headings and c.heading or nil,
    inline = function(text)
      return markdown.inline(emoji(text), read)
    end,
    paint = c.syntax and function(code, word)
      return syntax.paint(code, syntax.of_fence(word))
    end or nil,
  })
end

-- What a drawn table's cells are fenced with, its rules included, so
-- the keys move along a border row too.
local edges = { ["│"] = true, ["┼"] = true, ["├"] = true, ["┤"] = true }
for _, c in ipairs({ "┌", "┐", "└", "┘", "┬", "┴" }) do
  edges[c] = true
end

--- The display columns of the cell edges on `line`, in order.
local function fences(line)
  local out, vcol, i = {}, 1, 1
  while i <= #line do
    local n = vim.str_utf_end(line, i) + 1
    local char = line:sub(i, i + n - 1)
    if edges[char] then
      table.insert(out, vcol)
    end
    vcol = vcol + vim.fn.strdisplaywidth(char)
    i = i + n
  end
  return out
end

--- Moves the cursor in `win` to the cell beside the one it is in, `dir`
--- 1 to the right and -1 to the left, and scrolls the cell whole into
--- view, as a table reader's columns are. False off a table, where the
--- key keeps its own meaning.
function M.cell(win, dir)
  local row = vim.api.nvim_win_get_cursor(win)[1]
  local line = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), row - 1, row, false)[1]
  local at = fences(line or "")
  if #at < 2 then
    return false
  end
  local cur = vim.api.nvim_win_call(win, function()
    return vim.fn.virtcol(".")
  end)
  -- The edge that opens the cell to go to: the first past the cursor,
  -- or the one before the edge that opens the cursor's own cell.
  local open
  if dir > 0 then
    for i = 1, #at - 1 do
      if at[i] > cur then
        open = i
        break
      end
    end
  else
    local own = 0
    for i = 1, #at do
      if at[i] <= cur then
        own = i
      end
    end
    open = own > 1 and own - 1 or nil
  end
  if not open then
    return true
  end
  local from, to = at[open] + 1, at[open + 1] - 1
  -- On the cell's first word rather than the padding before it.
  local target = from
  for v = from, to do
    local byte = vim.fn.virtcol2col(win, row, v)
    if line:sub(byte, byte) ~= " " then
      target = v
      break
    end
  end
  vim.api.nvim_win_call(win, function()
    vim.api.nvim_win_set_cursor(win, { row, vim.fn.virtcol2col(win, row, target) - 1 })
    local view = vim.fn.winsaveview()
    local info = vim.fn.getwininfo(win)[1]
    local room = vim.api.nvim_win_get_width(win) - (info and info.textoff or 0)
    local left = view.leftcol
    if to + 1 > left + room then
      left = math.min(from - 2, to + 1 - room)
    end
    if from - 2 < left then
      left = math.max(0, from - 2)
    end
    vim.fn.winrestview({ leftcol = left })
  end)
  return true
end

--- `H` and `L` from cell to cell on a table, and what they always were
--- off one.
function M.keys(_)
  local k = config.keys
  local function step(dir, key)
    return function()
      local win = vim.api.nvim_get_current_win()
      local count = vim.v.count
      for _ = 1, math.max(count, 1) do
        if not M.cell(win, dir) then
          local native = vim.keycode(key)
          vim.cmd("normal! " .. (count > 0 and count or "") .. native)
          return
        end
      end
    end
  end
  return {
    { k.column_next, step(1, k.column_next), "next cell of a table" },
    { k.column_prev, step(-1, k.column_prev), "previous cell of a table" },
  }
end

return M
