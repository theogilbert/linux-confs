-- `conflict.lua`: a conflicted file annotated in place, and the review of a merge.
--
-- Each describe merges `feature/clash` into `feature/math` itself (it
-- stops on calc.lua and helper.lua) and aborts the merge after.
local h = require("helpers")
local uatis = require("uatis")
local config = require("uatis.config")
local conflict = require("uatis.conflict")
local merge = require("uatis.merge")
local pane_mod = require("uatis.pane")
local ui = require("uatis.ui")
local fixture = h.repo()
local kc = config.keys.conflict

local function edit(name)
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/" .. name))
  return vim.api.nvim_get_current_buf()
end

local function start_merge(...)
  vim.cmd("silent! only")
  edit("stable.lua")
  h.git("switch", "-qf", "feature/math")
  vim.fn.system({ "git", "-C", fixture, ... })
  return vim.v.shell_error
end

local function abort_merge()
  vim.cmd("silent! only")
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].modified then
      vim.api.nvim_buf_call(b, function() vim.cmd("silent! edit!") end)
    end
  end
  edit("stable.lua")
  h.git("merge", "--abort")
  h.git("switch", "-qf", "main")
  vim.cmd("silent! checktime")
  assert.are.equal("", h.git("status", "--porcelain"))
end

-- What the annotator drew: line bands by row, token marks with their
-- text, and the eol note by row.
local function drawn(buf)
  local out = { band = {}, mark = {}, note = {}, inline = {} }
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, conflict.ns, 0, -1, { details = true })) do
    local row, d = m[2] + 1, m[4]
    if d.line_hl_group then
      out.band[row] = d.line_hl_group
    elseif d.hl_group then
      table.insert(out.mark, { hl = d.hl_group,
        text = vim.api.nvim_buf_get_text(buf, m[2], m[3], m[2], d.end_col, {})[1] })
    elseif d.virt_text and d.virt_text_pos == "eol" then
      out.note[row] = d.virt_text[1][1]
    elseif d.virt_text and d.virt_text_pos == "inline" then
      out.inline[row] = d.virt_text[1][1]
    end
  end
  return out
end

local function marked(buf, hl)
  local out = {}
  for _, m in ipairs(drawn(buf).mark) do
    if m.hl == hl then
      table.insert(out, m.text)
    end
  end
  return out
end

local function floats()
  local out = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(w)
    if cfg.relative ~= "" then
      table.insert(out, { title = cfg.title and cfg.title[1][1],
        lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false) })
    end
  end
  return out
end

local function lines(buf, from, to)
  return vim.api.nvim_buf_get_lines(buf, from, to, false)
end

local function n_marks(buf)
  return #vim.api.nvim_buf_get_extmarks(buf, conflict.ns, 0, -1, {})
end

-- `vim.notify` captured for a whole describe; `said()` is the last word.
local notes = {}
local real_notify = vim.notify
local function capture() notes = {}; vim.notify = function(msg) table.insert(notes, msg) end end
local function release() vim.notify = real_notify end
local function said() return notes[#notes] or "" end

local function undo_to(c, n)
  vim.cmd("silent undo")
  h.wait_for(function() return #c.blocks == n end, "the block to come back on undo")
end

-- The annotator on its own, with no list: the buffer git left the
-- markers in, banded and dimmed, a motion between the blocks, and a
-- key for each way of settling one -- every one of them an ordinary
-- edit in the reader's own buffer.
describe("a conflicted file, annotated in place", function()
  capture()
  local buf, c, b, announced

  it("is what the fixture's clashing branch leaves in calc.lua: one block", function()
    assert.are_not.equal(0, start_merge("merge", "feature/clash"))
    buf = edit("calc.lua")
    assert.are.equal(1, #merge.blocks(lines(buf, 0, -1)))
  end)

  it("has its diagnostics turned off, since a file with markers does not parse", function()
    vim.api.nvim_create_autocmd("User", {
      pattern = "UatisConflictAttach",
      once = true,
      callback = function(ev) announced = ev.data end,
    })
    assert.is_true(vim.diagnostic.is_enabled({ bufnr = buf }))
    c = conflict.attach(buf, vim.api.nvim_get_current_win(), fixture, "calc.lua")
    b = c.blocks[1]
    assert.are.equal(c, conflict.get(buf))
    assert.is_false(vim.diagnostic.is_enabled({ bufnr = buf }))
  end)

  -- For a config that wants to know.
  it("announces itself with `User UatisConflictAttach`, after binding its keys", function()
    assert.are.same({ buf = buf, root = fixture, path = "calc.lua" }, announced)
    assert.are_not.equal("", vim.fn.maparg(kc.next, "n"))
    assert.are.equal(ui.CONFLICT_WINBAR, vim.wo.winbar)
  end)

  it("dims the markers and bands each side as its own", function()
    local d = drawn(buf)
    assert.are.same({
      [b.top] = "UatisMarker", [b.top + 1] = "UatisOurs", [b.sep - 1] = "UatisOurs",
      [b.sep] = "UatisMarker", [b.sep + 1] = "UatisTheirs", [b.bottom] = "UatisMarker",
    }, {
      [b.top] = d.band[b.top], [b.top + 1] = d.band[b.top + 1], [b.sep - 1] = d.band[b.sep - 1],
      [b.sep] = d.band[b.sep], [b.sep + 1] = d.band[b.sep + 1], [b.bottom] = d.band[b.bottom],
    })
    assert.is_nil(d.band[b.bottom + 1])
    assert.matches("conflict 1 of 1", d.note[b.top], 1, true)
  end)

  -- The one label git writes that names nothing.
  it("names the branch HEAD is after the HEAD marker", function()
    h.wait_for(function() return c.head ~= nil end, "the branch HEAD is on")
    assert.are.equal(" (feature/math)", drawn(buf).inline[b.top])
  end)

  -- The base is not in the markers, so it comes out of the index: the
  -- three stages merged again in diff3 style and matched by content.
  it("says the wand can take the block, once the base is known", function()
    h.wait_for(function() return c.base_lines ~= nil end, "the base to come out of the index")
    assert.matches("resolvable by the word", drawn(buf).note[b.top], 1, true)
  end)

  it("marks the words each side changed, joined across the blanks inside a change", function()
    assert.is_true(vim.tbl_contains(marked(buf, "UatisTheirsMark"), "-- sum"))
    local ours = marked(buf, "UatisOursMark")
    assert.is_true(vim.tbl_contains(ours, "("))
    assert.is_true(vim.tbl_contains(ours, "or 0)"))
  end)

  it("steps to the first row of the block, and says so at the last", function()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    h.press(kc.next)
    assert.are.equal(b.top + 1, vim.api.nvim_win_get_cursor(0)[1])
    h.press(kc.next)
    assert.are.equal(b.top + 1, vim.api.nvim_win_get_cursor(0)[1])
    assert.matches("last conflict", said(), 1, true)
  end)

  it("says in the winbar which block the cursor is in", function()
    assert.matches("conflict 1/1", ui.conflict_winbar_text(c, 120), 1, true)
  end)

  -- Both sides' changes on the base, since they touch no common word.
  it("settles the block by the word with the wand", function()
    h.press(kc.resolve)
    assert.are.equal(0, #c.blocks)
    assert.are.same({
      "function M.add(a, b)  -- sum",
      "  return (a or 0) + (b or 0)",
      "end",
      "",
      "function M.sub(a, b)  -- difference",
      "  return b - a",
      "end",
      "",
      "function M.mul(a, b)",
      "  return a * b",
    }, lines(buf, 2, 12))
    assert.are.equal(b.top, vim.api.nvim_win_get_cursor(0)[1])
    assert.are.equal(0, n_marks(buf))
  end)

  it("announces the file done, and gives diagnostics back", function()
    assert.matches("calc.lua resolved", said(), 1, true)
    assert.matches("no conflicts left", ui.conflict_winbar_text(c, 120), 1, true)
    assert.are.same({ conflicts = 0, resolved = 1 }, conflict.state(c))
    assert.is_true(vim.diagnostic.is_enabled({ bufnr = buf }))
  end)

  -- A pick is an edit.
  it("puts the block back, marks and all, on u", function()
    undo_to(c, 1)
    assert.is_true(n_marks(buf) > 0)
  end)

  it("takes their side whole", function()
    h.press(kc.theirs)
    assert.are.same({
      "function M.add(a, b)  -- sum",
      "  return a + b",
      "end",
      "",
      "function M.sub(a, b)  -- difference",
      "  return a - b",
    }, lines(buf, 2, 8))
    undo_to(c, 1)
  end)

  it("takes ours then theirs", function()
    h.press(kc.both)
    assert.are.same(vim.list_extend(vim.list_extend({}, b.ours), b.theirs),
      lines(buf, b.top - 1, b.top - 1 + #b.ours + #b.theirs))
    undo_to(c, 1)
  end)

  it("takes the base, which the index supplied", function()
    h.press(kc.base)
    assert.are.same({
      "function M.add(a, b)",
      "  return a + b",
      "end",
      "",
      "function M.sub(a, b)",
      "  return a - b",
    }, lines(buf, 2, 8))
    undo_to(c, 1)
  end)

  it("says so of a pick outside any block", function()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    h.press(kc.ours)
    assert.matches("not inside a conflict", said(), 1, true)
  end)

  -- `K` on a marker row: the commit it names, beside the cursor, gone
  -- when the cursor moves. On any other row, the reader's own `K` --
  -- an LSP's hover is buffer-local, and three rows of a file are no
  -- reason to take it off the rest.
  describe("K", function()
    local hovered = 0

    local function peek_at(row)
      vim.api.nvim_win_set_cursor(0, { row, 0 })
      h.press(kc.peek)
      h.wait_for(function() return #floats() > 0 end, "the commit the marker names")
      return floats()[1]
    end

    it("on the opening marker shows HEAD's commit, without taking the cursor", function()
      conflict.close(buf)
      vim.keymap.set("n", kc.peek, function() hovered = hovered + 1 end, { buffer = buf })
      c = conflict.attach(buf, vim.api.nvim_get_current_win(), fixture, "calc.lua")
      h.wait_for(function() return c.head ~= nil end, "the branch HEAD is on")
      b = c.blocks[1]
      local f = peek_at(b.top)
      assert.are.equal(" HEAD (feature/math) ", f.title)
      assert.matches("Fixture Author", f.lines[1], 1, true)
      assert.are.equal(c.win, vim.api.nvim_get_current_win())
    end)

    -- Not the tip: feature/math's tip is "document clamp", which never
    -- went near calc.lua.
    it("shows the commit that last touched the block's lines on that side", function()
      assert.is_true(vim.tbl_contains(floats()[1].lines, "fix sub argument order and add mul"))
    end)

    it("closes its float when the cursor moves", function()
      vim.cmd("doautocmd CursorMoved")
      assert.are.equal(0, #floats())
    end)

    it("on the closing marker shows the branch being merged", function()
      local f = peek_at(b.bottom)
      assert.are.equal(" feature/clash ", f.title)
      assert.is_true(vim.tbl_contains(f.lines, "document calc, add clamp the other way round"))
      vim.cmd("doautocmd CursorMoved")
      assert.are.equal(0, hovered)
    end)

    it("is the reader's own inside the block", function()
      vim.api.nvim_win_set_cursor(0, { b.top + 1, 0 })
      h.press(kc.peek)
      assert.are.equal(1, hovered)
      assert.are.equal(0, #floats())
    end)

    it("is the reader's own again once the annotator is closed", function()
      conflict.close(buf)
      h.press(kc.peek)
      assert.are.equal(2, hovered)
      vim.keymap.del("n", kc.peek, { buffer = buf })
    end)
  end)

  -- The other file: added by both sides, so there is no base and no
  -- word to merge against. The wand says so rather than guessing.
  describe("with no base", function()
    local hbuf, hc

    it("is entered by leaving the first file, which closes its annotator", function()
      conflict.attach(buf, vim.api.nvim_get_current_win(), fixture, "calc.lua")
      hbuf = edit("helper.lua")
      h.wait_for(function() return conflict.get(buf) == nil end, "the first annotator to close")
      hc = conflict.attach(hbuf, vim.api.nvim_get_current_win(), fixture, "helper.lua")
      assert.are.equal(1, #hc.blocks)
    end)

    it("is left alone by the wand, which reports it", function()
      h.wait_for(function() return hc.base_lines ~= nil end, "the index to be asked")
      vim.api.nvim_win_set_cursor(0, { hc.blocks[1].top + 1, 0 })
      h.press(kc.resolve_all)
      assert.are.equal(1, #hc.blocks)
      assert.matches("resolved 0 of 1", said(), 1, true)
    end)

    it("claims nothing on the marker row that the wand cannot do", function()
      assert.are.equal("conflict 1 of 1", drawn(hbuf).note[hc.blocks[1].top])
      assert.is_false(vim.diagnostic.is_enabled({ bufnr = hbuf }))
    end)

    -- Block or no block.
    it("gives back diagnostics, winbar, keys and marks on close", function()
      conflict.close(hbuf)
      assert.is_nil(conflict.get(hbuf))
      assert.is_true(vim.diagnostic.is_enabled({ bufnr = hbuf }))
      assert.are.equal("", vim.wo.winbar)
      assert.are.equal("", vim.fn.maparg(kc.next, "n"))
      assert.are.equal(0, n_marks(hbuf))
    end)
  end)

  it("leaves the fixture clean", function()
    release()
    abort_merge()
  end)
end)

-- The whole review: `<leader>gx` lists the files a merge stopped on,
-- annotates the one under the cursor -- or opens the first -- and the
-- list counts blocks settled rather than lines read. Ended by the same
-- key, with nothing of it left behind.
describe("the conflict review", function()
  local kg, kv = config.keys.global, config.keys.view
  local auto_open = config.pane.auto_open
  local p, buf, c
  capture()
  config.pane.auto_open = true

  local function row_of(name)
    for _, l in ipairs(lines(p.list_buf, 0, -1)) do
      if l:find(name, 1, true) then
        return l
      end
    end
  end

  local function current_name()
    return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t")
  end

  it("says there is nothing to do with nothing unmerged, and opens nothing", function()
    vim.cmd("silent! only")
    edit("stable.lua")
    h.press(kg.conflicts)
    h.wait_for(function() return #notes > 0 end, "an answer")
    assert.matches("no conflicts", said(), 1, true)
    assert.is_nil(pane_mod.get())
  end)

  -- From a file that is not one of them: the list comes up and the
  -- first conflicted file with it.
  it("lists the files the merge stopped on, each a U with its blocks counted", function()
    start_merge("merge", "feature/clash")
    h.press(kg.conflicts)
    h.wait_for(function()
      local q = pane_mod.get()
      return q ~= nil and (q.renders or 0) > 0 and conflict.get(vim.api.nvim_get_current_buf()) ~= nil
    end, "the conflict review to open on its first file")
    p = pane_mod.get()
    assert.is_true(p.conflicts)
    assert.are.equal("conflicts", p.mode)
    assert.are.equal(2, #p.files)
    assert.are.same({ "calc.lua", "U", 1 }, { p.files[1].path, p.files[1].status, p.files[1].conflicts })
  end)

  it("opens and annotates the first, the list beside it", function()
    assert.are.equal("calc.lua", current_name())
    buf = vim.api.nvim_get_current_buf()
    c = conflict.get(buf)
    assert.is_not_nil(c)
    assert.is_true(vim.api.nvim_win_is_valid(p.list_win))
  end)

  it("names the branch taking the merge, and counts blocks", function()
    local l = lines(p.list_buf, 0, -1)
    assert.matches("conflicts on feature/math", l[1], 1, true)
    assert.matches("2 files · 2 left · 0 resolved", l[2], 1, true)
    assert.matches("1 left", row_of("calc.lua"), 1, true)
    assert.matches("0/2", vim.wo[p.list_win].statusline, 1, true)
  end)

  it("answers review() and status() in blocks", function()
    local st, bs = uatis.review(), uatis.status()
    assert.are.same({ "conflicts", 2, 0, 2 }, { st.mode, st.conflicts, st.resolved, st.files })
    assert.are.same({ "conflicts", 1, 0, "calc.lua" }, { bs.mode, bs.conflicts, bs.resolved, bs.path })
  end)

  -- A conflict is settled, not read.
  it("offers the conflict keys under g?, and no commit walk or marking", function()
    local keys = h.offered(p)
    assert.matches(kc.resolve, keys, 1, true)
    assert.is_nil(keys:find("one commit at a time", 1, true))
    assert.is_nil(keys:find("back / forward", 1, true))
    assert.is_nil(keys:find("mark this row", 1, true))
  end)

  -- The row, the count line and the bar follow before the file is
  -- written.
  it("follows a block settled in the buffer before the file is written", function()
    h.wait_for(function() return c.base_lines ~= nil end, "the base")
    -- From the top of the file: the buffer remembers where the cursor
    -- last was, and from inside the block `]x` would step into the next
    -- file.
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    h.press(kc.next)
    h.press(kc.resolve)
    assert.are.equal(0, #c.blocks)
    assert.matches("done", row_of("calc.lua"), 1, true)
    assert.matches("1 left · 1 resolved", lines(p.list_buf, 0, -1)[2], 1, true)
    assert.matches("1/2", vim.wo[p.list_win].statusline, 1, true)
    assert.is_true(vim.bo[buf].modified)
  end)

  it("says what is left when a file is done", function()
    assert.matches("calc.lua resolved, 1 more in helper.lua", said(), 1, true)
  end)

  it("steps off the last block into the next file, on its first block", function()
    h.press(kc.next)
    h.wait_for(function()
      local hc = conflict.get(vim.api.nvim_get_current_buf())
      return hc ~= nil and hc ~= c and (hc.renders or 0) > 0
    end, "the next conflicted file")
    assert.are.equal("helper.lua", current_name())
    local hc = conflict.get(vim.api.nvim_get_current_buf())
    assert.are.equal(hc.blocks[1].top + 1, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("says so at the very end", function()
    h.press(kc.next)
    assert.matches("last conflict", said(), 1, true)
  end)

  it("walks the list with the file keys, annotating each file on arrival", function()
    h.press(kv.file_prev)
    h.wait_for(function() return current_name() == "calc.lua" end, "the previous file")
    assert.is_not_nil(conflict.get(vim.api.nvim_get_current_buf()))
  end)

  -- `x` in the list has nothing to mark here.
  it("refuses to mark a row read", function()
    vim.api.nvim_set_current_win(p.list_win)
    pane_mod.toggle_read(p, 2)
    assert.matches("not when it is marked", said(), 1, true)
    vim.api.nvim_set_current_win(p.code_win)
  end)

  it("ends on its key again: list, annotators, keys, winbar and marks", function()
    local cur = vim.api.nvim_get_current_buf()
    h.press(kg.conflicts)
    assert.is_nil(pane_mod.get())
    assert.are.equal(0, #conflict.all())
    assert.are.equal("", vim.fn.maparg(kc.next, "n"))
    assert.are.equal("", vim.wo.winbar)
    assert.are.equal(0, n_marks(cur))
  end)

  -- Being the key that ends the review in this tab.
  it("ends on the key that ends any review", function()
    h.press(kg.conflicts)
    h.wait_for(function() local q = pane_mod.get(); return q ~= nil and (q.renders or 0) > 0 end, "the review again")
    h.press(kg.toggle_diff)
    assert.is_nil(pane_mod.get())
    assert.are.equal(0, #conflict.all())
  end)

  it("leaves the fixture clean", function()
    release()
    config.pane.auto_open = auto_open
    abort_merge()
  end)
end)

-- Where `merge.conflictStyle` is diff3 or zdiff3 the block carries its
-- own base, and the index is never asked. A real overlap -- both sides
-- changed the same word -- is left as it is, whichever way the base
-- arrived, and the marker row says which kind of block it is.
describe("a block that carries its base", function()
  local buf, c, b
  capture()

  -- diff3 style forgoes the coalescing the default style does, so the
  -- two blocks are what git found.
  it("is what diff3 style leaves: two blocks, and the index not asked", function()
    start_merge("-c", "merge.conflictStyle=diff3", "merge", "feature/clash")
    buf = edit("calc.lua")
    c = conflict.attach(buf, vim.api.nvim_get_current_win(), fixture, "calc.lua")
    b = c.blocks[1]
    assert.are.equal(2, #c.blocks)
    assert.is_not_nil(b.mid)
    assert.is_not_nil(b.base)
    assert.is_nil(c.base_lines)
  end)

  it("dims the `|||||||` row and bands the base under it", function()
    local band = drawn(buf).band
    assert.are.same({ "UatisMarker", "UatisBase", "UatisBase" },
      { band[b.mid], band[b.mid + 1], band[b.sep - 1] })
  end)

  it("is settled by the wand to the same answer, still without the index", function()
    vim.api.nvim_win_set_cursor(0, { b.top + 1, 0 })
    h.press(kc.resolve)
    assert.are.equal(1, #c.blocks)
    assert.are.same({ "function M.add(a, b)  -- sum", "  return (a or 0) + (b or 0)" }, lines(buf, 2, 4))
    assert.is_nil(c.base_lines)
    undo_to(c, 2)
  end)

  -- Written by hand with its base: the wand refuses, the marker row says
  -- why, and every other key still works on it.
  describe("where both sides changed the same word", function()
    it("says on the marker row that it is a real overlap", function()
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        "local M = {}",
        "<<<<<<< HEAD",
        "x = 2",
        "||||||| base",
        "x = 1",
        "=======",
        "x = 3",
        ">>>>>>> feature/clash",
        "return M",
      })
      h.wait_for(function() return c.blocks[1] ~= nil and c.blocks[1].ours[1] == "x = 2" end, "the hand-made block")
      assert.matches("both sides changed the same words", drawn(buf).note[2], 1, true)
    end)

    it("is left by the wand, which says why", function()
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      h.press(kc.resolve)
      assert.are.equal(1, #c.blocks)
      assert.matches("real overlap", said(), 1, true)
      h.press(kc.resolve_all)
      assert.matches("resolved 0 of 1", said(), 1, true)
    end)

    it("takes the base the markers carry", function()
      h.press(kc.base)
      assert.are.same({ "local M = {}", "x = 1", "return M" }, lines(buf, 0, -1))
    end)
  end)

  it("leaves the fixture clean", function()
    conflict.close(buf)
    release()
    abort_merge()
  end)
end)
