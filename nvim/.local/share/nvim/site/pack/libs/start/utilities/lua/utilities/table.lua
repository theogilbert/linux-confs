local M = {}

local center = function(text, width)
    local rough_whitespace_count = (width - #text) / 2
    local before_len = math.floor(rough_whitespace_count)
    local after_len = math.ceil(rough_whitespace_count)
    return string.rep(' ', before_len) .. text .. string.rep(' ', after_len)
end

--- @return table data A structure keeping track of the state of a single CSV
--- cell being parsed character by character.
local function build_cell_data(start_idx, start_char)
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

local function parse_new_char(cell_data, idx, char)
    if char == '"' then
        cell_data.pending_quote = not cell_data.pending_quote
    elseif char == ',' then
        if not cell_data.quoted or cell_data.pending_quote then
            cell_data.end_pos = idx - 1
        end
    elseif cell_data.pending_quote then
        return "Unexpected quote character at index " .. idx - 1
    end

    return nil
end

local function process_end_of_line(cell_data, idx)
    if cell_data.quoted and not cell_data.pending_quote then
        return "Expected quoted cell starting at " .. cell_data.start_pos .. " to be closed at " .. idx
    end

    cell_data.end_pos = idx
    return nil
end

local function extract_text_from_cell_data(cell_data, line)
    local cell = line:sub(cell_data.start_pos, cell_data.end_pos)

    if cell_data.quoted then
        local trimmed = cell:sub(2, #cell - 1)
        cell = trimmed:gsub('""', '"')
    end

    return cell
end


--- Extract columns from a CSV line
---
--- @param csv_line string A single CSV line, using comma `,` as a separator.
--- @return table columns The list of columns extracted from the CSV line.
---   In case of a failure to parse the CSV line, the table will be empty.
--- @return string|nil err An error message if the CSV line could not be parsed.
---   Nil otherwise.
local parse_csv_line = function(csv_line)
    local cells = {}
    local current_cell_data = nil

    for idx = 1, #csv_line do
        local char = csv_line:sub(idx, idx)

        if current_cell_data == nil then
            current_cell_data = build_cell_data(idx, char)
        else
            local err = parse_new_char(current_cell_data, idx, char)
            if err ~= nil then
                return {}, "Error parsing CSV line '" .. csv_line .. "': " .. err
            end
        end

        if current_cell_data.end_pos ~= nil then
            table.insert(cells, extract_text_from_cell_data(current_cell_data, csv_line))
            current_cell_data = nil
        end
    end

    if current_cell_data ~= nil then
        local err = process_end_of_line(current_cell_data, #csv_line)
        if err ~= nil then
            return {}, "Failed to parse line '" .. csv_line .. "': " .. err
        end

        if current_cell_data.end_pos ~= nil then
            table.insert(cells, extract_text_from_cell_data(current_cell_data, csv_line))
        else
            return {}, "Unexpected end of CSV line '" .. csv_line .. "'"
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
---  - `lines` (table): The structured input data, in the form of a table whose elements
---     represent a line. Each line is itself a table where each element is a cell.
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

    return M.from_structured_data(lines)
end

---Creates a new formatted table object.
---
---@param lines table The structured data from which to create the formatted table.
---       This table should contain rows, where each row is itself a table containing multiple values.
---       All rows should contain the same number of elements.
---@return table FormattedTable A table with the following fields:
---  - `lines` (table): The input structure data
---  - `columns_width` (table): The width of each column of the table.
---  - `text` (table): The formatted text of the table, in the form of a table of textual lines.
function M.from_structured_data(lines)
    -- First, we need to detect the width of each column
    -- so that all rows for a given column are written over
    -- the same number of characters, without truncating any
    -- data.
    local cols_width = {}
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

-- TODO get column under cursor

return M

