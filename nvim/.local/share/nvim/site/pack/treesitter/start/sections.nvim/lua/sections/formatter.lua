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

local function get_section_text(section, cfg, depth)
    local prefix = string.rep(" ", depth * cfg.indent)
    local icon = get_section_icon(section.type)
    local text = get_section_name(section)
    local suffix = ""

    if section.collapsed and #section.children > 0 then
        suffix = " ..."
    end

    return prefix .. icon .. " " .. text .. suffix
end

local function build_sections_sequence_recursively(sequence, section, cfg, show_private, depth)
    depth = depth or 0

    if section.private and not show_private then
        return
    end

    local section_line = { depth = depth, value = section }
    table.insert(sequence, section_line)

    if not section.collapsed then
        for _, sub_section in pairs(section.children) do
            build_sections_sequence_recursively(sequence, sub_section, cfg, show_private, depth + 1)
        end
    end
end

local function unwrap_sections_into_sequence(sections, show_private, cfg)
    local sequence = {}

    for _, section in pairs(sections) do
        build_sections_sequence_recursively(sequence, section, cfg, show_private)
    end

    return sequence
end

M.format = function(sections, show_private)
    local cfg = config.get_config()

    local lines = {}
    local sequence = unwrap_sections_into_sequence(sections, show_private, cfg)

    for _, section_line in pairs(sequence) do
        local text = get_section_text(section_line.value, cfg, section_line.depth)
        table.insert(lines, text)
    end

    return lines
end

local function get_nth_section(sections, n)
    local cfg = config.get_config()
    local sequence = unwrap_sections_into_sequence(sections, cfg)

    if n > #sequence then
        return nil
    end

    return sequence[n].value
end

M.get_section_pos = function(sections, section_num)
    local section = get_nth_section(sections, section_num)
    if section ~= nil then
        return section.position
    end
    return nil
end

M.toggle_collapse = function(sections, section_num)
    local section = get_nth_section(sections, section_num)

    if section == nil then
        return
    end

    section.collapsed = not section.collapsed
end

return M
