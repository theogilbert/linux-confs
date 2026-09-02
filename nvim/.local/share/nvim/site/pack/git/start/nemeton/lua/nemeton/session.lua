-- One merge request at a time, and everything hanging off it.
--
-- "Reviewing MR 42" is a mode the editor is in, not a property of any
-- one buffer: the branch is checked out, the threads are fetched once,
-- and every file you open from then on is drawn against them. That mode
-- is this module.

local detail = require("nemeton.detail")
local glab = require("nemeton.glab")
local log = require("nemeton.log")
local marks = require("nemeton.marks")
local threads = require("nemeton.threads")

local M = {}

-- nil when no merge request is open.
M.current = nil

local root_cache = nil

--- The repository root, resolved once per editor session.
---
--- Synchronous, alone in this file: it is a `rev-parse` on a local
--- directory, it is needed before any of the asynchronous calls can be
--- made at all, and threading a callback through every entry point to
--- save a millisecond buys nothing.
function M.root()
  if root_cache then
    return root_cache
  end
  local cwd = vim.fn.getcwd()
  local done = log.exec({ "git", "rev-parse", "--show-toplevel" }, { cwd = cwd })
  local out = vim
    .system({ "git", "rev-parse", "--show-toplevel" }, { text = true, cwd = cwd })
    :wait()
  done(out.code, out.stderr)
  local root = out.code == 0 and vim.trim(out.stdout or "") or ""
  root_cache = root ~= "" and root or nil
  return root_cache
end

local function notify(msg, level)
  vim.notify("nemeton: " .. msg, level or vim.log.levels.INFO)
end

M.notify = notify

--- A buffer's path as GitLab names it: relative to the repository root,
--- forward slashes, no leading `./`. Returns nil for anything that is
--- not a file in this repository -- terminals, help, the MR list itself.
function M.relpath(bufnr)
  local root = M.root()
  if not root then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" or vim.bo[bufnr].buftype ~= "" then
    return nil
  end
  local full = vim.fn.fnamemodify(name, ":p")
  local prefix = root:gsub("/*$", "") .. "/"
  if full:sub(1, #prefix) ~= prefix then
    return nil
  end
  return full:sub(#prefix + 1)
end

--- The line -> threads table for a buffer, or nil if there is nothing
--- for it: no session, or no thread in this file.
function M.by_line(bufnr)
  if not M.current or M.current.mode == "off" then
    return nil
  end
  local path = M.relpath(bufnr)
  return path and M.current.by_file[path] or nil
end

function M.redraw(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local by_line = M.by_line(bufnr)
  if not by_line then
    marks.clear(bufnr)
    return
  end
  marks.render(bufnr, by_line, M.current.mode, {
    show_resolved = require("nemeton.config").comments.show_resolved,
    -- Passed in rather than reached for: this module is built on that
    -- one, and a drawing module that calls back into the session it is
    -- drawing for is a circle.
    was = M.was,
  })
end

function M.redraw_all()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      M.redraw(bufnr)
    end
  end
end

--- Re-reads the discussions and redraws. Called after posting anything,
--- because the forge is the source of truth and a locally invented note
--- is a note with no id to reply to.
function M.refresh(cb)
  if not M.current then
    return
  end
  local mr = M.current
  -- Both at once. The drafts are a second round trip and a refresh runs
  -- after everything that posts anything, so they go out together and
  -- the buffers are redrawn once, when both are in.
  local pending, ok = 2, true
  local function done()
    pending = pending - 1
    if pending > 0 or M.current ~= mr then
      return
    end
    -- The unsent replies go back into the threads they answer before
    -- anything is drawn from them; the threads themselves are rebuilt
    -- from the forge on every refresh, so this cannot double up.
    threads.attach_drafts(mr.inline, mr.draft_replies)
    threads.attach_drafts(mr.overview, mr.draft_replies)
    local all = vim.list_extend(vim.list_slice(mr.inline or {}), mr.drafts or {})
    mr.by_file = threads.index(all)
    M.redraw_all()
    if cb then
      cb(ok)
    end
  end

  glab.discussions(mr.root, mr.iid, function(data, err)
    if not data then
      notify("could not fetch discussions: " .. tostring(err), vim.log.levels.ERROR)
      ok = false
    else
      local parsed = threads.parse(data)
      mr.overview = parsed.overview
      mr.inline = parsed.inline
    end
    done()
  end)

  -- Quietly: draft notes arrived in GitLab 15.x and the endpoint 404s
  -- on anything older, where the right answer is "you have no drafts"
  -- rather than an error on every refresh.
  glab.draft_notes(mr.root, mr.iid, function(data)
    local parsed = threads.parse_drafts(type(data) == "table" and data or {})
    mr.drafts = parsed.inline
    mr.draft_overview = parsed.overview
    mr.draft_replies = parsed.replies
    done()
  end)
end

-- "<sha>:<path>" -> the file's lines as of that commit, or false for
-- one this checkout cannot show. Keyed by content, so it survives a
-- refresh; emptied when the session closes, because a review of another
-- merge request is another set of files.
local blobs = {}

--- A file as it was at `sha`, or nil while that is not known yet.
---
--- `git show` in the checkout rather than a call to the forge: the
--- commit is one this repository already has -- it is the head the
--- merge request was at when the note was written, and the branch is
--- checked out -- and this is asked once per thread on the screen,
--- which is not a question to answer over the network.
---
--- Asynchronous, like everything else that spawns anything, so the
--- first draw goes out without it and the answer brings a redraw of its
--- own. Remembered either way: a blob this checkout does not have --
--- the commit was force-pushed away -- is asked about once rather than
--- on every redraw for the rest of the session.
local function blob(root, sha, path)
  local key = sha .. ":" .. path
  local have = blobs[key]
  if have ~= nil then
    return have or nil
  end
  blobs[key] = false
  local cmd = { "git", "show", key }
  local done = log.exec(cmd, { cwd = root })
  vim.system(cmd, { text = true, cwd = root }, function(res)
    done(res.code, res.stderr)
    if res.code ~= 0 then
      return
    end
    blobs[key] = vim.split(res.stdout or "", "\n", { plain = true })
    vim.schedule(function()
      if M.current then
        M.redraw_all()
      end
    end)
  end)
  return nil
end

--- The code a thread was written against, when it is not the code the
--- thread is drawn on any more.
---
--- A comment is half of a pair, and the code is the half that moves:
--- someone pushes while you are reading, or you edit the file you are
--- reviewing, and the note stays on line 42 while line 42 comes to say
--- something else. The comment then reads as a remark about whatever
--- happens to be under it, which is worse than no comment at all.
---
--- `now` is what is there at this moment, read by whichever window is
--- drawing -- the buffer under the marker, the file on disk. Nil when
--- the two agree, which is nearly always, and nil when there is nothing
--- to compare: an overall comment, a thread with no position, a blob
--- that has not arrived or never will.
function M.was(thread, now)
  local mr = M.current
  if not (mr and now and thread and thread.line and thread.path) then
    return nil
  end
  -- A thread on a deleted line is against the old side of the diff, and
  -- the old side is the base of it.
  local sha = thread.side == "old" and (thread.base_sha or thread.head_sha) or thread.head_sha
  if not sha then
    return nil
  end
  local lines = blob(mr.root, sha, thread.path)
  if not lines then
    return nil
  end
  local was = vim.list_slice(lines, thread.first_line or thread.line, thread.line)
  if #was == 0 or table.concat(was, "\n") == table.concat(now, "\n") then
    return nil
  end
  return was
end

--- Every unsent comment, wherever it sits -- on a line, on the merge
--- request, or inside somebody's thread as an answer you have not sent.
--- Counted rather than read: this is what `publish` sends and what the
--- windows say is still owed.
function M.drafts()
  local mr = M.current
  if not mr then
    return {}
  end
  local all = vim.list_extend(vim.list_slice(mr.drafts or {}), mr.draft_overview or {})
  return vim.list_extend(all, mr.draft_replies or {})
end

--- Who has approved it, and how many more it needs.
---
--- Its own call and its own refresh rather than a passenger on the one
--- above: posting a comment cannot change an approval, and the path
--- that runs after every note is not where a second round trip belongs.
---
--- A failure here is quiet. Approvals are a paid feature on gitlab.com
--- and the endpoint 404s where they are not enabled; a warning every
--- time a merge request opens would be a warning nobody reads.
function M.refresh_approvals(cb)
  local mr = M.current
  if not mr then
    if cb then
      cb(nil, "no merge request open")
    end
    return
  end
  glab.approvals(mr.root, mr.iid, function(data, err)
    if data and M.current == mr then
      mr.approvals = data
      M.redraw_all()
    end
    if cb then
      cb(data, err)
    end
  end)
end

--- The diffs: how big the change is, and which lines of which files it
--- touches. One call, when the merge request opens -- the diffs are the
--- largest thing this plugin ever asks GitLab for, so it asks once.
---
--- Both facts come out of the same payload, which is why one call
--- serves the heading and the comment-anchoring both.
function M.refresh_changes(cb)
  local mr = M.current
  if not mr then
    return
  end
  glab.mr_changes(mr.root, mr.iid, function(data, err)
    if data and M.current == mr then
      mr.diff_stats = detail.diff_stats(data)
      mr.lines = threads.line_map(data)
      M.redraw_all()
    end
    if cb then
      cb(data, err)
    end
  end)
end

--- Opens a merge request: fetch it, check its branch out, fetch the
--- threads, draw them.
---
--- The metadata and the checkout go out together, because neither needs
--- the other -- `glab mr checkout` is given the number, not the payload
--- -- and one of them is a fetch over the network and the other is a
--- fetch over the network followed by a git checkout. Run in sequence
--- they are the whole of the wait before a review starts.
---
--- What is *not* parallel is the drawing: the threads are drawn onto
--- buffers the checkout is about to change under us, so nothing is
--- drawn until both have landed.
function M.open(iid, opts)
  opts = opts or {}
  local root = M.root()
  if not root then
    notify("not inside a git repository", vim.log.levels.ERROR)
    return
  end

  local mr, checked_out, failed = nil, opts.checkout == false, false

  --- Gives up, once: either half can be the one that fails, and the
  --- caller waiting to hear must not hear it twice.
  ---
  --- A caller that passed `on_error` is a caller with a window open
  --- and somebody looking at it -- the list. It says so there, and a
  --- notification saying the same thing over the top of it is the
  --- second copy of a message that was already in front of you.
  local function fail(msg)
    if failed then
      return
    end
    failed = true
    if opts.on_error then
      opts.on_error(msg)
    else
      notify(msg, vim.log.levels.ERROR)
    end
  end

  local function loaded()
    M.current = {
      root = root,
      iid = mr.iid,
      title = mr.title,
      description = mr.description or "",
      author = mr.author and mr.author.username,
      source_branch = mr.source_branch,
      target_branch = mr.target_branch,
      web_url = mr.web_url,
      -- What CI last said about the branch. Kept whole rather than as
      -- a status string: the pipeline's own URL is the next thing you
      -- want after "failed".
      head_pipeline = mr.head_pipeline or mr.pipeline,
      -- Filled in by the approvals call below; nil until it answers,
      -- and nil forever on a forge that refuses the endpoint, which
      -- every reader of it treats as "unknown" rather than "none".
      approvals = nil,
      diff_refs = mr.diff_refs or {},
      by_file = {},
      inline = {},
      overview = {},
      -- The comments you have written and not sent: drawn like any
      -- other, counted apart, and gone from here the moment they are
      -- published.
      drafts = {},
      draft_overview = {},
      draft_replies = {},
      mode = "signs",
    }
    M.refresh_approvals()
    M.refresh_changes()
    M.refresh(function()
      local n = #(M.current.inline or {})
      notify(
        ("!%d %s — %d inline thread%s"):format(mr.iid, mr.title or "", n, n == 1 and "" or "s")
      )
      if opts.on_open then
        opts.on_open()
      end
    end)
    if opts.checkout ~= false then
      M.check_head(root, mr)
    end
  end

  --- Called by each of the two; the second one through does the work.
  local function ready()
    if failed or not (mr and checked_out) then
      return
    end
    loaded()
  end

  glab.mr_get(root, iid, function(data, err)
    if not data then
      fail(("could not read !%d: %s"):format(iid, tostring(err)))
      return
    end
    mr = data
    ready()
  end)

  if opts.checkout ~= false then
    glab.checkout(root, iid, function(ok, out)
      if not ok then
        -- On its own line: what follows is git's own sentence, often
        -- beginning "error:", and "checkout failed: error: ..." reads
        -- as a failure inside a failure.
        fail("checkout failed\n" .. out)
        return
      end
      -- Neovim is still showing the files from the branch we left.
      vim.cmd("checktime")
      checked_out = true
      ready()
    end)
  end
end

--- To the code a thread is about, from whatever window is showing it.
---
--- `before` runs once the thread turns out to have somewhere to go and
--- before anything moves: every window that offers this is a float over
--- the middle of the editor, and closing it is what has to happen first
--- -- `:edit` from inside a float opens the file in the float.
---
--- Returns false for a thread that is about no line, which is not a
--- failure: the comments window lists those beside the ones on code,
--- and pressing the key on one is a fair thing to do.
function M.goto_thread(thread, before)
  if not (thread and thread.path and thread.line) then
    notify("that comment is about no line — it is on the merge request itself")
    return false
  end
  if before then
    before()
  end
  -- A buffer that is already open is switched to rather than re-read:
  -- `:edit` on the file you are looking at reloads it, and reloading a
  -- file somebody is halfway through changing is either a refusal or a
  -- loss. Reviewing means editing the code you are reading.
  local path = M.current.root .. "/" .. thread.path
  local bufnr = vim.fn.bufnr(path)
  if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
    local showing = vim.fn.win_findbuf(bufnr)
    if #showing > 0 then
      vim.api.nvim_set_current_win(showing[1])
    else
      vim.api.nvim_win_set_buf(0, bufnr)
    end
  else
    vim.cmd.edit(vim.fn.fnameescape(path))
  end
  local last = vim.api.nvim_buf_line_count(0)
  vim.api.nvim_win_set_cursor(0, { math.min(thread.line, last), 0 })
  return true
end

--- Warns when the local HEAD is not the revision the threads were
--- written against.
---
--- It happens constantly -- someone pushes while you are reviewing --
--- and the consequence is specific: every line number in every thread
--- refers to a file you are no longer looking at. Better to say so than
--- to draw markers next to the wrong code.
function M.check_head(root, mr)
  local head_sha = mr.diff_refs and mr.diff_refs.head_sha
  if not head_sha then
    return
  end
  local done = log.exec({ "git", "rev-parse", "HEAD" }, { cwd = root })
  vim.system({ "git", "rev-parse", "HEAD" }, { text = true, cwd = root }, function(res)
    done(res.code, res.stderr)
    local head = vim.trim(res.stdout or "")
    if res.code == 0 and head ~= "" and head ~= head_sha then
      vim.schedule(function()
        notify(
          ("local HEAD (%s) is not the MR head (%s) — thread lines may be off"):format(
            head:sub(1, 8),
            head_sha:sub(1, 8)
          ),
          vim.log.levels.WARN
        )
      end)
    end
  end)
end

function M.close()
  if not M.current then
    return
  end
  M.current = nil
  blobs = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    marks.clear(bufnr)
  end
  notify("closed")
end

--- Comments on or off. The threads stay fetched either way: this is a
--- redraw, and it has to be instant, because it is pressed to read the
--- code underneath and pressed again a second later.
function M.toggle()
  if not M.current then
    notify("no merge request open", vim.log.levels.WARN)
    return
  end
  M.current.mode = M.current.mode == "off" and "signs" or "off"
  M.redraw_all()
  return M.current.mode
end

--- The conversations themselves, under the lines they are about, rather
--- than only a mark in the gutter.
function M.toggle_expanded()
  if not M.current then
    notify("no merge request open", vim.log.levels.WARN)
    return
  end
  M.current.mode = M.current.mode == "expanded" and "signs" or "expanded"
  M.redraw_all()
  return M.current.mode
end

--- The threads under the cursor, in the current window.
function M.threads_at_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local by_line = M.by_line(bufnr)
  if not by_line then
    return {}
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  return marks.threads_at(bufnr, row, by_line)
end

--- Every stop `]m` makes, in the order it makes them: by file, then by
--- line -- the order the quickfix list is in, because they are two
--- answers to the same question and disagreeing about the order of a
--- review is worse than either order.
---
--- Unresolved only. `]m` is how a reviewer walks a review, and a
--- settled conversation is not a stop on that walk -- it is history,
--- still drawn in the gutter for whoever wants to read it, and stepped
--- over by the key that means "what is left". An unsent comment of your
--- own is a stop: it is owed a send.
---
--- A thread on a file that is not on disk -- one written against a line
--- that was deleted, or against a file the branch no longer has -- is
--- not a stop either. There is nowhere to put the cursor, and `:edit`
--- on it would answer the key with an empty buffer.
local function stops()
  local root = M.root()
  local out, exists = {}, {}
  for path, by_line in pairs(M.current.by_file) do
    if exists[path] == nil then
      exists[path] = root ~= nil and vim.uv.fs_stat(root .. "/" .. path) ~= nil
    end
    if exists[path] then
      for line, at in pairs(by_line) do
        for _, t in ipairs(at) do
          if not t.resolved then
            table.insert(out, { path = path, line = line })
            break
          end
        end
      end
    end
  end
  table.sort(out, function(a, b)
    if a.path ~= b.path then
      return a.path < b.path
    end
    return a.line < b.line
  end)
  return out
end

--- The next thread still owed something, in `dir` (1 or -1), wrapping.
--- Returns the line it landed on, or nil when the merge request has no
--- stop to make.
---
--- Across files, not just down this one. A review is a walk through a
--- change, and the change is not one file: `]m` stopping at the last
--- comment in app.lua and then going back to the first one in app.lua
--- is a key that says "you are done here" when there are eleven threads
--- in the next file. What it means is "the next thing owed an answer",
--- and the file that is in is a detail.
---
--- The jump goes through `m'` and `:edit`, so it lands in the jumplist:
--- `<C-o>` is how you get back from a key that moved the whole window
--- somewhere else, and a jump that cannot be undone is one people learn
--- not to press.
function M.jump(dir)
  if not M.current or M.current.mode == "off" then
    return nil
  end
  local list = stops()
  if #list == 0 then
    return nil
  end

  -- Where the walk is now. A buffer that is not a file of this
  -- repository -- the quickfix window, a terminal -- is before the
  -- first stop rather than nowhere: the key still has an obvious next.
  local path = M.relpath(vim.api.nvim_get_current_buf())
  local row = path and vim.api.nvim_win_get_cursor(0)[1] or 0

  local function after(s)
    if not path then
      return true
    end
    return s.path > path or (s.path == path and s.line > row)
  end
  local function before(s)
    if not path then
      return true
    end
    return s.path < path or (s.path == path and s.line < row)
  end

  local target
  if dir > 0 then
    for _, s in ipairs(list) do
      if after(s) then
        target = s
        break
      end
    end
    target = target or list[1]
  else
    for i = #list, 1, -1 do
      if before(list[i]) then
        target = list[i]
        break
      end
    end
    target = target or list[#list]
  end

  vim.cmd("normal! m'")
  if target.path ~= path then
    vim.cmd.edit(vim.fn.fnameescape(M.root() .. "/" .. target.path))
  end
  local last = vim.api.nvim_buf_line_count(0)
  vim.api.nvim_win_set_cursor(0, { math.min(target.line, last), 0 })
  return target.line
end

return M
