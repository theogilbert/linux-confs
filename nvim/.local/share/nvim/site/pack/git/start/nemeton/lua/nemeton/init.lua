-- nemeton: review merge requests where you read the code.
--
--   :Nemeton                open the merge request list
--   :Nemeton open 42        check !42 out and load its threads
--   :Nemeton description    what it says it is for
--   :Nemeton notes          every comment on it, one line each
--   :Nemeton comment        a new thread on the line under the cursor
--   :Nemeton reply          a reply into the thread under the cursor
--
-- The commands and the Lua functions are not two ways to do one thing. A
-- command is what you type when you know the number; a function is what
-- a keymap calls, and every one of these is pressed dozens of times in a
-- review.

local config = require("nemeton.config")
local glab = require("nemeton.glab")
local marks = require("nemeton.marks")
local session = require("nemeton.session")
local threads = require("nemeton.threads")

local M = {}

-- vim.system, vim.ui.open, extmark `sign_text` and `virt_lines` are all
-- 0.10-or-later, and none of them degrade: on anything older this errors
-- rather than doing less.
local FLOOR = { 0, 10, 0 }

local function supported()
  local v = vim.version()
  return vim.version.ge({ v.major, v.minor, v.patch }, FLOOR)
end

--- Every entry point that needs a merge request open goes through this,
--- so "there is nothing to do that to" is said once and said the same
--- way each time.
local function with_session(fn)
  return function(...)
    if not session.current then
      session.notify("no merge request open — :Nemeton to pick one", vim.log.levels.WARN)
      return
    end
    return fn(...)
  end
end

--- Wires the plugin if nothing has yet.
---
--- `setup{}` is how a plugin manager passes a table in, and it is also
--- the only thing that creates the autocommands and the highlight
--- groups. Nobody has to call it: the command and the global key are
--- registered without loading anything, so the first of them to be used
--- is the moment the rest has to exist.
local wired = false

local function ready()
  if not wired then
    M.setup()
  end
end

function M.list()
  ready()
  require("nemeton.list").open()
end

--- `opts.on_open` / `opts.on_error` are the list's: it keeps its window
--- up, saying what it is waiting for, until one of them fires.
function M.open(iid, opts)
  ready()
  iid = tonumber(iid)
  if not iid then
    return M.list()
  end
  opts = opts or {}
  session.open(iid, {
    on_open = function()
      M.attach_all()
      if opts.on_open then
        opts.on_open()
      end
    end,
    on_error = opts.on_error,
  })
end

function M.close()
  M.detach_all()
  session.close()
end

M.toggle = session.toggle
M.expand = session.toggle_expanded
M.refresh = function()
  session.refresh()
end

M.peek = with_session(function()
  local at = session.threads_at_cursor()
  if #at == 0 then
    session.notify("no thread on this line")
    return
  end
  require("nemeton.peek").show(at)
end)

M.next = with_session(function()
  session.jump(1)
end)
M.prev = with_session(function()
  session.jump(-1)
end)

--- Picks one thread out of the several that can sit on a line, then
--- calls `fn(thread)`. Silent when there is exactly one, which is the
--- overwhelmingly common case -- a prompt you always answer the same
--- way is a prompt that should not have been asked.
local function pick_thread(fn)
  local at = session.threads_at_cursor()
  if #at == 0 then
    session.notify("no thread on this line", vim.log.levels.WARN)
    return
  end
  if #at == 1 then
    return fn(at[1])
  end
  vim.ui.select(at, {
    prompt = "thread",
    format_item = function(t)
      return ("%s: %s"):format(
        t.notes[1].author,
        vim.split(t.notes[1].body, "\n", { plain = true })[1]
      )
    end,
  }, function(choice)
    if choice then
      fn(choice)
    end
  end)
end

--- Where a comment is going, as a reviewer would say it: "app.lua:12",
--- or "app.lua:12-15" when it is about more than one line.
local function span(path, first, last)
  if last > first then
    return ("%s:%d-%d"):format(path, first, last)
  end
  return ("%s:%d"):format(path, first)
end

--- A new thread against the line under the cursor, or against the lines
--- of a visual selection.
---
--- The line is taken from the cursor, not from a diff hunk: you comment
--- on the code you are reading, and whether that line happens to be part
--- of the change is GitLab's business, not the editor's. (GitLab refuses
--- a position on a line outside the diff, and says so; that message is
--- passed through rather than pre-empted.)
---
--- A selection is anchored to its *last* line, which is where GitLab
--- puts a multi-line thread and where the reviewer's cursor already is.
M.comment = with_session(function(first, last)
  local bufnr = vim.api.nvim_get_current_buf()
  local path = session.relpath(bufnr)
  if not path then
    session.notify("this buffer is not a file in the repository", vim.log.levels.WARN)
    return
  end
  local mr = session.current
  if not mr.diff_refs or not mr.diff_refs.head_sha then
    session.notify(
      "!" .. mr.iid .. " has no diff refs to anchor a comment to",
      vim.log.levels.ERROR
    )
    return
  end

  first = first or vim.api.nvim_win_get_cursor(0)[1]
  last = math.max(last or first, first)
  local where = span(path, first, last)
  -- Worked out before the composer opens rather than after it is
  -- written: a line GitLab will not take a comment on is a paragraph
  -- you should not have been invited to type.
  local position = threads.position(mr.diff_refs, path, last, mr.lines, first)
  if not position then
    local why = "%s is not in this merge request's diff"
      .. " — GitLab anchors a comment to lines the change touches"
    session.notify(why:format(where), vim.log.levels.WARN)
    return
  end
  require("nemeton.compose").open({
    title = ("!%d  %s"):format(mr.iid, where),
    on_submit = function(body)
      glab.create_discussion(mr.root, mr.iid, body, position, function(data, err)
        if not data then
          session.notify("could not post: " .. tostring(err), vim.log.levels.ERROR)
          return
        end
        session.notify("posted on " .. where)
        session.refresh()
      end)
    end,
    on_draft = M.keep("kept for " .. where, position),
  })
end)

--- What the composer does with a comment that is kept rather than
--- sent: one draft note, which goes out with the rest of the review
--- when you publish it.
function M.keep(said, position, discussion_id)
  return function(body)
    local mr = session.current
    glab.create_draft(mr.root, mr.iid, body, position, discussion_id, function(data, err)
      if not data then
        session.notify("could not keep: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      session.notify(said)
      session.refresh()
    end)
  end
end

--- Opens a merge request for the branch you are on.
---
--- The composer, with the first line for the title and the rest for the
--- description -- which is `git commit`'s shape, and the one every
--- reviewer already has in their hands. Empty rather than filled in
--- from the commits: a merge request is written to be read by somebody
--- else, and a title nobody chose is the first thing a reviewer has to
--- forgive.
---
--- A title that begins `Draft:` makes a draft merge request. That is
--- GitLab's own rule rather than ours, and it is not worth a key of its
--- own for something you can type.
---
--- No session needed and none started: this is what you do *before*
--- there is a review, and what comes back is a row in the list.
function M.create()
  local root = session.root()
  if not root then
    session.notify("not inside a git repository", vim.log.levels.ERROR)
    return
  end
  local branch = session.branch()
  if not branch then
    session.notify("not on a branch — a merge request comes from one", vim.log.levels.WARN)
    return
  end
  require("nemeton.compose").open({
    title = ("new merge request from %s  ·  first line is the title"):format(branch),
    on_submit = function(text)
      local lines = vim.split(text, "\n", { plain = true })
      local title = vim.trim(table.remove(lines, 1))
      if title == "" then
        session.notify("a merge request needs a title", vim.log.levels.WARN)
        return
      end
      session.notify("opening a merge request for " .. branch .. "…")
      glab.mr_create(root, title, vim.trim(table.concat(lines, "\n")), function(url, err)
        if not url then
          session.notify("could not open it: " .. tostring(err), vim.log.levels.ERROR)
          return
        end
        session.notify(url)
        -- The queue is what it is a row of now, so the queue is redrawn
        -- if it is up. Not opened if it is not: creating one from a
        -- file you are working on is not asking to review it.
        local list = require("nemeton.list")
        if list.win and vim.api.nvim_win_is_valid(list.win) then
          list.open()
        end
      end)
    end,
  })
end

--- Sends every comment you have written and not sent -- which is what
--- submitting a review is.
--- `cb` is the merge request's own window redrawing itself: what it
--- says is unsent is what GitLab says is unsent, once this has landed.
M.publish = with_session(function(cb)
  local mr = session.current
  local n = #session.drafts()
  if n == 0 then
    session.notify("nothing kept unsent")
    if cb then
      cb()
    end
    return
  end
  glab.publish_drafts(mr.root, mr.iid, function(ok, err)
    if not ok then
      session.notify("could not publish: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    session.notify(("published %d comment%s on !%d"):format(n, n == 1 and "" or "s", mr.iid))
    session.refresh(cb)
  end)
end)

--- A suggestion: a thread on the selected lines, carrying the code that
--- would replace them.
---
--- The composer opens on the lines themselves rather than on an empty
--- fence. A suggestion is an edit of what is there, and retyping four
--- lines to change one word is how a reviewer decides not to suggest
--- anything at all.
M.suggest = with_session(function(first, last)
  local bufnr = vim.api.nvim_get_current_buf()
  local path = session.relpath(bufnr)
  if not path then
    session.notify("this buffer is not a file in the repository", vim.log.levels.WARN)
    return
  end
  local mr = session.current
  if not mr.diff_refs or not mr.diff_refs.head_sha then
    session.notify(
      "!" .. mr.iid .. " has no diff refs to anchor a comment to",
      vim.log.levels.ERROR
    )
    return
  end

  first = first or vim.api.nvim_win_get_cursor(0)[1]
  last = math.max(last or first, first)
  local where = span(path, first, last)
  -- Anchored at the last line of the selection: that is the line the
  -- `-N+0` in the fence is measured back from, and the line GitLab
  -- anchors a thread on a span to.
  local position = threads.position(mr.diff_refs, path, last, mr.lines, first)
  if not position then
    local why = "%s is not in this merge request's diff"
      .. " — GitLab anchors a suggestion to lines the change touches"
    session.notify(why:format(where), vim.log.levels.WARN)
    return
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false)
  require("nemeton.compose").open({
    title = ("!%d  suggest %s"):format(mr.iid, where),
    body = threads.suggestion_body(lines),
    on_draft = M.keep("kept for " .. where, position),
    on_submit = function(body)
      glab.create_discussion(mr.root, mr.iid, body, position, function(data, err)
        if not data then
          session.notify("could not post: " .. tostring(err), vim.log.levels.ERROR)
          return
        end
        session.notify("suggested on " .. where)
        session.refresh()
      end)
    end,
  })
end)

M.reply = with_session(function()
  pick_thread(function(thread)
    require("nemeton.edit").reply(thread)
  end)
end)

M.resolve = with_session(function()
  local mr = session.current
  pick_thread(function(thread)
    if not thread.resolvable then
      session.notify("that thread cannot be resolved", vim.log.levels.WARN)
      return
    end
    local want = not thread.resolved
    glab.resolve(mr.root, mr.iid, thread.id, want, function(data, err)
      if not data then
        session.notify("could not resolve: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      session.notify(want and "resolved" or "reopened")
      session.refresh()
    end)
  end)
end)

--- What the merge request says it is for, in a float over the code.
---
--- Fetched with the merge request itself rather than on demand: it is
--- one field of a call that has already happened, and a review is full
--- of moments where you need the description again three files in.
M.description = with_session(function()
  require("nemeton.overview").open()
end)

--- Every comment on the merge request, one line each, in a window with
--- the keys to answer them. The opening note of each thread and no
--- reply to it: an index of the argument, not a transcript of it --
--- `:Nemeton conversation` is the transcript.
M.notes = with_session(function()
  require("nemeton.notes").open()
end)

--- Rewrites a comment already posted, from the line it sits on.
M.edit = with_session(function()
  pick_thread(function(thread)
    require("nemeton.edit").thread(thread)
  end)
end)

--- Deletes a comment already posted, after asking.
M.delete = with_session(function()
  pick_thread(function(thread)
    require("nemeton.edit").delete(thread)
  end)
end)

--- Approves the merge request, or takes the approval back.
---
--- One key for both, because it is one fact with two states and the
--- keyboard should not need two of them -- the same shape as the
--- resolve key on a thread. Which way it goes is read from
--- `user_has_approved`; a GitLab too old to send it is assumed not to
--- have your approval yet, and `:Nemeton unapprove` says so outright.
M.approve = with_session(function(want, cb)
  local mr = session.current
  local approval = require("nemeton.detail").approval(mr.approvals)
  if want == nil then
    want = not (approval and approval.mine)
  end
  glab.approve(mr.root, mr.iid, want, function(data, err)
    if not data then
      session.notify(
        ("could not %s: %s"):format(want and "approve" or "unapprove", tostring(err)),
        vim.log.levels.ERROR
      )
      return
    end
    session.notify(want and ("approved !" .. mr.iid) or ("approval withdrawn from !" .. mr.iid))
    session.refresh_approvals(cb)
  end)
end)

--- What CI did, job by job, in a float.
M.jobs = with_session(function()
  require("nemeton.jobs").open()
end)

--- Every thread on the merge request, in the quickfix list.
---
--- The counterpart to the gutter: the gutter says what is on the line
--- in front of you, and this says what is left everywhere else. A list
--- of *places*; `M.conversation` is the same threads read as what was
--- said, which is a different question.
M.threads = with_session(function()
  require("nemeton.qf").open()
end)

--- ...and the same threads to read rather than to walk.
M.conversation = with_session(function()
  require("nemeton.conversation").open()
end)

--- An overall comment -- on the merge request rather than on a line.
M.note = with_session(function()
  local mr = session.current
  require("nemeton.compose").open({
    title = ("!%d  overall comment"):format(mr.iid),
    on_draft = M.keep("kept for !" .. mr.iid, nil),
    on_submit = function(body)
      glab.create_note(mr.root, mr.iid, body, function(data, err)
        if not data then
          session.notify("could not post: " .. tostring(err), vim.log.levels.ERROR)
          return
        end
        session.notify("posted")
        session.refresh()
      end)
    end,
  })
end)

--- Types a token in, for this editor session only.
---
--- Rarely needed on purpose -- an expired token prompts by itself, at
--- the moment it fails -- but "I pasted the wrong one" and "I want to
--- review as the other account for a minute" both want a way to say so
--- without restarting Neovim.
function M.token()
  glab.set_token()
end

--- Drops it again, back to whatever the config and glab's keyring say.
function M.forget_token()
  glab.forget_token()
  session.notify("session token forgotten")
end

function M.status()
  local mr = session.current
  if not mr then
    session.notify("no merge request open")
    return
  end
  local open_count = 0
  for _, t in ipairs(mr.inline or {}) do
    if not t.resolved then
      open_count = open_count + 1
    end
  end
  local detail = require("nemeton.detail")
  local ci = detail.ci(mr)
  local approval = detail.approval(mr.approvals)
  local stats = detail.stats_text(mr.diff_stats)
  session.notify(
    ("!%d %s — %s → %s%s%s%s — %d inline (%d open), %d overall — comments %s"):format(
      mr.iid,
      mr.title or "",
      mr.source_branch or "?",
      mr.target_branch or "?",
      stats and (" — " .. stats) or "",
      ci and (" — CI " .. ci.word) or "",
      approval and (" — " .. approval.text) or "",
      #(mr.inline or {}),
      open_count,
      #(mr.overview or {}),
      mr.mode
    )
  )
end

-- The buffer-local keymaps, and the bookkeeping to take them away again.
--
-- Buffer-local rather than global because of what they mean: `]m` is
-- "next comment" only in a file that has comments in it, and stealing it
-- everywhere else -- in a terminal, in help, in the file you opened to
-- check something unrelated -- is how a review plugin becomes something
-- you turn off.
local attached = {}

--- Wraps a verb that takes a span of lines for use from an `x` mapping.
---
--- The selection is still live inside the callback: `v` is where it
--- started and `.` is where the cursor is, in either order. Left with
--- `<Esc>` first, because what opens next is a window and leaving
--- visual mode from inside it is not something the reviewer can do.
local function over_selection(fn)
  return function()
    local a, b = vim.fn.line("v"), vim.fn.line(".")
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
    fn(math.min(a, b), math.max(a, b))
  end
end

--- Binds the review keys on a file of the repository, and binds them
--- again every time something else has had a turn at that buffer.
---
--- Again, rather than once: a filetype plugin maps into the buffer it
--- is loaded for, and Neovim's own ftplugin/python.vim takes `]m` and
--- `[m` for its method motions. It runs on every FileType -- which
--- means on every re-read, and a checkout is a re-read of every file it
--- changed, which is most of the ones you had open. Attaching once left
--- the ftplugin with the last word: `]m` walked functions again, and
--- the marker in the gutter it was supposed to walk to sat there being
--- ignored. Rebinding is eighteen `keymap.set` calls, which is cheaper
--- than being wrong.
local function attach(bufnr)
  if not session.current then
    return
  end
  if not session.relpath(bufnr) then
    return
  end
  local k = config.keys.session
  local bindings = {
    { k.toggle, M.toggle, "comments on/off" },
    { k.expand, M.expand, "conversations inline" },
    { k.peek, M.peek, "peek at the thread here" },
    { k.comment, M.comment, "comment on this line" },
    { k.comment, over_selection(M.comment), "comment on these lines", "x" },
    { k.reply, M.reply, "reply to the thread here" },
    { k.edit, M.edit, "edit a comment in the thread here" },
    { k.delete, M.delete, "delete a comment in the thread here" },
    { k.suggest, over_selection(M.suggest), "suggest a change to these lines", "x" },
    { k.resolve, M.resolve, "resolve the thread here" },
    { k.description, M.description, "what this merge request is for" },
    { k.notes, M.notes, "every comment on the merge request" },
    { k.threads, M.threads, "every thread on the merge request" },
    { k.jobs, M.jobs, "what CI did, job by job" },
    {
      k.publish,
      function()
        M.publish()
      end,
      "send every comment kept unsent",
    },
    {
      k.approve,
      function()
        M.approve()
      end,
      "approve, or take it back",
    },
    { k.close, M.close, "end the review" },
    { k.next, M.next, "next comment" },
    { k.prev, M.prev, "previous comment" },
  }
  for _, b in ipairs(bindings) do
    if b[1] and b[1] ~= "" then
      vim.keymap.set(
        b[4] or "n",
        b[1],
        b[2],
        { buffer = bufnr, silent = true, desc = "nemeton: " .. b[3] }
      )
    end
  end
  attached[bufnr] = bindings
  session.redraw(bufnr)
end

local function detach(bufnr)
  local bindings = attached[bufnr]
  if not bindings then
    return
  end
  for _, b in ipairs(bindings) do
    if b[1] and b[1] ~= "" then
      pcall(vim.keymap.del, b[4] or "n", b[1], { buffer = bufnr })
    end
  end
  attached[bufnr] = nil
  marks.clear(bufnr)
end

--- The one review key that is not about the line under the cursor, and
--- so the one that is bound everywhere.
---
--- `description` opens the merge request's own window -- approvals, CI,
--- what is unsent, the keys that act on the whole review -- and the
--- places you reach for it from are exactly the places the buffer-local
--- keys are not: the quickfix list of threads, the comments window, the
--- terminal you ran the tests in, a file that is not in this repository
--- at all. Bound while a review is open and taken away with it, so that
--- nothing of this plugin is on a key when no review is on.
local function global_key(bind)
  local key = config.keys.session.description
  if not key or key == "" then
    return
  end
  if bind then
    vim.keymap.set("n", key, M.description, {
      silent = true,
      desc = "nemeton: the merge request",
    })
  else
    pcall(vim.keymap.del, "n", key)
  end
end

function M.attach_all()
  global_key(true)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      attach(bufnr)
    end
  end
end

function M.detach_all()
  global_key(false)
  for bufnr in pairs(vim.deepcopy(attached)) do
    detach(bufnr)
  end
end

local SUBCOMMANDS = {
  list = M.list,
  open = M.open,
  close = M.close,
  comments = M.toggle,
  expand = M.expand,
  peek = M.peek,
  create = M.create,
  comment = function()
    M.comment()
  end,
  reply = M.reply,
  resolve = M.resolve,
  note = M.note,
  refresh = M.refresh,
  status = M.status,
  edit = M.edit,
  delete = M.delete,
  suggest = function()
    M.suggest()
  end,
  jobs = M.jobs,
  conversation = M.conversation,
  publish = function()
    M.publish()
  end,
  description = M.description,
  notes = M.notes,
  threads = M.threads,
  approve = function()
    M.approve(true)
  end,
  unapprove = function()
    M.approve(false)
  end,
  token = M.token,
  ["forget-token"] = M.forget_token,
}

function M.command(opts)
  ready()
  local args = opts.fargs or {}
  if #args == 0 then
    return M.list()
  end
  local fn = SUBCOMMANDS[args[1]]
  if not fn then
    session.notify(
      "unknown: " .. args[1] .. " — try " .. table.concat(vim.tbl_keys(SUBCOMMANDS), ", "),
      vim.log.levels.ERROR
    )
    return
  end
  return fn(args[2])
end

function M.complete(arg_lead)
  return vim.tbl_filter(function(s)
    return s:find(arg_lead, 1, true) == 1
  end, vim.tbl_keys(SUBCOMMANDS))
end

--- Overlays `src` onto `dst` in place.
---
--- In place, and not `vim.tbl_deep_extend`, because every module in this
--- plugin holds a reference to the config table it required at load
--- time: replacing that table would leave nine modules reading the old
--- one. Lists are replaced wholesale rather than merged -- a user who
--- writes `fallbacks = { "trunk" }` means that list, not that list
--- appended to ours.
local function merge(dst, src)
  for k, v in pairs(src) do
    if type(v) == "table" and type(dst[k]) == "table" and not vim.islist(v) then
      merge(dst[k], v)
    else
      dst[k] = v
    end
  end
end

--- `require("nemeton").setup { ... }` -- anything in `config.lua`, in the
--- same shape. The common one is a self-managed host and where to find a
--- token:
---
---   require("nemeton").setup({
---     glab = {
---       host = "gitlab.example.com",
---       token = function() return vim.trim(vim.fn.system("pass show gitlab")) end,
---     },
---   })
---
--- Safe to call twice, and safe not to call at all: `:Nemeton` and the
--- global key call it themselves if a plugin manager has not.
function M.setup(opts)
  wired = true
  if opts then
    merge(config, opts)
    -- The host and the token are resolved once and cached, and this is
    -- the moment they changed.
    glab.reset_credentials()
  end

  if not supported() then
    session.notify(("needs Neovim %d.%d or newer"):format(FLOOR[1], FLOOR[2]), vim.log.levels.ERROR)
    return
  end

  marks.setup_highlights()
  local group = vim.api.nvim_create_augroup("Nemeton", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = marks.setup_highlights,
  })
  -- Every file opened while a review is on gets its markers and its
  -- keys, whether it was opened before the session or three minutes
  -- into it -- which is the whole point of a session being a mode the
  -- editor is in rather than a property of one buffer.
  --
  -- FileType among them, and last on purpose: it is the event a
  -- filetype plugin maps on, and this autocommand is created after the
  -- runtime's, so what it binds is what is left standing.
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWinEnter", "FileType" }, {
    group = group,
    callback = function(ev)
      if session.current then
        attach(ev.buf)
        session.redraw(ev.buf)
      end
    end,
  })
  -- The conversations are drawn to the width of the editor, so that
  -- band is the wrong length the moment the editor is another width --
  -- and they are wrapped to the width of the window, which a split or a
  -- drag changes without the editor changing size at all.
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = group,
    callback = function()
      if session.current then
        session.redraw_all()
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    callback = function(ev)
      attached[ev.buf] = nil
    end,
  })

  -- The plugin file bound the default; a `setup{}` that moves the key
  -- takes that one back rather than leaving the editor with both.
  local bound = vim.g.nemeton_global_key
  local k = config.keys.global.list
  if bound and bound ~= k then
    pcall(vim.keymap.del, "n", bound)
    vim.g.nemeton_global_key = nil
  end
  if k and k ~= "" and vim.g.nemeton_global_key ~= k then
    vim.keymap.set("n", k, M.list, { silent = true, desc = "nemeton: merge requests" })
    vim.g.nemeton_global_key = k
  end
end

return M
