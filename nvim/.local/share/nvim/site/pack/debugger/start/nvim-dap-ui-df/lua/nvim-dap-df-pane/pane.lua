local Buffer = require("nvim-dap-df-pane.buffer")

local Pane = {}
Pane.__index = Pane

-- Constructor
function Pane:new(config)
  local self = setmetatable({}, Pane)
  self.config = config
  self.win_id = nil
  self.buffer = Buffer:new()
  self.is_open_flag = false
  return self
end

-- Open the pane window
function Pane:open()
  if self:is_open() then
    return
  end
  
  -- Create the split based on position
  local cmd
  if self.config.position == "bottom" then
    cmd = string.format("botright %dsplit", self.config.size)
  elseif self.config.position == "top" then
    cmd = string.format("topleft %dsplit", self.config.size)
  elseif self.config.position == "left" then
    cmd = string.format("topleft %dvsplit", self.config.size)
  elseif self.config.position == "right" then
    cmd = string.format("botright %dvsplit", self.config.size)
  else
    error("Invalid position: " .. self.config.position)
  end
  
  vim.cmd(cmd)
  self.win_id = vim.api.nvim_get_current_win()
  
  -- Set the buffer in the window
  vim.api.nvim_win_set_buf(self.win_id, self.buffer.buf_id)
  
  -- Configure the window
  vim.api.nvim_win_set_option(self.win_id, "number", false)
  vim.api.nvim_win_set_option(self.win_id, "relativenumber", false)
  vim.api.nvim_win_set_option(self.win_id, "signcolumn", "no")
  vim.api.nvim_win_set_option(self.win_id, "winfixheight", true)
  vim.api.nvim_win_set_option(self.win_id, "winfixwidth", true)
  
  self.is_open_flag = true
  self:refresh()
end

-- Close the pane window
function Pane:close()
  if self.win_id and vim.api.nvim_win_is_valid(self.win_id) then
    vim.api.nvim_win_close(self.win_id, true)
  end
  self.win_id = nil
  self.is_open_flag = false
end

-- Check if the pane is open
function Pane:is_open()
  return self.is_open_flag and self.win_id and vim.api.nvim_win_is_valid(self.win_id)
end

-- Refresh the pane content
function Pane:refresh()
  if not self:is_open() then
    return
  end
  
  -- Check if DAP session is active
  local dap_ok, dap = pcall(require, "dap")
  local content
  
  if dap_ok and dap.session() then
    -- DAP session is active - for now just show a different message
    content = { "DAP session active" }
  else
    -- No DAP session
    content = { self.config.default_text }
  end
  
  self.buffer:set_content(content)
end

-- Set custom content (for internal use)
function Pane:set_content(lines)
  self.buffer:set_content(lines)
end

return Pane