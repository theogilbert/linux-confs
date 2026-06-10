local M = {}

local defaults = {
    -- cmd: string | string[]  -- command to run (required)
    width = 0.9,               -- fraction of columns
    height = 0.9,              -- fraction of lines
    border = "rounded",
    bg = "#222327",            -- float background (Sonokai dimmed bg)
    title = nil,               -- optional border title
    insert = true,             -- enter terminal insert mode on open
    -- close_on_exit: true | false | "success"
    --   true     -> always close the float when the process exits (good for TUIs)
    --   false    -> keep output visible; press `q` to close
    --   "success"-> close only on exit code 0, otherwise keep output for inspection
    close_on_exit = true,
}

-- Run `opts.cmd` in a centered floating terminal.
-- Returns { buf, win, close } so callers can manage the float if needed.
M.run = function(opts)
    opts = vim.tbl_extend("force", defaults, opts or {})
    assert(opts.cmd, "float_term.run requires a `cmd`")

    local width = math.floor(vim.o.columns * opts.width)
    local height = math.floor(vim.o.lines * opts.height)

    vim.api.nvim_set_hl(0, "UtilFloatTerm", { bg = opts.bg })

    local buf = vim.api.nvim_create_buf(false, true)
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
    vim.wo[win].winhighlight =
        "Normal:UtilFloatTerm,NormalFloat:UtilFloatTerm,FloatBorder:UtilFloatTerm"

    local function close()
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
        if vim.api.nvim_buf_is_valid(buf) then
            vim.api.nvim_buf_delete(buf, { force = true })
        end
    end

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
    -- such as lazygit keep grabbing keys in insert mode, so this never shadows
    -- their own `q`; it only matters once the app exits or you leave insert mode.
    vim.keymap.set("n", "q", close, { buffer = buf, nowait = true })

    if opts.insert then
        vim.cmd("startinsert")
    end

    return { buf = buf, win = win, close = close }
end

-- Convenience wrapper returning a function suitable for vim.keymap.set.
--   vim.keymap.set("n", "<leader>gl", float_term.runner({ cmd = "lazygit" }))
M.runner = function(opts)
    return function()
        M.run(opts)
    end
end

return M
