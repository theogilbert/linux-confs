local M = {}

local center = function(text, width)
    local rough_whitespace_count = (width - #text) / 2
    local before_len = math.floor(rough_whitespace_count)
    local after_len = math.ceil(rough_whitespace_count)
    return string.rep(' ', before_len) .. text .. string.rep(' ', after_len)
end

-- Builds a structure keeping track of the state of a single CSV cell
-- being parsed.
local function build_cell_parser(start_idx, start_char)
    local end_pos = nil
    if start_char == ',' then
        end_pos = start_idx - 1
    end

    return {
        start_pos = start_idx,
        quoted = start_char == '"',
        pending_quote = false,
        end_quote = nil,
        end_pos = end_pos,
    }
end

local function parse_new_char(parser, idx, char)
    if char == '"' then
        parser.pending_quote = not parser.pending_quote
    elseif char == ',' and (not parser.quoted or parser.pending_quote) then
        parser.end_pos = idx - 1
    end

    if char ~= "," and char ~= '"' and parser.pending_quote then
        return "Unexpected quote character at index " .. idx - 1
    end

    return nil
end

local function parse_end_of_line(parser, idx)
    if parser.quoted and not parser.pending_quote then
        return "Expected closing quote at index " .. idx .. " with cell starting at " .. parser.start_pos
    end

    parser.end_pos = idx
    return nil
end

local function extract_text_from_parser(parser, line)
    local cell = line:sub(parser.start_pos, parser.end_pos)

    if parser.quoted then
        local trimmed = cell:sub(2, #cell - 1)
        cell = trimmed:gsub('""', '"')
    end

    return cell
end


-- Return a table containing cells present in the line,
-- and a string or nil value indicating if an error was encountered
-- parsing the line
local parse_csv_line = function(csv_line)
    local cells = {}
    local current_cell_parser = nil

    for idx = 1, #csv_line do
        local char = csv_line:sub(idx, idx)

        if current_cell_parser == nil then
            current_cell_parser = build_cell_parser(idx, char)
        else
            local err = parse_new_char(current_cell_parser, idx, char)
            if err ~= nil then
                return nil, "Error parsing CSV line '" .. csv_line .. "': " .. err
            end
        end

        if current_cell_parser.end_pos ~= nil then
            table.insert(cells, extract_text_from_parser(current_cell_parser, csv_line))
            current_cell_parser = nil
        end
    end

    if current_cell_parser ~= nil then
        local err = parse_end_of_line(current_cell_parser, #csv_line)
        if err ~= nil then
            return nil, "Failed to parse line '" .. csv_line .. "': " .. err
        end

        if current_cell_parser.end_pos ~= nil then
            table.insert(cells, extract_text_from_parser(current_cell_parser, csv_line))
        else
            return nil, "Unexpected end of CSV line '" .. csv_line .. "'"
        end
    end

    return cells, nil
end

local update_cols_widths = function(columns, cols_width)
    for col_num, col in ipairs(columns) do
        if cols_width[col_num] == nil then
            cols_width[col_num] = 0
        end

        cols_width[col_num] = math.max(cols_width[col_num], vim.api.nvim_strwidth(col))
    end

    return cols_width
end


---Creates a new formatted table object.
---
---@param csv_text string A textual CSV content, using comma (`,`) as separator.
---@return table FormattedTable A table with the following fields:
---  - `lines` (table): The input structure data
---  - `columns_width` (table): The width of each column of the table.
---  - `text` (table): The formatted text of the table, in the form of a table of textual lines.
---@return string|nil err: Error message if parsing failed, or nil on success.
function M.from_csv(csv_text)
    local lines = {}

    for line in csv_text:gmatch("[^\n]+") do
        local cols, err = parse_csv_line(line)
        if err ~= nil then
            return {}, err
        end
        table.insert(lines, cols)
    end

    return M.from_lines(lines)
end

---Creates a new formatted table object.
---
---@param lines table The structure data from which to create the formatted table.
---       This table should contain rows, where each row is itself a table containing multiple values.
---       All rows should contain the same number of elements.
---@return table FormattedTable A table with the following fields:
---  - `lines` (table): The input structure data
---  - `columns_width` (table): The width of each column of the table.
---  - `text` (table): The formatted text of the table, in the form of a table of textual lines.
function M.from_lines(lines)
    local cols_width = {}

    -- First, we need to detect the width of each column
    -- so that all rows for a given column are written over
    -- the same number of characters, without truncating any
    -- data.
    for _, cols in ipairs(lines) do
        update_cols_widths(cols, cols_width)
    end

    local formatted_lines = {}
    for _, line in ipairs(lines) do
        local centered_cells = {}
        for col_num, col in ipairs(line) do
            local width = cols_width[col_num]
            local centered = center(col, width)
            table.insert(centered_cells, centered)
        end

        local formatted_line = '│ ' .. table.concat(centered_cells, ' │ ') .. ' │\n'
        table.insert(formatted_lines, formatted_line)
    end

    return {
        lines = lines,
        columns_width = cols_width,
        text = formatted_lines
    }
end

return M
