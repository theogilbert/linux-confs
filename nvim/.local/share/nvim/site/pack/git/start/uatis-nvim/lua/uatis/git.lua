-- Async git. Every call goes through vim.system() and reports back via a
-- callback; nothing here blocks the UI.
--
-- The repo root is resolved once, up front, and then passed explicitly to
-- every function -- a comparison is scoped to one repository, so there
-- is no per-buffer path bookkeeping to do.
--
-- Reads are cheap to repeat and expensive to get wrong, so blobs and
-- commit patches are cached content-addressably (by revision + path). The
-- caches are never evicted; an editing session is short-lived and the whole
-- point is that stepping back to a commit you already looked at is
-- instant.

local M = {}

local blob_cache = {}  -- "root\0rev:path" -> string | false (confirmed miss)
local patch_cache = {} -- "root\0sha"      -> string

local function key(...)
  return table.concat({ ... }, "\0")
end

--- Runs git and hands (ok, stdout, stderr) back on the main loop.
local function run(root, args, cb)
  local cmd = { "git", "-C", root }
  vim.list_extend(cmd, args)
  vim.system(cmd, { text = true }, function(res)
    vim.schedule(function()
      cb(res.code == 0, res.stdout or "", res.stderr or "")
    end)
  end)
end

M.run = run

--- Repo root containing `path` (a file or directory). cb(root|nil).
---
--- Treats empty stdout as a failure independently of the exit code: an
--- interrupted git call can exit 0 with nothing on stdout, and an empty
--- root is not nil, so a plain `if not root` guard downstream would let it
--- through and produce garbage paths with nothing pointing at the cause.
function M.root(path, cb)
  local dir = vim.fn.isdirectory(path) == 1 and path or vim.fn.fnamemodify(path, ":h")
  vim.system({ "git", "-C", dir, "rev-parse", "--show-toplevel" }, { text = true }, function(res)
    vim.schedule(function()
      local out = res.code == 0 and vim.trim(res.stdout or "") or ""
      cb(out ~= "" and out or nil)
    end)
  end)
end

--- `git rev-parse --abbrev-ref <ref>`. Returns the literal string "HEAD"
--- when HEAD is detached, a branch name otherwise.
function M.abbrev_ref(root, ref, cb)
  run(root, { "rev-parse", "--abbrev-ref", ref }, function(ok, out)
    cb(ok and vim.trim(out) or nil)
  end)
end

--- `git rev-parse <rev>` -- full sha for any rev expression.
function M.rev_parse(root, rev, cb)
  run(root, { "rev-parse", rev }, function(ok, out)
    cb(ok and vim.trim(out) or nil)
  end)
end

--- Fork point of the two refs. A comparison is "everything src added since it
--- diverged from target", which is the merge base, not target's tip.
function M.merge_base(root, a, b, cb)
  run(root, { "merge-base", a, b }, function(ok, out)
    cb(ok and vim.trim(out) or nil)
  end)
end

--- File content at a revision, cached. cb(text|nil) -- nil means the path
--- did not exist at that revision, which is a normal answer (a file added
--- by the branch has no base-side blob), not an error.
function M.blob(root, rev, path, cb)
  local k = key(root, rev .. ":" .. path)
  local hit = blob_cache[k]
  if hit ~= nil then
    -- Deferred for the same reason as commit_patch: a cache hit must not
    -- answer sooner than a miss, or callbacks land out of order.
    vim.schedule(function()
      cb(hit or nil)
    end)
    return
  end
  run(root, { "show", rev .. ":" .. path }, function(ok, out)
    if not ok then
      blob_cache[k] = false
      cb(nil)
      return
    end
    -- git appends a trailing newline; splitting on \n without stripping it
    -- first manufactures a phantom empty final line, which then reads as a
    -- spurious one-line diff between two byte-identical revisions.
    local text = (out:gsub("\n$", ""))
    blob_cache[k] = text
    cb(text)
  end)
end

--- Diff from a revision to the WORKING TREE, `git diff <rev>` with no
--- second revision. Not a range: the in-place view measures the live
--- buffer against a revision, so the file list beside it has to count the
--- same thing -- committed and uncommitted changes together. A range would
--- list a file whose edit is still unsaved as unchanged.
---
--- Untracked files are absent, which is what `git diff` means; a file git
--- has never seen has no revision to be measured against.
function M.diff_since(root, rev, cb)
  run(root, { "diff", rev }, function(ok, out)
    cb(ok and out or nil)
  end)
end

--- The default branch, read off `origin/HEAD`. cb("origin/main"|nil).
---
--- Kept remote-qualified rather than trimmed to `main`. It is the ref that
--- is guaranteed to exist -- a clone need not have a local branch of that
--- name at all -- and it is the tip a forge would compare against, so a
--- local branch that has drifted cannot quietly change what this means.
function M.origin_head(root, cb)
  run(root, { "symbolic-ref", "--short", "refs/remotes/origin/HEAD" }, function(ok, out)
    local name = ok and vim.trim(out) or ""
    cb(name ~= "" and name or nil)
  end)
end

--- Does `name` name something? cb(true|false).
function M.verify_ref(root, name, cb)
  run(root, { "rev-parse", "--verify", "--quiet", name .. "^{commit}" }, function(ok, out)
    cb(ok and vim.trim(out) ~= "")
  end)
end

--- Branch and tag names, for command completion.
function M.refs(root, cb)
  run(root, { "for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/tags", "refs/remotes" }, function(ok, out)
    if not ok then
      cb({})
      return
    end
    local refs = {}
    for line in out:gmatch("[^\r\n]+") do
      table.insert(refs, line)
    end
    cb(refs)
  end)
end

return M
