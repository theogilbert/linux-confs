local M = {}

local buf_utils = require("utilities.buffer")

-- Send the selected text to the terminal
M.send_sel_to_terminal = function()
    local selection = buf_utils.get_selection()

    if selection == nil or selection == "" then
        vim.notify("Cannot send selection to terminal: nothing to send")
        return
    end

    return M.send_to_terminal(selection)
end

M.send_to_terminals = function(text)
    local terminals = buf_utils.find_all_terminals()

    if #terminals == 0 then
        vim.notify("Cannot send selection to terminal: no terminal found")
        return
    end

    for _, v in ipairs(terminals) do
        local channel_id = vim.b[v.buf].terminal_job_id
        if channel_id then
            vim.api.nvim_chan_send(channel_id, text .. "\n")
        else
            print("Not a terminal buffer")
        end
    end
end

return M
