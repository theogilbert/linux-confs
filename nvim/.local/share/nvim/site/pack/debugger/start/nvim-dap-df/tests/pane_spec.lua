Pane = require("nvim-dap-df-pane.pane")
local hl = require("nvim-dap-df-pane.hl")

describe("Pane", function()
	local pane

	before_each(function()
		local config = { size = 10 }
		pane = Pane:new(config, 1)
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

	describe("jump_to_column()", function()
		--- Make the pane buffer wide enough that virtcol2col can resolve any
		--- target column we test against.
		local function fill_buffer(p)
			vim.bo[p.buffer.buf_id].modifiable = true
			vim.api.nvim_buf_set_lines(p.buffer.buf_id, 0, -1, false, { string.rep("x", 60) })
		end

		local function get_leftcol(p)
			local leftcol
			vim.api.nvim_win_call(p.win_id, function()
				leftcol = vim.fn.winsaveview().leftcol
			end)
			return leftcol
		end

		it("is a no-op when the pane is closed", function()
			assert.has_no.errors(function()
				pane:jump_to_column("age")
			end)
		end)

		it("is a no-op when there is no dataview", function()
			pane:open()
			pane.dataview = nil
			assert.has_no.errors(function()
				pane:jump_to_column("age")
			end)
		end)

		it("sets leftcol to the column boundary and moves the cursor onto it", function()
			pane:open()
			fill_buffer(pane)
			pane.dataview = {
				get_leftcol_for_column = function(_, name)
					return name == "age" and 6 or nil
				end,
				get_column_boundaries = function() return { 0, 6, 12 } end,
			}

			pane:jump_to_column("age")

			assert.equals(6, get_leftcol(pane))
			local cursor = vim.api.nvim_win_get_cursor(pane.win_id)
			assert.equals(6, cursor[2])
		end)

		it("is a no-op when the column is unknown", function()
			pane:open()
			fill_buffer(pane)
			pane.dataview = {
				get_leftcol_for_column = function() return nil end,
				get_column_boundaries = function() return { 0, 6 } end,
			}

			pane:jump_to_column("missing")

			assert.equals(0, get_leftcol(pane))
		end)
	end)

	describe("prompt_jump_to_column()", function()
		local recorded
		local original_fzf

		before_each(function()
			recorded = {}
			original_fzf = package.loaded["fzf-lua"]
			package.loaded["fzf-lua"] = {
				fzf_exec = function(items, opts)
					recorded.items = items
					recorded.opts = opts
				end,
			}
		end)

		after_each(function()
			package.loaded["fzf-lua"] = original_fzf
		end)

		it("is a no-op when there is no dataview", function()
			pane:prompt_jump_to_column()
			assert.is_nil(recorded.items)
		end)

		it("is a no-op when no columns are available", function()
			pane.dataview = { get_column_names = function() return {} end }
			pane:prompt_jump_to_column()
			assert.is_nil(recorded.items)
		end)

		it("passes the column names to fzf-lua", function()
			pane.dataview = { get_column_names = function() return { "idx", "age" } end }
			pane:prompt_jump_to_column()
			assert.same({ "idx", "age" }, recorded.items)
		end)

		it("jumps to the selected column when the default action fires", function()
			pane:open()
			vim.bo[pane.buffer.buf_id].modifiable = true
			vim.api.nvim_buf_set_lines(pane.buffer.buf_id, 0, -1, false, { string.rep("x", 60) })
			pane.dataview = {
				get_column_names = function() return { "idx", "age" } end,
				get_leftcol_for_column = function(_, name)
					return name == "age" and 6 or nil
				end,
				get_column_boundaries = function() return { 0, 6 } end,
			}

			pane:prompt_jump_to_column()
			recorded.opts.actions["default"]({ "age" })

			local leftcol
			vim.api.nvim_win_call(pane.win_id, function()
				leftcol = vim.fn.winsaveview().leftcol
			end)
			assert.equals(6, leftcol)
		end)
	end)
end)
