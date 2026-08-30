-- Unified diff parser. Turns raw `git diff` / `git show` text into:
--
--   { { path, old_path, status = "M"|"A"|"D"|"R", binary, added, removed,
--       hunks = { { old_start, old_count, new_start, new_count, lines } } } }
--
-- `lines` keeps the raw " "/"+"/"-" prefixes verbatim -- the prefix is what
-- tells added, removed and context apart, so stripping it here would throw
-- away the only signal.
--
-- Handles renames, binary files (a hunk-less stub entry rather than a
-- crash), mode-only changes (no hunks, status stays "M") and an empty
-- patch (an empty result table).

local M = {}

local function new_file(path)
  return {
    path = path,
    old_path = nil,
    status = "M",
    binary = false,
    added = 0,
    removed = 0,
    hunks = {},
  }
end

--- Parses every `diff --git` section in `text`. Anything before the first
--- one (a commit header, for instance) is skipped, so raw `git show`
--- output can be passed straight in.
function M.parse(text)
  local files, cur, hunk = {}, nil, nil

  local function flush_hunk()
    if cur and hunk then
      table.insert(cur.hunks, hunk)
      hunk = nil
    end
  end
  local function flush_file()
    flush_hunk()
    if cur then
      table.insert(files, cur)
      cur = nil
    end
  end

  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local a, b = line:match("^diff %-%-git a/(.-) b/(.-)$")
    if a then
      flush_file()
      cur = new_file(b)
      if a ~= b then
        cur.status = "R"
        cur.old_path = a
      end
    elseif cur then
      local renamed_from = line:match("^rename from (.+)$")
      if renamed_from then
        cur.status = "R"
        cur.old_path = renamed_from
      elseif line:match("^new file mode") then
        cur.status = "A"
      elseif line:match("^deleted file mode") then
        cur.status = "D"
      elseif line:match("^Binary files .* differ$") then
        cur.binary = true
      else
        local os_, oc, ns, nc = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
        if os_ then
          flush_hunk()
          hunk = {
            old_start = tonumber(os_),
            old_count = oc ~= "" and tonumber(oc) or 1,
            new_start = tonumber(ns),
            new_count = nc ~= "" and tonumber(nc) or 1,
            lines = {},
          }
        elseif hunk then
          local c = line:sub(1, 1)
          if c == " " or c == "+" or c == "-" then
            table.insert(hunk.lines, line)
            if c == "+" then
              cur.added = cur.added + 1
            elseif c == "-" then
              cur.removed = cur.removed + 1
            end
          end
        end
      end
    end
  end
  flush_file()
  return files
end

--- Total added/removed across a parsed file list.
function M.total(files)
  local added, removed = 0, 0
  for _, f in ipairs(files) do
    added = added + f.added
    removed = removed + f.removed
  end
  return added, removed
end

--- Looks a file up by either side of a rename -- callers know the path
--- under one revision and may be asking about the other.
function M.find(files, path)
  for _, f in ipairs(files) do
    if f.path == path or f.old_path == path then
      return f
    end
  end
  return nil
end

return M
