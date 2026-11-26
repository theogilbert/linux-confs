-- Small JSON files a plugin keeps between sessions: what was chosen,
-- what was read, what was left in a composer.
--
-- Read forgivingly -- a file that is missing, empty or half-written is
-- an empty store, since refusing to keep anything ever again because of
-- one bad write is the worse failure -- and written aside then moved
-- into place, so an editor killed mid-write leaves the last good file.

local M = {}

local uv = vim.uv or vim.loop

--- `stdpath(kind)/plugin/file`: kind "data" (default), "state" or
--- "cache".
function M.path(plugin, file, kind)
  return table.concat({ vim.fn.stdpath(kind or "data"), plugin, file }, "/")
end

--- What `path` holds, or `{}` where it holds nothing readable.
--- `opts.luanil` -- JSON null as nil rather than `vim.NIL`
function M.read(path, opts)
  opts = opts or {}
  local stat = path and uv.fs_stat(path)
  if not stat or stat.size == 0 then
    return {}
  end
  local fd = uv.fs_open(path, "r", 384)
  if not fd then
    return {}
  end
  local text = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  local ok, decoded = pcall(
    vim.json.decode,
    text or "",
    opts.luanil and { luanil = { object = true, array = true } } or {}
  )
  if not (ok and type(decoded) == "table") then
    return {}
  end
  return decoded
end

--- Writes `data` to `path` as JSON, its directory made if need be
--- (0700). True when it was written. `opts.mode` -- the file's mode, 0600
--- by default: what a plugin remembers about a reader is theirs, and not
--- anyone else's on a shared machine.
function M.write(path, data, opts)
  opts = opts or {}
  if not path then
    return false
  end
  local ok, text = pcall(vim.json.encode, data)
  if not ok then
    return false
  end
  local dir = vim.fn.fnamemodify(path, ":h")
  if vim.fn.isdirectory(dir) == 0 and vim.fn.mkdir(dir, "p", 448) == 0 then
    return false
  end
  local tmp = path .. ".new"
  local fd = uv.fs_open(tmp, "w", opts.mode or 384)
  if not fd then
    return false
  end
  local wrote = uv.fs_write(fd, text, 0)
  uv.fs_close(fd)
  if not wrote then
    pcall(uv.fs_unlink, tmp)
    return false
  end
  return uv.fs_rename(tmp, path) and true or false
end

return M
