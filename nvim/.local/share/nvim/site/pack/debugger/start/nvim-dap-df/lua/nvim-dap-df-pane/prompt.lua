local Buffer = require("nvim-dap-df-pane.buffer")

local M = {}

--- Opens a floating prompt buffer for entering a Python expression.
-- @param opts table
--   - on_confirm: function(expr: string) called with the expression on save
--   - on_cancel: function() called on exit without save
--   - title: optional string for the window title
--   - expression: optional expression to pre-fill in the prompt
function M.open(opts)
    opts = opts or {}
    local on_confirm = opts.on_confirm
    local title = opts.title or "DAP Expression"

    local buffer = Buffer:new("dap://expression", "dapui_dataframe", true, "acwrite")
    local buf = buffer.buf_id
    vim.bo[buf].bufhidden = "wipe"

    if opts.expression and opts.expression ~= "" then
        buffer:set_content(opts.expression)
    end

    -- Floating window geometry
    local width = math.floor(vim.o.columns * 0.6)
    local height = 5
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = row,
        col = col,
        style = "minimal",
        border = "rounded",
        title = " " .. title .. " ",
        title_pos = "center",
    })

    -- Window-local options
    vim.wo[win].wrap = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].number = false

    -- Track whether the expression was confirmed via save
    local confirmed = false

    -- BufWriteCmd: fires on :w, :wq, :x
    -- We intercept it to capture the expression and mark the buffer as unmodified
    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = buf,
        callback = function()
            local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
            -- Trim blank lines and join into a single expression
            local expr = table.concat(
                vim.tbl_filter(function(l) return l ~= "" end, lines),
                "\n"
            )
            if on_confirm then
                confirmed = true
                on_confirm(expr)
            end
            vim.schedule(function()
                buffer:close()  -- close after :wq fully completes
            end)
        end,
    })

    -- BufWipeout: fires when the window closes for any reason
    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = buf,
        once = true,
        callback = function()
            -- If we never confirmed, the user exited without saving — do nothing
            if not confirmed and opts.on_cancel then
                opts.on_cancel()
            end
        end,
    })
    -- Allow quitting the prompt without saving
    vim.api.nvim_create_autocmd("QuitPre", {
    buffer = buf,
    callback = function()
        -- Discard changes and wipe; BufWipeout will fire and handle on_cancel
        vim.bo[buf].modified = false
    end,
})
    -- Start in insert mode
    vim.cmd("startinsert")

    return buf, win
end

return M
