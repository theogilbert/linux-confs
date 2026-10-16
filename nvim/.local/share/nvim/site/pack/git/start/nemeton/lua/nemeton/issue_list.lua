-- The project's issues, in a float, searched as you type.
--
-- The merge request queue's window in what it looks like and in the
-- keys it answers to -- `<CR>`, `d`, `s`, `o`, `r`, `q`, `g?` -- and
-- not in where its rows come from: these are the cache's
-- (`nemeton.issue_cache`), every issue of the project, so the window is
-- up and full on the keypress and `/` narrows it on every key typed
-- rather than on a round trip. The forge is asked behind it, and what
-- has changed is drawn when it answers.
--
-- A row says why it is there. The description and the comments are
-- not on the screen, so an issue found by what somebody said under it
-- would be a row nobody can account for: a line under such a row says
-- where the word was and quotes the line it was in, the word picked
-- out.

local config = require("nemeton.config")
local detail = require("nemeton.detail")
local follow = require("nemeton.follow")
local glab = require("nemeton.glab")
local issue = require("nemeton.issue")
local issues = require("nemeton.issues")
local cache = require("nemeton.issue_cache")
local marks = require("nemeton.marks")
local session = require("nemeton.session")
local threads = require("nemeton.threads")
local win = require("nemeton.win")

local M = {}

M.win = nil
M.buf = nil
M.preview = { win = nil, buf = nil }

-- Line (1-based) -> the issue drawn on it. Both lines of a row that
-- has a second one are the row's.
local rows = {}
-- What is on the screen: the search typed, the state the list is of,
-- how many there are in all, and the hits.
local query = ""
local state = nil
local hits = {}
-- The repository the window is of, and whose token this is, for `@me`.
local root = nil
local me = nil
-- How far a first sync has got, while it is going: `{ kept, total }`.
local progress = nil
-- What the window says instead of rows, where it says something.
local message = nil
local back = function() end

local STATES = { "opened", "closed", "all" }

local function listing()
  return state or "opened"
end

local function next_state()
  local now = listing()
  for i, s in ipairs(STATES) do
    if s == now then
      return STATES[i % #STATES + 1]
    end
  end
  return STATES[1]
end

local function valid()
  return M.win ~= nil and vim.api.nvim_win_is_valid(M.win)
end

local function preview_open()
  return M.preview.win ~= nil and vim.api.nvim_win_is_valid(M.preview.win)
end

local function close_preview()
  if preview_open() then
    vim.api.nvim_win_close(M.preview.win, true)
  end
  M.preview = { win = nil, buf = nil }
end

function M.close()
  close_preview()
  if valid() then
    vim.api.nvim_win_close(M.win, true)
  end
  M.win, M.buf, rows, hits, message, state, progress = nil, nil, {}, {}, nil, nil, nil
end

--- Where the list goes, and the pane under it: the queue's geometry, so
--- the two windows sit in the same place on the screen. The list keeps
--- its top edge when the pane opens, and gives up rows from the bottom.
local function geometry(lines)
  local width = math.floor(vim.o.columns * config.list.width)
  local col = math.floor((vim.o.columns - width) / 2)
  local height = math.max(
    2,
    math.min(
      math.floor(vim.o.lines * config.list.height),
      math.max(lines, 1) + 1,
      config.list.rows + 1
    )
  )
  local budget = vim.o.lines - 2
  local wanted = math.max(math.min(config.list.preview_height, budget - 12), 3)
  -- Three rows clear above it, for the search box.
  local row = math.max(math.floor((budget - (height + wanted + 4)) / 2), 4)
  if not preview_open() then
    return { width = width, col = col, height = height, row = row }
  end
  local function below(h)
    return budget - (row + h + 3)
  end
  if below(height) < wanted then
    height = math.max(height - (wanted - below(height)), 2)
  end
  return {
    width = width,
    col = col,
    height = height,
    row = row,
    preview = math.max(math.min(below(height), wanted), 3),
  }
end

--- Where every query word is in `text`, smartcase like the search, for
--- picking them out of a title where the title is why a row is there.
local function spans(text, q)
  local out = {}
  for _, word in ipairs(q.words) do
    local hay, needle = text, word
    if not word:find("%u") then
      hay, needle = text:lower(), word:lower()
    end
    local from = 1
    while true do
      local a, b = hay:find(needle, from, true)
      if not a then
        break
      end
      table.insert(out, { a, b })
      from = b + 1
    end
  end
  table.sort(out, function(x, y)
    return x[1] < y[1]
  end)
  return out
end

--- `text` as chunks in `hl`, with the spans in `NemetonMatch`.
local function marked(text, hl, at)
  local out, from = {}, 1
  for _, s in ipairs(at) do
    if s[1] >= from then
      if s[1] > from then
        table.insert(out, { text:sub(from, s[1] - 1), hl })
      end
      table.insert(out, { text:sub(s[1], s[2]), "NemetonMatch" })
      from = s[2] + 1
    end
  end
  if from <= #text then
    table.insert(out, { text:sub(from), hl })
  end
  return out
end

--- The longest prefix of `s` in `width` columns, whole characters.
local function fit(s, width)
  if vim.fn.strdisplaywidth(s) <= width then
    return s
  end
  local out = ""
  for _, ch in ipairs(vim.fn.split(s, "\\zs")) do
    if vim.fn.strdisplaywidth(out .. ch .. "…") > width then
      break
    end
    out = out .. ch
  end
  return out .. "…"
end

-- How wide the title is. The rest of a row is short and the same width
-- on every row, so the columns after it line up; the labels go last,
-- because they are the one thing on a row of no fixed width.
local TITLE = 52

--- One row, as coloured chunks, and the line under it where there is
--- one.
local function row_chunks(hit, q)
  local i = hit.issue
  local out = { { ("#%-5d "):format(i.iid), "NemetonMeta" } }
  local room = TITLE
  if i.state == "closed" then
    table.insert(out, { "closed ", "NemetonMeta" })
    room = room - 7
  end
  if i.confidential then
    table.insert(out, { "🔒 ", "NemetonBad" })
    room = room - 3
  end
  local title = fit(i.title, room)
  vim.list_extend(out, marked(title, "NemetonThread", spans(title, q)))
  table.insert(out, { (" "):rep(math.max(room - vim.fn.strdisplaywidth(title), 0) + 2) })

  -- Whose it is, and who is on it: the author dim, the first assignee
  -- in the colour people are drawn in, since "who has this" is the
  -- question a list of issues is scanned with.
  local person = i.assignees[1]
  local who
  if person then
    who = { { fit(person == me and "you" or person, 14), "NemetonAuthor" } }
    if #i.assignees > 1 then
      table.insert(who, { ("+%d"):format(#i.assignees - 1), "NemetonMeta" })
    end
  else
    who = { { fit(i.author or "?", 14), "NemetonMeta" } }
  end
  local wide = 0
  for _, c in ipairs(who) do
    wide = wide + vim.fn.strdisplaywidth(c[1])
  end
  vim.list_extend(out, who)
  table.insert(out, { (" "):rep(math.max(17 - wide, 1)) })
  local ago = detail.ago(i.updated_at)
  table.insert(out, { ago, "NemetonMeta" })
  table.insert(out, { (" "):rep(math.max(5 - #ago, 1)) })
  local said = (i.notes_count or 0) > 0 and ("%d💬"):format(i.notes_count) or ""
  table.insert(out, { said, "NemetonMeta" })
  table.insert(out, { (" "):rep(math.max(6 - vim.fn.strdisplaywidth(said), 1)) })
  for n, l in ipairs(i.labels) do
    if n > 1 then
      table.insert(out, { " " })
    end
    vim.list_extend(
      out,
      marked(" " .. l.title .. " ", issue.label_hl(l), spans(" " .. l.title .. " ", q))
    )
  end

  if not hit.why then
    return out, nil
  end
  local ex = hit.why.excerpt
  local under = { { "       " } }
  if hit.why.kind == "comment" then
    table.insert(under, { "comment · ", "NemetonMeta" })
    table.insert(under, { (hit.why.author or "?") .. " · ", "NemetonAuthor" })
  else
    table.insert(under, { "description · ", "NemetonMeta" })
  end
  vim.list_extend(under, marked(ex.text, "NemetonMeta", { { ex.from, ex.to } }))
  return out, under
end

local function set_title()
  if not valid() then
    return
  end
  local parts = { "issues", listing() }
  if query ~= "" then
    table.insert(parts, "/" .. query)
  end
  local kept = root and cache.peek(root)
  local all = kept and vim.tbl_count(kept.issues) or 0
  table.insert(parts, ("%d of %d"):format(#hits, all))
  if progress then
    table.insert(parts, ("syncing %d/%s"):format(progress[1], tostring(progress[2] or "?")))
  elseif root and cache.syncing(root) then
    table.insert(parts, "syncing")
  end
  vim.api.nvim_win_set_config(M.win, {
    title = " " .. table.concat(parts, " · ") .. " ",
    title_pos = "center",
  })
end

local function set_hint()
  if not valid() then
    return
  end
  local k = config.keys.issue_list
  vim.wo[M.win].winbar = detail.hint({
    { k.select, "open" },
    { k.search, "search" },
    { k.description, "description" },
    { k.state, next_state() },
  }, k.help)
end

local function current()
  if not valid() then
    return nil
  end
  return rows[vim.api.nvim_win_get_cursor(M.win)[1]]
end

local function relayout(lines)
  if not valid() then
    return
  end
  local g = geometry(lines)
  vim.api.nvim_win_set_config(M.win, {
    relative = "editor",
    row = g.row,
    col = g.col,
    width = g.width,
    height = g.height,
  })
  if preview_open() then
    local i = current()
    vim.api.nvim_win_set_config(M.preview.win, {
      relative = "editor",
      row = g.row + g.height + 2,
      col = g.col,
      width = g.width,
      height = g.preview,
      title = i and (" #%d · description "):format(i.iid) or " description ",
      title_pos = "center",
    })
  end
  return g
end

local function update_preview()
  if not preview_open() then
    return
  end
  local i = current()
  relayout(vim.api.nvim_buf_line_count(M.buf))
  local lines = { "" }
  if i then
    local body = vim.trim(i.description or "")
    lines = body == "" and { "(no description)" }
      or vim.split(body:gsub("\r\n", "\n"), "\n", { plain = true })
  end
  vim.bo[M.preview.buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.preview.buf, 0, -1, false, lines)
  vim.bo[M.preview.buf].modifiable = false
end

--- Draws the list again from the cache: the search over every issue
--- kept, as it now stands. `keep` is the issue the cursor should stay
--- on, where it is still in the list -- a sync landing must not move
--- the row being read.
local function render(keep)
  if not valid() then
    return
  end
  local kept = root and cache.peek(root)
  local q = issues.parse(query)
  local width = vim.api.nvim_win_get_width(M.win)
  hits = kept
      -- The excerpt's room: the window, less the indent and the
      -- "comment · somebody · " in front of it.
      and issues.search(kept, q, { me = me, state = listing(), width = math.max(width - 28, 24) })
    or {}
  local chunks, map = {}, {}
  for _, hit in ipairs(hits) do
    local line, under = row_chunks(hit, q)
    table.insert(chunks, line)
    map[#chunks] = hit.issue
    if under then
      table.insert(chunks, under)
      map[#chunks] = hit.issue
    end
  end
  if #chunks == 0 then
    local said = message
    if not said then
      if not kept or (not kept.complete and vim.tbl_count(kept.issues) == 0) then
        said = "fetching every issue of the project, the first time…"
      elseif query ~= "" then
        said = "no issue matches"
      else
        said = ("no %s issues"):format(listing())
      end
    end
    chunks = { { { "  " .. said, "NemetonMeta" } } }
  end
  rows = map
  local lines, hls = threads.flatten(chunks, 0)
  vim.bo[M.buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.bo[M.buf].modifiable = false
  marks.paint(M.buf, hls)
  relayout(#lines)
  local row = 1
  if keep then
    for l = 1, #lines do
      if map[l] and map[l].iid == keep then
        row = l
        break
      end
    end
  end
  pcall(vim.api.nvim_win_set_cursor, M.win, { row, 0 })
  set_title()
  set_hint()
  update_preview()
end

--- The cursor's issue, by number, for keeping it across a redraw.
local function here_iid()
  local i = current()
  return i and i.iid or nil
end

--- Brings the cache up to date behind the window, and draws what that
--- changed. `sweep` is `r`: every comment compared, now.
local function sync(sweep)
  cache.sync(root, {
    sweep = sweep,
    progress = function(kept, total)
      progress = { kept, total }
      render(here_iid())
    end,
  }, function(fine, why)
    progress = nil
    if not fine then
      session.notify("could not sync the issues: " .. tostring(why), vim.log.levels.WARN)
    end
    render(here_iid())
  end)
  set_title()
end

--- What the search box completes: the forge's filter words, and after
--- one the values it takes, out of what the cache has. Whole lines, as
--- the prompt wants them -- the line typed so far with the last word
--- finished.
function M.complete(line)
  local lead, word = line:match("^(.-)(%S*)$")
  local negate, key = word:match("^(%-?)(%a+):")
  local kept = root and cache.peek(root)
  local items = {}
  -- Matched against what was typed with any quote it was opened with
  -- taken off, and offered with one where the value needs it.
  local typed = word:gsub('"', ""):lower()
  local function offer(value)
    local bare = negate .. key .. ":" .. value
    if bare:lower():find(typed, 1, true) ~= 1 then
      return
    end
    local full = value:find("%s") and (negate .. key .. ':"' .. value .. '"') or bare
    table.insert(items, { word = lead .. full .. " ", abbr = full })
  end
  if not key then
    if word ~= "" then
      for _, k in ipairs({ "label:", "assignee:", "author:", "state:" }) do
        if k:find(word:gsub("^%-", ""):lower(), 1, true) == 1 then
          local neg = word:sub(1, 1) == "-" and "-" or ""
          table.insert(items, { word = lead .. neg .. k, abbr = neg .. k })
        end
      end
    end
    return items
  end
  key = key:lower()
  local seen = {}
  local function once(v)
    if v and not seen[v] then
      seen[v] = true
      offer(v)
    end
  end
  if key == "state" then
    for _, s in ipairs({ "opened", "closed", "all" }) do
      once(s)
    end
  elseif kept then
    if key == "assignee" then
      once("@me")
      once("none")
    elseif key == "author" then
      once("@me")
    end
    local names = {}
    for _, i in pairs(kept.issues) do
      if key == "label" then
        for _, l in ipairs(i.labels) do
          names[l.title] = true
        end
      elseif key == "assignee" then
        for _, a in ipairs(i.assignees) do
          names[a] = true
        end
      elseif key == "author" and i.author then
        names[i.author] = true
      end
    end
    local sorted = vim.tbl_keys(names)
    table.sort(sorted)
    for _, n in ipairs(sorted) do
      once(n)
    end
  end
  return items
end

--- `/`: the search box over the list, narrowing it as it is typed.
--- `<CR>` keeps what was typed; `<Esc>` puts back what the list showed
--- before, the way vim's own `/` does with `incsearch`.
function M.search()
  if not valid() then
    return
  end
  local before = query
  local g = vim.api.nvim_win_get_config(M.win)
  local row = type(g.row) == "table" and g.row[false] or g.row
  require("nemeton.prompt").open({
    title = "search issues",
    text = query,
    menu = false,
    items = M.complete,
    at = { row = math.max(row - 3, 0), col = g.col, width = g.width },
    on_change = function(text)
      query = vim.trim(text)
      render()
    end,
    on_cancel = function()
      query = before
      render()
    end,
  }, function(answer)
    query = vim.trim(answer or "")
    render()
  end)
end

function M.toggle_preview()
  if preview_open() then
    close_preview()
    render(here_iid())
    return
  end
  M.preview.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[M.preview.buf].bufhidden = "wipe"
  vim.bo[M.preview.buf].modifiable = false
  vim.bo[M.preview.buf].filetype = "markdown"
  M.preview.win = vim.api.nvim_open_win(M.preview.buf, false, {
    relative = "editor",
    row = 1,
    col = 0,
    width = 10,
    height = 3,
    style = "minimal",
    border = "rounded",
    focusable = false,
  })
  vim.wo[M.preview.win].wrap = true
  vim.wo[M.preview.win].linebreak = true
  update_preview()
end

local function bind()
  local k = config.keys.issue_list
  local bindings = {
    {
      k.select,
      function()
        local i = current()
        if not i then
          return
        end
        M.close()
        back()
        issue.open(i.iid)
      end,
      "open it, in a tab",
    },
    { k.search, M.search, "search: words, phrases, label: assignee: author: state:" },
    { k.description, M.toggle_preview, "what it says, under the list" },
    {
      k.state,
      function()
        state = next_state()
        render(here_iid())
      end,
      "open, closed, or all of them",
    },
    {
      k.create,
      function()
        M.close()
        back()
        require("nemeton.issue_create").open()
      end,
      "file one",
    },
    {
      k.browser,
      function()
        local i = current()
        if i and i.web_url then
          follow.browse(i.web_url)
        end
      end,
      "open on GitLab",
    },
    {
      k.refresh,
      function()
        sync(true)
      end,
      "ask the forge what changed, every comment compared",
    },
    {
      k.quit,
      function()
        M.close()
        back()
      end,
      "close the list",
    },
  }
  detail.bind(M.buf, bindings, k.help, " issues ")
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = M.buf,
    callback = update_preview,
  })
  vim.api.nvim_create_autocmd({ "WinClosed", "BufWipeout" }, {
    buffer = M.buf,
    callback = close_preview,
  })
end

--- Opens the list: on what the cache has, at once, and on what the forge
--- says once it has been asked.
function M.open()
  root = session.root()
  if not root then
    session.notify("not inside a git repository", vim.log.levels.ERROR)
    return
  end
  if not glab.available() then
    session.notify("glab is not on your PATH", vim.log.levels.ERROR)
    return
  end
  if valid() then
    vim.api.nvim_set_current_win(M.win)
    return
  end
  back = win.came_from()
  query, state, progress, message = "", nil, nil, nil
  M.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[M.buf].bufhidden = "wipe"
  vim.bo[M.buf].modifiable = false
  local g = geometry(1)
  M.win = vim.api.nvim_open_win(M.buf, true, {
    relative = "editor",
    width = g.width,
    height = g.height,
    row = g.row,
    col = g.col,
    style = "minimal",
    border = "rounded",
    title = " issues ",
    title_pos = "center",
  })
  vim.wo[M.win].cursorline = true
  vim.wo[M.win].wrap = false
  bind()
  render()
  glab.me(root, function(who)
    me = who and who.username or nil
  end)
  cache.get(root, function(_, _, why)
    if why then
      message = "could not read the project: " .. tostring(why)
    end
    render()
    if not why then
      sync(false)
    end
  end)
  return M.win
end

return M
