-- A review's own checkout of the commit on show.
--
-- A file read at a commit used to be a `uatis://at/...` scratch buffer:
-- the right text, and no project around it, so no language server
-- attached -- no hover, no go-to-definition, no references, in exactly
-- the mode where the code being read is not the code on disk and the
-- reader most needs a way to ask what a name means. `at.lua` answers the
-- same question for a revision opened to be read, with a worktree; this
-- is that worktree made to follow a walk.
--
-- One per review, and MOVED from commit to commit (`git checkout
-- --detach`) rather than one per commit: a language server indexes the
-- project it is started in, and twenty commits stepped through must not
-- be twenty servers indexing twenty copies. Moved, the server stays up
-- and re-reads what changed; the buffers read out of the checkout are
-- reloaded, and one whose file the new commit does not have is wiped.
--
-- Read-only, as `at.lua`'s are, and gone with the walk: leaving commit
-- mode or ending the review removes it, with its buffers and the
-- language servers rooted in it. On the way out of the editor the
-- removal is waited for, since one killed half done leaves a checkout
-- git still believes in.

local config = require("uatis.config")
local git = require("uatis.git")

local M = {}

--- pane -> { root, dir, sha, want, busy, waiting = { { sha, cb } } }
local held = {}

local augroup

--- The folder a repository's review checkouts go in.
local function repo_dir(root)
  return vim.fs.normalize(vim.fn.stdpath("cache") .. "/uatis/review/"
    .. vim.fs.basename(root) .. "-" .. vim.fn.sha256(root):sub(1, 8))
end

--- Where `pane`'s checkout lives: one checkout per review in the
--- repository's folder.
local function dir_for(pane)
  return repo_dir(pane.root) .. "/" .. tostring(pane.tab) .. "-"
    .. tostring(vim.uv.hrtime() % 100000)
end

local function under(path, dir)
  path = vim.fs.normalize(path or "")
  return path == dir or path:sub(1, #dir + 1) == dir .. "/"
end

--- The checkout a path is in, if it is in one.
function M.owner_of(path)
  if not path or path == "" then
    return nil
  end
  for _, co in pairs(held) do
    if under(path, co.dir) then
      return co
    end
  end
  return nil
end

--- A buffer of a checkout made what it is: read-only, no swap file, and
--- wiped when it leaves its window -- a walk of twenty commits leaves no
--- trail of them in the buffer list, and reading one again costs a load.
local function take(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].buftype ~= "" then
    return
  end
  if not M.owner_of(vim.api.nvim_buf_get_name(bufnr)) then
    return
  end
  vim.bo[bufnr].readonly = true
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].bufhidden = "wipe"
end

M.take = take

local function watch()
  if augroup then
    return
  end
  augroup = vim.api.nvim_create_augroup("UatisCheckout", { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufEnter" }, {
    group = augroup,
    callback = function(ev)
      take(ev.buf)
    end,
  })
end

--- `buf` wiped without taking its windows with it. A wipe closes every
--- window showing the buffer -- the code window, when a step lands on a
--- commit without the file in it, or when the walk ends -- so each is
--- handed an empty placeholder first, for whatever opens next.
local function drop(buf)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local spare = vim.api.nvim_create_buf(false, true)
    vim.bo[spare].bufhidden = "wipe"
    pcall(vim.api.nvim_win_set_buf, win, spare)
  end
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

--- Every loaded buffer of the checkout read again from the disk after it
--- moved, and the ones the commit arrived at has no file for wiped.
local function reload(co)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if vim.api.nvim_buf_is_loaded(buf) and under(name, co.dir) then
      if vim.uv.fs_stat(name) then
        vim.api.nvim_buf_call(buf, function()
          vim.bo[buf].modifiable = true
          vim.cmd("silent! edit!")
          take(buf)
        end)
      else
        drop(buf)
      end
    end
  end
end

--- Answers the callers waiting on the sha the checkout is at, and moves
--- it on to the one wanted last: a step asked while the previous one is
--- still checking out waits for it, and only the latest is ever reached
--- -- the ones skipped past are answered with nothing.
local function pump(co)
  if co.busy then
    return
  end
  if co.sha == co.want then
    local waiting = co.waiting
    co.waiting = {}
    for _, w in ipairs(waiting) do
      w.cb(w.sha == co.sha and co.dir or nil)
    end
    return
  end
  co.busy = true
  local target = co.want
  local function done(ok, _, why)
    co.busy = false
    if held[co.pane] ~= co then
      return
    end
    if not ok then
      vim.notify("uatis: could not check out " .. target:sub(1, 12) .. ": "
        .. (vim.trim(why or ""):match("^[^\r\n]*") or ""), vim.log.levels.ERROR)
      local waiting = co.waiting
      co.waiting, co.want = {}, co.sha
      for _, w in ipairs(waiting) do
        w.cb(nil)
      end
      return
    end
    co.sha = target
    reload(co)
    pump(co)
  end
  -- No hooks: a `post-checkout` that installs dependencies or rebuilds
  -- something is right for a checkout someone will work in, and seconds
  -- of surprise on every step of a walk.
  if co.sha then
    git.run(co.dir, { "-c", "core.hooksPath=/dev/null", "checkout", "--detach", "--quiet",
      target }, done)
  else
    vim.fn.delete(co.dir, "rf")
    vim.fn.mkdir(vim.fs.dirname(co.dir), "p")
    -- Checkouts no review here holds are a session's that ended without
    -- removing them -- killed, crashed -- and git still lists each one
    -- in the repository's worktrees. Gone before another is added.
    for name, kind in vim.fs.dir(repo_dir(co.root)) do
      local stale = repo_dir(co.root) .. "/" .. name
      if kind == "directory" and stale ~= co.dir and not M.owner_of(stale) then
        vim.fn.delete(stale, "rf")
      end
    end
    git.run(co.root, { "worktree", "prune" }, function()
      git.run(co.root, { "-c", "core.hooksPath=/dev/null", "worktree", "add", "--detach",
        co.dir, target }, done)
    end)
  end
end

--- The folder `pane`'s checkout is in, once it holds `sha`: `cb(dir)`,
--- or `cb(nil)` where it could not be made or a later step overtook it,
--- or `cb(nil, "released")` where the review let it go meanwhile.
function M.at(pane, sha, cb)
  watch()
  local co = held[pane]
  if not co then
    co = { pane = pane, root = pane.root, dir = dir_for(pane), waiting = {} }
    held[pane] = co
  end
  co.want = sha
  table.insert(co.waiting, { sha = sha, cb = cb })
  pump(co)
end

--- Whether a checkout is in use for `pane`.
function M.has(pane)
  return held[pane] ~= nil
end

--- `pane`'s checkout gone: its buffers wiped, the language servers
--- rooted in it stopped -- a server per review left indexing a folder
--- that no longer exists -- and the worktree removed. `sync` on the way
--- out of the editor, where a removal left running is killed half done.
function M.release(pane, sync)
  local co = held[pane]
  if not co then
    return
  end
  held[pane] = nil
  -- Answered as gone, not as failed: a caller told the checkout could not
  -- be had falls back to a copy, and one released is not wanted at all.
  for _, w in ipairs(co.waiting) do
    w.cb(nil, "released")
  end
  co.waiting = {}
  if not sync then
    for _, client in ipairs(vim.lsp.get_clients()) do
      if client.root_dir and under(client.root_dir, co.dir) then
        client:stop()
      end
    end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if under(vim.api.nvim_buf_get_name(buf), co.dir) then
        drop(buf)
      end
    end
  end
  -- ...and the repository's folder once nothing is left in it:
  -- `delete(..., "d")` refuses a folder with another review's in it.
  local cmd = { "git", "-C", co.root, "worktree", "remove", "--force", co.dir }
  local parent = vim.fs.dirname(co.dir)
  if sync then
    vim.system(cmd):wait(10000)
    vim.fn.delete(parent, "d")
  else
    vim.system(cmd, {}, vim.schedule_wrap(function()
      vim.fn.delete(parent, "d")
    end))
  end
end

--- Every checkout removed, waited for: on the way out of the editor.
function M.release_all()
  for pane in pairs(held) do
    M.release(pane, true)
  end
end

--- Whether commit files are read out of a checkout at all.
function M.enabled()
  return config.show.checkout ~= false
end

return M
