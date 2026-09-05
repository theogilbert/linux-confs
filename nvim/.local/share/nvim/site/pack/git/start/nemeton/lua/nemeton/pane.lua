-- The conversations of the file you are reading, in a pane beside it.
--
-- The other half of expanding. Inline, a thread is drawn under the line
-- it is about, which is where it belongs and which pushes the code
-- apart to say so: four threads in a file is four blocks between you
-- and the next function, and a comment wrapped into a narrow split is a
-- comment read four words at a time. Here the code keeps its shape and
-- the conversations get a window of their own, wide enough to read
-- prose in.
--
-- One conversation at a time: the pane is where a thread is *read*, and
-- a window holding every thread in the file is a window you have to
-- navigate before you can read anything. `]m` and `[m` are the
-- navigation -- they are already the walk through what a review is owed
-- -- and they are the only thing that changes what is in here. The
-- gutter still says which lines carry a thread: the pane is the
-- reading, the markers are the map.
--
-- Not the cursor. Reading a comment and reading the code it is about
-- are the same activity: you go to the line it names, then to the
-- function that line calls, then back through three files -- and half
-- of that is standing on lines other people have commented on too. A
-- pane that answered the cursor would spend that walk showing
-- everything except the thing being read. So it holds still, and the
-- comment stays on the screen while the code under it moves.
--
-- One pane, not one per window. It is a place to read, like the
-- quickfix window, and a screen with a pane against every split is a
-- screen with no code left on it.

local config = require("nemeton.config")
local edit = require("nemeton.edit")
local marks = require("nemeton.marks")
local session = require("nemeton.session")
local syntax = require("nemeton.syntax")
local threads = require("nemeton.threads")

local M = {}

M.win = nil
M.buf = nil
-- The window the code is in: what the pane is drawn from, and where the
-- cursor goes back to when it closes.
M.source = nil

-- What the pane is showing: the buffer the conversation is in, and the
-- line of `by_file` it is indexed under. Not the threads themselves --
-- a refresh replaces every table in the session, and the pane has to
-- come back drawing what the forge now says about the same place.
M.at = nil

-- Pane row (1-based) -> the thread drawn there, for the keys that act
-- on the one under the cursor. A line of code can carry two
-- conversations; the pane shows a place, and both of them are here.
local rows = {}

local function valid()
  return M.win and vim.api.nvim_win_is_valid(M.win)
end

--- Where the pane opens.
---
--- `expand_anchor` decides which window it is a split *of*. "window"
--- splits the one the code is in, so the pane arrives beside it and the
--- rest of the screen keeps the layout the reviewer built; "editor"
--- puts it against the edge of the whole editor, full height down the
--- right or full width along the bottom, which is where a reader of one
--- file at a time wants it and where the quickfix window already is.
--- Never more than half the screen, whatever it is set to: sixty
--- columns is a comfortable width for prose and most of an eighty
--- column terminal, and a pane that leaves nineteen columns of code is
--- a pane opened once.
local function split_cmd()
  local c = config.comments
  local edge = c.expand_anchor == "editor" and "botright" or "belowright"
  if c.expand == "right" then
    local width = math.min(c.pane_width or 60, math.floor(vim.o.columns / 2))
    return ("%s vertical %dsplit"):format(edge, math.max(width, 10))
  end
  local height = math.min(c.pane_height or 15, math.floor(vim.o.lines / 2))
  return ("%s %dsplit"):format(edge, math.max(height, 3))
end

--- The buffer the pane is showing the threads of.
local function source_buf()
  if M.source and vim.api.nvim_win_is_valid(M.source) then
    return vim.api.nvim_win_get_buf(M.source)
  end
  return vim.api.nvim_get_current_buf()
end

--- Where each thread's line has got to since the markers were drawn.
---
--- A review is a session in which you change the file you are reading,
--- and the gutter marker moves with the edit while the index still
--- keys on the line the thread was written against. What a suggestion
--- would replace is read at the line the marker is on now, because
--- that is the code the comment is now about -- the same answer the
--- inline view gives, arrived at the same way.
local function moved(bufnr)
  local out = {}
  local known = marks.line_of_mark[bufnr] or {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, marks.ns, 0, -1, {})) do
    local line = known[mark[1]]
    if line then
      out[line] = mark[2] + 1
    end
  end
  return out
end

--- The thread the pane's cursor is in. A conversation is several lines
--- tall and the cursor lands anywhere in it, so the search walks
--- upwards -- the thread you are inside is the last one that started
--- above you.
local function thread_at()
  if not valid() then
    return nil
  end
  for i = vim.api.nvim_win_get_cursor(M.win)[1], 1, -1 do
    if rows[i] then
      return rows[i]
    end
  end
  return nil
end

--- The line of `by_file` a row of `bufnr` carries a thread for, by
--- asking the extmarks rather than the index -- so an edit that moved
--- the marker moves the answer with it.
local function line_at(bufnr, row)
  local known = marks.line_of_mark[bufnr] or {}
  for _, mark in
    ipairs(vim.api.nvim_buf_get_extmarks(bufnr, marks.ns, { row - 1, 0 }, { row - 1, -1 }, {}))
  do
    if known[mark[1]] then
      return known[mark[1]]
    end
  end
  return nil
end

local function visible(list)
  return vim.tbl_filter(function(t)
    return config.comments.show_resolved or not t.resolved
  end, list or {})
end

--- A winbar out of `pieces` -- `{ text, highlight }`, in order --
--- with `%` in anything written by a person escaped, since a path can
--- carry one and a winbar reads it as a field.
local function bar(pieces)
  local out = {}
  for _, piece in ipairs(pieces) do
    if piece[1] ~= "" then
      table.insert(out, ("%%#%s#%s%%*"):format(piece[2], (piece[1]:gsub("%%", "%%%%"))))
    end
  end
  return table.concat(out)
end

local function measure(pieces)
  local w = 0
  for _, piece in ipairs(pieces) do
    w = w + vim.fn.strdisplaywidth(piece[1])
  end
  return w
end

--- The pane's own header: what is being read, and what can be done to
--- it.
---
--- The one line of this window that does not scroll, so it carries what
--- stays true while the conversation is read: the state, in the glyph
--- the gutter marks that line with and in the same colour; where it
--- sits; and how much of it there is -- how many answers, and whether
--- the line carries a second argument as well. The block below says all
--- of that too, a note at a time and a screen at a time; the head says
--- it at a glance and goes on saying it four screens down.
---
--- Fitted here rather than left to the winbar's own truncation, which
--- happens at `%<` and takes everything after it. What is dropped is
--- dropped in order: the keys first -- a pane thirty columns wide is
--- one where the file name is worth more than a reminder that `q`
--- closes windows -- then how much of it there is, and last the head of
--- the path, which goes as `…app.lua:3`, because the end of a path is
--- the half that says which file it is.
local function header(list, path, row, width)
  local first = list[1]
  local unsent = threads.unsent(first)
  local glyph, hl = config.comments.sign_open, "NemetonSignOpen"
  if unsent then
    glyph, hl = config.comments.sign_draft, "NemetonDraft"
  elseif first.resolved then
    glyph, hl = config.comments.sign_resolved, "NemetonResolved"
  end

  local notes = 0
  for _, t in ipairs(list) do
    notes = notes + #t.notes
  end
  local much = {}
  if #list > 1 then
    table.insert(much, ("%d threads"):format(#list))
  end
  if notes > #list then
    table.insert(much, ("+%d"):format(notes - #list))
  end

  -- The keys, said twice: with what they do, and -- for a pane too
  -- narrow for that -- as the keys alone. A row of letters is a
  -- reminder rather than an explanation, which is what it is for by the
  -- fourth time a reviewer sees it.
  local said, alone = {}, {}
  for _, pair in ipairs({
    { config.keys.session.next, "next" },
    { config.keys.pane.reply, "reply" },
    { config.keys.pane.code, "code" },
    { config.keys.pane.quit, "close" },
  }) do
    if pair[1] and pair[1] ~= "" then
      table.insert(said, ("%s %s"):format(pair[1], pair[2]))
      table.insert(alone, pair[1])
    end
  end

  local place = ("%s:%d"):format(path, row)
  local left = { { " " .. glyph .. " ", hl }, { place, "NemetonPath" } }
  if #much > 0 then
    table.insert(left, { "  " .. table.concat(much, " · "), "NemetonMeta" })
  end
  -- Two columns and a gap of at least two, or one column and no keys.
  for _, keys in ipairs({ said, alone }) do
    local right = { { table.concat(keys, " · ") .. " ", "NemetonHint" } }
    if #keys > 0 and measure(left) + measure(right) + 2 <= width then
      return bar(left) .. "%=" .. bar(right)
    end
  end
  if #much > 0 and measure(left) > width then
    table.remove(left)
  end
  local over = measure(left) - width
  if over > 0 then
    -- The end of the path, with an ellipsis where the rest of it was.
    -- `…src/app.lua:3` cut at the front still names a file; cut at the
    -- back it names a directory.
    local room = vim.fn.strdisplaywidth(place) - over - 1
    local keep = place
    while room > 0 and vim.fn.strdisplaywidth(keep) > room do
      keep = vim.fn.strcharpart(keep, 1)
    end
    left[2][1] = room > 0 and ("…" .. keep) or ""
  end
  return bar(left)
end

--- Draws the conversation the pane is on, and marks in the gutter of
--- the code the lines it was written against.
function M.render()
  if not (valid() and M.buf and vim.api.nvim_buf_is_valid(M.buf) and session.current) then
    return
  end
  local at = M.at
  local bufnr = at and vim.api.nvim_buf_is_valid(at.buf) and at.buf or nil
  local path = bufnr and session.relpath(bufnr) or nil
  local by_line = path and session.current.by_file[path] or nil
  local shown = visible(by_line and by_line[at.line])

  local chunks, map, ground = {}, {}, {}
  local head = bar({ { " nothing being read ", "NemetonMeta" } })
  if #shown > 0 then
    -- Where the line has got to since the markers were drawn, which is
    -- what the comment is now about.
    local row = moved(bufnr)[at.line] or math.min(at.line, vim.api.nvim_buf_line_count(bufnr))
    head = header(shown, path, row, vim.api.nvim_win_get_width(M.win))
    local function replaced(above, below)
      return vim.api.nvim_buf_get_lines(bufnr, math.max(row - 1 - above, 0), row + below, false)
    end
    -- The colours of the language the file is in, for the code inside a
    -- suggestion. The buffer's own filetype rather than the thread's
    -- path: it is the same file, and the editor has already made up its
    -- mind about it -- modeline and all.
    --
    -- ...unless the line the thread sits on is inside a docstring or a
    -- comment, where what a suggestion replaces is prose. Cut out and
    -- parsed on its own it would come back as a keyword here and a
    -- function call there, which is a worse answer than leaving it the
    -- colour of the half of the diff it is.
    local lang = syntax.of_buf(bufnr)
    local paint = syntax.painter(lang)
    if paint and syntax.prose(bufnr, row - 1, lang) then
      paint = nil
    end
    -- Wrapped to the pane rather than to the window the code is in:
    -- this is a real buffer with `wrap` on, so nothing is lost at the
    -- edge -- but a wrapped line comes back at column zero, outside the
    -- rail, and a rail that reaches half of its own thread has stopped
    -- being an edge.
    local width = vim.api.nvim_win_get_width(M.win)

    local span = 0
    for i, t in ipairs(shown) do
      -- A blank line between two conversations on one line of code, and
      -- nothing but a blank line: it is the one place the rail stops
      -- and the one place the ground does, which is what makes "a new
      -- argument" look different from "an answer to the one above".
      if i > 1 then
        table.insert(chunks, {})
      end
      span = math.max(span, threads.span(t))
      local drawn = threads.render(t, {
        replaced = replaced,
        width = width,
        was = session.was(t, replaced(threads.span(t), 0)),
        paint = paint,
      })
      for _, said in ipairs(drawn) do
        table.insert(chunks, said)
        map[#chunks] = t
        ground[#chunks] = t.resolved and "settled" or "open"
      end
    end
    -- The lines this conversation was written against, in the gutter of
    -- the code. Reading a comment in a window beside the file is the
    -- one way of reading one where nothing on the code says which lines
    -- it is about -- the bubble marks the line it is anchored to, and a
    -- comment written over a selection is about the lines above that
    -- too.
    local first = shown[1]
    marks.current(
      bufnr,
      row - span,
      row,
      first.draft and "NemetonDraft" or (first.resolved and "NemetonResolved" or "NemetonSignOpen")
    )
  else
    marks.clear_current()
    chunks = {
      {
        {
          session.current.by_file
              and next(session.current.by_file)
              and "no thread here — ]m for the next one."
            or "nothing has been said on this merge request yet.",
          "NemetonMeta",
        },
      },
    }
  end

  local text, hls = marks.shade_lines(chunks, 0, ground)
  rows = map
  vim.bo[M.buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, text)
  vim.bo[M.buf].modifiable = false
  marks.paint(M.buf, hls)
  -- Back to the top: this is one conversation, read from the first
  -- thing anybody said, and a pane still scrolled to where the last one
  -- ended is a pane that opens in the middle of a sentence.
  vim.api.nvim_win_set_cursor(M.win, { 1, 0 })

  vim.wo[M.win].winbar = head
end

--- Shows whatever the cursor in `win` is standing on, and says whether
--- that was a thread. It is not one most of the time -- a review is
--- read and answered from the code -- and then the pane is left showing
--- what it was showing.
function M.show(win)
  if not (valid() and vim.api.nvim_win_is_valid(win)) then
    return false
  end
  local bufnr = vim.api.nvim_win_get_buf(win)
  local line = line_at(bufnr, vim.api.nvim_win_get_cursor(win)[1])
  if not line then
    return false
  end
  M.at = { buf = bufnr, line = line }
  M.render()
  return true
end

--- Which window the code is being read in, which is the window the
--- walk is made in and the one the cursor goes back to. Followed; what
--- is *shown* is not.
---
--- The cursor moving changes nothing in here. Reading a comment and
--- reading the code it is about are the same activity: you go to the
--- line, then to the function it calls, then back -- and half of that
--- is standing on lines other people have also commented on. A pane
--- that answered the cursor would spend that walk showing everything
--- except the thing being read.
---
--- So the conversation changes when you say so, and `]m` and `[m` are
--- how you say so.
function M.follow()
  if not valid() then
    return
  end
  local win = vim.api.nvim_get_current_win()
  if win == M.win then
    return
  end
  -- A window that is not a file of this merge request -- the quickfix
  -- list, a terminal, the composer -- is not where the walk happens
  -- either.
  if not session.relpath(vim.api.nvim_win_get_buf(win)) then
    return
  end
  M.source = win
end

function M.close()
  local win, source = M.win, M.source
  M.win, M.buf, M.source, M.at = nil, nil, nil, nil
  rows = {}
  marks.clear_current()
  pcall(vim.api.nvim_clear_autocmds, { group = "NemetonPane" })
  if win and vim.api.nvim_win_is_valid(win) then
    -- Back where the key was pressed. `nvim_win_close` hands the cursor
    -- to the first window of the layout, which on a split screen is not
    -- the one the pane was opened from.
    local here = vim.api.nvim_get_current_win() == win
    vim.api.nvim_win_close(win, true)
    if here and source and vim.api.nvim_win_is_valid(source) then
      pcall(vim.api.nvim_set_current_win, source)
    end
  end
end

--- The first conversation in `win`'s file at or after its cursor, and
--- the first in the file when the cursor is past the last of them.
local function next_in_file(win)
  local bufnr = vim.api.nvim_win_get_buf(win)
  local path = session.relpath(bufnr)
  local by_line = path and session.current and session.current.by_file[path]
  if not by_line then
    return nil
  end
  local lines = {}
  for line, list in pairs(by_line) do
    if #visible(list) > 0 then
      table.insert(lines, line)
    end
  end
  if #lines == 0 then
    return nil
  end
  table.sort(lines)
  local row = vim.api.nvim_win_get_cursor(win)[1]
  for _, line in ipairs(lines) do
    if line >= row then
      return { buf = bufnr, line = line }
    end
  end
  return { buf = bufnr, line = lines[1] }
end

function M.open()
  if not session.current then
    return nil
  end
  M.close()

  -- The window the pane is a split of has to be one that can be split:
  -- the key is bound everywhere, and "everywhere" includes this
  -- plugin's own floats. Any ordinary window of this tab will do --
  -- what the pane shows is decided by the cursor, not by the split.
  local source = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_config(source).relative ~= "" then
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_config(w).relative == "" then
        source = w
        break
      end
    end
  end
  M.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[M.buf].bufhidden = "wipe"

  -- Split from the window the code is in, and back to it afterwards:
  -- the pane is opened to be read beside the file, not to be typed in,
  -- and a key that takes the cursor out of the code is a key pressed
  -- once.
  local win
  vim.api.nvim_win_call(source, function()
    vim.cmd(split_cmd())
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, M.buf)
  end)
  M.win, M.source = win, source

  vim.wo[M.win].wrap = true
  vim.wo[M.win].linebreak = true
  vim.wo[M.win].cursorline = true
  vim.wo[M.win].number = false
  vim.wo[M.win].relativenumber = false
  vim.wo[M.win].signcolumn = "no"
  vim.wo[M.win].foldcolumn = "0"
  vim.wo[M.win].list = false
  vim.wo[M.win].spell = false
  -- The pane keeps the size it was given while the rest of the screen
  -- is split and closed around it: it is sized for prose, and prose
  -- resized by whatever happened to the window next door is prose at
  -- the wrong width.
  vim.wo[M.win].winfixwidth = true
  vim.wo[M.win].winfixheight = true

  local k = config.keys.pane
  local function on_thread(fn)
    return function()
      local thread = thread_at()
      if thread then
        fn(thread)
      end
    end
  end
  local bindings = {
    -- Not `M.close`: the pane is what "expanded" means while it is on,
    -- so the key that puts it away is the key that folds the
    -- conversations back into the gutter.
    { k.quit, session.toggle_expanded, "put the conversations away" },
    {
      k.code,
      function()
        local thread = thread_at()
        -- Out of the pane before the jump. `goto_thread` puts the file
        -- in the window it is called from when it is not already on the
        -- screen, and the pane is not a window to put code in.
        if M.source and vim.api.nvim_win_is_valid(M.source) then
          vim.api.nvim_set_current_win(M.source)
        end
        session.goto_thread(thread)
      end,
      "go to the code this is about",
    },
    { k.reply, on_thread(edit.reply), "reply to the thread here" },
    { k.edit, on_thread(edit.thread), "edit a comment in the thread here" },
    { k.delete, on_thread(edit.delete), "delete a comment in the thread here" },
    {
      k.refresh,
      function()
        session.refresh()
      end,
      "refetch",
    },
  }
  -- The walk, from inside the pane. `]m` and `[m` are bound everywhere
  -- while a review is on, and out in the code they move the cursor,
  -- which is what brings the next conversation in here. In here there
  -- is no cursor to move: the jump is made in the window the pane was
  -- opened from -- which shows it, on the way -- and the reading stays
  -- where the reader is.
  for _, walk in ipairs({
    { config.keys.session.next, 1, "the next thread owed an answer" },
    { config.keys.session.prev, -1, "the previous one" },
  }) do
    table.insert(bindings, {
      walk[1],
      function()
        local from = M.source
        if not (from and vim.api.nvim_win_is_valid(from)) then
          return
        end
        vim.api.nvim_win_call(from, function()
          session.jump(walk[2])
        end)
      end,
      walk[3],
    })
  end
  for _, b in ipairs(bindings) do
    if b[1] and b[1] ~= "" then
      vim.keymap.set("n", b[1], b[2], { buffer = M.buf, nowait = true, desc = "nemeton: " .. b[3] })
    end
  end

  local group = vim.api.nvim_create_augroup("NemetonPane", { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    group = group,
    callback = M.follow,
  })
  -- Closed by hand -- `:q` in it, or the window it was split from going
  -- away with it. The mode follows the window: the conversations are
  -- not expanded any more, whatever the session last recorded.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(M.win),
    callback = function()
      M.win = nil
      M.close()
      if session.current and session.current.mode == "expanded" then
        session.current.mode = "signs"
        session.redraw_all()
      end
    end,
  })

  -- What it opens on: the thread under the cursor, and otherwise the
  -- next one in this file. A pane that opens empty because the cursor
  -- happened to be on line 1 is a pane whose first keypress is `]m`,
  -- and that is a keypress the plugin can make for itself.
  if not M.show(source) then
    local at = next_in_file(source)
    if at then
      M.at = at
    end
    M.render()
  end
  return M.win
end

--- Redraws it if it is open, and does nothing if it is not: this is
--- what a session refresh, a resize and a toggle all call.
function M.redraw()
  if valid() then
    M.render()
  end
end

return M
