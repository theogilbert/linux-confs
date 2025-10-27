describe("Buffer", function()
  local Buffer
  
  before_each(function()
    package.loaded["nvim-dap-df-pane.buffer"] = nil
    Buffer = require("nvim-dap-df-pane.buffer")
  end)
  
  describe("new()", function()
    it("should create a new buffer", function()
      local buffer = Buffer:new()
      
      assert.is_not_nil(buffer)
      assert.is_not_nil(buffer.buf_id)
      assert.is_true(vim.api.nvim_buf_is_valid(buffer.buf_id))

      buffer:close()
    end)
    
    it("should set buffer options correctly", function()
      local buffer = Buffer:new()
      
      assert.equals("nofile", vim.api.nvim_buf_get_option(buffer.buf_id, "buftype"))
      assert.equals("hide", vim.api.nvim_buf_get_option(buffer.buf_id, "bufhidden"))
      assert.is_false(vim.api.nvim_buf_get_option(buffer.buf_id, "swapfile"))
      assert.is_false(vim.api.nvim_buf_get_option(buffer.buf_id, "modifiable"))

      buffer:close()
    end)
    
    it("should set buffer name", function()
      local buffer = Buffer:new()
      local name = vim.api.nvim_buf_get_name(buffer.buf_id)
      
      -- Buffer name should end with the expected pattern (may have path prefix)
      assert.matches("%[DAP DF Pane]$", name)
      buffer:close()
    end)
  end)
  
  describe("set_content()", function()
    local buffer
    
    before_each(function()
      buffer = Buffer:new()
    end)

    after_each(function()
      buffer:close()
    end)
    
    it("should set content from lines array", function()
      local lines = {"Line 1", "Line 2", "Line 3"}
      buffer:set_content(lines)
      
      local content = vim.api.nvim_buf_get_lines(buffer.buf_id, 0, -1, false)
      assert.are.same(lines, content)
    end)
    
    it("should set content from string", function()
      local text = "Line 1\nLine 2\nLine 3"
      buffer:set_content(text)
      
      local content = vim.api.nvim_buf_get_lines(buffer.buf_id, 0, -1, false)
      assert.are.same({"Line 1", "Line 2", "Line 3"}, content)
    end)
    
    it("should keep buffer non-modifiable after setting content", function()
      buffer:set_content({"Test"})
      assert.is_false(vim.api.nvim_buf_get_option(buffer.buf_id, "modifiable"))
    end)
  end)
  
  describe("get_content()", function()
    local buffer
    
    before_each(function()
      buffer = Buffer:new()
    end)

    after_each(function()
        buffer:close()
    end)
    
    it("should return current buffer content", function()
      local lines = {"Test 1", "Test 2"}
      buffer:set_content(lines)
      
      local content = buffer:get_content()
      assert.are.same(lines, content)
    end)
  end)
  
  describe("is_valid()", function()
    local buffer
    
    before_each(function()
      buffer = Buffer:new()
    end)

    after_each(function()
        buffer:close()
    end)

    it("should return true for valid buffer", function()
      assert.is_true(buffer:is_valid())
    end)
    
    it("should return false for deleted buffer", function()
      vim.api.nvim_buf_delete(buffer.buf_id, { force = true })
      assert.is_false(buffer:is_valid())
    end)
  end)
  
  describe("set_keymap()", function()
    local buffer
    
    before_each(function()
      buffer = Buffer:new()
    end)

    after_each(function()
        buffer:close()
    end)
    
    it("should set buffer-local keymaps", function()
      local called = false
      buffer:set_keymap("n", "q", function() called = true end)
      
      -- Switch to the buffer
      vim.api.nvim_set_current_buf(buffer.buf_id)
      
      -- Directly check if the keymap was set correctly by verifying it exists
      local keymaps = vim.api.nvim_buf_get_keymap(buffer.buf_id, "n")
      local found_keymap = false
      for _, keymap in ipairs(keymaps) do
        if keymap.lhs == "q" then
          found_keymap = true
          break
        end
      end
      
      assert.is_true(found_keymap)
    end)
  end)
end)
