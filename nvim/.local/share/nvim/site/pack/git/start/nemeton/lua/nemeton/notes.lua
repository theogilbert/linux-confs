-- Every conversation on the merge request, and the keys to answer
-- them.
--
-- Each thread whole -- every answer in it, and the code it is about
-- quoted above the first note -- under a rule naming where it sits.
-- An index of opening notes was quicker to scan and useless to act
-- on: whether an argument is worth being in is decided by the answers
-- to it, and a reply written from here was a reply to a thread whose
-- end you could not see. The rule is what the index was for: where
-- one conversation stops and the next starts, and what line it is on,
-- read down the left edge without reading a word of either.
--
-- Both kinds, because a review is both. Not every comment is about
-- code -- "this needs a changelog entry", "let us do this after the
-- release" -- and those hang off the merge request as a whole with no
-- line in any buffer to draw them next to; this is the only window
-- they have. The ones that are about code are here too, because "what
-- has been said" is one question and answering it twice in two
-- windows made you ask it twice.
--
-- `:Nemeton conversation` is the same threads by file, with no keys
-- for writing a new one.

local compose = require("nemeton.compose")
local config = require("nemeton.config")
local follow = require("nemeton.follow")
local glab = require("nemeton.glab")
local marks = require("nemeton.marks")
local session = require("nemeton.session")
local win = require("nemeton.win")
local who = require("nemeton.who")

local M = {}

M.win = nil
M.buf = nil
-- Line number (1-based) -> the thread drawn on it, and the note of it,
-- for the keys that act on what is under the cursor.
local rows = {}
local noted = {}
-- The threads folded shut, by id, for as long as the editor is up:
-- this window closes for every reply written from it and is drawn
-- afresh on every refetch, and a list you had folded down to the two
-- arguments still open is a list that has to stay that way through
-- both, or folding it was not worth the keys.
local shut = {}

--- Which of the drawn threads are folded, read off the window into
--- `shut` before the window or its lines go away.
local function remember()
  if not (M.win and vim.api.nvim_win_is_valid(M.win)) then
    return
  end
  vim.api.nvim_win_call(M.win, function()
    for row, t in pairs(rows) do
      if t.id and rows[row - 1] ~= t then
        shut[t.id] = vim.fn.foldclosed(row) == row or nil
      end
    end
  end)
end

function M.close()
  remember()
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    vim.api.nvim_win_close(M.win, true)
  end
  M.win, M.buf, rows, noted = nil, nil, {}, {}
end

--- `foldexpr`: a thread is a fold, from its rule to its last line, and
--- the blank line between two belongs to neither -- so a list folded
--- shut still reads as the rules alone, one under the next.
function M.foldexpr(lnum)
  local t = rows[lnum]
  if not t then
    return "0"
  end
  return rows[lnum - 1] == t and "1" or ">1"
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

--- The rule a thread is drawn under: where it sits, across the
--- window. The line it is on for one on code -- the file alone where
--- it is on none any more -- and "on the merge request" for the rest.
local function rule(t, width)
  local where, hl
  if t.path then
    where = t.line and ("%s:%d"):format(t.path, t.line) or t.path
    hl = "NemetonPath"
  else
    where, hl = "on the merge request", "NemetonMeta"
  end
  local line = config.comments.thread_rule
  if not line or line == "" then
    return { { where, hl } }
  end
  local lead = line:rep(2) .. " "
  local rest = width - vim.fn.strdisplaywidth(lead .. where) - 1
  return {
    { lead, "NemetonMeta" },
    { where, hl },
    { " " .. line:rep(math.max(rest, 0)), "NemetonMeta" },
  }
end

local function render()
  if not (M.buf and vim.api.nvim_buf_is_valid(M.buf) and session.current) then
    return
  end
  local list = everything()
  -- Measured rather than taken from the window's width: the quoted code
  -- and a suggestion are drawn to it, and a line one column too long
  -- wraps back to column zero, outside the rail.
  local width = vim.api.nvim_win_is_valid(M.win or -1) and vim.api.nvim_win_get_width(M.win)
    or math.min(math.floor(vim.o.columns * 0.7), 100)
  local draw = require("nemeton.conversation").reader(session.current.root, width)
  local chunks, map, notes, ground = {}, {}, {}, {}
  for i, t in ipairs(list) do
    if i > 1 then
      table.insert(chunks, {})
    end
    -- The rule belongs to the thread under it, so that the cursor on it
    -- is on that thread: it is the line <CR> is pressed on, having read
    -- where the thread is.
    table.insert(chunks, rule(t, width))
    map[#chunks] = t
    for _, line in ipairs(draw(t)) do
      table.insert(chunks, line)
      map[#chunks] = t
      notes[#chunks] = line.note
      ground[#chunks] = t.resolved and "settled" or "open"
    end
  end
  if #chunks == 0 then
    chunks = { { { "nothing has been said on this merge request yet.", "NemetonMeta" } } }
  end
  local lines, hls, refs = marks.shade_lines(chunks, 0, ground)
  remember()
  rows, noted = map, notes
  vim.bo[M.buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.bo[M.buf].modifiable = false
  marks.paint(M.buf, hls)
  follow.set(M.buf, refs, M.close)
  if vim.api.nvim_win_is_valid(M.win or -1) then
    vim.api.nvim_win_call(M.win, function()
      -- Replacing every line puts every fold back at `foldlevel`, open;
      -- the ones that were shut are shut again by hand.
      vim.cmd("normal! zx")
      for row, t in pairs(map) do
        if t.id and shut[t.id] and map[row - 1] ~= t then
          vim.cmd(row .. "foldclose")
        end
      end
    end)
  end
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

--- ...and which note of it the cursor is on, where it is on one: with
--- every answer drawn, "the comment here" is the one being pointed at
--- rather than one picked out of a list.
local function note_at()
  if not (M.win and vim.api.nvim_win_is_valid(M.win)) then
    return nil
  end
  return noted[vim.api.nvim_win_get_cursor(M.win)[1]]
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
--- `into` is the thread a reply goes into, where this is one: it is
--- what says where the comment is drawn while it is on its way, and a
--- new comment on the merge request has none.
local function write(title, send, keep, default, into)
  local mr = session.current
  M.close()
  --- What the forge answering means, either way -- and `sent` is the
  --- comment drawn in this window while it is on its way there, taken
  --- off by the refresh that brings back the real one.
  local function landed(said, sent)
    return function(data, err)
      if not data then
        sent(false)
        session.refused("could not post", err)
        return
      end
      session.notify(said .. " !" .. mr.iid)
      sent(true)
      session.refresh(function()
        M.open()
      end)
    end
  end
  compose.open({
    title = title,
    default = default,
    on_submit = function(body)
      local sent = session.sending({ body = body, discussion_id = into })
      send(mr, body, landed("posted on", sent))
    end,
    -- Only where there is something to keep it as. A comment posted on
    -- its own and a thread people can answer are different things on
    -- GitLab and a draft is neither until it is published, so those two
    -- keys still say what they mean and go out when pressed.
    on_draft = keep and function(body)
      local sent = session.sending({ body = body, discussion_id = into })
      keep(mr, body, landed("kept for", sent))
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

--- Rewrites the comment under the cursor, or one of the thread's where
--- the cursor is on none of them -- the rule, the quoted code.
---
--- The window goes away for the same reason it does when writing a
--- reply: the composer is a split, this is a float over the middle of
--- the editor, and one is in the way of the other.
function M.edit()
  local thread, note = thread_at(), note_at()
  if not thread then
    session.notify("no thread here", vim.log.levels.WARN)
    return
  end
  local mr = session.current
  M.close()
  require("nemeton.edit").thread(thread, nil, note)
  -- The composer posts and refreshes on its own; the window comes back
  -- when it does, which is what `write` does for the other two keys.
  vim.api.nvim_create_autocmd("BufWipeout", {
    once = true,
    pattern = "nemeton://compose/*",
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
    "post",
    thread.id
  )
end

--- The comments window, with `focus` -- a thread of `everything()` --
--- under the cursor where one is given.
---
--- Given by whatever sent the reader here rather than looked up: a link
--- to a comment on the merge request itself has nowhere else to go, and
--- a window that opens at the top of a list of nine threads has not
--- shown anybody the one they asked for.
function M.open(focus)
  if not session.current then
    session.notify("no merge request open — :Nemeton to pick one", vim.log.levels.WARN)
    return
  end
  M.close()

  local width = math.min(math.floor(vim.o.columns * 0.7), 100)
  local height = math.max(4, math.floor(vim.o.lines * 0.6))
  M.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[M.buf].bufhidden = "wipe"
  who.attach(M.buf)
  local back = win.came_from()
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
  vim.wo[M.win].linebreak = true
  vim.wo[M.win].cursorline = true
  -- One fold a thread, all open: the window is for reading every one of
  -- them, and folding is how the settled ones are put out of the way of
  -- the ones still being argued. A closed fold is drawn as its first
  -- line, highlights and all -- which is the rule, and the rule is
  -- already what this window says a thread is in one line.
  vim.wo[M.win].foldmethod = "expr"
  vim.wo[M.win].foldexpr = "v:lua.require'nemeton.notes'.foldexpr(v:lnum)"
  vim.wo[M.win].foldtext = ""
  vim.wo[M.win].foldlevel = 99
  vim.wo[M.win].foldenable = true

  local k = config.keys.notes
  -- In the order they are reached for: the two that are about the
  -- thread under the cursor, then the two that write a new one, then
  -- the housekeeping.
  vim.wo[M.win].winbar = require("nemeton.detail").hint({
    { k.code, "read" },
    { k.reply, "reply" },
    { k.add, "comment" },
    { k.thread, "thread" },
    { k.edit, "edit" },
    { k.delete, "delete" },
    { k.refresh, "refetch" },
    { k.quit, "quit" },
  })

  local bindings = {
    -- What the word under the cursor points at -- a link, a commit, the
    -- person a comment is calling on. See `comments.follow`.
    { k.follow, follow.here, "follow what is under the cursor" },
    { k.who, who.show, "who gave the reaction, or when the comment was written" },
    -- `q` puts the cursor back where it was; the keys below that
    -- close this window are on their way somewhere and must not.
    {
      k.quit,
      function()
        M.close()
        back()
      end,
      "close",
    },
    -- Into the code for a thread on a line, and into the pane for one
    -- on none: half of what this window lists has no code to be read
    -- beside, and this window closes to let the composer in -- so that
    -- is read where the ones on code are, with the same keys to answer
    -- it, and in a window that stays up while the composer is open.
    {
      k.code,
      function()
        local thread = thread_at()
        if not thread then
          return
        end
        if thread.path and thread.line then
          session.goto_thread(thread, M.close)
          return
        end
        M.close()
        require("nemeton.pane").read(thread)
      end,
      "read this, beside the code or in the pane",
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
          -- Redrawn when the forge has been asked again: this window
          -- stays up over the comment that has just gone, and a list
          -- you have to refetch by hand to believe is a list you stop
          -- believing.
          require("nemeton.edit").delete(thread, render, note_at())
        end
      end,
      "delete a comment in the thread here",
    },
    {
      k.link,
      function()
        follow.copy_note(thread_at(), note_at())
      end,
      "copy a link to the comment under the cursor",
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
  if focus then
    for row = 1, vim.api.nvim_buf_line_count(M.buf) do
      if rows[row] == focus then
        vim.api.nvim_win_set_cursor(M.win, { row, 0 })
        -- The head of the thread at the top of the window rather than
        -- wherever the cursor landing put it: what is being opened is a
        -- conversation, and one opened at its last line is one you have
        -- to scroll back through to read.
        vim.api.nvim_win_call(M.win, function()
          -- Opened if it was folded shut: it is the one asked for.
          vim.cmd("normal! zvzt")
        end)
        break
      end
    end
  end
  return M.win
end

return M
