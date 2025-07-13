local M = {}

local center = function(text, width)
    local rough_whitespace_count = (width - #text) / 2
    local before_len = math.floor(rough_whitespace_count)
    local after_len = math.ceil(rough_whitespace_count)
    return string.rep(' ', before_len) .. text .. string.rep(' ', after_len)
end

local parse_columns = function(csv_line)
    local cells = {}
    local bounding_quotes_count = 0 -- number of quotes used as a cell bound, when escaping commas
    local current_quotes_count = 0 -- counter used to detect end of bounding quotes
    local current_cell_start = nil

    for idx = 1, #csv_line do
        local char = csv_line:sub(idx, idx)

        if current_cell_start == nil then
            if char == '"' then
                bounding_quotes_count = bounding_quotes_count + 1
            elseif char == ',' and bounding_quotes_count == 0 then
                -- Special case: the cell is 0 characters long (e.g. the line ",,,")
                table.insert(cells, '')
            else
                current_cell_start = idx
            end
        else
            if char == ',' and current_quotes_count == bounding_quotes_count then
                local cell = csv_line:sub(current_cell_start, idx - 1)
                table.insert(cells, cell)
                current_cell_start = nil
                bounding_quotes_count = 0
            elseif char == '"' then
                current_quotes_count = current_quotes_count + 1
            elseif current_quotes_count > 0 then
                -- We are still in the cell, but not on a quote character
                -- We'll need to start counting current_quotes again
                current_quotes_count = 0
            end
        end
    end

    return cells
end

local update_cols_widths = function(columns, cols_width)
    for col_num, col in ipairs(columns) do
        if cols_width[col_num] == nil then
            cols_width[col_num] = 0
        end

        cols_width[col_num] = math.max(cols_width[col_num], #col)
    end

    return cols_width
end

-- @param csv_text string
-- @return string: a formatted, column-aligned CSV text
function M.format_csv(csv_text)
    local lines = {}
    local cols_width = {}

    for line in csv_text:gmatch("[^\n]+") do
        local cols = parse_columns(line)
        table.insert(lines, cols)
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

        local formatted_line = '| ' .. table.concat(centered_cells, ' | ') .. ' |\n'
        table.insert(formatted_lines, formatted_line)
    end

    return formatted_lines
end

return M
