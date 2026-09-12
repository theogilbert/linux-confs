-- A structural diff of a file too changed for difftastic to take whole.
--
-- difftastic bounds its own work: past `DFT_GRAPH_LIMIT` it puts the
-- parser down and compares words, which on a `.py` file rewritten since
-- the tag is the one file the reader most wanted read as Python. The
-- limit is about the file as a whole -- the class alone, three hundred
-- lines against six hundred, comes back as Python in a tenth of a
-- second; the file it sits in, with its imports changed above it, gives
-- up after three. So the file is cut where the tree says one thing ends
-- and the next begins, and difftastic is asked about each piece.
--
-- Where to cut is tree-sitter's answer, not a guess at column zero: a
-- class docstring holds markdown at column zero and a cut there lands
-- inside a string. Every piece is the top-level nodes -- a class, a
-- function, an import block -- that the line diff's hunks fall inside,
-- and the two sides are then brought back into step through the line
-- diff's own matching, so the rows between two pieces are rows it
-- matched one to one. Those rows are the stitches: aligned as pairs,
-- with nothing on them.
--
-- Only ever as a rescue, after difftastic has given up on the whole:
-- pieces are blind to a function moved from one to another, which the
-- whole-file answer reads as a move, and a file that fits under the
-- limit gets the better answer. A file that needed cutting once is cut
-- first the next time, since the three seconds difftastic spends
-- deciding are three seconds per keystroke while it is being edited.
--
-- A piece with nothing on one side is not sent: difftastic answers
-- `created`/`deleted` with no rows to align, and every row of the side
-- that exists is new, which is said here directly.

local M = {}

--- Top-level units of `text` in `lang` -- the root's children, as
--- 0-based inclusive row ranges, sorted. nil without a parser.
function M.units(text, lang)
  local ok, parser = pcall(vim.treesitter.get_string_parser, text, lang)
  if not ok or not parser then
    return nil
  end
  local ok2, trees = pcall(parser.parse, parser, true)
  if not ok2 or not trees or not trees[1] then
    return nil
  end
  local out = {}
  for node in trees[1]:root():iter_children() do
    local sr, _, er, ec = node:range()
    -- A node ending at column 0 of a row ends on the row before it.
    if ec == 0 and er > sr then
      er = er - 1
    end
    table.insert(out, { first = sr, last = er })
  end
  return out
end

local function unit_at(units, row)
  for _, u in ipairs(units) do
    if u.first <= row and row <= u.last then
      return u
    end
    if u.first > row then
      break
    end
  end
  return nil
end

--- The pieces to cut `old`/`new` into, from the line diff's `hunks`
--- (1-based, as `line_hunks` gives them) and the two sides' units.
--- Each is `{ lo_a, hi_a, lo_b, hi_b }`, 0-based inclusive, `hi < lo`
--- for a side with nothing in it.
---
--- A piece is widened to the units its rows fall in, and then the two
--- sides are brought back into step: the rows outside a hunk are
--- matched one to one by the line diff, so where the new side took in
--- four rows of context above and the old side two, the old side
--- takes in the partners of the other two as well. Without that the
--- rows between two pieces -- which are sewn as pairs -- would not be
--- pairs.
function M.pieces(hunks, units_a, units_b, n_a, n_b)
  -- The line diff's matching, row to row, outside its hunks.
  local to_b, from_b = {}, {}
  do
    local a, b = 0, 0
    for _, h in ipairs(hunks) do
      local ha = h.count_a > 0 and h.start_a - 1 or h.start_a
      local hb = h.count_b > 0 and h.start_b - 1 or h.start_b
      while a < ha and b < hb do
        to_b[a], from_b[b] = b, a
        a, b = a + 1, b + 1
      end
      a, b = ha + h.count_a, hb + h.count_b
    end
    while a < n_a and b < n_b do
      to_b[a], from_b[b] = b, a
      a, b = a + 1, b + 1
    end
  end

  local out = {}
  for _, h in ipairs(hunks) do
    local lo_a = h.count_a > 0 and h.start_a - 1 or h.start_a
    local hi_a = lo_a + h.count_a - 1
    local lo_b = h.count_b > 0 and h.start_b - 1 or h.start_b
    local hi_b = lo_b + h.count_b - 1
    table.insert(out, { lo_a = lo_a, hi_a = hi_a, lo_b = lo_b, hi_b = hi_b })
  end

  local function widen(p)
    local was = { p.lo_a, p.hi_a, p.lo_b, p.hi_b }
    if p.hi_a >= p.lo_a then
      local u = unit_at(units_a, p.lo_a)
      if u then p.lo_a = math.min(p.lo_a, u.first) end
      u = unit_at(units_a, p.hi_a)
      if u then p.hi_a = math.max(p.hi_a, u.last) end
    end
    if p.hi_b >= p.lo_b then
      local u = unit_at(units_b, p.lo_b)
      if u then p.lo_b = math.min(p.lo_b, u.first) end
      u = unit_at(units_b, p.hi_b)
      if u then p.hi_b = math.max(p.hi_b, u.last) end
    end
    -- Back into step, through the matching. A row inside another hunk
    -- has no partner; the piece will fold into that hunk's below.
    local moved = true
    while moved do
      moved = false
      local b = to_b[p.lo_a]
      if b and b < p.lo_b then p.lo_b, moved = b, true end
      local a = from_b[p.lo_b]
      if a and a < p.lo_a then p.lo_a, moved = a, true end
      b = to_b[p.hi_a]
      if b and b > p.hi_b then p.hi_b, moved = b, true end
      a = from_b[p.hi_b]
      if a and a > p.hi_a then p.hi_a, moved = a, true end
    end
    return was[1] ~= p.lo_a or was[2] ~= p.hi_a or was[3] ~= p.lo_b or was[4] ~= p.hi_b
  end
  local function fold()
    local merged, moved = {}, false
    for _, p in ipairs(out) do
      local last = merged[#merged]
      if last and (p.lo_a <= last.hi_a + 1 or p.lo_b <= last.hi_b + 1) then
        last.hi_a = math.max(last.hi_a, p.hi_a)
        last.hi_b = math.max(last.hi_b, p.hi_b)
        moved = true
      else
        table.insert(merged, p)
      end
    end
    out = merged
    return moved
  end
  local guard = 0
  repeat
    local moved = false
    for _, p in ipairs(out) do
      if widen(p) then
        moved = true
      end
    end
    if fold() then
      moved = true
    end
    guard = guard + 1
  until not moved or guard > 64
  return out
end

--- Every row of one side, as difftastic would have reported a file
--- created or deleted: a chunk entry per row with the whole row changed.
local function one_sided(lines, lo, hi, side)
  local entries = {}
  for row = lo, hi do
    local line = lines[row + 1] or ""
    table.insert(entries, { [side] = {
      line_number = row,
      changes = { { start = 0, ["end"] = #line, content = line, highlight = "normal" } },
    } })
  end
  return entries
end

--- Sews the pieces' answers into one difftastic answer for the file:
--- `chunks` and `aligned_lines` offset to file rows, and the rows between
--- pieces paired as the unchanged rows they are.
function M.stitch(pieces, old_lines, new_lines)
  local aligned, chunks = {}, {}
  local oa, ob = 0, 0
  for _, p in ipairs(pieces) do
    while oa < p.lo_a or ob < p.lo_b do
      table.insert(aligned, { oa < p.lo_a and oa or nil, ob < p.lo_b and ob or nil })
      oa = math.min(oa + 1, p.lo_a)
      ob = math.min(ob + 1, p.lo_b)
    end
    local d = p.data
    if p.hi_a < p.lo_a then
      for row = p.lo_b, p.hi_b do
        table.insert(aligned, { nil, row })
      end
      table.insert(chunks, one_sided(new_lines, p.lo_b, p.hi_b, "rhs"))
    elseif p.hi_b < p.lo_b then
      for row = p.lo_a, p.hi_a do
        table.insert(aligned, { row, nil })
      end
      table.insert(chunks, one_sided(old_lines, p.lo_a, p.hi_a, "lhs"))
    elseif d and d.aligned_lines then
      for _, pair in ipairs(d.aligned_lines) do
        table.insert(aligned, {
          pair[1] ~= nil and (pair[1] + p.lo_a) or nil,
          pair[2] ~= nil and (pair[2] + p.lo_b) or nil,
        })
      end
      for _, chunk in ipairs(d.chunks or {}) do
        local moved = {}
        for _, entry in ipairs(chunk) do
          local e = {}
          if entry.lhs then
            e.lhs = vim.tbl_extend("force", entry.lhs, { line_number = entry.lhs.line_number + p.lo_a })
          end
          if entry.rhs then
            e.rhs = vim.tbl_extend("force", entry.rhs, { line_number = entry.rhs.line_number + p.lo_b })
          end
          table.insert(moved, e)
        end
        table.insert(chunks, moved)
      end
    else
      -- `unchanged`: only whitespace differs. Paired by position, the
      -- rest one-sided, nothing on any of them.
      local a, b = p.lo_a, p.lo_b
      while a <= p.hi_a or b <= p.hi_b do
        table.insert(aligned, { a <= p.hi_a and a or nil, b <= p.hi_b and b or nil })
        a, b = a + 1, b + 1
      end
    end
    oa, ob = p.hi_a + 1, p.hi_b + 1
  end
  while oa < #old_lines or ob < #new_lines do
    table.insert(aligned, { oa < #old_lines and oa or nil, ob < #new_lines and ob or nil })
    oa = math.min(oa + 1, #old_lines)
    ob = math.min(ob + 1, #new_lines)
  end
  return { status = "changed", chunks = chunks, aligned_lines = aligned }
end

return M
