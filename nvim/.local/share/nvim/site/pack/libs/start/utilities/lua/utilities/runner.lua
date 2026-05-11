local M = {}

local run_state = {}  -- filepath -> { win, buf }

vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
        for _, state in pairs(run_state) do
            if vim.api.nvim_buf_is_valid(state.buf) then
                vim.api.nvim_buf_delete(state.buf, { force = true })
            end
        end
    end,
})

M.run_python_file = function()
    local filepath = vim.fn.expand("%:p")
    if filepath == "" then
        vim.notify("No file to run")
        return
    end

    local cmd = "python3 " .. vim.fn.shellescape(filepath)
    local state = run_state[filepath]
    local origin_win = vim.api.nvim_get_current_win()

    if state and vim.api.nvim_win_is_valid(state.win) then
        local old_buf = vim.api.nvim_win_get_buf(state.win)
        vim.api.nvim_set_current_win(state.win)
        vim.cmd("enew")
        vim.api.nvim_buf_delete(old_buf, { force = true })
        state.buf = vim.api.nvim_get_current_buf()
    else
        if state and vim.api.nvim_buf_is_valid(state.buf) then
            vim.api.nvim_buf_delete(state.buf, { force = true })
        end
        vim.cmd("belowright new")
        run_state[filepath] = {
            win = vim.api.nvim_get_current_win(),
            buf = vim.api.nvim_get_current_buf(),
        }
    end

    vim.fn.termopen(cmd)
    vim.api.nvim_set_current_win(origin_win)
end

return M
