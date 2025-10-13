local utils = require("sections.utils")
local ts = vim.treesitter

local M = {}

local SUPPORTED_CAPTURES = { "section.name", "section.type_annotation" }

local function build_section(match, metadata, query_info, buf_id)
    local current_section = { children = {} }

    for id, nodes in pairs(match) do
        for _, node in ipairs(nodes) do
            local capture_name = query_info.captures[id]

            if capture_name == "section" then
                local sr, sc, _, _ = ts.get_node_range(node)
                current_section.position = { sr + 1, sc }
                current_section.type = metadata.type
                current_section.private = (metadata.private == "true")
                current_section.node = node
            elseif capture_name == "section.param" then
                if current_section.parameters == nil then
                    current_section.parameters = {}
                end

                table.insert(current_section.parameters, ts.get_node_text(node, buf_id))
            elseif vim.startswith(capture_name, "section.") then
                local attr_name = string.sub(capture_name, 9)
                if vim.tbl_contains(SUPPORTED_CAPTURES, capture_name) then
                    current_section[attr_name] = ts.get_node_text(node, buf_id)
                else
                    vim.notify(
                        "Capture " .. capture_name .. " is not supported and has been ignored.",
                        vim.log.levels.WARN
                    )
                end
            end
        end
    end

    return current_section
end

local function merge_sections(sections_matches)
    local sections_by_id = {}

    for _, section in ipairs(sections_matches) do
        if #section.children > 1 then
            section.children = merge_sections(section.children)
        end

        local node_id = section.node:id()
        if sections_by_id[node_id] == nil then
            sections_by_id[node_id] = section
        else
            if section.parameters ~= nil then
                -- We only expect the param parameter to change
                local merged_params = utils.merge_tables(sections_by_id[node_id].parameters, section.parameters)
                sections_by_id[node_id].parameters = merged_params
            end
        end
    end

    local sections = {}
    for _, section in pairs(sections_by_id) do
        table.insert(sections, section)
    end

    table.sort(sections, function(s1, s2)
        return s1.position[1] < s2.position[1]
    end)

    return sections
end

local function is_descendant(child, parent_candidate)
    local node = child.node
    local parent_id = parent_candidate.node:id()

    if node == nil then
        return false
    end

    while node:parent() ~= nil do
        local parent = node:parent()
        if parent:id() == parent_id then
            return true
        end
        node = parent
    end

    return false
end

local function find_parent_section(child, section_stack)
    for i = #section_stack, 1, -1 do
        local candidate = section_stack[i]
        if is_descendant(child, candidate) then
            return i
        end
    end

    return -1
end

local function remove_after_nth_index(table, idx)
    for i = idx + 1, #table do
        table[i] = nil
    end
end

local function cleanup_internal_data_from_sections(sections)
    for i = 1, #sections do
        sections[i].node_id = sections[i].node:id()
        sections[i].node = nil
        sections[i].children = cleanup_internal_data_from_sections(sections[i].children)
    end
    return sections
end

-- Parses TSNode objects matching queries present in queries/<filetype>/sections.scm
-- @param buf_id The ID of the buffer from which to parse the sections
-- @return A table containing sections parsed from the buffer if sections are successfully parsed.
--         Otherwise, returns nil and the error message.
M.parse_sections = function(buf_id)
    local lang = vim.api.nvim_get_option_value("filetype", { buf = buf_id })

    local queries = ts.query.get(lang, "sections")
    if queries == nil then
        return nil, "No sections.scm file found for filetype '" .. lang .. "'"
    end
    local parser = ts.get_parser(buf_id, lang, { error = false })
    if parser == nil then
        return nil, "No treesitter parser found for filetype '" .. lang .. "'"
    end

    local tree = parser:parse()[1]
    local root = tree:root()

    local sections_match = {}
    local sections_stack = {}
    for _, match, meta in queries:iter_matches(root, buf_id, 0, -1) do
        local new_section = build_section(match, meta, queries.info, buf_id)

        local parent_section_idx = find_parent_section(new_section, sections_stack)
        if parent_section_idx >= 0 then
            table.insert(sections_stack[parent_section_idx].children, new_section)
            remove_after_nth_index(sections_stack, parent_section_idx)
        else
            table.insert(sections_match, new_section)
        end

        table.insert(sections_stack, new_section)
    end

    local sections = merge_sections(sections_match)

    return cleanup_internal_data_from_sections(sections), nil
end

return M
