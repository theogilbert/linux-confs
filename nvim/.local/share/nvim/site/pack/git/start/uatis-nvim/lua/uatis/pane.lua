-- The side pane: every file that changed since the fork point, beside the
-- one you are reading.
--
-- Every file it opens is your real, editable buffer with the diff drawn
-- on it -- no scratch copies, no second idea of what a file is. Selecting
-- a row and pressing ]f route through the same function, so there is only
-- ever one idea of what "go to a file" means.
--
-- It takes its revision from the view that was on screen when it opened
-- rather than resolving one of its own. That is what keeps the list and
-- the overlay beside it describing the same comparison: they are pinned to
-- one sha. Nothing moves that pin except choosing a different base branch,
-- which moves the views beside it in the same breath.

local config = require("uatis.config")
local git = require("uatis.git")
local patch = require("uatis.patch")
local filelist = require("uatis.filelist")
local ui = require("uatis.ui")
local view_mod = require("uatis.view")
local base = require("uatis.base")
local keys = require("uatis.keys")

local M = {}

local panes = {} -- tabpage -> pane

-- Defined further down, among the other ways a review takes a buffer in.
-- Re-reading the list is one of them, and that is written above them.
local follow_visible

function M.get(tab)
  return panes[tab or vim.api.nvim_get_current_tabpage()]
end

--- Every list open right now, one per tab.
---
--- A snapshot, because closing one unregisters it and removing entries
--- from a table being iterated is not something Lua promises anything
--- about.
function M.all()
  local out = {}
  for _, pane in pairs(panes) do
    table.insert(out, pane)
  end
  return out
end

-- ------------------------------------------------------------------
-- Contents
-- ------------------------------------------------------------------

--- What the list shows: what git says the branch changed, and what the
--- open buffers say it is changing right now.
---
--- Two sources because `git diff` can only see the disk. The overlay
--- beside the list measures the LIVE buffer, unsaved edits and all, so a
--- list built from git alone reports `(no changes)` next to a window full
--- of them -- and a file git has never seen is missing from its answer
--- whatever you do. Wherever a view is open on this comparison, its own
--- counts win: they are the ones drawn on the screen.
---
--- Sorted by path, which is the order git gives and the order the tree
--- drawing relies on.
local function compose(pane)
  local files, by_path = {}, {}
  -- A commit on show is finished. What it changed cannot depend on what
  -- is unsaved now, or on a file git has never been told about, so the
  -- two sources that answer for the working tree are left out and the
  -- list is exactly the commit's own diff.
  if pane.commit then
    for _, f in ipairs(pane.tracked or {}) do
      table.insert(files, vim.tbl_extend("force", {}, f))
    end
    table.sort(files, function(a, b) return a.path < b.path end)
    return files
  end
  for _, f in ipairs(pane.tracked or {}) do
    -- Copied, because this runs again on every keystroke that moves a
    -- count and must not edit what git said last time it was asked.
    local row = vim.tbl_extend("force", {}, f)
    table.insert(files, row)
    by_path[row.path] = row
  end

  -- Files git has never been told about. Not in `git diff` at all --
  -- there is no revision to measure them against -- and yet as much a
  -- part of what the branch did as any file it tracks. A path git DOES
  -- know about cannot appear twice, since `ls-files --others` is
  -- everything git does not know about.
  for _, f in ipairs(pane.untracked or {}) do
    if not by_path[f.path] then
      local row = vim.tbl_extend("force", {}, f)
      table.insert(files, row)
      by_path[row.path] = row
    end
  end

  for _, view in ipairs(view_mod.matching(pane.root, pane.rev, pane.standalone)) do
    -- Only where the buffer differs from the disk, or names a file git has
    -- no answer about at all. Once it is saved git's numbers are both true
    -- and the fresher of the two: a write re-reads the list immediately,
    -- while the view's own redraw waits out the keystrokes behind it.
    local dirty = vim.api.nvim_buf_is_valid(view.bufnr) and vim.bo[view.bufnr].modified
    local drawn = (view.renders or 0) > 0
    local row = by_path[view.relpath]
    if row then
      if dirty and drawn then
        row.added, row.removed = view.added, view.removed
      end
    elseif drawn and (dirty or view.new_file)
      and (view.added or 0) + (view.removed or 0) > 0 then
      -- Not in git's answer at all: an untracked file, or one whose only
      -- change is still in the buffer. `new_file` is the untracked case --
      -- a file git tracks and the branch added would be in the list
      -- already, because `git diff` counts commits as well as the tree.
      row = {
        path = view.relpath,
        old_path = view.old_path,
        status = view.new_file and "A" or "M",
        binary = false,
        added = view.added,
        removed = view.removed,
        hunks = {},
      }
      table.insert(files, row)
      by_path[row.path] = row
    end
  end

  table.sort(files, function(a, b) return a.path < b.path end)
  return files
end

--- A file git has never been told about, as a row of the list.
---
--- Every line of it is an addition -- there is no revision it existed in
--- to compare against -- so the count is the line count, read here
--- because no git call will give it: `git diff` has nothing to diff.
--- Over `pane.untracked_max_bytes` it is listed with no count at all,
--- which is also what an unreadable or binary file gets: the row is
--- worth having, the number is not worth a megabyte of reading.
local function untracked_row(root, path)
  local full = root .. "/" .. path
  local stat = vim.uv.fs_stat(full)
  local row = {
    path = path,
    old_path = nil,
    status = "A",
    binary = false,
    added = 0,
    removed = 0,
    hunks = {},
    untracked = true,
  }
  if not stat or stat.type ~= "file" then
    return nil
  end
  if stat.size > config.pane.untracked_max_bytes then
    row.binary = true
    return row
  end
  local ok, lines = pcall(vim.fn.readfile, full)
  if not ok or type(lines) ~= "table" then
    row.binary = true
    return row
  end
  row.added = #lines
  return row
end

--- Rebuilds the list from both, keeping the highlighted row on `keep_path`
--- where that file is still in it.
local function rebuild(pane, keep_path)
  pane.files = compose(pane)
  pane.stat_added, pane.stat_removed = patch.total(pane.files)
  pane.file_idx = 1
  if keep_path then
    for i, f in ipairs(pane.files) do
      if f.path == keep_path or f.old_path == keep_path then
        pane.file_idx = i
        break
      end
    end
  end
  -- Re-reading the list lands on a file the same way stepping to one
  -- does, so it opens the way to it for the same reason.
  M.reveal(pane, pane.file_idx)
end

--- A view's counts moved, so the list says so.
---
--- No git here: what changed is what a buffer says, and asking git about
--- an edit it cannot see would answer the wrong question at the cost of a
--- subprocess per keystroke.
function M.recount(view)
  for _, pane in pairs(panes) do
    if pane.root == view.root and pane.rev == view.rev then
      local cur = pane.files[pane.file_idx]
      rebuild(pane, cur and cur.path or nil)
      if pane.list_buf then
        filelist.render(pane)
      end
    end
  end
end

--- Re-reads what git has to say and redraws.
---
--- `git diff <fork point>` with no second revision, so it counts the
--- working tree rather than the commits: a file whose change is staged, or
--- saved and not committed, is part of what this branch has done.
local function refresh(pane, keep_path)
  pane.gen = (pane.gen or 0) + 1
  local gen = pane.gen
  local function read(cb)
    if pane.commit then
      -- The commit against its parent, which is what `pane.rev` is while
      -- one is on show. A range, not a comparison with the working tree:
      -- see `git.diff_range`.
      git.diff_range(pane.root, pane.rev, pane.commit.sha, cb)
    else
      git.diff_since(pane.root, pane.rev, cb)
    end
  end

  read(function(text, err)
    if panes[pane.tab] ~= pane or pane.gen ~= gen then
      return
    end
    pane.tracked = patch.parse(text or "")
    -- An empty list is the one failure this pane cannot show: it is also
    -- what "nothing changed" looks like. Said once per pane, because a
    -- write re-reads the list and a broken read stays broken.
    if not pane.complained and (text == nil or (text ~= "" and #pane.tracked == 0)) then
      pane.complained = true
      vim.notify("uatis: could not read `git diff " .. (pane.ref or pane.rev) .. "`: "
        .. (err ~= nil and err ~= "" and err
          or "git printed something that is not a unified diff"),
        vim.log.levels.ERROR)
    end
    local function drawn()
      rebuild(pane, keep_path)
      if pane.list_buf then
        filelist.render(pane)
      end
      follow_visible(pane)
      -- Counted so a test can wait for a redraw rather than for a
      -- wall-clock guess, the same way the review's panes are.
      pane.renders = (pane.renders or 0) + 1
      -- Anything waiting for the list to exist -- `]f` pressed before
      -- there was one -- runs here, once, now that there is.
      local ready = pane.on_ready
      if ready then
        pane.on_ready = nil
        ready(pane)
      end
    end

    -- ...and the other half of what the branch did, which `git diff`
    -- cannot answer: the files git has never been told about. Read
    -- after the diff rather than beside it so the list is drawn once,
    -- with both halves in it, instead of jumping as the second arrives.
    if pane.commit or config.pane.untracked_max_bytes <= 0 then
      pane.untracked = {}
      drawn()
      return
    end
    git.untracked(pane.root, function(paths)
      if panes[pane.tab] ~= pane or pane.gen ~= gen then
        return
      end
      local rows = {}
      for _, path in ipairs(paths) do
        local row = untracked_row(pane.root, path)
        if row then
          table.insert(rows, row)
        end
      end
      pane.untracked = rows
      drawn()
    end)
  end)
end

-- ------------------------------------------------------------------
-- Commit by commit
-- ------------------------------------------------------------------

--- The revision the commit at `idx` is measured against: the one before
--- it in the branch, and for the first one the revision the whole review
--- measures from. `--first-parent` makes that walk linear, so the list
--- itself answers this without asking git again.
local function parent_of(pane, idx)
  if idx > 1 then
    return pane.commits[idx - 1].sha
  end
  return pane.tree_rev
end

--- The help line under the list.
---
--- Reads off the mode, because two of the keys only exist in one of
--- them: `[C`/`]C` step within a commit-by-commit review and say so
--- when there is no review to step through, so a reader who has just
--- pressed `C` is exactly the reader who needs to be told about them.
--- `C` itself changes meaning rather than going away -- it is the way
--- back out -- so it changes what it says instead.
local function hint_for(pane)
  local k = config.keys.pane
  local parts = {
    k.file_next .. "/" .. k.file_prev .. " file",
    k.select .. " open",
  }
  if pane.standalone then
    -- Nothing about commits at all. This review IS one -- `:UatisShow`
    -- asked for that commit and nothing else -- so neither the toggle
    -- nor the step keys have anywhere to go, and a hint naming keys
    -- that answer with "there is only this one" is a hint that costs
    -- the reader a keypress to disbelieve.
  elseif pane.commit then
    table.insert(parts, k.commit_prev .. "/" .. k.commit_next .. " commit")
    table.insert(parts, k.commit_view .. " whole branch")
  else
    table.insert(parts, k.commit_view .. " commits")
  end
  table.insert(parts, k.fold .. " fold")
  table.insert(parts, k.quit .. " close")
  return table.concat(parts, " · ")
end

--- Puts one commit on show, or takes the review back to the working
--- tree when `idx` is nil.
---
--- Every view of this review closes first. They are pinned to the
--- revision the list was measured against, and that revision is exactly
--- what has just changed -- a view left open would be annotating one
--- commit's parent while the list beside it describes another's.
--- Whichever file the reader was on is opened again at the new
--- revision, so a step lands somewhere rather than on an empty window.
local function show(pane, idx, keep_path)
  local was = pane.rev
  if idx then
    local commit = pane.commits[idx]
    pane.commit, pane.commit_idx = commit, idx
    pane.mode = "commit"
    -- `ref` names what is being measured AGAINST, which is the commit
    -- before this one -- the first one's is the revision the whole
    -- review measures from, and that has a name worth keeping. The
    -- commit itself is named by the header and, on a file shown as it
    -- was, by the winbar's `at`.
    pane.target = idx > 1 and pane.commits[idx - 1].short or pane.tree_ref
    pane.src = commit.short
    pane.ref, pane.rev = pane.target, parent_of(pane, idx)
  else
    pane.commit, pane.commit_idx = nil, nil
    pane.ref, pane.rev = pane.tree_ref, pane.tree_rev
    pane.mode = "overall"
    pane.target, pane.src = pane.tree_ref, "working tree"
  end
  pane.hint = hint_for(pane)
  view_mod.close_all(pane.root, was, pane.standalone)

  pane.on_ready = function(p)
    if panes[p.tab] ~= p or #p.files == 0 then
      return
    end
    local at = 1
    for i, f in ipairs(p.files) do
      if f.path == keep_path or f.old_path == keep_path then
        at = i
        break
      end
    end
    M.goto_file(p, at)
  end
  refresh(pane, keep_path)
end

--- Runs `fn(pane)` once the branch's commits are known.
---
--- Read once per review, and re-read whenever the review is re-pointed
--- or git moves: which commits there are is a fact about the two
--- revisions, and those are what re-pointing changes.
local function with_commits(pane, fn)
  if pane.commits then
    fn(pane)
    return
  end
  if pane.reading_commits then
    return
  end
  pane.reading_commits = true
  git.commits_between(pane.root, pane.tree_rev, "HEAD", function(list)
    pane.reading_commits = nil
    if panes[pane.tab] ~= pane then
      return
    end
    pane.commits = list
    fn(pane)
  end)
end

local function current_path(pane)
  local file = pane.files[pane.file_idx]
  return file and file.path or nil
end

--- `<leader>gh`: read the review one commit at a time, or stop.
---
--- Entering shows the newest commit -- the last thing the branch did,
--- which is where reading it in order ends up and the most likely thing
--- to want to look at first. Leaving puts the review back to what it is
--- the rest of the time: the whole branch against the working tree.
function M.toggle_commits(pane)
  pane = pane or M.get()
  if not pane then
    return false
  end
  -- Nowhere to go from a review that is one commit. Off, this key means
  -- "the whole branch against the working tree", and here that would be
  -- the commit's PARENT against the working tree -- a comparison nobody
  -- asked for, arrived at by a key that says it is turning something
  -- off. `:Uatis` is how you ask for a review of your own branch.
  if pane.standalone then
    vim.notify("uatis: this review is one commit", vim.log.levels.INFO)
    return true
  end
  if pane.commit then
    show(pane, nil, current_path(pane))
    return false
  end
  with_commits(pane, function(p)
    if #p.commits == 0 then
      vim.notify("uatis: no commits between " .. tostring(p.tree_ref) .. " and HEAD",
        vim.log.levels.INFO)
      return
    end
    show(p, #p.commits, current_path(p))
  end)
  return true
end

--- `]C` / `[C`: the next or previous commit, WITHIN that mode.
---
--- They do not enter it. A navigation key that turns a mode on is a key
--- that moves the reader somewhere they did not ask to be, so pressed
--- outside it these say how to get in instead. Nor do they leave it at
--- the ends: the review stays on the first or the last commit and says
--- which, because walking off the end of a list is a thing to be told
--- about rather than a way out.
function M.step_commit(pane, dir)
  pane = pane or M.get()
  if not pane then
    return
  end
  if pane.standalone then
    vim.notify("uatis: this review is one commit", vim.log.levels.INFO)
    return
  end
  if not pane.commit then
    -- The view's key, not the list's: this is pressed in a file as often
    -- as in the list, and the list's own toggle is a bare letter that
    -- means something else there.
    vim.notify("uatis: not reading commit by commit · "
      .. config.keys.view.commit_view .. " to start", vim.log.levels.INFO)
    return
  end
  local n = #(pane.commits or {})
  local to = pane.commit_idx + dir
  if to < 1 then
    vim.notify("uatis: first commit of this review", vim.log.levels.INFO)
    return
  end
  if to > n then
    vim.notify("uatis: last commit of this review", vim.log.levels.INFO)
    return
  end
  show(pane, to, current_path(pane))
end

--- Re-reads the list, and the revision it is measured against, because
--- git may have moved while nvim was not looking.
---
--- A commit needs nothing: the list is `git diff <fork point>` against
--- the working tree, so committing moves nothing it counts. What does
--- move is HEAD -- a branch switched, a rebase, the base branch pulled --
--- and then the FORK POINT itself is somewhere else and a base-tracking
--- review is measuring against a revision that no longer answers "since
--- I branched". That is not staleness, it is a wrong answer, so the
--- revision is re-resolved before the list is re-read.
---
--- A review pinned by `:Uatis <ref>` keeps its revision: someone meant
--- that one. Only the tree it is compared against can have moved.
function M.recheck(pane)
  pane = pane or M.get()
  if not pane or pane.rechecking then
    return
  end
  -- A finished commit is finished: what it changed is a fact about two
  -- revisions, and neither the working tree nor the fork point is one of
  -- them. So none of what moved while nvim was not looking can have
  -- moved this.
  if pane.standalone then
    return
  end
  if not pane.tracks_base then
    return M.refresh(pane)
  end
  pane.rechecking = true
  base.resolve(pane.root, function(label, sha)
    pane.rechecking = nil
    if panes[pane.tab] ~= pane then
      return
    end
    if not label or not sha then
      return
    end
    -- A commit may have landed while nvim was not looking, so the walk
    -- is dropped either way and read again on the next step.
    pane.commits = nil
    if sha ~= pane.tree_rev then
      -- Both sides at once, from one answer: two ideas of the fork point
      -- on screen is the disagreement the pinning exists to prevent.
      view_mod.repoint(pane.root, label, sha)
      M.repoint(pane.root, label, sha)
    elseif pane.commit then
      -- The walk has just been dropped, and a commit on show is counted
      -- against it -- `12/17` in the header, and `[C`/`]C` stepping
      -- through it. So it is read again here rather than on the next
      -- step, and the reader is put back on the SAME commit: something
      -- landing on the branch moves their place in the count, not which
      -- commit they are reading.
      --
      -- Gone from the range altogether -- a rebase, a reset, a branch
      -- switched under the review -- and there is nothing to be on, so
      -- the review goes back to the working tree the way leaving commit
      -- mode does.
      with_commits(pane, function(p)
        if not p.commit then
          return M.refresh(p)
        end
        local at
        for i, c in ipairs(p.commits) do
          if c.sha == p.commit.sha then
            at = i
            break
          end
        end
        show(p, at, current_path(p))
      end)
    else
      M.refresh(pane)
    end
  end)
end

function M.refresh(pane, keep_path)
  pane = pane or M.get()
  if pane then
    local cur = pane.files[pane.file_idx]
    refresh(pane, keep_path or (cur and cur.path) or nil)
  end
end

--- Re-points every base-tracked list in `root` at `label`/`sha` and
--- re-reads it, keeping the highlighted row on the file being read where
--- that file is still in the list.
---
--- The pane pins itself to one revision on purpose, and this is the one
--- thing allowed to move it: the pin exists so a commit landing mid-review
--- cannot shift the list out from under the overlay beside it, not to
--- outlast a decision the reader made about what they are reviewing
--- against.
function M.repoint(root, label, sha)
  for _, pane in pairs(panes) do
    if pane.tracks_base and pane.root == root
      and (pane.tree_ref ~= label or pane.tree_rev ~= sha) then
      local cur = pane.files[pane.file_idx]
      pane.tree_ref, pane.tree_rev = label, sha
      -- Which commits there are is a fact about the two revisions, and
      -- one of them has just moved: the walk is re-read on the next
      -- step, and a commit on show is let go rather than left pointing
      -- into a range it may no longer be in.
      pane.commits = nil
      if pane.commit then
        show(pane, nil, cur and cur.path or nil)
        return
      end
      pane.ref, pane.rev, pane.target = label, sha, label
      refresh(pane, cur and cur.path or nil)
    end
  end
end

-- ------------------------------------------------------------------
-- Opening files
-- ------------------------------------------------------------------

--- The window a selected file is opened into: the one the pane was split
--- off, if it is still there and still showing something. Falling back to
--- any other window in the tab matters more than it looks -- the pane can
--- outlive the window it came from, and editing a file INTO the pane
--- itself would replace the list with the file it was listing.
local function target_win(pane)
  if pane.code_win and vim.api.nvim_win_is_valid(pane.code_win)
    and pane.code_win ~= pane.list_win
    and vim.api.nvim_win_get_tabpage(pane.code_win) == pane.tab then
    return pane.code_win
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(pane.tab)) do
    if win ~= pane.list_win then
      pane.code_win = win
      return win
    end
  end
  -- Only reachable when the list has a window and it is the only one
  -- left; a list with no window of its own always has somewhere to open
  -- a file, since the reader is standing in it.
  if pane.list_win and vim.api.nvim_win_is_valid(pane.list_win) then
    vim.api.nvim_set_current_win(pane.list_win)
    vim.cmd("rightbelow vsplit")
    pane.code_win = vim.api.nvim_get_current_win()
  end
  return pane.code_win
end

--- Every file the pane opens is pinned to the pane's own revision, handed
--- over directly rather than resolved again. Re-resolving would let a
--- commit landing mid-review move one file's comparison and not the rest.
local function pinned(pane, file)
  return {
    resolve = function(_, cb)
      cb(pane.ref, pane.rev)
    end,
    -- ...and which kind of review it is part of, so a commit read on
    -- its own and a branch read against the same revision do not count
    -- or close each other's buffers. See `view.matching`.
    standalone = pane.standalone,
    -- A file opened out of a base-tracked list is base-tracked too:
    -- choosing another base branch moves the list, and a view left
    -- measuring against the old fork point beside a list measuring
    -- against the new one is exactly the disagreement the pinning above
    -- exists to prevent.
    tracks_base = pane.tracks_base,
    -- Where the file came from, when the branch moved it. The view looks
    -- its old side up by path and would otherwise find nothing under the
    -- new name and call the whole file added.
    old_path = file.old_path,
  }
end

--- Opens the directories `idx` lives under, so the list can point at it.
---
--- Arriving somewhere is what reopens a fold: the alternative is a list
--- that has to special-case the row it is highlighting, and then the
--- twisty on a shut directory says shut while its contents are on
--- screen. Only ever opens -- nothing the reader folded away closes
--- itself again behind them.
function M.reveal(pane, idx)
  local f = pane.files[idx]
  if not f then
    return
  end
  pane.collapsed = pane.collapsed or {}
  for _, d in ipairs(ui.dirs_of(f.path)) do
    pane.collapsed[d] = nil
  end
end

--- Redraws after a fold and leaves the cursor on `path`'s row.
---
--- Every redraw ends by moving the cursor onto the current file
--- (`filelist.sync_cursor`), which is right for arriving at a file and
--- wrong for folding: the row you just acted on would slide out from
--- under you. Where `path` has no row left -- nothing does, after `zR`
--- -- the cursor stays where sync_cursor put it.
local function redraw_at(pane, path)
  if not pane.list_buf then
    return
  end
  filelist.render(pane)
  local win = pane.list_win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  for line, p in pairs(pane.list_dirs or {}) do
    if p == path then
      pcall(vim.api.nvim_win_set_cursor, win, { line, 0 })
      return
    end
  end
end

--- Folds one directory row shut, opens it, or toggles it -- `shut` true,
--- false, or nil.
local function set_fold(pane, path, shut)
  if not path then
    return
  end
  if shut == nil then
    shut = not pane.collapsed[path]
  end
  pane.collapsed[path] = shut or nil
  redraw_at(pane, path)
end

--- The whole tree at once.
---
--- Shut means every directory, not just the outermost: opening one back
--- up then shows the directories inside it still folded, a level at a
--- time, which is what `zM` followed by `zo` does anywhere else.
---
--- The cursor lands on the outermost directory the current file is
--- under, since after `zM` that is the row standing in for where you
--- are -- and the row you would open to get back to it.
local function set_all(pane, shut)
  pane.collapsed = {}
  if shut then
    for _, f in ipairs(pane.files) do
      for _, d in ipairs(ui.dirs_of(f.path)) do
        pane.collapsed[d] = true
      end
    end
  end
  local cur = pane.files[pane.file_idx]
  redraw_at(pane, cur and ui.dirs_of(cur.path)[1] or nil)
end

--- Which directory the cursor is asking about: the row itself where that
--- is a directory, and otherwise the innermost directory the file on
--- that row is in -- which is the fold a line inside a fold belongs to.
local function fold_target(pane)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local path = (pane.list_dirs or {})[line]
  if path then
    return path
  end
  local f = pane.files[(pane.list_rows or {})[line] or 0]
  local ds = f and ui.dirs_of(f.path) or {}
  return ds[#ds]
end

--- The file as it stands right now: the buffer if one is open on it,
--- since an unsaved edit is what the file IS, and the disk otherwise.
--- nil when there is nothing there to read.
local function live_text(root, path)
  local full = vim.fs.normalize(root .. "/" .. path)
  -- Found by walking the buffer list rather than with `bufnr()`, which
  -- matches its argument as a PATTERN: a path holding a `.` or a `~` --
  -- most of them -- is not the name it looks like there.
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b)
      and vim.fs.normalize(vim.api.nvim_buf_get_name(b)) == full then
      return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
    end
  end
  local ok, lines = pcall(vim.fn.readfile, full)
  if not ok or type(lines) ~= "table" then
    return nil
  end
  return table.concat(lines, "\n")
end

--- A read-only buffer holding `path` as it was at `sha`.
---
--- Named for the commit as well as the file, so stepping back and forth
--- reuses one buffer per commit rather than stacking a new one per
--- press, and so the name itself says what you are looking at.
local function buffer_at(root, sha, short, path, text)
  local name = "uatis://at/" .. short .. "/" .. path
  local buf = vim.fn.bufnr(name)
  if buf == -1 or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(false, true)
    pcall(vim.api.nvim_buf_set_name, buf, name)
  end
  vim.bo[buf].buftype = "nofile"
  -- Wiped when it leaves the window: a review stepped through twenty
  -- commits should not leave twenty copies of a file in the buffer
  -- list, and the blob behind this one is cached, so making it again
  -- costs nothing.
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text or "", "\n", { plain = true }))
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  vim.bo[buf].filetype = vim.filetype.match({ filename = path }) or ""
  return buf
end

--- Does `fn` in the pane's code window.
---
--- Focus follows the reader only where they already are. In the pane's
--- own tab, opening a file means going to it -- that is the whole of
--- what `<CR>` in the list is for. From another tab it does not: a file
--- is two git subprocesses away, and by the time one lands the reader
--- may have gone elsewhere. Dragging them back into a tab they had left
--- makes a review something they cannot put down -- and `:UatisShow`
--- opens in a tab of its own, so this is a keypress away rather than a
--- race nobody hits.
local function in_code_win(pane, win, fn)
  if vim.api.nvim_get_current_tabpage() == pane.tab then
    vim.api.nvim_set_current_win(win)
    return fn()
  end
  -- `win_call` rather than nothing at all: the file still opens, and the
  -- window it opens into is still the pane's -- `view_mod.open` reads
  -- the CURRENT buffer and window, which is what this makes true for as
  -- long as it takes.
  return vim.api.nvim_win_call(win, fn)
end

function M.goto_file(pane, idx)
  local f = pane.files[idx]
  if not f then
    return
  end
  pane.file_idx = idx
  M.reveal(pane, idx)
  if pane.list_buf then
    filelist.render(pane)
  end

  local win = target_win(pane)

  -- A file the branch DELETED has nothing in your tree to open, and it is
  -- the one file where "what was there" is the whole question. So the
  -- window gets an empty buffer standing for the file that is not there,
  -- and the comparison -- an empty new side against a revision with
  -- content -- says every line of it went. Side by side that reads
  -- directly: the old revision on the left, nothing opposite it.
  if f.status == "D" then
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].modifiable = false
    -- Named for the commit as well, while one is on show: two commits
    -- can each delete a file of the same name, and two buffers cannot
    -- share one.
    pcall(vim.api.nvim_buf_set_name, buf, "uatis://deleted/"
      .. (pane.commit and (pane.commit.short .. "/") or "") .. f.path)
    vim.bo[buf].filetype = vim.filetype.match({ filename = f.path }) or ""
    in_code_win(pane, win, function()
      vim.api.nvim_win_set_buf(win, buf)
      view_mod.open(pane.ref, vim.tbl_extend("force", pinned(pane, f), {
        root = pane.root,
        path = f.path,
      }))
    end)
    return
  end

  -- With one commit on show, the new side is that commit's content --
  -- and the reader's own buffer is that content, exactly, whenever
  -- nothing has touched the file since. That is the newest commit on a
  -- clean tree, and on older commits every file the later commits left
  -- alone: there the buffer stays the new side and keeps everything
  -- that makes it a buffer -- LSP, jumps, the unsaved state of the
  -- world. Where they differ, the file is shown as it was, read-only,
  -- because there is no honest way to draw one commit's changes on a
  -- buffer that holds five commits' worth.
  if pane.commit then
    local commit = pane.commit
    git.blob(pane.root, commit.sha, f.path, function(text)
      if panes[pane.tab] ~= pane or pane.commit ~= commit then
        return
      end
      if not vim.api.nvim_win_is_valid(win) then
        return
      end
      -- ...but never in a review that is only this commit. There the
      -- reader's buffer is not what is being read: `:UatisShow` is asked
      -- about somebody's finished work, as often as not on a branch this
      -- checkout is nowhere near, and handing back the writable file
      -- because today's copy happens to match would put a review of the
      -- past on a buffer that belongs to the present -- one whose view
      -- the review of your own branch, in the tab you came from, owns.
      in_code_win(pane, win, function()
        if not pane.standalone and text ~= nil and text == live_text(pane.root, f.path) then
          vim.cmd("edit " .. vim.fn.fnameescape(pane.root .. "/" .. f.path))
          view_mod.open(pane.ref, pinned(pane, f))
          return
        end
        local buf = buffer_at(pane.root, commit.sha, commit.short, f.path, text)
        vim.api.nvim_win_set_buf(win, buf)
        view_mod.open(pane.ref, vim.tbl_extend("force", pinned(pane, f), {
          root = pane.root,
          path = f.path,
          at_commit = commit.short,
        }))
      end)
    end)
    return
  end

  in_code_win(pane, win, function()
    vim.cmd("edit " .. vim.fn.fnameescape(pane.root .. "/" .. f.path))
    view_mod.open(pane.ref, pinned(pane, f))
  end)
end

--- Annotates `bufnr` as part of this review, if the review lists it.
---
--- This is what makes a review a mode rather than a decoration on one
--- buffer. You turned it on to read a branch; a jump to definition into
--- another file OF that branch is still reading the branch, and an
--- annotation that evaporated because you did not arrive through the list
--- would have the reader pressing a key to get back what they already had.
---
--- Pinned to the pane's revision like everything else it opens, so a file
--- you arrived at by jumping and a file you arrived at with `]f` are
--- measured against the same thing.
---
--- `force` takes in a file the list does not have -- `<leader>gu` pressed
--- in a file the branch has not touched, which is a reader asking for it
--- directly. It costs nothing to answer: nothing changed there, so nothing
--- is drawn, and the moment they edit it the marks appear.
local function follow(pane, bufnr, win, force)
  if not (config.pane.follow or force) then
    return false
  end
  if view_mod.get(bufnr) or not view_mod.can_open(bufnr) then
    return false
  end
  -- Never into the pane's own window: `:e` from inside the list would put
  -- a diff view's winbar over the list it was opened from.
  if not (win and vim.api.nvim_win_is_valid(win)) or win == pane.list_win then
    return false
  end
  local relpath = view_mod.relpath(pane.root, vim.api.nvim_buf_get_name(bufnr))
  if not relpath then
    return false
  end
  local file
  for _, f in ipairs(pane.files or {}) do
    if f.path == relpath or f.old_path == relpath then
      file = f
      break
    end
  end
  -- A buffer with unsaved edits is a file this branch is changing, whatever
  -- the list says: git reads the disk, and the list is built from git. Take
  -- it in and it reports itself -- which is how it reaches the list at all.
  if not file and not force and not vim.bo[bufnr].modified then
    return false
  end
  -- ...but not while one commit is on show. The review is then about
  -- that commit's content, and a file arrived at by hand holds the
  -- working tree's -- annotating it would draw one commit's diff on text
  -- that is not that commit's. Files are opened from the list there, at
  -- the revision the list is describing.
  if pane.commit then
    return false
  end
  view_mod.attach(bufnr, win, pane.root, relpath, pinned(pane, file or {}))
  return true
end

--- Every window in the tab, taken in by the review it is already part of.
---
--- Run after each re-read of the list, because that is when a file can
--- JOIN it: you start editing something the branch had not touched, save,
--- and the file you are looking at is now one of the branch's own. Waiting
--- for you to leave and come back before it said so would be a review
--- describing the branch as it was a minute ago.
follow_visible = function(pane)
  if not config.pane.follow or not vim.api.nvim_tabpage_is_valid(pane.tab) then
    return
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(pane.tab)) do
    follow(pane, vim.api.nvim_win_get_buf(win), win)
  end
end

--- Puts the list's cursor on the row for whatever `bufnr` holds.
---
--- The cursor IS how the list says where you are -- the row it sits on is
--- the one drawn as current -- so it is put back on every arrival, not
--- only on the arrivals that change which file that is. A list left on
--- the row of the file you came back FROM, or scrolled somewhere else by
--- hand on the way past, is a list pointing at the wrong file, and it
--- points at it for as long as you stay.
---
--- A buffer the list has no row for -- a scratch, a terminal, a file the
--- branch never touched -- moves nothing. The mark stays on the file you
--- were reading, which is still the file the review is about.
---
--- The view's own path first, since a commit read at `uatis://at/...` is
--- a file of the review with a name no path can be recovered from.
function M.point_at(pane, bufnr)
  local view = view_mod.get(bufnr)
  local relpath = view and view.relpath
    or view_mod.relpath(pane.root, vim.api.nvim_buf_get_name(bufnr))
  if not relpath then
    return
  end
  for i, f in ipairs(pane.files or {}) do
    if f.path == relpath or f.old_path == relpath then
      if pane.file_idx ~= i then
        pane.file_idx = i
        -- Folded out of sight is not "no row": the file you have just
        -- arrived at is worth opening the directories that hide it.
        -- Only on the arrival that changes which file is current,
        -- though, or a fold would not survive a window switch.
        M.reveal(pane, i)
        if pane.list_buf then
          filelist.render(pane) -- which ends by syncing the cursor
          return
        end
      end
      filelist.sync_cursor(pane)
      return
    end
  end
end

--- `<leader>gu` in a file this review does not list yet. Answered by the
--- review that is already running rather than by resolving a second
--- revision of our own: two comparisons on one screen, one of them a
--- keystroke old, is the disagreement the pinning exists to prevent.
function M.include(bufnr, win)
  local pane = M.get()
  if not pane then
    return false
  end
  return follow(pane, bufnr, win, true)
end

function M.step_file(pane, dir)
  if #pane.files == 0 then
    return
  end
  local next_idx = pane.file_idx + dir
  if next_idx < 1 or next_idx > #pane.files then
    vim.notify("uatis: " .. (dir > 0 and "last" or "first") .. " file", vim.log.levels.INFO)
    return
  end
  M.goto_file(pane, next_idx)
end

-- ------------------------------------------------------------------
-- Lifetime
-- ------------------------------------------------------------------

--- Lends `]f`/`[f` to whatever buffer you are in, for as long as the list
--- is open.
---
--- The view binds them too, but a reader is not always in a file with a
--- comparison on it: a scratch buffer, a file the branch did not touch,
--- an empty buffer where nvim started. Stepping the list is about the
--- LIST, and the list is open -- so the keys work wherever you are and go
--- back exactly as they were found when the pane closes.
---
--- Only real file buffers: a terminal, a help page or another plugin's
--- pane is somewhere you went for its own sake, and taking its keys would
--- be rude.
local function lend_keys(pane, bufnr)
  if pane.lent[bufnr] ~= nil
    or bufnr == pane.list_buf
    or not vim.api.nvim_buf_is_valid(bufnr)
    or vim.bo[bufnr].buftype ~= ""
    or view_mod.get(bufnr) ~= nil then -- the view has its own
    return
  end
  local k = config.keys.pane
  pane.lent[bufnr] = keys.apply(bufnr, "n", {
    { lhs = k.file_next, rhs = function() M.step_file(pane, 1) end,
      opts = { desc = "uatis: next changed file" } },
    { lhs = k.file_prev, rhs = function() M.step_file(pane, -1) end,
      opts = { desc = "uatis: previous changed file" } },
    { lhs = k.commit_next, rhs = function() M.step_commit(pane, 1) end,
      opts = { desc = "uatis: the review one commit forward" } },
    { lhs = k.commit_prev, rhs = function() M.step_commit(pane, -1) end,
      opts = { desc = "uatis: the review one commit back" } },
    -- The toggle is NOT lent. This one is a bare `C` -- affordable in
    -- the list, which is a scratch buffer of rows, and not in somebody
    -- else's file, where it is `c$`. `keys.view.commit_view` is the way
    -- in from anywhere that is a file.
  })
end

local function return_keys(pane)
  for bufnr, saved in pairs(pane.lent or {}) do
    keys.restore(bufnr, "n", saved)
  end
  pane.lent = {}
end

--- The window down, the list kept.
---
--- `q` in the list means "this window is in my way", not "stop
--- reviewing": the comparison in the file beside it is still open, `]f`
--- still steps the list, files you open are still annotated, and
--- `<leader>gf` puts a window back on the SAME list rather than reading a
--- new one. Ending the review is `<leader>gu`, which closes it for real.
function M.hide(pane)
  pane = pane or M.get()
  if not pane then
    return
  end
  local win = pane.list_win
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  -- Only forgotten if it actually went: the last window in a tab refuses
  -- to close, and a pane that thought its window was gone would put up a
  -- second one beside it.
  if not (win and vim.api.nvim_win_is_valid(win)) then
    pane.list_win = nil
  end
end

function M.close(pane)
  pane = pane or M.get()
  if not pane or pane.closing then
    return
  end
  pane.closing = true
  panes[pane.tab] = nil
  return_keys(pane)
  if pane.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, pane.augroup)
    pane.augroup = nil
  end
  -- A review that opened its own tab takes it away again: `:UatisShow`
  -- put that tab up for this commit and nothing else was ever in it, so
  -- leaving an empty one behind is asking the reader to tidy up after a
  -- key that said "close". Never the last tab -- nvim will not have it,
  -- and neither would anyone.
  if pane.owns_tab and vim.api.nvim_tabpage_is_valid(pane.tab)
    and #vim.api.nvim_list_tabpages() > 1 then
    pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(pane.tab))
  end
  -- Otherwise only the pane's own window goes: everything else in a tab
  -- the reader was already working in is their own layout.
  if pane.list_win and vim.api.nvim_win_is_valid(pane.list_win) then
    pcall(vim.api.nvim_win_close, pane.list_win, true)
  end
  if pane.list_buf and vim.api.nvim_buf_is_valid(pane.list_buf) then
    pcall(vim.api.nvim_buf_delete, pane.list_buf, { force = true })
  end
end

local function create_buf(tab)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "uatis-files"
  -- Named per tab: a review's list buffer is called `uatis://files`, and
  -- two buffers cannot share a name.
  vim.api.nvim_buf_set_name(buf, "uatis://changes/" .. tostring(tab))
  return buf
end

local function setup_keymaps(pane)
  local k = config.keys.pane
  keys.apply(pane.list_buf, "n", {
    { lhs = k.select, rhs = function()
      local line = vim.api.nvim_win_get_cursor(0)[1]
      local idx = (pane.list_rows or {})[line]
      if idx then
        M.goto_file(pane, idx)
      else
        -- On a directory row there is nothing else for "open this" to
        -- mean, so it means the fold.
        set_fold(pane, (pane.list_dirs or {})[line])
      end
    end, opts = { desc = "uatis: open file under cursor" } },
    { lhs = k.fold, rhs = function()
      set_fold(pane, fold_target(pane))
    end, opts = { desc = "uatis: fold the directory under the cursor" } },
    { lhs = k.fold_close, rhs = function()
      local path = fold_target(pane)
      -- Already shut, so what `zc` is being asked to close is the fold
      -- AROUND this one -- which is how it walks out of a nested tree
      -- everywhere else.
      if path and pane.collapsed[path] then
        local up = ui.dirs_of(path)
        path = up[#up]
      end
      set_fold(pane, path, true)
    end, opts = { desc = "uatis: fold the directory under the cursor shut" } },
    { lhs = k.fold_open, rhs = function()
      set_fold(pane, fold_target(pane), false)
    end, opts = { desc = "uatis: open the directory under the cursor" } },
    { lhs = k.fold_close_all, rhs = function() set_all(pane, true) end,
      opts = { desc = "uatis: fold every directory shut" } },
    { lhs = k.fold_open_all, rhs = function() set_all(pane, false) end,
      opts = { desc = "uatis: open every directory" } },
    { lhs = k.file_next, rhs = function() M.step_file(pane, 1) end,
      opts = { desc = "uatis: next changed file" } },
    { lhs = k.file_prev, rhs = function() M.step_file(pane, -1) end,
      opts = { desc = "uatis: previous changed file" } },
    { lhs = k.commit_next, rhs = function() M.step_commit(pane, 1) end,
      opts = { desc = "uatis: the review one commit forward" } },
    { lhs = k.commit_prev, rhs = function() M.step_commit(pane, -1) end,
      opts = { desc = "uatis: the review one commit back" } },
    { lhs = k.commit_view, rhs = function() M.toggle_commits(pane) end,
      opts = { desc = "uatis: read the review one commit at a time" } },
    { lhs = k.refresh, rhs = function() M.refresh(pane) end,
      opts = { desc = "uatis: re-read the changed-file list" } },
    { lhs = k.focus_code, rhs = function()
      local win = target_win(pane)
      if win then
        vim.api.nvim_set_current_win(win)
      end
    end, opts = { desc = "uatis: focus the file" } },
    { lhs = k.quit, rhs = function() M.hide(pane) end,
      opts = { desc = "uatis: close the changed-file list" } },
    -- The key that put this window up, taking it down again. Opening
    -- focuses the list, so without this the second press of a toggle
    -- would land in the one buffer that had nothing bound to it. Routed
    -- through `toggle` rather than straight to `hide`, so the rule about
    -- what the key means lives in one place.
    { lhs = k.files, rhs = function() M.toggle() end,
      opts = { desc = "uatis: close the changed-file list" } },
  })
end

local function setup_watchers(pane)
  pane.augroup = vim.api.nvim_create_augroup(
    "UatisPane" .. tostring(pane.tab), { clear = true })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = pane.augroup,
    callback = function(ev)
      if tonumber(ev.match) == pane.list_win then
        vim.schedule(function()
          if panes[pane.tab] == pane then
            M.hide(pane)
          end
        end)
      end
    end,
  })

  -- The three watchers below are about the working tree, and a review of
  -- one commit is not: `git diff <parent> <commit>` says the same thing
  -- after a write, a pull and a rebase as it did before them. Only the
  -- window, the cursor and the tab are worth watching there.
  if not pane.standalone then
    -- Saving changes the working tree, and the working tree is what the list
    -- is counting. Re-reading on write is what keeps a `+12 -3` from being a
    -- claim about a file as it was ten minutes ago.
    vim.api.nvim_create_autocmd("BufWritePost", {
      group = pane.augroup,
      callback = function(ev)
        if panes[pane.tab] ~= pane then
          return
        end
        local name = vim.api.nvim_buf_get_name(ev.buf)
        if name ~= "" and vim.startswith(vim.fs.normalize(name), vim.fs.normalize(pane.root)) then
          M.refresh(pane)
        end
      end,
    })

    -- Anything git did while nvim was not looking. Neither of the two
    -- above catches it: `lazygit` in the next window switches a branch, a
    -- colleague's PR is pulled onto the base branch, a rebase rewrites
    -- what HEAD means -- and no buffer here was written or re-read, so the
    -- list goes on describing a repository that has moved.
    --
    -- `FocusGained` is the window manager's answer to "you were away";
    -- `TermLeave` and `TermClose` are the same event for a git tool run
    -- inside nvim, which never takes focus away from it. Guarded against
    -- overlapping in `recheck` rather than debounced, since what makes it
    -- expensive is the subprocess and one is already in the air.
    vim.api.nvim_create_autocmd({ "FocusGained", "TermLeave", "TermClose" }, {
      group = pane.augroup,
      callback = function()
        if panes[pane.tab] ~= pane then
          return
        end
        M.recheck(pane)
      end,
    })

    -- ...and reading is the other half of that. `:e` puts the file back on
    -- screen from the disk, and what a reader is usually saying with it is
    -- that something ELSE wrote the file -- a formatter, a rebase, a
    -- checkout, a colleague's branch pulled in. The list is `git diff`
    -- against that disk, so it is stale for exactly as long as nobody
    -- asks git again.
    --
    -- Only for a buffer the review already knew about, which is what tells
    -- a re-read from a first open: every file opened while a list is up
    -- fires this too, and a `git diff` per jump-to-definition is a cost
    -- nobody asked for. A file the list has a row for, or one carrying a
    -- view, is one that was already on screen.
    vim.api.nvim_create_autocmd("BufReadPost", {
      group = pane.augroup,
      callback = function(ev)
        if panes[pane.tab] ~= pane then
          return
        end
        local name = vim.api.nvim_buf_get_name(ev.buf)
        if name == ""
          or not vim.startswith(vim.fs.normalize(name), vim.fs.normalize(pane.root)) then
          return
        end
        local known = view_mod.get(ev.buf) ~= nil
        if not known then
          local rel = view_mod.relpath(pane.root, name)
          for _, f in ipairs(pane.files or {}) do
            if f.path == rel or f.old_path == rel then
              known = true
              break
            end
          end
        end
        if known then
          M.refresh(pane)
        end
      end,
    })
  end

  -- Following the buffer that gets focus, so the highlighted row is
  -- whatever is actually on screen -- including files reached by `:e`, a
  -- jump to definition or anything else that has never heard of this pane.
  vim.api.nvim_create_autocmd("BufEnter", {
    group = pane.augroup,
    callback = function(ev)
      if panes[pane.tab] ~= pane
        or vim.api.nvim_get_current_tabpage() ~= pane.tab
        or ev.buf == pane.list_buf then
        return
      end
      if not view_mod.get(ev.buf) then
        -- A file this review lists is annotated on arrival, however you
        -- arrived. It binds `]f`/`[f` itself, so it is not lent them too:
        -- two owners of one mapping, and whichever gave it back second
        -- would put the other's back.
        if not follow(pane, ev.buf, vim.api.nvim_get_current_win()) then
          -- No comparison on this buffer -- but the list is still open,
          -- and stepping it is about the list.
          lend_keys(pane, ev.buf)
        end
      end
      -- Either way the list says where you are, and a file it lists is
      -- one it lists whether or not it has just been annotated: the row
      -- is moved to for the buffer, not for the attaching.
      M.point_at(pane, ev.buf)
    end,
  })

  -- A tab closing takes its pane with it, and the keys that pane lent to
  -- buffers elsewhere have to come back: those buffers outlive the tab,
  -- and a mapping left behind still points at a pane whose windows are
  -- gone -- which is how `]f` ends up asking a dead tabpage for its
  -- windows.
  vim.api.nvim_create_autocmd("TabClosed", {
    group = pane.augroup,
    callback = function()
      for tab, p in pairs(panes) do
        if not vim.api.nvim_tabpage_is_valid(tab) then
          panes[tab] = nil
          p.closing = true
          return_keys(p)
        end
      end
    end,
  })
end

-- ------------------------------------------------------------------
-- Entry point
-- ------------------------------------------------------------------

--- Opens the side pane for the diff view in the current buffer.
---
--- A no-op without one, deliberately: the pane's whole content -- which
--- files, measured against which revision -- comes from the view, so there
--- is nothing it could show. Opening one silently against a guessed
--- revision would be a different pane that happened to look the same.
---
--- Already open in this tab: focus it rather than stacking a second.
--- Reads the changed-file list for this tab, without showing it.
---
--- The list and the window onto it are separate things. `]f` wants the
--- list -- which file comes next, and where it is -- and putting a window
--- up for that is answering a question nobody asked; `<leader>gf` wants
--- the window. So this builds the list, `M.open` gives it a window, and
--- either can come first.
---
--- `opts.on_ready(pane)` runs once the list has been read, which is a
--- `git diff` away, so a caller that wants to act ON it has somewhere to
--- wait.
--- Builds the pane for `root` at `ref`/`rev`, registers it and starts
--- reading the list. Everything above this point is working out those
--- three things.
local function build(tab, root, ref, rev, relpath, opts, tracks_base)
  local pane = {
    tab = tab,
    root = root,
    ref = ref,
    rev = rev,
    -- Whether the list FOLLOWS the base branch. A list built from
    -- `:Uatis <ref>` was pointed somewhere by hand and stays there;
    -- one built from the base branch moves when the base branch does.
    tracks_base = tracks_base or false,
    -- What the review itself is measured against, kept aside because
    -- `ref`/`rev` move while a single commit is on show and have to be
    -- put back when it is not. `commits` is that range walked out, read
    -- the first time anyone steps into it.
    tree_ref = ref,
    tree_rev = rev,
    commits = nil,
    commit = nil,
    commit_idx = nil,
    -- What git said, and what git said folded together with what the open
    -- buffers say. `compose` builds the second from the first.
    tracked = {},
    files = {},
    file_idx = 1,
    list_rows = {},
    -- Directory rows folded shut, by full path. The reader's, and kept
    -- across every redraw -- a fold that reopened whenever the list was
    -- re-read would be gone the first time you moved.
    collapsed = {},
    list_dirs = {},
    -- Buffers this pane has lent `]f`/`[f` to, with whatever was mapped
    -- there before, to be handed back when it closes.
    lent = {},
    stat_added = 0,
    stat_removed = 0,
    -- Read by `ui.build_list`. The header says what is being compared:
    -- `main ← working tree`, because the new side here is the files as
    -- they stand, unsaved edits and all.
    mode = "overall",
    target = ref,
    src = "working tree",
    hint = "",
    code_win = vim.api.nvim_get_current_win(),
    -- Whether the tab goes when the review does. True only for the one
    -- this module opened for itself -- `:UatisShow` in a tab of its own
    -- -- since everything in any other tab is the user's own layout.
    owns_tab = opts.owns_tab or false,
  }

  -- A review whose whole subject is ONE commit, which is `show(pane, 1)`
  -- with a walk of length one: `ref`/`rev` are already the parent, and
  -- that is exactly what `show` sets them to at the first commit of a
  -- walk. Seeded here rather than by calling `show` afterwards so the
  -- list is read once, against the commit, instead of once against the
  -- working tree and again a subprocess later.
  if opts.commit then
    pane.standalone = true
    pane.commits = { opts.commit }
    pane.commit, pane.commit_idx = opts.commit, 1
    pane.mode = "commit"
    pane.src = opts.commit.short
  end

  pane.hint = hint_for(pane)
  panes[tab] = pane
  pane.on_ready = opts.on_ready
  lend_keys(pane, vim.api.nvim_get_current_buf())
  setup_watchers(pane)
  refresh(pane, relpath)
  return pane
end

--- Finds this tab's list, or makes one, and hands it to `cb`.
---
--- Three ways to know what to compare against, in order of how directly
--- the reader said it. A pane already open is the answer to itself. A
--- diff view under the cursor has a revision it is pinned to, and the two
--- must agree -- a list beside a view measuring something else is a lie.
--- And with neither, there is still an answer worth giving: the base
--- branch, from the repository you are standing in.
---
--- That last one is why this is a callback. Working it out is two git
--- subprocesses, so a caller that wants the pane ITSELF has to wait for
--- it -- which is also why `M.open` puts its window up in here rather
--- than after the call.
local function with_list(opts, cb)
  local tab = vim.api.nvim_get_current_tabpage()
  local existing = panes[tab]
  -- An explicit revision re-points the list, the way naming one re-points
  -- a view: asking for `main` and being handed the list against something
  -- else because it happened to be open is the kind of quiet
  -- disagreement this plugin is meant not to have.
  if existing and opts.resolve then
    M.close(existing)
    existing = nil
  end
  -- ...and a list that no longer agrees with the view under the cursor is
  -- re-read rather than handed back. The view was re-pointed by name
  -- while the list was hidden or standing beside something else --
  -- `<leader>gu` against a base with nothing in it, then `:Uatis
  -- HEAD~10` -- and this call is the reader asking for the two to be
  -- next to each other. Handing back the old list answers with the
  -- revision they moved off.
  --
  -- Compared on the REVISION and not the label. Files opened from the
  -- list are pinned to its sha and carry that sha as their ref, so a
  -- list called `main` is beside views called `4f6c20b` all day long and
  -- the two agree perfectly.
  if existing then
    local v = view_mod.get(vim.api.nvim_get_current_buf())
    if v and v.root == existing.root and v.rev ~= existing.rev then
      M.close(existing)
      existing = nil
    end
  end
  if existing then
    if opts.on_ready then
      if (existing.renders or 0) > 0 then
        opts.on_ready(existing)
      else
        existing.on_ready = opts.on_ready
      end
    end
    return cb(existing)
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local view = view_mod.get(bufnr)
  if view then
    return cb(build(tab, view.root, view.ref, view.rev, view.relpath, opts,
      view.tracks_base))
  end

  -- No view here -- a scratch buffer, a terminal, the empty buffer nvim
  -- started in. The question "what has this branch changed" is still a
  -- good one, and it is about the repository rather than about whichever
  -- buffer happens to be on screen.
  --
  -- Asked through `base.root`, which knows that a buffer with a name is
  -- not the same as a buffer with a path: a terminal is called
  -- `term://~/src/foo//4242:/bin/bash`, and handing that to `git -C` asks
  -- about a directory that does not exist and answers "not inside a git
  -- repository" from inside one.
  base.root(function(root, path)
    if not root then
      vim.notify("uatis: " .. path .. " is not inside a git repository",
        vim.log.levels.ERROR)
      return
    end
    local resolve = opts.resolve or base.resolve
    resolve(root, function(label, sha)
      if not label or not sha then
        return
      end
      if panes[tab] then
        return cb(panes[tab]) -- something else got there while we asked
      end
      cb(build(tab, root, label, sha, nil, opts, opts.resolve == nil))
    end)
  end)
end

--- Reads the changed-file list for this tab, without showing it.
---
--- The list and the window onto it are separate things. `]f` wants the
--- list -- which file comes next, and where it is -- and putting a window
--- up for that is answering a question nobody asked; `<leader>gf` wants
--- the window.
---
--- `opts.on_ready(pane)` runs once the list has been read, which is a
--- `git diff` away, so a caller that wants to act ON it has somewhere to
--- wait.
function M.list(opts)
  local found
  with_list(opts or {}, function(pane)
    found = pane
  end)
  return found -- nil when the revision had to be worked out asynchronously
end

--- ...and the window onto it, beside the file you are reading.
---
--- `opts.focus == false` leaves the cursor where it is.
function M.open(opts)
  opts = opts or {}
  local shown
  with_list(opts, function(pane)
    shown = pane
    if pane.list_win and vim.api.nvim_win_is_valid(pane.list_win) then
      if opts.focus ~= false then
        vim.api.nvim_set_current_win(pane.list_win)
      end
      return
    end

    local here = vim.api.nvim_get_current_win()
    pane.code_win = here
    pane.list_buf = pane.list_buf or create_buf(pane.tab)
    vim.cmd("topleft vsplit")
    pane.list_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(pane.list_win, pane.list_buf)
    vim.api.nvim_win_set_width(pane.list_win, config.list.width)
    filelist.setup_window(pane.list_win)
    -- The pane is not a winbar-carrying window, and the split inherits
    -- whatever the window it came from had -- which is the diff view's
    -- winbar, describing a file this pane is not showing.
    vim.wo[pane.list_win].winbar = ""
    setup_keymaps(pane)
    filelist.render(pane)

    if opts.focus == false and vim.api.nvim_win_is_valid(here) then
      vim.api.nvim_set_current_win(here)
    end
  end)
  return shown
end

--- A review whose whole subject is one commit, in a tab of its own.
---
--- The same shape as reading a branch a commit at a time -- one commit
--- against its parent, its own files, each of them shown as it was --
--- and reached without a branch review to be inside. `<leader>gh` walks
--- the commits YOU wrote since you forked; this answers the other
--- question, the one about somebody else's commit, on a branch this
--- checkout is nowhere near.
---
--- In a new tab because a review is a mode over a tab: `panes` is keyed
--- by tabpage, so opening this where the reader was standing would take
--- the review they already had. The tab is opened BEFORE the pane is
--- built, since `build` reads the tabpage and the window it is called
--- in. `config.show.tab = false` for anyone who would rather it happened
--- in place, which then replaces whatever review that tab held -- one
--- list per tab is the rule everything else here rests on.
---
--- Its list always goes up, `pane.auto_open` or not: in a tab of its own
--- there is otherwise nothing on screen at all, and the list is the
--- thing that was asked for.
function M.show_commit(rev, opts)
  opts = opts or {}
  base.root(function(root, path)
    if not root then
      vim.notify("uatis: " .. path .. " is not inside a git repository",
        vim.log.levels.ERROR)
      return
    end
    git.commit(root, rev, function(commit, parent, err)
      if not commit or not parent then
        -- git's first line only. The rest of what it says about an
        -- unknown revision is three lines about `--` and paths, which
        -- is advice for a command the reader did not type.
        local why = err and err:match("^[^\r\n]*") or ""
        vim.notify("uatis: no commit at " .. rev .. (why ~= "" and (": " .. why) or ""),
          vim.log.levels.ERROR)
        return
      end
      local own_tab = opts.tab
      if own_tab == nil then
        own_tab = config.show.tab
      end
      if own_tab then
        vim.cmd("tabnew")
      end
      local tab = vim.api.nvim_get_current_tabpage()
      if panes[tab] then
        M.close(panes[tab])
      end
      -- Named `<short>^` rather than by the parent's own abbreviation:
      -- it is the header's left-hand side, and "the commit before this
      -- one" is what the reader is thinking, where a second unrelated
      -- sha beside the first is one more thing to hold. A commit with no
      -- parent has no such name, and the empty tree it is measured
      -- against is not one either -- so it says what it is.
      local against = commit.orphan and "nothing" or (commit.short .. "^")
      local pane = build(tab, root, against, parent, nil, {
        commit = commit,
        owns_tab = own_tab,
        on_ready = function(p)
          if panes[p.tab] ~= p then
            return
          end
          if #p.files > 0 then
            M.goto_file(p, 1)
          end
          if opts.on_ready then
            opts.on_ready(p)
          end
        end,
      }, false)
      M.open({ focus = false })
      return pane
    end)
  end)
end

--- ...and the same key taking it away again -- but only from inside it.
---
--- Three states, not two, because "the list is on screen" and "I am
--- looking at it" are different places to be pressing this from. With no
--- window, it wants one. With a window it is not standing in, it wants
--- to get there -- reaching the list is the common thing to want, and
--- closing a window you are not even in would be a strange answer to a
--- key you pressed to see something. From inside, it means what `q`
--- means there: this window is in my way.
---
--- The WINDOW, not the review, in every one of them. The list goes on
--- being followed and stepped by `]f` either way, and ending the review
--- is still `<leader>gu`.
---
--- Read from the window rather than from a flag of its own, so a list
--- whose window the user closed by hand toggles back on rather than off.
function M.toggle(opts)
  local pane = M.get()
  if pane and pane.list_win and vim.api.nvim_win_is_valid(pane.list_win) then
    if vim.api.nvim_get_current_win() == pane.list_win then
      M.hide(pane)
    else
      vim.api.nvim_set_current_win(pane.list_win)
    end
    return pane
  end
  return M.open(opts)
end

return M
