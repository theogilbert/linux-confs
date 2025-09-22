local M = {}

M.PANE_FILETYPE = "dap-dataframe"

local _win
local _buf

M.write_lines = function(lines)
    vim.bo[_buf].modifiable = true
    vim.api.nvim_buf_set_lines(_buf, 0, -1, false, lines)
    vim.bo[_buf].modifiable = false
end

local function init_buf()
    _buf = vim.api.nvim_create_buf(false, false)
    vim.bo[_buf].filetype = M.PANE_FILETYPE
    vim.bo[_buf].buftype = "nofile"
    vim.bo[_buf].modifiable = false

    M.write_lines({"No DAP session is currently running."})
end

local function close_buf()
    if _buf and vim.api.nvim_buf_is_valid(_buf) then
        vim.api.nvim_buf_delete(_buf, { force = true })
    end

    _buf = nil
end

local function open_pane()
    print("Buf: " .. _buf)
    _win = vim.api.nvim_open_win(
        _buf,
        true,
        { split = "below", win = -1, height = 20 }
    )
    vim.wo[_win].wrap = false
end

local function close_pane()
    if vim.api.nvim_win_is_valid(_win) then
        vim.api.nvim_win_close(_win, true)
    end

    _win = nil
end

M.setup = function()
    init_buf()

    local group = vim.api.nvim_create_augroup("DapDataframePane", { clear = true })

    vim.api.nvim_create_autocmd("WinLeave", {
        group = group, callback = close_buf
    })
end

M.toggle_pane = function()
    if _win == nil then
        open_pane()
    else
        close_pane()
    end
end

M.get_buffer = function()
    return _buf
end

return M
