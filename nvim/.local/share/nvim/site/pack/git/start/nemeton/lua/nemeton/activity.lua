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
local markdown = require("nemeton.markdown")
local marks = require("nemeton.marks")
local session = require("nemeton.session")
local threads = require("nemeton.threads")
local hover = require("nemeton.who")
local win = require("nemeton.win")

local M = {}

M.win = nil
M.buf = nil
-- Line number (1-based) -> the event drawn on it.
local rows = {}

local function who(user)
  return type(user) == "table" and (user.username or user.name) or "?"
end

--- The first line of a body, as it was written: what a row says of a
--- comment is the start of it. The links in it are drawn as their words
--- by `M.lines`, which keeps where each one goes for `<C-]>`.
local function gist(body)
  return vim.split(vim.trim(body or ""), "\n", { plain = true })[1] or ""
end

--- `text` as the chunks it is drawn in: a link as its words, a sha or
--- a `!12` in their colours, each carrying what it points at -- the
--- same reading a comment gets in every other window, so that a row of
--- this one is followed the way a note is. `hl` is for the rest.
local function chunks_of(text, hl)
  local drawn, runs = markdown.inline(text)
  if not runs then
    return { { drawn, hl } }
  end
  local out = {}
  for _, run in ipairs(runs) do
    table.insert(out, { run[1], run[2] or hl, ref = run.ref, style = run.style })
  end
  return out
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
            body = note.body,
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
          body = note.body,
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

--- The events as lines and highlights, the event on each line, and
--- what the links, shas and references on them point at, as
--- `threads.flatten` hands them over. `now` is for the suite, as
--- `threads.age`'s is.
function M.lines(events, now)
  local rendered, map = {}, {}
  if #events == 0 then
    return { "nothing has happened yet" }, {}, {}, {}
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
    }
    vim.list_extend(head, chunks_of(e.verb))
    if e.path then
      table.insert(head, { (" on %s:%s"):format(e.path, e.line or "?"), "NemetonMeta" })
    end
    table.insert(rendered, head)
    map[#rendered] = e
    local indent = (" "):rep(8 + width + 2)
    if e.text and e.text ~= "" then
      table.insert(rendered, vim.list_extend({ { indent } }, chunks_of(e.text, "NemetonHint")))
      map[#rendered] = e
    end
    -- The sha a link to the commit, followed as one written in a
    -- comment is: `comments.follow.commit` decides what that does.
    for _, c in ipairs(e.commits or {}) do
      local row = {
        { indent },
        {
          c.sha:sub(1, 8),
          "NemetonCommit",
          ref = { kind = "commit", text = c.sha, sha = c.sha },
        },
        { " " },
      }
      vim.list_extend(row, chunks_of(c.title))
      table.insert(rendered, row)
      map[#rendered] = e
    end
  end
  local lines, hls, refs = threads.flatten(rendered, 0)
  return lines, hls, map, refs
end

--- One event whole, for `K`: who and what, to the second, where, and
--- everything that was said rather than its first line -- or, for a
--- push, every commit it brought. Pure, as `M.lines` is.
function M.detail(e)
  local rendered = {}
  table.insert(
    rendered,
    vim.list_extend({ { e.who, "NemetonAuthor" }, { " " } }, chunks_of(e.verb))
  )
  local when = threads.when(threads.epoch(e.at))
  if when then
    table.insert(rendered, { { when, "NemetonMeta" } })
  end
  if e.path then
    table.insert(rendered, { { ("on %s:%s"):format(e.path, e.line or "?"), "NemetonMeta" } })
  end
  local body = {}
  if e.commits then
    for _, c in ipairs(e.commits) do
      table.insert(
        body,
        vim.list_extend({ { c.sha:sub(1, 8), "NemetonCommit" }, { " " } }, chunks_of(c.title))
      )
    end
  else
    local said = vim.split(vim.trim(e.body or ""), "\n", { plain = true })
    -- A system note's first line is the verb already drawn above.
    for i = e.thread and 1 or 2, #said do
      table.insert(body, chunks_of(said[i]))
    end
  end
  if #body > 0 then
    table.insert(rendered, { { "" } })
    vim.list_extend(rendered, body)
  end
  local lines, hls = threads.flatten(rendered, 0)
  return lines, hls
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
  local lines, hls, map, refs = M.lines(events)
  rows = map
  follow.set(M.buf, refs, M.close)
  vim.bo[M.buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.bo[M.buf].modifiable = false
  marks.paint(M.buf, hls)
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
  vim.wo[M.win].winbar = detail.hint({ { k.browser, "on GitLab" } }, k.help)

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
    { k.follow, follow.here, "follow the link, sha or reference under the cursor" },
    -- The commit or the address under the cursor where there is one,
    -- as in a comment; the event whole anywhere else on its rows.
    {
      k.who,
      function()
        local pos = vim.api.nvim_win_get_cursor(M.win)
        if follow.under(M.buf, pos[1] - 1, pos[2]) and hover.show(false) then
          return
        end
        local e = event_at()
        if e then
          local lines, hls = M.detail(e)
          hover.popup(e, lines, hls)
        end
      end,
      "the event under the cursor whole, or the commit or link",
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
