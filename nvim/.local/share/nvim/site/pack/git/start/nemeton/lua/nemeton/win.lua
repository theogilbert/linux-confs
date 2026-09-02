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

return M
