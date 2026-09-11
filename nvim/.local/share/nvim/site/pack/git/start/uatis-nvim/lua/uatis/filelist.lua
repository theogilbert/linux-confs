-- The side pane's buffer: what is being compared on top, one row per
-- changed file below.
--
-- Drawing only. Which file is current, and what happens when you pick
-- one, belong to `pane.lua` -- selecting a row and pressing ]f route
-- through the same function there, so there is only ever one idea of
-- what "go to a file" means.

local ui = require("uatis.ui")
local config = require("uatis.config")

local M = {}

local ns = vim.api.nvim_create_namespace("uatis_list")

function M.create()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "uatis-files"
  vim.api.nvim_buf_set_name(buf, "uatis://files")
  return buf
end

function M.setup_window(win)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].winfixwidth = true
  vim.wo[win].list = false
  vim.wo[win].spell = false
end

--- Redraws the whole pane. Cheap enough to do on every navigation, which
--- keeps the header and the current-file marker from ever disagreeing
--- with the code pane.
function M.render(pane)
  local buf = pane.list_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  -- The window's real width, not the one it was opened at: a reader who
  -- widens the pane is asking to see the paths it was cutting off, and
  -- `config.list.width` is only where the window STARTS. Kept on the pane
  -- so a resize can tell whether anything it drew has moved.
  local win = pane.list_win
  local width = (win and vim.api.nvim_win_is_valid(win))
    and vim.api.nvim_win_get_width(win) or config.list.width
  pane.list_width = width
  local built = ui.build_list(pane, width)

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, built.lines)
  vim.bo[buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(built.hls) do
    local text = built.lines[h.line + 1] or ""
    local e = h.col_end < 0 and #text or math.min(h.col_end, #text)
    if e > h.col_start then
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, h.line, h.col_start, {
        end_col = e,
        hl_group = h.hl,
      })
    end
  end

  pane.list_rows = built.rows
  pane.list_dirs = built.dirs
  -- The foot of the pane: where the current file leaves you in the
  -- review. A window status line rather than a row of the buffer,
  -- because that is the one place in a window that is always at the
  -- bottom of it -- a last line scrolls away the moment the list is
  -- taller than the window, which is exactly the review that has
  -- progress worth reading. It is this window's own, so nothing of the
  -- reader's is being written over and there is nothing to hand back:
  -- the window is ours and closing it takes the setting with it.
  if win and vim.api.nvim_win_is_valid(win) then
    vim.wo[win].statusline = config.list.progress and ui.progress(pane, width) or ""
  end
  M.sync_cursor(pane)
end

--- Moves the pane's cursor onto the row for the current file, without
--- disturbing which window has focus.
function M.sync_cursor(pane)
  local win = pane.list_win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  for line, idx in pairs(pane.list_rows or {}) do
    if idx == pane.file_idx then
      pcall(vim.api.nvim_win_set_cursor, win, { line, 0 })
      return
    end
  end
end

return M
