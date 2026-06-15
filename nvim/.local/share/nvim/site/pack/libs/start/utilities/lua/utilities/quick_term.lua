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

-- There is only ever one quick_term at a time.
local active = nil -- { buf, win, job, close }

local function teardown(state)
    if not state then
        return
    end
    if state.job and not state.exited then
        pcall(vim.fn.jobstop, state.job)
        vim.notify("quick_term: running job aborted", vim.log.levels.WARN)
    end
    if state.win and vim.api.nvim_win_is_valid(state.win) then
        vim.api.nvim_win_close(state.win, true)
    end
    if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
        vim.api.nvim_buf_delete(state.buf, { force = true })
    end
end

-- Run `opts.cmd` in a floating or bottom-split terminal. Any existing
-- quick_term is replaced, so only one window/buffer ever exists.
-- Returns { buf, win, close } so callers can manage the window if needed.
M.run = function(opts)
    opts = vim.tbl_extend("force", defaults, opts or {})
    assert(opts.cmd, "quick_term.run requires a `cmd`")

    -- Replace any existing quick_term with this new one.
    teardown(active)
    active = nil

    local buf, win, jumped = open_window(opts)
    local state = { buf = buf, win = win }
    active = state

    local function close()
        teardown(state)
        if active == state then
            active = nil
        end
    end
    state.close = close

    -- jobstart(term=true) attaches to the current buffer, so run it while the
    -- terminal window/buffer is current, then restore focus if we didn't jump.
    local prev_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(win)
    state.job = vim.fn.jobstart(opts.cmd, {
        term = true,
        on_exit = function(_, code)
            state.exited = true
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

    return state
end

-- Convenience wrapper returning a function suitable for vim.keymap.set.
--   vim.keymap.set("n", "<leader>gl", quick_term.runner({ cmd = "lazygit" }))
M.runner = function(opts)
    return function()
        M.run(opts)
    end
end

return M
