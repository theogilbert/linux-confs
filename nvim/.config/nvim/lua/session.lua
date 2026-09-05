
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

local function is_visible(buf)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == buf then
            return true
        end
    end
    return false
end

function M.drop_background_buffers()
    local targets = {}
    local unsaved = {}
    local file_count = 0

    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[buf].buflisted and not is_visible(buf) then
            table.insert(targets, buf)
            local name = vim.api.nvim_buf_get_name(buf)
            local is_file = name ~= "" and vim.bo[buf].buftype == ""
            if is_file then
                file_count = file_count + 1
            end
            -- only warn for buffers backed by a path; scratch/nofile buffers are dropped silently
            if is_file and vim.bo[buf].modified then
                table.insert(unsaved, vim.fn.fnamemodify(name, ":~:."))
            end
        end
    end

    if #targets == 0 then
        vim.notify("No background buffer to drop", vim.log.levels.INFO)
        return
    end

    if #unsaved > 0 then
        local prompt = ("%d unsaved background buffer(s):\n%s\n\nDrop them anyway?")
            :format(#unsaved, table.concat(unsaved, "\n"))
        -- a keyboard interrupt raises here; treat it as "No"
        local ok, choice = pcall(vim.fn.confirm, prompt, "&Yes\n&No", 2, "Warning")
        if not ok or choice ~= 1 then
            return
        end
    end

    for _, buf in ipairs(targets) do
        vim.api.nvim_buf_delete(buf, { force = true })
    end

    vim.notify(
        ("Dropped %d background buffer(s): %d file(s), %d unnamed/scratch")
            :format(#targets, file_count, #targets - file_count),
        vim.log.levels.INFO
    )
end

vim.api.nvim_create_autocmd("VimEnter", {
    pattern = "*",
    callback = M.try_load_session
})

vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = M.save_session,
})

return M
