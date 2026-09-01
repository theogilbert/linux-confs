-- Everything this plugin runs, written down.
--
-- A review is a sequence of subprocesses -- `glab` at the API, `git` at
-- the checkout -- and when one of them does something surprising the
-- question is always the same one: what exactly was run, where, and what
-- did it say. That answer belongs in a file rather than in a `:messages`
-- scrollback that the next redraw eats.
--
--   ~/.local/state/nemeton/nemeton.log
--
-- XDG's state directory, not cache and not config: a log is neither
-- disposable nor yours to edit.
--
-- What is never written here is the token. Not the configured one, not
-- the one typed at the prompt, not one that wandered into an argument or
-- into glab's stderr. The environment is logged by name and by
-- presence -- `GITLAB_TOKEN=<set>` -- because "was a token exported at
-- all" is the question a log has to answer and "which one" is the
-- question it must not. A log is a file that gets pasted into an issue.
--
-- Nothing in here may touch `vim.fn` or the editor API: the completion
-- half of a `vim.system` call runs in a fast event context, and this is
-- called from there. libuv and plain Lua io only.

local config = require("nemeton.config")

local M = {}

-- Once something is wrong with the file -- an unwritable directory, a
-- full disk -- stop trying. A plugin that cannot log is a plugin that
-- still reviews merge requests; one that says so on every API call is
-- worse than one that says nothing.
local disabled = false

-- A counter, so the `run` line and the `exit` line of the same command
-- can be found together when several are in flight -- which they are:
-- the metadata and the discussions go out at once.
local seq = 0

-- Whether this editor session has announced itself yet. Sessions
-- interleave in one file; a header says whose lines are whose.
local announced = false

local function expand(p)
  local home = vim.uv.os_homedir()
  if home and p:sub(1, 1) == "~" then
    return home .. p:sub(2)
  end
  return p
end

--- Where the log is. nil when there is nowhere sensible to put it, which
--- on a machine with no home directory is a real answer rather than a
--- reason to guess.
function M.path()
  local configured = config.log.path
  if type(configured) == "string" and configured ~= "" then
    return expand(configured)
  end
  local base = vim.uv.os_getenv("XDG_STATE_HOME")
  if not base or base == "" then
    local home = vim.uv.os_homedir()
    if not home then
      return nil
    end
    base = home .. "/.local/state"
  end
  return base .. "/nemeton/nemeton.log"
end

local function mkdir_p(dir)
  if vim.uv.fs_stat(dir) then
    return true
  end
  local parent = dir:match("^(.*)/[^/]+$")
  if parent and parent ~= "" and not mkdir_p(parent) then
    return false
  end
  -- 0700: the log names hosts, projects and branches, and none of that
  -- is anyone else's on a shared machine.
  vim.uv.fs_mkdir(dir, tonumber("700", 8))
  return vim.uv.fs_stat(dir) ~= nil
end

--- The path, with its directory made and its size checked. nil once
--- something is wrong enough with it to stop trying.
---
--- The rotation is one generation, at `max_bytes`: two files bound the
--- disk, and nobody looking for what went wrong ten minutes ago has ever
--- wanted the seventh.
local function prepare()
  local path = M.path()
  if not path then
    disabled = true
    return nil
  end
  local dir = path:match("^(.*)/[^/]+$")
  if dir and not mkdir_p(dir) then
    disabled = true
    return nil
  end
  local max = config.log.max_bytes
  if max and max > 0 then
    local st = vim.uv.fs_stat(path)
    if st and st.size > max then
      vim.uv.fs_rename(path, path .. ".old")
      -- The file that starts now needs its own header: a log you can
      -- only date by reading its predecessor is half a log.
      announced = false
    end
  end
  return path
end

local function stamp()
  local sec, usec = vim.uv.gettimeofday()
  return ("%s.%03d"):format(os.date("%Y-%m-%dT%H:%M:%S", sec), math.floor(usec / 1000))
end

--- Opened and closed per line, rather than held open for the session: a
--- handle kept across an `:mksession`-length afternoon is a handle
--- pointing at a file that rotation, or the user, may have moved. The
--- cost is an open() per subprocess, which is nothing next to the
--- subprocess.
local function write(path, line)
  local f = io.open(path, "a")
  if not f then
    disabled = true
    return
  end
  f:write(stamp(), " ", line, "\n")
  f:close()
end

local function append(line)
  if disabled then
    return
  end
  local path = prepare()
  if not path then
    return
  end
  if not announced then
    announced = true
    local v = vim.version()
    write(
      path,
      ("--- nemeton, nvim %d.%d.%d, pid %d"):format(v.major, v.minor, v.patch, vim.uv.os_getpid())
    )
  end
  write(path, line)
end

--- Takes a secret out of a string that should not have had one in it.
---
--- Belt and braces: the token is passed in the environment and never in
--- an argument, so nothing here should ever match. But "should never"
--- is the state of affairs before someone adds a `--token` flag, and a
--- log that leaks once has leaked. Applied to arguments and to the
--- stderr of a failed call, which is the other place a forge is capable
--- of echoing back what it was sent.
local function redact(s)
  s = tostring(s)
  s = s:gsub("glpat%-[%w%-_]+", "<redacted>")
  s = s:gsub("([Tt][Oo][Kk][Ee][Nn]%s*[=:]%s*)[^%s\"']+", "%1<redacted>")
  s = s:gsub("([Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]%s*[=:]%s*)[^%s\"']+", "%1<redacted>")
  s = s:gsub("([Aa]uthorization:%s*%S+%s+)%S+", "%1<redacted>")
  return s
end

--- The command, as a line you could almost paste into a shell.
local function argv(cmd)
  local parts = {}
  for _, a in ipairs(cmd) do
    a = redact(a)
    if a == "" or a:find("[%s\"']") then
      a = '"' .. a:gsub('"', '\\"') .. '"'
    end
    parts[#parts + 1] = a
  end
  return table.concat(parts, " ")
end

--- Which variables were exported, and their values -- except where the
--- name says the value is a secret, where only the fact is logged.
local function env_repr(env)
  if type(env) ~= "table" or not next(env) then
    return nil
  end
  local keys = vim.tbl_keys(env)
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    if
      k:upper():find("TOKEN")
      or k:upper():find("SECRET")
      or k:upper():find("PASSWORD")
      or k:upper():find("KEY")
    then
      parts[#parts + 1] = k .. "=<set>"
    else
      parts[#parts + 1] = k .. "=" .. redact(env[k])
    end
  end
  return table.concat(parts, " ")
end

local function first_line(s)
  local line = vim.trim((s or ""):match("^[^\n]*") or "")
  if #line > 200 then
    line = line:sub(1, 200) .. "…"
  end
  return line
end

--- Records a command about to run, and hands back the function that
--- records how it went:
---
---   local done = log.exec(cmd, { cwd = root, env = e, stdin = body })
---   ... done(res.code, res.stderr)
---
--- Two lines rather than one, written at the two ends: a call that never
--- comes back -- a hung network, a `glab` waiting on a prompt that is
--- not there -- is exactly the one worth having in the log, and it has
--- no completion to be logged at.
---
--- `stdin` is logged as a byte count. What a comment says is between the
--- reviewer and the merge request.
function M.exec(cmd, opts)
  if not config.log.enabled or disabled then
    return function() end
  end
  opts = opts or {}
  seq = seq + 1
  local id = seq
  local start = vim.uv.hrtime()

  local parts = { ("[%d] run  %s"):format(id, argv(cmd)) }
  if opts.cwd then
    parts[#parts + 1] = "cwd=" .. opts.cwd
  end
  local e = env_repr(opts.env)
  if e then
    parts[#parts + 1] = "env=" .. e
  end
  if type(opts.stdin) == "string" then
    parts[#parts + 1] = ("stdin=%dB"):format(#opts.stdin)
  end
  append(table.concat(parts, "  "))

  return function(code, stderr)
    local ms = math.floor((vim.uv.hrtime() - start) / 1e6)
    local line = ("[%d] exit %s  %dms"):format(id, tostring(code), ms)
    if code ~= 0 then
      local why = first_line(stderr)
      if why ~= "" then
        line = line .. "  " .. redact(why)
      end
    end
    append(line)
  end
end

return M
