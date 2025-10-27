local M = {}

local pane = require("nvim-dap-ui-df.pane")

M.setup = function()
    pane.setup()
end

M.toggle_pane = pane.toggle_pane

return M
