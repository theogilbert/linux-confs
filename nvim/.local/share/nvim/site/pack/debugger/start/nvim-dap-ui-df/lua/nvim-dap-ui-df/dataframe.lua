local util = require("dapui.util")
local config = require("dapui.config")
local dapui = require("dapui")
local Canvas = require("dapui.render.canvas")

---@class nvim-dap-ui-df.element
---@toc_entry Watch Expressions
---@text
--- Allows creation of expressions to watch the value of in the context of the
--- current frame.
--- This uses a prompt buffer for input. To enter a new expression, just enter
--- insert mode and you will see a prompt appear. Press enter to submit
---
--- Mappings:
---
--- - `expand`: Toggle showing the children of an expression.
--- - `remove`: Remove the watched expression.
--- - `edit`: Edit an expression or set the value of a child variable.
--- - `repl`: Send expression to REPL
return function(client)
    local df_elt = {
        allow_without_session = true,
    }
    local send_ready = util.create_render_loop(function()
        df_elt.render()
    end)
    local dataframe = require("nvim-dap-ui-df.component")(client, send_ready)

    df_elt.render = function()
        local canvas = Canvas.new()
        dataframe.render(canvas)
        canvas:render_buffer(dapui.elements.dataframe.buffer(), config.element_mapping("dataframe"))
    end

    df_elt.buffer = util.create_buffer("DAP DataFrame", {
        filetype = "dapui_dataframe",
        omnifunc = "v:lua.require'dap'.omnifunc",
    })

    return df_elt
end
