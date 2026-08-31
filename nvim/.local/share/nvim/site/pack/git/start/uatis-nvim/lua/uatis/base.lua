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

--- Chooses the base: `name` if given, otherwise by asking.
---
--- The picker is `vim.ui.select`, so it is whatever the user has already
--- configured for choosing things rather than a list widget of this
--- plugin's own devising.
---
--- It offers the branch a review is almost always against -- whatever is
--- in force, and the conventional default names that exist here -- and
--- nothing else. Everything else is `:Uatis <ref>`, which takes any
--- revision git resolves, on the command line, with the plugin's own ref
--- completion behind it.
---
--- Two attempts at "everything else" came out of this picker and went
--- back in. A free-text row opening `vim.ui.input` was only usable
--- because it completed as you type, and `completion` is a field a
--- `vim.ui.input` replacement is free to drop -- the common ones do,
--- leaving a bare prompt for exactly the input nobody types from memory.
--- Listing every tag and branch instead is a list nobody reads, and
--- `vim.ui.select` may be a plain cursor list with nothing to filter it
--- by. The command line was better at this than either.
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

    -- The conventional default branches, and nothing else.
    --
    -- The list used to be every tag and every local branch. In a
    -- repository with a hundred of either that is not a list anyone
    -- reads -- and `vim.ui.select` is whatever picker the user has, which
    -- may be a plain cursor list with no way to filter it, so a long one
    -- cannot even be searched. A picker is for the answer you almost
    -- always want; `:Uatis <ref>` is for the rest, on the command line,
    -- with git's own ref completion behind it.
    --
    -- Verified before being offered, in `config.base.fallbacks` order:
    -- most repositories have exactly one of these three, and offering
    -- the two that are not there makes the short list wrong instead of
    -- merely short.
    M.get(root, function(current)
      local items, seen = {}, {}
      local function add(name)
        if name and name ~= "" and not seen[name] then
          seen[name] = true
          table.insert(items, { name = name })
        end
      end
      -- Whatever is in force first, detected or chosen: it is the answer
      -- most likely to be wanted, it is the one worth being able to see
      -- without leaving the picker, and when it was detected from
      -- `origin/HEAD` it is remote-qualified and in no other list here.
      add(current)

      local names = config.base.fallbacks
      local function try(i)
        local name = names[i]
        if not name then
          if #items == 0 then
            vim.notify("uatis: nothing to compare against in " .. root,
              vim.log.levels.ERROR)
            if cb then cb(nil) end
            return
          end
          vim.ui.select(items, {
            prompt = "uatis: base revision",
            format_item = function(item)
              return item.name == current and (item.name .. "  (current)")
                or item.name
            end,
          }, function(choice)
            commit(choice and choice.name or nil)
          end)
          return
        end
        if seen[name] then
          try(i + 1)
          return
        end
        git.verify_ref(root, name, function(exists)
          if exists then
            add(name)
          end
          try(i + 1)
        end)
      end
      try(1)
    end)
  end)
end

return M
