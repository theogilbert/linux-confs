-- Every thread on the merge request, in one list.
--
-- The gutter answers "is there a comment on this line" and the comments
-- window answers "what has been said, in one line each". Neither
-- answers the question a reviewer asks on the way back in: what is
-- still open, and where. That question wants a list of places, and
-- Neovim already has one -- the quickfix list, with `:cnext` on it, the
-- jump history behind it, and whatever the user has hung off it.
--
-- Threads rather than notes: a conversation is one place to go, however
-- many people have been in it.

local config = require("nemeton.config")
local session = require("nemeton.session")
local threads = require("nemeton.threads")

local M = {}

--- One line of the list: state, who started it, how many answers, and
--- the first line of what they said. The body is a whole markdown note
--- and this is one row of a window that does not wrap; the first line
--- of it is what the gutter promises anyway.
local function summary(thread)
  local first = thread.notes[1]
  local body = vim.split(threads.drawn(first.body), "\n", { plain = true })[1] or ""
  local more = #thread.notes > 1 and (" +%d"):format(#thread.notes - 1) or ""
  local mark = thread.draft and "✎" or (thread.resolved and "✓" or "●")
  return ("%s %s%s: %s"):format(mark, first.author, more, body)
end

--- The threads of the open merge request as quickfix items: the inline
--- ones by file and line, then the overall ones, which have no place to
--- jump to and are listed with none rather than left out.
function M.items(mr, opts)
  opts = opts or {}
  local items = {}
  -- The unsent ones too: "what is left on this merge request" includes
  -- the comments you have written and not sent, and those are the ones
  -- most easily forgotten.
  local inline = vim.tbl_filter(function(t)
    return opts.show_resolved ~= false or not t.resolved
  end, vim.list_extend(vim.list_slice(mr.inline or {}), mr.drafts or {}))
  table.sort(inline, function(a, b)
    if a.path ~= b.path then
      return (a.path or "") < (b.path or "")
    end
    return (a.line or 0) < (b.line or 0)
  end)
  for _, t in ipairs(inline) do
    table.insert(items, {
      filename = mr.root .. "/" .. t.path,
      lnum = t.line,
      col = 1,
      text = summary(t),
    })
  end
  for _, t in ipairs(vim.list_extend(vim.list_slice(mr.overview or {}), mr.draft_overview or {})) do
    -- No filename: quickfix draws an entry with nothing to jump to as
    -- text alone, which is exactly what a comment on the merge request
    -- as a whole is.
    table.insert(items, { text = summary(t) .. "  — overall" })
  end
  return items
end

--- Fills the quickfix list and opens it.
function M.open()
  local mr = session.current
  if not mr then
    session.notify("no merge request open — :Nemeton to pick one", vim.log.levels.WARN)
    return
  end
  local items = M.items(mr, { show_resolved = config.comments.show_resolved })
  if #items == 0 then
    session.notify(("!%d has no threads"):format(mr.iid))
    return
  end
  vim.fn.setqflist({}, " ", {
    title = ("!%d  %s"):format(mr.iid, mr.title or ""),
    items = items,
  })
  -- Tall enough for the list and no taller, up to a third of the
  -- editor: a quickfix window that opens at ten rows for three threads
  -- takes the code away for nothing.
  vim.cmd(("botright copen %d"):format(math.max(1, math.min(#items, math.floor(vim.o.lines / 3)))))
  return #items
end

return M
