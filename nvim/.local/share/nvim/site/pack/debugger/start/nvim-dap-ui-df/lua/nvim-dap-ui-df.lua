local M = {}

local dap = require('dap')
local dapui = require('dapui')
local dataframe = require('nvim-dap-ui-df.dataframe')

M.setup = function()
    local client = require("dapui.client")(dap.session)
    dapui.register_element("dataframe", dataframe(client))
end

return M
