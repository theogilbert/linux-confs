describe("nvim-dap-df-pane", function()
  local dap_pane
  
  before_each(function()
    -- Reset the module state
    package.loaded["nvim-dap-df-pane"] = nil
    package.loaded["nvim-dap-df-pane.pane"] = nil
    package.loaded["nvim-dap-df-pane.buffer"] = nil
    
    dap_pane = require("nvim-dap-df-pane")
  end)
  
  after_each(function()
    -- Clean up any open windows
    local existing_pane = dap_pane._get_pane()
    if existing_pane then
      existing_pane.buffer:close()
      dap_pane.close()
    end
  end)
  
  describe("setup()", function()
    it("should accept default configuration", function()
      assert.has_no.errors(function()
        dap_pane.setup()
      end)
    end)
    
    it("should accept custom configuration", function()
      assert.has_no.errors(function()
        dap_pane.setup({ size = 20 })
      end)
    end)
  end)
  
  describe("open()", function()
    before_each(function()
      dap_pane.setup()
    end)
    
    it("should open the pane window", function()
      local initial_windows = #vim.api.nvim_list_wins()
      dap_pane.open()
      assert.equals(initial_windows + 1, #vim.api.nvim_list_wins())
    end)
    
    it("should not create multiple windows when called twice", function()
      dap_pane.open()
      local windows_after_first = #vim.api.nvim_list_wins()
      dap_pane.open()
      assert.equals(windows_after_first, #vim.api.nvim_list_wins())
    end)
  end)
  
  describe("close()", function()
    before_each(function()
      dap_pane.setup()
    end)
    
    it("should close the pane window", function()
      local initial_windows = #vim.api.nvim_list_wins()
      dap_pane.open()
      dap_pane.close()
      assert.equals(initial_windows, #vim.api.nvim_list_wins())
    end)
    
    it("should handle closing when already closed", function()
      assert.has_no.errors(function()
        dap_pane.close()
      end)
    end)
  end)
  
  describe("toggle()", function()
    before_each(function()
      dap_pane.setup()
    end)
    
    it("should open when closed", function()
      local initial_windows = #vim.api.nvim_list_wins()
      dap_pane.toggle()
      assert.equals(initial_windows + 1, #vim.api.nvim_list_wins())
    end)
    
    it("should close when open", function()
      local initial_windows = #vim.api.nvim_list_wins()
      dap_pane.open()
      dap_pane.toggle()
      assert.equals(initial_windows, #vim.api.nvim_list_wins())
    end)
  end)
  
  describe("prompt expression", function()
    it("should display expression prompt", function()
      dap_pane.setup({})
      dap_pane.open()
      
      local pane = dap_pane._get_pane()
      local content = pane.buffer:get_content()
      assert.equals("Press 'e' to enter an expression", content[1])
    end)
  end)
end)
