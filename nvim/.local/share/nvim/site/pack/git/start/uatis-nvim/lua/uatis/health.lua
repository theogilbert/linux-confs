-- `:checkhealth uatis`
--
-- Three things decide whether this plugin can do its job, and all three
-- are outside it: the Neovim version, git, and difftastic. Each failure
-- has a different consequence, so each says what you lose rather than
-- just what is missing.
--
-- ...and then the fourth thing, which is this repository. "The pane says
-- nothing changed" has as many causes outside the plugin as in it -- no
-- `origin/HEAD` and no conventional branch to fall back on, a base whose
-- fork point is HEAD itself, a `git diff` the reader's own config
-- rewrites into something no parser reads -- and every one of them is a
-- fact that can simply be shown. `facts()` gathers them; `check()` says
-- what each one means.

local config = require("uatis.config")

local M = {}

local FLOOR = { 0, 12, 0 }

--- Runs git in `dir` and hands back trimmed stdout, or nil.
---
--- Synchronous, unlike everything else here: a health check is a report
--- printed once, on request, and an async one would have to invent a way
--- to say "not finished yet" in a buffer that has already been drawn.
local function git(dir, args, timeout)
  local cmd = { "git", "--no-pager", "-c", "core.quotepath=false", "-C", dir }
  vim.list_extend(cmd, args)
  local ok, res = pcall(function()
    return vim.system(cmd, { text = true }):wait(timeout or 2000)
  end)
  if not ok or not res or res.code ~= 0 then
    return nil
  end
  local out = vim.trim(res.stdout or "")
  return out ~= "" and out or nil
end

--- What this repository says about itself, as data.
---
--- Split out from the reporting so it can be tested: the interesting
--- part is which questions are asked, and `vim.health` has nowhere to
--- put an answer a test can read.
---
--- `dir` defaults to the working directory. Everything is nil when there
--- is no repository there, which is itself the first finding.
function M.facts(dir)
  dir = dir or vim.fn.getcwd()
  local out = { dir = dir }
  out.root = git(dir, { "rev-parse", "--show-toplevel" })
  if not out.root then
    return out
  end
  local base = require("uatis.base")
  out.head = git(out.root, { "rev-parse", "--abbrev-ref", "HEAD" })
  out.origin_head = git(out.root, { "symbolic-ref", "--short", "refs/remotes/origin/HEAD" })
  out.chosen = base.current(out.root)
  out.source = base.source(out.root)
  -- What a view opened right now would measure against: the same two
  -- steps `base.resolve` takes, asked here without waiting on it.
  local name = out.chosen or out.origin_head
  if not name then
    for _, candidate in ipairs(config.base.fallbacks) do
      if git(out.root, { "rev-parse", "--verify", "--quiet", candidate .. "^{commit}" }) then
        name = candidate
        break
      end
    end
  end
  out.base = name
  if name then
    out.fork_point = git(out.root, { "merge-base", name, "HEAD" })
    out.head_sha = git(out.root, { "rev-parse", "HEAD" })
  end
  -- The settings that rewrite `git diff` into something no unified-diff
  -- parser reads. The plugin spells every one of them out on the command
  -- line, so these are reported as facts and not as faults -- but they
  -- are the first thing anyone should be shown when a list is empty
  -- beside a buffer full of changes.
  out.diff_config = {}
  for _, key in ipairs({ "diff.external", "diff.noprefix", "diff.mnemonicPrefix",
    "color.ui", "core.quotepath" }) do
    -- Asked WITHOUT this file's own `-c` overrides, which git reports
    -- back as configuration: `git -c core.quotepath=false config --get
    -- core.quotepath` answers `false` in a repository that has never
    -- heard of the setting, and the report would be describing itself.
    local res = vim.system({ "git", "-C", out.root, "config", "--get", key },
      { text = true }):wait(2000)
    local value = res.code == 0 and vim.trim(res.stdout or "") or ""
    if value ~= "" then
      out.diff_config[key] = value
    end
  end
  return out
end

function M.check()
  vim.health.start("uatis")

  local v = vim.version()
  if vim.version.ge({ v.major, v.minor, v.patch }, FLOOR) then
    vim.health.ok(("Neovim %d.%d.%d"):format(v.major, v.minor, v.patch))
  else
    vim.health.error(
      ("Neovim %d.%d.%d is too old"):format(v.major, v.minor, v.patch),
      { ("uatis needs %d.%d or newer: the rendering uses inline virtual text, "):format(FLOOR[1], FLOOR[2])
        .. "multiline hl_eol ranges, statuscolumn and nvim_win_text_height" })
  end

  if vim.fn.executable("git") == 1 then
    vim.health.ok("git")
  else
    vim.health.error("git is not on your PATH", { "nothing works without it" })
  end

  local difft = config.diff.struct.bin
  if vim.fn.executable(difft) == 1 then
    local out = vim.system({ difft, "--version" }, { text = true }):wait()
    local version = vim.trim((out.stdout or ""):match("^[^\n]*") or "")
    vim.health.ok(version ~= "" and version or difft)
  else
    vim.health.warn(("%s is not on your PATH"):format(difft), {
      "structural diffing is difftastic, and there is no substitute for it here",
      "without it the diff is `vim.diff`, which cannot tell reindentation from a rewrite",
      "https://difftastic.wilfred.me.uk/",
    })
  end

  -- Neovim's parsers, and nothing to do with the diff: difftastic brings
  -- its own and this plugin never sees them. These colour the lines the
  -- branch REMOVED, which are drawn as virtual text -- and nothing
  -- highlights virtual text, so the old side is parsed separately to get
  -- the colours back. Missing one costs colour on those lines and
  -- nothing else, which is why this is not a warning.
  local parsers = {}
  for _, lang in ipairs({ "lua", "python", "c" }) do
    if pcall(vim.treesitter.language.add, lang) then
      table.insert(parsers, lang)
    end
  end
  if #parsers > 0 then
    vim.health.ok(("removed lines keep their colours (tree-sitter: %s…)")
      :format(table.concat(parsers, ", ")))
  else
    vim.health.info("removed lines will be drawn in one flat colour", {
      "they are virtual text, which no highlighter touches, so uatis parses",
      "the old side itself with Neovim's tree-sitter -- and found no parsers",
      "the diff itself does not use these: difftastic brings its own",
    })
  end

  M.report(M.facts())
end

--- The repository half of the report: what a review opened here, now,
--- would compare against.
function M.report(f)
  vim.health.start("uatis: this repository")

  if not f.root then
    vim.health.info(f.dir .. " is not inside a git repository", {
      "nothing below applies until you are in one",
    })
    return
  end
  vim.health.ok("repository " .. f.root)
  vim.health.info("HEAD is " .. (f.head or "detached"))

  if f.chosen and f.source == "remembered" then
    vim.health.ok("base " .. f.chosen .. " (remembered from a previous session)")
  elseif f.chosen then
    vim.health.ok("base " .. f.chosen .. " (chosen this session)")
  elseif f.origin_head then
    vim.health.ok("base " .. f.origin_head .. " (from origin/HEAD)")
  elseif f.base then
    vim.health.ok("base " .. f.base .. " (from base.fallbacks)")
  else
    vim.health.warn("no base branch here", {
      "no origin/HEAD, and none of " .. table.concat(config.base.fallbacks, ", "),
      "set one with <leader>gB, or :Uatis <ref> for a single view",
    })
  end

  if f.base and not f.fork_point then
    vim.health.error(("no common ancestor between %s and HEAD"):format(f.base), {
      "nothing can be measured against it; choose another base",
    })
  elseif f.fork_point then
    local at_head = f.fork_point == f.head_sha
    local line = ("fork point %s"):format(f.fork_point:sub(1, 8))
    if at_head then
      vim.health.warn(line .. ", which is HEAD itself", {
        "everything committed is already on " .. tostring(f.base),
        "a review here shows unsaved and uncommitted work and nothing else",
      })
    else
      vim.health.ok(line)
    end
  end

  -- Reported, not judged: every one of these is overridden on the
  -- command line where it would matter. Shown because an empty list
  -- beside a buffer full of changes used to have exactly these causes,
  -- and a reader cannot check what they cannot see.
  local set = {}
  for key, value in pairs(f.diff_config) do
    table.insert(set, key .. " = " .. value)
  end
  table.sort(set)
  if #set > 0 then
    vim.health.info("git config that rewrites `git diff`: " .. table.concat(set, ", "), {
      "uatis overrides these per call (--no-ext-diff --no-color, explicit prefixes)",
      "so the file list is read from a plain unified diff whatever they say",
    })
  end
end

return M
