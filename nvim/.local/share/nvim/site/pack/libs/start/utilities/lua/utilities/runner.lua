local M = {}

local buf_utils = require("utilities.buffer")

local run_state = {}  -- filepath -> { win, buf }
local repl_state = nil  -- { win, buf }

vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
        for _, state in pairs(run_state) do
            if vim.api.nvim_buf_is_valid(state.buf) then
                vim.api.nvim_buf_delete(state.buf, { force = true })
            end
        end
        if repl_state and vim.api.nvim_buf_is_valid(repl_state.buf) then
            vim.api.nvim_buf_delete(repl_state.buf, { force = true })
        end
    end,
})

local function repl_job_id()
    if not repl_state or not vim.api.nvim_buf_is_valid(repl_state.buf) then
        return nil
    end
    local job_id = vim.b[repl_state.buf].terminal_job_id
    if not job_id then return nil end
    if vim.fn.jobwait({ job_id }, 0)[1] == -1 then
        return job_id
    end
    return nil
end

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

local function strip_empty_lines(code)
    -- Stripping empty lines is necessary so that empty lines
    -- within functions / indented block do not cause the REPL
    -- to believe that the block is complete.
    local lines = vim.split(code, "\n")
    local result = {}
    for _, line in ipairs(lines) do
        if not line:match("^%s*$") then
            table.insert(result, line)
        end
    end
    return table.concat(result, "\n")
end

M.send_selection_to_repl = function()
    local selection = buf_utils.get_selection()
    if not selection or selection == "" then
        vim.notify("No selection to send to REPL")
        return
    end

    local origin_win = vim.api.nvim_get_current_win()
    local job_id = repl_job_id()

    if not job_id then
        if repl_state and vim.api.nvim_buf_is_valid(repl_state.buf) then
            vim.api.nvim_buf_delete(repl_state.buf, { force = true })
        end
        vim.cmd("belowright new")
        repl_state = {
            win = vim.api.nvim_get_current_win(),
            buf = vim.api.nvim_get_current_buf(),
        }
        job_id = vim.fn.termopen("python3")
    elseif not vim.api.nvim_win_is_valid(repl_state.win) then
        vim.cmd("belowright sbuffer " .. repl_state.buf)
        repl_state.win = vim.api.nvim_get_current_win()
    end

    vim.api.nvim_set_current_win(origin_win)
    vim.api.nvim_chan_send(job_id, strip_empty_lines(selection) .. "\n\n")
end

return M
