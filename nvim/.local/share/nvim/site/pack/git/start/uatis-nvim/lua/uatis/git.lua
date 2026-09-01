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
---
--- `core.quotepath=false` because git escapes any byte outside ASCII in
--- the paths it prints -- `"caf\303\251.lua"`, quotes and all -- and a
--- path that has been through that matches no buffer name we could look
--- it up by, so the file silently drops out of everything downstream.
local function run(root, args, cb)
  local cmd = { "git", "--no-pager", "-c", "core.quotepath=false", "-C", root }
  vim.list_extend(cmd, args)
  -- `text = true` is load-bearing beyond the type it returns: it also
  -- turns CRLF into LF. A repository that stores its line endings the
  -- Windows way hands back a blob whose every line ends in `\r`, while
  -- the buffer beside it has them stripped into `fileformat=dos` -- so
  -- without this every line of every file would differ from itself and
  -- the whole review would be one wholesale rewrite.
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
---
--- cb(text|nil, err) -- nil is a failed call, and `err` is git's own
--- complaint about it.
--- Spelled out against the reader's own git config, which is allowed to
--- make `git diff` print something no unified-diff parser can read. This
--- is the only place the plugin parses git's own diff output rather than
--- diffing text itself, so it is the only place that breaks -- and it
--- breaks silently, as an empty file list beside a buffer visibly full
--- of changes. `diff.external`/`GIT_EXTERNAL_DIFF` (difftastic, very
--- plausibly, on a machine that has it) replaces the output wholesale;
--- `color.ui = always` wraps every line in escapes; `diff.noprefix` and
--- `diff.mnemonicPrefix` rename the `a/`/`b/` the header is found by.
local DIFF_FLAGS = { "--no-ext-diff", "--no-color", "--no-textconv",
  "--src-prefix=a/", "--dst-prefix=b/" }

local function diff(root, revs, cb)
  local args = { "diff" }
  vim.list_extend(args, DIFF_FLAGS)
  vim.list_extend(args, revs)
  run(root, args, function(ok, out, err)
    -- The error text is handed back rather than swallowed: the caller
    -- draws an empty list either way, and "no files changed" and "git
    -- refused to answer" look identical on screen unless it can say so.
    if ok then
      cb(out)
    else
      cb(nil, vim.trim(err or ""))
    end
  end)
end

function M.diff_since(root, rev, cb)
  diff(root, { rev }, cb)
end

--- Diff BETWEEN two revisions, `git diff <a> <b>`. What one commit did,
--- when `a` is its parent -- the working tree has no part in it, which is
--- the whole difference from `diff_since`: a commit is finished, and what
--- it changed cannot depend on what is unsaved now.
function M.diff_range(root, a, b, cb)
  diff(root, { a, b }, cb)
end

--- The commits of `from..to`, oldest first: cb({ { sha, short, date,
--- author, subject }, ... }).
---
--- `--first-parent`, so a branch that merged the base back into itself
--- is a list of the commits its author wrote rather than of everything
--- that has ever been merged into it. Reviewing means reading what
--- somebody did, in the order they did it, and the merges they took in
--- along the way are not that.
---
--- Oldest first because that is the order the work happened in, and the
--- order `12/17` has to count in for the number to mean anything.
function M.commits_between(root, from, to, cb)
  run(root, { "log", "--first-parent", "--reverse", "--date=short",
    "--format=%H%x09%h%x09%ad%x09%an%x09%s", from .. ".." .. to },
    function(ok, out)
      if not ok then
        cb({})
        return
      end
      local commits = {}
      for line in out:gmatch("[^\r\n]+") do
        local sha, short, date, author, subject =
          line:match("^(%S+)\t(%S+)\t([^\t]*)\t([^\t]*)\t(.*)$")
        if sha then
          table.insert(commits, {
            sha = sha, short = short, date = date,
            author = author, subject = subject,
          })
        end
      end
      cb(commits)
    end)
end

--- Files git has never been told about: `ls-files --others
--- --exclude-standard`, so what `.gitignore` covers is not in it.
--- cb({ path, ... }), repo-relative.
---
--- `-z`, because this is the one list whose entries are paths straight
--- from the filesystem: a newline is a legal character in a filename and
--- splitting on it would turn one file into two that do not exist.
function M.untracked(root, cb)
  run(root, { "ls-files", "--others", "--exclude-standard", "-z" }, function(ok, out)
    if not ok then
      cb({})
      return
    end
    local paths = {}
    for path in out:gmatch("([^%z]+)") do
      table.insert(paths, path)
    end
    cb(paths)
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

--- Runs git and WAITS, up to `timeout` ms. Returns stdout, or nil.
---
--- The one synchronous call in this module, and it exists for the
--- command line: `:Uatis <Tab>` is a question with a deadline -- an
--- answer that arrives after the reader has finished typing is not an
--- answer. Everything else here is a callback for the good reason that
--- nothing else is waiting on a keypress.
local function sync(dir, args, timeout)
  local cmd = { "git", "--no-pager", "-c", "core.quotepath=false", "-C", dir }
  vim.list_extend(cmd, args)
  local ok, res = pcall(function()
    return vim.system(cmd, { text = true }):wait(timeout or 300)
  end)
  if not ok or not res or res.code ~= 0 then
    return nil
  end
  return res.stdout or ""
end

local REFS = { "for-each-ref",
  "--format=%(refname)%09%(refname:short)%09%(creatordate:short)",
  "refs/heads", "refs/tags", "refs/remotes" }

--- `%x09`, not `%09`: `git log` takes the hex escape, and `%09` reaches
--- the output as the two characters it looks like -- which is one field,
--- and no commits at all by the time it has been split.
---
--- The author date rather than the committer's: it is the date the work
--- was done, which is the one the reader is remembering, and a rebase
--- does not move it.
local function log_args(limit)
  return { "log", "--all", "--date=short", "--format=%h%x09%ad%x09%s",
    "-n", tostring(limit) }
end

local function parse_refs(out)
  local groups = { branch = {}, tag = {}, remote = {} }
  for line in (out or ""):gmatch("[^\r\n]+") do
    local full, short, date = line:match("^(%S+)\t([^\t]+)\t?(.*)$")
    if full then
      local kind = full:match("^refs/tags/") and "tag"
        or full:match("^refs/remotes/") and "remote"
        or "branch"
      table.insert(groups[kind], { name = short, kind = kind, date = date })
    end
  end
  local refs = {}
  for _, kind in ipairs({ "branch", "tag", "remote" }) do
    vim.list_extend(refs, groups[kind])
  end
  return refs
end

local function parse_commits(out)
  local commits = {}
  for line in (out or ""):gmatch("[^\r\n]+") do
    local sha, date, subject = line:match("^(%S+)\t([^\t]*)\t(.*)$")
    if sha then
      table.insert(commits, { sha = sha, date = date, subject = subject })
    end
  end
  return commits
end

--- Every ref, with what each one is and when it was made:
--- cb({ { name, kind, date }, ... }), where kind is "branch", "tag" or
--- "remote" and date is `YYYY-MM-DD`.
---
--- `creatordate`, not `committerdate`: an annotated tag is an object of
--- its own, with a tagger and no committer, so the column comes back
--- empty for exactly the refs a date is most wanted on.
---
--- Ordered by kind rather than by name. git answers in refname order,
--- which is `refs/heads`, then `refs/remotes`, then `refs/tags` -- so in
--- a repository with a few hundred branches the tags are past the end of
--- any list anyone looks at, and the reader concludes there are none.
--- Local branches first, then tags, then the remote-tracking refs, which
--- are the many and the least often typed.
function M.refs(root, cb)
  run(root, REFS, function(ok, out)
    cb(ok and parse_refs(out) or {})
  end)
end

--- ...and the same answer without waiting, for the command line. `dir`
--- need not be the repository root: git resolves it from anywhere
--- inside one.
function M.refs_sync(dir, timeout)
  return parse_refs(sync(dir, REFS, timeout))
end

--- Recent commits, newest first: cb({ { sha, date, subject }, ... }),
--- with the date as `YYYY-MM-DD`.
---
--- `--all` rather than HEAD: the commit worth comparing against is as
--- likely to be on the branch you are about to review as on the one you
--- are standing on. Abbreviated shas, because that is what a reader
--- copies out of a forge page or a `git log` and what git resolves back.
function M.commits(root, limit, cb)
  run(root, log_args(limit), function(ok, out)
    cb(ok and parse_commits(out) or {})
  end)
end

--- ...and the waiting version, for the command line.
function M.commits_sync(dir, limit, timeout)
  return parse_commits(sync(dir, log_args(limit), timeout))
end

return M
