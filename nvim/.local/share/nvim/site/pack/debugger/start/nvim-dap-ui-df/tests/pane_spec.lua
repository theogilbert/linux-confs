describe("Pane", function()
  local Pane
  
  before_each(function()
    package.loaded["nvim-dap-df-pane.pane"] = nil
    package.loaded["nvim-dap-df-pane.buffer"] = nil
    Pane = require("nvim-dap-df-pane.pane")
  end)
  
  describe("new()", function()
    it("should create a new pane instance", function()
      local config = {
        position = "bottom",
        size = 10,
        default_text = "Test",
      }
      local pane = Pane:new(config)
      
      assert.is_not_nil(pane)
      assert.equals(config, pane.config)
      assert.is_false(pane.is_open_flag)
      assert.is_nil(pane.win_id)
    end)
  end)
  
  describe("open()", function()
    local pane
    
    before_each(function()
      pane = Pane:new({
        position = "bottom",
        size = 10,
        default_text = "Test",
      })
    end)
    
    after_each(function()
      if pane:is_open() then
        pane:close()
      end
    end)
    
    it("should create a window with correct position", function()
      local initial_windows = #vim.api.nvim_list_wins()
      pane:open()
      
      assert.equals(initial_windows + 1, #vim.api.nvim_list_wins())
      assert.is_true(pane:is_open())
      assert.is_not_nil(pane.win_id)
    end)
    
    it("should set window options correctly", function()
      pane:open()
      
      assert.is_false(vim.api.nvim_win_get_option(pane.win_id, "number"))
      assert.is_false(vim.api.nvim_win_get_option(pane.win_id, "relativenumber"))
      assert.equals("no", vim.api.nvim_win_get_option(pane.win_id, "signcolumn"))
    end)
    
    it("should handle different positions", function()
      local positions = {"bottom", "top", "left", "right"}
      
      for _, pos in ipairs(positions) do
        local p = Pane:new({
          position = pos,
          size = 10,
          default_text = "Test",
        })
        
        assert.has_no.errors(function()
          p:open()
          p:close()
        end)
      end
    end)
  end)
  
  describe("close()", function()
    local pane
    
    before_each(function()
      pane = Pane:new({
        position = "bottom",
        size = 10,
        default_text = "Test",
      })
    end)
    
    it("should close the window", function()
      pane:open()
      local windows_when_open = #vim.api.nvim_list_wins()
      
      pane:close()
      
      assert.is_false(pane:is_open())
      assert.equals(windows_when_open - 1, #vim.api.nvim_list_wins())
    end)
  end)
  
  describe("set_content()", function()
    local pane
    
    before_each(function()
      pane = Pane:new({
        position = "bottom",
        size = 10,
        default_text = "Test",
      })
      pane:open()
    end)
    
    after_each(function()
      pane:close()
    end)
    
    it("should update buffer content", function()
      local test_lines = {"Line 1", "Line 2", "Line 3"}
      pane:set_content(test_lines)
      
      local content = pane.buffer:get_content()
      assert.are.same(test_lines, content)
    end)
  end)
end)