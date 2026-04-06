
local M = {}
local uv = vim.uv

local function should_manage_session()
    -- by default, contains { 'vim', '--embed' }
    return #vim.v.argv <= 2
end

local function get_session_dir()
    return vim.fn.stdpath('state') .. '/sessions/'
end

local function get_session_path()
    local cur_path = vim.fn.getcwd()
    local session_signature = vim.fn.sha256(cur_path)
    return get_session_dir() .. session_signature .. '.vim'
end

local function reload_all_file_buffers()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) then
        local name = vim.api.nvim_buf_get_name(buf)
        if name ~= "" then
          vim.api.nvim_buf_call(buf, function()
            vim.cmd("e!")
          end)
        end
      end
    end
end

function M.save_session()
    if not should_manage_session() then
        return
    end

    uv.fs_mkdir(get_session_dir(), 493)
    vim.cmd("mksession! " .. get_session_path())
end


function M.try_load_session()
    if not should_manage_session() then
        return
    end

    local session_path = get_session_path()

    local stat = uv.fs_stat(session_path)
    if not stat or stat.type ~= 'file' then
        return
    end

    vim.cmd("source " .. get_session_path())
    vim.defer_fn(function()
        reload_all_file_buffers()
    end, 50)
end

function M.clear_session()
    os.remove(get_session_path())
end

function M.reset_session()
    M.clear_session()
    -- close all tabs and windows
    vim.cmd("enew | only | tabonly | %bw!")
end

vim.api.nvim_create_autocmd("VimEnter", {
    pattern = "*",
    callback = M.try_load_session
})

vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = M.save_session,
})

return M
