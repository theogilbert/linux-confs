-- The diff view: your own buffer, annotated against a revision.
--
--   :Uatis [<gitref>]
--
-- The buffer you are already in stays exactly where it is -- same window,
-- same cursor, same undo history, still writable -- and what it replaced
-- is drawn around it, or beside it.
--
-- The new side is not a revision: it is the live buffer, unsaved edits
-- included. That is the point. "What have I changed since <ref>" is a
-- question about work in progress, and answering it from the file on disk
-- would be answering a different one.

local config = require("uatis.config")
local git = require("uatis.git")
local diff = require("uatis.diff")
local overlay = require("uatis.overlay")
local oldside = require("uatis.oldside")
local ui = require("uatis.ui")
local keys = require("uatis.keys")

local M = {}

local views = {} -- bufnr -> view

function M.get(bufnr)
  local v = views[bufnr]
  if v and not vim.api.nvim_buf_is_valid(bufnr) then
    views[bufnr] = nil
    return nil
  end
  return v
end

-- ------------------------------------------------------------------
-- Rendering
-- ------------------------------------------------------------------

local function buffer_text(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

--- Recomputes and redraws. Cheap to call: the blob is cached by content in
--- `git.lua` and the structural backend caches by input text, so a redraw
--- triggered by typing costs a diff and nothing else.
---
--- Guarded by a generation counter for the same reason the review is: the
--- structural backend is a subprocess, so a slow result from three
--- keystrokes ago must not land on top of a fast one from now.
local function render(view)
  view.gen = (view.gen or 0) + 1
  local gen = view.gen

  local function current()
    return views[view.bufnr] == view
      and view.gen == gen
      and vim.api.nvim_buf_is_valid(view.bufnr)
  end

  local new_text = buffer_text(view.bufnr)
  -- Fetched by resolved sha, not by the name it was asked for. `git.blob`
  -- caches on the rev string it is given, so a symbolic ref would be read
  -- once and then answered from cache for the rest of the session --
  -- silently stale the moment a commit lands. Pinning also makes the view
  -- mean one fixed thing while it is open; re-run the command to re-point
  -- it.
  -- The OLD path, where the two differ. A path is not an identity: a file
  -- the branch renamed has no blob under its new name at the fork point,
  -- so comparing name to name reports a pure `git mv` as a brand new file
  -- and every line of it as added. Only a caller working from a patch
  -- knows a rename happened -- git's rename detection is a property of a
  -- diff, not of a blob lookup -- so the side pane hands it over.
  git.blob(view.root, view.rev, view.old_path or view.relpath, function(old_text)
    if not current() then
      return
    end
    -- A path with no blob at that revision is a file the branch ADDED, and
    -- "all of this is new since <ref>" is both true and the answer worth
    -- drawing -- the side pane opens added files as a matter of course, so
    -- refusing here would make a third of a merge request unreachable. An
    -- empty old side says exactly that, in the same green as every other
    -- addition, and the header's `+N -0` says it again.
    -- Whether the path existed there at all, kept for the list: a file
    -- with no blob at the fork point is one the branch added, and the list
    -- cannot tell that from an empty old side once it has been defaulted.
    view.new_file = old_text == nil
    old_text = old_text or ""
    diff.compute(old_text, new_text, {
      backend = view.backend,
      path = view.relpath,
      bufnr = view.bufnr,
    }, function(result)
      if not current() then
        return
      end
      local added, removed = 0, 0
      for _, h in ipairs(result.hunks or {}) do
        added = added + h.count_b
        removed = removed + h.count_a
      end
      local moved = view.added ~= added or view.removed ~= removed
      view.added, view.removed = added, removed
      view.engine, view.dropped = result.engine, result.dropped
      -- Structural was asked for and difftastic could not answer. Said in
      -- the header rather than notified: this is a fact about what is on
      -- screen, and it would otherwise be a message per keystroke.
      view.unavailable = result.unavailable
      -- ...and difftastic answering with no parser for this file, which
      -- is a different thing and reads differently: what it compared were
      -- words, so the marks are word-precise and no more. Said in the
      -- header for the same reason, and because a reader who is not told
      -- reads a line-shaped answer as the structural one.
      view.prose = result.prose
      -- Kept for the old-revision window: it is the text this render was
      -- measured against, and the hunks are what tell it which line
      -- answers to which. Held on the view rather than fetched again so
      -- the two windows can never be describing different revisions.
      view.old_text, view.hunks = old_text, result.hunks or {}
      -- ...and the backend's row alignment where it has one, which is a
      -- better answer than the hunk shapes for "which line answers to
      -- this one" -- and the same one the rendering used.
      view.pairs, view.anchor = result.pairs, result.anchor
      -- ...and what it said about the OLD side, for the window that shows
      -- it: difftastic tints the tokens it called changed and leaves the
      -- rest of a removed line alone, which is a statement only it can
      -- make. `vim.diff` has none to make, so there is nothing to store
      -- and the old window falls back to marking whole lines.
      view.precise = result.precise
      local dels = {}
      for _, span in ipairs(result.spans or {}) do
        if span.kind == "delete" then
          dels[span.line] = dels[span.line] or {}
          table.insert(dels[span.line], span)
        end
      end
      view.del_spans = result.precise and dels or nil
      -- ...and the same question asked of the old side, which the old
      -- window draws: `render` is where the two blocks are compared, so
      -- it is where the answer is.
      view.anchors, view.del_fine = overlay.render(view.bufnr, view.win, result,
        vim.split(old_text, "\n", { plain = true }),
        -- Side by side, the old revision is a window of its own: drawing
        -- it here too would say everything twice.
        { before = view.layout ~= "side" })
      oldside.refresh(view)
      -- Counted so a test can wait for a redraw to have happened rather
      -- than for a wall-clock guess, the same way the review's panes do.
      view.renders = (view.renders or 0) + 1
      -- The list measures what this view measures, and only this view can
      -- see an edit that has not been saved: `git diff` reads the disk.
      -- Told rather than polled, and only when the numbers actually moved,
      -- so a burst of keystrokes redraws the list once.
      if moved or view.renders == 1 then
        require("uatis.pane").recount(view)
      end
      vim.cmd("redrawstatus")
    end)
  end)
end

--- Coalesces a burst of buffer changes into one redraw.
---
--- Every keystroke in insert mode fires TextChangedI, and in structural
--- mode each one would be a difftastic subprocess. Waiting for a pause
--- also matches how the result is read: a diff of a half-typed line is
--- noise, not information.
local function schedule_render(view)
  if not view.timer then
    view.timer = vim.uv.new_timer()
  end
  view.timer:stop()
  view.timer:start(150, 0, vim.schedule_wrap(function()
    if views[view.bufnr] == view then
      render(view)
    end
  end))
end

-- ------------------------------------------------------------------
-- Lifetime
-- ------------------------------------------------------------------

function M.close(bufnr)
  local view = views[bufnr]
  if not view then
    return
  end
  views[bufnr] = nil

  -- The old revision is an accessory to this view, not a file the user
  -- opened: leaving it behind would leave a window onto a revision with
  -- nothing to compare it against, and a `q` mapping pointing at a view
  -- that no longer exists.
  oldside.close(view)

  if view.timer then
    view.timer:stop()
    view.timer:close()
    view.timer = nil
  end
  if view.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, view.augroup)
  end
  if vim.api.nvim_buf_is_valid(bufnr) then
    overlay.clear(bufnr)
    keys.restore(bufnr, "n", view.saved_keys)
  end
  -- The window may have moved on to another buffer, or gone entirely.
  -- Restoring a winbar onto a window showing something else would put a
  -- blank line above unrelated code.
  if view.win and vim.api.nvim_win_is_valid(view.win)
    and vim.api.nvim_win_get_buf(view.win) == bufnr then
    vim.wo[view.win].winbar = view.saved_winbar
  end
end

--- Every open view measuring `root` at `rev`.
---
--- Asked by the list, which measures the same comparison and has to say
--- what these buffers say rather than only what git does, and asked by
--- `close_all` below, which ends them.
function M.matching(root, rev)
  local out = {}
  for bufnr, view in pairs(views) do
    if view.root == root and view.rev == rev and vim.api.nvim_buf_is_valid(bufnr) then
      table.insert(out, view)
    end
  end
  return out
end

--- Every view measuring the same comparison -- same repository, same
--- revision -- closed together.
---
--- Half of what "stop reviewing" means. A comparison follows the reader
--- from file to file while it is on, so by the time they turn it off it
--- is on five buffers; closing only the one they happen to be standing in
--- would leave the mode half up, with the other four still annotated and
--- no gesture that finishes them.
---
--- Matched on the revision as well as the root, so a view pinned by hand
--- to some other revision -- `:Uatis 16859ad` in a window on the same
--- repository -- is left where it was put. One pinned to the SAME
--- revision is not distinguishable from part of the review, and is not
--- worth distinguishing.
function M.close_all(root, rev)
  -- Collected first: closing unregisters, and removing entries from a
  -- table being iterated is not something Lua promises anything about.
  local doomed = M.matching(root, rev)
  for _, view in ipairs(doomed) do
    M.close(view.bufnr)
  end
  return #doomed
end

--- ...and the other half: the list that was following you with it.
---
--- The list is what a review IS -- which files, against which revision,
--- and the watcher that annotates them as you arrive. Leaving it up would
--- annotate the next file you opened, which is the opposite of what the
--- reader just asked for.
function M.stop(view)
  local root, rev = view.root, view.rev
  -- Required at call time: the pane requires this module to open the files
  -- it lists, and asking for it at the top would be a cycle.
  local pane = require("uatis.pane")
  local here = pane.get()
  -- Every list of this review, and not only the one in this tab: the
  -- same review reached from two tabs -- `:tab split` on a file being
  -- reviewed, then the list put up there as well -- left the other one
  -- running, still annotating each file opened in that tab, with the
  -- review that owned it gone.
  --
  -- The revision is not asked about for the list in THIS tab. A tab
  -- holds one list and it is the review the reader is standing in; the
  -- two revisions can drift apart -- a view pinned by `:Uatis <ref>`
  -- beside a list that followed a base change, a list re-read while the
  -- view was resolving -- and a list left behind by a key that says
  -- "stop" goes on annotating every file opened after it. Same
  -- repository is the whole test there. Elsewhere the revision has to
  -- match, since another tab may be reviewing the same repository
  -- against something else on purpose.
  for _, list in ipairs(pane.all()) do
    if list.root == root and (list == here or list.rev == rev) then
      pane.close(list)
    end
  end
  return M.close_all(root, rev)
end

--- Inline (the old side drawn around your buffer) or side by side (the
--- old side in a window of its own).
---
--- The same comparison either way -- this is a layout, not a mode: the
--- marks on your buffer are identical, and what moves is where the code
--- they replaced is drawn. Which one you want depends on the change: a
--- scatter of small edits reads better in place, and a rewritten file
--- reads better as two files.
local function set_layout(view, layout)
  view.layout = layout
  if layout == "side" then
    oldside.open(view)
  else
    oldside.close(view)
  end
  render(view)
end

local function toggle_layout(view)
  set_layout(view, view.layout == "side" and "inline" or "side")
end

local function toggle_backend(view)
  view.backend = view.backend == "line" and "struct" or "line"
  render(view)
end

--- Next or previous changed chunk. Stops at the ends rather than wrapping,
--- the same as the review: running off the end is a useful signal that
--- there is nothing more, and it leaves `]c` behaving like a motion.
local function step_hunk(view, dir)
  local win = view.win
  if not win or not vim.api.nvim_win_is_valid(win) or #(view.anchors or {}) == 0 then
    return
  end
  local cur = vim.api.nvim_win_get_cursor(win)[1]
  local target
  if dir > 0 then
    for _, a in ipairs(view.anchors) do
      if a > cur then
        target = a
        break
      end
    end
  else
    for i = #view.anchors, 1, -1 do
      if view.anchors[i] < cur then
        target = view.anchors[i]
        break
      end
    end
  end
  if not target then
    return
  end
  vim.api.nvim_win_set_cursor(win, { math.min(target, vim.api.nvim_buf_line_count(view.bufnr)), 0 })
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! zz")
  end)
end

--- Next or previous changed file, from the buffer you are reading.
---
--- Reads the list if there is not one yet, and does NOT put a window up
--- for it: the key asked which file comes next, not for somewhere to
--- stand and look at a list. `<leader>gf` is the window, on and off
--- again.
local function step_file(dir)
  local pane = require("uatis.pane")
  local list = pane.get()
  if list and (list.renders or 0) > 0 then
    pane.step_file(list, dir)
    return
  end
  pane.list({
    on_ready = function(p)
      pane.step_file(p, dir)
    end,
  })
end

--- ...and the same for stepping the review a commit at a time, which is
--- a question about the list too and so needs one to exist.
local function step_commit(dir)
  local pane = require("uatis.pane")
  local list = pane.get()
  if list and (list.renders or 0) > 0 then
    pane.step_commit(list, dir)
    return
  end
  pane.list({
    on_ready = function(p)
      pane.step_commit(p, dir)
    end,
  })
end

--- ...and turning that mode on from a file, which needs a list for the
--- same reason: which commits there are is a fact about the review.
local function toggle_commits()
  local pane = require("uatis.pane")
  local list = pane.get()
  if list and (list.renders or 0) > 0 then
    pane.toggle_commits(list)
    return
  end
  pane.list({
    on_ready = function(p)
      pane.toggle_commits(p)
    end,
  })
end

local function setup_keymaps(view)
  local k = config.keys.view
  view.saved_keys = keys.apply(view.bufnr, "n", {
    { lhs = k.hunk_next, rhs = function() step_hunk(view, 1) end,
      opts = { desc = "uatis: next chunk" } },
    { lhs = k.hunk_prev, rhs = function() step_hunk(view, -1) end,
      opts = { desc = "uatis: previous chunk" } },
    { lhs = k.diff_mode, rhs = function() toggle_backend(view) end,
      opts = { desc = "uatis: toggle line / structural diff" } },
    { lhs = k.layout, rhs = function() toggle_layout(view) end,
      opts = { desc = "uatis: switch between in-place and side-by-side" } },
    -- Required at call time: `pane` requires this module to open the
    -- files it lists, and asking for it at the top would be a cycle.
    { lhs = k.files, rhs = function() require("uatis.pane").toggle() end,
      opts = { desc = "uatis: show or hide the files changed since this revision" } },
    { lhs = k.file_next, rhs = function() step_file(1) end,
      opts = { desc = "uatis: next changed file" } },
    { lhs = k.file_prev, rhs = function() step_file(-1) end,
      opts = { desc = "uatis: previous changed file" } },
    -- The same list, one size up: `]c` is the next change in this file,
    -- `]C` the next change to the branch.
    { lhs = k.commit_next, rhs = function() step_commit(1) end,
      opts = { desc = "uatis: the review one commit forward" } },
    { lhs = k.commit_prev, rhs = function() step_commit(-1) end,
      opts = { desc = "uatis: the review one commit back" } },
    { lhs = k.commit_view, rhs = function() toggle_commits() end,
      opts = { desc = "uatis: read the review one commit at a time" } },
    -- Off by default, and skipped when it is: `<leader>gu` already ends
    -- the review from anywhere, including from in here. Bound for anyone
    -- who sets `keys.view.quit` to a key of their own.
    { lhs = k.quit, rhs = function() M.stop(view) end,
      opts = { desc = "uatis: stop reviewing" } },
  })
end

local function setup_watchers(view)
  -- `on_lines` rather than TextChanged, because TextChanged only fires for
  -- edits the user made: a formatter, an LSP code action or any other
  -- plugin writing through nvim_buf_set_lines changes the new side without
  -- firing it, and the overlay would go on describing text that is no
  -- longer there. `on_lines` sees every change to the buffer whatever made
  -- it.
  --
  -- Wrapped in a function because the attachment has to be renewable: see
  -- `on_detach`.
  local function attach()
    vim.api.nvim_buf_attach(view.bufnr, false, {
      on_lines = function()
        -- Detaches itself once the view is gone: a buffer that outlives
        -- the view should not keep waking a callback up.
        if views[view.bufnr] ~= view then
          return true
        end
        -- A fast context -- no API calls here. Arming a libuv timer is
        -- allowed, and its callback is scheduled back onto the main loop.
        schedule_render(view)
      end,
      -- Detached is not the same as gone. `:e` re-reads the file into the
      -- SAME buffer, and Neovim drops every attachment doing it -- so
      -- reloading a file ended the review, and reloading is exactly what
      -- a reader does when something else has written the file they are
      -- reviewing.
      --
      -- Asked on the next tick, by when the reload has finished: a buffer
      -- still loaded is a buffer that came back, and it gets its
      -- attachment and its marks again rather than a teardown. The marks
      -- are not optional there -- re-reading replaces the buffer's
      -- contents, and extmarks go with the lines they were on.
      on_detach = function()
        vim.schedule(function()
          if views[view.bufnr] ~= view then
            return
          end
          if vim.api.nvim_buf_is_valid(view.bufnr)
            and vim.api.nvim_buf_is_loaded(view.bufnr) then
            attach()
            render(view)
            return
          end
          M.close(view.bufnr)
        end)
      end,
    })
  end
  attach()

  view.augroup = vim.api.nvim_create_augroup(
    "UatisInline" .. tostring(view.bufnr), { clear = true })

  -- Leaving the buffer behind in this window ends the view: the winbar
  -- belongs to the window, and it would otherwise sit above whatever came
  -- next, describing a file that is no longer there.
  -- Side by side, the two windows are one view of one comparison, so the
  -- old one follows the cursor rather than being scrolled by hand. Bound
  -- to the cursor and not to `scrollbind`, which pairs the windows by
  -- SCREEN line: the two files are different lengths, so it drifts by
  -- exactly as much as the change is worth looking at.
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = view.augroup,
    buffer = view.bufnr,
    callback = function()
      if views[view.bufnr] ~= view or view.layout ~= "side" then
        return
      end
      if view.win and vim.api.nvim_win_is_valid(view.win)
        and vim.api.nvim_get_current_win() == view.win then
        oldside.sync(view, vim.api.nvim_win_get_cursor(view.win)[1])
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "BufWinLeave", "BufUnload" }, {
    group = view.augroup,
    buffer = view.bufnr,
    callback = function(ev)
      vim.schedule(function()
        -- ...but unloading is not leaving. `:e` unloads the buffer and
        -- reads it straight back into the same buffer number and the same
        -- window, so by this tick there is nothing here to close --
        -- `on_detach` has already put the attachment and the marks back.
        -- `BufWinLeave` is the honest signal for the window losing the
        -- buffer, and it does not fire for a reload.
        if ev.event == "BufUnload" and views[view.bufnr] == view
          and vim.api.nvim_buf_is_valid(view.bufnr)
          and vim.api.nvim_buf_is_loaded(view.bufnr) then
          return
        end
        M.close(view.bufnr)
      end)
    end,
  })
end

-- ------------------------------------------------------------------
-- Entry point
-- ------------------------------------------------------------------

--- What the working tree is sitting on, for the side-by-side winbar: the
--- branch name, or the sha where there is no branch to name. Asked once
--- per view rather than per redraw -- it answers a question about the
--- checkout, which the view is pinned to for as long as it is open.
local function resolve_head(view)
  git.abbrev_ref(view.root, "HEAD", function(name)
    if views[view.bufnr] ~= view then
      return
    end
    if name and name ~= "" and name ~= "HEAD" then
      view.head = "on " .. name
      vim.cmd("redrawstatus")
      return
    end
    -- Detached: there is no branch, and the sha is the only true answer.
    git.rev_parse(view.root, "HEAD", function(sha)
      if views[view.bufnr] == view and sha then
        view.head = "at " .. sha:sub(1, 7)
        vim.cmd("redrawstatus")
      end
    end)
  end)
end

--- Whether a view can be put on this buffer at all: a real file, with a
--- name. The repository it has to be inside is a question for git, and
--- that is asked below; this is the part that can be answered on the spot,
--- which is what a caller needs to know before it decides what to do
--- instead.
function M.can_open(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return vim.api.nvim_buf_is_valid(bufnr)
    and vim.bo[bufnr].buftype == ""
    and vim.api.nvim_buf_get_name(bufnr) ~= ""
end

--- Where `file` sits inside `root`, or nil when it does not sit inside it
--- at all.
---
--- Both sides are resolved the same way before the prefix is taken off:
--- git reports the toplevel with symlinks resolved, and a buffer opened
--- through a symlinked path otherwise fails to match a root it really is
--- under. Shared with the pane, which asks the same question of every
--- buffer you enter while a review is running.
function M.relpath(root, file)
  if not file or file == "" then
    return nil
  end
  local full = vim.fs.normalize(vim.fn.resolve(vim.fn.fnamemodify(file, ":p")))
  local top = vim.fs.normalize(vim.fn.resolve(root))
  if full:sub(1, #top + 1) ~= top .. "/" then
    return nil
  end
  return full:sub(#top + 2)
end

--- Resolves a revision the plain way: the ref is both what gets fetched
--- and what the winbar says.
function M.ref_resolver(ref)
  return function(root, cb)
    git.rev_parse(root, ref, function(sha)
      if not sha then
        vim.notify("uatis: unknown revision '" .. ref .. "'", vim.log.levels.ERROR)
        cb(nil)
        return
      end
      cb(ref, sha)
    end)
  end
end

--- Annotates the current buffer against `ref`.
---
--- Re-running with a different ref replaces the comparison in place rather
--- than stacking a second view on the same buffer.
---
--- `opts.resolve(root, cb(label, sha))` overrides how the revision is
--- found, because the name worth SHOWING and the revision worth FETCHING
--- are not always the same string: a base-branch view fetches the fork
--- point and says `main`, which is what the reviewer chose and what they
--- are thinking in. Resolving needs the repo root, which is worked out
--- here, so it is a callback rather than an argument.
function M.open(ref, opts)
  opts = vim.tbl_extend("keep", opts or {}, { ref = ref })
  local bufnr = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()

  -- A file the branch DELETED has no buffer to annotate -- there is
  -- nothing in your tree to put marks on -- so the caller hands over the
  -- path and the root itself and the buffer is a scratch one, empty,
  -- standing for a file that is not there. Everything below then works
  -- unchanged: an empty new side against a revision that has content is a
  -- file entirely removed, which is exactly what happened.
  if opts.path and opts.root then
    return M.attach(bufnr, win, opts.root, opts.path, opts)
  end

  -- Otherwise it has to be a real file inside a repository: a scratch,
  -- terminal or help buffer has no path to compare against.
  if vim.bo[bufnr].buftype ~= "" then
    vim.notify("uatis: not a file buffer", vim.log.levels.ERROR)
    return
  end
  local file = vim.api.nvim_buf_get_name(bufnr)
  if file == "" then
    vim.notify("uatis: this buffer has no file", vim.log.levels.ERROR)
    return
  end

  git.root(file, function(root)
    if not root then
      -- Named, because the answer is about a path and not about the
      -- editor: the file being read and the directory `:cd` last left
      -- the editor in are different questions with different answers,
      -- and a bare "not inside a git repository" says which of the two
      -- was asked about only to whoever wrote it.
      vim.notify("uatis: " .. file .. " is not inside a git repository",
        vim.log.levels.ERROR)
      return
    end
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end

    local relpath = M.relpath(root, file)
    if not relpath then
      vim.notify("uatis: " .. file .. " is not inside " .. root, vim.log.levels.ERROR)
      return
    end
    M.attach(bufnr, win, root, relpath, opts)
  end)
end

--- Annotates `bufnr` as `relpath` inside `root`, against whatever
--- `opts.resolve` names. Split out of `open` because a file the branch
--- deleted arrives here directly: there is no buffer name to work a path
--- out of, and the pane knows it already.
function M.attach(bufnr, win, root, relpath, opts)
  opts = opts or {}
  local resolve = opts.resolve or M.ref_resolver(opts.ref)
  do
    resolve(root, function(label, sha)
      if not label or not sha then
        return
      end
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end

      -- Re-running over a buffer that already has a view re-points it
      -- rather than stacking a second one: the mappings, the winbar and
      -- the buffer attachment are already in place and correct.
      --
      -- `on_open` still runs. It is not "a view was created", it is
      -- "there is now a view here measuring against this" -- which is
      -- how the changed-file list learns what it is beside, and is just
      -- as true of the second `:Uatis <ref>` in a buffer as of the
      -- first. Returning before it left the list pinned to whatever the
      -- reader had asked for previously, showing an empty pane next to a
      -- buffer full of marks.
      local existing = views[bufnr]
      if existing then
        existing.ref, existing.rev, existing.win = label, sha, win
        existing.old_path = opts.old_path
        existing.tracks_base = opts.tracks_base or false
        existing.at_commit = opts.at_commit
        render(existing)
        if opts.on_open then
          opts.on_open(existing)
        end
        return
      end

      local view = {
        bufnr = bufnr,
        win = win,
        root = root,
        relpath = relpath,
        old_path = opts.old_path,
        ref = label,
        rev = sha,
        -- The commit whose content this buffer holds, when it is not
        -- the reader's own file but a copy of it as it was. What the
        -- winbar says so nobody types into a rendering and wonders why
        -- it will not take.
        at_commit = opts.at_commit,
        -- Whether this comparison FOLLOWS the base branch or merely
        -- happens to be pointed where the base branch pointed once.
        -- Choosing another one re-points the first and leaves the second
        -- alone: `:Uatis 16859ad` named a revision, and a view that
        -- wandered off the revision you named would be a different tool.
        tracks_base = opts.tracks_base or false,
        backend = config.diff.default_backend,
        layout = "inline",
        added = 0,
        removed = 0,
        dropped = 0,
        anchors = {},
        gen = 0,
        -- Never save our own expression as "what was here before". A
        -- window that opens one diffed file after another -- which is what
        -- the side pane does -- hands the next view the winbar the last
        -- one left behind, and restoring THAT at the end leaves the option
        -- set. It would evaluate to nothing, but 'winbar' occupies a
        -- screen line whenever it is non-empty, so the file would keep a
        -- blank line above it for the rest of the session.
        saved_winbar = vim.wo[win].winbar ~= ui.VIEW_WINBAR
          and vim.wo[win].winbar or "",
      }
      views[bufnr] = view

      overlay.setup_highlights()
      resolve_head(view)
      setup_keymaps(view)
      setup_watchers(view)
      vim.wo[win].winbar = ui.VIEW_WINBAR
      render(view)
      -- Anything that needs the view to EXIST goes here, not on the line
      -- after the call: opening one is two git subprocesses deep, so a
      -- caller that looks for it straight away finds nothing.
      if opts.on_open then
        opts.on_open(view)
      end
    end)
  end
end

--- Re-points every base-tracked view in `root` at `label`/`sha`, and
--- redraws it.
---
--- Called when the base branch changes. Handed the resolved pair rather
--- than resolving per view: one choice of base branch is one fork point,
--- and re-resolving per buffer would let a commit landing mid-answer
--- leave two open views measuring against different revisions.
function M.repoint(root, label, sha)
  for bufnr, view in pairs(views) do
    if not vim.api.nvim_buf_is_valid(bufnr) then
      views[bufnr] = nil
    elseif view.tracks_base and view.root == root
      and (view.ref ~= label or view.rev ~= sha) then
      view.ref, view.rev = label, sha
      render(view)
    end
  end
end

--- Turns the view on the current buffer off if it has one, on if it does
--- not. Returns true when it turned one on -- which is a guess, since
--- opening is asynchronous and can still fail on a buffer that has no path
--- in the repository; the failure notifies for itself.
---
--- Toggling off closes this buffer's view alone. `M.stop` is the one that
--- ends the review -- the list and every view measuring the same
--- comparison -- and is what the key and `toggle_diff` reach for; this is
--- the narrow door, for a caller that means one buffer and says so.
function M.toggle(ref, opts)
  local bufnr = vim.api.nvim_get_current_buf()
  if views[bufnr] then
    M.close(bufnr)
    return false
  end
  M.open(ref, opts)
  return true
end

return M
