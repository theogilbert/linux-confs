-- The open merge requests you are in, across the whole forge, in a
-- float.
--
-- "In" four ways, which the forge keeps in four places: assigned to
-- you and asked of you as a reviewer are scopes of its merge request
-- list; a comment that named you is a to-do, pending or done; and one
-- you have commented on is only in your activity, as events that name
-- a project and a number and nothing else. So this is several calls,
-- drawn as each lands, and one row per merge request however many of
-- them found it.
--
-- Like the to-do list it is yours and not a project's: it needs no
-- review open and no repository, and opens one of the repository you
-- are in here and anything else on the forge.

local config = require("nemeton.config")
local detail = require("nemeton.detail")
local follow = require("nemeton.follow")
local glab = require("nemeton.glab")
local marks = require("nemeton.marks")
local session = require("nemeton.session")
local threads = require("nemeton.threads")
local win = require("nemeton.win")

local M = {}

M.win = nil
M.buf = nil
-- Every merge request found so far, by its forge-wide id: `{ mr =
-- <GitLab's object>, why = { [reason] = true } }`.
local found = {}
-- Row number (1-based) -> the entry on it.
local rows = {}
-- Which reason is shown, by name in `M.REASONS`; nil is all of them.
local filter = nil
-- How many calls have yet to land, and what the ones that failed said.
local pending, failed = 0, {}
local where, here, back = nil, nil, nil

-- The ways in, in the order they are said and `f` walks them: what
-- somebody is waiting on you for first, what was said to you, and what
-- you said last.
M.REASONS = {
  { name = "review", word = "review", hl = "NemetonKey" },
  { name = "assigned", word = "assigned", hl = "NemetonAuthor" },
  { name = "mentioned", word = "@you", hl = "NemetonMention" },
  { name = "commented", word = "commented", hl = "NemetonMeta" },
}

-- The to-dos that are a comment naming you.
local MENTIONS = { mentioned = true, directly_addressed = true }

-- Pages of your comments read, at a hundred each: the most recent five
-- hundred. Somebody who has written more than that since commenting on
-- a merge request that is still open has stopped waiting on it.
local COMMENT_PAGES = 5

--- Adds `mrs` (GitLab merge request objects) under `reason` to `into`,
--- keyed by id, and gives `into` back. Anything not open is left out:
--- a to-do keeps naming a merge request that has since merged.
function M.add(into, mrs, reason)
  for _, mr in ipairs(mrs or {}) do
    if type(mr) == "table" and mr.id and mr.state == "opened" then
      local e = into[mr.id] or { mr = mr, why = {} }
      e.why[reason] = true
      into[mr.id] = e
    end
  end
  return into
end

--- The merge requests the to-dos `todos` say named you.
function M.mentioned(todos)
  local out = {}
  for _, t in ipairs(todos or {}) do
    if MENTIONS[t.action_name] and t.target_type == "MergeRequest" then
      table.insert(out, t.target)
    end
  end
  return out
end

--- `{ [project_id] = { iid, ... } }`: the merge requests the comment
--- events `events` were written on that `known` does not have yet.
--- Those it does have are marked commented on where they are, rather
--- than asked for again.
function M.commented(events, known)
  local have = {}
  for _, e in pairs(known or {}) do
    if e.mr.project_id then
      have[e.mr.project_id .. "!" .. e.mr.iid] = e
    end
  end
  local out = {}
  for _, ev in ipairs(events or {}) do
    local note = ev.note
    if note and note.noteable_type == "MergeRequest" and note.noteable_iid and ev.project_id then
      local key = ev.project_id .. "!" .. note.noteable_iid
      if have[key] then
        if have[key] ~= true then
          have[key].why.commented = true
        end
      else
        have[key] = true
        out[ev.project_id] = out[ev.project_id] or {}
        table.insert(out[ev.project_id], note.noteable_iid)
      end
    end
  end
  return out
end

--- The entries `name` lets through, the most recently touched first;
--- nil lets every one through.
function M.only(all, name)
  local out = {}
  for _, e in pairs(all) do
    if not name or e.why[name] then
      table.insert(out, e)
    end
  end
  table.sort(out, function(a, b)
    if (a.mr.updated_at or "") ~= (b.mr.updated_at or "") then
      return (a.mr.updated_at or "") > (b.mr.updated_at or "")
    end
    return a.mr.id > b.mr.id
  end)
  return out
end

--- The filters worth walking to: all of them first, then each reason
--- with something under it.
function M.filters(all)
  local out = { false }
  for _, r in ipairs(M.REASONS) do
    if #M.only(all, r.name) > 0 then
      table.insert(out, r.name)
    end
  end
  return out
end

--- `group/proj!12`.
function M.reference(mr)
  if type(mr.references) == "table" and mr.references.full then
    return mr.references.full
  end
  return "!" .. tostring(mr.iid)
end

local function why_width(e)
  local n = 0
  for _, r in ipairs(M.REASONS) do
    if e.why[r.name] then
      n = n + #r.word + 1
    end
  end
  return n
end

--- One row, as coloured chunks: why, which, what, by whom, when it last
--- moved. `widths` is `{ why, ref }`, the widest of the rows shown.
function M.row(e, widths)
  local chunks = { { " " } }
  for _, r in ipairs(M.REASONS) do
    if e.why[r.name] then
      table.insert(chunks, { r.word .. " ", r.hl })
    end
  end
  table.insert(chunks, { (" "):rep(math.max(widths[1] - why_width(e), 0) + 1) })
  local mr = e.mr
  local ref = M.reference(mr)
  table.insert(chunks, {
    ref .. (" "):rep(math.max(widths[2] - vim.fn.strdisplaywidth(ref), 0) + 2),
    "NemetonPath",
  })
  local title = vim.fn.strcharpart(mr.title or "", 0, 56)
  if mr.draft then
    table.insert(chunks, { "draft ", "NemetonMeta" })
    title = vim.fn.strcharpart(title, 0, 50)
  end
  local author = (mr.author and mr.author.username or "?"):sub(1, 14)
  vim.list_extend(chunks, {
    { title, "NemetonThread" },
    { (" "):rep(math.max(57 - vim.fn.strdisplaywidth(title) - (mr.draft and 6 or 0), 1)) },
    { author, "NemetonAuthor" },
    { (" "):rep(math.max(15 - vim.fn.strdisplaywidth(author), 1)) },
    { detail.ago(mr.updated_at), "NemetonMeta" },
  })
  return chunks
end

local function valid()
  return M.win ~= nil and vim.api.nvim_win_is_valid(M.win)
end

function M.close()
  if valid() then
    vim.api.nvim_win_close(M.win, true)
  end
  M.win, M.buf, found, rows, filter = nil, nil, {}, {}, nil
end

local function current()
  if not valid() then
    return nil
  end
  return rows[vim.api.nvim_win_get_cursor(M.win)[1]]
end

local function set_title()
  if not valid() then
    return
  end
  local all = #M.only(found, nil)
  local title = filter and (" merge requests · %s %d/%d "):format(filter, #rows, all)
    or (" merge requests · %d "):format(all)
  if pending > 0 then
    title = title .. "… "
  end
  vim.api.nvim_win_set_config(M.win, { title = title, title_pos = "center" })
end

local function draw()
  if not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) then
    return
  end
  rows = M.only(found, filter)
  local lines, hls = {}, {}
  if #rows > 0 then
    local widths = { 0, 0 }
    for _, e in ipairs(rows) do
      widths[1] = math.max(widths[1], why_width(e))
      widths[2] = math.max(widths[2], vim.fn.strdisplaywidth(M.reference(e.mr)))
    end
    widths[2] = math.min(widths[2], 32)
    lines, hls = threads.flatten(
      vim.tbl_map(function(e)
        return M.row(e, widths)
      end, rows),
      0
    )
  end
  -- What went wrong stays under the rows rather than instead of them:
  -- three of the four ways in having answered is three quarters of the
  -- list, and worth reading.
  for _, said in ipairs(failed) do
    table.insert(lines, "  " .. said)
  end
  if #lines == 0 then
    lines = { pending > 0 and "  …" or "  nothing open that you are in" }
  end
  vim.bo[M.buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.bo[M.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(M.buf, marks.ui_ns, 0, -1)
  marks.paint(M.buf, hls)
  set_title()
end

local function load()
  local mine = M.buf
  found, failed, pending = {}, {}, 0
  -- Each call says it is out, and lands through here: what it found
  -- goes into the list, or what it said into the lines under it; then
  -- `after`, either way.
  local function ask(what, call, take, after)
    pending = pending + 1
    call(function(data, err)
      if M.buf ~= mine or not valid() then
        return
      end
      pending = pending - 1
      if data then
        take(data)
      else
        table.insert(failed, ("could not read %s: %s"):format(what, tostring(err)))
      end
      if after then
        after()
      end
      if filter and pending == 0 and #M.only(found, filter) == 0 then
        filter = nil
      end
      draw()
    end)
  end

  -- What you commented on is looked up last, because it is a set of
  -- numbers rather than merge requests: whatever the other ways in
  -- found need not be asked for again. Five calls to wait on: two
  -- scopes, two kinds of to-do, and the pages of comments.
  local events, waiting = {}, 5
  local function landed()
    waiting = waiting - 1
    if waiting > 0 then
      return
    end
    for project, iids in pairs(M.commented(events, found)) do
      ask("the merge requests you commented on", function(cb)
        glab.open_mrs(where, project, iids, cb)
      end, function(mrs)
        M.add(found, mrs, "commented")
      end)
    end
  end

  for _, s in ipairs({
    { "assigned_to_me", "assigned", "what is assigned to you" },
    { "reviews_for_me", "review", "the reviews asked of you" },
  }) do
    ask(s[3], function(cb)
      glab.my_mrs(where, s[1], cb)
    end, function(mrs)
      M.add(found, mrs, s[2])
    end, landed)
  end
  for _, state in ipairs({ "pending", "done" }) do
    ask("the comments that name you", function(cb)
      glab.mr_todos(where, state, cb)
    end, function(todos)
      M.add(found, M.mentioned(todos), "mentioned")
    end, landed)
  end
  local function page(n)
    local more = false
    ask("your comments", function(cb)
      glab.comment_events(where, n, cb)
    end, function(data)
      vim.list_extend(events, data)
      more = #data >= 100 and n < COMMENT_PAGES
    end, function()
      if more then
        page(n + 1)
      else
        landed()
      end
    end)
  end
  page(1)
  draw()
end

local function open(e)
  local mr = e.mr
  local ours = here and mr.references and mr.references.full == here .. "!" .. mr.iid
  if ours then
    M.close()
    require("nemeton").open(mr.iid)
  else
    follow.browse(mr.web_url)
  end
end

local function show()
  back = win.came_from()
  filter = nil

  local width = math.min(vim.o.columns - 4, 140)
  local height = math.max(4, math.floor(vim.o.lines * 0.6))
  M.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[M.buf].bufhidden = "wipe"
  M.win = vim.api.nvim_open_win(M.buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " merge requests ",
    title_pos = "center",
  })
  vim.wo[M.win].cursorline = true
  vim.wo[M.win].wrap = false

  local k = config.keys.involved
  vim.wo[M.win].winbar = detail.hint({
    { k.open, "open" },
    { k.filter, "filter" },
    { k.browser, follow.browse_hint() },
  }, k.help)

  local bindings = {
    {
      k.open,
      function()
        local e = current()
        if e then
          open(e)
        end
      end,
      "open it: here if it is of this repository, on GitLab if not",
    },
    {
      k.filter,
      function()
        local walk = M.filters(found)
        local i = 1
        for n, f in ipairs(walk) do
          if f == (filter or false) then
            i = n
          end
        end
        filter = walk[i % #walk + 1] or nil
        draw()
        vim.api.nvim_win_set_cursor(M.win, { 1, 0 })
      end,
      "show one way in: review, assigned, @you, commented, all",
    },
    {
      k.browser,
      function()
        local e = current()
        if e then
          follow.browse(e.mr.web_url)
        end
      end,
      "open it on GitLab",
    },
    { k.refresh, load, "refetch" },
    {
      k.quit,
      function()
        M.close()
        back()
      end,
      "close",
    },
  }
  detail.bind(M.buf, bindings, k.help, " merge requests ")
  load()
  return M.win
end

--- The open merge requests you are in, across the forge, in a float.
function M.open()
  if not glab.available() then
    session.notify("glab is not on your PATH", vim.log.levels.ERROR)
    return
  end
  if valid() then
    vim.api.nvim_set_current_win(M.win)
    return
  end
  session.locate(function(at, project)
    if not at then
      session.notify(
        "not in a GitLab project, and no glab.backup_host to ask instead — "
          .. "set it to the host whose merge requests to list outside one",
        vim.log.levels.ERROR
      )
      return
    end
    if valid() then
      return
    end
    where, here = at, project
    show()
  end)
end

return M
