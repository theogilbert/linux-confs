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
-- Open ones, and closed ones once `f` asks for them: what was closed
-- on you may still want an answer, but it is a second look.
--
-- Like the to-do list it is yours and not a project's: it needs no
-- review open and no repository, and opens one of the repository you
-- are in here and anything else on the forge.

local checklist = require("nemeton.checklist")
local config = require("nemeton.config")
local detail = require("nemeton.detail")
local follow = require("nemeton.follow")
local glab = require("nemeton.glab")
local marks = require("nemeton.marks")
local session = require("nemeton.session")
local spin = require("nemeton.spin")
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
-- What is shown: `{ [reason] = true, [state] = true }`, by name in
-- `M.REASONS` and `M.STATES`; nil is `M.SHOWN`. Back to that on every
-- opening, like any filter: the next look is a fresh one.
local filter = nil
-- What `i` narrowed the rows to, "" for nothing. Back to that on every
-- opening, like the filter.
local query = ""
-- Whether the closed ones have been asked for since the last load.
local asked_closed = false
-- How many calls have yet to land, and what the ones that failed said.
local pending, failed = 0, {}
-- `project_id!iid` -> when the forge last pointed you at it: the
-- newest to-do about it, or comment of yours on it.
local dates = {}
-- What the rows are in order of, by name in `M.SORTS`, and which way
-- round. Kept across opening and closing it, for the editor session.
local sort = { by = "moved", newest = true }
local where, here, back = nil, nil, nil

-- The ways in, in the order they are said and `f` offers them: what
-- somebody is waiting on you for first, what was said to you, and what
-- you said last.
M.REASONS = {
  { name = "review", word = "review", hl = "NemetonKey" },
  { name = "assigned", word = "assigned", hl = "NemetonAuthor" },
  { name = "mentioned", word = "@you", hl = "NemetonMention" },
  { name = "commented", word = "commented", hl = "NemetonMeta" },
}

-- The states a row can be in. Closed is kept, unlike merged: a merge
-- request closed on you is a question that may still want an answer
-- -- why, and whether it is coming back -- where a merged one has been
-- answered.
M.STATES = {
  { name = "opened", word = "open" },
  { name = "closed", word = "closed" },
}

-- What the window shows when it opens: every way in, and what is open.
-- The closed ones cost two calls more and are a second look, not the
-- first.
M.SHOWN = {
  review = true,
  assigned = true,
  mentioned = true,
  commented = true,
  opened = true,
}

-- What the rows can be in order of, in the order the sort float offers
-- them: when it last moved, which is what is worth reading first; when
-- you were last pointed at it -- asked to review it, assigned it,
-- named in a comment on it, or commenting on it yourself; and when it
-- was opened.
M.SORTS = {
  { name = "moved", word = "last moved" },
  { name = "you", word = "last pointed at you" },
  { name = "opened", word = "opened" },
}

-- The to-dos that are a comment naming you.
local MENTIONS = { mentioned = true, directly_addressed = true }

-- Pages of your comments read, at a hundred each: the most recent five
-- hundred. Somebody who has written more than that since commenting on
-- a merge request that is still open has stopped waiting on it.
local COMMENT_PAGES = 5

--- Adds `mrs` (GitLab merge request objects) under `reason` to `into`,
--- keyed by id, and gives `into` back. Only what is open or closed:
--- a to-do keeps naming a merge request that has since merged.
function M.add(into, mrs, reason)
  for _, mr in ipairs(mrs or {}) do
    if type(mr) == "table" and mr.id and (mr.state == "opened" or mr.state == "closed") then
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
      -- With the to-do's project where the target came without its
      -- own, which is what it is found by again.
      local mr = t.target
      if type(mr) == "table" and not mr.project_id and t.project then
        mr = vim.tbl_extend("force", mr, { project_id = t.project.id })
      end
      table.insert(out, mr)
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

local function key(project, iid)
  return tostring(project) .. "!" .. tostring(iid)
end

-- The part of a timestamp that sorts as a string: GitLab writes them
-- in UTC, and the fraction of a second is not always there.
local function stamp(iso)
  return type(iso) == "string" and iso:match("^%d+%-%d+%-%d+T%d+:%d+:%d+") or nil
end

local function later(into, k, iso)
  local s = stamp(iso)
  if s and (not into[k] or stamp(into[k]) < s) then
    into[k] = iso
  end
end

--- Adds to `into` when each merge request the to-dos `todos` are about
--- was last pointed at you -- whatever the to-do was for -- and the
--- same for the comment events `events`, and gives `into` back.
function M.dated(into, todos, events)
  for _, t in ipairs(todos or {}) do
    local mr = t.target
    -- The project is the to-do's as well as its target's, and some
    -- forges fill in only the one.
    local project = type(mr) == "table" and mr.project_id or (t.project and t.project.id)
    if t.target_type == "MergeRequest" and project then
      later(into, key(project, mr.iid), t.created_at)
    end
  end
  for _, ev in ipairs(events or {}) do
    local note = ev.note
    if note and note.noteable_type == "MergeRequest" and ev.project_id then
      later(into, key(ev.project_id, note.noteable_iid), ev.created_at)
    end
  end
  return into
end

--- The timestamp of `e` that `by` (a name in `M.SORTS`) sorts on, or
--- nil where it has none.
function M.when(e, by, known)
  if by == "you" then
    return (known or {})[key(e.mr.project_id, e.mr.iid)]
  end
  return by == "opened" and e.mr.created_at or e.mr.updated_at
end

--- The entries `shown` lets through -- found one of the ways it
--- ticks, and in one of the states it ticks; `M.SHOWN` where it is nil
--- -- in the order `order` says: `{ by = <name in M.SORTS>, newest =
--- bool }`, the most recently moved first where it is nil. One with no
--- time to sort on is last either way round: it is not the oldest,
--- only unknown.
function M.only(all, shown, order, known)
  shown = shown or M.SHOWN
  order = order or { by = "moved", newest = true }
  local out = {}
  for _, e in pairs(all) do
    local why = false
    for r in pairs(e.why) do
      why = why or shown[r] or false
    end
    if why and shown[e.mr.state] then
      table.insert(out, e)
    end
  end
  table.sort(out, function(a, b)
    local x, y = stamp(M.when(a, order.by, known)), stamp(M.when(b, order.by, known))
    if x ~= y then
      if not (x and y) then
        return x ~= nil
      end
      if order.newest then
        return x > y
      end
      return x < y
    end
    return a.mr.id > b.mr.id
  end)
  return out
end

--- Whether `e` is what the search `q` asks for: every word of it, a
--- number being the merge request's own -- `12` and `!12` both, and
--- not the `!123` that has those digits in it -- and anything else
--- found, smartcase, in its `group/proj!12`, its title, its author,
--- the words for its state (`open`, `closed`, `draft`), or a way in.
function M.matches(e, q)
  local mr = e.mr
  local said = {
    M.reference(mr),
    mr.title or "",
    mr.author and mr.author.username or "",
    mr.state == "closed" and "closed" or "open",
    mr.draft and "draft" or "",
  }
  for _, r in ipairs(M.REASONS) do
    if e.why[r.name] then
      table.insert(said, r.word)
    end
  end
  local hay = table.concat(said, " ")
  for word in (q or ""):gmatch("%S+") do
    local n = word:match("^!?(%d+)$")
    if n then
      if tostring(mr.iid) ~= n then
        return false
      end
    elseif word:find("%u") then
      if not hay:find(word, 1, true) then
        return false
      end
    elseif not hay:lower():find(word, 1, true) then
      return false
    end
  end
  return true
end

--- What `shown` narrows the list to, in words for the title: the ways
--- in ticked where not all of them are, and the states where they are
--- not the open ones alone. Nil where it is `M.SHOWN`.
function M.describe(shown)
  local parts, ways = {}, {}
  for _, r in ipairs(M.REASONS) do
    if shown[r.name] then
      table.insert(ways, r.word)
    end
  end
  if #ways < #M.REASONS then
    table.insert(parts, #ways > 0 and table.concat(ways, " ") or "no way in")
  end
  local states = {}
  for _, st in ipairs(M.STATES) do
    if shown[st.name] then
      table.insert(states, st.word)
    end
  end
  if not (#states == 1 and shown.opened) then
    table.insert(parts, #states > 0 and table.concat(states, " + ") or "no state")
  end
  return #parts > 0 and table.concat(parts, " · ") or nil
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

--- One row, as coloured chunks: why, which, what, by whom, and when --
--- `when`, the time it is sorted by, since that is the column that
--- says why it is where it is. `widths` is `{ why, ref }`, the widest
--- of the rows shown.
function M.row(e, widths, when)
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
  -- What it is, where that is not open and ready: said once, before
  -- the title, as the queue says it.
  local said = (mr.state == "closed" and "closed " or "") .. (mr.draft and "draft " or "")
  if said ~= "" then
    table.insert(chunks, { said, "NemetonMeta" })
    title = vim.fn.strcharpart(title, 0, 56 - #said)
  end
  local author = (mr.author and mr.author.username or "?"):sub(1, 14)
  vim.list_extend(chunks, {
    { title, "NemetonThread" },
    { (" "):rep(math.max(57 - vim.fn.strdisplaywidth(title) - #said, 1)) },
    { author, "NemetonAuthor" },
    { (" "):rep(math.max(15 - vim.fn.strdisplaywidth(author), 1)) },
    { when and detail.ago(when) or "-", "NemetonMeta" },
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
  M.win, M.buf, found, rows, filter, asked_closed = nil, nil, {}, {}, nil, false
  query = ""
  checklist.close()
  spin.stop("involved")
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
  local said = {}
  table.insert(said, filter and M.describe(filter) or nil)
  table.insert(said, query ~= "" and "/" .. query or nil)
  local title = #said > 0
      and (" merge requests · %s %d/%d "):format(
        table.concat(said, " · "),
        #rows,
        vim.tbl_count(found)
      )
    or (" merge requests · %d "):format(#rows)
  -- The order, where it is not the one the window opens in.
  if sort.by ~= "moved" or not sort.newest then
    for _, s in ipairs(M.SORTS) do
      if s.name == sort.by then
        title = title .. ("· %s %s "):format(s.word, sort.newest and "↓" or "↑")
      end
    end
  end
  if where and where.host then
    title = (" %s ·"):format(where.host) .. title
  end
  -- Still asking: turning, where there is something to turn.
  if pending > 0 then
    title = spin.on("involved") and " " .. spin.glyph("involved") .. title:sub(2) or title .. "… "
  end
  vim.api.nvim_win_set_config(M.win, { title = title, title_pos = "center" })
end

local function draw()
  if not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) then
    return
  end
  rows = M.only(found, filter, sort, dates)
  if query ~= "" then
    rows = vim.tbl_filter(function(e)
      return M.matches(e, query)
    end, rows)
  end
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
        return M.row(e, widths, M.when(e, sort.by, dates))
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
    lines = {
      pending > 0 and "  …"
        or query ~= "" and "  nothing that matches /" .. query
        or "  nothing open that you are in",
    }
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
  found, failed, pending, dates = {}, {}, 0, {}
  asked_closed = (filter or M.SHOWN).closed or false
  -- The scopes are asked a state at a time: a page of "all" of what
  -- was ever assigned to you is mostly merged, and would crowd the
  -- open ones off it. A list of numbers is short whatever it is asked.
  local states = asked_closed and { "opened", "closed" } or { "opened" }
  -- Each call says it is out, and lands through here: what it found
  -- goes into the list, or what it said into the lines under it; then
  -- `after`, either way.
  local function ask(what, call, take, after)
    pending = pending + 1
    spin.start("involved", set_title)
    call(function(data, err)
      if M.buf ~= mine or not valid() then
        return
      end
      pending = pending - 1
      if pending <= 0 then
        spin.stop("involved")
      end
      if data then
        take(data)
      else
        table.insert(failed, ("could not read %s: %s"):format(what, tostring(err)))
      end
      if after then
        after()
      end
      draw()
    end)
  end

  -- What you commented on is looked up last, because it is a set of
  -- numbers rather than merge requests: whatever the other ways in
  -- found need not be asked for again. Calls to wait on: two scopes a
  -- state, two kinds of to-do, and the pages of comments.
  local events, waiting = {}, 2 * #states + 3
  local function landed()
    waiting = waiting - 1
    if waiting > 0 then
      return
    end
    for project, iids in pairs(M.commented(events, found)) do
      ask("the merge requests you commented on", function(cb)
        glab.project_mrs(where, project, iids, asked_closed and "all" or "opened", cb)
      end, function(mrs)
        M.add(found, mrs, "commented")
      end)
    end
  end

  for _, state in ipairs(states) do
    for _, s in ipairs({
      { glab.assigned_mrs, "assigned", "what is assigned to you" },
      { glab.review_mrs, "review", "the reviews asked of you" },
    }) do
      ask(s[3], function(cb)
        s[1](where, state, cb)
      end, function(mrs)
        M.add(found, mrs, s[2])
      end, landed)
    end
  end
  for _, state in ipairs({ "pending", "done" }) do
    ask("the comments that name you", function(cb)
      glab.mr_todos(where, state, cb)
    end, function(todos)
      M.add(found, M.mentioned(todos), "mentioned")
      M.dated(dates, todos)
    end, landed)
  end
  local function page(n)
    local more = false
    ask("your comments", function(cb)
      glab.comment_events(where, n, cb)
    end, function(data)
      vim.list_extend(events, data)
      M.dated(dates, nil, data)
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

--- What the rows are in order of, ticked in a float, redrawn on every
--- tick.
local function choose_sort()
  local items = {}
  for _, s in ipairs(M.SORTS) do
    table.insert(items, { key = s.name, label = s.word, group = "by" })
  end
  vim.list_extend(items, {
    { key = "newest", label = "newest first", group = "order" },
    { key = "oldest", label = "oldest first", group = "order" },
  })
  checklist.open({
    title = "sort by",
    items = items,
    on = { [sort.by] = true, [sort.newest and "newest" or "oldest"] = true },
    on_change = function(on)
      for _, s in ipairs(M.SORTS) do
        if on[s.name] then
          sort.by = s.name
        end
      end
      sort.newest = on.newest or false
      draw()
      if valid() then
        vim.api.nvim_win_set_cursor(M.win, { 1, 0 })
      end
    end,
  })
end

--- What is shown, ticked in a float: the ways in, and the states.
--- Redrawn as it is ticked, and asked of the forge again the first
--- time the closed ones are, which the opening load leaves out.
local function choose_filter()
  local items = {}
  for _, r in ipairs(M.REASONS) do
    table.insert(items, { key = r.name, label = r.word })
  end
  for i, st in ipairs(M.STATES) do
    table.insert(items, { key = st.name, label = st.word, gap = i == 1 })
  end
  checklist.open({
    title = "show",
    items = items,
    on = filter or M.SHOWN,
    on_change = function(on)
      filter = on
      if on.closed and not asked_closed then
        load()
      else
        draw()
      end
      if valid() then
        vim.api.nvim_win_set_cursor(M.win, { 1, 0 })
      end
    end,
  })
end

--- `i`: a box over the list, narrowing it as it is typed. `<CR>` keeps
--- what was typed; `<Esc>` puts back what the list showed before, the
--- way vim's own `/` does with `incsearch`.
function M.search()
  if not valid() then
    return
  end
  local before = query
  local g = vim.api.nvim_win_get_config(M.win)
  local row = type(g.row) == "table" and g.row[false] or g.row
  local function narrow(text)
    query = vim.trim(text or "")
    draw()
    if valid() then
      vim.api.nvim_win_set_cursor(M.win, { 1, 0 })
    end
  end
  require("nemeton.prompt").open({
    title = "search merge requests",
    text = query,
    menu = false,
    at = { row = math.max(row - 3, 0), col = g.col, width = g.width },
    on_change = narrow,
    on_cancel = function()
      narrow(before)
    end,
  }, narrow)
end

local function show()
  back = win.came_from()
  filter, query = nil, ""

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
    { k.search, "search" },
    { k.filter, "filter" },
    { k.sort, "sort" },
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
      k.search,
      M.search,
      "search: its number, group/proj, title, author, open closed draft, why",
    },
    {
      k.filter,
      choose_filter,
      "what it shows, ticked in a float: review, assigned, @you, commented; open, closed",
    },
    {
      k.sort,
      choose_sort,
      "sort by when it last moved, was last pointed at you, or was opened",
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
        "not in a GitLab project, and glab names no host to ask instead — "
          .. "set glab.backup_host to the one whose merge requests to list outside one",
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
