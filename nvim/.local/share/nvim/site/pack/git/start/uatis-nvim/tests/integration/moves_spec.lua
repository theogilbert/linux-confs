-- Moves, in a view on a real file: `<C-]>` between the two ends, the old
-- window reading across from the old copy, both ends read, and a
-- definition moved to another file found by the review.
local h = require("helpers")
local uatis = require("uatis")
local overlay = require("uatis.overlay")
local view_mod = require("uatis.view")
local pane_mod = require("uatis.pane")
local ok, eq, wait_for = h.ok, h.eq, h.wait_for
local open_view, act, marks = h.open_view, h.act, h.marks
local removed = h.removed

-- The two lines naming a move's ends are virtual, so the key works from
-- the rows they stand for. On an identifier it is go-to-definition's, as
-- it was: a moved function is made of symbols. A keyword is not one.
describe("<C-]> goes to the other end of a move, and only off a symbol", function()
  local k, symbol, buf, view, mv
  it("one function read as moved", function()
    k = require("uatis.config").keys.view.move_jump
    symbol = 0
    vim.keymap.set("n", k, function() symbol = symbol + 1 end)
    buf, view = open_view("calc.lua", "main")
    act(view, function()
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        "local M = {}", "", "function M.sub(a, b)", "  return a - b", "end", "",
        "function M.add(a, b)", "  return a + b", "end", "", "return M",
      })
    end, "a render of the moved function")
    wait_for(function() return view.moves ~= nil end, "the move to be read")
    mv = view.moves and view.moves[1]
    if ok(mv ~= nil and #view.moves == 1, "one function read as moved") then
      local function press(row, col)
        vim.api.nvim_win_set_cursor(0, { row, col })
        vim.api.nvim_feedkeys(vim.keycode(k), "mx", false)
      end
      local at = math.min(mv.at, vim.api.nvim_buf_line_count(buf))
      -- The indentation of the body's second row.
      press(mv.new.first + 1, 0)
      wait_for(function() return vim.api.nvim_win_get_cursor(0)[1] == at end, "the jump to the old end")
      eq(vim.api.nvim_win_get_cursor(0)[1], at, "from inside the moved function to where it was")
      local line = vim.api.nvim_buf_get_lines(buf, at - 1, at, false)[1]
      press(at, math.max((line:find("[^%w_]") or 1) - 1, 0))
      if line:match("^[%w_]") and not line:find("[^%w_]") then
        print("  skip the jump back (the old end hangs above a row of one word)")
      else
        wait_for(function() return vim.api.nvim_win_get_cursor(0)[1] == mv.new.first end,
          "the jump back")
        eq(vim.api.nvim_win_get_cursor(0)[1], mv.new.first, "...and back again")
      end
      -- A keyword cannot be a definition's name.
      press(at, 0)
      wait_for(function() return vim.api.nvim_win_get_cursor(0)[1] ~= at end, "a jump")
      press(mv.new.first, 0)
      wait_for(function() return vim.api.nvim_win_get_cursor(0)[1] == at end,
        "the jump from the keyword the signature opens with")
      eq(vim.api.nvim_win_get_cursor(0)[1], at, "on `function`, the key is still the move's")
      eq(symbol, 0, "none of those went through the mapping it shadows")
      press(mv.new.first, ("function M."):len())
      eq(symbol, 1, "on a symbol, the mapping that was there before runs")
    end
    view_mod.close(buf)
    vim.keymap.del("n", k)
    vim.cmd("edit!")
  end)

end)

-- The indent of a before-image is spaces as wide as the gutter was when it
-- was drawn. A gutter that changes after -- 'number' turned on, a sign
-- column opening -- is found on the next redraw and drawn for; and a view
-- whose own window has closed while its buffer stays in another is drawn
-- for THAT one, not for a window with no gutter at all.
describe("a before-image follows the gutter it is drawn beside", function()
  local buf, view, first
  local function indent(buf)
    for _, m in ipairs(marks(buf)) do
      for _, vl in ipairs(m[4].virt_lines or {}) do
        if vl[1] and vl[1][2] == "UatisSign" then
          return vim.fn.strdisplaywidth(vl[1][1])
        end
      end
    end
  end
  local function textoff()
    return vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].textoff
  end
  it("drawn for a window with no gutter", function()
    vim.wo.number, vim.wo.signcolumn = false, "no"
    buf, view = open_view("calc.lua", "main")
    act(view, function()
      vim.api.nvim_buf_set_lines(buf, 3, 4, false, {})
    end, "a render with a line removed")
    eq(indent(buf), math.max(textoff(), 1), "drawn for a window with no gutter")
  end)

  it("the gutter opening is drawn for", function()
    act(view, function()
      vim.wo.number, vim.wo.signcolumn = true, "yes"
      vim.cmd("redraw")
    end, "a render once the gutter has opened")
    vim.cmd("redraw")
    eq(indent(buf), textoff(), "the gutter opening is drawn for")
  end)

  it("measured on the window the buffer is still in", function()
    first = vim.api.nvim_get_current_win()
    vim.cmd("vsplit")
    vim.wo.number, vim.wo.signcolumn = true, "yes:2"
    vim.api.nvim_win_close(first, true)
    act(view, function()
      vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "-- edited" })
    end, "a render after the view's own window closed")
    vim.cmd("redraw")
    eq(indent(buf), textoff(), "measured on the window the buffer is still in")
  end)

  view_mod.close(buf)
  vim.cmd("edit!")
  vim.wo.number, vim.wo.signcolumn = false, "auto"
end)

-- The alignment keeps one order and a move breaks it, so the two copies
-- stand opposite blank rows. The old copy is not red -- only what was
-- removed inside it is -- and while the cursor is in the new copy the
-- old window shows the old one, row for row. `<CR>` and `<C-]>` from
-- the old copy land on the row it became.
describe("side by side, a move is read across from its old copy", function()
  local oldside, buf, view, mv
  it("M.sub read as moved and edited", function()
    oldside = require("uatis.oldside")
    buf, view = open_view("calc.lua", "main")
    act(view, function()
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        "local M = {}", "", "function M.sub(a, b)", "  return b - a", "end", "",
        "function M.add(a, b)", "  return a + b", "end", "", "return M",
      })
    end, "a render of the moved function")
    wait_for(function() return view.moves ~= nil end, "the move to be read")
    mv = view.moves and view.moves[1]
    act(view, function() view_mod.choose_layout(view, "side") end, "the side-by-side render")
    wait_for(function() return oldside.is_open(view) and view.old_at_line ~= nil end,
      "the old window")
    if ok(mv ~= nil and mv.name == "M.sub" and mv.changes == 1, "M.sub read as moved and edited") then
      local ob = view.old.buf
      local function marks(line)
        local row = view.old_at_line[line] - 1
        return vim.api.nvim_buf_get_extmarks(ob, oldside.ns, { row, 0 }, { row, -1 }, { details = true })
      end
      local function red(line)
        for _, m in ipairs(marks(line)) do
          if (m[4].line_hl_group or m[4].hl_group) == "UatisDeleteBand" then
            return true
          end
        end
        return false
      end
      eq({ red(mv.old.first), red(mv.old.first + 1), red(mv.old.last) }, { false, true, false },
        "only the line the moved function lost is red in the old window")
      local note
      for _, m in ipairs(marks(mv.old.first)) do
        note = note or (m[4].virt_text and m[4].virt_text[1][1])
      end
      ok(note and note:find("M.sub moved to line 3", 1, true),
        "and its first row says where it went, got: " .. tostring(note))
      local lines = 0
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1, { details = true })) do
        lines = lines + #(m[4].virt_lines or {})
      end
      eq(lines, 0, "nothing in your buffer takes a row the old window does not have")
      local bar = vim.api.nvim_eval_statusline("%{v:lua.require'uatis.oldside'.number()}",
        { winid = view.old.win, use_statuscol_lnum = view.old_at_line[mv.old.first] }).str
      ok(bar:find("UatisMove", 1, true), "the old copy carries the bar, got: " .. bar)

      vim.api.nvim_set_current_win(view.win)
      vim.api.nvim_win_set_cursor(view.win, { mv.new.first + 1, 0 })
      oldside.sync(view, mv.new.first + 1)
      eq(view.old_of_row[vim.api.nvim_win_get_cursor(view.old.win)[1]], mv.old.first + 1,
        "inside the new copy, the old window stands on the old one")

      for _, key in ipairs({ require("uatis.config").keys.old.jump,
        require("uatis.config").keys.view.move_jump }) do
        vim.api.nvim_set_current_win(view.old.win)
        vim.api.nvim_win_set_cursor(view.old.win, { view.old_at_line[mv.old.last], 0 })
        vim.api.nvim_feedkeys(vim.keycode(key), "mx", false)
        eq({ vim.api.nvim_get_current_win() == view.win, vim.api.nvim_win_get_cursor(view.win)[1] },
          { true, mv.new.last }, key .. " from the old copy lands on the row it became")
      end
    end
    view_mod.choose_layout(view, "inline")
    view_mod.close(buf)
    vim.cmd("edit!")
  end)

end)

-- git does not see a move: it reports whatever its own diff made of the
-- rows, and its chunk where the definition used to be has no row on the
-- new side for the old end to stand on. That end stands on git's chunks
-- by their OLD rows, and each end is left on its own -- the move is read
-- once both are, and not before.
describe("a move is read at both ends", function()
  local cfg, read, dir, calc, spill, buf, list, v, f
  local function sh(...)
    vim.system({ "git", "-C", dir, ... }, { text = true }):wait()
  end
  it("one move, and git's two chunks for it", function()
    cfg = require("uatis.config")
    read = require("uatis.read")
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    calc = { "local M = {}", "", "function M.add(a, b)", "  return a + b", "end", "",
      "function M.sub(a, b)", "  return a - b", "end", "", "return M" }
    sh("init", "-q", "-b", "main")
    sh("config", "user.email", "t@example.com")
    sh("config", "user.name", "T")
    sh("config", "commit.gpgsign", "false")
    vim.fn.writefile(calc, dir .. "/calc.lua")
    sh("add", "calc.lua")
    sh("commit", "-qm", "initial")
    vim.fn.writefile({ "local M = {}", "", "function M.sub(a, b)", "  return b - a", "end", "",
      "function M.add(a, b)", "  return a + b", "end", "", "return M" }, dir .. "/calc.lua")

    spill = cfg.pane.chunk_spill
    cfg.pane.chunk_spill = false
    vim.cmd("tabnew")
    vim.cmd("tcd " .. vim.fn.fnameescape(dir))
    vim.cmd("edit calc.lua")
    buf = vim.api.nvim_get_current_buf()
    uatis.run({ fargs = { "main" } })
    wait_for(function()
      local v = view_mod.get(buf)
      return v ~= nil and (v.renders or 0) > 0 and v.moves ~= nil
    end, "the move to be read")
    wait_for(function()
      list = pane_mod.get()
      return list ~= nil and (list.renders or 0) > 0
    end, "the list")
    v = view_mod.get(buf)
    f = require("uatis.patch").find(list.files, "calc.lua")
    if ok(v and v.moves and f and #f.chunks == 2, "one move, and git's two chunks for it") then
      local function state()
        local s = ""
        for _, c in ipairs(f.chunks) do
          s = s .. (read.chunk_read(list, f, c) and "R" or ".")
        end
        return s, read.stops_read(list, f, view_mod.stops(v))
      end
      eq(#view_mod.stops(v), #v.anchors, "the read stops are the stops `]c` makes")
      local _, before = state()
      eq(before, { done = 0, total = #v.anchors }, "nothing is read before the reader has moved")
      local km = vim.fn.maparg(cfg.keys.view.hunk_next, "n", false, true)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local seen = {}
      for _ = 1, #v.anchors + 1 do
        km.callback()
        table.insert(seen, (state()))
      end
      local last = seen[#seen]
      eq({ seen[#seen - 1], last }, { "R.", "RR" },
        "the new copy read leaves the old end's chunk unread, until the old end is left too")
      local _, after = state()
      eq(after, { done = #v.anchors, total = #v.anchors }, "and every stop is read")
      ok(read.is_read(list, f), "which is the file read")

      -- `<C-]>` off an end leaves it, as `]c` does: what was stood on is
      -- read, and the end jumped to is not, until it too is left.
      list.read, list.left = {}, {}
      local mv = v.moves[1]
      local count = vim.api.nvim_buf_line_count(buf)
      local at = math.max(math.min(mv.at, count), 1)
      local jump = vim.keycode(cfg.keys.view.move_jump)
      vim.api.nvim_win_set_cursor(0, { mv.new.first + 1, 0 })
      vim.api.nvim_feedkeys(jump, "mx", false)
      wait_for(function() return vim.api.nvim_win_get_cursor(0)[1] == at end, "<C-]> to the old end")
      local s1, h1 = state()
      eq({ s1, h1.done }, { "R.", 2 },
        "<C-]> off the new copy leaves it and the edit in it: their chunk is read")
      vim.api.nvim_feedkeys(jump, "mx", false)
      wait_for(function() return vim.api.nvim_win_get_cursor(0)[1] == mv.new.first end, "<C-]> back")
      local s2, h2 = state()
      eq({ s2, h2.done }, { "RR", 3 }, "and back off the old end leaves that too")
    end
    view_mod.stop(view_mod.get(buf))
    vim.cmd("tabclose")
    cfg.pane.chunk_spill = spill
    vim.fn.delete(dir, "rf")
  end)

end)

-- Taken out of one file and put into another, a function is in two
-- comparisons that cannot see each other: removed whole in one, added
-- whole in the other. The review pairs them, and each file draws its own
-- end -- one line where it went, an edit of its old self where it came.
describe("a definition moved to another file is drawn as a move at both ends", function()
  local cfg, read, dir, spill, calc, list, index, vc, util, vu, mv, stops, f, cstops, at_old, k, at, skip
  local function sh(...)
    vim.system({ "git", "-C", dir, ... }, { text = true }):wait()
  end
  local function virt(buf)
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1, { details = true })) do
      for _, vl in ipairs(m[4].virt_lines or {}) do
        local t = ""
        for _, c in ipairs(vl) do
          t = t .. c[1]
        end
        table.insert(out, (t:gsub("%s+$", "")))
      end
    end
    return out
  end

  it("the review pairs the function across the two files", function()
    cfg = require("uatis.config")
    read = require("uatis.read")
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    sh("init", "-q", "-b", "main")
    sh("config", "user.email", "t@example.com")
    sh("config", "user.name", "T")
    sh("config", "commit.gpgsign", "false")
    vim.fn.writefile({ "local M = {}", "", "function M.add(a, b)", "  return a + b", "end", "",
      "function M.sub(a, b)", "  local d = a - b", "  return d", "end", "", "return M" }, dir .. "/calc.lua")
    vim.fn.writefile({ "local U = {}", "", "function U.id(x)", "  return x", "end", "", "return U" },
      dir .. "/util.lua")
    sh("add", ".")
    sh("commit", "-qm", "initial")
    vim.fn.writefile({ "local M = {}", "", "function M.add(a, b)", "  return a + b", "end", "",
      "return M" }, dir .. "/calc.lua")
    vim.fn.writefile({ "local U = {}", "", "function U.id(x)", "  return x", "end", "",
      "function M.sub(a, b)", "  local d = b - a", "  return d", "end", "", "return U" }, dir .. "/util.lua")

    spill = cfg.pane.chunk_spill
    cfg.pane.chunk_spill = false
    vim.cmd("tabnew")
    vim.cmd("tcd " .. vim.fn.fnameescape(dir))
    vim.cmd("edit calc.lua")
    calc = vim.api.nvim_get_current_buf()
    uatis.run({ fargs = { "main" } })
    wait_for(function()
      list = pane_mod.get()
      return list ~= nil and list.moves_across ~= nil and #list.moves_across > 0
    end, "the review's index of moves between files")
    index = list and list.moves_across or {}
    eq(vim.tbl_map(function(e) return { e.name, e.from.path, e.to.path } end, index),
      { { "M.sub", "calc.lua", "util.lua" } }, "the review pairs the function across the two files")
  end)

  it("calc.lua has the move's old end", function()
    wait_for(function()
      local v = view_mod.get(calc)
      return v ~= nil and v.moves ~= nil
    end, "calc.lua to draw its end")
    vc = view_mod.get(calc)
    eq(vc and vim.tbl_map(function(m) return m.kind end, vc.moves), { "out" }, "calc.lua has the move's old end")
    eq(virt(calc), { "↦M.sub moved to util.lua:7 · 1 change" },
      "drawn as one line, not the function in red, counting what changed on the way")
  end)

  it("util.lua has the new copy, compared against its old self", function()
    vim.cmd("edit util.lua")
    util = vim.api.nvim_get_current_buf()
    wait_for(function()
      local v = view_mod.get(util)
      return v ~= nil and v.moves ~= nil
    end, "util.lua to draw its end")
    vu = view_mod.get(util)
    mv = vu and vu.moves[1]
    eq(mv and { mv.kind, mv.new.first, mv.new.last, mv.changes }, { "in", 7, 10, 1 },
      "util.lua has the new copy, compared against its old self")
    eq(virt(util), { "↤M.sub moved from calc.lua:7 · 1 change", "-  local d = a - b" },
      "only what was edited on the way is drawn as removed")
  end)

  it("the new copy is a stop", function()
    stops = view_mod.stops(vu)
    ok(#stops >= 1 and stops[1].lo == 7, "the new copy is a stop")
  end)

  it("and the old end stands on git's chunk where the function was", function()
    f = require("uatis.patch").find(list.files, "calc.lua")
    cstops = view_mod.stops(vc)
    at_old = {}
    for _, s in ipairs(cstops) do
      if s.old then
        vim.list_extend(at_old, read.covering(f, s))
      end
    end
    ok(#at_old > 0, "and the old end stands on git's chunk where the function was")
  end)

  it("<C-]> on the new copy lands on the old end, in the other file", function()
    k = vim.keycode(cfg.keys.view.move_jump)
    vim.api.nvim_win_set_cursor(0, { 7, 0 })
    vim.api.nvim_feedkeys(k, "mx", false)
    wait_for(function() return vim.api.nvim_get_current_buf() == calc end, "<C-]> into calc.lua")
    at = math.max(math.min(vc.moves[1].at, vim.api.nvim_buf_line_count(calc)), 1)
    eq(vim.api.nvim_win_get_cursor(0)[1], at, "<C-]> on the new copy lands on the old end, in the other file")
  end)

  it("...and back onto the new copy", function()
    vim.api.nvim_feedkeys(k, "mx", false)
    wait_for(function() return vim.api.nvim_get_current_buf() == util end, "<C-]> back into util.lua")
    eq(vim.api.nvim_win_get_cursor(0)[1], 7, "...and back onto the new copy")
  end)

  -- Which files are looked at is a question of language: prose and data
  -- have trees too. Moves inside one file are not affected.
  it("a language left out is not looked at between files", function()
    skip = cfg.diff.move.across_skip
    cfg.diff.move.across_only = { "python" }
    require("uatis.xmoves").build(list)
    eq(list.moves_across, {}, "a language left out is not looked at between files")
  end)

  it("...and neither is one skipped", function()
    cfg.diff.move.across_only = false
    cfg.diff.move.across_skip = { "lua" }
    require("uatis.xmoves").build(list)
    eq(list.moves_across, {}, "...and neither is one skipped")
  end)

  cfg.diff.move.across_skip = nil
  require("uatis.xmoves").build(list)
  wait_for(function() return #(list.moves_across or {}) == 1 end, "the index back")
  cfg.diff.move.across_skip = skip

  view_mod.stop(view_mod.get(util))
  vim.cmd("tabclose")
  cfg.pane.chunk_spill = spill
  vim.fn.delete(dir, "rf")
end)

-- With a commit on show both sides come out of git -- the commit and
-- its parent -- and the index is the answer for that one commit, never
-- handed to a view measuring another. `:UatisShow` and stepping a branch
-- commit by commit read the move the way the working tree does.
describe("a move between files, in a commit", function()
  local dir, sha, home, p, idx, v, at, u, turns, cur
  local function sh(...)
    return vim.trim(vim.system({ "git", "-C", dir, ... }, { text = true }):wait().stdout or "")
  end
  it(":UatisShow pairs the move out of the commit and its parent", function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    sh("init", "-q", "-b", "main")
    sh("config", "user.email", "t@example.com")
    sh("config", "user.name", "T")
    sh("config", "commit.gpgsign", "false")
    vim.fn.writefile({ "local M = {}", "", "function M.add(a, b)", "  return a + b", "end", "",
      "function M.sub(a, b)", "  local d = a - b", "  return d", "end", "", "return M" }, dir .. "/calc.lua")
    vim.fn.writefile({ "local U = {}", "", "function U.id(x)", "  return x", "end", "", "return U" },
      dir .. "/util.lua")
    sh("add", ".")
    sh("commit", "-qm", "initial")
    sh("switch", "-qc", "feat")
    vim.fn.writefile({ "local M = {}", "", "function M.add(a, b)", "  return a + b", "end", "",
      "return M" }, dir .. "/calc.lua")
    vim.fn.writefile({ "local U = {}", "", "function U.id(x)", "  return x", "end", "",
      "function M.sub(a, b)", "  local d = b - a", "  return d", "end", "", "return U" }, dir .. "/util.lua")
    sh("commit", "-qam", "move sub")
    sha = sh("rev-parse", "HEAD")

    vim.cmd("tabnew")
    home = vim.api.nvim_get_current_tabpage()
    vim.cmd("tcd " .. vim.fn.fnameescape(dir))
    uatis.show_commit(sha)
    wait_for(function()
      p = pane_mod.get()
      return p ~= nil and p.standalone and p.moves_across ~= nil and #p.moves_across == 1
    end, "the commit's index of moves between files")
    eq(p and p.moves_across and { p.moves_across[1].from.path, p.moves_across[1].to.path },
      { "calc.lua", "util.lua" }, ":UatisShow pairs the move out of the commit and its parent")
  end)

  it("the commit's calc.lua has the old end", function()
    for i, f in ipairs(p and p.files or {}) do
      if f.path == "calc.lua" then idx = i end
    end
    pane_mod.goto_file(p, idx)
    wait_for(function()
      v = view_mod.get(vim.api.nvim_get_current_buf())
      return v ~= nil and v.relpath == "calc.lua" and v.moves ~= nil
    end, "calc.lua at the commit to draw its end")
    eq(v and vim.tbl_map(function(m) return m.kind end, v.moves), { "out" },
      "the commit's calc.lua has the old end")
  end)

  it("where the copy is an edit of its old self", function()
    at = v and math.max(math.min(v.moves[1].at, vim.api.nvim_buf_line_count(v.bufnr)), 1)
    if v then
      vim.api.nvim_win_set_cursor(0, { at, 0 })
      vim.api.nvim_feedkeys(vim.keycode(require("uatis.config").keys.view.move_jump), "mx", false)
    end
    wait_for(function()
      local u = view_mod.get(vim.api.nvim_get_current_buf())
      return u ~= nil and u.relpath == "util.lua" and u.moves ~= nil
        and vim.api.nvim_win_get_cursor(0)[1] == 7
    end, "<C-]> into the commit's util.lua, on the new copy")
    u = view_mod.get(vim.api.nvim_get_current_buf())
    eq(u and u.moves[1] and { u.moves[1].kind, u.moves[1].changes }, { "in", 1 },
      "where the copy is an edit of its old self")
  end)

  it("stepping onto the commit finds the move in it", function()
    if u then
      view_mod.stop(u)
    end
    wait_for(function() return pane_mod.get() == nil or not pane_mod.get().standalone end,
      "the commit's review to end")

    -- Commit by commit: the branch's one commit is the move, and entering it
    -- builds that commit's index.
    if vim.api.nvim_tabpage_is_valid(home) then
      vim.api.nvim_set_current_tabpage(home)
    end
    vim.cmd("edit calc.lua")
    uatis.run({ fargs = { "main" } })
    wait_for(function()
      p = pane_mod.get()
      return p ~= nil and (p.renders or 0) > 0
    end, "the branch review")
    turns = p.renders
    pane_mod.toggle_commits(p)
    wait_for(function()
      return p.commit ~= nil and (p.renders or 0) > turns and p.moves_across ~= nil
        and p.across_key == p.rev .. ":" .. p.commit.sha
    end, "the commit on show to have its own index")
    eq(#(p.moves_across or {}), 1, "stepping onto the commit finds the move in it")
  end)

  cur = view_mod.get(vim.api.nvim_get_current_buf())
  if cur then
    view_mod.stop(cur)
  end
  vim.cmd("tabclose")
  vim.fn.delete(dir, "rf")
end)

-- A module split up is several moves at once, and their sources and
-- destinations are every kind of file a review lists: a file nobody has
-- told git about yet, a file the branch deleted, a file it renamed.
describe("moves between files: into a new file, out of a deleted or renamed one, several at once", function()
  local dir, keep, list
  local function sh(...)
    return vim.trim(vim.system({ "git", "-C", dir, ... }, { text = true }):wait().stdout or "")
  end
  local function put(path, lines)
    vim.fn.writefile(lines, dir .. "/" .. path)
  end
  --- The moves the view on `path` draws, as `{ kind, name, changes }`.
  local function drawn(path)
    local idx
    for i, f in ipairs(list.files) do
      if f.path == path then
        idx = i
      end
    end
    if not idx then
      return "not listed"
    end
    pane_mod.goto_file(list, idx)
    local v
    wait_for(function()
      v = view_mod.get(vim.api.nvim_get_current_buf())
      return v ~= nil and v.relpath == path and v.moves ~= nil
    end, path .. " to draw its moves")
    local out = vim.tbl_map(function(m) return { m.kind, m.name, m.changes } end, v and v.moves or {})
    table.sort(out, function(x, y) return x[2] < y[2] end)
    return out
  end
  it("each paired with its own source: untracked, deleted, renamed and plain alike", function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    sh("init", "-q", "-b", "main")
    sh("config", "user.email", "t@example.com")
    sh("config", "user.name", "T")
    sh("config", "commit.gpgsign", "false")
    put("a.lua", { "local A = {}", "", "function A.one(x)", "  local y = x * 2", "  return y", "end", "",
      "function A.two(s)", "  local t = s:upper()", "  local u = t:reverse()", "  return u", "end", "",
      "return A" })
    put("gone.lua", { "local G = {}", "", "function G.three(list)", "  local n = 0",
      "  for _ in ipairs(list) do n = n + 1 end", "  return n", "end", "", "return G" })
    keep = { "local O = {}", "", "function O.keep(a, b, c)", "  local first = a or 1",
      "  local second = b or 2", "  local third = c or 3", "  local total = first + second + third",
      "  if total > 10 then", "    return total - 10", "  end", "  return total", "end", "" }
    put("old_name.lua", vim.list_extend(vim.deepcopy(keep), { "function O.four(t)", "  local k = {}",
      "  for key in pairs(t) do k[#k + 1] = key end", "  return k", "end", "", "return O" }))
    put("dest.lua", { "local D = {}", "", "function D.base()", "  return 0", "end", "", "return D" })
    sh("add", ".")
    sh("commit", "-qm", "initial")

    put("a.lua", { "local A = {}", "", "return A" })
    vim.fn.delete(dir .. "/gone.lua")
    sh("mv", "old_name.lua", "new_name.lua")
    put("new_name.lua", vim.list_extend(vim.deepcopy(keep), { "return O" }))
    put("new.lua", { "local N = {}", "", "function A.one(x)", "  local y = x * 3", "  return y", "end", "",
      "return N" })
    put("dest.lua", { "local D = {}", "", "function D.base()", "  return 0", "end", "",
      "function A.two(s)", "  local t = s:upper()", "  local u = t:reverse()", "  return u", "end", "",
      "function G.three(list)", "  local n = 0", "  for _ in ipairs(list) do n = n + 1 end", "  return n",
      "end", "", "function O.four(t)", "  local k = {}", "  for key in pairs(t) do k[#k + 1] = key end",
      "  return k", "end", "", "return D" })

    vim.cmd("tabnew")
    vim.cmd("tcd " .. vim.fn.fnameescape(dir))
    vim.cmd("edit dest.lua")
    uatis.run({ fargs = { "main" } })
    wait_for(function()
      list = pane_mod.get()
      return list ~= nil and list.moves_across ~= nil and #list.moves_across == 4
    end, "four moves between files")
    eq(list and vim.tbl_map(function(e)
      return { e.name, e.from.path, e.from.file, e.to.path }
    end, list.moves_across or {}), {
      { "A.two", "a.lua", "a.lua", "dest.lua" },
      { "G.three", "gone.lua", "gone.lua", "dest.lua" },
      { "O.four", "old_name.lua", "new_name.lua", "dest.lua" },
      { "A.one", "a.lua", "a.lua", "new.lua" },
    }, "each paired with its own source: untracked, deleted, renamed and plain alike")

    eq(drawn("dest.lua"), { { "in", "A.two", 0 }, { "in", "G.three", 0 }, { "in", "O.four", 0 } },
      "three moves into one file, each compared against its own old self")
    eq(drawn("new.lua"), { { "in", "A.one", 1 } }, "into a file git has not been told about")
    eq(drawn("a.lua"), { { "out", "A.one", 1 }, { "out", "A.two", 0 } },
      "two out of one file, each counting what changed on the way")
    eq(drawn("gone.lua"), { { "out", "G.three", 0 } }, "out of a file the branch deleted")
    eq(drawn("new_name.lua"), { { "out", "O.four", 0 } }, "out of a file the branch renamed")
  end)

  view_mod.stop(view_mod.get(vim.api.nvim_get_current_buf()))
  vim.cmd("tabclose")
  vim.fn.delete(dir, "rf")
end)

-- A leave can run a tick after the key that caused it -- `<C-]>`'s does
-- -- by which time another tab, with another review, may be current. Two
-- reviews can list a file of the same name, and the mark belongs to the
-- one whose view was left, never to the one that happens to be in front.
describe("a stop left in one review is marked in that review, from any tab", function()
  local x, y, tab_x, list_x, view_x, tab_y, list_y
  local function repo(after)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local function sh(...)
      vim.system({ "git", "-C", dir, ... }, { text = true }):wait()
    end
    sh("init", "-q", "-b", "main")
    sh("config", "user.email", "t@example.com")
    sh("config", "user.name", "T")
    sh("config", "commit.gpgsign", "false")
    vim.fn.writefile({ "local M = {}", "", "function M.add(a, b)", "  return a + b", "end", "",
      "function M.sub(a, b)", "  return a - b", "end", "", "return M" }, dir .. "/calc.lua")
    sh("add", ".")
    sh("commit", "-qm", "initial")
    vim.fn.writefile(after, dir .. "/calc.lua")
    return dir
  end
  local function review(dir)
    vim.cmd("tabnew")
    vim.cmd("tcd " .. vim.fn.fnameescape(dir))
    vim.cmd("edit calc.lua")
    local buf = vim.api.nvim_get_current_buf()
    uatis.run({ fargs = { "main" } })
    local list
    wait_for(function()
      local v = view_mod.get(buf)
      list = pane_mod.get()
      return list ~= nil and (list.renders or 0) > 0 and v ~= nil and (v.renders or 0) > 0
        and #(v.anchors or {}) > 0
    end, "a review of " .. dir)
    return vim.api.nvim_get_current_tabpage(), list, view_mod.get(buf)
  end

  -- Every line changed in the second, so any row of the first stands on
  -- a chunk of it.
  it("the second review's tab is in front", function()
    x = repo({ "local M = {}", "", "function M.add(a, b)", "  return (a or 0) + b", "end", "",
      "function M.sub(a, b)", "  return a - b", "end", "", "return M" })
    y = repo({ "local N = {}", "-- one", "-- two", "-- three", "-- four", "-- five", "-- six",
      "-- seven", "-- eight", "-- nine", "return N" })
    tab_x, list_x, view_x = review(x)
    tab_y, list_y = review(y)
    eq(vim.api.nvim_get_current_tabpage(), tab_y, "the second review's tab is in front")
  end)

  it("the stop is left in its own review", function()
    list_x.read, list_x.left, list_y.read, list_y.left = {}, {}, {}, {}
    view_mod.leave_move(view_x, view_x.anchors[1], nil)
    ok(next(list_x.left or {}) ~= nil, "the stop is left in its own review")
    eq({ list_y.read, list_y.left }, { {}, {} }, "and nothing is marked in the review in front")
  end)

  for _, tab in ipairs({ tab_y, tab_x }) do
    vim.api.nvim_set_current_tabpage(tab)
    view_mod.stop(view_mod.get(vim.api.nvim_get_current_buf()))
    vim.cmd("tabclose")
  end
  vim.fn.delete(x, "rf")
  vim.fn.delete(y, "rf")
end)


h.release()
