-- Where the cursor was before one of this plugin's windows took it.
--
-- Every window here opens over the file you are reading and is meant to
-- hand it back on the way out. `nvim_win_close` does not hand it back:
-- Neovim picks the successor itself, and what it picks is the first
-- window of the layout -- the top left one -- which on a split screen
-- is not the window the key was pressed in. So each of these remembers
-- where it came from, and the key that dismisses it goes back there.
--
-- The key that dismisses it, and not `close` itself: half of what these
-- windows do is close on the way to somewhere else -- the code a thread
-- is about, the thread a comment is on -- and putting the cursor back
-- afterwards would undo the jump that was the point of the keypress.

local M = {}

--- Remembers the window the cursor is in, and returns the function that
--- goes back to it. Call that after the window has been closed.
---
--- Nothing happens if what it remembers has gone in the meantime --
--- which is what closing a float over a float looks like -- and then
--- Neovim's own choice stands, because it is the only one left.
function M.came_from()
  local from = vim.api.nvim_get_current_win()
  return function()
    if vim.api.nvim_win_is_valid(from) then
      pcall(vim.api.nvim_set_current_win, from)
    end
  end
end

--- Takes the cursor into a float that is otherwise a hover -- the same
--- key pressed a second time, as `K` does over an LSP hover. A float
--- that goes on the next move is one that cannot be scrolled, searched
--- or yanked out of, and the second press is the reader saying they
--- want to do one of those.
---
--- `dismiss` is the autocmd that takes the float away when the cursor
--- moves, which entering it would fire: it goes first. Inside, `q` and
--- `<Esc>` close it and go back, and leaving it any other way closes it
--- behind you -- it is still a hover, only one being read.
function M.enter(float, dismiss, close)
  if dismiss then
    pcall(vim.api.nvim_del_autocmd, dismiss)
  end
  local back = M.came_from()
  local buf = vim.api.nvim_win_get_buf(float)
  local function done()
    close()
    back()
  end
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, done, { buffer = buf, nowait = true, desc = "close" })
  end
  -- Scheduled: the layout cannot change inside `WinLeave`. And only
  -- this float, which by then may have been replaced by the next one.
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    once = true,
    callback = vim.schedule_wrap(function()
      if vim.api.nvim_win_is_valid(float) and vim.api.nvim_get_current_win() ~= float then
        vim.api.nvim_win_close(float, true)
      end
    end),
  })
  vim.api.nvim_win_set_config(float, { focusable = true })
  vim.api.nvim_set_current_win(float)
end

return M
