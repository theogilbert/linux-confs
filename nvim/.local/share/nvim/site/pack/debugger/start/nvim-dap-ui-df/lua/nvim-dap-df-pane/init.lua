local dap = require("dap")
local Pane = require("nvim-dap-df-pane.pane")
local hl = require("nvim-dap-df-pane.hl")

local M = {}

-- Plugin state
local state = {
	config = {},
	pane = nil,
}

-- Default configuration
local default_config = {
	size = 10,
}

-- Setup function
function M.setup(opts)
	state.config = vim.tbl_deep_extend("force", default_config, opts or {})

        hl.setup()

	-- Set up autocommands for DAP session lifecycle
	local augroup = vim.api.nvim_create_augroup("NvimDapDfPane", { clear = true })

	vim.api.nvim_create_autocmd("User", {
		pattern = "DapSessionChanged",
		group = augroup,
		callback = function()
			if state.pane then
				state.pane:refresh()
			end
		end,
	})

	dap.listeners.after.event_stopped["dap-ui-df"] = function()
            if state.pane and state.pane:is_open() then
                state.pane:refresh()
            end
        end
end

-- Open the pane
function M.open()
	if not state.pane then
		state.pane = Pane:new(state.config)
	end
	state.pane:open()
end

-- Close the pane
function M.close()
	if state.pane then
		state.pane:close()
	end
end

-- Toggle the pane
function M.toggle()
	if state.pane and state.pane:is_open() then
		M.close()
	else
		M.open()
	end
end

-- Get the current pane instance (for internal use)
function M._get_pane()
	return state.pane
end

return M
