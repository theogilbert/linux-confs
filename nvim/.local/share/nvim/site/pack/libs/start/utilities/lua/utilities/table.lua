local M = {}

M.COL_SEPARATOR = '│'

local center = function(text, width)
    local rough_whitespace_count = (width - vim.api.nvim_strwidth(text)) / 2
    local before_len = math.floor(rough_whitespace_count)
    local after_len = math.ceil(rough_whitespace_count)
    return string.rep(' ', before_len) .. text .. string.rep(' ', after_len)
end

--- @class CellState
--- @field start_pos integer The position at which the cell starts.
--- @field end_pos integer The position at which the cell ends.
--- @field quoted boolean Whether the current cell is in quote or not.
--- @field pending_quote boolean If true, indicates that the last parsed
--- character was a quote. If the next character is also a quote,
--- then both quotes represent an escaped quote `"` charater within a
--- quoted cell. Otherwise, it means that the quoted cell ends here.


--- @return CellState state The state of the cell we are starting to read.
--- cell being parsed character by character.
local function new_cell_state(start_idx, start_char)
    local end_pos = nil
    if start_char == ',' then
        end_pos = start_idx - 1
    end

    return {
        start_pos = start_idx,
        quoted = start_char == '"',
        pending_quote = false,
        end_pos = end_pos,
    }
end

--- @class ParserState
--- @field text string A full copy of the CSV text.
--- @field cur_cell CellState|nil The state of the currently parsed cell.
--- @field cur_line string[] The current line being parsed.
--- @field lines string[][] Lines which have already been completely parsed.
--- nil if the first line is not complete.
--- @field add_empty_cell function Add a new empty cell to the line currently being parsed.
--- @field complete_cell function Reads the text from the current cell and merge it to the current line.
--- @field complete_line function Complete the current cell, and merge the current line to the list of parsed lines.



--- @param parser_state ParserState the current state of the parser.
--- @param idx integer The position of the parsed character in the document.
--- @param char string The new character to parse.
--- @return string|nil err An error message if something went wrong.
local function parse_new_char(parser_state, idx, char)
    local cell = parser_state.cur_cell
    local err = nil

    if cell == nil then
        if char == ',' then
            parser_state.add_empty_cell()
        elseif char == '\n' then
            err = parser_state.complete_line(idx - 1)
        else
            parser_state.cur_cell = new_cell_state(idx, char)
        end
    else
        if char == '"' then
            if cell.quoted then
                cell.pending_quote = not cell.pending_quote
            else
                return "Lone quote character found in unquoted cell at position " .. vim.inspect(idx)
            end
        elseif (cell.pending_quote or not cell.quoted) and (char == ',' or char == '\n') then
            -- A pending quote followed by `,` or `\n` means an end of quoted cell.
            if char == '\n' then
                err = parser_state.complete_line(idx - 1)
            else
                err = parser_state.complete_cell(idx - 1)
            end
        end
    end

    return err
end


--- @param cell_state CellState|nil The state of the cell whose text to read.
--- @param csv_content string The full string of the CSV content.
local function read_cell_text(cell_state, csv_content)
    if cell_state == nil then
        return ""
    end

    local cell = csv_content:sub(cell_state.start_pos, cell_state.end_pos)

    if cell_state.quoted then
        local trimmed = cell:sub(2, #cell - 1)
        cell = trimmed:gsub('""', '"')
    end

    return cell
end


--- Create an empty parser state, ready to parse a new document.
--- @param csv_content string A full copy of the CSV text.
--- @return ParserState state A newly initialized parser state.
local function new_parser_state(csv_content)
    local parser = {
        text = csv_content,
        cur_cell = nil,
        cur_line = {},
        lines = {}
    }

    parser.add_empty_cell = function()
        table.insert(parser.cur_line, "")
    end

    parser.complete_cell = function(idx)
        --- @type CellState|nil
        local cell = parser.cur_cell

        if cell ~= nil then
            if cell.quoted and not cell.pending_quote then
                return "Unclosed quoted cell at index " .. vim.inspect(idx)
            end

            cell.end_pos = idx
        end

        local cell_text = read_cell_text(cell, csv_content)
        cell_text = string.gsub(cell_text, "\n", "<LF>")
        table.insert(parser.cur_line, cell_text)

        parser.cur_cell = nil
        return nil
    end

    parser.complete_line = function(idx)
        if #parser.cur_line == 0 and parser.cur_cell == nil then
            -- Empty line - we ignore it.
            return nil
        end

        local err = parser.complete_cell(idx)

        table.insert(parser.lines, parser.cur_line)
        parser.cur_line = {}

        return err
    end

    return parser
end


--- Extract columns from a CSV line
---
--- @param csv_content string The full CSV text
--- @return table lines The list of lines extracted from the CSV content.
---   In case of a failure to parse the CSV line, the table will be empty.
--- @return string|nil err An error message if the CSV line could not be parsed.
---   Nil otherwise.
local parse_csv_content = function(csv_content)
    csv_content = string.gsub(csv_content, "\r\n", "\n")
    local parser_state = new_parser_state(csv_content)

    for idx = 1, #csv_content do
        local char = csv_content:sub(idx, idx)

        local err = parse_new_char(parser_state, idx, char)
        if err ~= nil then
            return {}, "Error parsing CSV content at position " .. idx .. ": " .. err
        end
    end

    local err = parser_state.complete_line()


    return parser_state.lines, err
end

local update_cols_widths = function(columns, cols_width)
    for col_num, col in ipairs(columns) do
        cols_width[col_num] = math.max(cols_width[col_num] or 2, vim.api.nvim_strwidth(col) + 2)
    end

    return cols_width
end

local function build_header_separator_line(cols_width)
    local line = "├"
    for col_num, col_width in ipairs(cols_width) do
        local col_sep = col_num < #cols_width and "┼" or ""
        line = line .. string.rep("─", col_width) .. col_sep
    end
    return line .. "┤"
end


---Creates a new formatted table object.
---
---@param csv_text string A textual CSV content, using comma (`,`) as separator.
---@param header_lines integer|nil How many lines should be considered part of the header.
---Defaults to 1.
---@return table FormattedTable A table with the following fields:
---  - `lines` (table): The structured input data, in the form of a table whose elements
---     represent a line. Each line is itself a table where each element is a cell.
---  - `columns_width` (table): The width of each column of the table.
---  - `text` (table): The formatted text of the table, in the form of a table of textual lines.
---@return string|nil err: Error message if parsing failed, or nil on success.
function M.from_csv(csv_text, header_lines)
    local lines, err = parse_csv_content(csv_text)
    if err ~= nil then
        return {}, err
    end

    return M.from_structured_data(lines, header_lines)
end

---Creates a new formatted table object.
---
---@param lines table The structured data from which to create the formatted table.
---       This table should contain rows, where each row is itself a table containing multiple values.
---       All rows should contain the same number of elements.
---@param header_lines integer|nil How many lines should be considered part of the header.
---Defaults to 1.
---@return table FormattedTable A table with the following fields:
---  - `lines` (table): The input structure data
---  - `columns_width` (table): The width of each column of the table.
---  - `text` (table): The formatted text of the table, in the form of a table of textual lines.
function M.from_structured_data(lines, header_lines)
    header_lines = header_lines ~= nil and header_lines or 1
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

        local formatted_line = M.COL_SEPARATOR .. table.concat(centered_cells, M.COL_SEPARATOR) .. M.COL_SEPARATOR
        table.insert(formatted_lines, formatted_line)
    end

    if header_lines > 0 and header_lines <= #formatted_lines then
        local separator = build_header_separator_line(cols_width)
        table.insert(formatted_lines, header_lines + 1, separator)
    end

    return {
        lines = lines,
        columns_width = cols_width,
        text = formatted_lines
    }
end

--- Returns the 1-indexed column number at a given virtual (display) column position.
--- @param cols_width table The width of each column (from FormattedTable.columns_width)
--- @param virtual_col integer The 1-indexed display column of the cursor
--- @return integer|nil col_idx The 1-indexed column index, or nil if the cursor is on a separator
function M.get_column_at_cursor(cols_width, virtual_col)
    local pos = 2 -- first content position (after leading │)
    for i, width in ipairs(cols_width) do
        if virtual_col >= pos and virtual_col < pos + width then
            return i
        end
        pos = pos + width + 1 -- skip content + │ separator
    end
    return nil
end

return M

