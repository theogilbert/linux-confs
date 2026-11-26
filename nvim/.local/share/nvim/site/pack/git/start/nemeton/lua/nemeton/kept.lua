-- What was written in the composer and not sent, kept until it is.
--
-- Closing the composer used to throw the paragraph away. Which is the
-- right answer for a window you opened by mistake and the wrong one for
-- every other reason a composer gets closed: the file it is about needs
-- looking at again, the test it is about has to be run, somebody walks
-- in. A review comment is prose, and prose that vanishes because you
-- went to check something is prose you write once and never twice.
--
-- So the buffer's contents outlive the window, and they outlive the
-- editor: `nvim` is restarted between reading a merge request and
-- finishing the sentence about it more often than anybody would like.
--
-- This is the one thing in this plugin that writes what you typed to
-- disk, which is a decision `nemeton.create` explicitly did not make --
-- "a plugin that starts writing half-finished merge requests into
-- somebody's state directory is a plugin that has to decide when to
-- delete them again". So here is that decision, and it is three rules:
-- an entry goes when the comment is sent or kept on the forge, it goes
-- when the composer is closed with nothing in it, and it goes when it
-- is `compose.remember_days` old. Anything the third rule catches is
-- something the reviewer walked away from a month ago.
--
-- Not the token, and not a comment already posted: what is here is what
-- has no other home. A comment kept for the review lives on the forge
-- as a draft note, which is why it is still there tomorrow and on
-- another machine.

local config = require("nemeton.config")
local jsonfile = require("common.store")

local M = {}

-- The whole file, read once per editor session. nil means "not read
-- yet"; a table with nothing in it is a file that was not there, which
-- is the ordinary case and not an error.
local all = nil

--- Where it lives: beside the log, in XDG's state directory. Neither
--- cache -- losing it loses what somebody wrote -- nor config, which is
--- a thing you edit.
function M.path()
  local configured = config.compose.remember_path
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
  return base .. "/nemeton/composing.json"
end

--- Everything on disk, with what has gone stale dropped.
---
--- Pruned on the way in rather than on a timer: this file is read once
--- per editor session, and once per editor session is exactly often
--- enough to notice that a comment nobody has finished in a month is a
--- comment nobody is going to.
local function load()
  if all then
    return all
  end
  all = {}
  local path = M.path()
  local decoded = jsonfile.read(path, { luanil = true })
  if next(decoded) == nil then
    -- A file this plugin cannot read is a file it overwrites. There is
    -- nothing to recover from a half-written one, and refusing to keep
    -- anything ever again because of it is the worse failure.
    return all
  end
  local days = config.compose.remember_days
  local cutoff = (type(days) == "number" and days > 0) and (os.time() - days * 86400) or nil
  for root, by_key in pairs(decoded) do
    if type(by_key) == "table" then
      local live = {}
      for key, entry in pairs(by_key) do
        if
          type(entry) == "table"
          and type(entry.text) == "string"
          and entry.text ~= ""
          and not (cutoff and type(entry.at) == "number" and entry.at < cutoff)
        then
          live[key] = entry
        end
      end
      if next(live) then
        all[root] = live
      end
    end
  end
  return all
end

local function save()
  local path = M.path()
  if not path then
    return
  end
  -- Written aside and moved into place: an editor killed halfway
  -- through a write is exactly the case this file exists for, and half
  -- a JSON object is a file that loses every comment in it rather than
  -- the one being written.
  jsonfile.write(path, all or {})
end

--- What was left in the composer for `key`, under `root`.
function M.get(root, key)
  if not (config.compose.remember and root and key) then
    return nil
  end
  local entry = (load()[root] or {})[key]
  return entry and entry.text or nil
end

--- ...and that, written down. An empty text forgets instead: the rule
--- is that what is remembered is what is in the buffer, so a composer
--- emptied and closed is a comment thrown away.
function M.set(root, key, text)
  if not (config.compose.remember and root and key) then
    return
  end
  load()
  if not text or vim.trim(text) == "" then
    return M.forget(root, key)
  end
  all[root] = all[root] or {}
  all[root][key] = { text = text, at = os.time() }
  save()
end

function M.forget(root, key)
  if not (root and key) then
    return
  end
  local by_key = load()[root]
  if not (by_key and by_key[key]) then
    return
  end
  by_key[key] = nil
  if not next(by_key) then
    all[root] = nil
  end
  save()
end

--- For the tests, and for anybody who has just changed the path.
function M.reread()
  all = nil
end

return M
