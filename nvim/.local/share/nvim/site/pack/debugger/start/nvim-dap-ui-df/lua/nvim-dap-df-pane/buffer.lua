local Buffer = {}
Buffer.__index = Buffer

-- Constructor
function Buffer:new()
  local self = setmetatable({}, Buffer)
  
  -- Create a new buffer
  self.buf_id = vim.api.nvim_create_buf(false, true)
  
  -- Configure the buffer
  vim.api.nvim_buf_set_option(self.buf_id, "buftype", "nofile")
  vim.api.nvim_buf_set_option(self.buf_id, "bufhidden", "hide")
  vim.api.nvim_buf_set_option(self.buf_id, "swapfile", false)
  vim.api.nvim_buf_set_option(self.buf_id, "modifiable", false)
  
  -- Create a unique name using the buffer ID to avoid conflicts
  local name = "[DAP DF Pane " .. self.buf_id .. "]"
  vim.api.nvim_buf_set_name(self.buf_id, name)
  
  return self
end

-- Set the buffer content
function Buffer:set_content(lines)
  if type(lines) == "string" then
    lines = vim.split(lines, "\n")
  end
  
  -- Temporarily make the buffer modifiable
  vim.api.nvim_buf_set_option(self.buf_id, "modifiable", true)
  
  -- Set the lines
  vim.api.nvim_buf_set_lines(self.buf_id, 0, -1, false, lines)
  
  -- Make it non-modifiable again
  vim.api.nvim_buf_set_option(self.buf_id, "modifiable", false)
end

-- Get the buffer content
function Buffer:get_content()
  return vim.api.nvim_buf_get_lines(self.buf_id, 0, -1, false)
end

-- Check if the buffer is valid
function Buffer:is_valid()
  return vim.api.nvim_buf_is_valid(self.buf_id)
end

-- Set a keymap for the buffer
function Buffer:set_keymap(mode, key, callback, opts)
  opts = opts or {}
  opts.buffer = self.buf_id
  vim.keymap.set(mode, key, callback, opts)
end

return Buffer