-- The project's issues, on disk, and kept in step with the forge.
--
-- What is kept is `nemeton.issues`'s: every issue and every comment on
-- it, as one record each. This is where that lives between editor
-- sessions and how it is brought up to date, which is three questions
-- asked three ways, because an issue changes in three ways the forge
-- tells apart:
--
--   * Its own fields -- title, description, labels, state, who it is
--     assigned to. Those move its `updated_at`, so the issues changed
--     since the newest one kept are asked for by `updatedAfter`, with
--     their comments, and that is the whole of a sync most of the time.
--   * A comment added. That does *not* move the issue's `updated_at`
--     (nor does a reaction, a link, or a mention from elsewhere: it is
--     the issue's own row that moves, and a comment is a row of its
--     own). It is an event, though, and the project's events since the
--     last sync name the issues that were commented on.
--   * A comment edited or deleted, or the issue deleted. Nothing says
--     so: no timestamp moves and no event is written. So once a week
--     (`issues.sweep_days`), and on `r` in the list, every issue's
--     comment ids and edit times are compared against what is kept, a
--     hundred issues a call and no bodies, and what differs is asked
--     for again.
--
-- The first sync of a project is all of it, oldest change first, and
-- written down as it goes: one that is broken off -- the editor closed,
-- the network gone -- carries on from the last issue it kept rather
-- than from the start.
--
-- None of it is the forge's word on anything. It is what a search is
-- run over and what the list draws while the forge is being asked; an
-- issue opened is asked for afresh, every time.

local config = require("nemeton.config")
local glab = require("nemeton.glab")
local issues = require("nemeton.issues")

local M = {}

-- The format of the file, which a file of another is not read as: it is
-- a cache, and one this plugin cannot read is one it starts again.
local VERSION = 1

-- root -> { project, store, syncing = { callbacks }, loaded }. Per root
-- and not per project because a root is what every caller has; two
-- checkouts of one project read one file.
local state = {}

local function mkdir_p(dir)
  if vim.uv.fs_stat(dir) then
    return true
  end
  local parent = dir:match("^(.*)/[^/]+$")
  if parent and parent ~= "" and not mkdir_p(parent) then
    return false
  end
  -- 0700, like the rest of what this plugin writes: what is in here is
  -- every issue of the project, confidential ones included.
  vim.uv.fs_mkdir(dir, tonumber("700", 8))
  return vim.uv.fs_stat(dir) ~= nil
end

--- The directory the files are in.
function M.dir()
  local configured = config.issues.cache_dir
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
  return base .. "/nemeton/issues"
end

--- The file a project is kept in: its path on the forge, with what a
--- file name cannot carry spelled out. `group/sub/proj` is
--- `group%2Fsub%2Fproj.json`, which is the forge's own spelling of the
--- same path in a URL and so the one somebody looking for it would try.
function M.file(project)
  local dir = M.dir()
  if not (dir and project) then
    return nil
  end
  local name = project:gsub("[^%w%-_.]", function(c)
    return ("%%%02X"):format(c:byte())
  end)
  return dir .. "/" .. name .. ".json"
end

local function read(project)
  local path = M.file(project)
  local stat = path and vim.uv.fs_stat(path)
  if not stat then
    return nil
  end
  local fd = vim.uv.fs_open(path, "r", tonumber("600", 8))
  if not fd then
    return nil
  end
  local text = vim.uv.fs_read(fd, stat.size, 0)
  vim.uv.fs_close(fd)
  local ok, decoded = pcall(vim.json.decode, text or "", {
    luanil = { object = true, array = true },
  })
  if not (ok and type(decoded) == "table" and decoded.version == VERSION) then
    return nil
  end
  local store = decoded.store
  if type(store) ~= "table" or type(store.issues) ~= "table" then
    return nil
  end
  -- JSON has no integer keys: the issues come back keyed by "12".
  local by_iid = {}
  for _, r in pairs(store.issues) do
    if type(r) == "table" and type(r.iid) == "number" then
      by_iid[r.iid] = r
    end
  end
  store.issues = by_iid
  return store
end

--- Writes what is kept for `project`, aside and moved into place: half a
--- file is every issue lost rather than the one being written.
local function write(project, store)
  if not config.issues.cache then
    return
  end
  local path = M.file(project)
  if not path then
    return
  end
  local dir = path:match("^(.*)/[^/]+$")
  if dir and not mkdir_p(dir) then
    return
  end
  -- A list and not the table as it is kept: an issue's number as a key
  -- is a sparse array to the encoder, which writes it as one.
  local list = {}
  for _, r in pairs(store.issues) do
    table.insert(list, r)
  end
  local out = vim.tbl_extend("force", {}, store, { issues = list })
  local tmp = path .. ".new"
  local fd = vim.uv.fs_open(tmp, "w", tonumber("600", 8))
  if not fd then
    return
  end
  vim.uv.fs_write(fd, vim.json.encode({ version = VERSION, project = project, store = out }), 0)
  vim.uv.fs_close(fd)
  vim.uv.fs_rename(tmp, path)
end

--- What is kept for `root`, read off the disk the first time: `cb(store,
--- project)`, or `cb(nil, nil, why)` for a checkout the forge will not
--- say the project of. A store that has never synced is empty, not nil.
function M.get(root, cb)
  local s = state[root]
  if s and s.store then
    cb(s.store, s.project)
    return
  end
  glab.project_path(root, function(project, err)
    if not project then
      cb(nil, nil, err or "no project")
      return
    end
    s = state[root] or {}
    state[root] = s
    s.project = project
    s.store = s.store or (config.issues.cache and read(project)) or issues.empty()
    cb(s.store, project)
  end)
end

--- What is kept for `root` if it has been read, without asking anybody:
--- the list draws this on the keypress.
function M.peek(root)
  return state[root] and state[root].store or nil
end

--- The comments past the first hundred of each record that has more,
--- onto the record, and `done()` once all of them are in.
local function rest_of_notes(root, records, done)
  local waiting = {}
  for _, r in ipairs(records) do
    if r.notes_after then
      table.insert(waiting, r)
    end
  end
  local function next_one()
    local r = table.remove(waiting)
    if not r then
      done()
      return
    end
    glab.issue_notes(root, r.iid, r.notes_after, function(conn)
      if not conn then
        -- Kept as far as it got: a search over most of a long thread
        -- is better than a sync that stops for it.
        r.notes_after = nil
        next_one()
        return
      end
      for _, n in ipairs(conn.nodes or {}) do
        table.insert(r.notes, issues.note_of(n))
      end
      local more = vim.tbl_get(conn, "pageInfo", "hasNextPage")
      r.notes_after = more and vim.tbl_get(conn, "pageInfo", "endCursor") or nil
      if r.notes_after then
        table.insert(waiting, r)
      end
      next_one()
    end)
  end
  next_one()
end

--- Asks for the issues `opts` describes a page at a time, merging each
--- into `store` as it lands, and `cb(ok, why)` at the end. `progress`
--- is told `(kept, total)` after each page.
local function pages(root, project, store, opts, progress, cb)
  local function ask(after)
    glab.issue_page(
      root,
      vim.tbl_extend("force", opts, { after = after, first = config.issues.page }),
      function(conn, err)
        if not conn then
          cb(false, err)
          return
        end
        local records = vim.tbl_map(issues.record, conn.nodes or {})
        rest_of_notes(root, records, function()
          issues.merge(store, records)
          local more = vim.tbl_get(conn, "pageInfo", "hasNextPage")
          local cursor = vim.tbl_get(conn, "pageInfo", "endCursor")
          if opts.resumable then
            -- Where to carry on from if this is the last page anybody
            -- sees -- and so written down with what it is the end of.
            store.resume = more and cursor or nil
            write(project, store)
          end
          if progress then
            progress(vim.tbl_count(store.issues), conn.count)
          end
          if more and cursor then
            ask(cursor)
          else
            cb(true)
          end
        end)
      end
    )
  end
  ask(opts.after)
end

--- The issues named, asked for again, fifty a call.
local function refetch(root, project, store, iids, cb)
  local batch = {}
  for i = 1, math.min(#iids, 50) do
    batch[i] = table.remove(iids, 1)
  end
  if #batch == 0 then
    cb(true)
    return
  end
  pages(root, project, store, { iids = batch }, nil, function(ok, err)
    if not ok then
      cb(false, err)
      return
    end
    refetch(root, project, store, iids, cb)
  end)
end

--- Today's date, the forge's way, `days` ago. The events take a date
--- and nothing finer, and they take it exclusively: "after the 15th"
--- is from the 16th. So the day before the last ask is what is asked
--- from, and an event seen twice is an issue fetched twice, which is
--- harmless.
local function date(days_ago)
  return os.date("!%Y-%m-%d", os.time() - (days_ago or 0) * 86400)
end

--- The issues commented on since `store.noted`, every page of events.
local function commented(root, store, cb)
  local since = store.noted
  if not since then
    cb({})
    return
  end
  local y, m, d = since:match("^(%d+)-(%d+)-(%d+)")
  local before = os.date(
    "!%Y-%m-%d",
    os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }) - 86400
  )
  local all = {}
  local function ask(page)
    glab.note_events(root, before, page, function(events, err)
      if type(events) ~= "table" then
        cb(nil, err)
        return
      end
      for _, iid in ipairs((issues.commented(events))) do
        table.insert(all, iid)
      end
      if #events >= 100 then
        ask(page + 1)
      else
        cb(all)
      end
    end)
  end
  ask(1)
end

--- Compares every issue against the forge, and asks again for what
--- differs: the weekly sweep.
local function sweep(root, project, store, cb)
  local stale, named = {}, {}
  local function ask(after)
    glab.issue_sweep(root, after, function(conn, err)
      if not conn then
        cb(false, err)
        return
      end
      local refetch_these, seen = issues.stale(store, conn.nodes)
      vim.list_extend(stale, refetch_these)
      for iid in pairs(seen) do
        named[iid] = true
      end
      local more = vim.tbl_get(conn, "pageInfo", "hasNextPage")
      local cursor = vim.tbl_get(conn, "pageInfo", "endCursor")
      if more and cursor then
        ask(cursor)
        return
      end
      issues.gone(store, named)
      refetch(root, project, store, stale, function(ok, why)
        if ok then
          store.swept = os.time()
        end
        cb(ok, why)
      end)
    end)
  end
  ask(nil)
end

--- Brings what is kept for `root` up to date, and `cb(ok, why)` once it
--- is: the whole project the first time, and after that what changed.
---
--- One at a time a project: a second caller while a sync is running
--- waits for that one rather than starting its own, since the answer is
--- the same and two of them write the same file.
---
--- `opts.sweep` is the comparison of every comment now rather than when
--- the week is up -- `r` in the list. `opts.progress(kept, total)` is
--- told how far the first sync has got, page by page.
function M.sync(root, opts, cb)
  opts = opts or {}
  cb = cb or function() end
  M.get(root, function(store, project, err)
    if not store then
      cb(false, err)
      return
    end
    local s = state[root]
    if s.waiting then
      table.insert(s.waiting, cb)
      return
    end
    s.waiting = { cb }
    local function finish(ok, why)
      write(project, store)
      local waiting = s.waiting
      s.waiting = nil
      for _, one in ipairs(waiting) do
        one(ok, why)
      end
    end

    if not store.complete then
      -- From the start, or from where a sync broken off got to.
      local started = date()
      pages(
        root,
        project,
        store,
        {
          after = store.resume,
          resumable = true,
        },
        opts.progress,
        function(ok, why)
          if ok then
            store.complete = true
            store.resume = nil
            store.noted = started
            store.swept = os.time()
          end
          finish(ok, why)
        end
      )
      return
    end

    -- What changed since: the issues' own fields first, then the
    -- comments the events name, then -- if the week is up -- everything.
    local before = store.cursor
    local asked = date()
    pages(root, project, store, { updated_after = before }, nil, function(ok, why)
      if not ok then
        finish(false, why)
        return
      end
      commented(root, store, function(iids, refused)
        if not iids then
          finish(false, refused)
          return
        end
        refetch(root, project, store, iids, function(fine, oops)
          if not fine then
            finish(false, oops)
            return
          end
          store.noted = asked
          local week = (config.issues.sweep_days or 7) * 86400
          if opts.sweep or not store.swept or os.time() - store.swept >= week then
            sweep(root, project, store, finish)
          else
            finish(true)
          end
        end)
      end)
    end)
  end)
end

--- Whether a sync is running for `root`.
function M.syncing(root)
  return state[root] ~= nil and state[root].waiting ~= nil
end

--- Puts one issue's latest into what is kept, asked of the forge in the
--- shape the cache keeps: what opening an issue does, so that the issue
--- you have just read is one a search finds as it now is.
function M.refresh_one(root, iid, cb)
  M.get(root, function(store, project)
    if not store then
      if cb then
        cb(false)
      end
      return
    end
    refetch(root, project, store, { iid }, function(ok)
      write(project, store)
      if cb then
        cb(ok)
      end
    end)
  end)
end

--- Forgets what is kept for `root`, on disk too: for the suite, and for
--- anybody who would rather it had never been written. `cb()` once the
--- file is gone -- straight away where this session has read it, and
--- after asking the forge which project it is where it has not.
function M.forget(root, cb)
  local s = state[root]
  state[root] = nil
  local function drop(project)
    local path = project and M.file(project)
    if path then
      os.remove(path)
    end
    if cb then
      cb()
    end
  end
  if s and s.project then
    drop(s.project)
    return
  end
  glab.project_path(root, drop)
end

return M
