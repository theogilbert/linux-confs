-- The merge requests waiting on you, in a float.
--
-- A window of our own rather than `vim.ui.select`: a review queue is
-- read as a table -- who, which branch, how many comments already, how
-- stale -- and a picker that renders one line per item throws all of
-- that away to save writing this file once.
--
-- Under it, optionally, a second float: the changelog of whichever row
-- the cursor is on, or what that row says it is for. Which merge
-- request to open is a question about what is *in* them and what they
-- are *for*, and neither answer fits in a row.

local config = require("nemeton.config")
local detail = require("nemeton.detail")
local glab = require("nemeton.glab")
local marks = require("nemeton.marks")
local session = require("nemeton.session")
local threads = require("nemeton.threads")

local M = {}

M.win = nil
M.buf = nil
-- The pane under the list. `mode` is nil when it is closed.
M.preview = { win = nil, buf = nil, mode = nil }
-- Row number (1-based) -> the merge request on it.
local rows = {}
-- Which merge requests the queue is asking for, once it has been asked
-- for something other than the configured state. A review queue is what
-- is open, and that is what this opens on; "how did we end up doing it
-- that way" is a question about one that is merged, and it is asked
-- often enough to deserve a key and rarely enough not to deserve a
-- setting of its own. Reset when the window is closed: the next queue
-- is a queue again.
local state = nil

-- The states, in the order the key walks them. Open first because that
-- is what a review is; "all" last because a queue with everything in it
-- is a history, and the one thing it is bad at is showing what is left
-- to do.
local STATES = { "opened", "merged", "closed", "all" }

--- What is being listed, whether or not the key has been pressed.
local function listing()
  return state or config.list.state or "opened"
end
-- What the window is saying instead of rows: that it is fetching them,
-- that it is opening one, what went wrong when it tried. Its lines,
-- wrapped to the width of the window, or nil while the queue itself is
-- on the screen.
--
-- In the body rather than along the border: a checkout fails in whole
-- sentences -- "the working tree has changes that would be lost by
-- reset, commit, stash or remove them first" -- and a sentence cut off
-- at the width of a border is a sentence you have to go to the log to
-- finish reading. `rows` is left alone underneath it, so the queue
-- comes back on a keypress rather than on a round trip.
local message = nil

local function preview_open()
  return M.preview.win ~= nil and vim.api.nvim_win_is_valid(M.preview.win)
end

local function close_preview()
  if preview_open() then
    vim.api.nvim_win_close(M.preview.win, true)
  end
  M.preview = { win = nil, buf = nil, mode = nil }
end

local function close()
  close_preview()
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    vim.api.nvim_win_close(M.win, true)
  end
  M.win, M.buf, rows, message, state = nil, nil, {}, nil, nil
end

--- The rows, and the highlights to paint on them.
---
--- CI gets a column of its own, one glyph wide, immediately after the
--- number: whether the branch builds is the first thing a reviewer
--- wants off a queue, and it is a fact with a colour -- which is the
--- whole reason this returns highlights rather than only text.
--- One row, as coloured chunks.
---
--- Chunks because half of what a row says is said in colour: whether
--- CI is green, how much of the change is additions, whose it is. The
--- flattening into text and highlights is `threads.flatten`, the same
--- one the conversations go through.
local function row_chunks(mr)
  local ci = detail.ci(mr)
  local stats = mr.diff_stats
  local out = {
    { ("!%-5d "):format(mr.iid), "NemetonMeta" },
    { ci and (ci.glyph .. "  ") or "   ", ci and ci.hl or nil },
  }
  if mr.draft then
    table.insert(out, { "draft ", "NemetonDraft" })
  end
  -- What state it is in, when that is not the state a review queue is
  -- about. Said in words rather than in a colour: a row of a mixed
  -- queue is read to decide whether it is worth opening, and "merged"
  -- is the answer to that, while a green title is a thing to work out.
  -- Nothing at all on an open one -- which is every row of the queue
  -- this opens on, and a column of "opened" is a column saying nothing.
  local mark = (mr.state == "merged" or mr.state == "closed" or mr.state == "locked") and mr.state
    or nil
  if mark then
    table.insert(out, { mark .. " ", mark == "merged" and "NemetonOk" or "NemetonMeta" })
  end
  local title = (mr.title or ""):sub(1, 58)
  local pad = 58
    - vim.fn.strdisplaywidth(title)
    + (mr.draft and -6 or 0)
    + (mark and -(#mark + 1) or 0)
  table.insert(out, { title, "NemetonThread" })
  table.insert(out, { (" "):rep(math.max(pad, 1)) })

  -- The size of the change, in the colours a diff is read in -- as
  -- foreground, not as the filled blocks DiffAdd and DiffDelete paint:
  -- these are two numbers in a table, and a row of coloured tiles is
  -- read as highlighting rather than as a count. Empty until the one
  -- call that counts them for the whole list comes back.
  if stats then
    local added, removed = ("+%d"):format(stats.added), ("−%d"):format(stats.removed)
    table.insert(out, { (" "):rep(math.max(11 - #added - #removed - 1, 1)) })
    table.insert(out, { added, "NemetonAdded" })
    table.insert(out, { " " })
    table.insert(out, { removed, "NemetonRemoved" })
  else
    table.insert(out, { (" "):rep(11) })
  end

  local author = (mr.author and mr.author.username or "?"):sub(1, 14)
  table.insert(out, { " " .. author, "NemetonAuthor" })
  table.insert(out, { (" "):rep(math.max(15 - vim.fn.strdisplaywidth(author), 1)) })
  table.insert(out, { detail.ago(mr.updated_at), "NemetonMeta" })
  if (mr.user_notes_count or 0) > 0 then
    table.insert(out, { ("  %d💬"):format(mr.user_notes_count), "NemetonMeta" })
  end
  -- What you wrote on it and have not sent, in the colour and the glyph
  -- an unsent comment is drawn in everywhere else -- last on the row,
  -- because it is the one thing here that is about you rather than
  -- about the merge request.
  local unsent = #(mr.drafts or {}) + #(mr.draft_overview or {}) + #(mr.draft_replies or {})
  if unsent > 0 then
    table.insert(out, { ("  %d%s"):format(unsent, config.comments.sign_draft), "NemetonDraft" })
  end
  return out
end

local function format(mrs)
  local chunks = {}
  for i, mr in ipairs(mrs) do
    rows[i] = mr
    chunks[i] = row_chunks(mr)
  end
  return threads.flatten(chunks, 0)
end

--- Redraws one row in place, for when its pipeline arrives after the
--- window is already up.
local function redraw_row(i)
  if message or not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) or not rows[i] then
    return
  end
  local line, hls = threads.flatten({ row_chunks(rows[i]) }, i - 1)
  vim.bo[M.buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.buf, i - 1, i, false, line)
  vim.bo[M.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(M.buf, marks.ui_ns, i - 1, i)
  for _, h in ipairs(hls) do
    vim.api.nvim_buf_set_extmark(M.buf, marks.ui_ns, h.row, h.col, {
      end_col = h.end_col,
      hl_group = h.hl,
    })
  end
end

-- iid -> { at = updated_at, stats = ... }, for the life of the editor.
local stats_cache = {}

--- How much each row changes, in one call for the whole list.
---
--- One call, so there is no pool and no ordering to think about: it is
--- either known for every row a moment after the window is up, or not
--- known at all -- on a GitLab whose GraphQL will not answer, the
--- column simply stays empty.
local function fetch_stats(root)
  if not config.list.stats then
    return
  end
  local wanted, at_row = {}, {}
  for i, mr in ipairs(rows) do
    local hit = stats_cache[mr.iid]
    if hit and hit.at == mr.updated_at then
      mr.diff_stats = hit.stats
      redraw_row(i)
    else
      table.insert(wanted, mr.iid)
      at_row[mr.iid] = i
    end
  end
  if #wanted == 0 then
    return
  end
  glab.diff_summaries(root, wanted, function(data)
    for iid, stats in pairs(data or {}) do
      local i = at_row[iid]
      if i and rows[i] and rows[i].iid == iid then
        stats_cache[iid] = { at = rows[i].updated_at, stats = stats }
        rows[i].diff_stats = stats
        redraw_row(i)
      end
    end
  end)
end

-- iid -> { at = updated_at, pipeline = ... }, for as long as the editor
-- lives. Keyed on `updated_at` as well as the number: a merge request
-- that has been pushed to since we asked is a merge request whose
-- pipeline we know nothing about, and one that has not been pushed to
-- has the pipeline we already have.
local pipeline_cache = {}

function M.forget_pipelines()
  pipeline_cache = {}
  stats_cache = {}
end

--- The questions a row of GitLab's list cannot answer, asked one row at
--- a time.
---
--- Two of them. What CI made of the branch, because the merge request
--- list carries no pipeline; and how many comments you wrote on it and
--- have not sent, because a draft note is yours and is in nobody's
--- list payload either. The second is the one worth the wait: an
--- unsent comment lives on the forge rather than in this editor, so it
--- is still there tomorrow, on a machine you are not sitting at, and
--- the queue is the only place you would ever be told.
---
--- One queue for both, a few at a time, in row order, each row redrawn
--- as its own answer lands: the list is readable the moment it opens
--- and fills in underneath you. One queue rather than two, because
--- every one of these is a process that starts, authenticates and
--- opens a connection of its own -- two pools of six is twelve of them
--- at once, and thirty together are slower end to end than six at a
--- time and take the machine down with them while they run. In row
--- order because the top of the list is what is being read while the
--- rest fills in.
local function fetch_rows(root)
  local queue = {}

  --- Runs `ask` for row `i` if the row is still the one it was asked
  --- about: the cursor moves faster than a forge answers, and `r`
  --- rebuilds the rows underneath a call that is still in flight.
  local function for_row(i, ask)
    local iid = rows[i].iid
    table.insert(queue, function(done)
      ask(iid, function(fill)
        if rows[i] and rows[i].iid == iid then
          fill(rows[i])
          redraw_row(i)
        end
        done()
      end)
    end)
  end

  for i, mr in ipairs(rows) do
    if config.list.ci then
      local hit = pipeline_cache[mr.iid]
      if hit and hit.at == mr.updated_at then
        mr.head_pipeline = hit.pipeline
        redraw_row(i)
      elseif not detail.ci(mr) then
        local updated = mr.updated_at
        for_row(i, function(iid, answered)
          glab.mr_pipelines(root, iid, function(data)
            local latest = type(data) == "table" and data[1]
            if not latest then
              answered(function() end)
              return
            end
            pipeline_cache[iid] = { at = updated, pipeline = latest }
            answered(function(row)
              row.head_pipeline = latest
            end)
          end)
        end)
      end
    end
    -- Not cached, unlike the pipeline: what you have written and not
    -- sent changes because *you* changed it, and it changes without
    -- the merge request being touched at all, so there is nothing to
    -- key a cache on. Quietly, too -- draft notes are GitLab 15.10 and
    -- the endpoint 404s on anything older, where the right answer is
    -- "you have none" rather than an error on every row.
    if config.list.drafts then
      for_row(i, function(iid, answered)
        glab.draft_notes(root, iid, function(data)
          local parsed = threads.parse_drafts(type(data) == "table" and data or {})
          answered(function(row)
            row.drafts, row.draft_overview = parsed.inline, parsed.overview
            row.draft_replies = parsed.replies
          end)
        end)
      end)
    end
  end

  local at_once = math.max(config.list.concurrency or 6, 1)
  local next_job
  next_job = function()
    local job = table.remove(queue, 1)
    if job then
      job(next_job)
    end
  end
  for _ = 1, math.min(at_once, #queue) do
    next_job()
  end
end

--- Where the list goes, and where the pane under it goes.
---
--- The list is centred, which is where a modal window belongs, and it
--- stays where it is: opening the pane must not move the thing you are
--- reading out from under you. So its top edge is the fixed point of
--- this, and the pane takes the room below it.
---
--- Where there is not enough room down there, the list gives up rows --
--- from the bottom, its top edge staying put -- and only if it has none
--- left to give does the pair move up the screen. A queue is scrolled;
--- a changelog four rows tall is a changelog nobody reads.
local function geometry()
  local width = math.floor(vim.o.columns * config.list.width)
  local col = math.floor((vim.o.columns - width) / 2)
  -- The winbar is drawn *inside* the window and takes a row out of its
  -- height, so the window has to be one taller than the list it holds.
  -- At a height of one -- a queue with a single merge request in it,
  -- which is most of them -- there is no row left for the list and
  -- Neovim refuses the winbar with "E36: Not enough room".
  local body = message and #message or math.max(#rows, 1)
  local height = math.max(2, math.min(math.floor(vim.o.lines * config.list.height), body + 1))
  -- Centred on the height it has when it is alone, so that the row
  -- below does not depend on whether the pane is open -- which is the
  -- whole point.
  local row = math.max(math.floor((vim.o.lines - height) / 2) - 1, 1)

  if not preview_open() then
    return { width = width, col = col, height = height, row = row }
  end

  -- Each float costs its border on top of its height, and the last two
  -- rows of the editor belong to the status and command lines.
  local budget = vim.o.lines - 2
  local function below(r, h)
    return budget - (r + h + 3)
  end
  -- ...and never more than half the editor: on a short screen the pane
  -- asking for fourteen rows is the pane asking for the list.
  local wanted =
    math.max(math.min(config.list.preview_height, math.floor(budget / 2), budget - 8), 3)

  if below(row, height) < wanted then
    height = math.max(height - (wanted - below(row, height)), 2)
  end
  -- ...and the pane takes what that leaves, which is often less than it
  -- asked for. Only when it is less than a pane can be read in at all
  -- does the pair come up the screen: a shorter changelog is worth a
  -- list that stays where you left it, and four rows of one is not.
  local least = math.min(wanted, 6)
  if below(row, height) < least then
    row = math.max(row - (least - below(row, height)), 1)
  end

  return {
    width = width,
    col = col,
    height = height,
    row = row,
    -- Never taller than it was asked to be, however much room there is
    -- under a short queue: this is a pane, not the other half of the
    -- screen.
    preview = math.max(math.min(below(row, height), wanted), 3),
  }
end

local function current()
  if message or not (M.win and vim.api.nvim_win_is_valid(M.win)) then
    return nil
  end
  return rows[vim.api.nvim_win_get_cursor(M.win)[1]]
end

local function relayout()
  if not (M.win and vim.api.nvim_win_is_valid(M.win)) then
    return
  end
  local g = geometry()
  vim.api.nvim_win_set_config(M.win, {
    relative = "editor",
    row = g.row,
    col = g.col,
    width = g.width,
    height = g.height,
  })
  if preview_open() then
    local mr = current()
    vim.api.nvim_win_set_config(M.preview.win, {
      relative = "editor",
      row = g.row + g.height + 2,
      col = g.col,
      width = g.width,
      height = g.preview,
      title = mr and (" !%d · %s "):format(mr.iid, M.preview.mode)
        or (" %s "):format(M.preview.mode),
      title_pos = "center",
    })
  end
end

--- Broken into lines that fit, on whitespace, because the window does
--- not wrap: a row of the queue is wider than a narrow window and has
--- to be cut off rather than folded in half, and a sentence has to be
--- folded rather than cut off. So the folding is done here, where the
--- difference between the two is known.
local function fold(text, width)
  local lines = {}
  for _, para in ipairs(vim.split(text, "\n", { plain = true })) do
    local line = nil
    for word in para:gmatch("%S+") do
      if not line then
        line = word
      elseif vim.fn.strdisplaywidth(line .. " " .. word) <= width then
        line = line .. " " .. word
      else
        table.insert(lines, line)
        line = word
      end
    end
    table.insert(lines, line or "")
  end
  return lines
end

--- What the keys do, which is not the same list while a message is over
--- the queue: most of them have nothing to act on until it is gone.
--- The state the key would move to, which is what the hint is named
--- after.
local function next_state()
  local now = listing()
  for i, s in ipairs(STATES) do
    if s == now then
      return STATES[i % #STATES + 1]
    end
  end
  return STATES[1]
end

--- The window's own title says which queue this is. The rows say it
--- one at a time; a window of nothing but merged merge requests has to
--- say it once, at the top, or an empty-looking review queue is a
--- filter nobody remembers turning on.
local function set_title()
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    vim.api.nvim_win_set_config(M.win, {
      title = (" merge requests · %s "):format(listing()),
      title_pos = "center",
    })
  end
end

local function set_hint()
  if not (M.win and vim.api.nvim_win_is_valid(M.win)) then
    return
  end
  local k = config.keys.list
  local keys
  if message and #rows > 0 then
    keys = { { k.select, "back to the list" }, { k.refresh, "refetch" }, { k.quit, "quit" } }
  elseif message then
    keys = { { k.refresh, "refetch" }, { k.quit, "quit" } }
  else
    keys = {
      { k.select, "open" },
      { k.commits, "commits" },
      { k.description, "description" },
      -- Named after what pressing it would show rather than after what
      -- is on the screen: every other hint on this bar is a verb.
      { k.state, next_state() },
      { k.refresh, "refresh" },
      { k.browser, "browser" },
      { k.quit, "quit" },
    }
  end
  vim.wo[M.win].winbar = detail.hint(keys)
end

--- Says what the window is doing, in the window.
---
--- Where the notification line said it before. A picker that is asked
--- for and does not appear until the forge answers -- and then answers
--- again, in the corner of the screen, while it is being read -- is a
--- picker whose waiting happens somewhere other than where you are
--- looking. So the window opens on the keypress and carries its own
--- state: fetching, opening one, or what went wrong -- whole, however
--- many lines that takes.
local function set_message(text, hl)
  local width = math.floor(vim.o.columns * config.list.width)
  message = vim.tbl_map(function(line)
    return "  " .. line
  end, fold(text, width - 4))
  if not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) then
    return
  end
  vim.bo[M.buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, message)
  vim.bo[M.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(M.buf, marks.ui_ns, 0, -1)
  for i, line in ipairs(message) do
    vim.api.nvim_buf_set_extmark(M.buf, marks.ui_ns, i - 1, 0, {
      end_col = #line,
      hl_group = hl or "NemetonMeta",
    })
  end
  set_hint()
  relayout()
end

--- The queue itself, in place of whatever the window was saying.
local function set_rows(mrs)
  if not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) then
    return
  end
  message, rows = nil, {}
  local lines, hls = format(mrs)
  vim.bo[M.buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.bo[M.buf].modifiable = false
  marks.paint(M.buf, hls)
  vim.api.nvim_win_set_cursor(M.win, { 1, 0 })
  set_hint()
  relayout()
end

local function draw_preview(lines, hls)
  if not preview_open() then
    return
  end
  vim.bo[M.preview.buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.preview.buf, 0, -1, false, lines)
  vim.bo[M.preview.buf].modifiable = false
  marks.paint(M.preview.buf, hls or {})
end

-- Which fetch the pane is still interested in. The cursor moves faster
-- than a forge answers, and a reply that arrives after the cursor has
-- left the row it was about must not be drawn.
local ticket = 0

local function update_preview(now)
  if not preview_open() then
    return
  end
  ticket = ticket + 1
  local mine = ticket
  local mr = current()
  relayout()
  if not mr then
    draw_preview({ "" })
    return
  end
  local function go()
    if mine ~= ticket or not preview_open() then
      return
    end
    local answered = false
    -- The second value is the highlights when there are lines, and the
    -- reason when there are not.
    detail.fetch(session.root(), mr, M.preview.mode, function(lines, hls_or_err)
      answered = true
      if mine ~= ticket then
        return
      end
      if not lines then
        draw_preview({
          ("could not read the %s: %s"):format(M.preview.mode, tostring(hls_or_err)),
        })
        return
      end
      draw_preview(lines, hls_or_err)
    end)
    -- Only when the fetch actually went out: a cached answer comes back
    -- inside the call above, and a "…" drawn either side of it is a
    -- flicker on every cursor move.
    if not answered then
      draw_preview({ "…" })
    end
  end
  if now then
    go()
  else
    -- Held down, `j` walks the queue faster than the network answers;
    -- the pane is for the row the cursor stopped on.
    vim.defer_fn(go, 80)
  end
end

--- Opens the pane, or closes it again. The mode it is already showing
--- toggles it shut, which is what pressing the same key twice means.
function M.toggle_preview(mode)
  if M.preview.mode == mode then
    close_preview()
    relayout()
    return nil
  end
  if not preview_open() then
    M.preview.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[M.preview.buf].bufhidden = "wipe"
    vim.bo[M.preview.buf].modifiable = false
    M.preview.win = vim.api.nvim_open_win(M.preview.buf, false, {
      relative = "editor",
      row = 1,
      col = 0,
      width = 10,
      height = 3,
      style = "minimal",
      border = "rounded",
      -- Not focusable: it is a second view of the row under the cursor,
      -- and a pane you can end up inside is a pane you have to get out
      -- of before the list's keys work again.
      focusable = false,
    })
    vim.wo[M.preview.win].wrap = true
    vim.wo[M.preview.win].linebreak = true
  end
  M.preview.mode = mode
  -- A description is markdown and is worth rendering as such; a
  -- changelog is a table and markdown would only find headings in it.
  vim.bo[M.preview.buf].filetype = mode == "description" and "markdown" or ""
  update_preview(true)
  return mode
end

local function open_window()
  M.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[M.buf].modifiable = false
  vim.bo[M.buf].bufhidden = "wipe"

  local g = geometry()
  M.win = vim.api.nvim_open_win(M.buf, true, {
    relative = "editor",
    width = g.width,
    height = g.height,
    row = g.row,
    col = g.col,
    style = "minimal",
    border = "rounded",
    title = (" merge requests · %s "):format(listing()),
    title_pos = "center",
  })
  vim.wo[M.win].cursorline = true
  -- A row of the queue is wider than a narrow window, and a row folded
  -- in half is two rows that are not two merge requests. Cut them off
  -- instead; what a message says is folded by hand before it gets here.
  vim.wo[M.win].wrap = false
  set_hint()

  local keys = config.keys.list

  vim.keymap.set("n", keys.quit, close, { buffer = M.buf, desc = "nemeton: close the list" })
  vim.keymap.set("n", keys.refresh, function()
    M.open()
  end, { buffer = M.buf, desc = "nemeton: refetch" })
  if keys.state and keys.state ~= "" then
    vim.keymap.set("n", keys.state, function()
      state = next_state()
      set_title()
      M.open()
    end, { buffer = M.buf, desc = "nemeton: open, merged, closed, or all of them" })
  end
  vim.keymap.set("n", keys.select, function()
    -- Reading a failure is the one thing this window does that ends
    -- with going back to what was on the screen before it.
    if message then
      if #rows > 0 then
        set_rows(rows)
      end
      return
    end
    local mr = current()
    if not mr then
      return
    end
    -- The window stays up, saying which one it is opening, until the
    -- merge request is actually open: that is a checkout and three
    -- round trips, and a picker that vanishes on the keypress leaves
    -- those seconds looking like nothing happened. It goes when there
    -- is something to go to; if the open fails, the queue comes back
    -- and another can be picked.
    local queue = rows
    close_preview()
    set_message(("opening !%d — %s…"):format(mr.iid, mr.title or ""))
    -- Through the plugin's own entry point rather than straight to
    -- session.open: opening a merge request also binds the review keys
    -- on the buffers that are already loaded, and a session with no
    -- keys on the file you were already reading is a session you cannot
    -- use.
    require("nemeton").open(mr.iid, {
      on_open = close,
      -- Said here rather than notified: this window is what is being
      -- looked at, and a reason worth reading is a sentence, which is
      -- what the body of a window is for. The queue is still in `rows`
      -- underneath it; `<CR>` puts it back without asking the forge
      -- anything.
      on_error = function(why)
        rows = queue
        set_message(why, "NemetonBad")
      end,
    })
  end, { buffer = M.buf, desc = "nemeton: check this one out and load its comments" })
  vim.keymap.set("n", keys.browser, function()
    local mr = current()
    if mr and mr.web_url then
      vim.ui.open(mr.web_url)
    end
  end, { buffer = M.buf, desc = "nemeton: open on GitLab" })
  for _, pane in ipairs({
    { keys.commits, "commits", "the commits on this merge request" },
    { keys.description, "description", "what this merge request is for" },
  }) do
    if pane[1] and pane[1] ~= "" then
      vim.keymap.set("n", pane[1], function()
        M.toggle_preview(pane[2])
      end, { buffer = M.buf, desc = "nemeton: " .. pane[3] })
    end
  end

  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = M.buf,
    callback = function()
      update_preview(false)
    end,
  })
  -- The list is the only thing holding the pane up.
  vim.api.nvim_create_autocmd({ "WinClosed", "BufWipeout" }, {
    buffer = M.buf,
    callback = close_preview,
  })
end

function M.open()
  local root = session.root()
  if not root then
    session.notify("not inside a git repository", vim.log.levels.ERROR)
    return
  end
  if not glab.available() then
    session.notify("glab is not on your PATH", vim.log.levels.ERROR)
    return
  end

  -- `r` means the queue has moved on; a changelog from before the last
  -- push is exactly what must not survive it.
  local mode = M.preview.mode
  detail.forget()
  -- ...and what CI said, which can have moved on without the merge
  -- request itself moving at all: a pipeline that was running when the
  -- list was last up has finished since.
  M.forget_pipelines()

  -- The window first, the queue afterwards. `r` refetches into the
  -- window that is already there rather than closing it and opening
  -- another one in the same place.
  close_preview()
  if not (M.win and vim.api.nvim_win_is_valid(M.win)) then
    open_window()
  end
  set_title()
  set_message(("fetching %s merge requests…"):format(listing()))
  local mine = M.buf

  glab.mr_list(root, listing(), function(mrs, err)
    -- Closed, or refetched, while the forge was thinking.
    if M.buf ~= mine or not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) then
      return
    end
    if not mrs then
      set_message("could not list merge requests: " .. tostring(err), "NemetonBad")
      return
    end
    if #mrs == 0 then
      set_message(("no %s merge requests"):format(listing()))
      return
    end
    set_rows(mrs)
    fetch_rows(root)
    fetch_stats(root)

    if mode then
      M.toggle_preview(mode)
      -- The list, not the pane, keeps the cursor.
      vim.api.nvim_set_current_win(M.win)
    end
  end)
end

M.close = close

return M
