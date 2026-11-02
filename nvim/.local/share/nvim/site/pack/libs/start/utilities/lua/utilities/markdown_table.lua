local M = {}

--- Split a markdown table row into trimmed cells.
--- Outer pipes are optional, escaped pipes (`\|`) stay within their cell.
--- @param line string
--- @return string[]
local function split_row(line)
    local row = vim.trim(line)
    row = row:gsub("^|", "")
    if row:match("[^\\]|$") or row == "|" then
        row = row:sub(1, -2)
    end

    local cells, start = {}, 1
    local i = 1
    while i <= #row do
        local char = row:sub(i, i)
        if char == "\\" then
            i = i + 1 -- skip the escaped character
        elseif char == "|" then
            table.insert(cells, vim.trim(row:sub(start, i - 1)))
            start = i + 1
        end
        i = i + 1
    end
    table.insert(cells, vim.trim(row:sub(start)))
    return cells
end

--- @param cells string[]
--- @return boolean
local function is_separator(cells)
    for _, cell in ipairs(cells) do
        if not cell:match("^:?%-+:?$") then
            return false
        end
    end
    return true
end

--- @param cell string A separator cell, e.g. `:---:`
--- @return "left"|"right"|"center"|nil
local function alignment(cell)
    local left, right = cell:sub(1, 1) == ":", cell:sub(-1) == ":"
    if left and right then
        return "center"
    elseif right then
        return "right"
    elseif left then
        return "left"
    end
end

--- @param text string
--- @param width integer
--- @param align "left"|"right"|"center"|nil
--- @return string
local function pad(text, width, align)
    local missing = width - vim.api.nvim_strwidth(text)
    if align == "right" then
        return string.rep(" ", missing) .. text
    elseif align == "center" then
        local before = math.floor(missing / 2)
        return string.rep(" ", before) .. text .. string.rep(" ", missing - before)
    end
    return text .. string.rep(" ", missing)
end

--- @param width integer
--- @param align "left"|"right"|"center"|nil
--- @return string
local function separator_cell(width, align)
    if align == "center" then
        return ":" .. string.rep("-", width - 2) .. ":"
    elseif align == "right" then
        return string.rep("-", width - 1) .. ":"
    elseif align == "left" then
        return ":" .. string.rep("-", width - 1)
    end
    return string.rep("-", width)
end

--- Align the columns of a markdown table.
--- Column alignments (`:--`, `--:`, `:-:`) found in the separator row are honored.
--- @param lines string[] The rows of the table
--- @return string[] lines The aligned rows, indented as the first one
function M.format(lines)
    local indent = lines[1] and lines[1]:match("^%s*") or ""
    local rows, aligns, widths, ncols = {}, {}, {}, 0

    for _, line in ipairs(lines) do
        local cells = split_row(line)
        local sep = is_separator(cells)
        table.insert(rows, { cells = cells, separator = sep })
        ncols = math.max(ncols, #cells)
        if sep then
            for col, cell in ipairs(cells) do
                aligns[col] = alignment(cell)
            end
        end
    end

    for col = 1, ncols do
        -- 3 is the shortest separator cell holding alignment colons (`:-:`)
        widths[col] = 3
        for _, row in ipairs(rows) do
            if not row.separator and row.cells[col] then
                widths[col] = math.max(widths[col], vim.api.nvim_strwidth(row.cells[col]))
            end
        end
    end

    local formatted = {}
    for _, row in ipairs(rows) do
        local cells = {}
        for col = 1, ncols do
            if row.separator then
                cells[col] = separator_cell(widths[col], aligns[col])
            else
                cells[col] = pad(row.cells[col] or "", widths[col], aligns[col])
            end
        end
        table.insert(formatted, indent .. "| " .. table.concat(cells, " | ") .. " |")
    end
    return formatted
end

--- Format the lines `first` to `last` (1-indexed, inclusive) of the current buffer.
--- @param first integer
--- @param last integer
function M.format_range(first, last)
    local lines = vim.api.nvim_buf_get_lines(0, first - 1, last, false)
    local formatted = M.format(lines)
    if not vim.deep_equal(lines, formatted) then
        vim.api.nvim_buf_set_lines(0, first - 1, last, false, formatted)
    end
end

--- Format the table under the cursor: the contiguous lines containing a `|`.
function M.format_at_cursor()
    local is_row = function(lnum) return vim.fn.getline(lnum):find("|", 1, true) ~= nil end
    local cur = vim.fn.line(".")
    if not is_row(cur) then
        vim.notify("No markdown table under the cursor", vim.log.levels.WARN)
        return
    end

    local first, last = cur, cur
    while first > 1 and is_row(first - 1) do first = first - 1 end
    while last < vim.fn.line("$") and is_row(last + 1) do last = last + 1 end
    M.format_range(first, last)
end

--- Find the tables among `lines`: runs of lines containing a `|` whose second
--- line is a separator row, outside of fenced code blocks.
--- @param lines string[]
--- @return {first: integer, last: integer}[] tables Line ranges, indexed in `lines`
function M.find_tables(lines)
    local tables = {}
    local fence = nil
    local i = 1
    while i <= #lines do
        local line = lines[i]
        local marker = line:match("^%s*(```+)") or line:match("^%s*(~~~+)")
        if fence then
            if marker and marker:sub(1, 1) == fence:sub(1, 1) and #marker >= #fence then
                fence = nil
            end
            i = i + 1
        elseif marker then
            fence = marker
            i = i + 1
        elseif line:find("|", 1, true) then
            local last = i
            while lines[last + 1] and lines[last + 1]:find("|", 1, true) do
                last = last + 1
            end
            if last > i and is_separator(split_row(lines[i + 1])) then
                table.insert(tables, { first = i, last = last })
            end
            i = last + 1
        else
            i = i + 1
        end
    end
    return tables
end

--- Format every table of the current buffer overlapping lines `first` to
--- `last` (1-indexed, inclusive). Tables are formatted as a whole, even when
--- they only partly overlap.
--- @param first integer
--- @param last integer
function M.format_tables(first, last)
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    -- Bottom-up, so that line numbers of the remaining tables stay valid
    local tables = M.find_tables(lines)
    for t = #tables, 1, -1 do
        local tbl = tables[t]
        if tbl.last >= first and tbl.first <= last then
            M.format_range(tbl.first, tbl.last)
        end
    end
end

--- 'operatorfunc' for `=` in markdown buffers, formatting the tables in range.
--- Native `=` is not run: markdown has no 'indentexpr', so it would fall back
--- to C-indenting, which flattens nested lists.
function M.equal_operator()
    M.format_tables(vim.fn.line("'["), vim.fn.line("']"))
end

--- Format the visually selected lines.
function M.format_selection()
    local first, last = vim.fn.line("v"), vim.fn.line(".")
    if first > last then first, last = last, first end
    M.format_range(first, last)
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "n", false)
end

return M
