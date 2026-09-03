-- The thread under the cursor, in a float.
--
-- The counterpart to expanded mode: expanded shows every conversation in
-- the file at once and pushes the code apart to do it, while this shows
-- one, over the top, and is gone on the next keystroke. Reading a
-- thread and reading the file are different activities.

local config = require("nemeton.config")
local marks = require("nemeton.marks")
local session = require("nemeton.session")
local threads = require("nemeton.threads")

local M = {}

M.win = nil

function M.close()
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    vim.api.nvim_win_close(M.win, true)
  end
  M.win = nil
end

function M.show(list)
  M.close()
  if not list or #list == 0 then
    return nil
  end

  -- The float is opened over the cursor, so the cursor's line is the
  -- line these threads sit on -- which is what a suggestion in one of
  -- them would replace.
  local bufnr = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local function replaced(above, below)
    return vim.api.nvim_buf_get_lines(bufnr, math.max(row - above, 0), row + below + 1, false)
  end

  -- The widest this float is allowed to open, which is what the thread
  -- is wrapped to; the window itself is then sized to whatever the
  -- wrapped text actually came to, which is usually less.
  local most = math.max(vim.o.columns - 10, 30)

  -- The code in a suggestion, in the colours of the file it is on --
  -- which is the file this float is over. Not where the line is inside
  -- a docstring or a comment: what a suggestion replaces there is
  -- prose, and prose parsed as code is confidently wrong about what is
  -- being read.
  local syntax = require("nemeton.syntax")
  local lang = syntax.of_buf(bufnr)
  local paint = not syntax.prose(bufnr, row, lang) and syntax.painter(lang) or nil

  local lines, hls = {}, {}
  local width = 0
  for i, t in ipairs(list) do
    if i > 1 then
      table.insert(lines, "")
    end
    local drawn = threads.render(t, {
      replaced = replaced,
      width = most,
      was = session.was(t, replaced(threads.span(t), 0)),
      paint = paint,
    })
    local text, painted = marks.shade_lines(drawn, #lines, t.resolved and "settled" or "open")
    vim.list_extend(lines, text)
    vim.list_extend(hls, painted)
    for _, l in ipairs(text) do
      width = math.max(width, vim.fn.strdisplaywidth(l))
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  -- Not markdown: the rail in front of every line is not markdown, and
  -- a syntax that reads "▎ # nope" as a heading fights the highlights
  -- this buffer paints for itself.
  marks.paint(buf, hls)
  vim.bo[buf].modifiable = false

  M.win = vim.api.nvim_open_win(buf, false, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = math.min(math.max(width + 1, 30), most),
    height = math.min(#lines, config.comments.peek_height),
    style = "minimal",
    border = "rounded",
    focusable = true,
  })
  -- The ground a conversation is drawn on is mixed out of `Normal`, and
  -- so is every band inside it -- the head of a note, the code it was
  -- written against, the two halves of a suggestion. Drawn on
  -- `NormalFloat` instead, all five are lifted off a background that is
  -- not the one they were measured against, and how far the box stands
  -- off the page becomes whatever the colourscheme happened to make the
  -- difference between the two. So these windows are the editor's own
  -- background, and `comments.ground` means what it says in here.
  vim.wo[M.win].winhighlight = "NormalFloat:Normal"
  vim.wo[M.win].wrap = true

  -- Dismissed by moving, like a hover. Deliberately not by a keymap:
  -- there is no state to remember here, and a float that needs closing
  -- is a float that gets left open over the code.
  vim.api.nvim_create_autocmd({ "CursorMoved", "InsertEnter", "BufLeave" }, {
    once = true,
    callback = M.close,
  })
  return M.win
end

return M
