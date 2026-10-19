-- Minimal RFC 4180 CSV parser for the output of pandas' `to_csv()`.
--
-- Quoted cells keep their embedded newlines and commas verbatim: the table
-- formatter escapes control characters for display, and the row detail float
-- shows the real value.
local M = {}

--- Parse CSV text into rows of cell strings. Empty lines are skipped.
--- @param text string
--- @return string[][] rows
--- @return string|nil err
function M.parse(text)
	text = text:gsub("\r\n", "\n")
	local rows, row, cell = {}, {}, {}
	local quoted, i, n = false, 1, #text
	-- Whether the current line holds anything yet, so an empty line is skipped.
	local started = false

	local function end_cell()
		row[#row + 1] = table.concat(cell)
		cell = {}
	end
	local function end_row()
		if started then
			end_cell()
			rows[#rows + 1] = row
		end
		row, cell, started = {}, {}, false
	end

	while i <= n do
		local c = text:sub(i, i)
		if quoted then
			if c == '"' then
				if text:sub(i + 1, i + 1) == '"' then
					cell[#cell + 1] = '"'
					i = i + 1
				else
					quoted = false
				end
			else
				cell[#cell + 1] = c
			end
		elseif c == '"' then
			if #cell > 0 then
				return {}, "Lone quote character found in unquoted cell at position " .. i
			end
			quoted, started = true, true
		elseif c == "," then
			started = true
			end_cell()
		elseif c == "\n" then
			end_row()
		else
			started = true
			cell[#cell + 1] = c
		end
		i = i + 1
	end

	if quoted then
		return {}, "Unclosed quoted cell at end of input"
	end
	end_row()
	return rows, nil
end

return M
