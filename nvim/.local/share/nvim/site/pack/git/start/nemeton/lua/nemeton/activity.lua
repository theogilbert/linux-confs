-- Everything that has happened to the merge request, newest first:
-- comments and replies, comments rewritten, pushes, the description
-- and the title changed, labels, approvals, reviewers, closes and
-- reopens.
--
-- The question it answers is "what changed since I last looked", and
-- the forge keeps the answer in four places. Most of it is in the
-- discussions the review already has: a push, a description changed,
-- an approval are *system notes* there, which the threads leave out
-- because nobody said them. Labels and the state are not -- GitLab
-- moved both out into resource events years ago and draws them back in
-- on the page -- and a rewritten comment is only told from one that
-- was resolved or moved by a push by GraphQL's `lastEditedBy`: REST
-- has no field for it, and `updated_at` moves on all three.
--
-- `M.events` and `M.lines` are pure, as `threads.lua` is.

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
-- Line number (1-based) -> the event drawn on it.
local rows = {}

local function who(user)
  return type(user) == "table" and (user.username or user.name) or "?"
end

--- The first line of a body, with a link written as its words: what
--- a row says of a comment is the start of it, and a system note's
--- links are to pages of the forge this window has its own keys for.
local function gist(body)
  local line = vim.split(vim.trim(body or ""), "\n", { plain = true })[1] or ""
  return (line:gsub("%[([^%]]*)%]%b()", "%1"))
end

--- The commits a push note lists, as `{ sha, title }`. GitLab writes
--- them as an HTML list inside the markdown -- `<li>8b491fe5 - tmp</li>`
--- -- and the page renders it; here it is taken apart.
local function pushed(body)
  local out = {}
  for item in (body or ""):gmatch("<li>(.-)</li>") do
    local sha, title = item:match("^(%x+)%s+%-%s+(.*)$")
    if sha then
      table.insert(out, { sha = sha, title = vim.trim(title) })
    end
  end
  return out
end

--- A system note that only repeats another one: GitLab adds one of
--- these to every thread whose line a push touched, beside the push
--- note that says the same thing once.
local function echo(body)
  return (body or ""):match("^changed this line in ") ~= nil
end

--- Everything, newest first, as records:
--- `{ at, who, verb, text?, path?, line?, thread?, note?, commits? }`.
---
--- `discussions` is the REST payload whole, system notes and all;
--- `extra` is what `glab.mr_activity` answers -- `labels` and `states`,
--- the two lists of resource events, and `edits`, note id to
--- `{ at, by }`. Any of them missing is that much less said, not an
--- error: the discussions alone are most of it.
function M.events(discussions, extra)
  extra = extra or {}
  local edits = extra.edits or {}
  local out = {}
  for _, d in ipairs(discussions or {}) do
    local first = (d.notes or {})[1]
    local place = first and first.position
    local path = place and (place.new_path or place.old_path)
    local line = place and (place.new_line or place.old_line)
    local said = 0
    for _, note in ipairs(d.notes or {}) do
      if note.system then
        if not echo(note.body) then
          local commits = pushed(note.body)
          table.insert(out, {
            at = note.created_at,
            who = who(note.author),
            verb = gist(note.body),
            commits = #commits > 0 and commits or nil,
            note = note.id,
          })
        end
      else
        said = said + 1
        local event = {
          at = note.created_at,
          who = who(note.author),
          verb = said > 1 and "replied" or "commented",
          text = gist(note.body),
          path = path,
          line = line,
          thread = d.id,
          note = note.id,
        }
        table.insert(out, event)
        local edit = edits[note.id]
        if edit then
          table.insert(
            out,
            vim.tbl_extend("force", event, {
              at = edit.at,
              who = edit.by or event.who,
              verb = edit.by and edit.by ~= event.who and ("edited %s's comment"):format(event.who)
                or "edited a comment",
            })
          )
        end
      end
    end
  end
  for _, e in ipairs(extra.labels or {}) do
    local name = type(e.label) == "table" and e.label.name or "?"
    table.insert(out, {
      at = e.created_at,
      who = who(e.user),
      verb = (e.action == "remove" and "removed ~%s" or "added ~%s"):format(name),
    })
  end
  for _, e in ipairs(extra.states or {}) do
    table.insert(out, { at = e.created_at, who = who(e.user), verb = e.state or "?" })
  end
  -- ISO timestamps in one zone sort as strings; a tie keeps the order
  -- they were found in, so a reply never lands above its comment.
  for i, e in ipairs(out) do
    e.order = i
  end
  table.sort(out, function(a, b)
    if (a.at or "") ~= (b.at or "") then
      return (a.at or "") > (b.at or "")
    end
    return a.order > b.order
  end)
  return out
end

--- The events as lines and highlights, and the event on each line.
--- `now` is for the suite, as `threads.age`'s is.
function M.lines(events, now)
  local rendered, map = {}, {}
  if #events == 0 then
    return { "nothing has happened yet" }, {}, {}
  end
  local width = 0
  for _, e in ipairs(events) do
    width = math.max(width, vim.fn.strdisplaywidth(e.who))
  end
  for _, e in ipairs(events) do
    local age = threads.age(e.at, now) or ""
    local head = {
      { ("%6s  "):format(age), "NemetonMeta" },
      { e.who .. (" "):rep(width - vim.fn.strdisplaywidth(e.who) + 2), "NemetonAuthor" },
      { e.verb },
    }
    if e.path then
      table.insert(head, { (" on %s:%s"):format(e.path, e.line or "?"), "NemetonMeta" })
    end
    table.insert(rendered, head)
    map[#rendered] = e
    local indent = (" "):rep(8 + width + 2)
    if e.text and e.text ~= "" then
      table.insert(rendered, { { indent .. e.text, "NemetonHint" } })
      map[#rendered] = e
    end
    for _, c in ipairs(e.commits or {}) do
      table.insert(rendered, {
        { indent .. c.sha:sub(1, 8) .. " ", "NemetonMeta" },
        { c.title },
      })
      map[#rendered] = e
    end
  end
  local lines, hls = threads.flatten(rendered, 0)
  return lines, hls, map
end

local function event_at()
  if not (M.win and vim.api.nvim_win_is_valid(M.win)) then
    return nil
  end
  return rows[vim.api.nvim_win_get_cursor(M.win)[1]]
end

function M.close()
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    vim.api.nvim_win_close(M.win, true)
  end
  M.win, M.buf, rows = nil, nil, {}
end

local function draw(events)
  local lines, hls, map = M.lines(events)
  rows = map
  vim.bo[M.buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.bo[M.buf].modifiable = false
  marks.paint(M.buf, hls)
end

--- The thread an event is about, as the review has it now.
local function thread_of(mr, id)
  for _, list in ipairs({ mr.inline or {}, mr.overview or {} }) do
    for _, t in ipairs(list) do
      if t.id == id then
        return t
      end
    end
  end
  return nil
end

--- The activity of the open merge request, in a float. `back` is
--- where `q` goes, as for `nemeton.jobs`.
function M.open(back)
  local mr = session.current
  if not mr then
    session.notify("no merge request open — :Nemeton to pick one", vim.log.levels.WARN)
    return
  end
  M.close()
  local width = math.min(math.floor(vim.o.columns * 0.8), 110)
  local height = math.max(4, math.floor(vim.o.lines * 0.6))
  M.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[M.buf].bufhidden = "wipe"
  back = back or win.came_from()
  M.win = vim.api.nvim_open_win(M.buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = (" !%d activity "):format(mr.iid),
    title_pos = "center",
  })
  vim.wo[M.win].cursorline = true
  vim.wo[M.win].wrap = false

  local k = config.keys.activity
  vim.wo[M.win].winbar = detail.hint({ { k.code, "go to it" } }, k.help)

  -- The review refetched first, so the comments in here are the ones
  -- the forge has now -- and the review drawn with them -- and the rest
  -- asked for beside it. Drawn once both are in: a list that grows a
  -- label change at the top a second after it opened is a list whose
  -- top line moved under the cursor.
  local function load()
    local mine = M.buf
    local extra, refreshed = nil, false
    local function ready()
      if not (extra and refreshed) or M.buf ~= mine or not vim.api.nvim_buf_is_valid(mine) then
        return
      end
      draw(M.events(mr.raw.discussions, extra))
    end
    session.refresh(function()
      refreshed = true
      ready()
    end)
    glab.mr_activity(mr.root, mr.iid, function(data)
      extra = data
      ready()
    end)
  end

  local bindings = {
    {
      k.quit,
      function()
        M.close()
        back()
      end,
      "close",
    },
    -- A comment is gone to as the comments window goes to one: beside
    -- the code for a thread on a line, in the pane for one on none.
    {
      k.code,
      function()
        local e = event_at()
        local thread = e and e.thread and thread_of(mr, e.thread)
        if not thread then
          return
        end
        if thread.path and thread.line then
          M.close()
          back()
          session.goto_thread(thread)
          return
        end
        M.close()
        back()
        require("nemeton.pane").read(thread)
      end,
      "go to the comment under the cursor",
    },
    {
      k.browser,
      function()
        local e = event_at()
        local url = mr.web_url
        if url and e and e.note then
          url = ("%s#note_%d"):format(url, e.note)
        end
        if url then
          follow.browse(url)
        end
      end,
      "open it on GitLab",
    },
    { k.refresh, load, "refetch" },
  }
  detail.bind(M.buf, bindings, k.help, " activity ")

  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, { "…" })
  vim.bo[M.buf].modifiable = false
  load()
  return M.win
end

return M
