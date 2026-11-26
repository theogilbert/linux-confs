-- `blame.lua`: who last wrote each line, named in the buffer's own gutter.
--
-- calc.lua on feature/math: `initial` wrote its frame, `fix sub argument
-- order and add mul` rewrote two bodies and added a function.
local h = require("helpers")
local uatis = require("uatis")
local config = require("uatis.config")
local blame = require("uatis.blame")
local view_mod = require("uatis.view")
local pane_mod = require("uatis.pane")
local fixture = h.repo()
local kb = config.keys.blame

local function edit(name)
  vim.cmd("silent! only")
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/" .. name))
  return vim.api.nvim_get_current_buf()
end

local function on(buf)
  vim.api.nvim_set_current_buf(buf)
  uatis.blame()
  local b = blame.get(buf)
  h.wait_for(function() return b.renders > 0 end, "a blame of " .. vim.api.nvim_buf_get_name(buf))
  return b
end

local function again(b, fn)
  local before = b.renders
  fn()
  h.wait_for(function() return b.renders > before end, "a blame again")
end

-- The window's 'statuscolumn' on `row`, evaluated as the screen would --
-- the option, not `blame.cell`, so what the column is handed when it is
-- drawn is under test too.
local function column(row)
  return vim.api.nvim_eval_statusline(vim.wo.statuscolumn,
    { winid = vim.api.nvim_get_current_win(), use_statuscol_lnum = row }).str
end

-- The column's cell on `row` of the current window: { text, hl }, the
-- `%#Group#` taken apart from what it colours.
local function cell(buf, row)
  local raw = blame.cell(buf, vim.api.nvim_get_current_win(), row, 0)
  local hl = raw:match("^%%#([^#]+)#")
  local text = raw:gsub("%%#[^#]*#", ""):gsub("%%%*", "")
  return { text = text, hl = hl }
end

describe("a blamed buffer", function()
  local buf, b

  it("names each run's commit by when and who in the column, and nothing past the end of a line", function()
    h.git("switch", "-qf", "feature/math")
    buf = edit("calc.lua")
    b = on(buf)
    -- Every field padded to the widest, so the brackets line up.
    h.eq(column(1):sub(1, b.label_width), "today FA")
    h.eq(vim.trim(column(3):sub(1, b.label_width)), "", "the run's own rows carry no label")
    -- `M.add`'s body is the fix's; the line above it is not.
    local fix = h.git("log", "-1", "--format=%H", "--grep=fix sub argument order")
    h.eq(b.runs[b.by_row[4]].commit.sha, fix)
    h.eq(column(4):sub(1, b.label_width), "today FA")
    h.eq(vim.fn.strdisplaywidth(column(1)), vim.fn.strdisplaywidth(column(4)), "one width")
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
      h.eq(m[4].virt_text, nil, "virtual text on row " .. (m[2] + 1))
    end
  end)

  it("names each run's commit in the gutter and brackets the rest of it", function()
    h.ok(vim.wo.statuscolumn:find("uatis.blame", 1, true), "the column is worn")
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    for _, r in ipairs(b.runs) do
      local top = cell(buf, r.from)
      h.eq(top.text:sub(1, #b.labels[r.commit.sha]), b.labels[r.commit.sha], "label of " .. r.from)
      if r.from == r.to then
        assert.truthy(top.text:find("╶", 1, true) or top.text:find("╺", 1, true))
      else
        assert.truthy(top.text:find("┌", 1, true) or top.text:find("┏", 1, true))
        h.eq(vim.trim(cell(buf, r.to).text:sub(1, b.label_width)), "", "no label under the top")
      end
    end
  end)

  it("gives neighbouring runs different colours, and the cursor's run its bold one", function()
    for i = 2, #b.runs do
      if b.runs[i].commit ~= b.runs[i - 1].commit then
        h.ok(cell(buf, b.runs[i].from).hl ~= cell(buf, b.runs[i - 1].from).hl,
          "runs at " .. b.runs[i - 1].from .. " and " .. b.runs[i].from)
      end
    end
    local r = b.runs[2]
    vim.api.nvim_win_set_cursor(0, { r.to, 0 })
    local top = cell(buf, r.from)
    h.ok(top.hl:match("Current$"), "the cursor's run is bold")
    h.ok(top.text:find("┏", 1, true) or top.text:find("╺", 1, true), "and heavier")
    h.ok(not cell(buf, b.runs[1].from).hl:match("Current$"), "the others are not")
  end)

  it("shows a run's commit, rows and what it did to them on the details key", function()
    -- `return (a or 0) + (b or 0)`, the fix's.
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    h.press(kb.details)
    h.wait_for(function() return b.hover and b.hover:is_open() end, "the details float")
    local float = b.hover.win
    local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(float), 0, -1, false), "\n")
    assert.truthy(text:find("fix sub argument order", 1, true))
    assert.truthy(text:find("here", 1, true))
    assert.truthy(text:find("+  return (a or 0) + (b or 0)", 1, true))
    assert.truthy(text:find("-  return a + b", 1, true))
    assert.truthy(text:find("-  return a + b\n+  return (a or 0) + (b or 0)", 1, true),
      "one row per line of the patch, no blank between")
    -- The patch in the file's own colours, its side said by the band.
    local fbuf = vim.api.nvim_win_get_buf(float)
    local rows = vim.api.nvim_buf_get_lines(fbuf, 0, -1, false)
    local function on(prefix)
      local row
      for i, l in ipairs(rows) do
        row = row or (vim.startswith(l, prefix) and i - 1)
      end
      local got = {}
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(fbuf, -1, { row, 0 }, { row, -1 }, { details = true })) do
        got[m[4].hl_group or m[4].line_hl_group] = true
      end
      return got
    end
    local added, removed = on("+  return"), on("-  return")
    h.ok(added["@keyword.return.lua"], "an added line is coloured as Lua")
    h.ok(added.UatisAdd and removed.UatisDeleteBg, "on its side's band")
    h.ok(removed["@keyword.return.lua"], "and so is a removed one")
    -- Again, into it; and moving the cursor in the file takes it away.
    h.press(kb.details)
    h.eq(vim.api.nvim_get_current_win(), float)
    vim.cmd("wincmd p")
    h.wait_for(function() return not b.hover:is_open() end, "the float to go")
  end)

  it("names an unsaved line as uncommitted, and keeps the rest on their rows", function()
    again(b, function()
      vim.api.nvim_buf_set_lines(buf, 1, 1, false, { "-- typed, not written" })
    end)
    h.eq(column(2):sub(1, 5), "new  ")
    h.eq(b.runs[b.by_row[5]].commit.sha,
      h.git("log", "-1", "--format=%H", "--grep=fix sub argument order"))
  end)

  it("describes the run under the cursor in a pane above, and follows the cursor", function()
    local function said()
      if not (b.pane and vim.api.nvim_win_is_valid(b.pane)) then
        return ""
      end
      return table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(b.pane), 0, -1, false), "\n")
    end
    local code = vim.api.nvim_get_current_win()
    -- `CursorMoved` comes from the main loop, which a headless test
    -- does not go round; fired here as it would be.
    local function move(row)
      vim.api.nvim_win_set_cursor(0, { row, 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
    end
    move(5)
    h.wait_for(function() return said():find("fix sub argument order", 1, true) end, "the fix's card")
    h.eq(vim.api.nvim_win_get_position(b.pane)[1] < vim.api.nvim_win_get_position(code)[1], true,
      "above the code")
    h.eq(vim.api.nvim_get_current_win(), code, "the cursor stays in the code")
    h.ok(not vim.wo[b.pane].statuscolumn:find("uatis", 1, true),
      "without the blame column the split copied")
    vim.cmd("redraw")
    move(5)
    h.eq(vim.fn.getwininfo(b.pane)[1].textoff, vim.fn.getwininfo(code)[1].textoff,
      "its text starting where the code does")
    local fill = vim.api.nvim_eval_statusline(vim.wo[b.pane].statuscolumn,
      { winid = b.pane, use_statuscol_lnum = 1, highlights = true })
    h.eq(fill.highlights[1].group, "UatisBlameGutter", "in a filled gutter")
    h.eq(fill.highlights[#fill.highlights].start, #fill.str - 1, "but for the space before the text")
    local rule = vim.api.nvim_eval_statusline(vim.wo[b.pane].statusline,
      { winid = b.pane, fillchar = "─", highlights = true })
    h.eq(rule.str, string.rep("─", vim.api.nvim_win_get_width(b.pane)), "a rule for a status line")
    h.eq(rule.highlights[1].group, "UatisBlameRule")
    h.eq(vim.wo[b.pane].fillchars:match("stl:(─)"), "─")
    h.ok(not said():find("@@", 1, true), "and without the patch")
    h.ok(not said():find("here", 1, true), "or the rows")
    h.eq(vim.api.nvim_win_get_height(b.pane), 3)
    move(1)
    h.wait_for(function() return said():find("initial", 1, true) end, "the initial commit's card")
    move(2)
    h.wait_for(function() return said() == "not committed" end, "an unsaved line's")
    -- Put away, it stays away for this blame.
    vim.api.nvim_set_current_win(b.pane)
    h.press("q")
    h.eq(b.pane, nil)
    vim.api.nvim_set_current_win(code)
    move(5)
    h.eq(b.pane, nil, "not opened again")
    b.pane_dismissed = nil
    move(1)
    h.ok(b.pane ~= nil, "the pane, for the test that turns the blame off")
  end)

  it("keeps the pane over its own window alone when that window is split", function()
    local code = b.pane_code
    -- Directly over: the pane's last row, its status line, then `win`.
    local function over(win)
      local p, w = vim.api.nvim_win_get_position(b.pane), vim.api.nvim_win_get_position(win)
      return p[2] == w[2] and p[1] + vim.api.nvim_win_get_height(b.pane) + 1 == w[1]
    end
    h.ok(over(code), "over its window to begin with")
    vim.api.nvim_set_current_win(code)
    vim.cmd("split")
    local other = vim.api.nvim_get_current_win()
    h.wait_for(function() return b.pane and over(code) end, "the pane back over its own window")
    h.ok(not over(other), "and not over the new one")
    h.eq(vim.api.nvim_win_get_height(b.pane), 3)
    -- Its own window gone, it goes to the one left.
    vim.api.nvim_win_close(code, true)
    h.wait_for(function() return b.pane and b.pane_code == other and over(other) end,
      "the pane over the window left")
    h.eq(vim.api.nvim_get_current_win(), other)
  end)

  it("steps between runs", function()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    h.press(kb.next)
    h.eq(vim.api.nvim_win_get_cursor(0)[1], 2)
    h.press(kb.next)
    h.eq(vim.api.nvim_win_get_cursor(0)[1], b.runs[3].from)
    h.press(kb.prev)
    h.eq(vim.api.nvim_win_get_cursor(0)[1], 2)
  end)

  it("opens the commit that wrote a line, at that line as the commit has it", function()
    -- `return b - a`: row 9 under the unsaved line, row 8 in the commit.
    vim.api.nvim_win_set_cursor(0, { 9, 0 })
    local tab = vim.api.nvim_get_current_tabpage()
    h.press(kb.show)
    h.wait_for(function()
      local v = view_mod.get(vim.api.nvim_get_current_buf())
      return vim.api.nvim_get_current_tabpage() ~= tab and v ~= nil and (v.renders or 0) > 0
        and v.relpath == "calc.lua" and vim.api.nvim_win_get_cursor(0)[1] == 8
    end, "the fix, open at sub's body")
    assert.truthy(pane_mod.get().commit.subject:find("fix sub argument order", 1, true))
    vim.cmd("tabclose")
    vim.api.nvim_set_current_tabpage(tab)
  end)

  it("hands back the buffer as it was when turned off", function()
    vim.api.nvim_set_current_buf(buf)
    uatis.blame()
    h.eq(blame.get(buf), nil)
    h.eq(#vim.api.nvim_buf_get_extmarks(buf, blame.ns, 0, -1, {}), 0)
    h.eq(vim.fn.maparg(kb.next, "n", false, true).buffer, nil)
    h.eq(vim.wo.statuscolumn, "")
    h.eq(#vim.api.nvim_tabpage_list_wins(0), 1, "and the pane with it")
  end)
end)

describe("a commit's lines with newer ones between them", function()
  -- Each commit rewrites the middle of the last one's lines, a year on.
  local function commit(name, lines, year, msg)
    vim.fn.writefile(lines, fixture .. "/" .. name)
    h.git("add", name)
    h.git("commit", "-qm", msg, "--date=" .. year .. "-01-01T12:00:00")
  end
  -- The brackets alone: the label's width and the space after cut off.
  local function brackets(buf, b, row)
    local text = cell(buf, row).text
    return vim.fn.strcharpart(text, b.label_width + 1, b.cols)
  end

  it("are one bracket, with the newer ones nested to its right", function()
    h.git("switch", "-qf", "main")
    commit("nest.lua", { "a", "a", "a", "a", "a", "a" }, 2020, "nest one")
    commit("nest.lua", { "a", "b", "b", "b", "b", "a" }, 2021, "nest two")
    commit("nest.lua", { "a", "b", "c", "b", "b", "a" }, 2022, "nest three")
    local buf = edit("nest.lua")
    local b = on(buf)
    h.eq(b.cols, 3)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    h.eq(brackets(buf, b, 1), "┏━━")
    h.eq(brackets(buf, b, 2), "┃┌─")
    h.eq(brackets(buf, b, 3), "┃│╶")
    h.eq(brackets(buf, b, 4), "┃├─", "the second commit's lines resumed")
    h.eq(brackets(buf, b, 5), "┃└─")
    h.eq(brackets(buf, b, 6), "┗━━", "the first commit's last line, joined to its first")
    uatis.blame()
  end)

  it("are two brackets where an older line stands between them", function()
    commit("nest.lua", { "a", "a", "a" }, 2019, "nest base")
    commit("nest.lua", { "x", "a", "x" }, 2023, "nest ends")
    local buf = edit("nest.lua")
    local b = on(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    h.eq(b.cols, 1)
    h.eq(brackets(buf, b, 1), "╶")
    h.eq(brackets(buf, b, 3), "╶")
    uatis.blame()
  end)

  it("give up their columns past four deep", function()
    local lines = {}
    for i = 1, 11 do
      lines[i] = "0"
    end
    commit("deep.lua", lines, 2010, "deep 0")
    for k = 1, 5 do
      for i = k + 1, 11 - k do
        lines[i] = tostring(k)
      end
      commit("deep.lua", lines, 2010 + k, "deep " .. k)
    end
    local buf = edit("deep.lua")
    local b = on(buf)
    vim.api.nvim_win_set_cursor(0, { 6, 0 })
    h.eq(b.cols, 4)
    h.eq(brackets(buf, b, 4), "│││┌", "four deep, drawn")
    h.eq(brackets(buf, b, 5), "────", "five deep, given up")
    h.eq(brackets(buf, b, 6), "━━━━", "and deeper")
    uatis.blame()
  end)
end)

describe("a file git has never seen", function()
  it("is not blamed, and says why", function()
    local path = fixture .. "/scratch.lua"
    vim.fn.writefile({ "return 1" }, path)
    local buf = edit("scratch.lua")
    local notes = h.notes(function()
      uatis.blame()
      h.wait_for(function() return blame.get(buf) == nil end, "the blame given up")
    end)
    assert.truthy(h.contains(notes, "no blame for scratch.lua"))
    h.eq(#vim.api.nvim_buf_get_extmarks(buf, blame.ns, 0, -1, {}), 0)
    vim.fn.delete(path)
  end)
end)

h.release()

describe("a blamed run's date", function()
  local ui = require("uatis.ui")
  local day = 86400

  it("counts calendar days, then weeks, months and years", function()
    local now = os.time()
    h.eq(ui.days_ago(now), "today")
    h.eq(ui.days_ago(now - day), "1d ago")
    h.eq(ui.days_ago(now - 3 * day), "3d ago")
    h.eq(ui.days_ago(now - 15 * day), "2w ago")
    h.eq(ui.days_ago(now - 70 * day), "2m ago")
    h.eq(ui.days_ago(now - 800 * day), "2y ago")
  end)
end)
