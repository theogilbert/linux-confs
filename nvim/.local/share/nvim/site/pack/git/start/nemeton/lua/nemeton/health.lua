-- `:checkhealth nemeton`
--
-- Four things decide whether this plugin can do its job and all four are
-- outside it: the Neovim version, git, glab, and a token glab can use.
-- Each failure loses something different, so each says what.

local config = require("nemeton.config")
local glab = require("nemeton.glab")
local log = require("nemeton.log")

local M = {}

local FLOOR = { 0, 10, 0 }

-- The oldest GitLab that can do everything here.
--
-- Set by the draft notes: writing a review and sending it in one go is
-- `POST .../draft_notes/bulk_publish`, which is 15.10. Everything else
-- -- discussions, positions, approvals, pipelines, the notes API -- has
-- been there for years, so an older GitLab loses the unsent comments
-- and keeps the rest.
local NEEDS = { 15, 10 }

--- What the forge itself can do, asked of the forge rather than assumed.
---
--- Two calls, and blocking ones: a health check is read top to bottom
--- and is allowed to take a moment.
local function forge()
  local version = glab.sync({ "api", "version" })
  local reported = (version.stdout or ""):match('"version"%s*:%s*"([^"]+)"')
  if not reported then
    vim.health.warn("could not read the GitLab version", {
      "`glab api version` said: "
        .. vim.trim((version.stderr or version.stdout or ""):match("^[^\n]*") or "nothing"),
    })
  else
    local major, minor = reported:match("^(%d+)%.(%d+)")
    major, minor = tonumber(major) or 0, tonumber(minor) or 0
    local enough = major > NEEDS[1] or (major == NEEDS[1] and minor >= NEEDS[2])
    local said = ("GitLab %s%s"):format(
      reported,
      reported:match("ee") and " (Enterprise Edition)" or ""
    )
    if enough then
      vim.health.ok(said)
    else
      vim.health.warn(said .. " is older than " .. table.concat(NEEDS, "."), {
        "comments, suggestions, approvals and pipelines all work",
        "keeping a comment unsent needs the draft notes API (GitLab 15.10)",
        "`<C-p>` in the composer posts one on the spot, which works anywhere",
      })
    end
  end

  -- The one GraphQL query in the plugin, which is also the only thing
  -- that can be missing on a working instance: an administrator can
  -- turn the GraphQL API off, and some proxies do it for them.
  local graph = glab.sync({ "api", "graphql", "--raw-field", "query={ currentUser { username } }" })
  -- `username`, not `currentUser`: an unauthenticated GraphQL request
  -- answers with the field present and null, which is the API working
  -- and the credentials not.
  if graph.code == 0 and (graph.stdout or ""):match('"username"') then
    vim.health.ok("GraphQL answers (the list's +N −N column)")
  else
    vim.health.warn("GraphQL did not answer", {
      "everything works except how much each merge request changes,",
      "which is one GraphQL call for the whole list -- REST publishes",
      "no line totals, and counting them there is one full diff per row",
      "`list.stats = false` stops asking",
    })
  end
end

function M.check()
  vim.health.start("nemeton")

  local v = vim.version()
  if vim.version.ge({ v.major, v.minor, v.patch }, FLOOR) then
    vim.health.ok(("Neovim %d.%d.%d"):format(v.major, v.minor, v.patch))
  else
    vim.health.error(
      ("Neovim %d.%d.%d is too old"):format(v.major, v.minor, v.patch),
      { ("nemeton needs %d.%d or newer"):format(FLOOR[1], FLOOR[2]) }
    )
  end

  if vim.fn.executable("git") == 1 then
    vim.health.ok("git")
  else
    vim.health.error("git is not on your PATH", { "nothing works without it" })
  end

  local bin = config.glab.bin
  if vim.fn.executable(bin) ~= 1 then
    vim.health.error(("%s is not on your PATH"):format(bin), {
      "every call to GitLab goes through it",
      "https://gitlab.com/gitlab-org/cli",
    })
    return
  end

  local version = glab.sync({ "--version" })
  vim.health.ok(vim.trim((version.stdout or ""):match("^[^\n]*") or bin))

  -- Where the host and the token come from. Worth saying out loud: the
  -- commonest configuration failure is not a wrong value, it is a value
  -- set in a place you have forgotten about while you edit another.
  local creds = glab.credentials()
  if creds.host then
    vim.health.ok(("host: %s (config.glab.host)"):format(creds.host))
  elseif vim.env.GITLAB_HOST then
    vim.health.info(("host: %s (GITLAB_HOST in the environment)"):format(vim.env.GITLAB_HOST))
  else
    vim.health.ok("host: from the git remote, or from `glab auth login`")
  end
  if creds.source == "prompt" then
    vim.health.ok("token: typed in this session (`:Nemeton token` to replace it)")
  elseif creds.token then
    vim.health.ok("token: config.glab.token")
  elseif vim.env.GITLAB_TOKEN then
    vim.health.info("token: GITLAB_TOKEN in the environment")
  else
    vim.health.ok("token: glab's own (keyring or config file)")
  end

  -- `auth status` exits non-zero when the token is missing or rejected,
  -- and its stderr already says which. Reviewing is entirely an
  -- authenticated activity -- even reading discussions on a public
  -- project is -- so this is an error, not a warning.
  local auth = glab.sync({ "auth", "status" })
  if auth.code == 0 then
    vim.health.ok("glab is authenticated")
  else
    -- The output is a status report per host, so the useful line is the
    -- one that failed rather than the first one printed.
    local why
    for _, line in ipairs(vim.split((auth.stderr or "") .. (auth.stdout or ""), "\n")) do
      if line:match("401") or line:match("[Nn]o token") then
        why = vim.trim(line)
        break
      end
    end
    vim.health.error("glab is not authenticated", {
      "`:Nemeton token` types one in for this editor session",
      "`glab auth login` stores one, or set config.glab.token",
      why or "glab auth status exited non-zero",
    })
  end

  forge()

  -- Where to look after the fact. Named here because the point of a log
  -- nobody can find is hard to state.
  if not config.log.enabled then
    vim.health.info("log: off (config.log.enabled)")
  else
    local path = log.path()
    if path then
      vim.health.ok("log: " .. path)
    else
      vim.health.warn("log: nowhere to write one (no HOME, no XDG_STATE_HOME)")
    end
  end
end

return M
