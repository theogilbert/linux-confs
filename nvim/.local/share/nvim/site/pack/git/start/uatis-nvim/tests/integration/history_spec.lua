-- History: every commit that touched a file, a directory or a run of
-- lines, back to the one that made it -- a list of commits rather than
-- of files, each read the way `:UatisShow` reads one: against its own
-- parent, in its own buffers, in a tab of its own.
local h = require("helpers")
local uatis = require("uatis")
local config = require("uatis.config")
local ui = require("uatis.ui")
local view_mod = require("uatis.view")
local pane_mod = require("uatis.pane")
local fixture = h.repo()
local keys = config.keys.pane

h.git("switch", "-qf", "feature/math")

local function short_of(subject)
  return h.git("log", "--all", "--format=%h", "-1", "--grep=" .. subject)
end

local function current_view()
  return view_mod.get(vim.api.nvim_get_current_buf())
end

-- The pane a history just opened, once its first file has drawn.
local function opened(before, what)
  h.wait_for(function()
    local q = pane_mod.get()
    if not (q and q ~= before and q.history and (q.renders or 0) > 0) then
      return false
    end
    local v = current_view()
    return v ~= nil and (v.renders or 0) > 0
  end, what)
  return pane_mod.get()
end

-- ...and once the commit at `idx` is the one drawn.
local function on_show(p, idx, what)
  h.wait_for(function()
    local v = current_view()
    return p.commit_idx == idx and v ~= nil and (v.renders or 0) > 0
      and v.at_commit == p.commits[idx].short
  end, what)
end

local function list_text(p)
  return table.concat(vim.api.nvim_buf_get_lines(p.list_buf, 0, -1, false), "\n")
end

-- The commit card pinned over the file: the unfocusable float in this tab.
local function card()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local c = vim.api.nvim_win_get_config(w)
    if c.relative ~= "" and not c.focusable then
      return w, vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)
    end
  end
  return nil, {}
end

local function card_top()
  local _, lines = card()
  return lines[1] or ""
end

local function home_file(home, name)
  vim.api.nvim_set_current_tabpage(home)
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/" .. name))
end

-- What uatis said while `ask` ran, once it said something; and how many
-- tabs that left.
local function refusal(ask)
  local before = #vim.api.nvim_list_tabpages()
  local said = {}
  local real = vim.notify
  vim.notify = function(msg) table.insert(said, msg) end
  ask()
  local fine = vim.wait(10000, function() return #said > 0 end, 20)
  vim.notify = real
  assert(fine, "uatis said nothing")
  return said, #vim.api.nvim_list_tabpages() - before
end

describe("the history of a file", function()
  local home, p

  it("opens in a tab of its own, on the newest of the commits that touched it", function()
    vim.cmd("silent! tabonly!")
    vim.cmd("silent! only")
    vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
    home = vim.api.nvim_get_current_tabpage()
    uatis.history()
    p = opened(nil, "the history of calc.lua")
    assert.are_not.equal(home, p.tab)
    assert.are.equal(2, #vim.api.nvim_list_tabpages())
    -- Creation included.
    assert.are.equal(2, #p.commits)
    assert.are.equal(2, p.commit_idx)
    assert.are.equal(short_of("fix sub argument order"), p.commits[2].short)
  end)

  it("measures a commit against its own parent", function()
    assert.are.equal(p.commits[2].parent, p.rev)
  end)

  it("tells a statusline what kind of review it is", function()
    assert.are.equal("history", uatis.review().mode)
  end)

  it("says in the list what it is the history of, and how long", function()
    assert.matches("history of calc.lua", list_text(p), 1, true)
    assert.matches("2 commits", list_text(p), 1, true)
  end)

  -- The way every log is read.
  it("lists the newest first", function()
    local text = list_text(p)
    local newest = text:find(p.commits[2].subject:sub(1, 7), 1, true)
    local oldest = text:find(p.commits[1].subject:sub(1, 7), 1, true)
    assert.is_true(newest < oldest)
  end)

  it("dates each row, and names the sha only under the one on show", function()
    local text = list_text(p)
    assert.matches(" " .. p.commits[2].date .. " ", text, 1, true)
    assert.matches(p.commits[2].short, text, 1, true)
    assert.is_nil(text:find(p.commits[1].short, 1, true))
  end)

  -- Never the reader's own buffer, which holds the present.
  it("shows the file as it was, out of the history's checkout", function()
    assert.is_not_nil(require("uatis.checkout").owner_of(vim.api.nvim_buf_get_name(0)))
  end)

  it("puts the cursor on the change the commit made", function()
    assert.are.equal(current_view().anchors[1], vim.api.nvim_win_get_cursor(0)[1])
  end)

  describe("its commit card", function()
    local code_win

    -- Datetime to the second, then its message; the sha is the winbar's.
    it("pins the commit over the file: datetime and subject on the top row", function()
      code_win = vim.api.nvim_get_current_win()
      h.wait_for(function() return card_top():find(":%d%d ") ~= nil end,
        "the commit's message pinned over the file")
      assert.matches("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d · fix sub argument order", card_top())
    end)

    it("sits on the window's first row of text, its full width", function()
      local info = vim.fn.getwininfo(code_win)[1]
      local cc = vim.api.nvim_win_get_config((card()))
      assert.are.same({ info.winrow - 1 + info.winbar, info.wincol - 1, info.width },
        { cc.row, cc.col, cc.width })
    end)

    -- Blank filler above line 1 is what it sits over at the top, and
    -- 'scrolloff' keeps the cursor out from under it everywhere else.
    it("covers nothing of the file", function()
      local _, lines = card()
      local sight = vim.fn.winsaveview()
      -- The change is near the top, so the window is too.
      assert.are.equal(1, sight.topline)
      assert.is_true(sight.topfill >= #lines)
      assert.is_true(vim.wo[code_win].scrolloff >= #lines)
    end)
  end)

  -- Two rows by default: a body of one line fits under the subject, a
  -- longer one is `...`. The cap is a setting.
  describe("ui.commit_card", function()
    local two = config.show.message_lines

    it("fits one body line under the subject", function()
      assert.are.equal(2, #ui.commit_card("d", "subject\n\none", two))
    end)

    it("cuts more than that to the subject and ...", function()
      local cut = ui.commit_card("d", "subject\n\none\ntwo", two)
      assert.are.same({ 2, "..." }, { #cut, cut[2][1][1] })
    end)

    it("drops the blank row under the subject, and says on the last row there is more", function()
      local long = ui.commit_card("2026-01-02 03:04:05", "subject\n\none\ntwo\nthree\nfour\nfive", 5)
      assert.are.same({ 5, "one", "..." }, { #long, long[2][1][1], long[5][1][1] })
    end)

    it("does not cut one that fits", function()
      assert.are.equal(5, #ui.commit_card("d", "subject\n\none\ntwo\nthree\nfour", 5))
    end)
  end)

  it("offers the walk under g?, and no whole to go back out to", function()
    local offered = h.offered(p)
    assert.matches("this history", offered, 1, true)
    assert.matches(keys.commit_prev .. " " .. keys.commit_next, offered, 1, true)
    assert.is_nil(offered:find("| " .. keys.commit_view .. " ", 1, true))
  end)

  -- The commit's whole message, and under it what the commit did to each
  -- file it touched -- the churn, then the path.
  it("says on K what the commit did to each file", function()
    pane_mod.peek_commit(p)
    local lines
    h.wait_for(function()
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local c = vim.api.nvim_win_get_config(w)
        if c.relative ~= "" and c.focusable then
          lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)
          pcall(vim.api.nvim_win_close, w, true)
          return true
        end
      end
    end, "the commit's message in a float")
    local stat = vim.tbl_filter(function(l) return l:find("calc.lua", 1, true) end, lines)
    assert.matches("^%s*%+%d+%s+%-%d+%s+calc%.lua$", stat[1])
  end)

  -- difftastic takes seconds over a large file, and the next commit is
  -- the one question a history knows is coming.
  it("compares the older neighbour ahead of the step", function()
    assert.is_truthy(p.prefetched and p.prefetched[p.commits[1].sha])
  end)

  -- The first commit made the file, and has no parent to be measured
  -- against but nothing.
  it("steps to the commit that made the file, measured against nothing", function()
    pane_mod.step_commit(p, -1)
    on_show(p, 1, "the commit that made calc.lua")
    assert.are.equal("nothing", p.target)
    assert.are.equal(0, p.stat_removed)
  end)

  -- The file of the commit left behind is wiped a tick later, and that
  -- must not take the new card with it.
  it("moves the card with the step, and keeps it once the old file is gone", function()
    h.wait_for(function() return card_top():find(p.commits[1].subject, 1, true) ~= nil end,
      "the older commit's card")
    vim.wait(50)
    assert.matches(p.commits[1].subject, card_top(), 1, true)
  end)

  it("says so off the old end, and that C has nothing to enter", function()
    local said = h.notes(function()
      pane_mod.step_commit(p, -1)
      pane_mod.toggle_commits(p)
    end)
    assert.is_true(h.contains(said, "oldest commit"))
    assert.is_true(h.contains(said, "one commit at a time"))
    assert.are.equal(1, p.commit_idx)
  end)

  it("puts the commit row picked with <CR> on show", function()
    vim.api.nvim_set_current_win(p.list_win)
    for line, idx in pairs(p.list_commits) do
      if idx == 2 then
        vim.api.nvim_win_set_cursor(p.list_win, { line, 0 })
      end
    end
    vim.api.nvim_feedkeys(vim.keycode(keys.select), "x", false)
    on_show(p, 2, "the row picked back on show")
  end)

  -- The branch review's subtree is not this history's.
  it("is left alone by choosing what the branch review is about", function()
    pane_mod.rescope(p.root, "util")
    assert.are.equal("", p.scope)
  end)

  it("closes its tab with it", function()
    pane_mod.close(p)
    h.wait_for(function() return not vim.api.nvim_tabpage_is_valid(p.tab) end, "the history's tab to go")
  end)

  -- Each commit read under the name it had then.
  describe("that was renamed", function()
    it("follows it back past the rename", function()
      home_file(home, "renamed_to.lua")
      uatis.history()
      p = opened(nil, "the history of a renamed file")
      -- The rename, and the commit that made it under its old name.
      assert.are.equal(2, #p.commits)
    end)

    it("reads the older commit under the name it had", function()
      pane_mod.step_commit(p, -1)
      on_show(p, 1, "the file under its old name")
      assert.matches("renamed_from.lua", vim.api.nvim_buf_get_name(0), 1, true)
      pane_mod.close(p)
    end)
  end)

  -- `M.sub`'s three rows, followed by `git log -L`.
  describe("narrowed to a run of lines", function()
    it("lists every commit that touched them, the cursor where git says they stood", function()
      home_file(home, "calc.lua")
      uatis.history({ range = 2, line1 = 7, line2 = 9 })
      p = opened(nil, "the history of calc.lua:7-9")
      assert.are.same({ 7, 9 }, { p.history.from, p.history.to })
      assert.are.equal(2, #p.commits)
      assert.matches("lines 7-9", list_text(p), 1, true)
      assert.are.equal(7, vim.api.nvim_win_get_cursor(0)[1])
      pane_mod.close(p)
    end)

    -- Three lines typed at the top move `M.sub` to 10-12 in the buffer,
    -- and it is still 7-9 in every commit git can be asked about.
    it("asks for them as HEAD has them, through an edit not yet committed", function()
      home_file(home, "calc.lua")
      vim.api.nvim_buf_set_lines(0, 0, 0, false, { "-- one", "-- two", "-- three" })
      uatis.history({ range = 2, line1 = 10, line2 = 12 })
      p = opened(nil, "the history of lines an edit moved")
      assert.are.same({ 7, 9 }, { p.history.from, p.history.to })
      pane_mod.close(p)
    end)

    -- Lines that exist nowhere but the buffer have no history.
    it("says so of uncommitted lines, and opens no tab", function()
      vim.api.nvim_set_current_tabpage(home)
      local said, tabs = refusal(function() uatis.history({ range = 2, line1 = 1, line2 = 3 }) end)
      assert.is_true(h.contains(said, "not been committed"))
      assert.are.equal(0, tabs)
      vim.cmd("silent! edit!")
    end)
  end)
end)

-- `:UatisHistory util`, which `plugin/` defines and the suite does not
-- source.
describe("the history of a directory", function()
  local p

  it("is its commits, read as the list's subtree", function()
    uatis.history({ path = "util" })
    p = opened(nil, "the history of util/")
    assert.is_true(p.history.dir)
    assert.are.equal("util", p.scope)
    assert.are.equal(1, #p.commits)
  end)

  it("draws the files it touched in there relative to it", function()
    assert.are.equal(1, #p.files)
    assert.matches("A strings.lua", list_text(p), 1, true)
  end)

  it("opens a file row's own history on L", function()
    vim.api.nvim_set_current_win(p.list_win)
    vim.api.nvim_win_set_cursor(p.list_win, { next(p.list_rows), 0 })
    vim.api.nvim_feedkeys(keys.history, "x", false)
    local q = opened(p, "the history of the row under the cursor")
    assert.are.equal("util/strings.lua", q.history.path)
    pane_mod.close(q)
    pane_mod.close(p)
  end)
end)

describe("the history of a path nothing ever touched", function()
  it("says so and opens nothing", function()
    local said, tabs = refusal(function() uatis.history({ path = "no-such-file.lua" }) end)
    assert.is_true(h.contains(said, "no commit has touched"))
    assert.are.equal(0, tabs)
  end)

  vim.cmd("silent! tabonly!")
  h.git("switch", "-qf", "main")
end)

h.release()
