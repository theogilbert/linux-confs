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

--- A title change, as `{ old, new }`, each a list of `{ text, changed }`
--- pieces, or nil for a note that is not one. GitLab writes the change
--- into the note as HTML -- `changed title from <code
--- class="idiff">a<span class="idiff … deletion">b</span></code> to
--- …` -- and draws the spans as the words that went and came; an older
--- one wrote it as markdown, `**{-b-}**` and `**{+c+}**`.
local function retitled(body)
  body = body or ""
  local old, new = body:match("changed title from <code[^>]*>(.-)</code> to <code[^>]*>(.-)</code>")
  local open, close = "<span[^>]*>", "</span>"
  if not old then
    old, new = body:match("changed title from %*%*(.-)%*%* to %*%*(.-)%*%*%s*$")
    open, close = "{[-+]", "[-+]}"
  end
  if not old then
    return nil
  end
  local function pieces(text)
    local out, at = {}, 1
    while at <= #text do
      local from, to = text:find(open, at)
      local stop, last
      if from then
        stop, last = text:find(close, to + 1)
      end
      if not stop then
        table.insert(out, { markdown.unescaped(text:sub(at)) })
        break
      end
      if from > at then
        table.insert(out, { markdown.unescaped(text:sub(at, from - 1)) })
      end
      table.insert(out, { markdown.unescaped(text:sub(to + 1, stop - 1)), true })
      at = last + 1
    end
    return out
  end
  return { old = pieces(old), new = pieces(new) }
end

--- The pieces as the words they come to.
local function worded(pieces)
  return table.concat(vim.tbl_map(function(p)
    return p[1]
  end, pieces))
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
--- the two lists of resource events, `edits`, note id to `{ at, by }`,
--- and `descriptions`, note id to the description that change left.
--- Any of them missing is that much less said, not an error: the
--- discussions alone are most of it.
function M.events(discussions, extra)
  extra = extra or {}
  local edits = extra.edits or {}
  local descriptions = extra.descriptions or {}
  local out, described = {}, {}
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
          local title = retitled(note.body)
          local event = {
            at = note.created_at,
            who = who(note.author),
            verb = title
                and ("changed title from %s to %s"):format(worded(title.old), worded(title.new))
              or gist(note.body),
            body = note.body,
            commits = #commits > 0 and commits or nil,
            title = title,
            description = descriptions[note.id],
            note = note.id,
          }
          table.insert(out, event)
          if event.description then
            table.insert(described, event)
          end
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
  -- What each change of the description changed it from: the one
  -- before it. The first has nothing before it to say -- the forge
  -- keeps a version for every change and none for what the merge
  -- request was opened with.
  table.sort(described, function(a, b)
    return (a.at or "") < (b.at or "")
  end)
  for i = 2, #described do
    described[i].before = described[i - 1].description
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
--- `threads.flatten` hands them over, and the column what an event
--- says starts at. `now` is for the suite, as `threads.age`'s is.
function M.lines(events, now)
  local rendered, map = {}, {}
  if #events == 0 then
    return { "nothing has happened yet" }, {}, {}, {}, 0
  end
  local width = 0
  for _, e in ipairs(events) do
    width = math.max(width, vim.fn.strdisplaywidth(e.who))
  end
  for _, e in ipairs(events) do
    local age = threads.age(e.at, now) or ""
    local head = {
      -- `K` on it says when to the second, as on a note's head.
      { (" "):rep(6 - vim.fn.strdisplaywidth(age)) },
      { age, "NemetonMeta", ref = { kind = "stamp", written = e.at } },
      { "  " },
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
  return lines, hls, map, refs, 8 + width + 2
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
  if e.title then
    -- The words that went and the words that came, in the colours of
    -- a diff; the rest of the title in the colour of what stayed.
    for _, side in ipairs({
      { "- ", e.title.old, "NemetonRemoved" },
      { "+ ", e.title.new, "NemetonAdded" },
    }) do
      local row = { { side[1], side[3] } }
      for _, p in ipairs(side[2]) do
        table.insert(row, { p[1], p[2] and side[3] or nil })
      end
      table.insert(body, row)
    end
  elseif e.description then
    vim.list_extend(body, M.changed(e.before, e.description))
  elseif e.commits then
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

--- What a change of the description did, as rows of chunks: a diff of
--- the source against the version before, or -- for the first change,
--- which has none -- what it said afterwards. The source and not the
--- page: a diff is about what was typed.
function M.changed(before, after)
  local out = {}
  if not before then
    table.insert(out, { { "it now says:", "NemetonMeta" } })
    for _, line in ipairs(vim.split(after, "\n", { plain = true })) do
      table.insert(out, { { line } })
    end
    return out
  end
  local diff = (vim.text and vim.text.diff or vim.diff)(before .. "\n", after .. "\n", {
    ctxlen = 2,
  })
  local colour = { ["+"] = "NemetonAdded", ["-"] = "NemetonRemoved", ["@"] = "NemetonMeta" }
  for _, line in ipairs(vim.split(vim.trim(diff or ""), "\n", { plain = true })) do
    if line ~= "" and line ~= "\\ No newline at end of file" then
      table.insert(out, { { line, colour[line:sub(1, 1)] } })
    end
  end
  if #out == 0 then
    table.insert(out, { { "the same words as before", "NemetonMeta" } })
  end
  return out
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
  local lines, hls, map, refs, column = M.lines(events)
  rows = map
  -- Wrapped by the window rather than by the lines: a row stays the
  -- one event the keys act on, and what runs past the edge goes on
  -- under where it started -- under the verb, past the ages and the
  -- names, which are the column the eye runs down.
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    vim.wo[M.win].breakindentopt = "column:" .. column
  end
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
  vim.wo[M.win].wrap = true
  vim.wo[M.win].linebreak = true
  vim.wo[M.win].breakindent = true

  local k = config.keys.activity
  vim.wo[M.win].winbar = detail.hint({ { k.browser, "on GitLab" } }, k.help)

  -- The review refetched first, so the comments in here are the ones
  -- the forge has now -- and the review drawn with them -- and the rest
  -- asked for beside it. Drawn once both are in: a list that grows a
  -- label change at the top a second after it opened is a list whose
  -- top line moved under the cursor.
  local function load()
    local mine = M.buf
    local spin = require("nemeton.spin")
    local done = spin.busy(mine)
    local extra
    local ready = spin.after(2, function()
      done()
      if not extra or M.buf ~= mine or not vim.api.nvim_buf_is_valid(mine) then
        return
      end
      draw(M.events(mr.raw.discussions, extra))
    end)
    session.refresh(ready)
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
    -- as in a comment, and the time to the second on the age; the
    -- event whole anywhere else on its rows.
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
      "the event under the cursor whole, or the commit, link or time",
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
