local utils = require("sections.utils")
local man = require("sections.man")
local ts = vim.treesitter

local M = {}

local SUPPORTED_CAPTURES = { "section.name", "section.type_annotation", "section.level", "section.description" }

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

-- Whether @node is alone on its line, i.e. only whitespace precedes it
local function is_own_line(node, source)
    local row, col = node:start()
    local line
    if type(source) == "number" then
        line = vim.api.nvim_buf_get_lines(source, row, row + 1, false)[1]
    else
        line = vim.split(source, "\n", { plain = true })[row + 1]
    end
    return line ~= nil and line:sub(1, col):match("^%s*$") ~= nil
end

-- `(#sections-own-line? @node)`: @node is alone on its line, as opposed to a
-- comment trailing some code.
ts.query.add_predicate("sections-own-line?", function(match, _, source, predicate)
    return is_own_line(match[predicate[2]][1], source)
end, { force = true, all = true })

-- `(#sections-tags-only? @node)`: @node holds nothing but tags, e.g. a help
-- line `*'aleph'* *'al'*` tagging the line below it.
ts.query.add_predicate("sections-tags-only?", function(match, _, _, predicate)
    local node = match[predicate[2]][1]
    for _, child in ipairs(node:named_children()) do
        if child:type() ~= "tag" then
            return false
        end
    end
    return node:named_child_count() > 0
end, { force = true, all = true })

-- `(#sections-indented? @node)`: @node, starting its line, is indented
ts.query.add_predicate("sections-indented?", function(match, _, _, predicate)
    local _, col = match[predicate[2]][1]:start()
    return col > 0
end, { force = true, all = true })

-- Trims a description's lines, dropping its leading and trailing blank lines.
-- Returns nil for an empty description.
local function normalize_description(lines)
    local out = {}
    for _, line in ipairs(lines) do
        table.insert(out, (line:gsub("%s+$", "")))
    end
    while #out > 0 and out[1] == "" do
        table.remove(out, 1)
    end
    while #out > 0 and out[#out] == "" do
        table.remove(out)
    end
    return #out > 0 and table.concat(out, "\n") or nil
end

-- Strips the indentation shared by the lines of a docstring, the first line
-- (which follows the opening quotes) aside, like `inspect.cleandoc`.
local function dedent_docstring(text)
    local lines = vim.split(text, "\n", { plain = true })
    local indent
    for i = 2, #lines do
        if lines[i]:match("%S") then
            local width = #lines[i]:match("^%s*")
            indent = indent and math.min(indent, width) or width
        end
    end
    for i = 2, #lines do
        lines[i] = lines[i]:sub((indent or 0) + 1)
    end
    return table.concat(lines, "\n")
end

-- The source of a definition up to its body, e.g. `def f(x: int) -> str:`,
-- preceded by its decorators.
local function definition_signature(section, buf_id)
    local start_node = section.node
    local parent = start_node:parent()
    if parent ~= nil and parent:type() == "decorated_definition" then
        start_node = parent
    end
    local sr, sc = start_node:start()
    local br, bc = section.body:start()
    local lines = vim.api.nvim_buf_get_text(buf_id, sr, sc, br, bc, {})
    -- Continuation lines are indented like the definition itself
    for i = 2, #lines do
        lines[i] = lines[i]:gsub("^" .. (" "):rep(sc), "")
    end
    return vim.trim(table.concat(lines, "\n"))
end

-- `(#set! description_prefix <pattern>)`: the section's description is the
-- run of comment lines right below its header (its last captured node), each
-- stripped of <pattern> and of an optional closing box. The run ends at a blank line, code, a rule, or a line
-- starting another section.
local function collect_following_comments(section, section_rows, source)
    local node = section.header_end
    local lines = {}
    local sibling = node:next_sibling()
    while
        sibling ~= nil
        and sibling:type() == node:type()
        and sibling:start() == node:end_() + 1
        and section_rows[sibling:start()] == nil
        and not is_rule(sibling, source)
        and is_own_line(sibling, source)
    do
        local text = ts.get_node_text(sibling, source)
        local _, prefix_end = text:find(section.description_prefix)
        if prefix_end ~= nil then
            -- Drop a box closing the line with the same marker, e.g. `-- text --`
            local marker = vim.trim(text:sub(1, prefix_end))
            text = text:sub(prefix_end + 1)
            if marker ~= "" and vim.endswith(text, " " .. marker) then
                text = text:sub(1, -#marker - 2)
            end
        end
        table.insert(lines, text)
        node, sibling = sibling, sibling:next_sibling()
    end
    return lines
end

local function build_section(match, metadata, query_info, buf_id)
    local current_section = { children = {} }

    for id, nodes in pairs(match) do
        for _, node in ipairs(nodes) do
            local capture_name = query_info.captures[id]

            -- The header ends with the last node of the match, e.g. a banner's closing rule
            if current_section.header_end == nil or node:end_() > current_section.header_end:end_() then
                current_section.header_end = node
            end

            if capture_name == "section" then
                local sr, sc, _, _ = ts.get_node_range(node)
                current_section.position = { sr + 1, sc }
                current_section.type = metadata.type
                current_section.private = (metadata.private == "true")
                current_section.node = node
            elseif capture_name == "section.body" then
                current_section.body = node
            elseif capture_name == "section.param" then
                if current_section.parameters == nil then
                    current_section.parameters = {}
                end

                local row, col = node:start()
                table.insert(
                    current_section.parameters,
                    { text = ts.get_node_text(node, buf_id), row = row, col = col }
                )
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
    current_section.description_prefix = metadata.description_prefix
    if metadata.docstring == "true" and current_section.description ~= nil then
        current_section.description = dedent_docstring(current_section.description)
    end
    if metadata.signature == "true" and current_section.body ~= nil then
        current_section.signature = definition_signature(current_section, buf_id)
    end

    return current_section
end

local function merge_sections(sections_matches)
    local sections_by_id = {}

    for _, section in ipairs(sections_matches) do
        local node_id = section.node:id()
        if sections_by_id[node_id] == nil then
            sections_by_id[node_id] = section
        else
            local existing = sections_by_id[node_id]
            if section.parameters ~= nil then
                -- We only expect the param parameter to change
                existing.parameters = utils.merge_tables(existing.parameters, section.parameters)
            end
            -- Children may have been attached to any of the duplicate matches,
            -- e.g. to the last match of a class with several superclasses
            vim.list_extend(existing.children, section.children)
        end
    end

    local sections = {}
    for _, section in pairs(sections_by_id) do
        if #section.children > 1 then
            section.children = merge_sections(section.children)
        end
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

-- Matches come in no particular order, so parameters are put back in source order
local function sorted_parameter_names(parameters)
    table.sort(parameters, function(p1, p2)
        if p1.row ~= p2.row then
            return p1.row < p2.row
        end
        return p1.col < p2.col
    end)
    return vim.tbl_map(function(parameter)
        return parameter.text
    end, parameters)
end

local function cleanup_internal_data_from_sections(sections)
    for i = 1, #sections do
        if sections[i].parameters ~= nil then
            sections[i].parameters = sorted_parameter_names(sections[i].parameters)
        end
        sections[i].node_id = sections[i].node:id()
        sections[i].node = nil
        sections[i].level = nil
        sections[i].header_end = nil
        sections[i].body = nil
        sections[i].description_prefix = nil
        sections[i].children = cleanup_internal_data_from_sections(sections[i].children)
    end
    return sections
end

-- Parses TSNode objects matching queries present in queries/<filetype>/sections.scm
-- @param buf_id The ID of the buffer from which to parse the sections
-- @return A table containing sections parsed from the buffer if sections are successfully parsed.
--         Otherwise, returns nil and the error message.
M.parse_sections = function(buf_id)
    local filetype = vim.api.nvim_get_option_value("filetype", { buf = buf_id })
    if filetype == "man" then
        return man.parse_sections(buf_id), nil
    end
    -- The Tree-sitter language may differ from the filetype, e.g. `vimdoc` for `help`
    local lang = ts.language.get_lang(filetype) or filetype

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
    local all_sections = {}
    for _, match, meta in queries:iter_matches(root, buf_id, 0, -1) do
        local new_section = build_section(match, meta, queries.info, buf_id)
        table.insert(all_sections, new_section)

        local parent_section_idx = find_parent_section(new_section, sections_stack)
        if parent_section_idx >= 0 then
            table.insert(sections_stack[parent_section_idx].children, new_section)
            remove_after_nth_index(sections_stack, parent_section_idx)
        else
            table.insert(sections_match, new_section)
        end

        table.insert(sections_stack, new_section)
    end

    local section_rows = {}
    for _, section in ipairs(all_sections) do
        section_rows[section.position[1] - 1] = true
    end
    for _, section in ipairs(all_sections) do
        local lines = section.description and vim.split(section.description, "\n", { plain = true }) or {}
        if section.description_prefix ~= nil then
            vim.list_extend(lines, collect_following_comments(section, section_rows, buf_id))
        end
        section.description = normalize_description(lines)
    end

    local sections = merge_sections(sections_match)

    return cleanup_internal_data_from_sections(sections), nil
end

return M
