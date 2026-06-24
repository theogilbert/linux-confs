-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at https://mozilla.org/MPL/2.0/.

local get_config = require('suit.config').get_config
local util = require('suit.util')

-- Attach secret-mode masking to buf/win.
-- All printable ASCII keys are individually mapped in insert mode so the
-- real characters never reach the buffer.  Each keystroke appends to
-- real_value and re-renders the line as all '*'.
-- Returns an append(text) function for feeding content from other sources
-- (e.g. bracketed paste via vim.paste override).
local function attach_secret(buf, win_id, on_real_value)
  local real_value = ""

  local function refresh()
    local masked = string.rep("*", #real_value)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { masked })
    pcall(vim.api.nvim_win_set_cursor, win_id, { 1, #masked })
    on_real_value(real_value)
  end

  local function append(text)
    real_value = real_value .. text:gsub("[\r\n]", "")
    refresh()
  end

  -- Printable ASCII (space through ~)
  for i = 32, 126 do
    local ch = string.char(i)
    vim.keymap.set("i", ch, function()
      append(ch)
    end, { buffer = buf, noremap = true })
  end

  vim.keymap.set("i", "<BS>", function()
    if #real_value > 0 then
      real_value = real_value:sub(1, -2)
      refresh()
    end
  end, { buffer = buf, noremap = true })

  vim.keymap.set("i", "<C-u>", function()
    real_value = ""
    refresh()
  end, { buffer = buf, noremap = true })

  vim.keymap.set("i", "<C-w>", function()
    real_value = real_value:match("^(.-)%s*%S+%s*$") or ""
    refresh()
  end, { buffer = buf, noremap = true })

  -- <C-r><reg>: paste from a Neovim register (e.g. <C-r>+ for system clipboard)
  vim.keymap.set("i", "<C-r>", function()
    local ok, char = pcall(vim.fn.getcharstr)
    if not ok or not char then return end
    local content = vim.fn.getreg(char)
    if content and content ~= "" then
      append(content)
    end
  end, { buffer = buf, noremap = true })

  -- Block other paste paths that would bypass masking
  for _, lhs in ipairs({ "<C-v>", "<C-a>" }) do
    vim.keymap.set("i", lhs, "", { buffer = buf, noremap = true })
  end

  return append
end

local function open(opts, on_confirm)
  local config = get_config().input
  local prompt = opts.prompt or config.default_prompt
  local secret = opts.secret == true
  local win_config = vim.deepcopy(config.win_config)
  local default_value_width = (not secret and opts.default)
      and vim.str_utfindex(opts.default, 'utf-16')
    or 0
  local input_width = win_config.width + default_value_width
  local prompt_width = vim.str_utfindex(prompt, 'utf-16')
  local width = input_width > prompt_width and input_width or prompt_width
  win_config.width = util.clamp(width, config.max_width or 50)
  win_config.title = { { prompt, 'suitPrompt' } }
  local win = util.open_float_win(win_config, { not secret and opts.default or nil })
  local cursor_col = not secret and opts.default and default_value_width + 1 or 0
  vim.cmd('startinsert')
  vim.api.nvim_win_set_cursor(win.window, { 1, cursor_col })

  local current_value = not secret and (opts.default or "") or ""

  -- restore_paste() undoes the vim.paste override; no-op for non-secret inputs.
  local restore_paste = function() end

  if secret then
    local append = attach_secret(win.buffer, win.window, function(v) current_value = v end)

    -- Override vim.paste so that bracketed-paste sequences (Shift+Insert,
    -- Ctrl+Shift+V, SSH terminal paste, etc.) are routed through our masking
    -- logic rather than written directly to the buffer.
    local orig_paste = vim.paste
    vim.paste = function(lines, phase)
      append(table.concat(lines, ""))
      return true
    end
    restore_paste = function()
      vim.paste = orig_paste
    end
  end

  local confirmed = false
  vim.keymap.set({ 'n', 'i', 'v' }, '<cr>', function()
    if on_confirm then
      confirmed = true
      restore_paste()
      local value = secret and current_value
          or vim.api.nvim_buf_get_lines(win.buffer, 0, 1, false)[1]
      on_confirm(value)
    end
    util.close_window(win.window)
  end, { buffer = win.buffer })
  vim.api.nvim_create_autocmd({ 'BufLeave', 'InsertLeave' }, {
    buffer = win.buffer,
    callback = function()
      restore_paste()
      if on_confirm and not confirmed then
        on_confirm(nil)
      end
      util.close_window(win.window)
    end,
  })
end

local M = { open = open }

return M
