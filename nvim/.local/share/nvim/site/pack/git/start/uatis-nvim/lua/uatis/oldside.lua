-- The old revision, in a window of its own, beside the in-place view.
--
--   <leader>go
--
-- Removed code is drawn as virtual lines, and virtual text is a
-- decoration rather than buffer content: the cursor cannot enter it, `/`
-- and `*` do not see it, and there is nothing to yank. That is the price
-- of the in-place view's whole shape -- you read your own navigable,
-- writable, LSP-attached buffer, and what it replaced is drawn around it
-- -- and it is the right price, because a diff you can search on both
-- sides is a buffer that IS a patch, which is the thing the view exists
-- to avoid being.
--
-- So the old side gets a real buffer instead. It is the file at the
-- revision being compared against, whole, with the lines this branch
-- removed banded in red: searchable, yankable, and syntax-highlighted
-- like any other file. Opening it puts the cursor on the line answering
-- to the one you were on, and `<CR>` takes you back the same way, so the
-- two windows stay a pair rather than becoming two unrelated files.
--
-- Read-only on purpose. It is a revision, not a working copy, and an edit
-- there would have nowhere to go.

local config = require("uatis.config")
local git = require("uatis.git")
local overlay = require("uatis.overlay")
local ui = require("uatis.ui")

local M = {}

M.ns = vim.api.nvim_create_namespace("uatis_oldside")

-- old bufnr -> the in-place view it belongs to. The winbar expression
-- runs with only a window to go on, and the mappings need the view back.
local owners = {}

function M.view_for(bufnr)
  return owners[bufnr]
end

-- ------------------------------------------------------------------
-- Line correspondence
-- ------------------------------------------------------------------

--- How alike two lines are, for picking one line out of a block: the
--- length of what they start with in common, once indentation is off the
--- front. Indentation is exactly what a restructuring changes -- moving a
--- function into a class shifts every line of it -- so comparing with it
--- left on would score the very lines being looked for at zero.
local function affinity(a, b)
  a, b = a:gsub("^%s+", ""), b:gsub("^%s+", "")
  if #a < 3 or #b < 3 then
    return 0 -- `end`, `)`, a blank line: matches everything, means nothing
  end
  if a == b then
    return math.huge
  end
  local i = 0
  while i < #a and i < #b and a:byte(i + 1) == b:byte(i + 1) do
    i = i + 1
  end
  return i
end

--- The line on the other side answering to `row`.
---
--- Outside every hunk it is a matter of counting what was added and
--- removed above, and inside a hunk that pairs its two sides line for
--- line it is the line directly across. Neither holds inside a hunk that
--- does not pair up -- a file whose functions were moved into a class
--- comes back from the line backend as ONE hunk covering all of it, and
--- there is no line-for-line anything in there.
---
--- So the block is searched. Position gives the guess -- the same offset
--- from the top of the block -- and the text corrects it: the candidate
--- that starts with the most in common wins, with the positional guess
--- breaking ties. That finds `def test_area():` for `def
--- test_area(self):` sixteen rows into a block where counting alone
--- would have been a line out, and falls back to counting where the
--- text says nothing.
local function map_row(hunks, row, forward, from_lines, to_lines)
  local offset = 0
  for _, h in ipairs(hunks or {}) do
    local from_start = forward and h.start_b or h.start_a
    local from_count = forward and h.count_b or h.count_a
    local to_start = forward and h.start_a or h.start_b
    local to_count = forward and h.count_a or h.count_b

    if from_count > 0 and row < from_start then
      break
    end
    if from_count > 0 and row < from_start + from_count then
      if from_count == to_count then
        return to_start + (row - from_start)
      end
      if to_count == 0 then
        -- Nothing on the other side at all: the block was inserted here,
        -- so the row it follows is the closest true answer.
        return math.max(to_start, 1)
      end
      local guess = to_start + math.min(row - from_start, to_count - 1)
      local text = (from_lines or {})[row]
      if not text or not to_lines then
        return guess
      end
      local best, best_score = guess, 0
      for i = to_start, to_start + to_count - 1 do
        local score = affinity(text, to_lines[i] or "")
        if score > best_score
          or (score == best_score and score > 0
            and math.abs(i - guess) < math.abs(best - guess)) then
          best, best_score = i, score
        end
      end
      return best_score > 0 and best or guess
    end
    if from_count == 0 and row <= from_start then
      break
    end
    offset = offset + (to_count - from_count)
  end
  return row + offset
end

M.map_row = map_row

--- The lines of each side, as the mapping wants them: 1-based arrays.
---
--- Cached against the render count. Both sides are needed for every
--- mapped row, and a mapped row is wanted on every cursor movement --
--- splitting a file into lines twice per keypress is a cost that grows
--- with the file while the answer cannot change until the next render.
local function sides(view)
  local gen = view.renders or 0
  if not (view.side_cache and view.side_cache.gen == gen) then
    view.side_cache = {
      gen = gen,
      old = vim.split(view.old_text or "", "\n", { plain = true }),
      new = vim.api.nvim_buf_is_valid(view.bufnr)
        and vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false) or {},
    }
  end
  return view.side_cache.old, view.side_cache.new
end

--- The old-side line answering to `row` on the new side, and back again.
---
--- The backend's own alignment first, where it has one. difftastic aligns
--- the two files row by row and says which old row each new row answers
--- to; that is both exact and the same correspondence the marks are drawn
--- from, so the cursor lands where the rendering says it should. Working
--- it out from hunk shapes is what to do when nobody has said.
function M.old_row(view, row)
  -- Laid out, the answer is a row of this buffer and the buffer IS the
  -- alignment: row N of it stands for alignment row N, whether that is a
  -- line of the revision or a blank standing in for one of yours.
  if view.new_at then
    return view.new_at[row] or (view.align and #view.align) or row
  end
  local paired = view.pairs and view.pairs[row]
  if paired then
    return paired
  end
  local old_lines, new_lines = sides(view)
  return map_row(view.hunks, row, true, new_lines, old_lines)
end

function M.new_row(view, row)
  -- Laid out, `row` is an alignment row: the line across from it, or --
  -- where that side has none -- the next line it does have, which is
  -- where a reader pressing "take me to now" expects to arrive.
  if view.align then
    for i = row, #view.align do
      if view.align[i].new then
        return view.align[i].new
      end
    end
    return vim.api.nvim_buf_is_valid(view.bufnr)
      and vim.api.nvim_buf_line_count(view.bufnr) or 1
  end
  -- `anchor` is where the old row is DRAWN -- above its partner, or above
  -- the next new row there is one for -- which is exactly where a reader
  -- pressing "take me to now" expects to arrive.
  local at = view.anchor and view.anchor[row]
  if at then
    return at
  end
  local old_lines, new_lines = sides(view)
  return map_row(view.hunks, row, false, old_lines, new_lines)
end

local function clamp(bufnr, row)
  local n = vim.api.nvim_buf_line_count(bufnr)
  return math.max(1, math.min(row, n))
end

local function put_cursor(win, bufnr, row)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  vim.api.nvim_win_set_cursor(win, { clamp(bufnr, row), 0 })
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! zz")
  end)
end

-- ------------------------------------------------------------------
-- Marks
-- ------------------------------------------------------------------

--- The two sides interleaved, one entry per display row: the old row, the
--- new row, or both. What a diff tool means by "these lines are opposite
--- each other".
---
--- Built from the backend's row alignment where it has one, and from the
--- hunk shapes where it does not: outside a hunk the two files advance
--- together, and inside one the two blocks start opposite each other and
--- the shorter side runs out first, which is what every side-by-side diff
--- has always drawn.
--- True for a side with no content at all. An empty file has NO lines,
--- and a buffer showing one always reports one -- which matters here in
--- the same way it matters to `vim.diff`: counted as a line, the empty
--- side gets a row of the alignment, the other side's content is laid out
--- ABOVE it, and a window cannot be scrolled above its first line. A file
--- the branch deleted then has its whole content off the top of the
--- screen, which is the one file where that content is the point.
local function empty_side(lines)
  return #lines == 0 or (#lines == 1 and lines[1] == "")
end

function M.alignment(view)
  local old_lines = vim.split(view.old_text or "", "\n", { plain = true })
  local new_lines = vim.api.nvim_buf_is_valid(view.bufnr)
    and vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false) or {}
  local old_count = empty_side(old_lines) and 0 or #old_lines
  local new_count = empty_side(new_lines) and 0 or #new_lines
  local out, o = {}, 1

  local function take_old(upto)
    while o <= upto do
      table.insert(out, { old = o })
      o = o + 1
    end
  end

  if view.pairs then
    for n = 1, new_count do
      local p = view.pairs[n]
      if p and p >= o then
        take_old(p - 1)
        table.insert(out, { old = p, new = n })
        o = p + 1
      else
        table.insert(out, { new = n })
      end
    end
  else
    -- No alignment to follow: pair positionally, hunk by hunk.
    local hunks = vim.deepcopy(view.hunks or {})
    table.sort(hunks, function(a, b)
      return a.start_b < b.start_b or (a.start_b == b.start_b and a.start_a < b.start_a)
    end)
    local n = 1
    for _, h in ipairs(hunks) do
      -- Unchanged rows before the hunk advance in step. A pure deletion
      -- anchors AFTER the row it follows -- `start_b` is "the line after
      -- which content was removed" -- so that row is emitted first and
      -- the removed block goes under it.
      local upto = h.count_b > 0 and (h.start_b - 1) or h.start_b
      while n <= upto and o <= old_count do
        table.insert(out, { old = o, new = n })
        o, n = o + 1, n + 1
      end
      -- A deletion anchors AFTER the row it follows, so its old rows come
      -- once that row has been emitted, not before it.
      for i = 0, math.max(h.count_a, h.count_b) - 1 do
        local a = i < h.count_a and (h.start_a + i) or nil
        local b = i < h.count_b and (h.start_b + i) or nil
        if a or b then
          table.insert(out, { old = a, new = b })
        end
      end
      o = math.max(o, h.start_a + h.count_a)
      n = math.max(n, h.start_b + h.count_b)
    end
    while n <= new_count and o <= old_count do
      table.insert(out, { old = o, new = n })
      o, n = o + 1, n + 1
    end
    while n <= new_count do
      table.insert(out, { new = n })
      n = n + 1
    end
  end
  take_old(old_count)
  return out
end

--- The old side laid out to match: the revision's lines with a blank one
--- wherever the new side has lines it does not.
---
--- Real lines, not virtual ones. Virtual fillers are the obvious way and
--- they do not survive contact with scrolling: a block of them hanging
--- below the last line cannot be scrolled into at all -- not by
--- `topline`, not by `topfill`, not by `<C-e>` -- so a shorter old file
--- pinned its last line to the top of the window and sat there while the
--- new side scrolled on past it. A block bigger than the window is worse
--- again: the cursor has to be on a real line, so a window showing
--- nothing but fillers is a window Neovim will scroll somewhere else.
---
--- With real lines the old side is just a file the same length as the
--- alignment, and every row of it can be scrolled to and put a cursor on.
--- What it costs is the numbering, which `statuscolumn` puts back: the
--- gutter shows the revision's own line numbers, and nothing at all
--- beside a row that is not in it.
local function laid_out(view)
  local align = M.alignment(view)
  local old_lines = sides(view)
  local lines, of_row, at_line, new_at = {}, {}, {}, {}
  for i, e in ipairs(align) do
    lines[i] = e.old and (old_lines[e.old] or "") or ""
    if e.old then
      of_row[i] = e.old
      at_line[e.old] = i
    end
    if e.new then
      new_at[e.new] = i
    end
  end
  return align, lines, of_row, at_line, new_at
end

--- Replaces the buffer's lines, but only when they are not already what
--- they should be: rewriting them resets the window's view, and a redraw
--- on every keystroke would throw the reader's place away.
local function put_lines(bufnr, lines)
  local current = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if #current == #lines then
    local same = true
    for i = 1, #lines do
      if current[i] ~= lines[i] then
        same = false
        break
      end
    end
    if same then
      return false
    end
  end
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modified = false
  vim.bo[bufnr].modifiable = false
  return true
end

--- Blank rows for YOUR buffer, where the old side has lines it does not.
--- Virtual here, because this is a file you are editing and blank lines
--- punched into it would be an edit. The limits above apply, and are why
--- the alignment is driven from this window rather than the other one:
--- what cannot be scrolled into on this side is never asked for.
local function pad(bufnr, win, before, tail)
  local count = vim.api.nvim_buf_line_count(bufnr)
  local width = (win and vim.api.nvim_win_is_valid(win))
    and vim.api.nvim_win_get_width(win) or 40
  -- The character comes from `fillchars` so it matches whatever the
  -- reader has diff mode set to.
  local char = (vim.opt.fillchars:get() or {}).diff or "-"
  local line = { { string.rep(char, width), "UatisFiller" } }

  local function block(n)
    local virt = {}
    for _ = 1, n do
      table.insert(virt, line)
    end
    return virt
  end

  for row, n in pairs(before) do
    if row >= 1 and row <= count then
      vim.api.nvim_buf_set_extmark(bufnr, M.ns, row - 1, 0, {
        virt_lines = block(n),
        virt_lines_above = true,
        virt_lines_leftcol = true,
        priority = 90,
      })
    end
  end
  if tail > 0 and count > 0 then
    vim.api.nvim_buf_set_extmark(bufnr, M.ns, count - 1, 0, {
      virt_lines = block(tail),
      virt_lines_leftcol = true,
      priority = 90,
    })
  end
end

--- Where the new side needs blank rows: one per alignment row that the
--- old side has and it does not, counted up to the row they go above.
local function new_fillers(align)
  local before, pending, tail = {}, 0, 0
  for _, e in ipairs(align) do
    if e.new then
      before[e.new] = pending > 0 and pending or nil
      pending = 0
    else
      pending = pending + 1
    end
  end
  tail = pending
  return before, tail
end

--- What the old buffer is called: which revision of which file it holds.
local function old_name(view)
  return string.format("uatis://%s/%s", view.ref, view.old_path or view.relpath)
end

--- Bands the lines this branch removed, and -- side by side -- pads both
--- windows so the two sides line up row for row.
---
--- The band is background only, and no strikethrough: everything in this
--- buffer is the old side, so struck-through text would say nothing while
--- making every line harder to read -- and this is the window you came to
--- in order to READ the old code. The red says which of it is gone.
function M.refresh(view)
  local old = view.old
  if not (old and vim.api.nvim_buf_is_valid(old.buf)) then
    return
  end

  -- The name carries the ref, and the ref moves under an open window when
  -- the base branch is changed. Left alone, `:ls` and the tabline would go
  -- on naming the revision this window stopped showing.
  if old.ref ~= view.ref then
    old.ref = view.ref
    pcall(vim.api.nvim_buf_set_name, old.buf, old_name(view))
  end

  -- Side by side, the buffer holds the revision laid out against your
  -- side; on its own it holds the revision, plainly. Both are rebuilt
  -- from the same text, so switching layouts is just a relayout.
  local of_row, at_line, new_at = nil, nil, nil
  if view.layout == "side" then
    local align, lines
    align, lines, of_row, at_line, new_at = laid_out(view)
    put_lines(old.buf, lines)
    view.align = align
  else
    view.align = nil
    put_lines(old.buf, sides(view))
  end
  view.old_of_row, view.old_at_line, view.new_at = of_row, at_line, new_at

  vim.api.nvim_buf_clear_namespace(old.buf, M.ns, 0, -1)
  if vim.api.nvim_buf_is_valid(view.bufnr) then
    vim.api.nvim_buf_clear_namespace(view.bufnr, M.ns, 0, -1)
  end

  --- The revision's line `n`, as a row of this buffer.
  local function row_of(n)
    return (at_line and at_line[n] or n) - 1
  end

  local count = vim.api.nvim_buf_line_count(old.buf)
  local function row_text(row)
    return vim.api.nvim_buf_get_lines(old.buf, row, row + 1, false)[1] or ""
  end

  if view.del_spans then
    -- Token by token, as difftastic reported it. Its own display tints
    -- the words it called changed and leaves the rest of the line in
    -- ordinary colour -- including a line inside a changed region that
    -- came through untouched -- and this window is that column.
    --
    -- Keyed by ROW rather than by revision line from here on: laid out
    -- against the other side, a line of the revision sits wherever its
    -- partner put it, and the blank rows between are what make the two
    -- windows scroll together. The prose pass reads rows, and reads the
    -- blank ones as the gaps inside a node rather than as its end.
    local spans_by_row, fine_by_row = {}, {}
    for line, spans in pairs(view.del_spans) do
      local row = row_of(line)
      if row >= 0 and row < count then
        spans_by_row[row] = spans
        fine_by_row[row] = (view.del_fine or {})[line]
      end
    end

    -- Which of those rows are prose, and which words of them actually
    -- went away: the same statement the new side makes, made about the
    -- side it was taken from. A removed docstring reports every word
    -- removed, so without this the old window answers a reworded
    -- sentence with a solid red block.
    local marks = overlay.prose_marks(spans_by_row, row_text, function(row)
      return fine_by_row[row]
    end, view.prose)

    for row, spans in pairs(spans_by_row) do
      local text = row_text(row)
      local p = marks[row]
      if p and p.narrowed and p.full then
        -- The atom is the row, so the row steps back and the words that
        -- went keep the red -- the new side's rule, in the new side's
        -- colours' opposite number.
        overlay.paint_row(old.buf, M.ns, row, "UatisDeleteBandDim", p.fine,
          text, count, "UatisDeleteBand")
      elseif overlay.covers_all(spans, text) then
        -- A line every token of which went is a line that went.
        vim.api.nvim_buf_set_extmark(old.buf, M.ns, row, 0, {
          line_hl_group = "UatisDeleteBand",
          priority = 100,
        })
      else
        for _, span in ipairs(overlay.joined(spans, text)) do
          local s2 = math.min(span.col_start, #text)
          local e2 = math.min(span.col_end, #text)
          if e2 > s2 then
            vim.api.nvim_buf_set_extmark(old.buf, M.ns, row, s2, {
              end_col = e2,
              hl_group = "UatisDeleteBand",
              priority = 100,
            })
          end
        end
        -- ...and an atom sharing its line with code steps back inside
        -- its own columns, over the marks just drawn.
        for _, r in ipairs((p and p.narrowed) and p.quiet or {}) do
          local s2 = math.min(r.col_start, #text)
          local e2 = math.min(r.col_end, #text)
          if e2 > s2 then
            vim.api.nvim_buf_set_extmark(old.buf, M.ns, row, s2, {
              end_col = e2,
              hl_group = "UatisDeleteBandDim",
              priority = 110,
            })
          end
        end
      end
    end
  else
    -- A line backend knows lines and nothing finer, so the line is what
    -- it marks.
    for _, h in ipairs(view.hunks or {}) do
      for i = 0, h.count_a - 1 do
        local row = row_of(h.start_a + i)
        if row >= 0 and row < count then
          vim.api.nvim_buf_set_extmark(old.buf, M.ns, row, 0, {
            line_hl_group = "UatisDeleteBand",
            priority = 100,
          })
        end
      end
    end
  end

  if view.layout ~= "side" then
    return
  end

  -- The rows of the laid-out buffer that stand for nothing in the
  -- revision, drawn as blanks rather than left empty: a run of empty rows
  -- in the middle of a file reads as part of the code, and these are
  -- "nothing here, look across".
  local width = vim.api.nvim_win_is_valid(old.win)
    and vim.api.nvim_win_get_width(old.win) or 40
  local char = (vim.opt.fillchars:get() or {}).diff or "-"
  for row = 0, count - 1 do
    if not of_row[row + 1] then
      vim.api.nvim_buf_set_extmark(old.buf, M.ns, row, 0, {
        virt_text = { { string.rep(char, width), "UatisFiller" } },
        virt_text_pos = "overlay",
        virt_text_win_col = 0,
        priority = 90,
      })
    end
  end

  local before, tail = new_fillers(view.align)
  pad(view.bufnr, view.win, before, tail)

  -- How wide the other window's gutter is, for `number()` to match. Read
  -- here rather than there because it costs a window query and the answer
  -- is the same for every row of a redraw.
  local info = vim.api.nvim_win_is_valid(view.win) and vim.fn.getwininfo(view.win)[1]
  view.gutter = info and info.textoff or nil
end

-- ------------------------------------------------------------------
-- Lifetime
-- ------------------------------------------------------------------

function M.close(view)
  local old = view.old
  view.old = nil
  if not old then
    return
  end
  owners[old.buf] = nil
  -- The fillers live in the buffer you are editing, so they have to go
  -- when the window they were lining up with does -- and so does the
  -- wrapping this turned off.
  if vim.api.nvim_buf_is_valid(view.bufnr) then
    vim.api.nvim_buf_clear_namespace(view.bufnr, M.ns, 0, -1)
  end
  if old.wrap ~= nil and view.win and vim.api.nvim_win_is_valid(view.win) then
    vim.wo[view.win].wrap = old.wrap
  end
  if old.win and vim.api.nvim_win_is_valid(old.win) then
    -- Never the last window: closing it would take the editor down with
    -- it, and this window is an accessory to one that is still open.
    if #vim.api.nvim_tabpage_list_wins(0) > 1 then
      pcall(vim.api.nvim_win_close, old.win, true)
    end
  end
  if vim.api.nvim_buf_is_valid(old.buf) then
    pcall(vim.api.nvim_buf_delete, old.buf, { force = true })
  end
end

function M.is_open(view)
  local old = view.old
  return old ~= nil and vim.api.nvim_buf_is_valid(old.buf)
    and old.win ~= nil and vim.api.nvim_win_is_valid(old.win)
end

local function setup_keymaps(view, buf)
  local k = config.keys.old
  local function map(lhs, rhs, desc)
    if lhs and lhs ~= "" then
      vim.keymap.set("n", lhs, rhs, {
        buffer = buf, nowait = true, silent = true, desc = desc,
      })
    end
  end
  map(k.quit, function()
    local win = view.win
    M.close(view)
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_current_win(win)
    end
  end, "uatis: close the old revision")
  map(k.jump, function()
    if not (view.win and vim.api.nvim_win_is_valid(view.win)) then
      return
    end
    local row = vim.api.nvim_win_get_cursor(0)[1]
    vim.api.nvim_set_current_win(view.win)
    put_cursor(view.win, view.bufnr, M.new_row(view, row))
  end, "uatis: jump to the line this became")
end

local function fill(view, text)
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = vim.split(text, "\n", { plain = true })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modified = false
  vim.bo[buf].modifiable = false
  -- Named for what it is, so `:ls`, the tabline and a stray `<C-^>` all
  -- say which revision of which file this is rather than "[Scratch]".
  -- Two views of the same file at the same ref cannot both be open, so
  -- the name cannot collide with itself; pcall covers a buffer the user
  -- happens to have named this by hand.
  pcall(vim.api.nvim_buf_set_name, buf, old_name(view))
  -- Matched on the PATH, not the buffer name: the name is a URL and no
  -- filetype pattern would recognise it, and the point of a real buffer
  -- is that the old code is highlighted like code.
  vim.bo[buf].filetype = vim.filetype.match({
    filename = view.old_path or view.relpath,
    contents = lines,
  }) or ""
  return buf
end

--- Moves the old window's cursor to the line answering to `row`, without
--- taking focus, and puts its first visible line opposite the first
--- visible line here. What keeps the two windows a pair while you read
--- down one of them.
---
--- Both halves are needed. The cursor alone leaves the two windows
--- scrolled independently -- a line and the line it replaced end up on
--- different rows of the screen, which is the one thing a side-by-side
--- layout exists to avoid. The top alone would leave the cursor behind.
---
--- `scrollbind` does neither: it pairs windows by screen line, and with
--- the two files different lengths it drifts by exactly as much as the
--- change is worth looking at. The alignment is what says which rows are
--- opposite each other, so the alignment is what drives this.
function M.sync(view, row)
  if not M.is_open(view) then
    return
  end
  if not (view.win and vim.api.nvim_win_is_valid(view.win)) then
    return
  end

  local here = vim.api.nvim_win_call(view.win, function()
    return vim.fn.winsaveview()
  end)

  -- The two sides' code has to start in the same screen column, and what
  -- decides that is the width of each window's gutter. Corrected from
  -- what the two windows actually render rather than computed: a sign
  -- column set to `auto` appears and disappears with the signs in it, and
  -- a `statuscolumn` does not report the width its own text takes. One
  -- keypress of lag, and self-correcting whatever the two gutters are
  -- made of.
  local mine = vim.fn.getwininfo(view.win)[1]
  local theirs = vim.fn.getwininfo(view.old.win)[1]
  if mine and theirs and mine.textoff ~= theirs.textoff then
    view.gutter = math.max(math.min((view.gutter or 4)
      + (mine.textoff - theirs.textoff), 16), 2)
  end

  local lnum, topline
  if view.new_at then
    -- Both windows now count in the same rows, so the top of one is the
    -- top of the other. `topfill` is how far into a block of blanks this
    -- window has scrolled -- those blanks are alignment rows too, and the
    -- old side has real lines standing for them.
    lnum = M.old_row(view, row)
    topline = (view.new_at[here.topline] or 1) - (here.topfill or 0)
  else
    lnum = M.old_row(view, row)
    topline = M.old_row(view, here.topline)
  end
  lnum, topline = clamp(view.old.buf, lnum), clamp(view.old.buf, topline)

  -- One view change, not two. Moving the cursor and then correcting the
  -- scroll -- worse, correcting it a tick later -- draws the old window
  -- twice per keypress, and the intermediate frame is a jump to a
  -- different part of the file. That is the flicker.
  vim.api.nvim_win_call(view.old.win, function()
    local v = vim.fn.winsaveview()
    if v.lnum == lnum and v.topline == topline then
      return -- nothing moved; drawing again would be the flicker itself
    end
    v.lnum, v.col, v.curswant, v.topline = lnum, 0, 0, topline
    vim.fn.winrestview(v)
  end)
end

--- The revision's own line number for a row of the laid-out buffer, for
--- `statuscolumn` -- blank where the row stands for a line the revision
--- does not have. Without this the gutter would number the layout, and
--- the numbers a reader takes from this window would belong to nothing.
function M.number()
  -- By buffer, not by window: `g:statusline_winid` is set while a
  -- statusline is drawn and NOT while a status COLUMN is, but the buffer
  -- being drawn is current either way -- and this mapping belongs to the
  -- buffer.
  local view = owners[vim.api.nvim_get_current_buf()]
  if not view then
    return "%l "
  end
  -- As wide as the other window's gutter, so the two sides' CODE starts
  -- in the same screen column. Otherwise a number column of a different
  -- width -- or the signs a plugin puts beside your own buffer and not
  -- beside a scratch copy of a revision -- shifts one side against the
  -- other, and lines that are opposite each other do not look it.
  local width = math.max(view.gutter or 4, 2)
  local n = view.old_of_row and view.old_of_row[vim.v.lnum] or nil
  if not view.old_of_row then
    n = vim.v.lnum -- not laid out: rows are lines
  end
  return n and string.format("%" .. (width - 1) .. "d ", n)
    or string.rep(" ", width)
end

--- Puts the old revision up beside the buffer, or re-syncs it if it is
--- already there.
---
--- It goes to the LEFT, because that is the order every diff has ever
--- been written in and the order the two ref names are read in. The
--- cursor stays where it was: this half is something to SEE while you
--- carry on reading -- and editing -- your own.
function M.open(view, opts)
  opts = opts or { focus = false }
  if not (view.win and vim.api.nvim_win_is_valid(view.win)) then
    return
  end
  local row = vim.api.nvim_win_get_cursor(view.win)[1]

  if M.is_open(view) then
    M.sync(view, row)
    return
  end

  local function show(text)
    -- Required at call time, not at load: `inline` requires this module,
    -- and asking for it at the top would be a cycle. By the time anyone
    -- can press the key, both halves are loaded.
    local live = vim.api.nvim_buf_is_valid(view.bufnr)
      and require("uatis.view").get(view.bufnr) == view
    if not (live and view.win and vim.api.nvim_win_is_valid(view.win)) then
      return
    end
    local buf = fill(view, text)
    local rows = vim.api.nvim_buf_line_count(buf)
    local win = vim.api.nvim_open_win(buf, false, {
      split = "left",
      win = view.win,
    })
    vim.wo[win].winbar = ui.OLD_WINBAR
    vim.wo[win].number = vim.wo[view.win].number
    vim.wo[win].relativenumber = false
    if vim.wo[win].number then
      vim.wo[win].statuscolumn = "%{%v:lua.require'uatis.oldside'.number()%}"
    end
    vim.wo[win].foldcolumn = "0"
    vim.wo[win].signcolumn = "no"
    vim.wo[win].wrap = false

    -- Wrapping breaks the alignment, so it goes off on both sides while
    -- they are paired -- the same thing diff mode does, for the same
    -- reason. A wrapped line takes two screen rows and the blank opposite
    -- it takes one, and everything below them is a row out. Put back when
    -- the window goes.
    local wrapped = vim.wo[view.win].wrap
    vim.wo[view.win].wrap = false
    view.old = { buf = buf, win = win, rows = rows, wrap = wrapped, ref = view.ref }
    owners[buf] = view
    setup_keymaps(view, buf)
    M.refresh(view)
    -- Aligned on the way in, not on the first cursor movement. Placing the
    -- cursor alone leaves the two windows scrolled independently, so a
    -- view opened anywhere but the top of the file comes up misaligned and
    -- corrects itself only when the reader moves -- which reads as a bug,
    -- because it is one.
    M.sync(view, row)

    -- The window may be closed by anything -- `:only`, `:q`, a layout
    -- plugin -- and the view has to notice, or the next press would
    -- re-sync a window that is gone.
    vim.api.nvim_create_autocmd("WinClosed", {
      pattern = tostring(win),
      once = true,
      callback = function()
        if view.old and view.old.win == win then
          owners[view.old.buf] = nil
          view.old = nil
        end
      end,
    })
  end

  -- Usually already here: every render keeps the text it diffed against,
  -- and git.blob caches besides. Fetched only when the split is opened
  -- before the first render has landed.
  if view.old_text then
    show(view.old_text)
  else
    git.blob(view.root, view.rev, view.old_path or view.relpath, function(text)
      show(text or "")
    end)
  end
end

return M
