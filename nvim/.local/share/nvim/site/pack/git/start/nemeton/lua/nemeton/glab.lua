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
      table.insert(lines, line)
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
function M.mr_list(root, state, cb)
  local args = { "mr", "list", "--output", "json", "--per-page", tostring(config.list.per_page) }
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

--- A new thread anchored to a line of a file in the diff.
---
--- `position` is GitLab's, verbatim: the three shas that identify the
--- diff, the path on each side, and a line on one side. See
--- `nemeton.position`, which is where one gets built out of a buffer and
--- a cursor.
function M.create_discussion(root, iid, body, position, cb)
  post(
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
  post(
    root,
    ("projects/:fullpath/merge_requests/%d/draft_notes"):format(iid),
    { note = body, position = position, in_reply_to_discussion_id = discussion_id },
    cb
  )
end

--- Rewrites one that has not been sent.
function M.update_draft(root, iid, draft_id, body, cb)
  send(
    "PUT",
    root,
    ("projects/:fullpath/merge_requests/%d/draft_notes/%s"):format(iid, draft_id),
    { note = body },
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
