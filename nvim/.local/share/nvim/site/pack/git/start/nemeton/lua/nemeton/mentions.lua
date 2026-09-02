-- The people you can put an `@` in front of.
--
-- A review comment names people: the person who wrote the line, the one
-- who owns the module, the one who has to say yes. GitLab turns
-- `@username` into a notification and everything else into text, so the
-- cost of misspelling one is a question nobody is told was asked.
--
-- `projects/:fullpath/users` is who GitLab will accept: the members of
-- the project and of the groups above it. Asked once per repository per
-- editor session -- a team changes about as often as a clone does --
-- and asked when the composer opens rather than when the `@` is typed,
-- because completion is synchronous and a round trip in the middle of a
-- keystroke is a freeze.

local glab = require("nemeton.glab")

local M = {}

-- root -> the list, or {} for "asked, and the forge would not say".
local known = {}
local asking = {}

--- Forgets them, for a token that has changed or a session that has
--- ended: who is on a project is a question about the host as much as
--- about the directory.
function M.forget()
  known, asking = {}, {}
end

--- Asks who is on the project, once, in the background.
---
--- Quietly on failure: the endpoint is one an ordinary token may not be
--- allowed near, and a composer that completes nothing is a composer.
--- An error in front of a half-written comment is not.
function M.prefetch(root)
  if not root or known[root] or asking[root] then
    return
  end
  asking[root] = true
  glab.project_users(root, function(data)
    asking[root] = nil
    local users = {}
    for _, u in ipairs(type(data) == "table" and data or {}) do
      if u.username then
        table.insert(users, { username = u.username, name = u.name })
      end
    end
    table.sort(users, function(a, b)
      return a.username < b.username
    end)
    known[root] = users
  end)
end

--- The ones worth offering for `prefix` -- which is what was typed
--- after the `@`, and is empty when nothing was.
---
--- Username first and display name second, both case-insensitively: you
--- reach for `@theo` as often as for `@tgilbert`, and which of the two
--- a forge calls a username is not something to have to remember. The
--- ones matched on their username come first, because that is what is
--- being typed.
function M.candidates(root, prefix)
  local users = known[root]
  if not users then
    return {}
  end
  prefix = (prefix or ""):lower()
  local first, second = {}, {}
  for _, u in ipairs(users) do
    if prefix == "" or u.username:lower():find(prefix, 1, true) == 1 then
      table.insert(first, u)
    elseif (u.name or ""):lower():find(prefix, 1, true) == 1 then
      table.insert(second, u)
    end
  end
  return vim.list_extend(first, second)
end

--- Neovim's `omnifunc`, which is Vim's: asked for the start of the word
--- first and for the matches second.
---
--- The word starts at the `@`, and the `@` is part of what is inserted:
--- what GitLab notifies on is `@username`, and a completion that leaves
--- the sigil to the user is one that silently posts a comment naming
--- nobody.
---
--- `-3` where there is no `@` behind the cursor: cancel, and leave
--- completion mode rather than sitting in it with nothing to show.
function M.omnifunc(findstart, base)
  local root = require("nemeton.session").root()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local head = vim.api.nvim_get_current_line():sub(1, col)
  if findstart == 1 then
    -- Preceded by nothing or by whitespace: an `@` in the middle of a
    -- word is an email address or a Lua operator, not a mention.
    local at = head:match("^()@[%w%._%-]*$") or head:match("[%s([{'\"]()@[%w%._%-]*$")
    return at and (at - 1) or -3
  end
  local items = {}
  for _, u in ipairs(M.candidates(root, (base or ""):gsub("^@", ""))) do
    table.insert(items, {
      word = "@" .. u.username,
      menu = u.name or "",
    })
  end
  return items
end

return M
