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

--- The key a chunk is marked under.
function M.fingerprint(c)
  return c.fp .. ":" .. c.added .. ":" .. c.removed
end

--- Whether this chunk of `f` is read.
function M.chunk_read(pane, f, c)
  local set = (pane.read or {})[f.path]
  return set ~= nil and set[M.fingerprint(c)] == true
end

--- Whether every chunk of `f` is read -- which is what a read FILE is.
function M.is_read(pane, f)
  for _, c in ipairs(f.chunks or M.chunks(f)) do
    if not M.chunk_read(pane, f, c) then
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
