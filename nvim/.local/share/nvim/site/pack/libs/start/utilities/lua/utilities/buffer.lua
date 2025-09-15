M = {}

M.is_in_visual_mode = function()
    local cur_mode = vim.fn.mode()

    return cur_mode == 'v' or cur_mode == 'V' or cur_mode == "\22"
end

M.get_selection = function()
    if not M.is_in_visual_mode() then
        return nil
    end

    local _, start_row, start_col, _ = unpack(vim.fn.getpos("v"))
    local _, end_row, end_col, _ = unpack(vim.fn.getpos("."))

    -- Adjust row/col if needed
    if start_row > end_row or (start_row == end_row and start_col > end_col) then
        start_row, end_row = end_row, start_row
        start_col, end_col = end_col, start_col
    end

    local lines = vim.fn.getline(start_row, end_row)
    if #lines == 0 then return "" end

    if vim.fn.mode() ~= 'V' then
        lines[1] = string.sub(lines[1], start_col)
        lines[#lines] = string.sub(lines[#lines], 1, end_col)
    end

    -- TODO handle block visual mode

    return table.concat(lines, "\n")
end

-- Find the first window in the current tab whose
-- displayed buffer matches the specified filetype.
-- Returns the window ID.
-- If no terminal is found, returns nil.
M.find_one_by_filetype = function(target_filetype)
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local bufnr = vim.api.nvim_win_get_buf(win)
        local filetype = vim.api.nvim_buf_get_option(bufnr, "filetype")
        if filetype == target_filetype then
            return win
        end
    end

    return nil
end

M.focus_filetype = function(target_filetype)
    local win_id = M.find_one_by_filetype(target_filetype)
    if win_id ~= nil and vim.api.nvim_win_is_valid(win_id) then
        vim.api.nvim_set_current_win(win_id)
    end
end


-- Find the first terminal in the current tab.
-- Returns the winid and the buffer number.
-- If no terminal is found, returns nil, nil
M.find_terminal = function()
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local bufnr = vim.api.nvim_win_get_buf(win)
        local buftype = vim.api.nvim_buf_get_option(bufnr, "buftype")
        if buftype == "terminal" then
            return win, bufnr
        end
    end

    return nil, nil
end

return M
