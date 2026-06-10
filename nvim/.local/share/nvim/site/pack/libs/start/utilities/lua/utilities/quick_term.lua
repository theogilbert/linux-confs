local M = {}

local defaults = {
    -- cmd: string | string[]  -- command to run (required)
    position = "float",        -- "float" | "bottom"
    width = 0.9,               -- float: fraction of columns
    height = nil,              -- fraction of lines (float default 0.9, bottom default 0.3)
    border = "rounded",        -- float only
    bg = "#222327",            -- window background (Sonokai dimmed bg)
    title = nil,               -- float border title
    insert = true,             -- enter terminal insert mode (float only)
    -- close_on_exit: true | false | "success"
    --   true     -> always close when the process exits (good for TUIs)
    --   false    -> keep output visible; press `q` to close
    --   "success"-> close only on exit code 0, otherwise keep output for inspection
    close_on_exit = true,
}

-- Open the window the terminal will live in.
-- Returns buf, win, and whether the cursor was moved into the new window.
local function open_window(opts)
    vim.api.nvim_set_hl(0, "UtilFloatTerm", { bg = opts.bg })
    local winhl = "Normal:UtilFloatTerm,NormalFloat:UtilFloatTerm,FloatBorder:UtilFloatTerm"
    local buf = vim.api.nvim_create_buf(false, true)

    if opts.position == "bottom" then
        -- Bottom split: keep the cursor in the current window.
        local orig_win = vim.api.nvim_get_current_win()
        local height = math.floor(vim.o.lines * (opts.height or 0.3))
        vim.cmd("botright " .. height .. "split")
        local win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(win, buf)
        vim.wo[win].winhighlight = winhl
        vim.api.nvim_set_current_win(orig_win)
        return buf, win, false
    end

    -- Float: centered, cursor moves into it.
    local width = math.floor(vim.o.columns * opts.width)
    local height = math.floor(vim.o.lines * (opts.height or 0.9))
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = math.floor((vim.o.lines - height) / 2),
        col = math.floor((vim.o.columns - width) / 2),
        style = "minimal",
        border = opts.border,
        title = opts.title,
        title_pos = opts.title and "center" or nil,
    })
    vim.wo[win].winhighlight = winhl
    return buf, win, true
end

-- Run `opts.cmd` in a floating or bottom-split terminal.
-- Returns { buf, win, close } so callers can manage the window if needed.
M.run = function(opts)
    opts = vim.tbl_extend("force", defaults, opts or {})
    assert(opts.cmd, "quick_term.run requires a `cmd`")

    local buf, win, jumped = open_window(opts)

    local function close()
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
        if vim.api.nvim_buf_is_valid(buf) then
            vim.api.nvim_buf_delete(buf, { force = true })
        end
    end

    -- jobstart(term=true) attaches to the current buffer, so run it while the
    -- terminal window/buffer is current, then restore focus if we didn't jump.
    local prev_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(win)
    vim.fn.jobstart(opts.cmd, {
        term = true,
        on_exit = function(_, code)
            local should_close = opts.close_on_exit == true
                or (opts.close_on_exit == "success" and code == 0)
            if should_close then
                close()
            end
        end,
    })

    -- Close from terminal-normal mode (`<C-\><C-n>` then `q`). Interactive TUIs
    -- such as lazygit grab keys in insert mode, so this never shadows their own
    -- `q`; it only matters once the app exits or you leave insert mode.
    vim.keymap.set("n", "q", close, { buffer = buf, nowait = true })

    if jumped then
        if opts.insert then
            vim.cmd("startinsert")
        end
    else
        vim.api.nvim_set_current_win(prev_win)
    end

    return { buf = buf, win = win, close = close }
end

-- Convenience wrapper returning a function suitable for vim.keymap.set.
--   vim.keymap.set("n", "<leader>gl", quick_term.runner({ cmd = "lazygit" }))
M.runner = function(opts)
    return function()
        M.run(opts)
    end
end

return M
