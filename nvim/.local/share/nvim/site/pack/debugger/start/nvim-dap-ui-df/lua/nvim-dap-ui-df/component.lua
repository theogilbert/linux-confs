local config = require("dapui.config")

---@param client dapui.DAPClient
component = function(client, send_ready)
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

            if success then
                formatted_result = evaluate_expression(client, frame_id, expr)
                canvas:write(formatted_result)
            else
                canvas:write(error_msg)
            end

            canvas:add_mapping("edit", function()
                editing = true
                send_ready()
            end, { line = 0 })

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

    if evaluated.type ~= "DataFrame" then
        return false, "Expression is not a Dataframe"
    end

    return true, ""
end

function evaluate_expression(client, frame_id, expr)
    formatted_expr = expr .. ".head(100).to_markdown()"
    success, evaluated = pcall(
        client.request.evaluate,
        { context = "watch", expression = formatted_expr, frameId = frame_id }
    )
    
    if not success then
        return vim.inspect(evaluated)
    end

    return evaluated.result:gsub('\\n', '\n'):sub(2, -2)
end

return component
