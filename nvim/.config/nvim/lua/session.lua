
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

    -- a broken session (e.g. corrupted ShaDa) must not abort startup
    local ok, err = pcall(vim.cmd, "source " .. vim.fn.fnameescape(session_path))
    if not ok then
        vim.notify("Failed to load session: " .. err, vim.log.levels.ERROR)
    end
    vim.defer_fn(function()
        reload_all_file_buffers()
    end, 50)
end

function M.clear_session()
    os.remove(get_session_path())
end

-- floating window showing `lines`, calls on_confirm() only if the user presses y
local function confirm_float(title, lines, on_confirm)
    lines = vim.list_extend(vim.deepcopy(lines), { "", "[y] Yes   [n] No" })

    local width = #title + 4
    for _, line in ipairs(lines) do
        width = math.max(width, vim.fn.strdisplaywidth(line))
    end
    width = math.min(width + 2, vim.o.columns - 4)
    local height = math.min(#lines, vim.o.lines - 4)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.tbl_map(function(l) return " " .. l end, lines))
    vim.bo[buf].modifiable = false
    vim.bo[buf].bufhidden = "wipe"

    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = math.floor((vim.o.lines - height) / 2) - 1,
        col = math.floor((vim.o.columns - width) / 2),
        style = "minimal",
        border = "rounded",
        title = " " .. title .. " ",
        title_pos = "center",
    })

    local done = false
    local function close(confirmed)
        if done then
            return
        end
        done = true
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
        if confirmed then
            on_confirm()
        end
    end

    vim.keymap.set("n", "y", function() close(true) end, { buffer = buf, nowait = true })
    for _, key in ipairs({ "n", "q", "<Esc>" }) do
        vim.keymap.set("n", key, function() close(false) end, { buffer = buf, nowait = true })
    end
    -- leaving the window any other way counts as "No"
    vim.api.nvim_create_autocmd("WinLeave", {
        buffer = buf,
        once = true,
        callback = function() vim.schedule(function() close(false) end) end,
    })
end

function M.reset_session()
    local unsaved = {}
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[buf].modified then
            local name = vim.api.nvim_buf_get_name(buf)
            table.insert(unsaved, name ~= "" and vim.fn.fnamemodify(name, ":~:.") or ("[No Name] #" .. buf))
        end
    end

    local lines = { "Clear session and close all buffers?" }
    if #unsaved > 0 then
        lines = { ("%d unsaved buffer(s), changes will be lost:"):format(#unsaved) }
        for _, name in ipairs(unsaved) do
            table.insert(lines, "  " .. name)
        end
        vim.list_extend(lines, { "", "Clear session and close all buffers anyway?" })
    end

    confirm_float("Clear session", lines, function()
        M.clear_session()
        -- close all tabs and windows, discarding unsaved changes
        local old_bufs = vim.api.nvim_list_bufs()
        vim.api.nvim_win_set_buf(0, vim.api.nvim_create_buf(true, false))
        vim.cmd("silent! only! | silent! tabonly!")
        for _, buf in ipairs(old_bufs) do
            if vim.api.nvim_buf_is_valid(buf) then
                vim.api.nvim_buf_delete(buf, { force = true })
            end
        end
    end)
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
