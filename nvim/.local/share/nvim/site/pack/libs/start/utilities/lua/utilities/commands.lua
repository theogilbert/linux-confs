local M = {}

M.run_and_check = function(command)
    vim.fn.system(command)
    return vim.v.shell_error == 0
end

return M
