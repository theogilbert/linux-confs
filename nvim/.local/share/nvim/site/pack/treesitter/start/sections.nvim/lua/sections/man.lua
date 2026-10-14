-- Man pages have no Tree-sitter grammar: their sections are read from the
-- layout of the rendered page instead.
--
-- * level 1: section headings (`.SH`), at column 0, e.g. `DESCRIPTION`
-- * level 2: subsection headings (`.SS`), indented by 3, e.g. `   Exit status:`
-- * level 3: option entries, indented by 7 and starting a paragraph, e.g. `       -a, --all`

local M = {}

-- The page's title and footer lines, e.g. `LS(1)   User Commands   LS(1)`
local function is_title_or_footer(line)
    return line:match("%S+%(%w+%)%s*$") ~= nil
end

local function get_heading_level(line)
    if line:match("^%S") then
        return not is_title_or_footer(line) and 1 or nil
    elseif line:match("^   %S") then
        return 2
    end
    return nil
end

local function get_level(line, prev_line)
    local level = get_heading_level(line)
    if level ~= nil then
        return level
    end
    -- An option starts its paragraph, as opposed to an option quoted mid-sentence
    local starts_paragraph = prev_line == nil or prev_line:match("^%s*$") or get_heading_level(prev_line) ~= nil
    if line:match("^       %-") and starts_paragraph then
        return 3
    end
    return nil
end

--- @param buf_id number The man page's buffer
--- @return table sections The page's sections, nested by level
M.parse_sections = function(buf_id)
    local lines = vim.api.nvim_buf_get_lines(buf_id, 0, -1, false)
    local sections = {}
    local stack = {}

    local i = 1
    while i <= #lines do
        local line = lines[i]
        local level = get_level(line, lines[i - 1])
        if level == nil then
            i = i + 1
        else
            local name = vim.trim(line)
            local start_row = i
            if level == 3 then
                -- Short options may share their line with their description, e.g. `-c     with -lt: ...`
                name = name:gsub("%s%s+.*", "")
                -- Long option lists wrap on the following lines, e.g. `--min-parents=<n>, --no-min-parents,`
                while vim.endswith(name, ",") and lines[i + 1] ~= nil and lines[i + 1]:match("^       %-") do
                    i = i + 1
                    name = name .. " " .. vim.trim(lines[i])
                end
            end
            i = i + 1

            local section = {
                name = name:gsub(":$", ""),
                type = level == 3 and "attribute" or "header",
                position = { start_row, #line:match("^%s*") },
                private = false,
                node_id = start_row,
                level = level,
                children = {},
            }

            while #stack > 0 and stack[#stack].level >= level do
                table.remove(stack)
            end
            table.insert(#stack > 0 and stack[#stack].children or sections, section)
            table.insert(stack, section)
        end
    end

    local function cleanup(list)
        for _, section in ipairs(list) do
            section.level = nil
            cleanup(section.children)
        end
        return list
    end
    return cleanup(sections)
end

return M
