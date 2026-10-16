-- One issue, in a tab of its own.
--
-- A tab and not a float, which is where this plugin differs from the
-- merge request's window on purpose. A merge request is read beside its
-- code, and its window is a glance taken in the middle of that -- what
-- CI said, who has approved -- and then closed. An issue is the thing
-- being read: it is kept open while a branch is written to fix it, gone
-- back to, read again. A float is in the way of all of that, and a tab
-- is the editor's own way of keeping a page open to one side: `gt`,
-- `:tabs`, `<C-w>` inside it, several issues in several tabs, and the
-- composer as an ordinary split under it.
--
-- The issue's own text in the buffer -- what it is, what state, whose,
-- and then what it says -- and what has been said under it in a pane
-- beside it (`nemeton.issue_comments`), the way a review's
-- conversations are read beside the code.
--
-- Drawn from the cache on the keypress where the issue is in it, and
-- from the forge as soon as that answers: the cache is a copy for
-- searching, and the window is what the forge says.

local config = require("nemeton.config")
local detail = require("nemeton.detail")
local follow = require("nemeton.follow")
local glab = require("nemeton.glab")
local marks = require("nemeton.marks")
local session = require("nemeton.session")

local M = {}

-- "root\0iid" -> the open issue: { buf, subject, view, related, awards }.
-- One per issue: opening one that is already open goes to its tab.
local open = {}

local function key(root, iid)
  return root .. "\0" .. tostring(iid)
end

--- An issue as the window draws it, out of either shape it arrives in:
--- REST's (`glab.issue_get`, a POST's answer) or the cache's record
--- (`nemeton.issues`). The labels are names in one and objects in the
--- other, with their colours where the forge sent them.
function M.view(raw)
  local function name(user)
    if type(user) == "table" then
      return user.username or user.name
    end
    return user
  end
  local labels = {}
  for _, l in ipairs(raw.labels or {}) do
    if type(l) == "string" then
      table.insert(labels, { title = l })
    elseif type(l) == "table" then
      table.insert(labels, {
        title = l.title or l.name,
        color = l.color,
        text_color = l.text_color,
      })
    end
  end
  return {
    iid = tonumber(raw.iid),
    title = raw.title or "",
    description = raw.description or "",
    state = raw.state,
    web_url = raw.web_url,
    created_at = raw.created_at,
    updated_at = raw.updated_at,
    closed_at = raw.closed_at,
    confidential = raw.confidential == true,
    author = name(raw.author),
    assignees = vim.tbl_map(name, raw.assignees or {}),
    labels = labels,
    notes = raw.user_notes_count or raw.notes_count,
    upvotes = raw.upvotes or 0,
    downvotes = raw.downvotes or 0,
  }
end

--- The highlight a label is drawn in: its own colours, as a chip, the
--- way the forge draws one. Made the first time a colour is asked for
--- and again after a `:colorscheme`, which clears every group.
local function label_hl(l)
  local bg = type(l.color) == "string" and l.color:match("^#%x%x%x%x%x%x$")
  if not bg then
    return "NemetonLabel"
  end
  local name = "NemetonLabel_" .. bg:sub(2)
  if vim.tbl_isempty(vim.api.nvim_get_hl(0, { name = name })) then
    local fg = type(l.text_color) == "string" and l.text_color:match("^#%x%x%x%x%x%x$")
    vim.api.nvim_set_hl(0, name, { bg = bg, fg = fg or "#FFFFFF" })
  end
  return name
end

M.label_hl = label_hl

--- The labels as chips: each in its own colour, a space either side.
function M.label_chunks(labels)
  local out = {}
  for i, l in ipairs(labels) do
    if i > 1 then
      table.insert(out, { " " })
    end
    table.insert(out, { " " .. l.title .. " ", label_hl(l) })
  end
  return out
end

-- Wide enough for the longest label, as the merge request's window.
local LABEL = "%-10s"

local function fact(out, label, chunks)
  local line = { { LABEL:format(label), "NemetonMeta" } }
  vim.list_extend(line, chunks)
  table.insert(out, line)
end

--- The issue as coloured lines: what it is, the facts about it in a
--- column, and what it says.
---
--- The same shape as the merge request's window
--- (`detail.description_chunks`), so the two are read the same way:
--- the number and title, whose and when, a column of labelled facts,
--- and the description at the left edge under them.
---
--- `extra.related` is the merge requests about it, `extra.awards` the
--- reactions on it, `extra.me` whose token this is.
function M.chunks(v, extra)
  extra = extra or {}
  local out = {}
  local head = {
    { ("#%d"):format(v.iid or 0), "NemetonKey" },
    { "  " },
    { v.title, "NemetonThread" },
  }
  if v.confidential then
    table.insert(head, { "  confidential", "NemetonBad" })
  end
  table.insert(out, head)

  local who = { { v.author or "?", "NemetonAuthor" } }
  if v.created_at then
    table.insert(who, { " · opened " .. detail.ago(v.created_at) .. " ago", "NemetonMeta" })
  end
  if v.updated_at then
    table.insert(who, { " · updated " .. detail.ago(v.updated_at) .. " ago", "NemetonMeta" })
  end
  table.insert(out, who)

  local facts = {}
  -- Only where it is not the state an issue is written for, as in the
  -- merge request's window: an open issue is the ordinary case, and a
  -- row saying so is a row saying nothing.
  if v.state == "closed" then
    fact(facts, "State", {
      { "closed", "NemetonMeta" },
      v.closed_at and { " " .. detail.ago(v.closed_at) .. " ago", "NemetonMeta" } or nil,
    })
  end
  local assignees = {}
  for i, a in ipairs(v.assignees) do
    if i > 1 then
      table.insert(assignees, { ", ", "NemetonMeta" })
    end
    table.insert(assignees, { a == extra.me and "you" or a, "NemetonAuthor" })
  end
  fact(facts, "Assignees", #assignees > 0 and assignees or { { "nobody", "NemetonMeta" } })
  fact(facts, "Labels", #v.labels > 0 and M.label_chunks(v.labels) or { { "none", "NemetonMeta" } })
  if extra.awards and #extra.awards > 0 then
    -- Counted by name, in the order they were first given: the row the
    -- forge draws under an issue, and what the comments draw under a
    -- note.
    local order, count, mine = {}, {}, {}
    for _, a in ipairs(extra.awards) do
      if not count[a.name] then
        table.insert(order, a.name)
        count[a.name] = 0
      end
      count[a.name] = count[a.name] + 1
      if vim.tbl_get(a, "user", "username") == extra.me then
        mine[a.name] = true
      end
    end
    local chunks = {}
    for i, name in ipairs(order) do
      if i > 1 then
        table.insert(chunks, { "  " })
      end
      table.insert(chunks, {
        ("%s %d"):format(require("nemeton.threads").emoji(":" .. name .. ":"), count[name]),
        mine[name] and "NemetonReactionMine" or "NemetonReaction",
      })
    end
    fact(facts, "Reactions", chunks)
  end
  if extra.related and #extra.related > 0 then
    for i, mr in ipairs(extra.related) do
      local state = mr.state ~= "opened" and (" · " .. tostring(mr.state)) or ""
      fact(facts, i == 1 and "Merge req" or "", {
        { ("!%d"):format(mr.iid or 0), "NemetonKey" },
        { "  " .. (mr.title or ""), "NemetonThread" },
        { state, mr.state == "merged" and "NemetonOk" or "NemetonMeta" },
      })
    end
  end
  if v.notes then
    fact(facts, "Comments", { { tostring(v.notes), "NemetonMeta" } })
  end
  table.insert(out, {})
  vim.list_extend(out, facts)
  table.insert(out, {})

  local body = vim.trim(v.description or "")
  if body == "" then
    table.insert(out, { { "(no description)", "NemetonMeta" } })
    return out
  end
  -- Unpainted, at the left edge, as the merge request's is: it is
  -- markdown and the buffer says so.
  for _, l in ipairs(vim.split(body:gsub("\r\n", "\n"), "\n", { plain = true })) do
    table.insert(out, { { l } })
  end
  return out
end

local function valid(entry)
  return entry and entry.buf and vim.api.nvim_buf_is_valid(entry.buf)
end

--- Draws `entry` into its buffer.
local function draw(entry)
  if not (valid(entry) and entry.view) then
    return
  end
  local lines, hls = require("nemeton.threads").flatten(M.chunks(entry.view, entry), 0)
  vim.bo[entry.buf].modifiable = true
  vim.api.nvim_buf_set_lines(entry.buf, 0, -1, false, lines)
  vim.bo[entry.buf].modifiable = false
  marks.paint(entry.buf, hls)
end

local function hint(entry)
  local k = config.keys.issue
  local closed = entry.view and entry.view.state == "closed"
  return detail.hint({
    { k.comments, "comments" },
    { k.describe, "describe" },
    { k.close, closed and "reopen" or "close" },
  }, k.help)
end

local function redraw(entry)
  draw(entry)
  for _, w in ipairs(vim.fn.win_findbuf(entry.buf or -1)) do
    vim.wo[w].winbar = hint(entry)
  end
  if entry.subject then
    entry.subject.web_url = entry.view and entry.view.web_url or entry.subject.web_url
  end
end

--- What the forge answered a change with, onto the window.
local function took(entry, data)
  if type(data) == "table" and data.iid then
    entry.view = M.view(data)
    redraw(entry)
    require("nemeton.issue_cache").refresh_one(entry.subject.root, entry.view.iid)
  end
end

--- Asks the forge for all of it again: the issue, what is being done
--- about it, and what it is reacted with. `cb()` once the issue itself
--- is in, which is what the window is waiting for.
local function fetch(entry, cb)
  local root, iid = entry.subject.root, entry.subject.iid
  glab.issue_get(root, iid, function(data, err)
    if not valid(entry) then
      return
    end
    if not data then
      session.notify(("could not fetch #%d: %s"):format(iid, tostring(err)), vim.log.levels.ERROR)
      if cb then
        cb(false)
      end
      return
    end
    entry.view = M.view(data)
    redraw(entry)
    if cb then
      cb(true)
    end
  end)
  -- Quietly, both: an issue drawn without the merge requests about it or
  -- without its pictures is still the issue.
  glab.issue_related(root, iid, function(data)
    if valid(entry) and type(data) == "table" then
      entry.related = data
      redraw(entry)
    end
  end)
  glab.issue_awards(root, iid, function(data)
    if valid(entry) and type(data) == "table" then
      entry.awards = data
      redraw(entry)
    end
  end)
  glab.me(root, function(who)
    if valid(entry) and who and who.username then
      entry.me = who.username
      entry.subject.me = who.username
      redraw(entry)
    end
  end)
end

--- The issue open in the current tab, or nil.
function M.here()
  local buf = vim.api.nvim_get_current_buf()
  for _, entry in pairs(open) do
    if entry.buf == buf then
      return entry
    end
  end
  -- ...or in the pane beside it, whose keys act on the same issue.
  for _, entry in pairs(open) do
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_buf(w) == entry.buf then
        return entry
      end
    end
  end
  return nil
end

--- Closes the tab, and goes back to the one it was opened from.
local function close(entry)
  local from = entry.from
  open[key(entry.subject.root, entry.subject.iid)] = nil
  local tab = nil
  for _, w in ipairs(vim.fn.win_findbuf(entry.buf or -1)) do
    tab = vim.api.nvim_win_get_tabpage(w)
  end
  if tab and #vim.api.nvim_list_tabpages() > 1 then
    -- Every window of it: the pane beside the issue and a composer
    -- under it are the issue's, and a tab left behind holding them is a
    -- tab of nothing.
    vim.cmd(("tabclose %d"):format(vim.api.nvim_tabpage_get_number(tab)))
  elseif valid(entry) then
    -- The only tab there is: the buffer goes, and the window is left on
    -- an empty one rather than closing the editor.
    vim.cmd("enew")
  end
  if valid(entry) then
    vim.api.nvim_buf_delete(entry.buf, { force = true })
  end
  if from and vim.api.nvim_tabpage_is_valid(from) then
    vim.api.nvim_set_current_tabpage(from)
  end
end

--- A new title, asked for over the one it has.
function M.retitle(entry)
  entry = entry or M.here()
  if not (entry and entry.view) then
    return
  end
  vim.ui.input({ prompt = "title: ", default = entry.view.title }, function(text)
    if text == nil then
      return
    end
    text = vim.trim(text)
    if text == "" then
      session.notify("an issue has to have a title", vim.log.levels.WARN)
      return
    end
    if text == entry.view.title then
      session.notify("unchanged")
      return
    end
    glab.issue_update(entry.subject.root, entry.subject.iid, { title = text }, function(data, err)
      if not data then
        session.notify("could not change the title: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      took(entry, data)
      session.notify("retitled")
    end)
  end)
end

--- The description rewritten in the composer, under the issue. Sent,
--- as the merge request's is: there is no unsent edit of one.
function M.describe(entry)
  entry = entry or M.here()
  if not (entry and entry.view) then
    return
  end
  local was = vim.trim(entry.view.description or "")
  require("nemeton.compose").open({
    title = ("#%d  description"):format(entry.view.iid),
    body = entry.view.description or "",
    empty = true,
    on_submit = function(body)
      if body == was then
        session.notify("unchanged")
        return
      end
      glab.issue_update(
        entry.subject.root,
        entry.subject.iid,
        { description = body },
        function(data, err)
          if not data then
            session.notify(
              "could not change the description: " .. tostring(err),
              vim.log.levels.ERROR
            )
            return
          end
          took(entry, data)
          session.notify("description changed")
        end
      )
    end,
  })
end

--- Closes it, or reopens it where it is closed -- after asking, as the
--- merge request's does: a close is a message to everybody watching.
function M.close_or_reopen(entry)
  entry = entry or M.here()
  if not (entry and entry.view) then
    return
  end
  local event = entry.view.state == "closed" and "reopen" or "close"
  local verb = event == "close" and "Close" or "Reopen"
  require("nemeton.edit").confirm(
    ("%s #%d: %s"):format(verb, entry.view.iid, entry.view.title),
    function(yes)
      if not yes then
        return
      end
      glab.issue_update(
        entry.subject.root,
        entry.subject.iid,
        { state_event = event },
        function(data, err)
          if not data then
            session.notify(("could not %s: %s"):format(event, tostring(err)), vim.log.levels.ERROR)
            return
          end
          took(entry, data)
          session.notify(
            ("%s #%d"):format(event == "close" and "closed" or "reopened", entry.view.iid)
          )
        end
      )
    end,
    verb
  )
end

--- A set picked out of `names` one at a time: each choice ticks a name
--- or takes the tick off, and the list comes back with it moved until
--- it is dismissed -- the create window's labels, and for the same
--- reason: any `vim.ui.select` can be a picker that comes back, and few
--- are one that returns a set. `done(set)` once, when it is dismissed,
--- with what is ticked then, so that four labels changed are one call
--- to the forge rather than four.
---
--- `shown(name)` is how a name is drawn in the list, where that is not
--- itself.
function M.pick_set(title, names, chosen, shown, done)
  local on = {}
  for _, n in ipairs(chosen) do
    on[n] = true
  end
  local function ask()
    local items, picked = {}, {}
    for _, n in ipairs(names) do
      table.insert(items, (on[n] and "✓ " or "  ") .. (shown and shown(n) or n))
      if on[n] then
        table.insert(picked, n)
      end
    end
    vim.ui.select(items, {
      prompt = #picked > 0 and (title .. " · " .. table.concat(picked, ", ")) or title,
    }, function(choice, index)
      if not choice then
        local set = {}
        for _, n in ipairs(names) do
          if on[n] then
            table.insert(set, n)
          end
        end
        -- ...and the ones it had that are not in the list at all -- a
        -- label deleted from the project since -- kept, since nobody
        -- unticked them.
        for _, n in ipairs(chosen) do
          if on[n] and not vim.tbl_contains(set, n) then
            table.insert(set, n)
          end
        end
        done(set)
        return
      end
      local n = names[index]
      on[n] = not on[n] or nil
      -- On the next tick, so the picker closing is closed before the
      -- next one opens.
      vim.schedule(ask)
    end)
  end
  ask()
end

--- Whether two lists hold the same names, whatever their order.
local function same(a, b)
  if #a ~= #b then
    return false
  end
  local seen = {}
  for _, x in ipairs(a) do
    seen[x] = true
  end
  for _, x in ipairs(b) do
    if not seen[x] then
      return false
    end
  end
  return true
end

--- Its labels, ticked on and off out of the project's.
function M.labels(entry)
  entry = entry or M.here()
  if not (entry and entry.view) then
    return
  end
  local had = vim.tbl_map(function(l)
    return l.title
  end, entry.view.labels)
  glab.labels(entry.subject.root, function(data, err)
    if type(data) ~= "table" then
      session.notify(
        "could not ask which labels this project has: " .. tostring(err),
        vim.log.levels.ERROR
      )
      return
    end
    local names = {}
    for _, l in ipairs(data) do
      if l.name then
        table.insert(names, l.name)
      end
    end
    M.pick_set("labels", names, had, nil, function(set)
      if same(set, had) then
        return
      end
      glab.issue_update(entry.subject.root, entry.subject.iid, { labels = set }, function(got, why)
        if not got then
          session.notify("could not change the labels: " .. tostring(why), vim.log.levels.ERROR)
          return
        end
        -- What came back names the labels and not their colours, and
        -- the window draws them in theirs: the forge is asked again.
        took(entry, got)
        M.refresh(entry)
        session.notify("labels changed")
      end)
    end)
  end)
end

--- Who it is assigned to, ticked on and off out of the project's
--- members.
function M.assignees(entry)
  entry = entry or M.here()
  if not (entry and entry.view) then
    return
  end
  local had = vim.list_slice(entry.view.assignees)
  glab.project_users(entry.subject.root, function(data, err)
    if type(data) ~= "table" then
      session.notify(
        "could not ask who is on this project: " .. tostring(err),
        vim.log.levels.ERROR
      )
      return
    end
    local names, ids, full = {}, {}, {}
    for _, u in ipairs(data) do
      if u.username then
        table.insert(names, u.username)
        ids[u.username] = u.id
        full[u.username] = u.name
      end
    end
    local function shown(n)
      return full[n] and full[n] ~= n and ("%s  %s"):format(n, full[n]) or n
    end
    M.pick_set("assignees", names, had, shown, function(set)
      if same(set, had) then
        return
      end
      local list = {}
      for _, n in ipairs(set) do
        if ids[n] then
          table.insert(list, ids[n])
        end
      end
      glab.issue_update(
        entry.subject.root,
        entry.subject.iid,
        { assignee_ids = list },
        function(got, why)
          if not got then
            session.notify(
              "could not change who it is assigned to: " .. tostring(why),
              vim.log.levels.ERROR
            )
            return
          end
          took(entry, got)
          session.notify(#list > 0 and "assigned" or "unassigned")
        end
      )
    end)
  end)
end

--- The keys, on the issue's buffer.
local function bind(entry)
  local k = config.keys.issue
  local bindings = {
    {
      k.comments,
      function()
        require("nemeton.issue_comments").toggle(entry)
      end,
      "what has been said under it, in a pane beside it",
    },
    {
      k.describe,
      function()
        M.describe(entry)
      end,
      "rewrite its description",
    },
    {
      k.retitle,
      function()
        M.retitle(entry)
      end,
      "give it a new title",
    },
    {
      k.labels,
      function()
        M.labels(entry)
      end,
      "its labels, ticked on and off",
    },
    {
      k.assignees,
      function()
        M.assignees(entry)
      end,
      "who it is assigned to",
    },
    {
      k.close,
      function()
        M.close_or_reopen(entry)
      end,
      "close it, or reopen it, after asking",
    },
    {
      k.browser,
      function()
        if entry.view and entry.view.web_url then
          follow.browse(entry.view.web_url)
        end
      end,
      "open it on GitLab",
    },
    {
      k.refresh,
      function()
        M.refresh(entry)
      end,
      "refetch",
    },
    {
      k.quit,
      function()
        close(entry)
      end,
      "close the tab",
    },
  }
  detail.bind(entry.buf, bindings, k.help, (" #%d "):format(entry.subject.iid))
end

--- Asks the forge again, and puts what it says into the window and the
--- cache both.
function M.refresh(entry, cb)
  entry = entry or M.here()
  if not entry then
    return
  end
  fetch(entry, cb)
  local comments = require("nemeton.issue_comments")
  if comments.is_open(entry) then
    comments.refresh(entry)
  end
  require("nemeton.issue_cache").refresh_one(entry.subject.root, entry.subject.iid)
end

--- Opens issue `iid` of the project in `root`'s checkout, in a tab, or
--- goes to the tab it is already open in. `cb(entry)` once it is drawn
--- from something.
function M.open(iid, cb)
  iid = tonumber(iid)
  local root = session.root()
  if not root then
    session.notify("not inside a git repository", vim.log.levels.ERROR)
    return
  end
  if not iid then
    return require("nemeton").ask_issue()
  end
  local entry = open[key(root, iid)]
  if valid(entry) then
    local w = vim.fn.win_findbuf(entry.buf)[1]
    if w then
      vim.api.nvim_set_current_win(w)
    end
    M.refresh(entry)
    if cb then
      cb(entry)
    end
    return
  end

  local from = vim.api.nvim_get_current_tabpage()
  vim.cmd("tabnew")
  local placeholder = vim.api.nvim_get_current_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "markdown"
  pcall(vim.api.nvim_buf_set_name, buf, ("nemeton://issue/%d"):format(iid))
  vim.api.nvim_win_set_buf(0, buf)
  if placeholder ~= buf and vim.api.nvim_buf_is_valid(placeholder) then
    pcall(vim.api.nvim_buf_delete, placeholder, { force = true })
  end
  local w = vim.api.nvim_get_current_win()
  vim.wo[w].wrap = true
  vim.wo[w].linebreak = true
  vim.wo[w].number = false
  vim.wo[w].relativenumber = false
  vim.wo[w].signcolumn = "no"
  vim.wo[w].list = false

  entry = {
    buf = buf,
    from = from,
    subject = {
      kind = "issue",
      root = root,
      iid = iid,
      label = ("#%d"):format(iid),
      noteable = ("issues/%d"):format(iid),
      -- GitLab keeps no unsent comments on an issue: a comment written
      -- here is posted.
      drafts = false,
    },
  }
  -- What a reply, an edit or a reaction written in the pane does once
  -- it lands: the pane asks the forge again. Nothing is drawn while it
  -- is on its way -- that is the review's drawing, and without this a
  -- reply to an issue would be drawn into whatever review is open.
  entry.subject.refetch = function(after)
    require("nemeton.issue_comments").refresh(entry, after)
  end
  entry.subject.show_sending = function()
    return function() end
  end
  open[key(root, iid)] = entry
  bind(entry)
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      if open[key(root, iid)] == entry then
        open[key(root, iid)] = nil
      end
    end,
  })

  -- What the cache has, on the keypress; the forge's answer over it.
  local kept = require("nemeton.issue_cache").peek(root)
  local record = kept and kept.issues[iid]
  if record then
    entry.view = M.view(record)
    redraw(entry)
  else
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { ("fetching #%d…"):format(iid) })
    vim.bo[buf].modifiable = false
    vim.wo[w].winbar = hint(entry)
  end
  glab.project(root, function(project)
    if project and valid(entry) then
      entry.subject.target_branch = project.default_branch
      pcall(
        vim.api.nvim_buf_set_name,
        buf,
        ("nemeton://issue/%s/%d"):format(project.path_with_namespace or "", iid)
      )
    end
  end)
  -- ...and what has been said under it, beside it, unless that has been
  -- asked not to: an issue is read with its conversation, which is most
  -- of what an issue is. The cursor stays on the issue.
  if config.issues.comments then
    require("nemeton.issue_comments").open(entry)
    vim.api.nvim_set_current_win(w)
  end
  fetch(entry, function()
    if cb then
      cb(entry)
    end
  end)
  require("nemeton.issue_cache").refresh_one(root, iid)
  return entry
end

--- Every issue open, for `:checkhealth` and the suite.
function M.all()
  return open
end

return M
