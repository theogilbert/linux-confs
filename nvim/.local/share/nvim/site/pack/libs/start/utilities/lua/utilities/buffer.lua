M = {}

-- Find the first terminal in the current tab.
-- Returns the winid and the buffer number.
-- If no terminal is found, returns nil, nil
M.find_terminal = function()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        local bufnr = vim.api.nvim_win_get_buf(win)
        local buftype = vim.api.nvim_buf_get_option(bufnr, "buftype")
        if buftype == "terminal" then
            return win, bufnr
        end
    end

    return nil, nil
end

return M
