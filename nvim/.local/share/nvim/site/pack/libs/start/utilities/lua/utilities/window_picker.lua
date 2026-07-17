local M = {}
local H = {}

local LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
local HL_GROUP = "UtilWindowPickerLabel"

--- Returns every window of the current tab (including floats), in reading
--- order (top-to-bottom, then left-to-right within a row), each annotated
--- with the label that should be shown over it.
---
--- Windows sharing the same top row are grouped together and ordered left to
--- right; this matches how split layouts form a grid, so sorting purely by
--- (row, col) yields the expected reading order without needing to detect
--- rows explicitly.
---
---@return table[] entries { win = integer, row = integer, col = integer, label = string|nil }
---  `label` is nil for windows beyond the 26 available letters.
function M.get_ordered_wins()
    local entries = {}

    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local cfg = vim.api.nvim_win_get_config(win)
        -- Non-focusable floats (hover/signature-help/completion/notification
        -- popups, virtual-text-style overlays, ...) are meant to be looked at,
        -- not jumped into, so they don't get a label.
        if cfg.focusable ~= false then
            local pos = vim.api.nvim_win_get_position(win)
            table.insert(entries, { win = win, row = pos[1], col = pos[2] })
        end
    end

    table.sort(entries, function(a, b)
        if a.row ~= b.row then
            return a.row < b.row
        end
        return a.col < b.col
    end)

    for idx, entry in ipairs(entries) do
        entry.label = idx <= #LETTERS and LETTERS:sub(idx, idx) or nil
    end

    return entries
end

-- Open one small floating window per entry, showing its label. Returns the
-- list of { win, buf } pairs so they can be torn down afterwards.
function H.show_labels(entries)
    vim.api.nvim_set_hl(0, HL_GROUP, { bold = true, fg = "#1e1e1e", bg = "#ffcc00" })

    local label_wins = {}
    for _, entry in ipairs(entries) do
        if entry.label then
            local buf = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, { " " .. entry.label .. " " })

            local win = vim.api.nvim_open_win(buf, false, {
                relative = "editor",
                row = entry.row,
                col = entry.col,
                width = 3,
                height = 1,
                style = "minimal",
                focusable = false,
                zindex = 300,
            })
            vim.wo[win].winhighlight = "Normal:" .. HL_GROUP

            table.insert(label_wins, { win = win, buf = buf })
        end
    end

    return label_wins
end

function H.close_labels(label_wins)
    for _, lw in ipairs(label_wins) do
        if vim.api.nvim_win_is_valid(lw.win) then
            vim.api.nvim_win_close(lw.win, true)
        end
        if vim.api.nvim_buf_is_valid(lw.buf) then
            vim.api.nvim_buf_delete(lw.buf, { force = true })
        end
    end
end

--- Label every window in the current tab (including floats) with a letter,
--- then focus whichever window's letter is pressed next. Pressing any other
--- key (or <Esc>) cancels without changing focus.
function M.pick()
    local entries = M.get_ordered_wins()

    if #entries <= 1 then
        return
    end

    if #entries > #LETTERS then
        vim.notify(
            "window_picker: " .. #entries .. " windows open, only labelling the first " .. #LETTERS,
            vim.log.levels.WARN
        )
    end

    local label_wins = H.show_labels(entries)
    vim.cmd("redraw")

    local ok, char = pcall(vim.fn.getcharstr)

    H.close_labels(label_wins)
    vim.cmd("redraw")

    if not ok then
        return
    end

    local label = char:upper()
    for _, entry in ipairs(entries) do
        if entry.label == label then
            vim.api.nvim_set_current_win(entry.win)
            return
        end
    end
end

return M
