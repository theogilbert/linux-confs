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

  for _, view in ipairs(view_mod.matching(pane.root, pane.rev)) do
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
  git.diff_since(pane.root, pane.rev, function(text, err)
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
    if config.pane.untracked_max_bytes <= 0 then
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
    if sha ~= pane.rev then
      -- Both sides at once, from one answer: two ideas of the fork point
      -- on screen is the disagreement the pinning exists to prevent.
      view_mod.repoint(pane.root, label, sha)
      M.repoint(pane.root, label, sha)
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
      and (pane.ref ~= label or pane.rev ~= sha) then
      local cur = pane.files[pane.file_idx]
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
  vim.api.nvim_set_current_win(win)

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
    pcall(vim.api.nvim_buf_set_name, buf, "uatis://deleted/" .. f.path)
    vim.bo[buf].filetype = vim.filetype.match({ filename = f.path }) or ""
    vim.api.nvim_win_set_buf(win, buf)
    view_mod.open(pane.ref, vim.tbl_extend("force", pinned(pane, f), {
      root = pane.root,
      path = f.path,
    }))
    return
  end

  vim.cmd("edit " .. vim.fn.fnameescape(pane.root .. "/" .. f.path))
  view_mod.open(pane.ref, pinned(pane, f))
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
  -- Only the pane's own window goes. Unlike the review, which owns its
  -- whole tab, everything else in this one is the user's own layout.
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
      local view = view_mod.get(ev.buf)
      if not view then
        -- A file this review lists is annotated on arrival, however you
        -- arrived. It binds `]f`/`[f` itself, so it is not lent them too:
        -- two owners of one mapping, and whichever gave it back second
        -- would put the other's back.
        if follow(pane, ev.buf, vim.api.nvim_get_current_win()) then
          return
        end
        -- No comparison on this buffer, so nothing to highlight in the
        -- list -- but the list is still open, and stepping it is about
        -- the list.
        lend_keys(pane, ev.buf)
        return
      end
      for i, f in ipairs(pane.files or {}) do
        if f.path == view.relpath or f.old_path == view.relpath then
          if pane.file_idx ~= i then
            pane.file_idx = i
            M.reveal(pane, i)
            if pane.list_buf then
              filelist.render(pane)
            end
          end
          return
        end
      end
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
    hint = config.keys.pane.file_next .. "/" .. config.keys.pane.file_prev
      .. " file · " .. config.keys.pane.select .. " open · "
      .. config.keys.pane.fold .. " fold · "
      .. config.keys.pane.quit .. " close",
    code_win = vim.api.nvim_get_current_win(),
  }

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
