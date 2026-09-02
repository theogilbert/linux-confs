-- Every conversation on the merge request, one line each, and the keys
-- to answer them.
--
-- An index rather than a transcript: the opening note of each thread
-- and nothing else, because what this window is for is deciding which
-- argument to be in. Where a thread sits, whether it is settled and how
-- many answers it has are on the same line as who wrote it, so the
-- whole review is a column you scan rather than a page you read.
--
-- Both kinds, because a review is both. Not every comment is about
-- code -- "this needs a changelog entry", "let us do this after the
-- release" -- and those hang off the merge request as a whole with no
-- line in any buffer to draw them next to; this is the only window
-- they have. The ones that are about code are here too, saying which
-- line, because "what has been said" is one question and answering it
-- twice in two windows made you ask it twice.
--
-- `:Nemeton conversation` is the transcript: the same threads with
-- every answer in them, to read rather than to scan.

local compose = require("nemeton.compose")
local config = require("nemeton.config")
local glab = require("nemeton.glab")
local marks = require("nemeton.marks")
local session = require("nemeton.session")
local threads = require("nemeton.threads")

local M = {}

M.win = nil
M.buf = nil
-- Line number (1-based) -> the thread drawn on it.
local rows = {}

function M.close()
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    vim.api.nvim_win_close(M.win, true)
  end
  M.win, M.buf, rows = nil, nil, {}
end

--- Every thread, in reading order: the ones on code by file and line,
--- then the ones on the merge request as a whole. Unsent comments of
--- your own sit among them, where they will be once they are sent.
local function everything()
  local mr = session.current
  if not mr then
    return {}
  end
  local inline = vim.list_extend(vim.list_slice(mr.inline or {}), mr.drafts or {})
  table.sort(inline, function(a, b)
    if a.path ~= b.path then
      return (a.path or "") < (b.path or "")
    end
    return (a.line or 0) < (b.line or 0)
  end)
  return vim.list_extend(
    inline,
    vim.list_extend(vim.list_slice(mr.overview or {}), mr.draft_overview or {})
  )
end

local function render()
  if not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) then
    return
  end
  local lines, hls, map = {}, {}, {}
  local list = everything()
  if #list == 0 then
    lines = { "nothing has been said on this merge request yet." }
  else
    for i, t in ipairs(list) do
      if i > 1 then
        table.insert(lines, "")
      end
      local text, painted = threads.flatten(threads.render(t, { summary = true }), #lines)
      vim.list_extend(lines, text)
      vim.list_extend(hls, painted)
      for row = #lines - #text + 1, #lines do
        map[row] = t
      end
    end
  end
  rows = map
  vim.bo[M.buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.bo[M.buf].modifiable = false
  marks.paint(M.buf, hls)
end

local function thread_at()
  if not (M.win and vim.api.nvim_win_is_valid(M.win)) then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(M.win)[1]
  -- The cursor lands on the blank line between two threads as often as
  -- on a note; the one above it is the one being read.
  for i = row, 1, -1 do
    if rows[i] then
      return rows[i]
    end
  end
  return nil
end

--- Writes one, and puts the window back with it in.
---
--- The window goes away while you type: the composer is a split, this
--- is a float over the middle of the editor, and a review comment is
--- written by reading the thread above it rather than by looking at a
--- window that is no longer there.
--- `default` is which of the two keys is the reflex, and is the
--- composer's: "post" for a reply, because an answer kept back is
--- invisible to the person waiting for it and invisible in the thread
--- it answers until the whole review goes out.
local function write(title, send, keep, default)
  local mr = session.current
  M.close()
  local function landed(said)
    return function(data, err)
      if not data then
        session.notify("could not post: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      session.notify(said .. " !" .. mr.iid)
      session.refresh(function()
        M.open()
      end)
    end
  end
  compose.open({
    title = title,
    default = default,
    on_submit = function(body)
      send(mr, body, landed("posted on"))
    end,
    -- Only where there is something to keep it as. A comment posted on
    -- its own and a thread people can answer are different things on
    -- GitLab and a draft is neither until it is published, so those two
    -- keys still say what they mean and go out when pressed.
    on_draft = keep and function(body)
      keep(mr, body, landed("kept for"))
    end or nil,
  })
end

--- A comment on the merge request. `kind` is "note" for one posted on
--- its own -- GitLab's Comment button -- or "thread" for one people can
--- answer, which is its Start thread.
---
--- Both, rather than a choice made here, because the difference is real
--- and permanent: an individual note cannot be turned into a thread
--- afterwards, and cannot be replied to.
function M.add(kind)
  if not session.current then
    session.notify("no merge request open", vim.log.levels.WARN)
    return
  end
  local mr = session.current
  if kind == "thread" then
    write(("!%d  a thread on the merge request"):format(mr.iid), function(m, body, cb)
      -- The same endpoint an inline thread goes to, without a position:
      -- what makes a discussion inline is the position, and one with
      -- none is the overall thread the page shows at the bottom.
      glab.create_discussion(m.root, m.iid, body, nil, cb)
    end)
    return
  end
  write(("!%d  a comment on the merge request"):format(mr.iid), function(m, body, cb)
    glab.create_note(m.root, m.iid, body, cb)
  end)
end

--- Rewrites one of the comments in the thread under the cursor.
---
--- The window goes away for the same reason it does when writing a
--- reply: the composer is a split, this is a float over the middle of
--- the editor, and one is in the way of the other.
function M.edit()
  local thread = thread_at()
  if not thread then
    session.notify("no thread here", vim.log.levels.WARN)
    return
  end
  local mr = session.current
  M.close()
  require("nemeton.edit").thread(thread)
  -- The composer posts and refreshes on its own; the window comes back
  -- when it does, which is what `write` does for the other two keys.
  vim.api.nvim_create_autocmd("BufWipeout", {
    once = true,
    pattern = "nemeton://compose",
    callback = function()
      vim.schedule(function()
        if session.current == mr then
          M.open()
        end
      end)
    end,
  })
end

--- A reply into the overall thread under the cursor.
function M.reply()
  local thread = thread_at()
  if not thread then
    session.notify("no thread here", vim.log.levels.WARN)
    return
  end
  if thread.individual_note then
    session.notify(
      ("GitLab does not take replies to a comment posted on its own — %s starts a thread instead"):format(
        config.keys.notes.thread
      ),
      vim.log.levels.WARN
    )
    return
  end
  write(
    ("!%d  reply to %s"):format(session.current.iid, thread.notes[1].author),
    function(m, body, cb)
      glab.reply(m.root, m.iid, thread.id, body, cb)
    end,
    function(m, body, cb)
      glab.create_draft(m.root, m.iid, body, nil, thread.id, cb)
    end,
    "post"
  )
end

function M.open()
  if not session.current then
    session.notify("no merge request open — :Nemeton to pick one", vim.log.levels.WARN)
    return
  end
  M.close()

  local width = math.min(math.floor(vim.o.columns * 0.7), 100)
  local height = math.max(4, math.floor(vim.o.lines * 0.5))
  M.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[M.buf].bufhidden = "wipe"
  M.win = vim.api.nvim_open_win(M.buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = (" !%d · comments "):format(session.current.iid),
    title_pos = "center",
  })
  vim.wo[M.win].wrap = true
  vim.wo[M.win].linebreak = true
  vim.wo[M.win].cursorline = true

  local k = config.keys.notes
  -- In the order they are reached for: the two that are about the
  -- thread under the cursor, then the two that write a new one, then
  -- the housekeeping.
  vim.wo[M.win].winbar = require("nemeton.detail").hint({
    { k.code, "code" },
    { k.reply, "reply" },
    { k.add, "comment" },
    { k.thread, "thread" },
    { k.edit, "edit" },
    { k.delete, "delete" },
    { k.refresh, "refetch" },
    { k.quit, "quit" },
  })

  local bindings = {
    { k.quit, M.close, "close" },
    -- The window closes only once the thread turns out to have
    -- somewhere to go: half of what is listed here is on no line, and
    -- pressing this on one of those is a fair thing to do.
    {
      k.code,
      function()
        session.goto_thread(thread_at(), M.close)
      end,
      "go to the code this is about",
    },
    {
      k.add,
      function()
        M.add("note")
      end,
      "a comment on the merge request",
    },
    {
      k.thread,
      function()
        M.add("thread")
      end,
      "a thread on the merge request",
    },
    { k.reply, M.reply, "reply to the thread here" },
    { k.edit, M.edit, "edit a comment in the thread here" },
    {
      k.delete,
      function()
        local thread = thread_at()
        if thread then
          require("nemeton.edit").delete(thread)
        end
      end,
      "delete a comment in the thread here",
    },
    {
      k.refresh,
      function()
        session.refresh(render)
      end,
      "refetch",
    },
  }
  for _, b in ipairs(bindings) do
    if b[1] and b[1] ~= "" then
      vim.keymap.set("n", b[1], b[2], { buffer = M.buf, nowait = true, desc = "nemeton: " .. b[3] })
    end
  end

  render()
  return M.win
end

return M
