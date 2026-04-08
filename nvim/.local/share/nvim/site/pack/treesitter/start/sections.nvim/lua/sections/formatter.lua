local config = require("sections.config")

local M = {}

local function get_section_icon(section_type)
    local cfg = config.get_config()
    return cfg.icons[section_type] or " "
end

local function get_section_name(section)
    local suffix = ""
    if section.type == "function" or section.type == "class" then
        if section.parameters == nil then
            suffix = "()"
        else
            suffix = "(" .. table.concat(section.parameters, ", ") .. ")"
        end
    elseif section.type == "attribute" and section.type_annotation ~= nil then
        suffix = ": " .. section.type_annotation
    end

    return section.name .. suffix
end

local function get_section_text(section, collapsed, cfg, depth)
    local prefix = string.rep(" ", depth * cfg.indent)
    local icon = get_section_icon(section.type)
    local text = get_section_name(section)
    local suffix = ""

    if collapsed[section.node_id] and #section.children > 0 then
        suffix = " ..."
    end

    return prefix .. icon .. " " .. text .. suffix
end

local function build_sections_sequence_recursively(sequence, section, cfg, collapsed, show_private, depth)
    depth = depth or 0

    if section.private and not show_private then
        return
    end

    local section_line = { depth = depth, value = section }
    table.insert(sequence, section_line)

    if not collapsed[section.node_id] then
        for _, sub_section in pairs(section.children) do
            build_sections_sequence_recursively(sequence, sub_section, cfg, collapsed, show_private, depth + 1)
        end
    end
end

local function unwrap_sections_into_sequence(sections, collapsed, show_private, cfg)
    local sequence = {}

    for _, section in pairs(sections) do
        build_sections_sequence_recursively(sequence, section, cfg, collapsed, show_private)
    end

    return sequence
end

--- Formats the given sections in a textual format.
---
---@param sections table The list of section objects to format
---@param collapsed table A mapping whose keys represent the collapsed sections' `node_id`
---@param show_private boolean If false, sections marked as private will be hidden
---@return table lines The text lines representing the formatted sections
M.format = function(sections, collapsed, show_private)
    local cfg = config.get_config()
    local sequence = unwrap_sections_into_sequence(sections, collapsed, show_private, cfg)

    local lines = {}
    for _, section_line in pairs(sequence) do
        local text = get_section_text(section_line.value, collapsed, cfg, section_line.depth)
        table.insert(lines, text)
    end

    return lines
end

--- Returns the section represented on the nth line in the formatted text
--- @param sections table The list of sections which are formatted
--- @param n integer The line number from which to retrieve the section
--- @param collapsed table A mapping whose keys represent the collapsed sections' `node_id`
--- @param consider_private boolean If false, sections marked as private are considered as hidden
--- @return table|nil found The section present at line `n`, or nil of none found.
M.get_nth_section = function(sections, n, collapsed, consider_private)
    local cfg = config.get_config()
    local sequence = unwrap_sections_into_sequence(sections, collapsed, consider_private, cfg)

    if n > #sequence then
        return nil
    end

    return sequence[n].value
end

--- Returns the section represented on the nth line in the formatted text
--- @param sections table The list of sections which are formatted
--- @param n integer The line number from which to retrieve the section
--- @param collapsed table A mapping whose keys represent the collapsed sections' `node_id`
--- @param consider_private boolean If false, sections marked as private are considered as hidden
--- @return table|nil position The position of the section at the line `section_num`
M.get_section_pos = function(sections, n, collapsed, consider_private)
    local section = M.get_nth_section(sections, n, collapsed, consider_private)
    if section ~= nil then
        return section.position
    end
    return nil
end

--- Builds a flat sequence of visible sections.
--- @param sections table The list of sections
--- @param collapsed table A mapping whose keys represent collapsed sections' node_id
--- @param show_private boolean If false, private sections are hidden
--- @return table sequence The flat sequence
M.build_sequence = function(sections, collapsed, show_private)
    local cfg = config.get_config()
    return unwrap_sections_into_sequence(sections, collapsed, show_private, cfg)
end

--- Returns the maximum display width needed to show section names (excluding parameters).
--- @param sections table The list of sections
--- @param collapsed table A mapping whose keys represent collapsed sections' node_id
--- @param show_private boolean If false, private sections are hidden
--- @return integer width The maximum width in columns
M.get_max_name_width = function(sections, collapsed, show_private)
    local cfg = config.get_config()
    local sequence = unwrap_sections_into_sequence(sections, collapsed, show_private, cfg)

    local max_width = 0
    for _, section_line in ipairs(sequence) do
        local section = section_line.value
        local prefix = string.rep(" ", section_line.depth * cfg.indent)
        local icon = get_section_icon(section.type)
        local name_width = vim.api.nvim_strwidth(prefix .. icon .. " " .. section.name)
        if name_width > max_width then
            max_width = name_width
        end
    end

    return max_width
end

--- Returns the pane line number of the section closest to the given cursor position.
--- If the exact section is not visible (collapsed or hidden), the last visible
--- section before the cursor is returned instead.
--- @param sequence table The flat sequence from `build_sequence()`
--- @param cursor_line integer The 1-indexed cursor line in the source buffer
--- @param cursor_col integer The 0-indexed cursor column in the source buffer
--- @return integer|nil pane_line The 1-indexed pane line, or nil if no section precedes the cursor
M.get_current_section_pane_line = function(sequence, cursor_line, cursor_col)
    -- Binary search: find the last entry with position <= (cursor_line, cursor_col)
    local lo, hi = 1, #sequence
    local best_line = nil

    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local pos = sequence[mid].value.position
        if pos and (pos[1] < cursor_line or (pos[1] == cursor_line and pos[2] <= cursor_col)) then
            best_line = mid
            lo = mid + 1
        else
            hi = mid - 1
        end
    end

    return best_line
end

return M
