local M = {}

-- Open lazygit in a floating terminal taking up 90% of the screen.
-- When lazygit exits (e.g. pressing `q`), the float is closed immediately
-- instead of leaving a "[Process exited 0]" buffer on screen.
M.open = function()
    if vim.fn.executable("lazygit") == 0 then
        vim.notify("lazygit is not installed", vim.log.levels.ERROR)
        return
    end

    local width = math.floor(vim.o.columns * 0.9)
    local height = math.floor(vim.o.lines * 0.9)

    vim.api.nvim_set_hl(0, "LazygitFloat", { bg = "#222327" })

    local buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = math.floor((vim.o.lines - height) / 2),
        col = math.floor((vim.o.columns - width) / 2),
        style = "minimal",
        border = "rounded",
    })

    vim.wo[win].winhighlight = "Normal:LazygitFloat,NormalFloat:LazygitFloat,FloatBorder:LazygitFloat"

    vim.fn.jobstart("lazygit", {
        term = true,
        on_exit = function()
            if vim.api.nvim_win_is_valid(win) then
                vim.api.nvim_win_close(win, true)
            end
            if vim.api.nvim_buf_is_valid(buf) then
                vim.api.nvim_buf_delete(buf, { force = true })
            end
        end,
    })

    vim.cmd("startinsert")
end

return M
