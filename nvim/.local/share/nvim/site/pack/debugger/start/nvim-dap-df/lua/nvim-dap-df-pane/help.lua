local M = {}

--- Display keymaps in a floating window.
--- @param keymaps table[] List of {mode, key, opts} tuples (as stored by Buffer:set_keymap)
function M.show(keymaps)
    local lines = {}
    local max_key_len = 0

    for _, km in ipairs(keymaps) do
        local key = km[2]
        if #key > max_key_len then
            max_key_len = #key
        end
    end

    for _, km in ipairs(keymaps) do
        local key = km[2]
        local desc = km[3] and km[3].desc or ""
        table.insert(lines, string.format("  %-" .. max_key_len .. "s  %s", key, desc))
    end

    local width = 0
    for _, line in ipairs(lines) do
        if #line > width then
            width = #line
        end
    end
    width = width + 2

    local height = #lines
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].bufhidden = "wipe"

    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = row,
        col = col,
        style = "minimal",
        border = "rounded",
        title = " Keymaps ",
        title_pos = "center",
    })

    -- Close on Esc/q key press
    vim.keymap.set("n", "<Esc>", function()
        vim.api.nvim_win_close(win, true)
    end, { buffer = buf })

    vim.keymap.set("n", "q", function()
        vim.api.nvim_win_close(win, true)
    end, { buffer = buf })
end

return M
