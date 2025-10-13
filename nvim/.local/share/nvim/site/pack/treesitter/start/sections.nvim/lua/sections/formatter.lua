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

    local lines = {}
    local sequence = unwrap_sections_into_sequence(sections, collapsed, show_private, cfg)

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

return M
