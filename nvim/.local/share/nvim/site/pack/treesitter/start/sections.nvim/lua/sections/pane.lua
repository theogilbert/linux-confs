local hl = require("sections.hl")

local M = {}

M.PANE_FILETYPE = "sections-pane"
local pane_infos = {}

local function init_pane_info(pane_win, pane_buf, on_close)
    local tab = vim.api.nvim_get_current_tabpage()
    pane_infos[tab] = {
        header_lines = {},
        pane_win = pane_win,
        pane_buf = pane_buf,
        on_close = on_close,
    }
end
local function get_pane_info()
    local cur_tab = vim.api.nvim_get_current_tabpage()
    return pane_infos[cur_tab]
end

local function clear_pane_info()
    local cur_tab = vim.api.nvim_get_current_tabpage()
    pane_infos[cur_tab] = nil
end

M.get_selected_section = function()
    local info = get_pane_info()
    if info == nil then
        return nil, "Cannot get the current line: section pane is not open"
    end

    local selected_line = vim.api.nvim_win_get_cursor(info.pane_win)[1]
    local section_number = selected_line - #info.header_lines

    return (section_number >= 1) and section_number or nil
end

local function write_lines(lines, start, end_)
    local pane_info = get_pane_info()
    if pane_info == nil then
        return false, "Cannot write lines: pane is not open"
    end

    local cursor = vim.api.nvim_win_get_cursor(pane_info.pane_win)

    local pane_buf = pane_info.pane_buf
    vim.bo[pane_buf].modifiable = true
    vim.api.nvim_buf_set_lines(pane_buf, start, end_, false, lines)
    vim.bo[pane_buf].modifiable = false

    local cursor_line, cursor_col = cursor[1], cursor[2]
    if cursor_line <= #lines and cursor_col <= #lines[cursor_line] then
        vim.api.nvim_win_set_cursor(pane_info.pane_win, cursor)
    end

    return true, nil
end

M.write_header = function(lines)
    local pane_info = get_pane_info()

    if pane_info == nil then
        return false, "Cannot write header lines: section pane is not open"
    end

    local success, err = write_lines(lines, 0, #pane_info.header_lines)
    if not success then
        return false, err
    end

    pane_info.header_lines = lines
    return true, nil
end

M.write_sections = function(lines)
    local pane_info = get_pane_info()

    if pane_info == nil then
        return false, "Cannot write sections lines: section pane is not open"
    end

    local success, err = write_lines(lines, #pane_info.header_lines, -1)
    if not success then
        return false, err
    end

    return true, nil
end

M.write_error = function(lines)
    local pane_info = get_pane_info()

    if pane_info == nil then
        return false, "Cannot write error lines: section pane is not open"
    end

    local success, err = write_lines(lines, 0, -1)
    if not success then
        return false, err
    end

    return true, nil
end

-- @param hl_rules table[] List of highlight rules to apply to the buffer, where each rule has:
--   - `higroup` (string): The name of the highlight group to apply
--   - `start` (string|integer[]): Start of region as a (line, column) tuple
--     or string accepted by |getpos()|
--   - `finish` (string|integer[]): End of region as a (line, column) tuple
--     or string accepted by |getpos()|
M.apply_highlight = function(hl_rules)
    local info = get_pane_info()
    if info == nil then
        return
    end

    for _, rule in ipairs(hl_rules) do
        vim.hl.range(info.pane_buf, hl.NS_ID, rule.higroup, rule.start, rule.finish)
    end
end

M.open = function(opts)
    local bufid = vim.api.nvim_create_buf(true, false)
    vim.bo[bufid].filetype = M.PANE_FILETYPE
    vim.bo[bufid].buftype = "nofile"
    vim.bo[bufid].modifiable = false

    local winid = vim.api.nvim_open_win(
        bufid,
        false,
        { vertical = true, split = "left", win = -1, width = 50, style = "minimal" }
    )
    vim.wo[winid].wrap = false
    vim.api.nvim_set_option_value("cursorline", true, { win = winid })
    vim.api.nvim_win_set_hl_ns(winid, hl.NS_ID)
    vim.api.nvim_set_current_win(winid)

    for keymap, action in pairs(opts.keymaps) do
        vim.keymap.set("n", keymap, action, { buffer = bufid })
    end

    init_pane_info(winid, bufid, opts.on_close)
end

M.close = function()
    local info = get_pane_info()
    if info == nil then
        return -- Nothing to do
    end

    if vim.api.nvim_buf_is_valid(info.pane_buf) then
        vim.api.nvim_buf_delete(info.pane_buf, { force = true })
    end
    if vim.api.nvim_win_is_valid(info.pane_win) then
        vim.api.nvim_win_close(info.pane_win, true)
    end

    if info.on_close ~= nil then
        info.on_close()
    end

    clear_pane_info()
end

M.setup = function()
    local group = vim.api.nvim_create_augroup("SectionsPaneCleanup", { clear = true })

    vim.api.nvim_create_autocmd("BufWinEnter", {
        group = group,
        callback = function()
            local info = get_pane_info()
            if info == nil then
                return
            end

            local win = vim.api.nvim_get_current_win()
            if win == info.pane_win then
                -- Prevent switching to another buffer from the pane window, by closing the pane.
                M.close()
            end
        end,
    })
    vim.api.nvim_create_autocmd("WinClosed", {
        group = group,
        callback = function(args)
            local info = get_pane_info()
            if info == nil then
                return
            end

            if args.buf == info.pane_buf then
                M.close()
            end
        end,
    })
end

return M
