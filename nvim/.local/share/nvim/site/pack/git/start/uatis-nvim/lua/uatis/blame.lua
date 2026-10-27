-- Who wrote each line, drawn on the buffer you are editing: the commit
-- that last touched a run of lines, named in a column of the gutter at
-- the run's first row and bracketed down the rest of it.
--
-- A sibling of `view.lua` and `conflict.lua`, not a mode of either: no
-- revision is measured against and nothing is compared. What it shares
-- with them is the premise -- the reader's own buffer, still writable,
-- annotated in place rather than copied into a scratch buffer of
-- `sha author | code` the way a blame usually is. The buffer is handed
-- to git as it stands (`git.blame`'s `--contents -`), so an unsaved edit
-- is blamed as one and every row git answers about is a row on screen.
--
-- One sha per RUN of lines from one commit, not one per line: a column
-- of the same sha forty rows deep is read as noise and then not read at
-- all. Where the run stops is the bracket's job, and the colour's: each
-- commit has one of the colourscheme's own syntax colours, and is not
-- handed the one the run above it wears. The run under the cursor is
-- drawn in bold with a heavier bracket, so the lines a sha is about are
-- read off the gutter rather than counted.
--
-- Nothing is drawn past the end of a line. An author and a subject on
-- every run's first row was a second column of text beside the code, and
-- the code is what the reader came to; who and why is one key away
-- (`details`), where there is room for all of it.
--
-- The gutter is 'statuscolumn', since a sign is two cells and a sha is
-- seven. Ours is put IN FRONT of whatever the window had, never in its
-- place, and what it had is put back when the blame goes: a reader's
-- statuscolumn is configuration, and this is a mode.

local config = require("uatis.config")
local git = require("uatis.git")
local keys = require("uatis.keys")
local syntax = require("uatis.syntax")
local ui = require("uatis.ui")

local M = {}

-- bufnr -> state. The runs are the buffer's; the column is drawn per
-- window, from whichever buffer that window shows.
local blames = {}

-- win -> the 'statuscolumn' it had before ours was put in front of it.
local worn = {}

M.ns = vim.api.nvim_create_namespace("uatis_blame")

local EXPR = "%{%v:lua.require'uatis.blame'.column()%}"
-- What a window with no 'statuscolumn' draws: folds, signs, the number.
local PLAIN = "%C%s%l%{&nu||&rnu?' ':''}"

-- The colourscheme groups a commit's colour is taken from, in order.
local SOURCES = { "Function", "String", "Type", "Constant", "Statement", "Special",
  "Identifier", "PreProc" }
local colours = 0

function M.get(bufnr)
  local b = blames[bufnr]
  if b and not vim.api.nvim_buf_is_valid(bufnr) then
    blames[bufnr] = nil
    return nil
  end
  return b
end

--- One group per distinct foreground the scheme gives `SOURCES`, plus a
--- bold one of each for the run under the cursor. The scheme's own
--- colours because they are the ones already chosen to sit on this
--- background; distinct, because two groups linked to one colour would
--- make two neighbouring runs one.
function M.setup_highlights()
  vim.api.nvim_set_hl(0, "UatisBlame", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "UatisBlameUncommitted", { link = "UatisPlus", default = true })
  vim.api.nvim_set_hl(0, "UatisBlameGutter", { link = "CursorLine", default = true })
  vim.api.nvim_set_hl(0, "UatisBlameRule", { link = "WinSeparator", default = true })
  local seen, fgs = {}, {}
  for _, name in ipairs(SOURCES) do
    local fg = vim.api.nvim_get_hl(0, { name = name, link = false }).fg
    if fg and not seen[fg] then
      seen[fg] = true
      table.insert(fgs, fg)
    end
  end
  colours = math.max(#fgs, 1)
  for i = 1, colours do
    local spec = fgs[i] and { fg = fgs[i] } or { link = "Comment" }
    vim.api.nvim_set_hl(0, "UatisBlame" .. i, spec)
    vim.api.nvim_set_hl(0, "UatisBlame" .. i .. "Current",
      fgs[i] and { fg = fgs[i], bold = true } or { link = "CursorLineNr" })
  end
end

-- ------------------------------------------------------------------
-- Drawing
-- ------------------------------------------------------------------

--- A colour for each commit, the first time it is met going down the
--- file: the one used longest ago that the run above is not wearing.
--- A commit met again further down keeps its colour, since one colour
--- for one commit is what lets a reader see it come back.
local function assign(runs)
  local of, last_used, prev, clock = {}, {}, nil, 0
  for _, r in ipairs(runs) do
    local sha = r.commit.sha
    if not r.commit.uncommitted and not of[sha] then
      local best
      for i = 1, colours do
        if i ~= prev and (not best or (last_used[i] or 0) < (last_used[best] or 0)) then
          best = i
        end
      end
      of[sha] = best or 1
    end
    if of[sha] then
      clock = clock + 1
      last_used[of[sha]] = clock
    end
    prev = of[sha]
  end
  return of
end

local function colour(b, r, current)
  if r.commit.uncommitted then
    return "UatisBlameUncommitted"
  end
  return "UatisBlame" .. (b.colour[r.commit.sha] or 1) .. (current and "Current" or "")
end

local function run_at(b, row)
  local i = b.by_row[row]
  if i then
    return i, b.runs[i]
  end
end

-- Brackets drawn side by side before the deepest are given up on.
local DEPTH = 4

local function newer(c, than)
  if c.uncommitted then
    return not than.uncommitted
  end
  return not than.uncommitted and (c.time or 0) > (than.time or 0)
end

--- Runs of one commit joined into GROUPS, each drawn as one bracket: two
--- runs of a commit are one where every line between them is newer --
--- the commit's block, edited later in the middle, and the reader asking
--- whether the lines either side of the edit belong together. An older
--- line between them means the commit was not there; they are two.
---
--- Joined that way, two groups never half overlap: a group starts and
--- ends on its own commit's lines and holds only newer ones between, so
--- another group either sits inside one of its gaps (and is newer) or
--- clear of it. That is what lets each be drawn one column right of
--- the group around it, newest furthest right.
---
--- Sets `r.group` on every run; returns the groups, each `{ commit,
--- from, to, depth, parent }`, and the deepest depth there is.
local function nest(runs)
  local groups, last, deepest = {}, {}, 0
  for i, r in ipairs(runs) do
    local c, g = r.commit, nil
    local j = last[c.sha]
    if j then
      g = runs[j].group
      for k = j + 1, i - 1 do
        if not newer(runs[k].commit, c) then
          g = nil
          break
        end
      end
    end
    if g then
      g.to = r.to
    else
      g = { commit = c, from = r.from, to = r.to }
      table.insert(groups, g)
    end
    r.group = g
    last[c.sha] = i
  end
  local open = {}
  for _, g in ipairs(groups) do
    while #open > 0 and open[#open].to < g.from do
      table.remove(open)
    end
    g.parent, g.depth = open[#open], #open
    deepest = math.max(deepest, g.depth)
    table.insert(open, g)
  end
  return groups, deepest
end

--- The first letter of each word of `name`, at most three: `TG` for
--- Theo Gilbert -- enough to tell the people of one file apart.
local function initials(name)
  local out = {}
  for word in (name or ""):gmatch("[^%s%.%-_]+") do
    table.insert(out, vim.fn.strcharpart(word, 0, 1):upper())
  end
  return table.concat(out, "", 1, math.min(#out, 3))
end

local function pad(text, n)
  return text .. string.rep(" ", n - vim.fn.strdisplaywidth(text))
end

--- What names a run's commit in the column: when and who -- a sha says
--- neither, and was read only to be looked up. Not what it says: twenty
--- characters of subject tripled the column for a clue `gK` answers
--- whole. Each field padded to the widest of the buffer's runs, so the
--- brackets stand in one column; a line not committed is `new`.
local function labels(runs)
  local fields, width = {}, { 0, 0 }
  for _, r in ipairs(runs) do
    local c = r.commit
    if not fields[c.sha] then
      local f = c.uncommitted and { "new", "" }
        or { c.time and ui.days_ago(c.time) or "", initials(c.author) }
      fields[c.sha] = f
      for i, v in ipairs(f) do
        width[i] = math.max(width[i], vim.fn.strdisplaywidth(v))
      end
    end
  end
  local out, total = {}, 0
  for sha, f in pairs(fields) do
    out[sha] = pad(f[1], width[1]) .. " " .. pad(f[2], width[2])
  end
  for i = 1, 2 do
    total = total + width[i]
  end
  return out, total + 1
end

--- The gutter cell of `lnum` in `win`, which shows `buf`: the label on
--- a run's first row, blank under it, then one column per depth of
--- nesting -- each group around the row a `│` in its own colour, and the
--- row's own group its piece, a corner or a resumption drawn out to the
--- column's edge with `─` so the eye can follow it to the code. Past
--- `DEPTH` the row is that many `─`, the outer brackets given up rather
--- than the column widened. `virtnum` is 'statuscolumn''s own: past 0 a
--- wrapped part of the row, below it a virtual line above it, and either
--- carries the `│` of every group that goes on past it.
function M.cell(buf, win, lnum, virtnum)
  local b = blames[buf]
  if not b then
    return ""
  end
  local cols = b.cols or 1
  local blank = string.rep(" ", (b.label_width or 0) + cols + 2)
  local i, r = run_at(b, lnum)
  if not r then
    return blank
  end
  local own = r.group
  local ok, cur = pcall(vim.api.nvim_win_get_cursor, win)
  local at = ok and b.by_row[cur[1]]
  local current_group = at and b.runs[at].group
  local function hl(g)
    local c = g.commit
    if c.uncommitted then
      return "UatisBlameUncommitted"
    end
    return "UatisBlame" .. (b.colour[c.sha] or 1) .. (g == current_group and "Current" or "")
  end
  local function marks(g)
    local m = config.marker.blame
    return g == current_group and m.current or m
  end

  local cells = {}
  for d = 1, cols do
    cells[d] = { " ", nil }
  end
  if own.depth >= DEPTH then
    if virtnum == 0 then
      for d = 1, cols do
        cells[d] = { marks(own).fill, hl(own) }
      end
    end
  else
    local g = own
    while g do
      local m = marks(g)
      local piece
      if virtnum ~= 0 then
        piece = ((virtnum > 0 and lnum < g.to) or (virtnum < 0 and lnum > g.from)) and m.mid or " "
      elseif g ~= own then
        piece = m.mid
      elseif g.from == g.to then
        piece = m.single
      elseif lnum == g.from then
        piece = m.first
      elseif lnum == g.to then
        piece = m.last
      elseif lnum == r.from then
        piece = m.resume
      else
        piece = m.mid
      end
      cells[g.depth + 1] = { piece, hl(g) }
      g = g.parent
    end
    if virtnum == 0 and (lnum == r.from or lnum == own.to) then
      for d = own.depth + 2, cols do
        cells[d] = { marks(own).fill, hl(own) }
      end
    end
  end

  local name = string.rep(" ", b.label_width)
  if virtnum == 0 and lnum == r.from then
    name = b.labels[r.commit.sha]
  end
  local out = { "%#", hl(own), "#", name, " " }
  for _, c in ipairs(cells) do
    if c[2] then
      table.insert(out, "%#" .. c[2] .. "#" .. c[1])
    else
      table.insert(out, "%*" .. c[1])
    end
  end
  table.insert(out, "%* ")
  return table.concat(out)
end

--- `g:statusline_winid` is set only where the whole option is a `%!`
--- expression, and ours is a `%{%...%}` item so it can stand in front of
--- the reader's own. An item is evaluated with the window being drawn
--- made current, which is the answer it would have given.
function M.column()
  local win = vim.g.statusline_winid or vim.api.nvim_get_current_win()
  local ok, buf = pcall(vim.api.nvim_win_get_buf, win)
  if not ok then
    return ""
  end
  return M.cell(buf, win, vim.v.lnum, vim.v.virtnum)
end

--- Our column put in front of `win`'s, or taken off it, as the buffer
--- it shows is blamed or not. A window split from one wearing it has
--- copied the expression without being in `worn`, which is why what it
--- had is read with ours stripped off the front.
local function sync(win)
  if not vim.api.nvim_win_is_valid(win) then
    worn[win] = nil
    return
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local now = vim.wo[win].statuscolumn
  if blames[buf] then
    if worn[win] == nil then
      local was = now:sub(1, #EXPR) == EXPR and now:sub(#EXPR + 1) or now
      if was == PLAIN then
        was = ""
      end
      worn[win] = was
      vim.wo[win].statuscolumn = EXPR .. (was ~= "" and was or PLAIN)
    end
  elseif worn[win] ~= nil or now:sub(1, #EXPR) == EXPR then
    local was = worn[win]
    if was == nil then
      was = now:sub(#EXPR + 1)
      was = was == PLAIN and "" or was
    end
    worn[win] = nil
    vim.wo[win].statuscolumn = was
  end
end

local watching = false
local function watch_windows()
  if watching then
    return
  end
  watching = true
  local group = vim.api.nvim_create_augroup("UatisBlameWindows", { clear = true })
  vim.api.nvim_create_autocmd({ "BufWinEnter", "WinNew" }, {
    group = group,
    callback = function()
      vim.schedule(function()
        for _, win in ipairs(vim.api.nvim_list_wins()) do
          sync(win)
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(ev)
      worn[tonumber(ev.match)] = nil
    end,
  })
end

local function redraw_column(b)
  for _, win in ipairs(vim.fn.win_findbuf(b.bufnr)) do
    pcall(vim.api.nvim__redraw, { win = win, statuscolumn = true })
  end
end

--- The window above the blamed one that keeps the run under the cursor
--- described -- the head of `gK`'s card and the subject, so the gutter's `3 days
--- ago FA` is answered without a key per run. A split rather than a
--- float: it is there the whole time the blame is, and a float would sit
--- over the code it describes. Redrawn when the cursor enters another
--- run, not on every move; `q` in it puts it away for this blame.
local pane = {}
-- Header, committer's date, subject: one height for every run, so the
-- code below does not jump as the cursor goes from run to run.
local PANE_ROWS = 3
-- Below, beside the float that shares them.
local card, facts

local function pane_open(b)
  return b.pane and vim.api.nvim_win_is_valid(b.pane)
end

function pane.close(b)
  if pane_open(b) then
    b.closing_pane = true
    pcall(vim.api.nvim_win_close, b.pane, true)
    b.closing_pane = nil
  end
  b.pane = nil
end

--- The pane's text starts in the column the code does: a gutter of
--- blanks as wide as the blamed window's whole one -- our column, the
--- reader's numbers and signs -- so a subject reads over the code it
--- describes rather than out at the edge of the screen. Measured off
--- the window as last drawn, so a column that has just widened is
--- caught up with on the next move.
function pane.align(b)
  if not (pane_open(b) and b.pane_code and vim.api.nvim_win_is_valid(b.pane_code)) then
    return
  end
  local info = vim.fn.getwininfo(b.pane_code)[1]
  local n = info and info.textoff or 0
  -- Filled, not left blank: three rows of empty margin read as a gap in
  -- the layout rather than as the gutter the code's is. All but its
  -- last cell, which is the space before the text, as in the code's.
  local gutter = n > 0 and ("%#UatisBlameGutter#" .. string.rep(" ", n - 1) .. "%* ") or ""
  if vim.wo[b.pane].statuscolumn ~= gutter then
    vim.wo[b.pane].statuscolumn = gutter
  end
end

local function pane_lines(b, lines, marks)
  local buf = vim.api.nvim_win_get_buf(b.pane)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  for at, hl in pairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, M.ns, at - 1, 0, {
      end_row = at - 1, end_col = #lines[at], hl_group = hl })
  end
  pcall(vim.api.nvim_win_set_height, b.pane, PANE_ROWS)
  pane.align(b)
  pcall(vim.api.nvim_win_set_cursor, b.pane, { 1, 0 })
end

--- Whether `pane` sits directly over `code`: the two one after the other
--- in one column of the layout.
local function sits_over(pane_win, code)
  local function walk(node)
    if node[1] == "leaf" then
      return false
    end
    for i, child in ipairs(node[2]) do
      if node[1] == "col" and child[1] == "leaf" and child[2] == pane_win then
        local below = node[2][i + 1]
        return below ~= nil and below[1] == "leaf" and below[2] == code
      end
      if walk(child) then
        return true
      end
    end
    return false
  end
  local tab = vim.api.nvim_win_get_tabpage(pane_win)
  return walk(vim.fn.winlayout(vim.api.nvim_tabpage_get_number(tab)))
end

--- The pane kept over the window it was opened above, and over that one
--- alone: a `:split` of it opens a window between the two, which put the
--- pane over a whole column of the buffer. Moved back on top of its own
--- window where the layout has come between them; handed to another
--- window of the buffer where its own has gone or shows another file,
--- and closed where there is none.
function pane.place(b)
  if not pane_open(b) then
    return
  end
  local code = b.pane_code
  local tab = vim.api.nvim_win_get_tabpage(b.pane)
  if not (code and vim.api.nvim_win_is_valid(code) and vim.api.nvim_win_get_buf(code) == b.bufnr
      and vim.api.nvim_win_get_tabpage(code) == tab) then
    code = nil
    local now = vim.api.nvim_get_current_win()
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      if vim.api.nvim_win_get_buf(w) == b.bufnr and (not code or w == now) then
        code = w
      end
    end
    if not code then
      return pane.close(b)
    end
    b.pane_code = code
  end
  if not sits_over(b.pane, code) then
    pcall(vim.fn.win_splitmove, b.pane, code, { vertical = false, rightbelow = false })
    pcall(vim.api.nvim_win_set_height, b.pane, PANE_ROWS)
  end
  pane.align(b)
end

--- Opened above `win` where the blame wants one and the reader has not
--- put it away.
function pane.open(b, win)
  if pane_open(b) or not config.blame.pane or b.pane_dismissed then
    return
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  local w = vim.api.nvim_open_win(buf, false, {
    split = "above", win = win, height = PANE_ROWS,
  })
  -- A split copies the window it came from, our column in front of the
  -- reader's included.
  for k, v in pairs({ number = false, relativenumber = false, signcolumn = "no",
    foldcolumn = "0", statuscolumn = "", cursorline = false, spell = false,
    list = false, wrap = true, winfixheight = true, winbar = "",
    -- A split always has a status line while 'laststatus' is 2, and this
    -- window has nothing to put on one. A blank row there hid the bar
    -- and left the gap; a thin rule says where the pane ends and keeps
    -- it with the code under it, as a full status bar between them does
    -- not.
    statusline = "%#UatisBlameRule#%=",
    fillchars = "stl:─,stlnc:─",
    winhighlight = "StatusLine:Normal,StatusLineNC:Normal" }) do
    vim.wo[w][k] = v
  end
  b.pane = w
  b.pane_code = win
  b.pane_run = nil
  for _, lhs in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", lhs, function()
      b.pane_dismissed = true
      pane.close(b)
    end, { buffer = buf, nowait = true, silent = true })
  end
  vim.api.nvim_create_autocmd("WinClosed", {
    group = b.augroup, pattern = tostring(w), once = true,
    callback = function()
      -- Closed by the reader (`:q`, `<C-w>o`) is put away as `q` is.
      if not b.closing_pane then
        b.pane_dismissed = true
      end
      if b.pane == w then
        b.pane = nil
      end
    end,
  })
end

--- Shows run `i`'s card, once git has answered about its commit.
function pane.show(b, i)
  if not pane_open(b) or b.pane_run == i then
    return
  end
  b.pane_run = i
  local r = i and b.runs[i]
  if not r then
    return pane_lines(b, { "git has not answered for this line yet" }, { [1] = "UatisBlame" })
  end
  if r.commit.uncommitted then
    return pane_lines(b, { "not committed" }, { [1] = "UatisBlameUncommitted" })
  end
  facts(b, r.commit.sha, function(t, message)
    if blames[b.bufnr] == b and pane_open(b) and b.pane_run == i and b.runs[i] == r then
      pane_lines(b, card(b, r, t, message, true))
    end
  end)
end

local function draw_cursor(b)
  if not vim.api.nvim_buf_is_valid(b.bufnr) then
    return
  end
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) ~= b.bufnr then
    return
  end
  local row = vim.api.nvim_win_get_cursor(win)[1]
  local i = run_at(b, row)
  -- The column is redrawn by Neovim only on the rows that changed, and
  -- moving into another run changes how every row of two runs is drawn.
  if b.cursor_run ~= i then
    b.cursor_run = i
    pcall(vim.api.nvim__redraw, { win = win, statuscolumn = true })
  end
  pane.open(b, win)
  pane.place(b)
  pane.show(b, i)
end

local function draw(b)
  b.colour = assign(b.runs)
  b.labels, b.label_width = labels(b.runs)
  local _, deepest = nest(b.runs)
  b.cols = math.min(deepest + 1, DEPTH)
  b.by_row = {}
  for i, r in ipairs(b.runs) do
    for row = r.from, r.to do
      b.by_row[row] = i
    end
  end
  b.cursor_run = nil
  b.pane_run = nil
  draw_cursor(b)
  redraw_column(b)
end

-- ------------------------------------------------------------------
-- Reading
-- ------------------------------------------------------------------

--- Asks git again, and draws what it says if nothing newer was asked
--- in the meantime. A buffer pinned to a revision is not handed over:
--- its lines ARE that revision's, and git reads them faster than a pipe.
local function refresh(b)
  b.gen = b.gen + 1
  local gen = b.gen
  local text = not b.rev
    and table.concat(vim.api.nvim_buf_get_lines(b.bufnr, 0, -1, false), "\n") or nil
  git.blame(b.root, b.rev, b.path, text, function(runs, err)
    if blames[b.bufnr] ~= b or b.gen ~= gen then
      return
    end
    if not runs then
      -- Said once and the blame taken off: a file git has never seen
      -- has nobody to name, and a column left from an older answer would
      -- be naming somebody wrongly.
      vim.notify("uatis: no blame for " .. b.path .. ": " .. (err or ""):match("^[^\r\n]*"),
        vim.log.levels.INFO)
      return M.close(b.bufnr)
    end
    b.runs = runs
    draw(b)
    b.renders = b.renders + 1
  end)
end

local function schedule(b)
  if b.timer then
    b.timer:stop()
  else
    b.timer = vim.uv.new_timer()
  end
  b.timer:start(150, 0, vim.schedule_wrap(function()
    if blames[b.bufnr] == b then
      refresh(b)
    end
  end))
end

-- ------------------------------------------------------------------
-- Acting on a run
-- ------------------------------------------------------------------

local function cursor_run(b)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local _, r = run_at(b, row)
  if not r then
    vim.notify("uatis: git has not answered for this line yet", vim.log.levels.INFO)
    return
  end
  if r.commit.uncommitted then
    vim.notify("uatis: this line has not been committed", vim.log.levels.INFO)
    return
  end
  return r, row
end

--- The run's commit against its parent, opened at this line as that
--- commit has it -- not the row the buffer has it at, which every edit
--- since has moved.
local function show(b)
  local r, row = cursor_run(b)
  if not r then
    return
  end
  local path, at = r.path or b.path, r.orig + (row - r.from)
  local pane = require("uatis.pane")
  local view = require("uatis.view")
  pane.show_commit(r.commit.sha, {
    on_ready = function(p)
      for i, f in ipairs(p.files) do
        if f.path == path then
          view.land_at(p.root, path, at)
          return pane.goto_file(p, i)
        end
      end
    end,
  })
end

--- The marks for a `git log -L` patch drawn from row `at` + 1 of the
--- float: each hunk's two sides parsed as code in the file's own
--- language, so a changed line reads in its colours as it does in the
--- buffer, with only the BAND under it saying which side it is from --
--- the same rule as a view's before-image. A whole line of
--- DiffAdd/DiffDelete foreground was the colouring taken away exactly
--- where the reader is asked to compare. A side is parsed per hunk:
--- concatenated, a hunk ending mid-string leaks into the next one.
--- Without a parser the line keeps the plain diff foreground.
local function patch_marks(patch, filetype, at)
  local out = {}
  local function mark(row, col, end_col, hl)
    table.insert(out, { row = row, col = col, end_col = end_col, hl = hl })
  end
  local function flush(hunk)
    if not hunk then
      return
    end
    for _, side in ipairs({ "-", "+" }) do
      local text, rows, where = {}, {}, {}
      for _, e in ipairs(hunk) do
        if e.sign == " " or e.sign == side then
          table.insert(text, e.line:sub(2))
          table.insert(rows, #text)
          where[#text] = e
        end
      end
      local spans = syntax.spans(table.concat(text, "\n"), filetype, rows) or {}
      for i, e in pairs(where) do
        if e.sign == side or (side == "+" and e.sign == " ") then
          if spans[i] then
            for _, run in ipairs(spans[i]) do
              mark(e.row, run[1] + 1, math.min(run[2] + 1, #e.line), run[3])
            end
          elseif e.sign ~= " " then
            mark(e.row, 1, #e.line, side == "+" and "UatisStatAdd" or "UatisStatDel")
          end
        end
      end
    end
  end
  local hunk
  for i, l in ipairs(patch) do
    local row, sign = at + i, l:sub(1, 1)
    if l:match("^@@") then
      flush(hunk)
      hunk = {}
      mark(row, 0, #l, "UatisBlame")
    elseif hunk and (sign == "+" or sign == "-" or sign == " ") then
      table.insert(hunk, { row = row, sign = sign, line = l })
      if sign ~= " " then
        mark(row, nil, nil, sign == "+" and "UatisAdd" or "UatisDeleteBg")
        mark(row, 0, 1, sign == "+" and "UatisStatAdd" or "UatisStatDel")
      end
    end
  end
  flush(hunk)
  return out
end

--- What is known of run `r`'s commit, as rows of text: the commit, who
--- and exactly when, the rows the run covers here and in that commit,
--- and the whole message. `marks` is row -> highlight group. `brief`
--- is the pane's: who and when, and the subject alone.
function card(b, r, t, message, brief)
  local c = r.commit
  local path = r.path or b.path
  local lines, marks = {}, {}
  local function add(text, hl)
    table.insert(lines, text)
    if hl then
      marks[#lines] = hl
    end
  end
  local when = t.author and (t.author .. (t.epoch and ("  · " .. ui.ago(t.epoch)) or "")) or ""
  add(c.short .. " · " .. (c.author or "") .. " · " .. when, colour(b, r, true))
  if t.committer then
    add("committed " .. t.committer, "UatisBlame")
  end
  if brief then
    add(vim.split(message ~= "" and message or (c.summary or ""), "\n", { plain = true })[1])
    return lines, marks
  end
  local n = r.to - r.from + 1
  local orig_to = r.orig + (r.to - r.from)
  local here = n == 1 and ("row " .. r.from) or ("rows " .. r.from .. "–" .. r.to)
  local there = n == 1 and ("row " .. r.orig) or ("rows " .. r.orig .. "–" .. orig_to)
  add(here .. " here · " .. there .. " in " .. c.short
    .. (path ~= b.path and (" (" .. path .. ")") or ""), "UatisBlame")
  add("")
  for _, l in ipairs(vim.split(message ~= "" and message or (c.summary or ""),
    "\n", { plain = true })) do
    add(l)
  end
  return lines, marks
end

--- A commit's times and message, which never change, read once per sha:
--- cb(times, message). The pane asks on every run the cursor enters.
function facts(b, sha, cb)
  b.facts = b.facts or {}
  local f = b.facts[sha]
  if f and f.times and f.message then
    return cb(f.times, f.message)
  end
  if f then
    return table.insert(f.waiting, cb)
  end
  f = { waiting = { cb } }
  b.facts[sha] = f
  local function ready()
    if f.times and f.message then
      for _, w in ipairs(f.waiting) do
        w(f.times, f.message)
      end
      f.waiting = {}
    end
  end
  git.commit_times(b.root, sha, function(t)
    f.times = t or {}
    ready()
  end)
  git.commit_message(b.root, sha, function(text)
    f.message = text or ""
    ready()
  end)
end

--- The run under the cursor, in a float beside it: the commit, who and
--- exactly when, the rows the run covers here and in that commit, the
--- whole message, and what the commit did to THESE lines -- the hunks
--- `git log -L` gives for them, which is the question a blame is usually
--- asked to answer and the one the gutter has no room for. Gone when the
--- cursor moves; the key again goes into it, as a hover does.
local function details(b)
  if b.float and vim.api.nvim_win_is_valid(b.float) then
    return vim.api.nvim_set_current_win(b.float)
  end
  local r, row = cursor_run(b)
  if not r then
    return
  end
  local c = r.commit
  local path = r.path or b.path
  local orig_to = r.orig + (r.to - r.from)
  local got = {}
  local function ready()
    if not (got.times and got.message and got.patch) then
      return
    end
    if blames[b.bufnr] ~= b or vim.api.nvim_get_current_buf() ~= b.bufnr
      or vim.api.nvim_win_get_cursor(0)[1] ~= row then
      return
    end
    local lines, marks = card(b, r, got.times, got.message)
    local function add(text, hl)
      table.insert(lines, text)
      if hl then
        marks[#lines] = hl
      end
    end
    local painted = {}
    if #got.patch > 0 then
      add("")
      add("what it did to these lines", "UatisBlame")
      local at = #lines
      for _, l in ipairs(got.patch) do
        table.insert(lines, l)
      end
      local ft = vim.bo[b.bufnr].filetype
      painted = patch_marks(got.patch, ft ~= "" and ft or vim.filetype.match({ filename = path }), at)
    end

    local width = 0
    for _, l in ipairs(lines) do
      width = math.max(width, vim.fn.strdisplaywidth(l))
    end
    width = math.min(math.max(width + 2, 40), math.max(vim.o.columns - 8, 20))
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].modifiable = false
    for at, hl in pairs(marks) do
      vim.api.nvim_buf_set_extmark(buf, M.ns, at - 1, 0, {
        end_row = at - 1, end_col = #lines[at], hl_group = hl })
    end
    for _, m in ipairs(painted) do
      vim.api.nvim_buf_set_extmark(buf, M.ns, m.row - 1, m.col or 0, m.col
        and { end_col = m.end_col, hl_group = m.hl, priority = 200 }
        or { line_hl_group = m.hl, priority = 100 })
    end
    local win = vim.api.nvim_open_win(buf, false, {
      relative = "cursor", row = 1, col = 0,
      width = width, height = math.min(#lines, math.max(vim.o.lines - 6, 5)),
      style = "minimal", border = "rounded", title = " blame ", title_pos = "center",
    })
    vim.wo[win].wrap = true
    b.float = win
    local group = vim.api.nvim_create_augroup("UatisBlameFloat" .. win, { clear = true })
    local function close()
      pcall(vim.api.nvim_del_augroup_by_id, group)
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
      if b.float == win then
        b.float = nil
      end
    end
    -- Not `BufLeave`: going INTO the float leaves the buffer too.
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "InsertEnter", "BufHidden" }, {
      group = group, buffer = b.bufnr, callback = close,
    })
    vim.api.nvim_create_autocmd("WinLeave", {
      group = group, buffer = buf, callback = close,
    })
    for _, lhs in ipairs({ "q", "<Esc>" }) do
      vim.keymap.set("n", lhs, close, { buffer = buf, nowait = true, silent = true })
    end
  end
  facts(b, c.sha, function(t, message)
    got.times, got.message = t, message
    ready()
  end)
  git.line_patch(b.root, c.sha, path, r.orig, orig_to, function(lines)
    got.patch = lines
    ready()
  end)
end

local function jump(b, dir)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local i = run_at(b, row)
  if not i then
    return
  end
  -- `[r` inside a run goes to its own top first, as `[[` does.
  local to = dir < 0 and row > b.runs[i].from and b.runs[i] or b.runs[i + dir]
  if to then
    vim.api.nvim_win_set_cursor(0, { to.from, 0 })
  end
end

-- ------------------------------------------------------------------
-- Lifecycle
-- ------------------------------------------------------------------

local function setup_keymaps(b)
  local k = config.keys.blame
  b.saved_keys = keys.apply(b.bufnr, "n", {
    { lhs = k.next, rhs = function() jump(b, 1) end,
      opts = { desc = "Uatis - Next blame run" } },
    { lhs = k.prev, rhs = function() jump(b, -1) end,
      opts = { desc = "Uatis - Previous blame run" } },
    { lhs = k.show, rhs = function() show(b) end,
      opts = { desc = "[G]it - Show the [c]ommit that wrote this line" } },
    { lhs = k.details, rhs = function() details(b) end,
      opts = { desc = "Uatis - Details of the blame run under the cursor" } },
  })
end

local function setup_watchers(b)
  b.augroup = vim.api.nvim_create_augroup("UatisBlame" .. b.bufnr, { clear = true })
  if not b.rev then
    vim.api.nvim_buf_attach(b.bufnr, false, {
      on_lines = function()
        if blames[b.bufnr] ~= b then
          return true
        end
        schedule(b)
      end,
      on_reload = function()
        if blames[b.bufnr] == b then
          schedule(b)
        end
      end,
    })
    -- A commit is made outside the editor, and every line it took goes
    -- from "not committed" to a sha without the buffer changing at all.
    vim.api.nvim_create_autocmd({ "BufWritePost", "FocusGained", "TermLeave" }, {
      group = b.augroup,
      callback = function(ev)
        if ev.event ~= "BufWritePost" or ev.buf == b.bufnr then
          schedule(b)
        end
      end,
    })
  end
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = b.augroup,
    buffer = b.bufnr,
    callback = function() draw_cursor(b) end,
  })
  -- The pane describes a buffer on screen; it goes when the buffer does
  -- and comes back with it.
  vim.api.nvim_create_autocmd("BufWinLeave", {
    group = b.augroup,
    buffer = b.bufnr,
    callback = function() vim.schedule(function() pane.close(b) end) end,
  })
  -- Any change of layout can come between the pane and its window.
  vim.api.nvim_create_autocmd({ "WinNew", "WinClosed", "BufWinEnter" }, {
    group = b.augroup,
    callback = function()
      vim.schedule(function()
        if blames[b.bufnr] == b then
          pane.place(b)
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = b.augroup,
    buffer = b.bufnr,
    callback = function()
      b.pane_run = nil
      draw_cursor(b)
    end,
  })
  -- `:edit!` unloads a buffer it then reads straight back into, and
  -- that is a reload to blame again, not the end of the blame.
  vim.api.nvim_create_autocmd("BufUnload", {
    group = b.augroup,
    buffer = b.bufnr,
    callback = function()
      vim.schedule(function()
        if blames[b.bufnr] ~= b then
          return
        end
        if vim.api.nvim_buf_is_valid(b.bufnr) and vim.api.nvim_buf_is_loaded(b.bufnr) then
          return refresh(b)
        end
        M.close(b.bufnr)
      end)
    end,
  })
end

--- What `bufnr` holds, as git would be asked about it: cb(root, path,
--- rev) -- `rev` nil for the working tree -- or cb(nil, why). A view's
--- copy of a file at a commit and the old side of a comparison are
--- blamed AT their revision; anything else is a file of some checkout.
local function subject(bufnr, cb)
  local view = require("uatis.view")
  local v = view.get(bufnr)
  if v and v.at_commit then
    return cb(v.root, v.relpath, v.at_commit)
  end
  local old = require("uatis.oldside").view_for(bufnr)
  if old then
    return cb(old.root, old.old_path or old.relpath, old.rev)
  end
  local file = vim.api.nvim_buf_get_name(bufnr)
  if vim.bo[bufnr].buftype ~= "" or file == "" then
    return cb(nil, "not a file buffer")
  end
  git.root(file, function(root)
    if not root then
      return cb(nil, file .. " is not inside a git repository")
    end
    local rel = view.relpath(root, file)
    if not rel then
      return cb(nil, file .. " is not inside " .. root)
    end
    cb(root, rel, nil)
  end)
end

function M.attach(bufnr)
  if blames[bufnr] then
    return blames[bufnr]
  end
  local b = { bufnr = bufnr, gen = 0, renders = 0, runs = {}, by_row = {}, colour = {} }
  blames[bufnr] = b
  subject(bufnr, function(root, path, rev)
    if blames[bufnr] ~= b then
      return
    end
    if not root then
      blames[bufnr] = nil
      vim.notify("uatis: " .. path, vim.log.levels.ERROR)
      return
    end
    b.root, b.path, b.rev = root, path, rev
    setup_keymaps(b)
    setup_watchers(b)
    watch_windows()
    for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
      sync(win)
    end
    refresh(b)
  end)
  return b
end

function M.close(bufnr)
  local b = blames[bufnr]
  if not b then
    return
  end
  blames[bufnr] = nil
  if b.timer then
    b.timer:stop()
    b.timer:close()
    b.timer = nil
  end
  if b.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, b.augroup)
  end
  if vim.api.nvim_buf_is_valid(bufnr) then
    keys.restore(bufnr, "n", b.saved_keys)
    for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
      sync(win)
    end
  end
  if b.float and vim.api.nvim_win_is_valid(b.float) then
    vim.api.nvim_win_close(b.float, true)
  end
  pane.close(b)
end

function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if blames[bufnr] then
    return M.close(bufnr)
  end
  return M.attach(bufnr)
end

return M
