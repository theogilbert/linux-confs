-- What a merge request says about itself: the commits it carries, and
-- the description somebody wrote for it.
--
-- Both are read *before* the diff is -- "what is in this", "what is it
-- for" -- and neither is a question a row in a list can answer. One
-- module because they are the same shape: one fetch per merge request,
-- cached for as long as it is being looked at, rendered into lines that
-- somebody else puts in a window.

local config = require("nemeton.config")
local glab = require("nemeton.glab")
local threads = require("nemeton.threads")

local M = {}

-- iid -> { commits = { line, ... }, description = { line, ... } }
local cache = {}

--- Drops everything fetched so far.
---
--- Called when the list is refreshed: `r` there means "the queue has
--- moved on", and a changelog from before the last push is exactly what
--- must not still be on the screen afterwards.
function M.forget()
  cache = {}
end

--- "3d" / "4h" / "12m" -- how long ago an ISO timestamp was.
---
--- Here rather than in the list because both windows are read the same
--- way: a queue is scanned for what is stale, and a changelog for what
--- landed since you last looked.
function M.ago(iso)
  if type(iso) ~= "string" then
    return ""
  end
  local y, mo, d, h, mi = iso:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+)")
  if not y then
    return ""
  end
  local t = os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
    sec = 0,
  })
  -- os.time read the timestamp as local; GitLab wrote it as UTC.
  local secs = os.difftime(os.time(os.date("!*t")), t)
  if secs < 3600 then
    return ("%dm"):format(math.max(secs, 0) / 60)
  elseif secs < 86400 then
    return ("%dh"):format(secs / 3600)
  end
  return ("%dd"):format(secs / 86400)
end

-- GitLab's pipeline statuses, as the state this plugin draws them as
-- (`config.ci`), the word GitLab's own UI uses, and a colour. "success"
-- is the API's word and "passed" is the one on the page; the page is
-- what the reviewer has read a thousand times.
local PIPELINE = {
  success = { "passed", "passed", "NemetonOk" },
  failed = { "failed", "failed", "NemetonBad" },
  running = { "running", "running", "NemetonBusy" },
  pending = { "waiting", "pending", "NemetonBusy" },
  created = { "waiting", "created", "NemetonBusy" },
  waiting_for_resource = { "waiting", "waiting", "NemetonBusy" },
  preparing = { "waiting", "preparing", "NemetonBusy" },
  manual = { "manual", "manual", "NemetonBusy" },
  scheduled = { "manual", "scheduled", "NemetonBusy" },
  canceled = { "canceled", "canceled", "NemetonMeta" },
  skipped = { "skipped", "skipped", "NemetonMeta" },
}

--- One CI status -- a pipeline's or a job's, which are the same
--- vocabulary -- as a glyph, a word and a colour.
function M.status(status)
  if type(status) ~= "string" then
    return nil
  end
  local known = PIPELINE[status] or { "unknown", status, "NemetonMeta" }
  return { glyph = config.ci[known[1]] or config.ci.unknown, word = known[2], hl = known[3] }
end

--- What CI says about a merge request, or nil when the payload carried
--- no pipeline at all.
---
--- `head_pipeline` is the one the single-merge-request endpoint sends
--- and `pipeline` the older field some list endpoints still send; a
--- merge request with neither has never been built, which is not the
--- same fact as a pipeline that has not finished, and is why this
--- returns nil rather than "pending".
function M.ci(mr)
  local p = mr.head_pipeline or mr.pipeline
  local status = type(p) == "table" and p.status or nil
  if not status then
    return nil
  end
  local out = M.status(status)
  out.url = p.web_url
  out.id = p.id
  return out
end

--- Who has approved a merge request, from the approvals endpoint's
--- payload, or nil when it was never fetched.
---
--- The names, not just the count: "1 of 2" is a progress bar, and what
--- a reviewer coming back to a merge request actually wants to know is
--- whether the one person whose opinion decides it has been in yet.
function M.approval(a)
  if type(a) ~= "table" then
    return nil
  end
  local names = {}
  for _, entry in ipairs(a.approved_by or {}) do
    local user = entry.user or entry
    table.insert(names, user.username or user.name or "?")
  end
  local required = tonumber(a.approvals_required) or 0
  local enough = required > 0 and (tonumber(a.approvals_left) or 0) == 0
    or (required == 0 and #names > 0)
  -- The same tick CI passing is drawn with: "it is through" is one
  -- fact in this window, whoever is saying it.
  local glyph = enough and config.ci.passed or config.ci.waiting
  -- The verdict on its own, apart from the names it was reached by: the
  -- two are read as separate facts -- is it through, and who has been
  -- in -- and the window that draws them draws them in two colours.
  local count
  if required > 0 then
    count = ("%s %d of %d"):format(glyph, #names, required)
  elseif #names > 0 then
    count = glyph .. " approved"
  else
    count = glyph .. " nobody has approved it"
  end
  local text = count
  if #names > 0 then
    text = ("%s · %s"):format(count, table.concat(names, ", "))
  elseif required > 0 then
    text = count .. " · nobody yet"
  end
  return {
    text = text,
    count = count,
    -- The verdict as one character, for the row of a list, where the
    -- names do not fit and the count barely does.
    glyph = glyph,
    names = names,
    required = required,
    enough = enough,
    -- Whether *you* have approved it, which decides what the approve
    -- key does next. Newer GitLab sends it; older does not, and the
    -- caller falls back to looking for itself in `names`.
    mine = a.user_has_approved,
    -- Not yet approved is a state something is waiting on, which is
    -- what the busy colour means everywhere else here -- and dim, which
    -- is what it was, is the colour of a fact nobody is waiting on.
    hl = enough and "NemetonOk" or "NemetonBusy",
  }
end

--- How big the change is: files touched, lines added, lines removed.
---
--- Counted out of the diffs because GitLab publishes no totals. Its own
--- merge request payload carries `changes_count`, which is a count of
--- files and a string, and nothing at all about lines.
---
--- The `+++`/`---` file headers are two of the characters being counted
--- and are the first thing to get this wrong; a diff of a file whose
--- only change is its mode has neither, and contributes nothing, which
--- is right.
function M.diff_stats(changes)
  local list = changes and changes.changes or changes
  if type(list) ~= "table" then
    return nil
  end
  local stats = { files = 0, added = 0, removed = 0 }
  for _, change in ipairs(list) do
    stats.files = stats.files + 1
    for line in tostring(change.diff or ""):gmatch("[^\n]+") do
      if line:sub(1, 3) == "+++" or line:sub(1, 3) == "---" then -- luacheck: ignore
        -- a file header, not a line of the file
      elseif line:sub(1, 1) == "+" then
        stats.added = stats.added + 1
      elseif line:sub(1, 1) == "-" then
        stats.removed = stats.removed + 1
      end
    end
  end
  return stats
end

--- "+120 −34 in 7 files", or nil when nothing has counted them yet.
function M.stats_text(stats)
  if type(stats) ~= "table" or not stats.files then
    return nil
  end
  return ("+%d −%d in %d file%s"):format(
    stats.added or 0,
    stats.removed or 0,
    stats.files,
    stats.files == 1 and "" or "s"
  )
end

--- The commits, newest first, as GitLab hands them over.
---
--- Only the subject line of each: a commit message's body is written
--- for whoever runs `git log`, and a reviewer deciding whether to open
--- a merge request wants the shape of the branch, not its prose.
function M.commit_chunks(commits)
  if not commits or #commits == 0 then
    return { { { "(no commits)", "NemetonMeta" } } }
  end
  local out = {
    { { ("%d commit%s"):format(#commits, #commits == 1 and "" or "s"), "NemetonMeta" } },
    {},
  }
  for _, c in ipairs(commits) do
    local title = vim.split(c.title or c.message or "", "\n", { plain = true })[1]:sub(1, 58)
    local author = (c.author_name or "?"):sub(1, 14)
    table.insert(out, {
      { ("%-8s  "):format((c.short_id or c.id or ""):sub(1, 8)), "NemetonMeta" },
      { title, "NemetonThread" },
      { (" "):rep(math.max(60 - vim.fn.strdisplaywidth(title), 2)) },
      { author, "NemetonAuthor" },
      { (" "):rep(math.max(15 - vim.fn.strdisplaywidth(author), 1)) },
      { M.ago(c.created_at or c.authored_date), "NemetonMeta" },
    })
  end
  return out
end

--- The author, whoever is asking.
---
--- GitLab sends a user object; `session.current` keeps the username it
--- pulled out of one. Both arrive here, because both windows that draw
--- a description have one of them and not the other.
local function author_of(mr)
  local a = mr.author
  if type(a) == "table" then
    return a.username or a.name or "?"
  end
  return a or "?"
end

--- How much conversation there is on a merge request.
---
--- Every number says what it counts, because two of them nearly do not:
--- a *thread* is one conversation however many people have been in it,
--- and a thread on a line and a thread on the merge request as a whole
--- are different enough to be counted apart. So: conversations anchored
--- to code, how many of those are settled, conversations anchored to
--- nothing, and -- separately -- how many comments were written across
--- all of them.
---
--- Nil when none of it is known: a row of the list carries no threads,
--- and "0 threads" there would be a lie rather than a count.
function M.counts(mr)
  if not mr.inline and not mr.overview then
    return nil
  end
  local resolved, comments = 0, 0
  for _, t in ipairs(mr.inline or {}) do
    if t.resolved then
      resolved = resolved + 1
    end
    comments = comments + #(t.notes or {})
  end
  for _, t in ipairs(mr.overview or {}) do
    comments = comments + #(t.notes or {})
  end
  return {
    on_lines = #(mr.inline or {}),
    resolved = resolved,
    overall = #(mr.overview or {}),
    comments = comments,
    unsent = #(mr.drafts or {}) + #(mr.draft_overview or {}) + #(mr.draft_replies or {}),
  }
end

--- The merge request as coloured lines: what it is, what state it is
--- in, and then what it says it is for.
---
--- Chunks rather than strings, and one highlight per fact rather than
--- one per line, for the same reason a note is drawn that way: this is
--- a window that is *read at a glance* to decide something -- is it
--- green, has anybody approved it, how much is left -- and a wall of
--- one colour has to be read word by word to answer any of that.
---
--- The state is a column of labels and a column of values, rather than
--- the ragged unlabelled lines this began as. "◌ 1 of 2 · reviewer"
--- alone on a line has to be parsed before it can be recognised, so
--- five such lines are read in order, one at a time, every time the
--- window opens. A label column is not read at all: the eye goes down
--- the left edge to the word it came for and across once. It also costs
--- nothing when a fact is missing -- an unbuilt branch simply has no CI
--- row, and everything else stays in the column it was in.
---
--- The heading is repeated here rather than left to the window title
--- because this is also what `:Nemeton description` shows, on its own,
--- over a file three days into a review -- at which point "which merge
--- request is this" is a real question.

-- Wide enough for the longest label, and every value starts after it.
local LABEL = "%-10s"

--- One labelled row: the label dim, the value in whatever colour the
--- value means.
local function fact(out, label, chunks)
  local line = { { LABEL:format(label), "NemetonMeta" } }
  vim.list_extend(line, chunks)
  table.insert(out, line)
end

function M.description_chunks(mr)
  local out = {}
  local ci = M.ci(mr)
  local approval = M.approval(mr.approvals)
  local counts = M.counts(mr)

  -- The number in the colour a key is drawn in and the title in the
  -- colour the list draws it in: the head of this window is the row of
  -- the list you came from, and the one thing on it that is looked up
  -- rather than read is the number.
  local head = {
    { ("!%d"):format(mr.iid or 0), "NemetonKey" },
    { "  " },
    { mr.title or "", "NemetonThread" },
  }
  -- Whether it is a draft belongs beside the title: it is the one state
  -- that says nothing here can be merged yet, however green the rest of
  -- the window is.
  if mr.draft or mr.work_in_progress then
    table.insert(head, { "  draft", "NemetonDraft" })
  end
  table.insert(out, head)

  -- Three facts in three colours rather than one line of prose: whose
  -- it is, where it goes, and when it last moved are looked for
  -- separately, and a run of one colour has to be read from the left
  -- every time to find any of them.
  local who = {
    { author_of(mr), "NemetonAuthor" },
    { " · ", "NemetonMeta" },
    { mr.source_branch or "?", "NemetonBranch" },
    { " → ", "NemetonMeta" },
    { mr.target_branch or "?", "NemetonBranch" },
  }
  if mr.updated_at then
    table.insert(who, { " · updated " .. M.ago(mr.updated_at) .. " ago", "NemetonMeta" })
  end
  table.insert(out, who)

  local facts = {}
  -- Only when it is not the state everything here is written for: a
  -- merged merge request is still full of threads to read, and nothing
  -- else in the window says the argument is over.
  local state = mr.state
  if state == "merged" or state == "closed" or state == "locked" then
    fact(facts, "State", { { state, state == "merged" and "NemetonOk" or "NemetonMeta" } })
  end
  if ci then
    fact(facts, "CI", { { ci.glyph .. " " .. ci.word, ci.hl } })
  end
  if approval then
    -- The count and the names in colours of their own: the count is a
    -- verdict -- enough, or not yet -- and the names are people, drawn
    -- the way this plugin draws people everywhere else.
    local chunks = { { approval.count, approval.hl } }
    if #approval.names > 0 then
      table.insert(chunks, { " · ", "NemetonMeta" })
      table.insert(chunks, { table.concat(approval.names, ", "), "NemetonAuthor" })
    elseif approval.required > 0 then
      table.insert(chunks, { " · nobody yet", "NemetonMeta" })
    end
    fact(facts, "Approval", chunks)
  end
  -- The size of the change, in the colours a diff is read in -- as
  -- foreground, because this is a count of lines and not a block of
  -- them; DiffAdd would put two filled tiles in the middle of a table.
  if type(mr.diff_stats) == "table" and mr.diff_stats.files then
    fact(facts, "Change", {
      { ("+%d"):format(mr.diff_stats.added or 0), "NemetonAdded" },
      { " ", "NemetonMeta" },
      { ("−%d"):format(mr.diff_stats.removed or 0), "NemetonRemoved" },
      {
        ("  in %d file%s"):format(mr.diff_stats.files, mr.diff_stats.files == 1 and "" or "s"),
        "NemetonMeta",
      },
    })
  end

  -- Conversations on two rows rather than one: threads are places to go
  -- and comments are how much there is to read, and the single line
  -- that carried all five numbers wrapped into a paragraph in a float
  -- this width -- which is the shape prose has, not the shape a count
  -- has.
  if counts then
    -- Open first, and counted rather than left to be worked out: "3 on
    -- lines · 1 resolved" is a subtraction, and the number that decides
    -- whether there is anything here for you is the answer to it. In
    -- the colour the gutter marks an unanswered thread in, so the
    -- number and the markers you are about to go and read are the same
    -- fact in the same colour.
    local open = counts.on_lines - counts.resolved
    fact(facts, "Threads", {
      { ("%d open"):format(open), open > 0 and "NemetonSignOpen" or "NemetonMeta" },
      { (", %d resolved"):format(counts.resolved), "NemetonSignResolved" },
      { (" · %d on the merge request itself"):format(counts.overall), "NemetonMeta" },
    })
    local comments = { { ("%d in all"):format(counts.comments), "NemetonMeta" } }
    if counts.unsent > 0 then
      table.insert(comments, { (" · %d unsent"):format(counts.unsent), "NemetonDraft" })
    end
    fact(facts, "Comments", comments)
  end

  if #facts > 0 then
    table.insert(out, {})
    vim.list_extend(out, facts)
  end

  table.insert(out, {})

  local body = vim.trim(mr.description or "")
  if body == "" then
    table.insert(out, { { "(no description)", "NemetonMeta" } })
    return out
  end
  -- The description itself unpainted, and starting where the labels do
  -- rather than where their values do: it is markdown, the window says
  -- so, and a colour of ours over the top of that is a colour instead
  -- of it. Sitting at the left edge is also what separates it from the
  -- block above without a rule -- and a rule would have to know how
  -- wide the window is, which this does not.
  for _, l in ipairs(vim.split(body:gsub("\r\n", "\n"), "\n", { plain = true })) do
    table.insert(out, { { l } })
  end
  return out
end

--- Everything the block at the top of a description is drawn from,
--- for a merge request that is only a row of a list.
---
--- The window under the list and the merge request's own window are
--- meant to be the same window, and a row carries about half of what
--- that window says: no approvals, and nothing about the conversation.
--- So the missing half is asked for here -- three calls at once, once
--- per merge request, cached with the rendering they go into -- rather
--- than leaving the pane a poorer version of the thing it is showing.
---
--- `mr list` carries the description itself on the GitLab versions that
--- send it, and the merge request is asked for in full only when it did
--- not: a round trip saved on the common path.
local function facts(root, mr, cb)
  local whole, pending, failed = vim.tbl_extend("keep", {}, mr), 3, false
  local function fill(data)
    for k, v in pairs(data or {}) do
      if whole[k] == nil then
        whole[k] = v
      end
    end
  end
  local function done()
    pending = pending - 1
    if pending == 0 and not failed then
      cb(whole)
    end
  end

  if mr.description ~= nil then
    done()
  else
    glab.mr_get(root, mr.iid, function(full, err)
      if not full then
        failed = true
        cb(nil, err)
        return
      end
      fill(full)
      done()
    end)
  end

  -- Both quietly: approvals are a paid feature and the endpoint 404s
  -- where they are not enabled, and a forge that will not answer either
  -- of these leaves its row out rather than putting an error in a
  -- window somebody is reading a description in.
  glab.approvals(root, mr.iid, function(data)
    whole.approvals = data
    done()
  end)
  glab.discussions(root, mr.iid, function(data)
    if type(data) == "table" then
      local parsed = threads.parse(data)
      whole.inline, whole.overview = parsed.inline, parsed.overview
    end
    done()
  end)
end

local function remember(iid, mode, chunks)
  cache[iid] = cache[iid] or {}
  cache[iid][mode] = chunks
  return chunks
end

--- `mode` is "commits" or "description". cb(lines, highlights) or
--- cb(nil, err), and called *synchronously* on a cache hit -- which is
--- what lets the preview pane redraw without a flash of "…" every time
--- the cursor moves back over a row it has already been on.
---
--- The same lines and the same colours the merge request's own window
--- draws, because it is the same question being asked from two places:
--- what is this, and is it worth opening.
function M.fetch(root, mr, mode, cb)
  local function hand(chunks)
    local lines, hls = threads.flatten(chunks, 0)
    cb(lines, hls)
  end

  local hit = cache[mr.iid] and cache[mr.iid][mode]
  if hit then
    hand(hit)
    return
  end

  if mode == "description" then
    facts(root, mr, function(whole, err)
      if not whole then
        cb(nil, err)
        return
      end
      hand(remember(mr.iid, mode, M.description_chunks(whole)))
    end)
    return
  end

  glab.mr_commits(root, mr.iid, function(commits, err)
    if not commits then
      cb(nil, err)
      return
    end
    hand(remember(mr.iid, mode, M.commit_chunks(commits)))
  end)
end

--- The winbar of a float that has keys: the keys themselves in one
--- colour and what they do in another.
---
--- Two colours because of how a hint row is used. It is not read, it is
--- searched -- "what was approve again" -- and a single dim run of
--- "a approve · c comments · p jobs" answers that only after the whole
--- line has been read word by word. The letters standing out turns the
--- row into a column of answers with their labels beside them.
---
--- `%<` at the end rather than nowhere: a statusline with no truncation
--- point is truncated at its *start*, which on a narrow window would
--- take away the first key and leave the least useful one.
function M.hint(pairs_)
  local out = {}
  for _, h in ipairs(pairs_) do
    if h[1] and h[1] ~= "" then
      table.insert(
        out,
        ("%%#NemetonKey#%s%%#NemetonHint# %s"):format((h[1]:gsub("%%", "%%%%")), h[2])
      )
    end
  end
  return "%#NemetonHint#" .. table.concat(out, "  ") .. "%<%*"
end

--- A float in the middle of the editor, for reading one of these on its
--- own rather than under the list.
---
--- Focused, unlike the peek float: a description is a page of prose you
--- scroll, and a window that closes on the first cursor movement cannot
--- be scrolled.
--- `opts.winbar` -- a winbar string, for a float that has keys of its own
--- `opts.keys`   -- { { lhs, fn, desc }, ... }, bound in the float
--- `opts.quit`   -- what closes it, if not `q`. `<Esc>` always does.
function M.float(lines, title, opts)
  opts = opts or {}
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  if opts.hls then
    require("nemeton.marks").paint(buf, opts.hls)
  end
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  local width = math.min(math.floor(vim.o.columns * 0.7), 100)
  local height = math.max(3, math.min(#lines + 1, math.floor(vim.o.lines * 0.6)))
  local back = require("nemeton.win").came_from()
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  if opts.winbar then
    vim.wo[win].winbar = opts.winbar
  end

  local function shut()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    back()
  end
  for _, key in ipairs({ opts.quit or "q", "<Esc>" }) do
    vim.keymap.set("n", key, shut, { buffer = buf, nowait = true, desc = "nemeton: close" })
  end
  for _, k in ipairs(opts.keys or {}) do
    if k[1] and k[1] ~= "" then
      vim.keymap.set("n", k[1], k[2], { buffer = buf, nowait = true, desc = "nemeton: " .. k[3] })
    end
  end
  return win, buf
end

return M
