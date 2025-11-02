Pane = require("nvim-dap-df-pane.pane")
local hl = require("nvim-dap-df-pane.hl")

describe("Pane", function()
	local pane

	before_each(function()
		local config = { size = 10 }
		pane = Pane:new(config)
		hl.setup()
	end)

	after_each(function()
		pane.buffer:close()
	end)

	describe("new()", function()
		it("should create a new pane instance", function()
			assert.not_nil(pane)
			assert.is_false(pane.is_open_flag)
			assert.is_nil(pane.win_id)
		end)
	end)

	describe("open()", function()
		it("should set window options correctly", function()
			pane:open()

			assert.is_false(vim.api.nvim_win_get_option(pane.win_id, "number"))
			assert.is_false(vim.api.nvim_win_get_option(pane.win_id, "relativenumber"))
			assert.equals("no", vim.api.nvim_win_get_option(pane.win_id, "signcolumn"))
		end)
	end)

	describe("close()", function()
		it("should close the window", function()
			pane:open()
			local windows_when_open = #vim.api.nvim_list_wins()

			pane:close()

			assert.is_false(pane:is_open())
			assert.equals(windows_when_open - 1, #vim.api.nvim_list_wins())
		end)
	end)
end)
