-- What the reader has read, and what that is a statement about.
--
-- The unit is a CHUNK -- one hunk of a file's diff as git reports it,
-- read without context so that it is a run of changed lines and nothing
-- else -- and a mark is not on a position but on the chunk's content:
-- its lines, hashed, with the `@@` header left out. A chunk is read
-- while a chunk with that fingerprint is still in the file's diff, and a
-- file is read when every chunk of it is. Everything else follows:
--
--   - a commit landing on the branch resets the chunks it touched and
--     none of the others, in the same file or any other;
--   - the fork point moving resets a chunk only where its own lines
--     moved with it -- not where a base branch that grew above the
--     change shifted every hunk down by a few rows;
--   - a chunk edited after it was read stops being read the moment the
--     edit is written, and is read again when the edit is undone and
--     written: that IS the chunk that was read;
--   - a change read in the branch is read in the commit that made it,
--     where the commit's hunk is the same bytes as the branch's.
--
-- Kept between sessions, per repository, in `state` beside the base
-- choice: a review is rarely finished in one sitting, and the marks are
-- exactly the part of it that git cannot give back.
--
-- One unit, whichever backend drew the file. Structural mode draws
-- nothing for a chunk that is only formatting -- a block reindented, a
-- reflow -- and `]c` never stops there; so a file read stop by stop in
-- structural mode still had a chunk nobody could mark, and the row
-- stayed unread. Those chunks are not a second kind of mark: they are
-- set aside (`pane.hidden`, from the view that drew the file) for as
-- long as that is how the file is drawn, and the file is read when
-- every chunk that is NOT set aside is. Switch the file to line mode
-- and they are drawn, and count, and are unread. In memory only:
-- which chunks a backend hides is a fact about the backend and the
-- file, and is known again the moment the file is opened.

local config = require("uatis.config")

local M = {}

--- A file's chunks, from the hunks git gave it.
---
--- One per hunk: the fingerprint, its own delta LOC, and where it sits
--- on the new side, which is how a `]c` in the buffer finds the chunk
--- it is leaving. A file git reported no hunks for is ONE chunk covering
--- the whole of it: a binary, a mode change, a rename with nothing
--- inside it, or a file git has never been told about, whose `fp` is
--- then its content.
function M.chunks(f)
  local out = {}
  for _, h in ipairs(f.hunks or {}) do
    local added, removed = 0, 0
    for _, l in ipairs(h.lines or {}) do
      local c = l:sub(1, 1)
      if c == "+" then
        added = added + 1
      elseif c == "-" then
        removed = removed + 1
      end
    end
    table.insert(out, {
      fp = vim.fn.sha256(table.concat(h.lines or {}, "\n")),
      added = added,
      removed = removed,
      start = h.new_start,
      count = h.new_count,
    })
  end
  if #out == 0 then
    table.insert(out, {
      fp = f.fp or "",
      added = f.added or 0,
      removed = f.removed or 0,
      start = 1,
      count = math.huge,
    })
  end
  return out
end

--- The chunks of `f` that overlap new-side rows `lo..hi` -- the git
--- chunks a view hunk stands on. difftastic's hunks and git's do not
--- line up one to one: a lone unchanged row between two changes is one
--- node to difftastic and two chunks to git, so a stop `]c` makes can
--- cover several marks, and the count has to be taken in the same unit
--- the stop is.
function M.covering(f, lo, hi)
  local out = {}
  for _, c in ipairs(f.chunks or M.chunks(f)) do
    local s, e = c.start, c.start + math.max(c.count, 1) - 1
    if s <= hi and e >= lo then
      table.insert(out, c)
    end
  end
  return out
end

--- The chunks of `f` no hunk in `hunks` stands on: what the backend
--- that produced `hunks` drew nothing for. A set of fingerprints.
function M.hidden(f, hunks)
  local out = {}
  for _, c in ipairs(f.chunks or M.chunks(f)) do
    local s, e = c.start, c.start + math.max(c.count, 1) - 1
    local covered = false
    for _, h in ipairs(hunks or {}) do
      local lo = h.start_b
      local hi = lo + math.max(h.count_b, 1) - 1
      if s <= hi and e >= lo then
        covered = true
        break
      end
    end
    if not covered then
      out[M.fingerprint(c)] = true
    end
  end
  return out
end

--- The chunks of `f` that leaving stop `idx` of `stops` marks read,
--- given `left` -- the stops of this file already left, by key -- and
--- `target`, the row the cursor is going to. Records the stop in
--- `left` on the way, unless the target is still inside it.
---
--- A stop is the view's hunk; the mark is on git's chunk; and one git
--- chunk can carry several stops -- a hundred added lines is one chunk
--- to git and, to a backend that found blank rows inside it, five
--- stops. Marked on the first of them left, the chunk took the other
--- four with it: the header jumped by five on one press and stood
--- still on the next four. So a chunk is marked only once EVERY stop
--- on it has been left. Which stops have been left is a fact about the
--- session, held in memory and keyed by the stop's content; the mark,
--- which is what lasts, is still the chunk's.
function M.leave(left, stops, idx, f, target)
  local s = stops[idx]
  if not s then
    return {}
  end
  if not (target and target >= s.lo and target <= s.hi) then
    left[s.key] = true
  end
  local out = {}
  for _, c in ipairs(M.covering(f, s.lo, s.hi)) do
    local cs, ce = c.start, c.start + math.max(c.count, 1) - 1
    if not (target and target >= cs and target <= ce) then
      local all = true
      for _, o in ipairs(stops) do
        if o.lo <= ce and o.hi >= cs and not left[o.key] then
          all = false
          break
        end
      end
      if all then
        table.insert(out, c)
      end
    end
  end
  return out
end

--- How many of `stops` are behind the reader, and how many there are:
--- `{ done, total }`, or nil with nothing to step. A stop is read when
--- it has been left this session, or when every chunk it stands on is
--- marked -- which is what `x` in the list does, and what a mark kept
--- from the last session says.
function M.stops_read(pane, f, stops)
  local left = (pane.left or {})[f.path] or {}
  local done, total = 0, 0
  for _, s in ipairs(stops or {}) do
    total = total + 1
    local all = left[s.key] == true
    if not all then
      all = true
      for _, c in ipairs(M.covering(f, s.lo, s.hi)) do
        if not M.chunk_read(pane, f, c) then
          all = false
          break
        end
      end
    end
    if all then
      done = done + 1
    end
  end
  -- Nothing to step is nothing to count: `0/0 read` on a file the
  -- backend found no change in says less than saying nothing.
  if total == 0 then
    return nil
  end
  return { done = done, total = total }
end

--- The key a chunk is marked under.
function M.fingerprint(c)
  return c.fp .. ":" .. c.added .. ":" .. c.removed
end

--- Whether this chunk of `f` is read.
function M.chunk_read(pane, f, c)
  local set = (pane.read or {})[f.path]
  return set ~= nil and set[M.fingerprint(c)] == true
end

--- Whether this chunk of `f` is set aside: the backend drawing the file
--- reported nothing for it, so there is nothing in it to read.
function M.is_hidden(pane, f, c)
  local set = (pane.hidden or {})[f.path]
  return set ~= nil and set[M.fingerprint(c)] == true
end

--- Whether every chunk of `f` is read -- which is what a read FILE is.
--- A chunk set aside is not one to wait for.
function M.is_read(pane, f)
  for _, c in ipairs(f.chunks or M.chunks(f)) do
    if not M.chunk_read(pane, f, c) and not M.is_hidden(pane, f, c) then
      return false
    end
  end
  return true
end

--- Marks `chunks` of `f` read, or not, in memory. Returns whether
--- anything changed, so the caller can save and redraw only when it did.
function M.mark(pane, f, chunks, on)
  local set = pane.read[f.path] or {}
  local moved = false
  for _, c in ipairs(chunks) do
    local fp = M.fingerprint(c)
    if (set[fp] == true) ~= on then
      set[fp] = on or nil
      moved = true
    end
  end
  pane.read[f.path] = next(set) ~= nil and set or nil
  return moved
end

--- Where the marks are kept between sessions. `config.pane.remember_read`
--- is the switch and, as a string, the file; see `base.lua` for why
--- `state` and not `data`.
local function store_file()
  local where = config.pane.remember_read
  if where == false or where == nil then
    return nil
  end
  if type(where) == "string" then
    return where
  end
  return vim.fs.joinpath(vim.fn.stdpath("state"), "uatis", "read.json")
end

--- What is on disk: { [repo root] = { [path] = { fingerprint, ... } } }.
--- Read fresh every time, for the reason `base.lua` gives: two editors
--- on two repositories, and a cached copy written back whole would have
--- the second forgetting what the first had just decided.
local function read_store()
  local path = store_file()
  if not path then
    return {}
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or type(lines) ~= "table" or #lines == 0 then
    return {}
  end
  local decoded
  ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not ok or type(decoded) ~= "table" then
    return {}
  end
  return decoded
end

--- The marks kept for `root`, as a fresh table the list may write to.
function M.load(root)
  local entry = read_store()[root]
  local out = {}
  if type(entry) ~= "table" then
    return out
  end
  for path, fps in pairs(entry) do
    if type(fps) == "table" then
      local set = {}
      for _, fp in ipairs(fps) do
        if type(fp) == "string" then
          set[fp] = true
        end
      end
      if next(set) ~= nil then
        out[path] = set
      end
    end
  end
  return out
end

--- Past this many paths for one repository, the ones not in the list
--- being saved go first: a mark on a path no branch has touched in a
--- year is not worth the line.
local CAP = 4000

--- Writes the marks for `files` back -- those paths and no others, so a
--- second list on the same repository, scoped to a different subtree or
--- open on a different branch, keeps what it has said about its own.
---
--- Only fingerprints the file still has are written: a chunk edited out
--- from under its mark is not coming back in that shape, and a set that
--- kept every version of every chunk ever read would grow with the
--- branch's history rather than with its size.
function M.save(root, marks, files)
  local path = store_file()
  if not path then
    return
  end
  local all = read_store()
  local entry = type(all[root]) == "table" and all[root] or {}
  local listed = {}
  for _, f in ipairs(files) do
    listed[f.path] = true
    local set = marks[f.path]
    local kept = {}
    if set then
      for _, c in ipairs(f.chunks or M.chunks(f)) do
        local fp = M.fingerprint(c)
        if set[fp] then
          table.insert(kept, fp)
        end
      end
    end
    table.sort(kept)
    entry[f.path] = #kept > 0 and kept or nil
  end
  local n = 0
  for _ in pairs(entry) do
    n = n + 1
  end
  if n > CAP then
    for p in pairs(entry) do
      if not listed[p] then
        entry[p] = nil
      end
    end
  end
  all[root] = next(entry) ~= nil and entry or nil
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  -- Silent on failure, as the base choice is: the mark is already in
  -- force for this session, and not being able to keep it for the next
  -- is no reason to interrupt the one it was made in.
  pcall(vim.fn.writefile, { vim.json.encode(all) }, path)
end

return M
