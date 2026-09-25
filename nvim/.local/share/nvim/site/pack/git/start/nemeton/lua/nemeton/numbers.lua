-- The things on this project that are named by a number: `#12` is an
-- issue and `!7` a merge request.
--
-- A review comment points at them -- "closes #12", "same fix as !7"
-- -- and GitLab turns the number into a link and a cross-reference on
-- the page it names, so the cost of the wrong number is a link to the
-- wrong argument and a note on the wrong issue saying so. Nobody
-- remembers the number; what they remember is roughly what it was
-- called, and that is what this completes over: the sigil, then the
-- first digits or the first letters of a title.
--
-- What is open, most recently touched first, which is the forge's own
-- order and the order somebody's memory of "that proxy one" is in.
-- One page of a hundred: past that a project has a list nobody types
-- a number out of. Asked when the composer opens rather than when the
-- sigil is typed, because completion is synchronous and a round trip
-- in the middle of a keystroke is a freeze -- and asked every time it
-- opens, since an issue is filed more often than a member joins: the
-- last answer stands while the next is on its way.

local glab = require("nemeton.glab")

local M = {}

--- The two sigils, and which list each one reaches for.
M.sigils = { ["#"] = "issues", ["!"] = "merge_requests" }

-- root -> { issues = list, merge_requests = list }, each
-- `{ iid, title }`, or {} for "asked, and the forge would not say".
local known = {}
local asking = {}

--- Forgets them: for a token that has changed or a session that has
--- ended.
function M.forget()
  known, asking = {}, {}
end

--- Asks for both lists, in the background.
---
--- Quietly on failure: a composer that completes nothing is a
--- composer, and an error in front of a half-written comment is not.
function M.prefetch(root)
  if not root then
    return
  end
  known[root] = known[root] or {}
  asking[root] = asking[root] or {}
  for _, kind in pairs(M.sigils) do
    if not asking[root][kind] then
      asking[root][kind] = true
      glab.numbered(root, kind, function(data)
        if not asking[root] then
          return
        end
        asking[root][kind] = nil
        local list = {}
        for _, one in ipairs(type(data) == "table" and data or {}) do
          if one.iid then
            table.insert(list, { iid = one.iid, title = one.title or "" })
          end
        end
        known[root][kind] = list
      end)
    end
  end
end

--- The ones worth offering for `prefix` -- what was typed after the
--- sigil, and empty when nothing was -- out of the list `sigil` names.
---
--- Digits match the front of the number, and anything else matches
--- anywhere in the title, case-insensitively: `#12` is typed by
--- somebody who knows the number, and `#proxy` by everybody else, for
--- whom "the proxy one" is what it is called.
function M.candidates(root, sigil, prefix)
  local list = known[root] and known[root][M.sigils[sigil] or ""]
  if not list then
    return {}
  end
  prefix = (prefix or ""):lower()
  local out = {}
  for _, one in ipairs(list) do
    if prefix == "" then
      table.insert(out, one)
    elseif prefix:match("^%d+$") then
      if tostring(one.iid):find(prefix, 1, true) == 1 then
        table.insert(out, one)
      end
    elseif one.title:lower():find(prefix, 1, true) then
      table.insert(out, one)
    end
  end
  return out
end

--- Neovim's `omnifunc`, which is Vim's: asked for the start of the word
--- first and for the matches second.
---
--- The word starts at the sigil, and the sigil is part of what is
--- inserted: `#12` is what GitLab links, and `12` is a number.
---
--- Preceded by nothing or by whitespace, like a mention: `foo#bar` is
--- a Ruby method and `great!` is a sentence. A `#` at the start of a
--- line with nothing after it yet is left alone as well -- it is how a
--- heading starts, and a menu on every heading is a menu switched off.
--- `-3` where the cursor is inside neither: cancel, and leave
--- completion mode rather than sitting in it with nothing to show.
function M.omnifunc(findstart, base)
  local root = require("nemeton.session").root()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local head = vim.api.nvim_get_current_line():sub(1, col)
  if findstart == 1 then
    local at = head:match("^()[#!][%w%._%-]+$")
      or head:match("^()![%w%._%-]*$")
      or head:match("[%s([{'\"]()[#!][%w%._%-]*$")
    return at and (at - 1) or -3
  end
  local sigil = (base or ""):sub(1, 1)
  local items = {}
  for _, one in ipairs(M.candidates(root, sigil, (base or ""):sub(2))) do
    table.insert(items, { word = sigil .. one.iid, menu = one.title })
  end
  return items
end

return M
