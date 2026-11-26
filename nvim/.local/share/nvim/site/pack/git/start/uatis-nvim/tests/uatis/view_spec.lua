-- `view.lua`: one buffer annotated against a revision, inline or side by
-- side, on the fixture repo (checked out on main).
local h = require("helpers")
local uatis = require("uatis")
local config = require("uatis.config")
local overlay = require("uatis.overlay")
local oldside = require("uatis.oldside")
local ui = require("uatis.ui")
local view_mod = require("uatis.view")
local pane_mod = require("uatis.pane")
local fixture = h.repo()
local kv = config.keys.view

local function edit(name)
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/" .. name))
  return vim.api.nvim_get_current_buf()
end

-- `:Uatis <ref>` on `name`, waited on until the view has drawn a change.
local function run_on(name, ref)
  local buf = edit(name)
  uatis.run({ fargs = { ref } })
  h.wait_for(function()
    local v = view_mod.get(buf)
    return v ~= nil and #(v.anchors or {}) > 0
  end, "the view on " .. name .. " vs " .. ref)
  return buf, view_mod.get(buf)
end

-- A winbar with its highlight and truncation items taken out.
local function plain(s)
  return (s:gsub("%%#[%w]*#", ""):gsub("%%%*", ""):gsub("%%<", ""))
end

local function n_marks(buf)
  return #vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1, {})
end

-- What uatis says when `run` is refused: the first thing notified.
local function complaint(run)
  local said = {}
  local real = vim.notify
  vim.notify = function(msg) table.insert(said, msg) end
  run()
  local fine = vim.wait(10000, function() return #said > 0 end, 20)
  vim.notify = real
  assert(fine, "uatis said nothing")
  return said[1]
end

-- Blank rows the side-by-side layout pads `buf` with.
local function filler_rows(buf)
  local n = 0
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, oldside.ns, 0, -1, { details = true })) do
    n = n + #(m[4].virt_lines or {})
  end
  return n
end

-- Both backends will answer about a PNG. difftastic falls back to
-- comparing words where it has no parser, and `vim.diff` will happily
-- split one on whatever newline bytes it contains. Both answers are true
-- of the bytes and useless: marks over noise, a before-image of noise
-- above them, counts that mean nothing. What can honestly be said is
-- what the file weighs.
describe("a file of bytes", function()
  local path = fixture .. "/binblob/logo.png"
  local buf, v

  it("is weighed as a person reads a size", function()
    assert.are.equal("0 B", ui.size(0))
    assert.are.equal("900 B", ui.size(900))
    assert.are.equal("1.2 KB", ui.size(1231))
    -- A file that did not exist weighed nothing.
    assert.are.equal("nothing", ui.size(nil))
  end)

  -- A NUL near the front is how git decides this too, and it is asked of
  -- the CONTENT: the question is whether the file can be read as lines,
  -- and an extension does not answer it.
  it("is known for bytes, counted as nothing and drawn on not at all", function()
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    -- `writefile` refuses a string with a NUL in it -- it becomes a Blob
    -- on the way through Vimscript. Written from Lua, which does not care.
    local fd = assert(io.open(path, "wb"))
    fd:write("\137PNG\r\n\26\n" .. string.rep("\0\1\2\3", 40))
    fd:close()
    h.git("add", "binblob/logo.png")
    h.git("commit", "-m", "a binary file")

    buf, v = h.open_view("binblob/logo.png", "main")
    assert.is_not_nil(v.binary)
    assert.are.equal(0, v.added)
    assert.are.equal(0, v.removed)
    assert.are.equal(0, n_marks(buf))
  end)

  -- Neovim stores a NUL as a newline and splits on the rest, so a PNG
  -- round-tripped through buffer lines comes back a different length
  -- than the file is.
  it("reports the size of the file, not of the buffer", function()
    assert.are.equal(vim.uv.fs_stat(path).size, v.binary.new)
  end)

  -- None of the slots that describe a comparison of TEXT: no counts, no
  -- backend, no parser note. None of them is a fact about a PNG.
  it("says so in the winbar, with what it weighed and weighs, and nothing about text", function()
    local bar = plain(ui.view_winbar_text(v, 100))
    assert.matches("binary", bar, 1, true)
    assert.matches("→", bar, 1, true)
    assert.is_nil(bar:find("+0", 1, true))
    assert.is_nil(bar:find("structural", 1, true))
    assert.is_nil(bar:find("line", 1, true))
  end)

  view_mod.stop(v)
  h.git("rm", "-r", "-f", "binblob")
  h.git("commit", "-m", "and out again")
end)

-- The fixture leaves main checked out, so the buffer is main's calc.lua
-- and the branch is what it is measured against.
describe("the diff view", function()
  local buf, view

  it("annotates the buffer, which stays a normal, writable file buffer", function()
    buf, view = run_on("calc.lua", "feature/math")
    assert.are.equal("calc.lua", view.relpath)
    assert.are_not.equal("", vim.wo.winbar)
    assert.is_true(n_marks(buf) > 0)
    assert.are.equal("", vim.bo[buf].buftype)
    assert.is_true(vim.bo[buf].modifiable)
  end)

  -- `b - a` became `a - b`, and the cursor goes to what is marked there.
  -- A row that only lost characters has nothing on it to land on, and
  -- takes the first non-blank.
  it("lands ]c on the change itself, or on the first non-blank of a row with none", function()
    local step = vim.fn.maparg(kv.hunk_next, "n", false, true).callback
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    step()
    assert.are.same({ 4, 2 }, vim.api.nvim_win_get_cursor(0))
    step()
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    assert.are.same({ 8, "-" }, { row, vim.api.nvim_get_current_line():sub(col + 1, col + 1) })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
  end)

  it("names the file and the revision in the winbar", function()
    local bar = plain(ui.view_winbar_text(view, 200))
    assert.matches("calc.lua", bar, 1, true)
    assert.matches("vs feature/math", bar, 1, true)
  end)

  -- The identity is read on every glance and the keys once, and `g?` in
  -- the list teaches them on demand.
  it("names no key in the winbar", function()
    local bar = plain(ui.view_winbar_text(view, 200))
    assert.is_nil(bar:find(config.keys.global.toggle_diff .. " close", 1, true))
    assert.is_nil(bar:find(kv.hunk_next .. "/", 1, true))
  end)

  -- difftastic answering without a parser is not difftastic being
  -- missing, and the two read differently: one is a line diff, the other
  -- is a structural diff of words. Both are worth a word in the header,
  -- because both look like less than the reader asked for.
  it("says so when difftastic answered without a parser", function()
    local bar = plain(ui.view_winbar_text(vim.tbl_extend("force", {}, view, { prose = true }), 200))
    assert.matches("structural · no parser", bar, 1, true)
  end)

  -- ...and WHY, where it had a parser and put it down. `no parser` on
  -- a `.py` file reads as "difftastic cannot do Python"; the truth was
  -- a diff too large for its graph limit, or a file that would not
  -- parse just now, and either is something the reader can act on.
  it("names the limit difftastic gave up at", function()
    local bar = plain(ui.view_winbar_text(
      vim.tbl_extend("force", {}, view, { prose = true, fallback = "graph limit" }), 200))
    assert.matches("structural · text fallback (graph limit)", bar, 1, true)
  end)

  it("reads that limit off difftastic's own language string", function()
    local fallback_of = require("uatis.diff").fallback_of
    assert.are.equal("graph limit", fallback_of("Text (exceeded DFT_GRAPH_LIMIT)"))
    assert.are.equal("parse errors",
      fallback_of("Text (3 Python parse errors, exceeded DFT_PARSE_ERROR_LIMIT)"))
    -- No parser to put down, or no fallback at all.
    assert.is_nil(fallback_of("Text"))
    assert.is_nil(fallback_of("Python"))
  end)

  it("says when the file was read in pieces", function()
    local bar = plain(ui.view_winbar_text(vim.tbl_extend("force", {}, view, { pieces = 3, prose = false }), 200))
    assert.matches("structural · in 3 pieces", bar, 1, true)
  end)

  -- Rather than stacking a second view on the same buffer.
  it("is reused when re-run against another revision", function()
    local before = view.renders
    uatis.run({ fargs = { "main" } })
    h.wait_for(function()
      local v = view_mod.get(buf)
      return v ~= nil and v.ref == "main" and (v.renders or 0) > before
    end, "the ref to be replaced in place")
    assert.are.equal(view, view_mod.get(buf))
    -- Against the checked-out revision there is nothing to show.
    assert.are.equal(0, #(view.anchors or {}))
  end)

  -- Editing moves the new side, so the diff has to follow it. Debounced,
  -- so this waits rather than asserting immediately.
  it("shows an unsaved edit as an addition", function()
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "-- a line that is not in main" })
    h.wait_for(function() return #(view.anchors or {}) > 0 end, "the diff to follow an edit to the buffer")
    assert.is_true(view.added > 0)
  end)

  it("puts back every mark and the winbar when it closes", function()
    view_mod.close(buf)
    assert.is_nil(view_mod.get(buf))
    assert.are.equal(0, n_marks(buf))
    assert.are.equal("", vim.wo.winbar)
  end)

  edit("calc.lua")
end)

-- The same comparison drawn two ways. In place, the old side is virtual
-- lines around your buffer; side by side, it is the window next door and
-- drawing it twice would say everything twice. What does not change is
-- the marks on your own buffer: what was added is a property of the
-- buffer, not of the layout.
describe("side by side, or in place", function()
  local buf, view, settled

  local function switch_layout()
    h.act(view, function() h.press(kv.layout) end, "a redraw after " .. kv.layout)
  end

  local function counts()
    local out = { marks = 0, before = 0 }
    for _, m in ipairs(h.marks(buf)) do
      local d = m[4]
      if d.line_hl_group or d.end_col or d.virt_text_pos == "inline" then
        out.marks = out.marks + 1
      end
      out.before = out.before + #(d.virt_lines or {})
    end
    return out
  end

  local function old_view()
    return vim.api.nvim_win_call(view.old.win, vim.fn.winsaveview)
  end

  it("starts in place, the old side drawn around your buffer", function()
    vim.cmd("silent! only")
    buf, view = run_on("calc.lua", "feature/math")
    assert.are.equal("inline", view.layout)
    assert.is_true(counts().before > 0)
  end)

  it("opens the old revision in its own window, leaving you in your buffer", function()
    switch_layout()
    assert.are.equal("side", view.layout)
    assert.is_true(oldside.is_open(view))
    -- Yours is the one you can edit.
    assert.are.equal(view.win, vim.api.nvim_get_current_win())
  end)

  it("stops drawing the old side twice, and keeps your buffer's own marks", function()
    local c = counts()
    assert.are.equal(0, c.before)
    assert.is_true(c.marks > 0)
  end)

  -- The two windows are one view of one comparison, so the old one
  -- follows the cursor rather than being scrolled by hand.
  it("moves the old window's cursor with yours, to the row the mapping says", function()
    vim.api.nvim_win_set_cursor(view.win, { 4, 0 })
    vim.cmd("doautocmd CursorMoved")
    assert.are.equal(oldside.old_row(view, 4), vim.api.nvim_win_get_cursor(view.old.win)[1])
    settled = old_view()
    assert.are.equal(oldside.old_row(view, 4), settled.lnum)
  end)

  -- One view change per movement, and none at all when the answer has
  -- not changed. Moving the cursor and then correcting the scroll drew
  -- the old window twice per keypress, with a jump to another part of the
  -- file in between -- which is what flickering is.
  it("changes nothing at all when synced again for the same row", function()
    oldside.sync(view, 4)
    assert.are.same(settled, old_view())
  end)

  -- And the other way: read from the old window and yours follows. A
  -- row your side does not have is one of the fillers above the next
  -- line it does, so your window starts on that line with the fillers
  -- still in view counted in `topfill`.
  it("moves your window with the old one, fillers and all", function()
    local align = oldside.alignment(view)
    local gap
    for i, e in ipairs(align) do
      if not e.new then
        gap = i
        break
      end
    end
    assert.is_not_nil(gap, "an alignment row your side does not have")
    local next_new, fill
    for i = gap, #align do
      if align[i].new then
        next_new, fill = align[i].new, i - gap
        break
      end
    end
    local before = vim.api.nvim_win_get_cursor(view.win)[2]
    vim.api.nvim_set_current_win(view.old.win)
    vim.api.nvim_win_call(view.old.win, function()
      vim.fn.winrestview({ lnum = gap, topline = gap, col = 0 })
    end)
    vim.cmd("doautocmd CursorMoved")
    local mine = vim.api.nvim_win_call(view.win, vim.fn.winsaveview)
    assert.are.equal(oldside.new_row(view, gap), mine.lnum)
    assert.are.equal(next_new, mine.topline)
    assert.are.equal(fill, mine.topfill)
    assert.are.equal(before, mine.col)
    vim.api.nvim_set_current_win(view.win)
  end)

  -- The old window scrolled by `sync` is not the reader scrolling it:
  -- answered, your window must not move under your cursor.
  it("leaves your window alone when the old one only followed it", function()
    vim.api.nvim_win_set_cursor(view.win, { 4, 0 })
    vim.cmd("doautocmd CursorMoved")
    local mine = vim.api.nvim_win_call(view.win, vim.fn.winsaveview)
    vim.cmd("doautocmd WinScrolled " .. view.old.win)
    assert.are.same(mine, vim.api.nvim_win_call(view.win, vim.fn.winsaveview))
  end)

  -- The branch this is measured against only ADDED, so the padding all
  -- lands on your side: there is nothing there to sit opposite `M.mul`.
  it("pads your side where the old one has lines you do not", function()
    assert.is_true(filler_rows(buf) > 0)
  end)

  -- The old side is padded with REAL lines instead. Virtual ones cannot
  -- be scrolled into -- a block below the last line not at all, and one
  -- taller than the window not without a real line to put the cursor on
  -- -- so a shorter old file pinned its last line to the top and sat
  -- there while your side scrolled past it.
  it("gives the old buffer one line per row of the alignment", function()
    assert.are.equal(#oldside.alignment(view), vim.api.nvim_buf_line_count(view.old.buf))
  end)

  -- This branch only added, so nothing had to be padded on the old side.
  -- The alignment's own tests cover the other direction line by line.
  it("holds every line of the revision there and nothing else", function()
    local old_lines = vim.api.nvim_buf_get_lines(view.old.buf, 0, -1, false)
    assert.are.same(vim.split(view.old_text, "\n", { plain = true }), old_lines)
  end)

  it("leaves the two sides exactly as tall as each other", function()
    assert.are.equal(vim.api.nvim_win_text_height(view.win, {}).all,
      vim.api.nvim_win_text_height(view.old.win, {}).all)
  end)

  -- Which is the question a two-window layout invents.
  it("says in each window which revision it shows", function()
    assert.matches("working tree", plain(ui.view_winbar_text(view, 200)), 1, true)
    local theirs = plain(ui.old_winbar_text(view, 200))
    assert.matches("feature/math", theirs, 1, true)
    assert.matches(view.rev:sub(1, 7), theirs, 1, true)
  end)

  it("goes back in place on the key again, taking the window and the padding away", function()
    switch_layout()
    assert.are.equal("inline", view.layout)
    assert.is_false(oldside.is_open(view))
    assert.is_true(counts().before > 0)
    assert.are.equal(0, filler_rows(buf))
  end)

  view_mod.close(buf)
  vim.cmd("silent! only")
end)

-- The fillers that line your buffer up with the old window are extmarks
-- in YOUR buffer, and `:tabclose` takes both windows away at once. The
-- old window's `WinClosed` dropped `view.old` so the next sync would not
-- reach for a window that was gone -- and the view's own close, coming
-- a tick later, found no old side to clean up after. The buffer stayed
-- loaded, and the file came back with blank rows between its lines.
describe("a tab closed on a side-by-side view", function()
  local buf, tab, view, wrapped

  it("held the old revision beside a padded buffer", function()
    -- The file is shown in the new tab and nowhere else: a view is one
    -- per buffer, and a buffer on screen in two tabs is a different
    -- question.
    vim.cmd("silent! only")
    edit("stable.lua")
    vim.cmd("tabnew")
    buf, view = run_on("calc.lua", "feature/math")
    tab = vim.api.nvim_get_current_tabpage()
    wrapped = vim.wo[view.win].wrap

    -- Pressed from the file, as it would be: the old revision opens
    -- beside the window the key was pressed in.
    h.act(view, function() h.press(kv.layout) end, "the side-by-side layout")
    assert.is_true(oldside.is_open(view))
    assert.is_true(filler_rows(buf) > 0)
  end)

  -- Loaded, as any hidden buffer is.
  it("closes the view and takes the padding out of the buffer", function()
    vim.cmd("tabclose")
    h.wait_for(function() return view_mod.get(buf) == nil end, "the view to close with its tab")
    assert.is_false(vim.api.nvim_tabpage_is_valid(tab))
    assert.is_true(vim.api.nvim_buf_is_loaded(buf))
    assert.are.equal(0, filler_rows(buf))
  end)

  it("lets the file reopen with no blank rows and its wrapping as it was", function()
    vim.cmd("silent! only")
    assert.are.equal(buf, edit("calc.lua"))
    assert.are.equal(0, filler_rows(buf))
    assert.are.equal(wrapped, vim.wo.wrap)
  end)
end)

-- `BufWinLeave` is what closes a view when its window moves to the next
-- file -- and it does not fire while the buffer is still on screen
-- somewhere else: the same file open in another tab. `]f` then left the
-- view standing, `view.win` showing a file that was not its own and the
-- old revision still split beside it, and the next file's old window
-- opened alongside -- two old sides on screen.
describe("a window that moves on to the next file", function()
  local buf, tab, view, win

  local function olds()
    local n = 0
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      if oldside.view_for(vim.api.nvim_win_get_buf(w)) then
        n = n + 1
      end
    end
    return n
  end

  it("starts from one old side on screen", function()
    h.git("switch", "-qf", "feature/math")
    vim.cmd("silent! only")
    -- The file on screen in another tab as well, which is what keeps
    -- `BufWinLeave` from firing when the review's window moves on.
    buf = edit("calc.lua")
    vim.cmd("tabnew")
    vim.api.nvim_win_set_buf(0, buf)
    tab = vim.api.nvim_get_current_tabpage()

    uatis.run({ fargs = { "main" } })
    h.wait_for(function()
      local v, p = view_mod.get(buf), pane_mod.get()
      return v ~= nil and (v.renders or 0) > 0 and p ~= nil and (p.renders or 0) > 0
    end, "the review to open on calc.lua")
    view = view_mod.get(buf)
    win = view.win

    h.press(kv.layout)
    h.wait_for(function() return oldside.is_open(view) end, "the old window")
    assert.are.equal(1, olds())
  end)

  it("takes its view with it, though the file is still on screen elsewhere", function()
    h.press(kv.file_next)
    h.wait_for(function()
      local v = view_mod.get(vim.api.nvim_get_current_buf())
      return v ~= nil and v ~= view and (v.renders or 0) > 0 and oldside.is_open(v)
    end, "the next file, side by side")
    h.wait_for(function() return view_mod.get(buf) == nil end, "the view on the file left behind to close")
    assert.are_not.equal(buf, vim.api.nvim_win_get_buf(win))
  end)

  it("leaves one old side on screen, not two", function()
    assert.are.equal(1, olds())
  end)

  view_mod.stop(view_mod.get(vim.api.nvim_get_current_buf()))
  h.wait_for(function() return pane_mod.get() == nil end, "the review to end")
  vim.cmd("silent! tabclose")
  vim.cmd("silent! only")
  h.git("switch", "-qf", "main")
  edit("calc.lua")
end)

-- The old window is a file of the review too, so the walk through it
-- works from there: a change in this file is landed on in place, and
-- the next file opens next door with the cursor back in ITS old side.
-- Measured from main against the branch, so what the branch added is
-- what this side lacks: removals, whose new row is the line below.
describe("walking the review from the old window", function()
  local buf, view

  local function old_cursor()
    return vim.api.nvim_win_get_cursor(view.old.win)[1]
  end

  it("starts side by side, the cursor in the old window", function()
    -- A list of its own: one left by an earlier review is pinned to
    -- whatever that one measured against.
    if pane_mod.get() then
      pane_mod.close(pane_mod.get())
    end
    vim.cmd("silent! only")
    buf, view = run_on("calc.lua", "feature/math")
    h.wait_for(function()
      local p = pane_mod.get()
      return p ~= nil and (p.renders or 0) > 0
    end, "the list")
    h.act(view, function() h.press(kv.layout) end, "a redraw side by side")
    vim.api.nvim_set_current_win(view.old.win)
    vim.api.nvim_win_set_cursor(view.old.win, { 1, 0 })
    vim.cmd("doautocmd CursorMoved")
  end)

  it("lands on the next change in both windows, staying in the old one", function()
    local first = view.anchors[1]
    h.press(kv.hunk_next)
    assert.are.equal(view.old.win, vim.api.nvim_get_current_win())
    assert.are.equal(first, vim.api.nvim_win_get_cursor(view.win)[1])
    assert.are.equal(oldside.old_row(view, first), old_cursor())
  end)

  -- The second change is lines the branch added: rows of this side with
  -- nothing opposite, standing above the line that follows them there.
  it("lands on the first removed row of a removal, not on the line below", function()
    local second = view.anchors[2]
    h.press(kv.hunk_next)
    assert.are.equal(view.old.win, vim.api.nvim_get_current_win())
    assert.are.equal(second, vim.api.nvim_win_get_cursor(view.win)[1])
    local align, r = view.align, old_cursor()
    assert.is_nil(align[r].new)
    assert.is_truthy(align[r].old)
    assert.is_truthy(align[r - 1].new)
    assert.are.equal(second, oldside.new_row(view, r))
  end)

  it("opens the next file next door and goes on reading its old side", function()
    local win = view.win
    h.press(kv.file_next)
    h.wait_for(function()
      local v = view_mod.get(vim.api.nvim_win_get_buf(win))
      return v ~= nil and v ~= view and oldside.is_open(v)
        and vim.api.nvim_get_current_win() == v.old.win
    end, "the next file's old window, with the cursor in it")
    assert.are.equal(1, #vim.tbl_filter(function(w)
      return oldside.view_for(vim.api.nvim_win_get_buf(w)) ~= nil
    end, vim.api.nvim_tabpage_list_wins(0)))
  end)

  it("never opens a file into the old window itself", function()
    local v = view_mod.get(vim.api.nvim_win_get_buf(view.win))
    pane_mod.get().code_win = v.old.win
    h.press(kv.file_prev)
    h.wait_for(function()
      local now = view_mod.get(vim.api.nvim_win_get_buf(view.win))
      return now ~= nil and now ~= v and oldside.is_open(now)
    end, "the file before, in the window beside")
    assert.are.equal(buf, vim.api.nvim_win_get_buf(view.win))
  end)

  -- The list toggles from here too, and opened from here it still puts
  -- picked files in YOUR window, never over the old revision.
  it("toggles the list from the old window", function()
    local v = view_mod.get(vim.api.nvim_win_get_buf(view.win))
    local p = pane_mod.get()
    if p.list_win and vim.api.nvim_win_is_valid(p.list_win) then
      pane_mod.hide(p)
    end
    vim.api.nvim_set_current_win(v.old.win)
    h.press(kv.files)
    assert.is_truthy(p.list_win and vim.api.nvim_win_is_valid(p.list_win))
    assert.are.equal(view.win, p.code_win)
    vim.api.nvim_set_current_win(v.old.win)
    h.press(kv.files)
    assert.is_falsy(p.list_win and vim.api.nvim_win_is_valid(p.list_win))
  end)

  view_mod.stop(view_mod.get(vim.api.nvim_win_get_buf(view.win)) or view)
  h.wait_for(function() return pane_mod.get() == nil end, "the review to end")
  vim.cmd("silent! only")
  edit("calc.lua")
end)

-- What a side-by-side layout needs and an overlay does not: for every
-- display row, the old line, the new line, or both. Padding each side
-- where the other has lines it does not is what puts a line and the line
-- it replaced on the same screen row.
describe("oldside.alignment", function()
  local buf = vim.api.nvim_create_buf(false, true)

  -- The alignment as "old|new" per display row.
  local function rows(view, olds, news)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, news)
    view.bufnr = buf
    view.old_text = table.concat(olds, "\n")
    return vim.tbl_map(function(e)
      return (e.old and olds[e.old] or "-") .. "|" .. (e.new and news[e.new] or "-")
    end, oldside.alignment(view))
  end

  local old = { "one", "two", "three", "four" }
  local new = { "one", "TWO", "two and a half", "three", "four" }
  local one_by_two = { { start_a = 2, count_a = 1, start_b = 2, count_b = 2 } }

  -- By the hunk shapes alone: the two blocks start opposite each other
  -- and the shorter side runs out first, which is what every
  -- side-by-side diff has always drawn.
  it("advances unchanged lines in step, and pads a replacement to the longer side", function()
    assert.are.same({
      "one|one",
      "two|TWO",
      "-|two and a half",
      "three|three",
      "four|four",
    }, rows({ hunks = one_by_two }, old, new))
  end)

  -- Here the backend says the old `two` answers to `two and a half`,
  -- not to `TWO`.
  it("follows the backend's own pairing where it has one", function()
    assert.are.same({
      "one|one",
      "-|TWO",
      "two|two and a half",
      "three|three",
      "four|four",
    }, rows({ hunks = one_by_two, pairs = { [1] = 1, [3] = 2, [4] = 3, [5] = 4 } }, old, new))
  end)

  -- `start_b` is "the line after which content was removed", so the
  -- padding goes under new line 2, not over it.
  it("pads a deletion on the new side under the row it follows", function()
    assert.are.same({
      "one|one",
      "two|two",
      "three|-",
      "four|-",
    }, rows({ hunks = { { start_a = 3, count_a = 2, start_b = 2, count_b = 0 } } }, old, { "one", "two" }))
  end)
end)

-- Counting added and removed lines is exact outside a hunk and inside one
-- that pairs its two sides. It is useless inside one that does not: a file
-- whose functions were moved into a class comes back from the line
-- backend as ONE hunk covering all of it, and counting alone puts every
-- row in it on the same line. The text has to break the tie.
describe("oldside.map_row", function()
  local old_lines = {
    "import pytest",                                  -- 1
    "",                                               -- 2
    "from widgetry.core import Widget, normalise",    -- 3
    "",                                               -- 4
    "",                                               -- 5
    "def test_area():",                               -- 6
    "    widget = Widget(name=\"a\")",                 -- 7
    "    assert widget.area() == 6.0",                -- 8
  }
  local new_lines = {
    "import pytest",                                  -- 1
    "",                                               -- 2
    "from widgetry.core import Widget, clamp",        -- 3
    "",                                               -- 4
    "",                                               -- 5
    "class TestWidget:",                              -- 6
    "    def test_area(self):",                       -- 7
    "        widget = Widget(name=\"a\")",             -- 8
    "        assert widget.area() == 6.0",            -- 9
  }

  local function old_row(row, hunks)
    -- One hunk over everything from line 3, six old lines against seven new.
    hunks = hunks or { { start_a = 3, count_a = 6, start_b = 3, count_b = 7 } }
    return oldside.map_row(hunks, row, true, new_lines, old_lines)
  end

  it("finds the line an indented, re-signatured line came from", function()
    assert.are.equal(6, old_row(7))
  end)

  it("finds the line a body that only moved came from", function()
    assert.are.equal(7, old_row(8))
  end)

  it("leaves a line above every hunk where it always was", function()
    assert.are.equal(1, old_row(1))
  end)

  -- A blank line matches everything, so position decides rather than a
  -- coincidence of text.
  it("counts for a line with no text to match", function()
    assert.are.equal(4, old_row(4))
  end)

  it("answers a hunk that pairs up by position alone", function()
    assert.are.equal(4, old_row(4, { { start_a = 4, count_a = 1, start_b = 4, count_b = 1 } }))
  end)

  -- A pure insertion has no line on the other side at all; the row it
  -- follows is the closest true answer.
  it("answers an inserted block with the line it follows", function()
    assert.are.equal(3, old_row(5, { { start_a = 3, count_a = 0, start_b = 4, count_b = 2 } }))
  end)
end)

-- The review's panes are scratch buffers, so a mapping left behind there
-- dies with them. Here it would sit on a file buffer for the rest of the
-- session. A global mapping is the case that bites: maparg reports it as
-- the mapping in effect, and "restoring" it re-creates it globally while
-- the buffer-local one still shadows it.
describe("the view and your mappings", function()
  local buf, mine

  it("takes a mapping the buffer had while it is open", function()
    -- Nothing following the cursor: a review running would have
    -- annotated the file on arrival -- before the mapping this section is
    -- about existed.
    pane_mod.close(pane_mod.get())
    view_mod.close(edit("calc.lua"))
    vim.keymap.set("n", kv.hunk_next, "<Cmd>echo 'mine'<CR>", { desc = "user's own" })
    mine = vim.fn.maparg(kv.hunk_next, "n")

    buf = run_on("calc.lua", "feature/math")
    assert.are_not.equal(mine, vim.fn.maparg(kv.hunk_next, "n"))
  end)

  it("hands it straight back on close, leaving nothing of its own", function()
    view_mod.close(buf)
    assert.are.equal(mine, vim.fn.maparg(kv.hunk_next, "n"))
    assert.are.equal("", vim.fn.maparg(kv.layout, "n"))
  end)

  vim.keymap.del("n", kv.hunk_next)
end)

describe("a view that cannot open", function()
  local function list_opened(what)
    local said = h.notes(function()
      uatis.run({ fargs = { "main" } })
      h.wait_for(function()
        local p = pane_mod.get()
        return p ~= nil and (p.renders or 0) > 0
      end, "the file list from " .. what)
    end)
    local p = pane_mod.get()
    pane_mod.close(p)
    return p, said
  end

  -- A buffer with no file in it has nothing to annotate -- but "what has
  -- this branch changed" is still a good question, and it is about the
  -- repository rather than about whichever buffer is on screen.
  it("opens the file list from a buffer with no file, saying nothing", function()
    vim.cmd("enew!")
    local p, said = list_opened("a buffer with no file in it")
    assert.are.equal("main", p.ref)
    assert.are.same({}, said)
  end)

  -- A terminal is called `term://<cwd>//<pid>:<shell>`, and handing that
  -- to `git -C` asks about a directory that does not exist -- which used
  -- to answer "not inside a git repository" from inside one.
  it("opens it from a buffer whose name is not a path, too", function()
    vim.cmd("enew!")
    vim.bo.buftype = "nofile"
    vim.api.nvim_buf_set_name(0, "term://" .. fixture .. "//4242:/bin/bash")
    local _, said = list_opened("a buffer whose name is not a path")
    assert.are.same({}, said)
  end)

  it("names an unknown revision as one, and leaves no view", function()
    local buf = edit("calc.lua")
    -- Re-reading the file does not end a review on it: what is asked is
    -- whether a ref that does not resolve leaves a view, not whether one
    -- was already there.
    if view_mod.get(buf) then
      view_mod.stop(view_mod.get(buf))
    end
    assert.matches("unknown revision", complaint(function() uatis.run({ fargs = { "no-such-ref" } }) end), 1, true)
    assert.is_nil(view_mod.get(buf))
  end)
end)

-- The old side comes from `git show` and the new side from the buffer.
-- A repo that commits its line endings the Windows way hands back a
-- blob whose every line ends in `\r`, while nvim has stripped them into
-- `fileformat=dos` -- and every line would then differ from itself.
-- `vim.system(..., { text = true })` normalises that away; this is here
-- so nobody takes it for a type annotation and turns it off.
describe("a repository that stores CRLF", function()
  local repo = vim.fn.tempname()
  local buf, v

  local function git(...)
    return vim.fn.system(vim.list_extend({ "git", "-C", repo }, { ... }))
  end

  it("is read by nvim as a dos file", function()
    vim.fn.mkdir(repo, "p")
    git("init", "-q", ".")
    git("config", "user.email", "t@example.com")
    git("config", "user.name", "t")
    git("config", "core.autocrlf", "false")
    -- Written as bytes, so the CRLF survives into the blob.
    vim.fn.writefile({ "local a = 1\r", "local b = 2\r", "local c = 3\r" }, repo .. "/dos.lua", "b")
    git("add", "dos.lua")
    git("commit", "-qm", "one")

    vim.cmd("silent! only")
    vim.cmd("edit! " .. vim.fn.fnameescape(repo .. "/dos.lua"))
    buf = vim.api.nvim_get_current_buf()
    assert.are.equal("dos", vim.bo[buf].fileformat)
  end)

  it("counts the one changed line as the only change", function()
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "local b = 22" })
    view_mod.open("HEAD")
    h.wait_for(function()
      v = view_mod.get(buf)
      return v ~= nil and (v.renders or 0) > 0
    end, "a view over a file with CRLF behind it")
    assert.are.equal(1, v.added)
    assert.are.equal(1, v.removed)
  end)

  it("draws on one row of the file and no other", function()
    local rows = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1, {})) do
      rows[m[2]] = true
    end
    assert.are.equal(1, vim.tbl_count(rows))
  end)

  view_mod.stop(v)
  vim.cmd("silent! bwipeout! " .. buf)
  vim.fn.delete(repo, "rf")
end)

-- Every way in has to say so, and say WHERE: a file is asked about by
-- its own path and a buffer with no file by the working directory, so
-- "not inside a git repository" on its own leaves the reader guessing
-- which of the two the answer is about.
describe("outside a repository", function()
  local dir = vim.fn.tempname()
  local file = dir .. "/loose.lua"
  local buf

  it("refuses a file by name, leaving no view on it", function()
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ "local M = {}", "return M" }, file)
    -- In a tab of its own: a review running in this one would answer the
    -- key before any of this got asked, and the `lcd` below would follow
    -- the reader back out.
    vim.cmd("tabnew")
    vim.cmd("silent! only")
    vim.cmd("edit! " .. vim.fn.fnameescape(file))
    buf = vim.api.nvim_get_current_buf()
    assert.are.equal("uatis: " .. file .. " is not inside a git repository",
      complaint(function() view_mod.open("main") end))
    assert.is_nil(view_mod.get(buf))
  end)

  -- Which resolves a base branch first.
  it("says the same through the key, putting up neither a view nor a list", function()
    assert.matches("is not inside a git repository", complaint(uatis.toggle_diff), 1, true)
    assert.is_nil(view_mod.get(buf))
    assert.is_nil(pane_mod.get())
  end)

  -- The question is about the working directory, so that is what the
  -- answer names.
  it("answers a buffer with no file about the directory it is in", function()
    vim.cmd("enew")
    vim.cmd("lcd " .. vim.fn.fnameescape(dir))
    assert.are.equal("uatis: " .. dir .. " is not inside a git repository", complaint(uatis.toggle_diff))
    assert.is_nil(pane_mod.get())
  end)

  it("answers choosing a base branch the same way", function()
    assert.are.equal("uatis: " .. dir .. " is not inside a git repository",
      complaint(function() uatis.set_base_branch() end))
  end)

  vim.cmd("silent! tabclose")
  vim.cmd("silent! bwipeout! " .. buf)
  vim.fn.delete(dir, "rf")
end)
