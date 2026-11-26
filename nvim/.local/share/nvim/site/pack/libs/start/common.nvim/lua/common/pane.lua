-- A side pane: a split beside the code holding a plugin's buffer, sized
-- for what it shows and kept that size, and the way back to where the
-- cursor came from.
--
-- What goes in it is the caller's business; this is the window.

local M = {}

--- The window the cursor is in, and the function that goes back to it.
--- Call that after closing a window of yours: `nvim_win_close` leaves
--- Neovim to pick the successor, and it picks the first window of the
--- layout -- the top left -- which on a split screen is not where the
--- key was pressed. Nothing happens if that window has gone since.
function M.came_from()
  local from = vim.api.nvim_get_current_win()
  return function()
    if vim.api.nvim_win_is_valid(from) then
      pcall(vim.api.nvim_set_current_win, from)
    end
  end
end

--- `win` if it can be split, else the first window of its tab that
--- can: a float cannot, and a key bound everywhere is pressed in floats
--- too.
function M.splittable(win)
  win = (win == nil or win == 0) and vim.api.nvim_get_current_win() or win
  if vim.api.nvim_win_get_config(win).relative == "" then
    return win
  end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(win))) do
    if vim.api.nvim_win_get_config(w).relative == "" then
      return w
    end
  end
  return win
end

local SIDES = { right = true, left = true, below = true, above = true }

--- Opens `opts.buf` in a split and returns the window.
---
--- `opts.side`   -- "right" (default), "left", "below" or "above"
--- `opts.size`   -- columns (right/left) or rows; 40 / 12 by default.
---                  Never more than half the editor: a pane that leaves
---                  nineteen columns of code is a pane opened once.
--- `opts.edge`   -- "window" (default) splits `opts.from`, so the pane
---                  arrives beside it and the layout built around it
---                  stays; "editor" puts it against the editor's edge,
---                  full height or full width
--- `opts.from`   -- the window to split, the current one by default
--- `opts.enter`  -- take the cursor into it (false by default: a pane
---                  is opened to be read beside the code)
--- `opts.wo`     -- window options over the defaults: no number, sign
---                  or fold column, no list, spell or wrap, and its
---                  size fixed while the screen is split around it
function M.open(opts)
  opts = opts or {}
  local side = SIDES[opts.side] and opts.side or "right"
  local vertical = side == "right" or side == "left"
  local cap = vertical and math.floor(vim.o.columns / 2) or math.floor(vim.o.lines / 2)
  local size = math.max(vertical and 10 or 3, math.min(opts.size or (vertical and 40 or 12), cap))

  local config = { split = side, win = -1 }
  if opts.edge ~= "editor" then
    config.win = M.splittable(opts.from)
  end
  config[vertical and "width" or "height"] = size
  local win = vim.api.nvim_open_win(opts.buf, opts.enter or false, config)

  local wo = vim.tbl_extend("force", {
    number = false,
    relativenumber = false,
    signcolumn = "no",
    foldcolumn = "0",
    list = false,
    spell = false,
    wrap = false,
    winfixwidth = true,
    winfixheight = true,
  }, opts.wo or {})
  for name, value in pairs(wo) do
    vim.api.nvim_set_option_value(name, value, { scope = "local", win = win })
  end
  return win
end

return M
