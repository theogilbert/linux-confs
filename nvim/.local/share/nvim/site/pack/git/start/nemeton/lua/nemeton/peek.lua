-- The thread under the cursor, in a float.
--
-- The counterpart to the pane: that is a window to read a conversation
-- in and answer it from, while this shows one over the top and is gone
-- on the next keystroke. A glance at what is on this line, without
-- opening anything. The same key again goes into it, for a thread
-- longer than the float is tall.

local config = require("nemeton.config")
local marks = require("nemeton.marks")
local session = require("nemeton.session")
local threads = require("nemeton.threads")
local M = {}

-- The float (common.hover). `M.win` is its window while it is up.
local hover = require("common.hover").new()
setmetatable(M, {
  __index = function(_, k)
    if k == "win" then
      return hover.win
    end
  end,
})

function M.close()
  hover:close()
end

function M.show(list)
  -- Still up is still over the line it was opened on: the first move
  -- takes it down. So this is the second press, and it goes in.
  if hover:enter() then
    return hover.win
  end
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
  -- ...and the code the thread is about, out of the file's own tree,
  -- where a docstring is a docstring.
  local paint_was = syntax.painter_of(bufnr, lang)

  local lines, hls = {}, {}
  local width = 0
  for i, t in ipairs(list) do
    if i > 1 then
      table.insert(lines, "")
    end
    local context = config.comments.context or 0
    local drawn = threads.render(t, {
      replaced = replaced,
      original = function(above, below)
        return session.original(t, above, below)
      end,
      width = most,
      was = session.quoted(t, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), context, row + 1),
      paint = paint,
      paint_was = paint_was,
    })
    local text, painted = marks.shade_lines(drawn, #lines, t.resolved and "settled" or "open")
    vim.list_extend(lines, text)
    vim.list_extend(hls, painted)
    for _, l in ipairs(text) do
      width = math.max(width, vim.fn.strdisplaywidth(l))
    end
  end

  -- Dismissed by moving, like a hover (common.hover). Deliberately not by
  -- a keymap: there is no state to remember here, and a float that needs
  -- closing is a float that gets left open over the code. Not focusable
  -- until the second press: a hover is not somewhere `<C-w>w` should stop
  -- on the way past.
  local _, buf = hover:open(lines, {
    width = math.min(math.max(width + 1, 30), most),
    max_height = config.comments.peek_height,
    -- Wrapped or not by `win.wrap`, once the lines are in.
    wrap = false,
    -- Not markdown: the rail in front of every line is not markdown, and
    -- a syntax that reads "▎ # nope" as a heading fights the highlights
    -- this buffer paints for itself.
    paint = function(b)
      marks.paint(b, hls)
    end,
    -- The ground a conversation is drawn on is mixed out of `Normal`, and
    -- so is every band inside it. Drawn on `NormalFloat` instead, they
    -- are lifted off a background that is not the one they were measured
    -- against. So these windows are the editor's own background, and
    -- `comments.ground` means what it says in here.
    winhighlight = "NormalFloat:Normal",
    events = { "CursorMoved", "InsertEnter", "BufLeave" },
  })
  require("nemeton.win").wrap(buf)
  return hover.win
end

return M
