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
local SHA = 7

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

--- The bracket's piece on `row` of run `r`.
local function corner(r, row, current)
  local m = config.marker.blame
  m = current and m.current or m
  if r.from == r.to then
    return m.single
  end
  return row == r.from and m.first or row == r.to and m.last or m.mid
end

--- The gutter cell of `lnum` in `win`, which shows `buf`: the sha on a
--- run's first row, blank under it, and the bracket's piece. `virtnum`
--- is 'statuscolumn''s own: past 0 a wrapped part of the row, below it
--- a virtual line above it, and either is the bracket's middle where
--- the run goes on past it.
function M.cell(buf, win, lnum, virtnum)
  local b = blames[buf]
  local blank = string.rep(" ", SHA + 3)
  if not b then
    return ""
  end
  local i, r = run_at(b, lnum)
  if not r then
    return blank
  end
  local ok, cur = pcall(vim.api.nvim_win_get_cursor, win)
  local current = ok and b.by_row[cur[1]] == i
  local hl = colour(b, r, current)
  local piece
  if virtnum == 0 then
    piece = corner(r, lnum, current)
  elseif (virtnum > 0 and lnum < r.to) or (virtnum < 0 and lnum > r.from) then
    piece = (current and config.marker.blame.current or config.marker.blame).mid
  else
    return blank
  end
  local name = string.rep(" ", SHA)
  if virtnum == 0 and lnum == r.from then
    name = r.commit.uncommitted and ("new" .. string.rep(" ", SHA - 3)) or r.commit.short
  end
  return "%#" .. hl .. "#" .. name .. " " .. piece .. "%* "
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
end

local function draw(b)
  b.colour = assign(b.runs)
  b.by_row = {}
  for i, r in ipairs(b.runs) do
    for row = r.from, r.to do
      b.by_row[row] = i
    end
  end
  b.cursor_run = nil
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
    local t = got.times
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
    local n = r.to - r.from + 1
    local here = n == 1 and ("row " .. r.from) or ("rows " .. r.from .. "–" .. r.to)
    local there = n == 1 and ("row " .. r.orig) or ("rows " .. r.orig .. "–" .. orig_to)
    add(here .. " here · " .. there .. " in " .. c.short
      .. (path ~= b.path and (" (" .. path .. ")") or ""), "UatisBlame")
    add("")
    for _, l in ipairs(vim.split(got.message ~= "" and got.message or (c.summary or ""),
      "\n", { plain = true })) do
      add(l)
    end
    if #got.patch > 0 then
      add("")
      add("what it did to these lines", "UatisBlame")
      for _, l in ipairs(got.patch) do
        local first = l:sub(1, 1)
        add(l, l:match("^@@") and "UatisBlame"
          or first == "+" and "UatisStatAdd" or first == "-" and "UatisStatDel" or nil)
      end
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
  git.commit_times(b.root, c.sha, function(t)
    got.times = t or {}
    ready()
  end)
  git.commit_message(b.root, c.sha, function(text)
    got.message = text
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
end

function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if blames[bufnr] then
    return M.close(bufnr)
  end
  return M.attach(bufnr)
end

return M
