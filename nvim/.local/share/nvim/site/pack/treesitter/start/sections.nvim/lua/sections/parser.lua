local utils = require("sections.utils")
local ts = vim.treesitter

local M = {}

local SUPPORTED_CAPTURES = { "section.name", "section.type_annotation", "section.level" }

-- A banner rule is a comment made of a single repeated character, e.g. `------`
local function is_rule(node, source)
    local text = ts.get_node_text(node, source)
    return #text >= 3 and text:match("^%p") ~= nil and text == text:sub(1, 1):rep(#text)
end

-- `(#sections-banner? @rule @name @close)`: @rule opens a line comment banner
-- whose name line @name follows on the next row, and whose closing rule @close
-- follows on the row after. Banners being closed by the same rule they open
-- with, @rule is an opener when an even number of rules precede it in its run
-- of consecutive comment lines.
ts.query.add_predicate("sections-banner?", function(match, _, source, predicate)
    local rule, name, close = match[predicate[2]][1], match[predicate[3]][1], match[predicate[4]][1]
    if name:start() ~= rule:end_() + 1 or close:start() ~= name:end_() + 1 then
        return false
    end

    local rules_before = 0
    local node = rule
    local prev = node:prev_sibling()
    while prev ~= nil and prev:type() == rule:type() and prev:end_() + 1 == node:start() do
        if is_rule(prev, source) then
            rules_before = rules_before + 1
        end
        node, prev = prev, prev:prev_sibling()
    end

    return rules_before % 2 == 0
end, { force = true, all = true })

-- `(#sections-own-line? @node)`: @node is alone on its line, i.e. only
-- whitespace precedes it, as opposed to a comment trailing some code.
ts.query.add_predicate("sections-own-line?", function(match, _, source, predicate)
    local row, col = match[predicate[2]][1]:start()
    local line
    if type(source) == "number" then
        line = vim.api.nvim_buf_get_lines(source, row, row + 1, false)[1]
    else
        line = vim.split(source, "\n", { plain = true })[row + 1]
    end
    return line ~= nil and line:sub(1, col):match("^%s*$") ~= nil
end, { force = true, all = true })

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
                    -- Directives such as #gsub! store a rewritten text in the capture's metadata
                    local capture_meta = metadata[id]
                    current_section[attr_name] = (capture_meta and capture_meta.text) or ts.get_node_text(node, buf_id)
                else
                    vim.notify(
                        "Capture " .. capture_name .. " is not supported and has been ignored.",
                        vim.log.levels.WARN
                    )
                end
            end
        end
    end

    -- A level is set statically (`#set! level`) or by the length of the
    -- @section.level text, e.g. `##` is level 2
    current_section.level = tonumber(metadata.level) or (current_section.level and #current_section.level)

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
        if s1.position[1] ~= s2.position[1] then
            return s1.position[1] < s2.position[1]
        end
        return s1.position[2] < s2.position[2]
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
        if child.level ~= nil and candidate.level ~= nil then
            -- Leveled sections (e.g. comment banners) are siblings in the tree:
            -- they nest under the closest preceding section of a lower level
            if candidate.level < child.level then
                return i
            end
        elseif is_descendant(child, candidate) then
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
        sections[i].level = nil
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
