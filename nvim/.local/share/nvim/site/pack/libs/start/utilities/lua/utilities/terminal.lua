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

M.send_to_terminal = function(text)
    _, term_buf = buf_utils.find_terminal()

    if term_buf == nil then
        vim.notify("Cannot send selection to terminal: no terminal found")
        return
    end
    local channel_id = vim.b[term_buf].terminal_job_id
    if channel_id then
        vim.fn.chansend(channel_id, text .. "\n")
    else
        print("Not a terminal buffer.")
    end
end

return M
