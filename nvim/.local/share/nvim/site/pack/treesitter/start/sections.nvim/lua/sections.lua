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

    info.watched_win = win
    info.watched_buf = buf
    info.sections = sections
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

    local sections_lines = formatter.format(info.sections, info.collapsed, info.show_private)
    pane.write_sections(sections_lines)
end

local function toggle_private()
    local info = get_tab_info()
    if info == nil then
        return
    end

    info.show_private = not info.show_private

    render_header(info)

    local sections_lines = formatter.format(info.sections, info.collapsed, info.show_private)
    pane.write_sections(sections_lines)
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

    -- When focusing a different win, refresh the pane
    vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter" }, {
        group = group,
        callback = function(args)
            local win = vim.api.nvim_get_current_win()
            refresh_pane(win, args.buf)
        end,
    })
    --
    -- When closing the window, go back to the original win
    vim.api.nvim_create_autocmd({ "WinClosed" }, {
        group = group,
        callback = function(args)
            local info = get_tab_info()
            if info == nil then
                return
            end
            vim.api.nvim_set_current_win(info.watched_win)
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

M.setup = function(config_)
    config.init(config_)
    setup_autocommands()
    pane.setup()
    hl.setup()
end

return M
