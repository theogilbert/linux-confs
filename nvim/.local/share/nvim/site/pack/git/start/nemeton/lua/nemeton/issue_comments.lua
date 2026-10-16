-- What has been said under an issue, in a pane beside it.
--
-- The review's pane in where it goes -- a split of the issue's window,
-- `comments.expand`, `pane_width` and the rest -- and the comments
-- window in what it holds and what its keys do: every thread whole,
-- the answers under each, and `r`, `a`, `t`, `e`, `d`, `+`, `K`,
-- `<C-]>` acting on the comment under the cursor. A split and not a
-- float, because it is read beside the issue rather than instead of
-- it, and stays up while a reply is written under both.
--
-- Every comment is posted as it is sent. A merge request's are kept
-- unsent until the review goes out, because a review is written as a
-- whole; GitLab keeps no unsent comments on an issue, and an issue has
-- no review to write.

local compose = require("nemeton.compose")
local config = require("nemeton.config")
local detail = require("nemeton.detail")
local edit = require("nemeton.edit")
local follow = require("nemeton.follow")
local glab = require("nemeton.glab")
local marks = require("nemeton.marks")
local session = require("nemeton.session")
local threads = require("nemeton.threads")
local who = require("nemeton.who")

local M = {}

-- buf -> { entry, rows, noted }: what each pane drew on which line, for
-- the keys that act on what is under the cursor.
local panes = {}

local function pane_of(entry)
  for buf, p in pairs(panes) do
    if p.entry == entry and vim.api.nvim_buf_is_valid(buf) then
      return buf, p
    end
  end
  return nil
end

local function window_of(buf)
  return vim.fn.win_findbuf(buf or -1)[1]
end

--- `foldexpr`: a thread is a fold, as in the comments window.
function M.foldexpr(lnum)
  local p = panes[vim.api.nvim_get_current_buf()]
  local t = p and p.rows[lnum]
  if not t then
    return "0"
  end
  return p.rows[lnum - 1] == t and "1" or ">1"
end

--- Draws what `entry` has been told into its pane, if it has one.
local function render(entry)
  local buf, p = pane_of(entry)
  if not buf then
    return
  end
  local w = window_of(buf)
  local width = w and vim.api.nvim_win_get_width(w) or 60
  local draw = require("nemeton.conversation").reader(entry.subject.root, width)
  local chunks, map, notes, ground = {}, {}, {}, {}
  for i, t in ipairs(entry.threads or {}) do
    if i > 1 then
      table.insert(chunks, {})
    end
    for _, line in ipairs(draw(t)) do
      table.insert(chunks, line)
      map[#chunks] = t
      notes[#chunks] = line.note
      ground[#chunks] = t.resolved and "settled" or "open"
    end
  end
  if #chunks == 0 then
    local said = entry.threads and "nothing has been said on this issue yet."
      or "fetching the comments…"
    chunks = { { { said, "NemetonMeta" } } }
  end
  local lines, hls, refs = marks.shade_lines(chunks, 0, ground)
  p.rows, p.noted = map, notes
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  marks.paint(buf, hls)
  -- A split rather than a float, so nothing closes on the way to what a
  -- link points at.
  follow.set(buf, refs, nil, entry.subject)
  if w then
    vim.api.nvim_win_call(w, function()
      vim.cmd("normal! zx")
    end)
  end
end

--- Asks the forge what has been said, and who reacted to it, and draws
--- it. `after()` once it is drawn.
function M.refresh(entry, after)
  local subject = entry.subject
  local pending, discussions, facts = 2, nil, nil
  local function done()
    pending = pending - 1
    if pending > 0 then
      return
    end
    if discussions then
      local parsed = threads.parse(discussions)
      -- An issue has no lines: every thread of it is on the issue.
      local all = vim.list_extend(parsed.overview, parsed.inline)
      subject.me = subject.me or (facts and facts.me)
      threads.attach_reactions(all, facts and facts.reactions or {}, subject.me)
      for _, t in ipairs(all) do
        t.on = subject
      end
      entry.threads = all
    end
    render(entry)
    if after then
      after()
    end
  end
  glab.discussions(subject.root, subject.noteable, function(data, err)
    if not data then
      session.notify(
        ("could not fetch the comments on #%d: %s"):format(subject.iid, tostring(err)),
        vim.log.levels.ERROR
      )
    end
    discussions = data
    done()
  end)
  glab.issue_facts(subject.root, subject.iid, function(got)
    facts = got
    done()
  end)
end

local function thread_at(buf)
  local p = panes[buf]
  local w = window_of(buf)
  if not (p and w) then
    return nil
  end
  for i = vim.api.nvim_win_get_cursor(w)[1], 1, -1 do
    if p.rows[i] then
      return p.rows[i]
    end
  end
  return nil
end

local function note_at(buf)
  local p = panes[buf]
  local w = window_of(buf)
  if not (p and w) then
    return nil
  end
  return p.noted[vim.api.nvim_win_get_cursor(w)[1]]
end

--- A new comment on the issue: one on its own (GitLab's Comment) or one
--- people can answer (its Start thread), the same two the comments
--- window writes on a merge request.
function M.add(entry, kind)
  local subject = entry.subject
  local thread = kind == "thread"
  compose.open({
    title = ("#%d  %s"):format(subject.iid, thread and "a thread" or "a comment"),
    -- Filed under the issue, so that a comment closed half-written is
    -- there when one is next written on it. See `nemeton.kept`.
    remember = ("#%d %s"):format(subject.iid, kind),
    default = "post",
    on_submit = function(body)
      local function landed(data, err)
        if not data then
          session.notify("could not post: " .. tostring(err), vim.log.levels.ERROR)
          M.refresh(entry)
          return
        end
        session.notify(("posted on #%d"):format(subject.iid))
        M.refresh(entry)
      end
      if thread then
        glab.create_discussion(subject.root, subject.noteable, body, nil, landed)
      else
        glab.create_note(subject.root, subject.noteable, body, landed)
      end
    end,
  })
end

--- Closes the pane of `entry`, where it has one.
function M.close(entry)
  local buf = pane_of(entry)
  local w = window_of(buf)
  if w and #vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(w)) > 1 then
    vim.api.nvim_win_close(w, true)
  end
end

--- Whether `entry` has its pane open.
function M.is_open(entry)
  return window_of(pane_of(entry)) ~= nil
end

local function bind(buf, entry)
  local k = config.keys.issue_comments
  local function on_thread(fn)
    return function()
      local t = thread_at(buf)
      if t then
        fn(t, note_at(buf))
      end
    end
  end
  local again = function()
    M.refresh(entry)
  end
  local bindings = {
    { k.reply, on_thread(function(t)
      edit.reply(t)
    end), "reply to the thread here" },
    {
      k.add,
      function()
        M.add(entry, "note")
      end,
      "a comment on the issue",
    },
    {
      k.thread,
      function()
        M.add(entry, "thread")
      end,
      "a thread on the issue",
    },
    {
      k.edit,
      on_thread(function(t, note)
        edit.thread(t, again, note)
      end),
      "edit the comment under the cursor",
    },
    {
      k.delete,
      on_thread(function(t, note)
        edit.delete(t, again, note)
      end),
      "delete the comment under the cursor",
    },
    {
      k.react,
      on_thread(function(t, note)
        edit.react(t, again, note)
      end),
      "react to the comment under the cursor",
    },
    { k.follow, follow.here, "follow what is under the cursor" },
    { k.who, who.show, "who reacted, when, what commit, where a link goes" },
    {
      k.link,
      on_thread(function(t, note)
        follow.copy_note(t, note)
      end),
      "copy a link to the comment under the cursor",
    },
    { k.refresh, again, "refetch" },
    {
      k.quit,
      function()
        M.close(entry)
      end,
      "close the pane",
    },
  }
  detail.bind(buf, bindings, k.help, (" #%d · comments "):format(entry.subject.iid))
end

--- Opens the pane beside the issue, or closes it where it is open.
function M.toggle(entry)
  if M.is_open(entry) then
    M.close(entry)
    return
  end
  M.open(entry)
end

--- Opens the pane beside `entry`'s window, and fetches what goes in it.
function M.open(entry)
  local existing = pane_of(entry)
  if window_of(existing) then
    vim.api.nvim_set_current_win(window_of(existing))
    return
  end
  local from = window_of(entry.buf)
  if not from then
    return
  end
  vim.api.nvim_set_current_win(from)
  local c = config.comments
  if c.expand == "right" then
    local width = math.min(c.pane_width or 60, math.floor(vim.o.columns / 2))
    vim.cmd(("belowright vertical %dsplit"):format(math.max(width, 10)))
  else
    local height = math.min(c.pane_height or 15, math.floor(vim.o.lines / 2))
    vim.cmd(("belowright %dsplit"):format(math.max(height, 3)))
  end
  local w = vim.api.nvim_get_current_win()
  local buf = existing
  if not buf then
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].modifiable = false
    pcall(vim.api.nvim_buf_set_name, buf, ("nemeton://issue-comments/%d"):format(entry.subject.iid))
    panes[buf] = { entry = entry, rows = {}, noted = {} }
    who.attach(buf)
    bind(buf, entry)
    -- Gone with the issue: a pane of comments on an issue nobody has
    -- open is a buffer of nothing.
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = entry.buf,
      once = true,
      callback = function()
        panes[buf] = nil
        if vim.api.nvim_buf_is_valid(buf) then
          vim.schedule(function()
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
          end)
        end
      end,
    })
  end
  vim.api.nvim_win_set_buf(w, buf)
  vim.wo[w].winhighlight = "NormalFloat:Normal"
  vim.wo[w].wrap = true
  vim.wo[w].linebreak = true
  vim.wo[w].number = false
  vim.wo[w].relativenumber = false
  vim.wo[w].signcolumn = "no"
  vim.wo[w].cursorline = true
  vim.wo[w].foldmethod = "expr"
  vim.wo[w].foldexpr = "v:lua.require'nemeton.issue_comments'.foldexpr(v:lnum)"
  vim.wo[w].foldlevel = 99
  vim.wo[w].foldenable = true
  local k = config.keys.issue_comments
  vim.wo[w].winbar = detail.hint({
    { k.reply, "reply" },
    { k.add, "comment" },
  }, k.help)
  render(entry)
  M.refresh(entry)
  return w
end

return M
