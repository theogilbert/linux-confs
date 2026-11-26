-- `at.lua`: the project checked out at a revision, in a tab of its own.
--
-- Not a comparison: the project as it was, checked out, in a tab of its
-- own -- real files, so a language server and an explorer find a
-- project there -- and read-only, and gone when the tab is.
local h = require("helpers")
local uatis = require("uatis")
local at = require("uatis.at")
local fixture = h.repo()

local function text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf or 0, 0, -1, false), "\n")
end

local function open_at(rev)
  uatis.at(rev)
  h.wait_for(function() return at.get() ~= nil end, "the project checked out at " .. rev)
  return at.get()
end

describe("the project at a revision", function()
  local home, short, a

  it("opens in a tab of its own, on the file the reader was in", function()
    h.git("switch", "-qf", "feature/math")
    vim.cmd("silent! tabonly!")
    vim.cmd("silent! only")
    vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
    home = vim.api.nvim_get_current_tabpage()
    short = h.git("rev-parse", "--short", "HEAD~2")

    a = open_at("HEAD~2")
    assert.are_not.equal(home, vim.api.nvim_get_current_tabpage())
    assert.are.equal(short, a.short)
    assert.are.equal(a.dir .. "/calc.lua", vim.api.nvim_buf_get_name(0))
    assert.are.equal(h.git("show", "HEAD~2:calc.lua"), text())
  end)

  it("is read-only", function()
    assert.is_true(vim.bo.readonly)
    assert.is_false(vim.bo.modifiable)
  end)

  it("gives the tab the checkout as its directory, and leaves the reader's alone", function()
    assert.are.equal(a.dir, vim.fn.getcwd(-1, 0))
    assert.are_not.equal(a.dir, vim.fn.getcwd(-1, vim.api.nvim_tabpage_get_number(home)))
  end)

  it("names the revision in the winbar", function()
    assert.matches("at " .. short, vim.api.nvim_eval_statusline(vim.wo.winbar, {}).str, 1, true)
  end)

  -- Which is what a language server needs.
  it("is a real checkout", function()
    assert.are.equal(short, vim.trim(vim.fn.system({ "git", "-C", a.dir, "rev-parse", "--short", "HEAD" })))
  end)

  -- Anything opened from there is the past too.
  it("lands a relative :edit in the checkout, read-only as well", function()
    vim.cmd("edit helper.lua")
    assert.are.equal(a.dir .. "/helper.lua", vim.api.nvim_buf_get_name(0))
    assert.is_true(vim.bo.readonly)
    assert.is_false(vim.bo.modifiable)
  end)

  it("removes the checkout when the tab closes", function()
    vim.cmd("tabclose")
    h.wait_for(function() return vim.uv.fs_stat(a.dir) == nil end, "the checkout to be removed")
    assert.is_nil(h.git("worktree", "list"):find(a.dir, 1, true))
    assert.is_nil(at.get())
    h.wait_for(function() return vim.uv.fs_stat(vim.fs.dirname(a.dir)) == nil end,
      "the repository's empty folder in the cache to go too")
  end)

  -- The checkout opens on its directory instead.
  it("says so of a file that did not exist then", function()
    vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/helper.lua"))
    local said = h.notes(function() a = open_at("HEAD~3") end)
    assert.is_true(h.contains(said, "did not exist"))
  end)

  -- ...and on the way out of the editor, from inside it. The tab is one
  -- window, and `:qa` refuses to quit if that window is closed.
  it("closes on ExitPre, keeping the window the quit came from", function()
    local quitting = vim.api.nvim_get_current_win()
    vim.api.nvim_exec_autocmds("ExitPre", {})
    assert.are.equal(1, #vim.api.nvim_list_tabpages())
    assert.is_true(vim.api.nvim_win_is_valid(quitting))
    assert.is_nil(vim.uv.fs_stat(a.dir))
  end)
end)
