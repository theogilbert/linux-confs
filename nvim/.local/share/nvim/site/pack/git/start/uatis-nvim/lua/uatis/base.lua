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
local prompt = require("uatis.prompt")

local M = {}

local chosen = {}   -- root -> name the user picked, this session
local detected = {} -- root -> name worked out for the repository
local kept = nil    -- root -> name picked in an earlier session, read from disk
local checked = {}  -- root -> the kept name has been verified to still exist

--- Where a choice of base branch is kept between sessions.
---
--- `config.base.remember` is the switch and, as a string, the file.
--- nil means it is off.
---
--- `state`, not `data`: XDG keeps them apart, and this is state by every
--- part of that distinction. It is per-machine (the paths in it are
--- absolute), it is not worth backing up, and losing it costs one
--- `<leader>gB` per repository -- while `data` is where a plugin puts
--- what it would be sorry to lose. Neovim puts its own shada and undo
--- history in `state` for the same reasons.
local function store_file()
  local where = config.base.remember
  if where == false or where == nil then
    return nil
  end
  if type(where) == "string" then
    return where
  end
  return vim.fs.joinpath(vim.fn.stdpath("state"), "uatis", "base.json")
end

--- What is on disk: { [repo root] = base name }.
---
--- Read straight from the file every time it is written back, and cached
--- for reading. Two editors open on two repositories is the normal case,
--- and a cached copy written back whole would have the second one
--- forgetting what the first had just decided.
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

local function write_store(root, name)
  local path = store_file()
  if not path then
    return
  end
  local all = read_store()
  all[root] = name
  kept = all
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  -- Failures are silent on purpose: not being able to remember a base
  -- branch is not a reason to interrupt someone who has just chosen one,
  -- and the choice itself is already in force for this session.
  pcall(vim.fn.writefile, { vim.json.encode(all) }, path)
end

local function kept_name(root)
  if kept == nil then
    kept = read_store()
  end
  return kept[root]
end

--- The repo root for wherever the user currently is.
--- cb(root|nil, path) -- `path` being what was asked about, which is
--- what an answer of nil has to name to be worth reading.
---
--- The buffer's own file when it has one, so the answer is about the
--- repository being edited rather than about wherever `:cd` last left the
--- editor -- those differ the moment a second repository is opened.
function M.root(cb)
  local file = vim.api.nvim_buf_get_name(0)
  local path = (file ~= "" and vim.bo.buftype == "") and file or vim.fn.getcwd()
  git.root(path, function(root)
    cb(root, path)
  end)
end

--- What is set for `root`, without going and finding out. nil means
--- "nothing chosen yet, nothing kept from last time and nothing detected
--- yet", not "no base branch".
function M.current(root)
  return chosen[root] or kept_name(root) or detected[root]
end

--- Where that answer came from: "chosen" here, "remembered" from a
--- previous session, "detected" from the repository. nil when there is
--- no answer yet.
function M.source(root)
  if chosen[root] then
    return "chosen"
  elseif kept_name(root) then
    return "remembered"
  elseif detected[root] then
    return "detected"
  end
  return nil
end

--- Chooses the base for `root`, and remembers it for next time.
---
--- A choice, not a detection: what was worked out from `origin/HEAD` or
--- from the conventional names is worked out again next session, because
--- that answer can change without anyone having decided anything.
function M.set(root, name)
  chosen[root] = name
  checked[root] = true
  write_store(root, name)
end

--- Drops what this SESSION knows about `root`, so the next `get` works
--- it out again. What is on disk stays there -- which is what makes this
--- the way a test asks "and what would a new session do?".
function M.forget(root)
  chosen[root], detected[root], checked[root] = nil, nil, nil
  kept = nil
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
  local known = chosen[root] or detected[root]
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

  -- A choice from an earlier session, checked once before it is used: a
  -- branch that was the base last week can have been merged and deleted
  -- since, and a base that no longer exists is worse than none -- it
  -- fails at the fork point, where the reason is two steps away from the
  -- thing that caused it. Gone, it is dropped and the repository is
  -- asked again.
  local last = kept_name(root)
  if last and not checked[root] then
    git.verify_ref(root, last, function(exists)
      checked[root] = true
      if exists then
        chosen[root] = last
        cb(last)
      else
        write_store(root, nil)
        M.get(root, cb)
      end
    end)
    return
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

--- What the menu says beside a candidate: when it was made, and -- for a
--- commit, whose sha says nothing at all -- what it did. The date leads,
--- so the column lines up and a year or a month is something the prompt
--- can be typed at.
local function said_of(date, subject)
  if date == "" or date == nil then
    return subject
  elseif subject == nil or subject == "" then
    return date
  end
  return date .. "  " .. subject
end

--- The candidates for "which revision": every ref, and the recent
--- commits, as `prompt.lua` items -- `word` to insert, `menu` for what
--- the row says about itself, `kind` for what it is.
---
--- One builder, because there are two places that ask: the prompt behind
--- `type a revision...` and the command line behind `:Uatis`. They
--- cannot present the same way -- the command line has no menu column --
--- but offering different candidates would make them two different
--- questions wearing one name.
function M.items(refs, commits)
  local items = {}
  for _, ref in ipairs(refs or {}) do
    table.insert(items, {
      word = ref.name, kind = ref.kind, menu = said_of(ref.date),
    })
  end
  for _, c in ipairs(commits or {}) do
    table.insert(items, {
      word = c.sha, kind = "commit", menu = said_of(c.date, c.subject),
    })
  end
  return items
end

--- ...read for `root`, asynchronously. cb(items).
function M.candidates(root, cb)
  git.refs(root, function(refs)
    git.commits(root, config.base.prompt_commits, function(commits)
      cb(M.items(refs, commits))
    end)
  end)
end

--- ...and without waiting, for the command line, which cannot be
--- answered later. `dir` need not be the repository root.
function M.candidates_sync(dir, timeout)
  return M.items(git.refs_sync(dir, timeout),
    git.commits_sync(dir, config.base.prompt_commits, timeout))
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
--- then a way to type anything else. `:Uatis <ref>` still takes any
--- revision git resolves, on the command line, and means the same thing
--- for one view rather than for the repository.
---
--- Its last row is the rest of git: `type a revision...`, which opens a
--- one-line prompt of the plugin's own (`prompt.lua`) completing every
--- branch, tag and remote-tracking ref in the repository. It is our
--- window rather than `vim.ui.input` for the reason the free-text row
--- was taken out once already -- `completion` is a field a `vim.ui.input`
--- replacement is free to ignore, and the common ones do, which leaves a
--- bare prompt for exactly the input nobody types from memory. Listing
--- every ref in the picker instead is a list nobody reads, and
--- `vim.ui.select` may be a plain cursor list with nothing to filter it
--- by; a short list plus somewhere to type is the shape that works
--- whatever the reader's UI turns out to be.
---
--- `cb(picked, root)` -- the root as well as the name, because what a
--- choice of base branch is worth doing to is everything already open
--- against the old one, and that is a question about a repository. Acting
--- on it belongs to whoever owns views and panes rather than here: this
--- module answers what the base branch IS, and nothing below it knows
--- there is such a thing as a window.
function M.select(name, cb)
  M.root(function(root, path)
    if not root then
      vim.notify("uatis: " .. path .. " is not inside a git repository",
        vim.log.levels.ERROR)
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

    -- The last row of the picker: everything the short list is not.
    -- Every ref in the repository and the last `base.prompt_commits`
    -- commits are read before the prompt goes up, so completing is a
    -- table lookup rather than a subprocess between keystrokes -- and
    -- `HEAD~3`, which no list can offer, is simply typed.
    --
    -- Commits are in it because a base is not always a name. The one
    -- worth comparing against is often the commit before a refactor
    -- landed, and nobody has its sha memorised -- so they carry their
    -- subject line, which is what the prompt matches them on.
    local function ask()
      M.candidates(root, function(items)
        prompt.open({
          prompt = "uatis: base revision",
          items = items,
        }, function(text)
          if not text then
            if cb then cb(nil) end
            return
          end
          verify(root, text, commit)
        end)
      end)
    end

    -- The conventional default branches, and nothing else.
    --
    -- The list used to be every tag and every local branch. In a
    -- repository with a hundred of either that is not a list anyone
    -- reads -- and `vim.ui.select` is whatever picker the user has, which
    -- may be a plain cursor list with no way to filter it, so a long one
    -- cannot even be searched. A picker is for the answer you almost
    -- always want, and the one row under it is for the rest.
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
          -- A repository whose branches are named nothing conventional
          -- lands here with an empty list, and that is the case the
          -- prompt is most needed in: it goes straight there rather than
          -- putting up a picker with one row saying "type it yourself".
          if #items == 0 then
            ask()
            return
          end
          table.insert(items, { prompt = true })
          vim.ui.select(items, {
            prompt = "uatis: base revision",
            format_item = function(item)
              if item.prompt then
                return "type a revision..."
              end
              return item.name == current and (item.name .. "  (current)")
                or item.name
            end,
          }, function(choice)
            if choice and choice.prompt then
              ask()
              return
            end
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
