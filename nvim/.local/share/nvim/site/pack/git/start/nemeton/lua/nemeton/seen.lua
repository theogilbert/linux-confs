-- What the forge last said was open here.
--
-- `:Nemeton open` asks for a number and completes over the merge
-- requests you could mean, which is a list only the forge has -- so the
-- prompt used to wait for `glab` before it could be typed into. A
-- subprocess and a round trip is a second on a good day and five on a
-- bad one, and a prompt that is not there yet is a prompt you have
-- already given up on: the whole reason it exists is that it is faster
-- than opening the queue.
--
-- So the answer from last time is written down, and the prompt comes up
-- on it immediately. The forge is still asked -- in the background, with
-- the window already on the screen -- and what it says replaces the list
-- under the menu and goes back to disk for next time.
--
-- What is written is a number, a title, a branch and a state per merge
-- request: what the completion draws, and what an editor started on a
-- branch needs to know which review to open (`M.here`) without asking
-- anybody. Not the author, not the description. A cache is a thing that can be deleted at
-- any moment without anybody noticing, and the smallest one that answers
-- the question is the one that stays true longest.
--
-- Nothing here is trusted to be current. It is what was open the last
-- time anybody looked, offered while the forge is being asked, and
-- replaced the moment it answers. A number typed over the top of it is
-- opened whether or not this file has ever heard of it.

local config = require("nemeton.config")

local M = {}

-- The whole file, read once per editor session. nil is "not read yet";
-- an empty table is a file that was not there, which is the ordinary
-- case on the first run and not an error.
local all = nil

--- Where it lives: beside the log and beside what the composer kept, in
--- XDG's state directory. A cache rather than either of those, and it
--- would go under `XDG_CACHE_HOME` if the other two were not already
--- here -- one directory per plugin is easier to find and easier to
--- delete than two.
function M.path()
  local configured = config.list.remember_path
  if type(configured) == "string" and configured ~= "" then
    return vim.fn.expand(configured)
  end
  local base = vim.uv.os_getenv("XDG_STATE_HOME")
  if not base or base == "" then
    local home = vim.uv.os_homedir()
    if not home then
      return nil
    end
    base = home .. "/.local/state"
  end
  return base .. "/nemeton/merge-requests.json"
end

local function mkdir_p(dir)
  if vim.uv.fs_stat(dir) then
    return true
  end
  local parent = dir:match("^(.*)/[^/]+$")
  if parent and parent ~= "" and not mkdir_p(parent) then
    return false
  end
  -- 0700, like the log's and the composer's: this names projects and the
  -- things people are reviewing on them, and that is nobody else's on a
  -- shared machine.
  vim.uv.fs_mkdir(dir, tonumber("700", 8))
  return vim.uv.fs_stat(dir) ~= nil
end

--- Everything on disk, with the repositories that have gone dropped.
---
--- Pruned by whether the checkout is still there rather than by age: a
--- merge request list goes stale in an afternoon and it does not matter
--- that it has -- it is replaced by the fetch it is shown alongside --
--- but a repository somebody deleted last year is an entry that will
--- never be looked at again and never be replaced either. Once per
--- editor session is exactly often enough to notice.
local function load()
  if all then
    return all
  end
  all = {}
  local path = M.path()
  local stat = path and vim.uv.fs_stat(path)
  if not stat then
    return all
  end
  local fd = vim.uv.fs_open(path, "r", tonumber("600", 8))
  if not fd then
    return all
  end
  local text = vim.uv.fs_read(fd, stat.size, 0)
  vim.uv.fs_close(fd)
  local ok, decoded = pcall(vim.json.decode, text or "", {
    luanil = { object = true, array = true },
  })
  if not (ok and type(decoded) == "table") then
    -- A file this plugin cannot read is a file it overwrites. This one
    -- is a cache: there is nothing in it to recover and nothing lost by
    -- starting again.
    return all
  end
  for root, list in pairs(decoded) do
    if not vim.uv.fs_stat(root) then
      require("nemeton.snapshot").drop_all(root)
    elseif type(list) == "table" then
      local rows = {}
      for _, one in ipairs(list) do
        if type(one) == "table" and type(one.iid) == "number" then
          table.insert(rows, {
            iid = one.iid,
            title = type(one.title) == "string" and one.title or "",
            branch = type(one.branch) == "string" and one.branch or nil,
            state = type(one.state) == "string" and one.state or nil,
            visited = type(one.visited) == "string" and one.visited or nil,
            seen_sha = type(one.seen_sha) == "string" and one.seen_sha or nil,
            seen_notes = type(one.seen_notes) == "number" and one.seen_notes or nil,
          })
        end
      end
      if #rows > 0 then
        all[root] = rows
      end
    end
  end
  return all
end

--- What is kept of a merge request.
local function row(mr)
  return {
    iid = mr.iid,
    title = mr.title or "",
    branch = mr.source_branch,
    state = mr.state,
  }
end

--- What `before` says of your last visit, carried onto `now`: the
--- forge's answer is the rest of a row, and knows nothing of this.
local function keep_visit(now, before)
  if before then
    now.visited, now.seen_sha, now.seen_notes = before.visited, before.seen_sha, before.seen_notes
  end
end

--- The reviews kept of what `root` no longer has open (`snapshot.lua`):
--- one written down before and not as open now. Its own function
--- because every write below can be the one that learns it.
local function forget_reviews(root, before, now)
  local open = {}
  for _, one in ipairs(now or {}) do
    if one.state == nil or one.state == "opened" then
      open[one.iid] = true
    end
  end
  for _, one in ipairs(before or {}) do
    if not open[one.iid] then
      require("nemeton.snapshot").drop(root, one.iid)
    end
  end
end

local function save()
  local path = M.path()
  if not path then
    return
  end
  local dir = path:match("^(.*)/[^/]+$")
  if dir and not mkdir_p(dir) then
    return
  end
  -- Written aside and moved into place, like the composer's: half a
  -- JSON object is a file that loses every repository in it rather than
  -- the one being written.
  local tmp = path .. ".new"
  local fd = vim.uv.fs_open(tmp, "w", tonumber("600", 8))
  if not fd then
    return
  end
  vim.uv.fs_write(fd, vim.json.encode(all or {}), 0)
  vim.uv.fs_close(fd)
  vim.uv.fs_rename(tmp, path)
end

--- What was open in `root` the last time anybody looked: a list of
--- `{ iid = ..., title = ... }` in the order the forge gave them, and
--- an empty one for a repository this has never seen.
function M.get(root)
  if not (config.list.remember and root) then
    return {}
  end
  return load()[root] or {}
end

--- ...and that, written down. `list` is what `glab mr list` answered
--- with, whole objects and all; what is kept is the number and the
--- title of each.
---
--- An empty answer is written as well, and on purpose: a project whose
--- last merge request was merged this morning should stop offering it.
function M.set(root, list)
  if not (config.list.remember and root and type(list) == "table") then
    return
  end
  load()
  -- ...but not when you last looked, which the forge does not know and
  -- which only a review opening writes (`M.visit`).
  local visited = {}
  for _, one in ipairs(all[root] or {}) do
    visited[one.iid] = one
  end
  local rows = {}
  for _, mr in ipairs(list) do
    if type(mr) == "table" and mr.iid then
      local one = row(mr)
      keep_visit(one, visited[mr.iid])
      table.insert(rows, one)
    end
  end
  forget_reviews(root, all[root], rows)
  all[root] = rows
  save()
end

--- What a list of merged or closed merge requests says about the open
--- ones written down: that these are not, any more. Not `M.set`, which
--- is the whole list of what is open -- this is a list of something
--- else, and only takes away.
function M.gone(root, list)
  if not (config.list.remember and root and type(list) == "table") then
    return
  end
  local shut = {}
  for _, mr in ipairs(list) do
    if type(mr) == "table" and mr.iid and mr.state and mr.state ~= "opened" then
      shut[mr.iid] = true
    end
  end
  local before = load()[root] or {}
  local rows = vim.tbl_filter(function(one)
    return not shut[one.iid]
  end, before)
  if #rows == #before then
    return
  end
  forget_reviews(root, before, rows)
  all[root] = rows
  save()
end

--- One merge request, written down or brought up to date: a review
--- that opened is a merge request this repository has had open, which
--- is what `M.here` looks for the next time the editor starts.
function M.note(root, mr)
  if not (config.list.remember and root and type(mr) == "table" and mr.iid) then
    return
  end
  load()
  local rows = all[root] or {}
  if mr.state and mr.state ~= "opened" then
    require("nemeton.snapshot").drop(root, mr.iid)
  end
  for i, one in ipairs(rows) do
    if one.iid == mr.iid then
      rows[i] = row(mr)
      keep_visit(rows[i], one)
      all[root] = rows
      save()
      return
    end
  end
  table.insert(rows, row(mr))
  all[root] = rows
  save()
end

--- That the review of `iid` was in front of you until now: what the
--- queue's mark for a merge request that moved since is measured
--- against (`M.visited`).
---
--- Three things and not one, because GitLab's `updated_at` is the time
--- the merge request's own fields last changed and nothing else: a
--- comment does not move it, and neither does a push (both checked on
--- a live forge). So `seen` also holds the head commit and the number
--- of comments that were in front of you -- `sha` and `user_notes_count`
--- are in every row of the listing, which is what the queue holds them
--- against -- and the time is for the rest: a title, a label, an
--- approval, a reviewer.
---
--- The editor's clock rather than the merge request's own `updated_at`,
--- because what you did in the review moves that too, and it is written
--- when the review opens, when it closes and when the editor quits, so
--- that what you did there is before it. UTC and in GitLab's own
--- spelling, to the second, so the two compare as strings.
function M.visit(root, iid, sha, notes)
  if not (config.list.remember and root and iid) then
    return
  end
  for _, one in ipairs(load()[root] or {}) do
    if one.iid == iid then
      one.visited = os.date("!%Y-%m-%dT%H:%M:%S")
      one.seen_sha = type(sha) == "string" and sha or one.seen_sha
      one.seen_notes = type(notes) == "number" and notes or one.seen_notes
      save()
      return
    end
  end
end

--- What each merge request of `root` was when last visited, by
--- number: `{ at, sha, notes }`.
function M.visited(root)
  local out = {}
  if config.list.remember and root then
    for _, one in ipairs(load()[root] or {}) do
      if one.visited then
        out[one.iid] = { at = one.visited, sha = one.seen_sha, notes = one.seen_notes }
      end
    end
  end
  return out
end

--- The branch HEAD is on in `root`, or nil on a detached one.
---
--- Read out of `.git` rather than asked of git: a subprocess for a
--- string sitting in a file is a subprocess too many, and this is read
--- while the editor starts. A worktree keeps its `.git` as a file
--- pointing at the real one, which is the one case worth following.
function M.head(root)
  local dot = root .. "/.git"
  local stat = vim.uv.fs_stat(dot)
  if stat and stat.type == "file" then
    local ok, lines = pcall(vim.fn.readfile, dot)
    local where = ok and (lines[1] or ""):match("^gitdir: (.+)$")
    if not where then
      return nil
    end
    dot = where:sub(1, 1) == "/" and where or (root .. "/" .. where)
  end
  local ok, head = pcall(vim.fn.readfile, dot .. "/HEAD")
  if not ok then
    return nil
  end
  return (head[1] or ""):match("^ref: refs/heads/(.+)$")
end

--- The open merge request the branch in front of you was last known to
--- have, out of this file alone: its number, and the repository and
--- branch it was found for -- or nil.
---
--- Off the disk and nothing else, because it is asked as the editor
--- starts, of every editor started in a repository: a `glab` call
--- there is a round trip paid by every `nvim` whether or not anybody
--- is reviewing anything. The root is found the same way, by looking
--- for `.git` rather than running git, and resolved as `rev-parse`
--- resolves it so that it is the key the file was written under.
---
--- What was open last time may be merged by now. That is the forge's
--- to say, and it says it when the review is asked for.
function M.here(cwd)
  if not config.list.remember then
    return nil
  end
  local found = vim.fs.root(cwd or vim.fn.getcwd(), ".git")
  local root = found and vim.uv.fs_realpath(found)
  local branch = root and M.head(root)
  if not branch then
    return nil
  end
  for _, one in ipairs(load()[root] or {}) do
    if one.branch == branch and (one.state == nil or one.state == "opened") then
      return one.iid, root, branch
    end
  end
  return nil
end

--- Forgets a repository, for the suite and for anybody who would rather
--- this plugin had never written the file.
function M.forget(root)
  if not root then
    return
  end
  load()
  require("nemeton.snapshot").drop_all(root)
  if all[root] then
    all[root] = nil
    save()
  end
end

return M
