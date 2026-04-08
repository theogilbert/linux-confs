local config = require("sections.config")
local pane = require("sections.pane")
local hl = require("sections.hl")
local header = require("sections.header")
local parser = require("sections.parser")
local formatter = require("sections.formatter")

local M = {}

local tab_infos = {}
-- Keeps various information related to the tab, such as:
-- * Which window is currently being watched
-- * Which buffer is currently being watched
-- * Parsed sections to display
-- * Whether or not to display private sections
--
-- The key is the tab number. If the tab number is not present, it means
-- that the section pane is not open.

local function init_tab_info(watched_win, watched_buf)
    local cur_tab = vim.api.nvim_get_current_tabpage()

    tab_infos[cur_tab] = {
        watched_win = watched_win,
        watched_buf = watched_buf,
        sections = {},
        collapsed = {},
        show_private = true,
    }
end

local function get_tab_info()
    local cur_tab = vim.api.nvim_get_current_tabpage()
    return tab_infos[cur_tab]
end

local function clear_tab_info()
    local cur_tab = vim.api.nvim_get_current_tabpage()
    tab_infos[cur_tab] = nil
end

local IGNORED_BUFTYPES = { "nofile", "terminal", "quickfix", "help", "prompt" }

local function supports_buf(buf)
    local bt = vim.api.nvim_get_option_value("buftype", { buf = buf })
    if vim.tbl_contains(IGNORED_BUFTYPES, bt) then
        return false
    end

    return true
end

local function update_current_section_highlight()
    local info = get_tab_info()
    if info == nil or not vim.api.nvim_win_is_valid(info.watched_win) then
        return
    end

    local cursor = vim.api.nvim_win_get_cursor(info.watched_win)
    local cursor_line, cursor_col = cursor[1], cursor[2]
    if info.cached_sequence == nil then
        info.cached_sequence = formatter.build_sequence(info.sections, info.collapsed, info.show_private)
    end
    local pane_line = formatter.get_current_section_pane_line(info.cached_sequence, cursor_line, cursor_col)

    if pane_line == info.last_pane_line then
        return
    end
    info.last_pane_line = pane_line

    pane.highlight_section(pane_line)
    if pane_line ~= nil then
        pane.focus(pane_line)
    end
end

local function render_header(tab_info)
    local header_lines = header.get_lines(tab_info.show_private)
    pane.write_header(header_lines)
    pane.apply_highlight(header.get_hl_rules(tab_info.show_private))
end

local function refresh_pane(win, buf)
    local info = get_tab_info()
    if info == nil or win == nil or buf == nil then
        return
    end

    local win_cfg = vim.api.nvim_win_get_config(win)
    if win_cfg.relative ~= "" then
        return -- Window is floating
    end

    if not supports_buf(buf) then
        return
    end

    render_header(info)

    local sections, err = parser.parse_sections(buf)
    if err ~= nil then
        pane.write_error({ err })
        return
    end

    local sections_lines = formatter.format(sections, info.collapsed, info.show_private)
    pane.write_sections(sections_lines)

    local name_width = formatter.get_max_name_width(sections, info.collapsed, info.show_private)
    local pane_width = pane.get_width()
    local total_width = vim.api.nvim_win_get_width(win) + pane_width
    local max_width = math.floor(total_width / 2)
    local header_width = vim.api.nvim_strwidth(header.get_lines(info.show_private)[1])
    local padding = 2
    local min_width = header_width + padding
    pane.set_width(math.max(min_width, math.min(name_width + padding, max_width)))

    info.watched_win = win
    info.watched_buf = buf
    info.sections = sections
    info.last_pane_line = nil
    info.cached_sequence = nil

    update_current_section_highlight()
end

local function select_section()
    local info = get_tab_info()
    if info == nil then
        return
    end

    local section_number, err = pane.get_selected_section()
    if err ~= nil then
        vim.notify("Failed to select section: " .. err, vim.log.levels.ERROR)
        return
    end

    if section_number == nil then
        return
    end

    local section_pos = formatter.get_section_pos(info.sections, section_number, info.collapsed, info.show_private)
    if section_pos == nil then
        vim.notify("Failed to select section: could not retrieve section position", vim.log.levels.ERROR)
        return
    end

    vim.api.nvim_win_set_cursor(info.watched_win, section_pos)
    vim.api.nvim_set_current_win(info.watched_win)
end

local function toggle_section_collapse()
    local info = get_tab_info()
    if info == nil then
        return
    end

    local section_line, err = pane.get_selected_section()
    if err ~= nil then
        vim.notify("Cannot select section: " .. err, vim.log.level.ERROR)
        return
    end

    local section = formatter.get_nth_section(info.sections, section_line, info.collapsed, info.show_private)
    if section == nil then
        vim.notify("Cannot select section: section is nil", vim.log.level.ERROR)
        return
    end

    if info.collapsed[section.node_id] == nil then
        info.collapsed[section.node_id] = true
    else
        info.collapsed[section.node_id] = nil
    end

    info.last_pane_line = nil
    info.cached_sequence = nil

    local sections_lines = formatter.format(info.sections, info.collapsed, info.show_private)
    pane.write_sections(sections_lines)

    update_current_section_highlight()
end

local function toggle_private()
    local info = get_tab_info()
    if info == nil then
        return
    end

    info.show_private = not info.show_private
    info.last_pane_line = nil
    info.cached_sequence = nil

    render_header(info)

    local sections_lines = formatter.format(info.sections, info.collapsed, info.show_private)
    pane.write_sections(sections_lines)

    update_current_section_highlight()
end

local function setup_autocommands()
    local group = vim.api.nvim_create_augroup("SectionsAutoRefresh", { clear = true })

    -- When saving a file, refresh the pane if the file is currently watched
    vim.api.nvim_create_autocmd("BufWritePost", {
        group = group,
        callback = function(args)
            local info = get_tab_info()
            if info == nil then
                return
            end

            if args.buf == info.watched_buf then
                local win = vim.api.nvim_get_current_win()
                refresh_pane(win, args.buf)
            end
        end,
    })

    -- When moving the cursor in the watched buffer, highlight the current section in the pane
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
        group = group,
        callback = function(args)
            local info = get_tab_info()
            if info == nil or args.buf ~= info.watched_buf then
                return
            end

            update_current_section_highlight()
        end,
    })
end

M.toggle = function()
    local info = get_tab_info()
    local cfg = config.get_config()

    if info == nil then
        local watched_buf = vim.api.nvim_get_current_buf()
        local watched_win = vim.api.nvim_get_current_win()
        init_tab_info(watched_win, watched_buf)
        pane.open({
            width = cfg.width,
            keymaps = {
                [cfg.keymaps.select_section] = select_section,
                [cfg.keymaps.toggle_section_collapse] = toggle_section_collapse,
                [cfg.keymaps.toggle_private] = toggle_private,
            },
            on_close = clear_tab_info,
        })
        refresh_pane(watched_win, watched_buf)
    else
        pane.close()
        clear_tab_info()
    end
end

M.focus = function()
    local pane_win = pane.get_win()
    if pane_win == nil then
        vim.notify("No sections pane is currently open")
        return
    end
    vim.api.nvim_set_current_win(pane_win)
end

M.setup = function(config_)
    config.init(config_)
    setup_autocommands()
    pane.setup()
    hl.setup()
end

return M
