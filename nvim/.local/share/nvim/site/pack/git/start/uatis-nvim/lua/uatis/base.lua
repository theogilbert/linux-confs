-- The base: what a diff view measures against.
--
-- Usually a branch, and named for the common case, but anything git can
-- resolve to a commit will do -- a tag, a hash, `HEAD~3`. "What has
-- changed since the release" is the same question as "what have I changed
-- since I branched", asked of a different revision.
--
-- One choice per repository, held for the editing session. Everything a
-- diff view shows follows from it, so it is worth being able to say once
-- and then forget -- and worth defaulting well enough that most of the
-- time it never has to be said at all.
--
-- The comparison is against the FORK POINT, `merge-base(base, HEAD)`, not
-- the base branch's tip. The same reason a forge shows a three-dot diff:
-- once the base branch moves on past where you branched off, its own
-- commits would otherwise appear in your diff as changes you have to
-- account for, reversed. What "since I branched" means does not change
-- because someone else pushed to main.

local config = require("uatis.config")
local git = require("uatis.git")

local M = {}

local chosen = {}   -- root -> name the user picked
local detected = {} -- root -> name worked out for the repository

--- The repo root for wherever the user currently is. cb(root|nil).
---
--- The buffer's own file when it has one, so the answer is about the
--- repository being edited rather than about wherever `:cd` last left the
--- editor -- those differ the moment a second repository is opened.
function M.root(cb)
  local file = vim.api.nvim_buf_get_name(0)
  local path = (file ~= "" and vim.bo.buftype == "") and file or vim.fn.getcwd()
  git.root(path, cb)
end

--- What is set for `root`, without going and finding out. nil means
--- "nothing chosen yet and nothing detected yet", not "no base branch".
function M.current(root)
  return chosen[root] or detected[root]
end

function M.set(root, name)
  chosen[root] = name
end

--- Drops everything remembered for `root`, so the next `get` detects
--- again. Exists for tests; nothing in the plugin calls it.
function M.forget(root)
  chosen[root], detected[root] = nil, nil
end

--- The base branch for `root`, detecting one if none has been chosen.
--- cb(name|nil).
---
--- Detection is `origin/HEAD` first -- the repository's own answer to the
--- question -- and a list of conventional names after it, because a
--- repository that was never cloned has no `origin/HEAD` to read and
--- guessing right there is the difference between the plugin working on a
--- local repo and asking about it before it will do anything.
function M.get(root, cb)
  local known = M.current(root)
  if known then
    -- Deferred, so `get` answers on the next tick whether or not it had to
    -- ask git. A callback that sometimes fires inline and sometimes does
    -- not makes every caller race against its own ordering.
    vim.schedule(function()
      cb(known)
    end)
    return
  end

  local function remember(name)
    detected[root] = name
    cb(name)
  end

  git.origin_head(root, function(name)
    if name then
      remember(name)
      return
    end
    local candidates = config.base.fallbacks
    local function try(i)
      local candidate = candidates[i]
      if not candidate then
        remember(nil)
        return
      end
      git.verify_ref(root, candidate, function(exists)
        if exists then
          remember(candidate)
        else
          try(i + 1)
        end
      end)
    end
    try(1)
  end)
end

--- Resolves the base branch into the revision a diff view compares
--- against. cb(name, sha) -- or cb(nil) having said why.
---
--- Shaped to be handed straight to `inline.open` as its resolver: the
--- label the winbar shows is the branch name, while the revision fetched
--- is the fork point, and those are two different strings.
function M.resolve(root, cb)
  M.get(root, function(name)
    if not name then
      vim.notify(
        "uatis: no base branch — set one with require('uatis').set_base_branch()",
        vim.log.levels.ERROR)
      cb(nil)
      return
    end
    git.merge_base(root, name, "HEAD", function(sha)
      if not sha then
        vim.notify("uatis: no common ancestor between '" .. name .. "' and HEAD",
          vim.log.levels.ERROR)
        cb(nil)
        return
      end
      cb(name, sha)
    end)
  end)
end

--- Completion for the revision prompt: every ref in the repository, tags
--- first, filtered by what has been typed.
---
--- A module-local pool rather than an argument because the completion is
--- reached through `v:lua`, from inside `input()`, where there is nowhere
--- to put a closure -- and emptied again when the prompt closes, so a
--- stale list cannot be offered against another repository.
---
--- Matched on the prefix, which is what every other completion in the
--- editor does: `orig<Tab>` for `origin/main`.
local completing = {}

function M.complete_rev(lead)
  return vim.tbl_filter(function(name)
    return name:find(lead, 1, true) == 1
  end, completing)
end

--- Checks a revision names something before it becomes the base.
---
--- `^{commit}` rather than a bare `rev-parse`, so a tag resolves to what
--- it points at and a string that is merely hex-shaped is refused.
local function verify(root, name, commit)
  git.verify_ref(root, name, function(exists)
    if not exists then
      vim.notify("uatis: unknown revision '" .. name .. "'", vim.log.levels.ERROR)
      commit(nil)
      return
    end
    commit(name)
  end)
end

--- Anything the list did not show: a remote branch, a tag from a hundred
--- of them, `HEAD~3`, a hash off a forge page.
---
--- A list you scroll is a list you stop reading, so the picker holds the
--- answers worth reading and this holds the rest, completed on as you
--- type -- tags first, then branches, then remotes, which is the order
--- `git.candidates` gives them in.
local function prompt(root, candidates, commit)
  completing = vim.tbl_map(function(c) return c.name end, candidates)
  -- Asked through `vim.ui.input`, like everything else this plugin asks,
  -- and `completion` is part of that contract -- `:h vim.ui.input`. Not
  -- every replacement honours it: a floating-window input has no wildmenu
  -- to offer and drops the field silently, and there is nothing to be done
  -- about that from here. Calling `vim.fn.input` to force the command line
  -- would take the user's own prompt away from them to work around their
  -- own plugin.
  vim.ui.input({
    prompt = "uatis: base revision: ",
    completion = "customlist,v:lua.require'uatis.base'.complete_rev",
  }, function(input)
    completing = {}
    local name = input and vim.trim(input) or ""
    if name == "" then
      commit(nil)
      return
    end
    verify(root, name, commit)
  end)
end

--- Chooses the base: `name` if given, otherwise by asking.
---
--- The picker is `vim.ui.select`, so it is whatever the user has already
--- configured for choosing things rather than a list widget of this
--- plugin's own devising.
---
--- `cb(picked, root)` -- the root as well as the name, because what a
--- choice of base branch is worth doing to is everything already open
--- against the old one, and that is a question about a repository. Acting
--- on it belongs to whoever owns views and panes rather than here: this
--- module answers what the base branch IS, and nothing below it knows
--- there is such a thing as a window.
function M.select(name, cb)
  M.root(function(root)
    if not root then
      vim.notify("uatis: not inside a git repository", vim.log.levels.ERROR)
      if cb then cb(nil) end
      return
    end

    local function commit(picked)
      if not picked then
        if cb then cb(nil) end
        return
      end
      M.set(root, picked)
      vim.notify("uatis: base " .. picked)
      if cb then cb(picked, root) end
    end

    if name and name ~= "" then
      verify(root, name, commit)
      return
    end

    git.candidates(root, function(candidates)
      M.get(root, function(default)
        -- The detected default first and once: it is remote-qualified
        -- (`origin/main`) and so is usually not in the local branch list at
        -- all, and it is the answer most likely to be wanted.
        local items = {}
        if default then
          table.insert(items, { name = default, kind = "branch" })
        end
        -- Then tags, then local branches, in the order they came. Remotes
        -- are left to the prompt: one per branch anybody ever pushed is
        -- most of what a repository has, and almost none of it is what you
        -- are about to pick.
        for _, c in ipairs(candidates) do
          if c.kind ~= "remote" and c.name ~= default then
            table.insert(items, c)
          end
        end
        if #items == 0 then
          vim.notify("uatis: nothing to compare against in " .. root,
            vim.log.levels.ERROR)
          if cb then cb(nil) end
          return
        end
        -- ...and the way out of the list, for everything it does not hold.
        table.insert(items, { kind = "prompt" })

        vim.ui.select(items, {
          prompt = "uatis: base revision",
          format_item = function(item)
            if item.kind == "prompt" then
              return "…another revision, by name or hash"
            end
            local label = item.kind == "tag" and (item.name .. "  (tag)") or item.name
            return item.name == M.current(root) and (label .. "  (current)") or label
          end,
        }, function(choice)
          if not choice then
            commit(nil)
          elseif choice.kind == "prompt" then
            prompt(root, candidates, commit)
          else
            commit(choice.name)
          end
        end)
      end)
    end)
  end)
end

return M
