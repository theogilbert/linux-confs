local config = require("sections.config")
local pane = require("sections.pane")
local hl = require("sections.hl")
local header = require("sections.header")
local parser = require("sections.parser")
local formatter = require("sections.formatter")

local M = {}

-- One state per open pane, keyed by the window it watches. Several panes may be
-- open in the same tab, one per watched window. A state holds:
-- * `watched_win`, `watched_buf`: the window being watched, and the buffer it shows
-- * `pane`: the pane handle (see `sections.pane`)
-- * `sections`: parsed sections to display
-- * `collapsed`, `show_private`: display options
local states = {}

--- @return table|nil state The state of the pane watching `win`, or displayed in `win`
local function get_state(win)
    win = win or vim.api.nvim_get_current_win()
    if states[win] ~= nil then
        return states[win]
    end
    for _, state in pairs(states) do
        if state.pane.pane_win == win then
            return state
        end
    end
    return nil
end

local IGNORED_BUFTYPES = { "nofile", "terminal", "quickfix", "help", "prompt" }
-- Man pages are rendered in nofile buffers, help pages in help buffers
local SUPPORTED_SPECIAL_FILETYPES = { "man", "help" }

local function supports_buf(buf)
    local bt = vim.api.nvim_get_option_value("buftype", { buf = buf })
    if vim.tbl_contains(IGNORED_BUFTYPES, bt) and not vim.tbl_contains(SUPPORTED_SPECIAL_FILETYPES, vim.bo[buf].filetype) then
        return false
    end

    return true
end

local function update_current_section_highlight(info)
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

    pane.highlight_section(info.pane, pane_line)
    if pane_line ~= nil then
        pane.focus(info.pane, pane_line)
    end
end

local function cursor_to_current_section(info)
    if info ~= nil and info.last_pane_line ~= nil then
        pane.set_cursor(info.pane, info.last_pane_line)
    end
end

local function render_header(info)
    local header_lines = header.get_lines(info.show_private)
    pane.write_header(info.pane, header_lines)
    pane.apply_highlight(info.pane, header.get_hl_rules(info.show_private))
end

local function refresh_pane(info, opts)
    opts = opts or {}
    if info == nil then
        return
    end
    local win = info.watched_win
    if not vim.api.nvim_win_is_valid(win) then
        return
    end
    local buf = vim.api.nvim_win_get_buf(win)

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
        pane.write_error(info.pane, { err })
        return
    end

    if opts.reset_collapse then
        local cursor = vim.api.nvim_win_get_cursor(win)
        info.collapsed = formatter.get_default_collapsed(sections, cursor[1], cursor[2])
    end

    local sections_lines = formatter.format(sections, info.collapsed, info.show_private)
    pane.write_sections(info.pane, sections_lines)

    local name_width = formatter.get_max_name_width(sections, info.collapsed, info.show_private)
    local pane_width = pane.get_width(info.pane)
    local total_width = vim.api.nvim_win_get_width(win) + pane_width
    local max_width = math.floor(total_width / 2)
    local header_width = vim.api.nvim_strwidth(header.get_lines(info.show_private)[1])
    local padding = 2
    local min_width = header_width + padding
    pane.set_width(info.pane, math.max(min_width, math.min(name_width + padding, max_width)))

    info.watched_buf = buf
    info.sections = sections
    info.last_pane_line = nil
    info.cached_sequence = nil

    update_current_section_highlight(info)
end

local function select_section()
    local info = get_state()
    if info == nil then
        return
    end

    local section_number, err = pane.get_selected_section(info.pane)
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

--- Collapses or expands the section under the cursor in the pane.
---@param collapse boolean|nil true to collapse, false to expand, nil to toggle
---@param recursive boolean|nil true to also apply it to every nested section
local function set_section_collapse(collapse, recursive)
    local info = get_state()
    if info == nil then
        return
    end

    local section_line, err = pane.get_selected_section(info.pane)
    if err ~= nil then
        vim.notify("Cannot select section: " .. err, vim.log.levels.ERROR)
        return
    end

    local section = formatter.get_nth_section(info.sections, section_line, info.collapsed, info.show_private)
    if section == nil then
        vim.notify("Cannot select section: section is nil", vim.log.levels.ERROR)
        return
    end

    if collapse == nil then
        collapse = info.collapsed[section.node_id] == nil
    end
    if recursive then
        local function walk(s)
            info.collapsed[s.node_id] = collapse or nil
            for _, child in ipairs(s.children) do
                walk(child)
            end
        end
        walk(section)
    else
        if (info.collapsed[section.node_id] ~= nil) == collapse then
            return
        end
        info.collapsed[section.node_id] = collapse or nil
    end

    info.last_pane_line = nil
    info.cached_sequence = nil

    local sections_lines = formatter.format(info.sections, info.collapsed, info.show_private)
    pane.write_sections(info.pane, sections_lines)

    update_current_section_highlight(info)
end

--- Collapses or expands every section in the pane, nested ones included.
---@param collapse boolean true to collapse, false to expand
local function set_all_collapse(collapse)
    local info = get_state()
    if info == nil then
        return
    end

    -- With a cursor preceding every section, nothing is left expanded
    info.collapsed = collapse and formatter.get_default_collapsed(info.sections, 0, 0) or {}

    info.last_pane_line = nil
    info.cached_sequence = nil

    local sections_lines = formatter.format(info.sections, info.collapsed, info.show_private)
    pane.write_sections(info.pane, sections_lines)

    update_current_section_highlight(info)
end

local function show_description()
    local info = get_state()
    if info == nil then
        return
    end

    local section_line, err = pane.get_selected_section(info.pane)
    if err ~= nil then
        vim.notify("Cannot select section: " .. err, vim.log.levels.ERROR)
        return
    end

    local section = formatter.get_nth_section(info.sections, section_line, info.collapsed, info.show_private)
    if section == nil then
        return
    end

    if section.description == nil and section.signature == nil then
        vim.notify("No description for section " .. section.name, vim.log.levels.INFO)
        return
    end

    local lines
    if section.signature ~= nil then
        -- The signature is highlighted as code of the watched buffer's language
        local lang = vim.treesitter.language.get_lang(vim.bo[info.watched_buf].filetype) or ""
        lines = { "```" .. lang }
        vim.list_extend(lines, vim.split(section.signature, "\n", { plain = true }))
        table.insert(lines, "```")
    else
        lines = { "**" .. section.name .. "**", "" }
    end
    if section.description ~= nil then
        if section.signature ~= nil then
            table.insert(lines, "---")
        end
        vim.list_extend(lines, vim.split(section.description, "\n", { plain = true }))
    end
    vim.lsp.util.open_floating_preview(lines, "markdown", { border = "rounded", focus_id = "sections_description" })
end

-- Closes the pane and returns to the code window it watches
local function close_pane()
    local info = get_state()
    local watched_win = info and info.watched_win
    -- A pane left behind by its closed watched window has no state anymore
    pane.close(info and info.pane or pane.get_by_win(vim.api.nvim_get_current_win()))
    if watched_win ~= nil and vim.api.nvim_win_is_valid(watched_win) then
        vim.api.nvim_set_current_win(watched_win)
    end
end

local function toggle_private()
    local info = get_state()
    if info == nil then
        return
    end

    info.show_private = not info.show_private
    info.last_pane_line = nil
    info.cached_sequence = nil

    render_header(info)

    local sections_lines = formatter.format(info.sections, info.collapsed, info.show_private)
    pane.write_sections(info.pane, sections_lines)

    update_current_section_highlight(info)
end

local function setup_autocommands()
    local group = vim.api.nvim_create_augroup("SectionsAutoRefresh", { clear = true })

    -- When saving a file, refresh every pane watching it
    vim.api.nvim_create_autocmd("BufWritePost", {
        group = group,
        callback = function(args)
            for _, info in pairs(states) do
                if args.buf == info.watched_buf then
                    refresh_pane(info)
                end
            end
        end,
    })

    -- When a watched window switches to another buffer, watch that buffer instead
    vim.api.nvim_create_autocmd("BufWinEnter", {
        group = group,
        callback = function(args)
            local win = vim.api.nvim_get_current_win()
            local info = states[win]
            if info == nil or args.buf == info.watched_buf or vim.api.nvim_win_get_buf(win) ~= args.buf then
                return
            end

            refresh_pane(info, { reset_collapse = true })
        end,
    })

    -- When moving the cursor in a watched window, highlight the current section in its pane
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
        group = group,
        callback = function(args)
            local info = states[vim.api.nvim_get_current_win()]
            if info == nil or args.buf ~= info.watched_buf then
                return
            end

            update_current_section_highlight(info)
        end,
    })

    -- When quitting a watched window while its pane is the only other window of the tab,
    -- close the pane first: doing it from WinClosed would make the quit abort (E855),
    -- as the watched window would then be the last one.
    vim.api.nvim_create_autocmd("QuitPre", {
        group = group,
        callback = function()
            local info = states[vim.api.nvim_get_current_win()]
            if info == nil then
                return
            end

            if #vim.api.nvim_tabpage_list_wins(0) == 2 then
                pane.close(info.pane)
            end
        end,
    })

    -- When a watched window is closed, close its pane along with it
    vim.api.nvim_create_autocmd("WinClosed", {
        group = group,
        callback = function(args)
            local info = states[tonumber(args.match)]
            if info == nil then
                return
            end

            local tab = vim.api.nvim_win_get_tabpage(info.watched_win)
            if #vim.api.nvim_tabpage_list_wins(tab) > 2 then
                pane.close(info.pane)
            else
                -- The pane is left as the last window: it can no longer follow anything
                states[info.watched_win] = nil
            end
        end,
    })
end

--- Opens a pane watching the current window, or closes the pane of the current
--- window when it has one (the current window being either the pane or the
--- window it watches). Each window of a tab may have its own pane.
M.toggle = function()
    local info = get_state()
    local cur_win = vim.api.nvim_get_current_win()
    if info ~= nil or pane.get_by_win(cur_win) ~= nil then
        pane.close(info and info.pane or pane.get_by_win(cur_win))
        return
    end

    local cfg = config.get_config()
    local watched_win = vim.api.nvim_get_current_win()
    info = {
        watched_win = watched_win,
        watched_buf = vim.api.nvim_win_get_buf(watched_win),
        sections = {},
        collapsed = {},
        show_private = true,
    }
    states[watched_win] = info

    info.pane = pane.open({
        win = watched_win,
        width = cfg.width,
        keymaps = {
            { cfg.keymaps.select_section, select_section },
            { cfg.keymaps.collapse_section, function() set_section_collapse(true) end },
            { cfg.keymaps.expand_section, function() set_section_collapse(false) end },
            { cfg.keymaps.toggle_section_collapse, function() set_section_collapse(nil) end },
            { cfg.keymaps.collapse_section_recursive, function() set_section_collapse(true, true) end },
            { cfg.keymaps.expand_section_recursive, function() set_section_collapse(false, true) end },
            { cfg.keymaps.collapse_all, function() set_all_collapse(true) end },
            { cfg.keymaps.expand_all, function() set_all_collapse(false) end },
            { cfg.keymaps.toggle_private, toggle_private },
            { cfg.keymaps.show_description, show_description },
            { cfg.keymaps.close, close_pane },
        },
        on_close = function()
            if states[watched_win] == info then
                states[watched_win] = nil
            end
        end,
    })
    refresh_pane(info, { reset_collapse = true })
    cursor_to_current_section(info)
end

--- Moves the cursor into the pane of the current window or, when it has none,
--- into the first pane found in the current tab.
M.focus = function()
    local info = get_state()
    if info == nil then
        local tab = vim.api.nvim_get_current_tabpage()
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
            if states[win] ~= nil then
                info = states[win]
                break
            end
        end
    end

    if info == nil then
        vim.notify("No sections pane is currently open")
        return
    end
    vim.api.nvim_set_current_win(info.pane.pane_win)
    cursor_to_current_section(info)
end

--- Flattens a sections tree into `{ name, position }` entries in buffer
--- order. Nested sections are qualified with their ancestors' names
--- ("Class.method") so that same-named sections stay distinguishable.
local function flatten_sections(sections, prefix, out)
    for _, section in ipairs(sections) do
        local qualified = prefix .. section.name
        table.insert(out, { name = qualified, position = section.position })
        flatten_sections(section.children, qualified .. ".", out)
    end
    return out
end

local function get_jump_targets(buf)
    local sections, err = parser.parse_sections(buf)
    if err ~= nil then
        return nil, err
    end
    return flatten_sections(sections, "", {})
end

--- Resolves `name` against the targets, from strictest to loosest:
--- exact qualified name, then bare name (last component), then
--- case-insensitive substring. The first tier with any match wins.
--- @return table|nil target, table|nil ambiguous Every target of the winning tier when it holds more than one
local function find_target(targets, name)
    local needle = name:lower()
    local tiers = { {}, {}, {} }

    for _, target in ipairs(targets) do
        if target.name == name then
            table.insert(tiers[1], target)
        elseif vim.endswith(target.name, "." .. name) then
            table.insert(tiers[2], target)
        elseif target.name:lower():find(needle, 1, true) then
            table.insert(tiers[3], target)
        end
    end

    for _, tier in ipairs(tiers) do
        if #tier == 1 then
            return tier[1], nil
        elseif #tier > 1 then
            return nil, tier
        end
    end

    return nil, nil
end

--- Command-line completion over the current buffer's sections. Usable as a
--- `customlist` completer (see |:command-completion-customlist|), e.g.
--- `completion = "customlist,v:lua.require'sections'.complete"`.
--- @param arglead string The text typed so far
--- @return string[] names Qualified section names containing `arglead`, case-insensitively, in buffer order
M.complete = function(arglead)
    local targets = get_jump_targets(vim.api.nvim_get_current_buf())
    if targets == nil then
        return {}
    end

    local needle = (arglead or ""):lower()
    local names = {}
    for _, target in ipairs(targets) do
        if target.name:lower():find(needle, 1, true) then
            table.insert(names, target.name)
        end
    end
    return names
end

--- Moves the cursor to a section of the current buffer. The pane does not
--- need to be open.
--- @param name string|nil Section name, qualified ("Class.method") or not.
---   When nil or empty, it is asked for on the command line with |input()|,
---   with native completion over the buffer's sections.
M.jump = function(name)
    if name == nil or name == "" then
        name = vim.fn.input({
            prompt = "Section: ",
            completion = "customlist,v:lua.require'sections'.complete",
            cancelreturn = "",
        })
        if name == "" then
            return
        end
    end

    local targets, err = get_jump_targets(vim.api.nvim_get_current_buf())
    if err ~= nil then
        vim.notify("Cannot jump to section: " .. err, vim.log.levels.ERROR)
        return
    end

    local target, ambiguous = find_target(targets, name)
    if target == nil then
        if ambiguous ~= nil then
            local names = vim.tbl_map(function(t)
                return t.name
            end, ambiguous)
            vim.notify("Ambiguous section '" .. name .. "': " .. table.concat(names, ", "), vim.log.levels.WARN)
        else
            vim.notify("No section named '" .. name .. "'", vim.log.levels.WARN)
        end
        return
    end

    -- Record the jump so that <C-o> comes back.
    vim.cmd("normal! m'")
    vim.api.nvim_win_set_cursor(0, target.position)
end

M.setup = function(config_)
    config.init(config_)
    setup_autocommands()
    pane.setup()
    hl.setup()

    vim.api.nvim_create_user_command("SectionsJump", function(cmd)
        M.jump(cmd.args)
    end, { nargs = "?", complete = M.complete, desc = "Jump to a section of the current buffer" })
end

return M
