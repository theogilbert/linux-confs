local dap = require("dap")
local table_fmt = require("utilities.table")

local pane = require("nvim-dap-ui-df.pane")

local M = {}

local _expr = ""

local function evaluate(session)
    local err, result = session:request("evaluate", { expression = _expr })

    if err ~= nil then
        return {err}
    end
    if result.type ~= "DataFrame" and result.type ~= "series" then
        return {"Expression is neither a Dataframe not a Series, but a " .. result.type}
    end

    local df_err, df_data = session:request("evaluate", {
        expression = _expr .. ".head(500).to_csv()"
    })

    if df_err ~= nil then
        return {df_err}
    end

    local dtypes_expr = "','.join([" .. _expr .. ".index.dtype.name, *[" .. _expr .. "[col].dtype.name for col in " .. _expr .. ".columns]])"

    local dtypes_err, df_dtypes = session:request("evaluate", { expression = dtypes_expr })

    if dtypes_err ~= nil then
        return {dtypes_err}
    end

    local data_first_eol = df_data:find("\n")
    local lines = df_data:sub(1, data_first_eol) .. df_dtypes .. "\n" .. df_data:sub(data_first_eol + 1)

    local table, fmt_err = table_fmt.from_csv(lines, 2)

    if fmt_err then
        return { fmt_err }
    end

    return table.text
end

local function refresh()
    if #_expr == 0 then
        return
    end

    local session = dap.session()
    if session == nil then
        return
    end

    coroutine.wrap(function()
        local result = evaluate(session)
        -- TODO insert > _expr as first line
        pane.write_lines(result)
    end)()
end

M.setup = function()
    -- TODO : auto-refresh on breakpoint stop
    vim.keymap.set("n", "e", function()
        vim.ui.input("Dataframe expression", function (input)
            _expr = input
            refresh()
        end)
    end, { buffer = pane.get_buffer() })
end
