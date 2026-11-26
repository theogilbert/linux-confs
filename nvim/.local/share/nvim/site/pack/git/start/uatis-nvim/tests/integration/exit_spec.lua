-- Leaving the editor, and the command-line window.
local h = require("helpers")
local uatis = require("uatis")
local pane_mod = require("uatis.pane")
local fixture = h.repo()

h.git("switch", "-qf", "feature/math")

-- A review of the given kind on screen, waited on until its list is drawn.
local function opened(what, open, extra)
  open()
  h.wait_for(function()
    local q = pane_mod.get()
    return q ~= nil and (q.renders or 0) > 0 and (extra == nil or extra(q))
  end, what)
  return pane_mod.get()
end

local function history(extra)
  return opened("a history in its own tab", uatis.history, function(q)
    return q.history and (extra == nil or extra(q))
  end)
end

-- The tabs uatis opened for itself go before the editor does, so a
-- session saved on the way out does not bring back a tab of `uatis://`
-- buffers that no longer exist.
describe("leaving the editor", function()
  local home, hist, shown

  it("starts from three tabs, two of them uatis's", function()
    vim.cmd("silent! tabonly!")
    vim.cmd("silent! only")
    vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
    home = vim.api.nvim_get_current_tabpage()
    hist = history()
    vim.api.nvim_set_current_tabpage(home)
    shown = opened("a commit in its own tab", function() uatis.show_commit("HEAD") end,
      function(q) return q ~= hist and q.standalone end)
    assert.are.equal(3, #vim.api.nvim_list_tabpages())
  end)

  -- Quit from inside one of them. `:qa` refuses to go on when `ExitPre`
  -- closed the window it was asked from -- nvim simply stays up -- so
  -- that window has to outlive the tabs.
  it("closes the tabs uatis opened on ExitPre, ending their reviews", function()
    local quitting = vim.api.nvim_get_current_win()
    vim.api.nvim_exec_autocmds("ExitPre", {})
    assert.are.equal(1, #vim.api.nvim_list_tabpages())
    assert.are.equal(home, vim.api.nvim_get_current_tabpage())
    assert.is_nil(pane_mod.get(hist.tab))
    assert.is_nil(pane_mod.get(shown.tab))
    assert.is_true(vim.api.nvim_win_is_valid(quitting))
  end)

  -- A window the review would otherwise close itself.
  it("closes the tab when the quit came from the list, keeping the list's window", function()
    vim.cmd("silent! only")
    local p = history(function(q) return q.list_win ~= nil end)
    vim.api.nvim_set_current_win(p.list_win)
    local quitting = vim.api.nvim_get_current_win()
    vim.api.nvim_exec_autocmds("ExitPre", {})
    assert.are.equal(1, #vim.api.nvim_list_tabpages())
    assert.is_true(vim.api.nvim_win_is_valid(quitting))
  end)

  -- nvim will not close its last tab.
  it("puts a blank tab in place of a review's tab that is the only one", function()
    vim.cmd("silent! only")
    history()
    vim.cmd("silent! tabonly!")
    assert.are.equal(1, #vim.api.nvim_list_tabpages())
    vim.api.nvim_exec_autocmds("ExitPre", {})
    assert.is_nil(pane_mod.get())
    assert.are.equal(1, #vim.api.nvim_list_tabpages())
    assert.are.equal("", vim.api.nvim_buf_get_name(0))
  end)

  h.git("switch", "-qf", "main")
end)

-- `q:` is a normal-mode window, so the global keys fire in it -- and
-- every one of them ends in opening a window or leaving the buffer,
-- which is `E11` there. The window is two git calls past the key, so
-- unguarded the refusal arrived as a traceback out of a `vim.schedule`
-- callback with nothing on screen to connect it to.
describe("the command-line window", function()
  it("refuses every global key, saying why, rather than raising", function()
    local errs = {}
    local notes = h.notes(function()
      vim.api.nvim_create_autocmd("CmdwinEnter", {
        once = true,
        callback = function()
          for _, lhs in pairs(require("uatis.config").keys.global) do
            if lhs and lhs ~= "" then
              local m = vim.fn.maparg(vim.keycode(lhs), "n", false, true)
              if m and m.callback then
                local good, err = pcall(m.callback)
                if not good then
                  table.insert(errs, lhs .. ": " .. tostring(err))
                end
              end
            end
          end
          vim.api.nvim_feedkeys(vim.keycode("<C-c>"), "n", false)
        end,
      })
      vim.api.nvim_feedkeys("q:", "x", false)
    end)
    assert.are.same({}, errs)
    assert.matches("command%-line window", notes[1])
    assert.is_nil(pane_mod.get())
  end)
end)

-- `os.exit` fires no `ExitPre`: what a quit would take down is taken
-- down here, so no checkout outlives the run in git's worktree list.
h.release()
