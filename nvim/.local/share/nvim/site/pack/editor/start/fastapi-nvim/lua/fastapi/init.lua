-- Public API.
local M = {}

---@type string
M.version = "0.1.0"

---@param opts? table
function M.setup(opts)
    require("fastapi.config").setup(opts)
end

---@return fastapi.App[]
function M.apps()
    return require("fastapi.state").get().apps
end

function M.refresh()
    local state = require("fastapi.state")
    state.refresh()
    state.need_rg("discovery")
end

function M.explorer()
    require("fastapi.ui.explorer").toggle()
end

function M.search()
    require("fastapi.ui.picker").search()
end

function M.jump()
    require("fastapi.ui.jump").jump()
end

return M
