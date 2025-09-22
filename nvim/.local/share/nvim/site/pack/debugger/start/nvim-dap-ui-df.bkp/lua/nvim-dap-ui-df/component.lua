local config = require("dapui.config")
local table_fmt = require("utilities.table")

-- TODO separate column names from data lines
-- TODO add column dtype below column name

local function evaluate_expression(client, frame_id, expr)
    local success, evaluated = pcall(
        client.request.evaluate,
        { context = "watch", expression = expr, frameId = frame_id }
    )

    if not success then
        return "", vim.inspect(evaluated)
    end

    local lines = evaluated.result:gsub('\\n', '\n'):sub(2, -2)
    return lines, nil
end

local function fetch_and_format_df(client, frame_id, df_expr)
    -- TODO make this configurable
    local df_data, err = evaluate_expression(
        client, frame_id, df_expr .. ".head(500).to_csv()"
    )

    if err ~= nil then
        return "", err
    end

    local dtypes_expr = "','.join([" .. df_expr .. ".index.dtype.name, *[" .. df_expr .. "[col].dtype.name for col in " .. df_expr .. ".columns]])"
    local df_dtypes, dtypes_err = evaluate_expression(
        client, frame_id, dtypes_expr
    )

    if dtypes_err ~= nil then
        return "", dtypes_err
    end


    local data_first_eol = df_data:find("\n")
    local lines = df_data:sub(1, data_first_eol) .. df_dtypes .. "\n" .. df_data:sub(data_first_eol + 1)

    local table, fmt_err = table_fmt.from_csv(lines, 2)
    return table.text, fmt_err
end

---@param client dapui.DAPClient
local component = function(client, send_ready)
    local running = false
    client.listen.scopes(function()
        running = true
        send_ready()
    end)
    local on_exit = function()
        running = false
        send_ready()
    end

    client.listen.terminated(on_exit)
    client.listen.exited(on_exit)
    client.listen.disconnect(on_exit)

    local expr = ""
    local editing = false

    local function edit_expr(new_value)
        editing = false
        expr = new_value
        send_ready()
    end

    return {
        render = function(canvas)
            if not running then
                canvas:write("No active session")
            end

            local frame_id = client.session
            and client.session.current_frame
            and client.session.current_frame.id

            if editing then
                canvas:set_prompt("> ", edit_expr, { fill = expr })
            end

            success, error_msg = check_expression(client, frame_id, expr)

            local prefix = config.icons["collapsed"]
            canvas:write({
                { prefix, group = success and "DapUIWatchesValue" or "DapUIWatchesError" },
                " " .. expr .. "\n",
            })

            local displayed_text = error_msg
            if success then
                local formatted_result, err = fetch_and_format_df(client, frame_id, expr)
                displayed_text = err or formatted_result
            end

            canvas:write(displayed_text)

            canvas:add_mapping("edit", function()
                editing = true
                send_ready()
            end, { line = 0 })
            -- TODO add mapping on all lines displaying the df
            -- TODO sort by selected column with shortcut

        end
    }
end

function check_expression(client, frame_id, expr)
    if #expr == 0 then
        return false, "No expression"
    end

    success, evaluated = pcall(
        client.request.evaluate,
        { context = "watch", expression = expr, frameId = frame_id }
    )

    if not success or evaluated == nil or evaluated.result == nil then
        return success, evaluated and evaluated.result or "Unexpected failure"
    end

    if evaluated.type ~= "DataFrame" and evaluated.type ~= "Series" then
        return false, "Expression is neither a Dataframe nor a Series"
    end

    return true, ""
end


return component
