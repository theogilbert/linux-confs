local dap = require("dap")
local Pane = require("nvim-dap-df-pane.pane")
local hl = require("nvim-dap-df-pane.hl")

local M = {}

-- Plugin state
local state = {
	config = {},
	panes = {},
}

-- Default configuration
local default_config = {
	size = 10,
	limit = 500,
}

local function remove_pane(pane)
    for i, p in ipairs(state.panes) do
        if p == pane then
            table.remove(state.panes, i)
            break
        end
    end
end

local pane_count = 0

local function create_pane()
    pane_count = pane_count + 1
    local pane = Pane:new(state.config, pane_count, {
        on_split = function(source)
            local new_pane = create_pane()
            new_pane:open(source.win_id)
        end,
        on_close = remove_pane,
    })
    table.insert(state.panes, pane)
    return pane
end

-- Setup function
function M.setup(opts)
    state.config = vim.tbl_deep_extend("force", default_config, opts or {})

    hl.setup()

    dap.listeners.after.scopes["dap-ui-df"] = function()
        for _, pane in ipairs(state.panes) do
            pane:refresh()
        end
    end
end

-- Open panes. Reopens existing panes if any, otherwise creates a new one.
function M.open()
    if #state.panes > 0 then
        if state.panes[1]:is_open() then
            return
        end
        -- Reopen existing panes
        state.panes[1]:open()
        for i = 2, #state.panes do
            state.panes[i]:open(state.panes[i - 1].win_id)
        end
    else
        local pane = create_pane()
        pane:open()
    end
end

-- Close all pane windows (preserves state for reopening)
function M.close()
    for _, pane in ipairs(state.panes) do
        pane:close()
    end
end

-- Close all panes and destroy state
function M.destroy()
    M.close()
    state.panes = {}
end

-- Inspect a DataFrame/Series expression directly (opens the pane if needed)
function M.inspect(expr)
    if not expr or expr == "" then
        return
    end

    if not dap.session() then
        vim.notify("No active DAP session", vim.log.levels.WARN)
        return
    end

    M.open()
    state.panes[1]:set_expression(expr)
end

-- Get the current pane instance (for internal use)
function M._get_pane()
    return state.panes[1]
end

return M
