-- Delimited text into records: CSV as RFC 4180 has it, and its cousins
-- (TSV, `;` from a spreadsheet set to a comma-decimal locale, `|`).
--
-- Read from the lines of a buffer rather than from one string, since a
-- buffer is what there is, and every record knows the line it starts
-- on -- a reader drawing the table has to put the cursor back on the
-- file's line. A quoted field may run over several lines; its record
-- then starts on the first of them.

local M = {}

--- The records of `lines`, each `{ cells = { ... }, row = n }`, `row`
--- the 1-based line the record starts on. A line with nothing on it
--- (outside a quoted field) is no record. A trailing `\r` is dropped,
--- so a file written on Windows reads the same.
---
--- `opts.sep` -- the delimiter, "," by default: one character.
function M.parse(lines, opts)
  opts = opts or {}
  local sep = opts.sep or ","
  local records = {}
  local cells, field, quoted, start = nil, {}, false, nil

  local function finish_field()
    table.insert(cells, table.concat(field))
    field = {}
  end

  local function read(n, line)
    if not quoted then
      cells, start = {}, n
    else
      -- A quoted field running over the end of the line keeps the line
      -- break as part of its value.
      table.insert(field, "\n")
    end
    local i, len = 1, #line
    while i <= len do
      local c = line:sub(i, i)
      if quoted then
        if c == '"' then
          if line:sub(i + 1, i + 1) == '"' then
            table.insert(field, '"')
            i = i + 1
          else
            quoted = false
          end
        else
          table.insert(field, c)
        end
      elseif c == '"' and #field == 0 then
        quoted = true
      elseif c == sep then
        finish_field()
      else
        table.insert(field, c)
      end
      i = i + 1
    end
    if not quoted then
      finish_field()
      table.insert(records, { cells = cells, row = start })
    end
  end

  for n, line in ipairs(lines) do
    if line:sub(-1) == "\r" then
      line = line:sub(1, -2)
    end
    if quoted or line ~= "" then
      read(n, line)
    end
  end
  -- A quote never closed: what there was of the field, rather than the
  -- last record lost.
  if quoted then
    finish_field()
    table.insert(records, { cells = cells, row = start })
  end
  return records
end

local CANDIDATES = { ",", "\t", ";", "|" }

--- The delimiter `lines` were most likely written with, out of `,`,
--- tab, `;` and `|`: the one that splits the first lines into the same
--- number of fields, the most fields winning a tie. "," where none
--- splits anything.
function M.sniff(lines, sample)
  local head = vim.list_slice(lines, 1, sample or 20)
  local best, best_score = ",", 0
  for _, sep in ipairs(CANDIDATES) do
    local recs = M.parse(head, { sep = sep })
    if #recs > 0 then
      local n = #recs[1].cells
      local same = 0
      for _, r in ipairs(recs) do
        if #r.cells == n then
          same = same + 1
        end
      end
      -- Agreement first, width second: a `,` in every line of prose
      -- separated by tabs splits it, but not into equal parts.
      local score = n > 1 and (same / #recs) * 1000 + n or 0
      if score > best_score then
        best, best_score = sep, score
      end
    end
  end
  return best
end

return M
