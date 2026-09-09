-- The only module that spawns `glab`. Everything else in the plugin
-- talks to GitLab through the functions here, so the day a flag is
-- spelled differently -- or the day this grows a `gh` twin for GitHub --
-- there is one file to change.
--
-- Every call is asynchronous and reports back on the main loop. A review
-- session is a sequence of round trips to a forge on the far side of a
-- network; none of them may hold the editor still.

local config = require("nemeton.config")
local log = require("nemeton.log")

local M = {}

-- The host and the token, resolved once.
--
-- Once, because either may be a function, and a function is where you
-- shell out to a password manager: `pass show gitlab/token` on every
-- keystroke-triggered API call would be a subprocess per comment. Reset
-- with `M.reset_credentials()` after changing the config -- or after
-- rotating a token in the middle of a session, which is the only time it
-- comes up.
local cached_env = nil

-- What the forge turned out to be, resolved once and kept beside the
-- credentials: its version, and whether it refuses the line numbers
-- inside a `line_range`. Both are set where a position is posted, far
-- below -- declared up here because `M.reset_credentials` forgets them
-- and comes first, and a local declared after it would leave that
-- function writing to two globals of the same name.
local forge_version = nil
local trims_ranges = false

-- A token typed into the prompt below. It lives here, in this variable,
-- for as long as the editor does: not written to `config`, not written
-- to a file, not passed to `glab auth login`. A token that a plugin
-- persists on your behalf is a token you will find in a backup.
local session_token = nil

-- Bumped whenever the token changes. A call that went out under an old
-- one and comes back unauthorized after somebody else has already
-- typed a new one should retry, not ask again: several calls go out at
-- once, they fail milliseconds apart rather than simultaneously, and
-- the second failure must not put a second prompt on the screen.
local generation = 0

-- root -> the project's full path, resolved once. GraphQL wants the
-- path spelled out; glab's `:fullpath` placeholder only fills in a REST
-- endpoint, so it is asked for and kept.
--
-- Declared up here with the other caches rather than beside the
-- function that fills it, because `reset_credentials` below clears it
-- and a `local` declared after its use is a different variable: a
-- global, silently, and the cache went on being read.
local project_paths = {}

-- root -> whose token this is, as GitLab's own `user` object, resolved
-- once. Which reaction on a note is yours is a question with no other
-- answer: the forge names the person who gave each one, and nothing
-- else in a review knows who you are. Kept beside the credentials, and
-- forgotten with them -- another token is another person.
local whoami = {}

-- The generation at which the prompt was last answered with nothing.
-- Several calls go out together and fail together; one refusal answers
-- for all of them, rather than one prompt per call in flight.
local declined = nil

--- Reads a config value that may be a string, a function, or nil.
local function value(v)
  if type(v) == "function" then
    local ok, out = pcall(v)
    if not ok then
      vim.notify(
        "nemeton: could not read a glab credential: " .. tostring(out),
        vim.log.levels.ERROR
      )
      return nil
    end
    v = out
  end
  if type(v) == "string" and v ~= "" then
    return v
  end
  return nil
end

--- The environment every glab call runs in, or nil when the config says
--- nothing and glab should decide for itself -- from the git remote, and
--- then from what `glab auth login` wrote.
---
--- Only the variables that were actually configured are set. Exporting
--- `GITLAB_HOST=""` is not the same as not exporting it: an empty
--- GITLAB_HOST makes glab refuse to match any remote.
local function env()
  if cached_env == nil then
    cached_env = {}
    local host = value(config.glab.host)
    if host then
      cached_env.GITLAB_HOST = host
    end
    -- The prompted token wins over the configured one: you are only
    -- ever asked because what was configured did not work.
    local token = session_token or value(config.glab.token)
    if token then
      cached_env.GITLAB_TOKEN = token
    end
  end
  return next(cached_env) and cached_env or nil
end

--- Forgets the resolved host and token, so the next call reads the
--- config again.
function M.reset_credentials()
  cached_env = nil
  -- Which project a directory belongs to is a question about the host
  -- as much as about the directory.
  project_paths = {}
  -- ...and so is who the token belongs to.
  whoami = {}
  -- ...and so is what the forge is and what its API will take: a
  -- different host is a different GitLab, of a different age.
  forge_version, trims_ranges = nil, false
end

--- What is configured, without the token itself -- for `:checkhealth`,
--- which should be able to say where the credentials came from without
--- printing a secret into a buffer the user is about to paste into an
--- issue.
function M.credentials()
  local e = env() or {}
  return {
    host = e.GITLAB_HOST,
    -- Whether a token is set here at all. `false` is not "unauthenticated":
    -- it means glab is using its own keyring, which is the normal case.
    token = e.GITLAB_TOKEN ~= nil,
    -- ...and if so, whether it was typed in this session or configured.
    source = session_token and "prompt" or (e.GITLAB_TOKEN and "config" or nil),
  }
end

--- Runs glab and hands (ok, stdout, stderr) back on the main loop.
---
--- `cwd` matters more than it looks: glab reads the project from the git
--- remote of the directory it runs in, and that is what makes the
--- `:fullpath` placeholder below resolve to the right project. Neovim's
--- own cwd wanders -- `:lcd`, file pickers, autocmds -- so the repo root
--- is passed explicitly rather than assumed.
local function spawn(args, opts, cb)
  opts = opts or {}
  local cmd = { config.glab.bin }
  vim.list_extend(cmd, args)
  local e = env()
  -- A call that spawns git of its own can ask for more than the token,
  -- and says so with an env of its own.
  if opts.env then
    e = vim.tbl_extend("force", e or {}, opts.env)
  end
  -- Logged before the call rather than after it, so a call that hangs is
  -- in the file too. `done` closes the entry with the exit code.
  local done = log.exec(cmd, { cwd = opts.cwd, env = e, stdin = opts.stdin })
  vim.system(cmd, {
    text = true,
    cwd = opts.cwd,
    stdin = opts.stdin,
    -- Merged into the inherited environment rather than replacing it:
    -- glab still needs PATH, HOME (its config), and whatever keyring
    -- socket the desktop session put there.
    env = e,
    timeout = config.glab.timeout * 1000,
  }, function(res)
    done(res.code, res.stderr)
    vim.schedule(function()
      cb(res.code == 0, res.stdout or "", res.stderr or "")
    end)
  end)
end

--- Whether a failure was glab saying "I do not know who you are".
---
--- Narrow on purpose. A 401 or a missing token is a credential problem
--- and asking for a better one is the fix; a 403 is *not* -- that is a
--- token that works and an account that may not touch this project, and
--- prompting there would teach the user to paste a token at a permission
--- error, which is exactly the reflex a plugin should not train.
local function is_auth_failure(text)
  if text == "" then
    return false
  end
  return text:match("401") ~= nil
    or text:match("[Uu]nauthorized") ~= nil
    or text:match("[Nn]o token") ~= nil
    or text:match("[Aa]uthentication required") ~= nil
end

--- What a failed call said, minus what it said on the way.
---
--- `glab` answers a failure with everything it saw: what git printed
--- while it worked, then what git printed when it stopped, then glab's
--- own conclusion under an ERROR banner, wrapped to the width of a
--- terminal nobody was looking at. Handed to a window whole, that is
--- nine lines with the two that matter in the middle of them.
---
--- What matters is: what git said went wrong, and what glab concluded
--- from it. What does not is the fetch it managed on the way, the
--- banner, the blank lines the banner is padded with, and -- when
--- there is anything above it to say why -- glab's own
--- "exit status 1", which says only that the command it ran came back
--- non-zero.
---
--- A checkout onto a dirty tree is the case this is written for. git
--- says "your local changes to the following files would be
--- overwritten by checkout", names them, and says to commit or stash
--- them; glab says "could not checkout branch: exit status 1". Only
--- one of those is worth reading, and it is not the one at the bottom.
---
--- Lines, not a line: an explanation that fits on one is rare, and the
--- windows this goes into fold what they are given.

-- Git talking about its progress rather than about the failure.
local NOISE = {
  "^From%s%S+$", -- the fetch it managed on the way
  "%->%s%S+$", -- " * [new branch]  fbranch  -> fbranch"
  "^remote:",
  "^Receiving objects",
  "^Resolving deltas",
  "^Counting objects",
  "^Compressing objects",
  "^Unpacking objects",
  "^Aborting$", -- git's full stop, after it has already said why
}

--- What GitLab put inside its refusal, as a sentence.
---
--- A 4xx from the API is a JSON body and glab prints it whole: what
--- reaches a notification is `{"message":{"position":["must be a valid
--- json schema"]}}`, braces, quotes and all. Every word a person needs
--- is in there and none of the punctuation is, and a reviewer told
--- that in the middle of writing a comment has been handed a wire
--- format to read.
---
--- Both shapes, because GitLab uses both: `message` a sentence, and
--- `message` an object of field -> what is wrong with it, which is
--- what a validation failure looks like. `error` is the other spelling
--- -- OAuth's, and what the token endpoints answer with.
---
--- Nil for anything this does not recognise, which is left exactly as
--- it arrived: a message this cannot read is still a message, and
--- swallowing it would be worse than printing braces.
local function unwrap(line)
  if not line:match("^[{%[]") then
    return nil
  end
  local ok, body = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  if not (ok and type(body) == "table") then
    return nil
  end

  --- One value, flattened: a string is itself, a list is its items, and
  --- an object is `field: what is wrong with it`.
  local function said(v, field)
    if type(v) == "string" or type(v) == "number" then
      return { field and (field .. ": " .. tostring(v)) or tostring(v) }
    end
    if type(v) ~= "table" then
      return {}
    end
    local out = {}
    if vim.islist(v) then
      for _, item in ipairs(v) do
        vim.list_extend(out, said(item, field))
      end
      return out
    end
    for key, item in pairs(v) do
      vim.list_extend(out, said(item, field and (field .. "." .. key) or key))
    end
    return out
  end

  local parts = said(body.message or body.error or body.error_description)
  if #parts == 0 then
    return nil
  end
  return table.concat(parts, "; ")
end

function M.reason(out)
  local lines = {}
  for line in tostring(out or ""):gmatch("[^\n]+") do
    -- Colours, and the padding glab draws its banner with: it writes
    -- for a terminal, and this is going into a buffer.
    line = vim.trim((line:gsub("\27%[[%d;]*m", "")))
    -- Usage is glab answering a question about how to call it, which
    -- is a question about this plugin rather than about your branch.
    -- Nothing after it is about the failure either.
    if line:match("^Usage:") then
      break
    end
    local noise = line == ""
    for _, pattern in ipairs(NOISE) do
      noise = noise or line:match(pattern) ~= nil
    end
    if not noise then
      table.insert(lines, unwrap(line) or line)
    end
  end

  -- Everything after the banner is one sentence glab wrapped; put it
  -- back together.
  local banner
  for i, line in ipairs(lines) do
    if line:match("^[x!]?%s*ERROR%s*$") then
      banner = i
    end
  end
  local said = lines
  if banner then
    local concluded = table.concat(vim.list_slice(lines, banner + 1), " ")
    said = vim.list_slice(lines, 1, banner - 1)
    -- ...and keep it, unless it is the wrapper that says a command
    -- failed to something that has already said why.
    if concluded ~= "" and not (concluded:match("exit status %d") and #said > 0) then
      table.insert(said, concluded)
    end
  end

  if #said == 0 then
    return "glab said nothing"
  end
  -- Enough for an explanation, not enough for a transcript.
  if #said > 6 then
    said = vim.list_slice(said, 1, 6)
    said[6] = said[6] .. " …"
  end
  local text = table.concat(said, "\n")
  if #text > 500 then
    text = text:sub(1, 500) .. "…"
  end
  return text
end

-- Everyone waiting on the one prompt. Several calls go out at once -- the
-- MR metadata and its discussions, say -- and if the token is bad they
-- all come back unauthorized within milliseconds of each other. One
-- prompt, and everybody retries when it is answered.
local waiting = nil

--- Asks for a token, and hands it to everyone who was waiting.
---
--- `inputsecret` rather than `vim.ui.input`: a token typed into the
--- command line is a token in `:history` and on the screen behind you.
--- The cost is that it is modal and cannot be routed through a fancy
--- input UI, which for a secret is the right trade.
--- The prompt itself, as one replaceable function: the suite has to be
--- able to answer it, and a headless Neovim cannot type.
function M.ask(prompt)
  local ok, entered = pcall(vim.fn.inputsecret, prompt)
  return ok and entered or nil
end

local function prompt_token(cb)
  if waiting then
    table.insert(waiting, cb)
    return
  end
  waiting = { cb }
  vim.schedule(function()
    local host = (env() or {}).GITLAB_HOST or "GitLab"
    local entered = M.ask(("nemeton: token for %s (not stored): "):format(host))
    -- The prompt leaves the cursor on the message line; without this the
    -- next notification lands on top of a half-drawn prompt.
    vim.cmd("redraw")
    local token = vim.trim(entered or "")
    if token ~= "" then
      session_token = token
      generation = generation + 1
      -- Force env() to rebuild with it.
      cached_env = nil
    else
      declined = generation
    end
    local queue = waiting
    waiting = nil
    for _, waiter in ipairs(queue) do
      waiter(token ~= "")
    end
  end)
end

--- Sets, or replaces, the session token by asking for it.
function M.set_token(cb)
  session_token = nil
  cached_env = nil
  prompt_token(function(got)
    if got then
      vim.notify("nemeton: token set for this session", vim.log.levels.INFO)
    end
    if cb then
      cb(got)
    end
  end)
end

--- Forgets it again, back to whatever the config and glab's own keyring
--- say.
function M.forget_token()
  session_token = nil
  generation = generation + 1
  cached_env = nil
end

--- Runs glab, and if glab says the credentials are no good, asks for a
--- token and runs it once more.
---
--- The retry is here, at the bottom, rather than in each of the dozen
--- callers: an expired token shows up as whichever request happened to
--- be in flight, and every one of them should recover the same way.
local function run(args, opts, cb)
  opts = opts or {}
  local sent_under = generation
  spawn(args, opts, function(ok, out, err)
    -- `no_prompt` is for the calls whose *own* failure mode looks like
    -- an authentication one. GitLab answers a second approval on the
    -- same merge request with a 401, and asking for a token there would
    -- teach the reflex of pasting a secret at a message that has
    -- nothing to do with the token.
    if
      ok
      or opts.retried
      or opts.no_prompt
      or not config.glab.prompt_for_token
      or not is_auth_failure(err .. out)
    then
      cb(ok, out, err)
      return
    end
    local retry = function()
      spawn(args, vim.tbl_extend("force", opts, { retried = true }), cb)
    end
    -- The token has changed since this call went out: somebody has
    -- already been asked and answered, and this one only needs to run
    -- again.
    if generation ~= sent_under then
      retry()
      return
    end
    -- ...and the other way: the prompt has already been put up for
    -- this batch and waved away.
    if declined == generation then
      cb(ok, out, err)
      return
    end
    prompt_token(function(got)
      if not got then
        cb(ok, out, err)
        return
      end
      retry()
    end)
  end)
end

M.run = run

--- The same, with the stdout decoded. cb(data|nil, err|nil).
---
--- `luanil` on both object and array is not a detail: GitLab returns
--- `null` for every field that does not apply -- `old_line` on a note
--- against an added line, `resolved_by` on an unresolved thread -- and
--- without it those arrive as `vim.NIL`, which is truthy. Every guard
--- downstream would have to know that.
local function json(args, opts, cb)
  run(args, opts, function(ok, out, err)
    if not ok then
      -- Reduced here rather than at each of the fifteen places that
      -- show one: an error goes into a notification or into a window,
      -- and neither is a terminal glab can draw a box in.
      cb(nil, M.reason(err ~= "" and err or out))
      return
    end
    if vim.trim(out) == "" then
      cb(nil, "glab returned nothing")
      return
    end
    local decoded_ok, decoded = pcall(vim.json.decode, out, {
      luanil = { object = true, array = true },
    })
    if not decoded_ok then
      cb(nil, "could not read glab's json: " .. tostring(decoded))
      return
    end
    cb(decoded, nil)
  end)
end

M.json = json

function M.available()
  return vim.fn.executable(config.glab.bin) == 1
end

--- A blocking call, for `:checkhealth` and nothing else -- health checks
--- are read top to bottom and are allowed to take a moment. It goes
--- through here rather than calling vim.system directly so that what
--- health reports is what the plugin actually does: same binary, same
--- host, same token.
function M.sync(args)
  local cmd = { config.glab.bin }
  vim.list_extend(cmd, args)
  local done = log.exec(cmd, { env = env() })
  local res = vim.system(cmd, { text = true, env = env() }):wait()
  done(res.code, res.stderr)
  return res
end

--- Merge requests on the project this repository points at, in `state`
--- -- "opened", "merged", "closed" or "all". Nil for the configured
--- one, which is what a queue opens on.
---
--- `--output json` is the API's own objects, so the fields here are the
--- fields the GitLab docs describe -- iid, source_branch, diff_refs and
--- the rest -- and not a shape glab invented for its table view.
---
--- `page` is 1 unless the window is asking for the next one: a queue of
--- what is merged is a history and the answer to "when did we stop
--- doing it that way" is usually older than thirty merge requests.
function M.mr_list(root, state, cb, page)
  local args = { "mr", "list", "--output", "json", "--per-page", tostring(config.list.per_page) }
  if page and page > 1 then
    vim.list_extend(args, { "--page", tostring(page) })
  end
  if config.list.order then
    vim.list_extend(args, { "--order", config.list.order })
  end
  -- `mr list` has no --state: the states are three separate flags, and
  -- "opened" is what you get by passing none of them.
  state = state or config.list.state
  if state == "merged" then
    table.insert(args, "--merged")
  elseif state == "closed" then
    table.insert(args, "--closed")
  elseif state == "all" then
    table.insert(args, "--all")
  end
  json(args, { cwd = root }, cb)
end

--- Everybody who can be mentioned on this project.
---
--- The members of the project and of the groups above it, which is
--- exactly who GitLab turns an `@` into a notification for. A page of a
--- hundred: a project with more members than that has a directory
--- rather than a team, and the ones you mention in a review are the
--- ones already on it.
function M.project_users(root, cb)
  json({ "api", "projects/:fullpath/users?per_page=100" }, { cwd = root }, cb)
end

--- The branches on the project, for the one a merge request goes to.
---
--- The forge's list rather than `git branch -r`: what a merge request
--- can be aimed at is what is on the forge, and a remote-tracking ref
--- here is a copy of that from whenever it was last fetched. The
--- `default` flag each one carries is the other half of the answer --
--- which of them a merge request goes to unless you say otherwise --
--- and it saves asking the project endpoint the same question.
---
--- One page of a hundred: past that a project has a branch list nobody
--- picks from, and the target of a merge request is one of the few at
--- the top of it.
function M.branches(root, cb)
  json({ "api", "projects/:fullpath/repository/branches?per_page=100" }, { cwd = root }, cb)
end

--- Every label the project has, for the ones a new merge request goes
--- out wearing.
---
--- The project's own, which is what GitLab will accept: a label typed
--- into `--label` that no project has is created by the create call
--- itself, silently, and a review queue full of one-off labels spelled
--- four ways is how that ends.
function M.labels(root, cb)
  json({ "api", "projects/:fullpath/labels?per_page=100" }, { cwd = root }, cb)
end

--- What CI last made of a branch.
---
--- For a merge request that does not exist yet, and so has no pipeline
--- of its own: the branch has run one already, against the same
--- commits, and "the build is red" is the answer that decides whether
--- this should go out at all. The newest, which is the one about the
--- commit you are looking at.
function M.branch_pipelines(root, ref, cb)
  json({
    "api",
    ("projects/:fullpath/pipelines?ref=%s&per_page=1"):format(vim.uri_encode(ref, "rfc2396")),
  }, { cwd = root }, cb)
end

--- Opens a merge request for the branch the repository is on.
---
--- `mr` is what the window collected: `title`, `body`, `target`,
--- `labels` and `draft`. Only the title is required -- everything else
--- left out is a question glab answers for itself, which for the target
--- branch is the project's default and for the rest is "none".
---
--- `glab mr create` rather than the API, which is the exception to what
--- every other call here does: the branch this should come from, the
--- branch it should go to, which remote either belongs to and whether
--- the source has been pushed at all are four things glab works out and
--- this plugin would have to ask for one call at a time. `--push` is
--- the fourth of them and `--yes` is what keeps the other three from
--- being asked at a prompt: every field it would otherwise ask about is
--- given, and a subprocess with no terminal is not a place to be asked
--- anything.
---
--- Answers with the new merge request's URL, which is what `mr create`
--- prints and the only thing it prints that is of any use.
function M.mr_create(root, mr, cb)
  local args = {
    "mr",
    "create",
    "--title",
    mr.title,
    "--description",
    mr.body or "",
    "--push",
    "--yes",
  }
  if mr.target and mr.target ~= "" then
    vim.list_extend(args, { "--target-branch", mr.target })
  end
  if mr.labels and #mr.labels > 0 then
    -- One flag, comma-separated: glab takes the flag repeated as well,
    -- and a single argument is one thing to read in the log.
    vim.list_extend(args, { "--label", table.concat(mr.labels, ",") })
  end
  if mr.draft then
    -- The flag rather than a `Draft:` in front of the title. The two
    -- make the same merge request -- GitLab reads the prefix off the
    -- title itself -- but only one of them leaves the title as the
    -- thing that was typed.
    table.insert(args, "--draft")
  end
  run(args, {
    cwd = root,
    -- This one spawns a git that talks to the remote, and a git that
    -- asks for a password at a terminal here is a git asking nobody:
    -- there is no terminal, and the call would sit there until the
    -- timeout ended it. Credential helpers still work; only the prompt
    -- that could not be answered is refused.
    env = { GIT_TERMINAL_PROMPT = "0" },
  }, function(ok, out, err)
    if not ok then
      cb(nil, M.reason(err ~= "" and err or out))
      return
    end
    cb((out .. "\n" .. err):match("https?://%S+/merge_requests/%d+") or vim.trim(out), nil)
  end)
end

--- One merge request, in full -- which is how the diff refs are got.
---
--- Through `api` rather than `mr view` because a comment's position has
--- to carry base_sha/start_sha/head_sha, and those three are the whole
--- reason for this call.
function M.mr_get(root, iid, cb)
  json({ "api", ("projects/:fullpath/merge_requests/%d"):format(iid) }, { cwd = root }, cb)
end

--- The commits a merge request carries -- its changelog.
---
--- Not `--paginate`: a hundred commits on one branch is already a
--- merge request nobody is going to review commit by commit, and a
--- picker that pauses to walk five pages to say so has answered the
--- wrong question.
function M.mr_commits(root, iid, cb)
  json(
    { "api", ("projects/:fullpath/merge_requests/%d/commits?per_page=100"):format(iid) },
    { cwd = root },
    cb
  )
end

--- Every discussion on the merge request, inline and overall.
---
--- Paginated because a long review is hundreds of notes and the default
--- page is twenty; a thread silently missing from the gutter is worse
--- than a slow fetch.
function M.discussions(root, iid, cb)
  json({
    "api",
    "--paginate",
    ("projects/:fullpath/merge_requests/%d/discussions?per_page=100"):format(iid),
  }, { cwd = root }, cb)
end

--- Who has approved the merge request, and how many more it needs.
---
--- Its own endpoint because approvals are their own resource: the
--- merge request payload says nothing about them on any GitLab
--- edition, and on the editions without approval rules this answers
--- with zero required and whoever has clicked the button.
function M.approvals(root, iid, cb)
  json(
    { "api", ("projects/:fullpath/merge_requests/%d/approvals"):format(iid) },
    { cwd = root },
    cb
  )
end

function M.project_path(root, cb)
  local known = project_paths[root]
  if known ~= nil then
    cb(known or nil)
    return
  end
  json({ "api", "projects/:fullpath" }, { cwd = root }, function(data, err)
    local path = type(data) == "table" and data.path_with_namespace or nil
    -- `false` rather than nil for "asked and got nowhere", so a forge
    -- that will not answer is not asked once per list.
    project_paths[root] = path or false
    cb(path, err)
  end)
end

--- Whose token this is, as GitLab's `user` object.
---
--- Asked once per repository and kept. The one thing it is for is
--- telling your own reaction on a note from somebody else's, which is
--- the difference between a key that adds one and a key that toggles
--- it -- and a call per keypress to answer a question whose answer
--- cannot change is a call too many.
function M.me(root, cb)
  local known = whoami[root]
  if known ~= nil then
    cb(known or nil)
    return
  end
  json({ "api", "user" }, { cwd = root }, function(data, err)
    -- `false` for "asked and got nowhere", so a forge that will not say
    -- is not asked again on the next keypress.
    whoami[root] = (type(data) == "table" and data.username) and data or false
    cb(whoami[root] or nil, err)
  end)
end

--- Every reaction on every note of a merge request, as
--- `{ [note_id] = { { name, user }, ... } }`.
---
--- The second GraphQL in this plugin, and for the same kind of reason
--- as the first. REST publishes reactions one note at a time --
--- `/notes/:id/award_emoji` -- so the REST answer to "what has been
--- reacted to in this review" is one request per comment, forty
--- subprocesses to draw a row of thumbs. GraphQL hands over the whole
--- of it beside the notes it belongs to, in one.
---
--- A hundred discussions and a hundred notes in each, which is the page
--- GraphQL gives without being asked and more than a merge request
--- anybody is reviewing in an editor has. Past that the reactions on
--- the tail of the thread are missing, which is a row of pictures
--- missing and not a comment missing.
---
--- Quietly: this is decoration. A forge too old for the field, a token
--- without `read_api`, an instance with GraphQL turned off -- none of
--- them is a reason to put an error on the screen after every refresh,
--- and none of them stops a single comment being read or written. The
--- callback gets an empty table and the review is drawn without them.
function M.reactions(root, iid, cb)
  M.project_path(root, function(path)
    if not path then
      cb({})
      return
    end
    local query = (
      '{ project(fullPath: "%s") { mergeRequest(iid: "%d") { discussions { nodes '
      .. "{ notes { nodes { id awardEmoji { nodes { name user { username } } } } } } } } } }"
    ):format(path, iid)
    json({ "api", "graphql", "--raw-field", "query=" .. query }, { cwd = root }, function(data)
      local nodes =
        vim.tbl_get(data or {}, "data", "project", "mergeRequest", "discussions", "nodes")
      if type(nodes) ~= "table" then
        cb({})
        return
      end
      local out = {}
      for _, discussion in ipairs(nodes) do
        for _, note in ipairs(vim.tbl_get(discussion, "notes", "nodes") or {}) do
          -- GraphQL names a note `gid://gitlab/DiscussionNote/1234`;
          -- everything else in this plugin knows it as 1234.
          local id = tonumber(tostring(note.id or ""):match("(%d+)$"))
          local given = vim.tbl_get(note, "awardEmoji", "nodes") or {}
          if id and #given > 0 then
            local list = {}
            for _, award in ipairs(given) do
              table.insert(list, {
                name = award.name,
                user = vim.tbl_get(award, "user", "username"),
              })
            end
            out[id] = list
          end
        end
      end
      cb(out)
    end)
  end)
end

--- Reacts to a note, and takes it back.
---
--- Two calls because GitLab has two: the name goes in as a query
--- parameter on the way in, and what comes back out is named by the id
--- of the reaction rather than by the emoji -- so taking one back means
--- reading that note's reactions first, which `M.reactions` above does
--- for the whole review but without the ids REST needs.
function M.award(root, iid, note_id, name, cb)
  json({
    "api",
    "--method",
    "POST",
    ("projects/:fullpath/merge_requests/%d/notes/%s/award_emoji?name=%s"):format(
      iid,
      note_id,
      vim.uri_encode(name)
    ),
  }, { cwd = root }, cb)
end

--- The reactions on one note, as REST tells them -- with the ids that
--- `M.unaward` needs and `M.reactions` does not have.
function M.note_awards(root, iid, note_id, cb)
  json(
    { "api", ("projects/:fullpath/merge_requests/%d/notes/%s/award_emoji"):format(iid, note_id) },
    { cwd = root },
    cb
  )
end

function M.unaward(root, iid, note_id, award_id, cb)
  run({
    "api",
    "--method",
    "DELETE",
    ("projects/:fullpath/merge_requests/%d/notes/%s/award_emoji/%s"):format(iid, note_id, award_id),
  }, { cwd = root }, function(ok, out, err)
    cb(ok, vim.trim(err ~= "" and err or out))
  end)
end

--- How many lines each of `iids` adds and removes, in one call.
---
--- GraphQL, and the only GraphQL in this plugin, for a reason worth the
--- exception: REST publishes no line totals anywhere, so the REST
--- answer to this question is to fetch every merge request's entire
--- diff -- thirty diffs to put a number on thirty rows. `diffStatsSummary`
--- is the number itself, for the whole list, in one request.
function M.diff_summaries(root, iids, cb)
  if #iids == 0 then
    cb({})
    return
  end
  M.project_path(root, function(path)
    if not path then
      cb(nil, "could not read the project's path")
      return
    end
    local quoted = {}
    for _, iid in ipairs(iids) do
      table.insert(quoted, ('"%d"'):format(iid))
    end
    local query = (
      '{ project(fullPath: "%s") { mergeRequests(iids: [%s]) '
      .. "{ nodes { iid diffStatsSummary { additions deletions fileCount } } } } }"
    ):format(path, table.concat(quoted, ", "))
    -- `--raw-field`, not `--field`: the query starts with a brace, and
    -- --field parses anything starting with one as JSON.
    json({ "api", "graphql", "--raw-field", "query=" .. query }, { cwd = root }, function(data, err)
      if not data then
        cb(nil, err)
        return
      end
      local nodes = vim.tbl_get(data, "data", "project", "mergeRequests", "nodes")
      if type(nodes) ~= "table" then
        cb(nil, "the forge answered without any merge requests in it")
        return
      end
      local out = {}
      for _, node in ipairs(nodes) do
        local summary = node.diffStatsSummary
        if summary then
          out[tonumber(node.iid)] = {
            added = summary.additions or 0,
            removed = summary.deletions or 0,
            files = summary.fileCount or 0,
          }
        end
      end
      cb(out)
    end)
  end)
end

--- The pipelines a merge request has run, newest first.
---
--- One call per merge request, which is what it costs: the list
--- endpoint sends no pipeline with its rows on any GitLab this has been
--- pointed at, and the alternative -- one page of the project's
--- pipelines, matched back to branches -- is one call that is wrong
--- about forks and about anything older than the page.
function M.mr_pipelines(root, iid, cb)
  json(
    { "api", ("projects/:fullpath/merge_requests/%d/pipelines?per_page=1"):format(iid) },
    { cwd = root },
    cb
  )
end

--- Every job of a pipeline, in the order GitLab returns them -- which
--- is the order they were created, and so the order of the stages.
function M.pipeline_jobs(root, pipeline_id, cb)
  json(
    { "api", ("projects/:fullpath/pipelines/%s/jobs?per_page=100"):format(pipeline_id) },
    { cwd = root },
    cb
  )
end

--- What one job printed while it ran.
---
--- Not `json`: `/trace` answers with the log itself, as text, and the
--- decoder would refuse the first line of it. So this is the one call
--- here whose body is handed back as it arrived -- ANSI escapes,
--- section markers and all. `jobs.log_lines` is what makes it readable.
---
--- Whole rather than paginated, because a trace is not a list: GitLab
--- sends the last of a running job's output and all of a finished one's,
--- and there is no page after it.
function M.job_trace(root, job_id, cb)
  run(
    { "api", ("projects/:fullpath/jobs/%s/trace"):format(job_id) },
    { cwd = root },
    function(ok, out, err)
      if not ok then
        cb(nil, M.reason(err ~= "" and err or out))
        return
      end
      cb(out or "", nil)
    end
  )
end

--- The files a merge request touches, with their diffs.
---
--- Only ever asked for to count lines: GitLab sends no add/remove
--- totals anywhere in the merge request payload, and the diff is the
--- only place the numbers exist. Not paginated -- this is one call for
--- one merge request, made once when it opens.
function M.mr_changes(root, iid, cb)
  json({ "api", ("projects/:fullpath/merge_requests/%d/changes"):format(iid) }, { cwd = root }, cb)
end

--- Checks the merge request's source branch out locally.
---
--- glab does the work: it knows whether the branch is from a fork, and
--- fetches the right ref either way. Failure here is usually a dirty
--- working tree, so the stderr is worth showing verbatim.
function M.checkout(root, iid, cb)
  run({ "mr", "checkout", tostring(iid) }, { cwd = root }, function(ok, out, err)
    cb(ok, M.reason(err ~= "" and err or out))
  end)
end

--- POSTs a JSON body, given as a Lua table, to an API path.
---
--- Through `--input -` rather than a fistful of `--field` flags: a
--- comment's position is a nested object, and flattening it into
--- `position[new_line]=12` pairs is a second encoding to get wrong for
--- no gain when glab will take the body whole on stdin.
---
--- The Content-Type has to be said out loud. glab sets one when it
--- builds the body itself out of `--field`, and sets none when the body
--- arrives on stdin -- so the request goes out with an empty
--- content-type and GitLab answers `415 The provided content-type '' is
--- not supported.` rather than anything that names the real problem.
local function send(method, root, path, body, cb, opts)
  local args = { "api", "--method", method }
  local run_opts = vim.tbl_extend("force", { cwd = root }, opts or {})
  if body then
    vim.list_extend(args, { "--header", "Content-Type: application/json", "--input", "-" })
    run_opts.stdin = vim.json.encode(body)
  end
  table.insert(args, path)
  json(args, run_opts, cb)
end

local function post(root, path, body, cb, opts)
  send("POST", root, path, body, cb, opts)
end

-- The first GitLab whose API takes the line numbers inside a
-- `line_range`.
--
-- Up to 18.5 it declares the `old_line` and `new_line` of a range as
-- strings, coerces the integers a client sends into them, and then
-- validates the position it built against its own schema, which says
-- those two are integers. So every multi-line comment is refused, with
-- `position: ["must be a valid json schema"]` and nothing about which
-- field. 18.6 declares them integers and takes them.
local RANGE_NUMBERS = { 18, 6 }

-- `forge_version` is what it said it is, `{major, minor}` or false for
-- one that would not say; `trims_ranges` is whether it has turned out
-- to refuse the numbers anyway, which is what is believed over the
-- version -- a self-managed instance can be a patched one, and the
-- string it reports says nothing about what its administrator
-- backported. Both are declared at the top of the file, with the
-- credentials they are reset alongside.

--- `position` with the line numbers taken out of the two ends of its
--- `line_range`, or nil where there is no range to trim or nothing left
--- to name the lines with.
---
--- The workaround for a bug in GitLab's own API. It declares the
--- `old_line` and `new_line` of a `line_range` as strings, coerces the
--- integers a client sends into them, and then validates the position
--- it built against a schema that says those two are integers -- so
--- every multi-line comment is refused, with `position: ["must be a
--- valid json schema"]` and nothing about which field. Fixed upstream
--- after 18.4; every release before that has it.
---
--- Left out, the same comment is accepted: the `line_code` on each end
--- names the line, and it is the anchor. What is lost is the "lines 19
--- to 21" label on the page, which GitLab reads out of the two numbers
--- and does not derive from the codes -- so this is the second thing
--- tried and never the first.
local function trimmed(position)
  local range = type(position) == "table" and position.line_range
  if type(range) ~= "table" then
    return nil
  end
  local out = vim.deepcopy(position)
  for _, at in ipairs({ "start", "end" }) do
    local side = out.line_range[at]
    if type(side) ~= "table" or not side.line_code then
      -- A range end with no line code names no line once its numbers
      -- are gone, and a comment anchored to nothing is worse than one
      -- the forge refused.
      return nil
    end
    side.old_line, side.new_line = nil, nil
  end
  return out
end

--- Whether a failure was the forge refusing a position it built itself.
--- The message names the field and nothing else in GitLab says it.
local function is_schema_failure(text)
  return text ~= nil and text:match("must be a valid json schema") ~= nil
end

--- What the forge says it is, as `{major, minor}` -- or false, for one
--- that would not say.
---
--- Asked once and kept, like the host and the token: it is a fact about
--- the instance rather than about the call, and every comment written
--- after the first would otherwise ask again. Asked at all only where
--- the answer changes what is sent, so a session that writes no
--- multi-line comment never makes the call.
local function version(root, cb)
  if forge_version ~= nil then
    cb(forge_version)
    return
  end
  json({ "api", "version" }, { cwd = root }, function(data)
    local said = type(data) == "table" and data.version or nil
    local major, minor = tostring(said or ""):match("^(%d+)%.(%d+)")
    -- False and not nil for a forge that would not answer: nil is "not
    -- asked yet", and asking again on every comment is a round trip for
    -- a question already answered with a shrug.
    forge_version = major and { tonumber(major), tonumber(minor) } or false
    cb(forge_version)
  end)
end

--- Whether `v` is older than `want`, and false for a version nobody
--- could read -- an unknown forge is treated as a current one, because
--- the payload that is right everywhere else is the one to try.
local function older(v, want)
  if type(v) ~= "table" then
    return false
  end
  return v[1] < want[1] or (v[1] == want[1] and v[2] < want[2])
end

--- POSTs (or PUTs) a note carrying a `position`.
---
--- Two ways of not being refused by a GitLab older than 18.6, and they
--- are not the same thing. The version is asked first, so an instance
--- known to be too old is never sent a payload it is known to refuse --
--- which is also what lets `:checkhealth` say so in advance. The retry
--- is for the rest: a forge that would not say what it is, and one that
--- says 18.6 and refuses anyway, which a patched self-managed instance
--- can.
---
--- The retry is safe. What failed was a validation, so there is no
--- half-written comment on the other side for a second attempt to
--- duplicate.
local function with_position(method, root, path, body, cb)
  version(root, function(v)
    if trims_ranges or older(v, RANGE_NUMBERS) then
      body.position = trimmed(body.position) or body.position
    end
    send(method, root, path, body, function(data, err)
      if data or not is_schema_failure(err) then
        cb(data, err)
        return
      end
      local without = trimmed(body.position)
      if not without then
        cb(data, err)
        return
      end
      log.note("position refused: sending it again without the line numbers in its range")
      trims_ranges = true
      body.position = without
      send(method, root, path, body, cb)
    end)
  end)
end

--- A new thread anchored to a line of a file in the diff.
---
--- `position` is GitLab's, verbatim: the three shas that identify the
--- diff, the path on each side, and a line on one side. See
--- `nemeton.position`, which is where one gets built out of a buffer and
--- a cursor.
function M.create_discussion(root, iid, body, position, cb)
  with_position(
    "POST",
    root,
    ("projects/:fullpath/merge_requests/%d/discussions"):format(iid),
    { body = body, position = position },
    cb
  )
end

--- A note added to an existing thread. The position is the thread's
--- already, so a reply carries nothing but its text.
function M.reply(root, iid, discussion_id, body, cb)
  post(
    root,
    ("projects/:fullpath/merge_requests/%d/discussions/%s/notes"):format(iid, discussion_id),
    { body = body },
    cb
  )
end

--- An overall comment -- one with no position, which is what the MR page
--- shows at the bottom rather than against a line.
function M.create_note(root, iid, body, cb)
  post(root, ("projects/:fullpath/merge_requests/%d/notes"):format(iid), { body = body }, cb)
end

--- Rewrites a note that is already posted.
---
--- The plain notes endpoint rather than the discussion one: a note in a
--- thread is a note on the merge request, and this way a line comment
--- and an overall comment are edited by the same call. GitLab refuses a
--- note that is not yours with a 403, which is passed through -- there
--- is no way to ask it beforehand whether you may.
function M.update_note(root, iid, note_id, body, cb)
  send(
    "PUT",
    root,
    ("projects/:fullpath/merge_requests/%d/notes/%s"):format(iid, note_id),
    { body = body },
    cb
  )
end

--- The comments you have written and not sent.
---
--- Only ever your own: GitLab shows a draft note to nobody but its
--- author, which is what makes the whole feature safe to use in the
--- middle of a review.
function M.draft_notes(root, iid, cb)
  json({
    "api",
    "--paginate",
    ("projects/:fullpath/merge_requests/%d/draft_notes?per_page=100"):format(iid),
  }, { cwd = root }, cb)
end

--- Writes one: against a line, against a thread already there, or
--- against the merge request as a whole.
function M.create_draft(root, iid, body, position, discussion_id, cb)
  with_position(
    "POST",
    root,
    ("projects/:fullpath/merge_requests/%d/draft_notes"):format(iid),
    { note = body, position = position, in_reply_to_discussion_id = discussion_id },
    cb
  )
end

--- Rewrites one that has not been sent.
---
--- The position goes back with the text. GitLab writes the update's
--- position over the one the draft has, and an absent one is a null: a
--- body-only PUT leaves the comment anchored to nothing, which is a
--- comment on the merge request as a whole. An unsent reply has no
--- position to send -- it hangs off the discussion it answers.
function M.update_draft(root, iid, draft_id, body, position, cb)
  with_position(
    "PUT",
    root,
    ("projects/:fullpath/merge_requests/%d/draft_notes/%s"):format(iid, draft_id),
    { note = body, position = position },
    cb
  )
end

--- Throws one away.
function M.delete_draft(root, iid, draft_id, cb)
  run({
    "api",
    "--method",
    "DELETE",
    ("projects/:fullpath/merge_requests/%d/draft_notes/%s"):format(iid, draft_id),
  }, { cwd = root }, function(ok, out, err)
    cb(ok, vim.trim(err ~= "" and err or out))
  end)
end

--- Sends all of them at once -- which is what submitting a review is.
---
--- Answers 204 and an empty body, like a delete, so it goes through
--- `run` rather than through the JSON helper.
function M.publish_drafts(root, iid, cb)
  run({
    "api",
    "--method",
    "POST",
    ("projects/:fullpath/merge_requests/%d/draft_notes/bulk_publish"):format(iid),
  }, { cwd = root }, function(ok, out, err)
    cb(ok, vim.trim(err ~= "" and err or out))
  end)
end

--- Deletes a note.
---
--- Through `run` rather than the JSON helper: GitLab answers a delete
--- with 204 and an empty body, and "glab returned nothing" is this
--- plugin's phrase for a call that failed.
function M.delete_note(root, iid, note_id, cb)
  run({
    "api",
    "--method",
    "DELETE",
    ("projects/:fullpath/merge_requests/%d/notes/%s"):format(iid, note_id),
  }, { cwd = root }, function(ok, out, err)
    cb(ok, vim.trim(err ~= "" and err or out))
  end)
end

--- Approves the merge request, or takes an approval back.
---
--- No body: both are bare POSTs, and GitLab answers with the approvals
--- payload, which is the same shape `M.approvals` returns and is used
--- to redraw without a second call.
---
--- `no_prompt`, because approving one you have already approved comes
--- back as a 401 -- which is what this plugin otherwise reads as an
--- expired token.
function M.approve(root, iid, approved, cb)
  post(
    root,
    ("projects/:fullpath/merge_requests/%d/%s"):format(iid, approved and "approve" or "unapprove"),
    nil,
    cb,
    { no_prompt = true }
  )
end

--- Marks a thread resolved, or puts it back.
function M.resolve(root, iid, discussion_id, resolved, cb)
  json({
    "api",
    "--method",
    "PUT",
    "--field",
    "resolved=" .. tostring(resolved),
    ("projects/:fullpath/merge_requests/%d/discussions/%s"):format(iid, discussion_id),
  }, { cwd = root }, cb)
end

return M
