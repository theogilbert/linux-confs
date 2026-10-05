-- A definition that moved inside the file.
--
-- Neither backend knows what a move is. difftastic aligns the two trees
-- in order, and `vim.diff` aligns lines in order, so a function taken
-- from the bottom of a file to the top comes back as a removal in one
-- place and an addition in another: the whole body in red where it
-- was, the whole body in green where it is, and whatever changed inside
-- it left for the reader to find by comparing the two by eye -- forty
-- rows apart, which is the comparison a diff exists to do for them.
--
-- So the backend's answer is read again here. A tree-sitter node that
-- lies wholly inside the rows one side removed, paired with one wholly
-- inside the rows the other side added -- by name first, by content
-- where there is no name to go by -- is a move. Its old copy is taken
-- out of the answer and one line is drawn where it was; its new copy is
-- compared against its OLD SELF (`inner`, the same backend over just
-- the two nodes), and that comparison is spliced in where the addition
-- was. What the reader sees at the new place is then an ordinary edit
-- of a function, plus a line saying where it came from.
--
-- Which of two swapped definitions "moved" is the backend's choice and
-- is left with it: it matched one of them in place, and only the other
-- arrives here as a removal and an addition.
--
-- The rewritten answer is for drawing only (`result.drawn`). The hunks
-- the list counts, the read marks, and the side-by-side window all go
-- on reading the backend's own -- git sees a removal and an addition,
-- and the chunks a reader marks read are git's.

local config = require("uatis.config")

local M = {}

local function blank(s)
  return s == nil or not s:match("%S")
end

--- Rows (1-based) a hunk list covers on side `a` or `b`.
local function covered(hunks, side)
  local set = {}
  for _, h in ipairs(hunks) do
    local start, count = h["start_" .. side], h["count_" .. side]
    for r = start, start + count - 1 do
      set[r] = true
    end
  end
  return set
end

--- What a definition is called, where the tree says: its own `name`
--- field, or that of the definition it wraps (a decorator, an `export`),
--- or the target of an assignment (`M.foo = function`). nil where none
--- of those is there; content then has to carry the match on its own.
local function name_of(node, src)
  local function text(n)
    return vim.treesitter.get_node_text(n, src):gsub("%s+", " ")
  end
  local n = node:field("name")[1]
  if n then
    return text(n)
  end
  for _, f in ipairs({ "definition", "declaration" }) do
    local d = node:field(f)[1]
    if d and d:field("name")[1] then
      return text(d:field("name")[1])
    end
  end
  for child in node:iter_children() do
    if child:named() and child:type():match("declarator") and child:field("name")[1] then
      return text(child:field("name")[1])
    end
  end
  if node:type():match("assignment") then
    local lhs = node:named_child(0)
    if lhs and lhs:start() == node:start() then
      local first = lhs:named_child(0) or lhs
      return text(first)
    end
  end
  return nil
end

--- The nodes of `text` lying wholly inside `rows` (1-based set): whole
--- lines, `min_lines` or more, and the outermost such -- a class that
--- went, not each of its methods. Methods are found when the class
--- stayed, which is what descending into a node that is NOT wholly
--- inside is for.
local function candidates(text, lines, lang, rows)
  local ok, parser = pcall(vim.treesitter.get_string_parser, text, lang)
  if not ok or not parser then
    return {}
  end
  local ok2, trees = pcall(parser.parse, parser, true)
  if not ok2 or not trees or not trees[1] then
    return {}
  end
  local min = config.diff.move.min_lines
  local out = {}
  local function inside(first, last)
    for r = first, last do
      if not rows[r] and not blank(lines[r]) then
        return false
      end
    end
    return true
  end
  local function touches(first, last)
    for r = first, last do
      if rows[r] then
        return true
      end
    end
    return false
  end
  local function visit(node, top)
    local sr, sc, er, ec = node:range()
    if ec == 0 and er > sr then
      er = er - 1
      ec = #(lines[er + 1] or "")
    end
    local first, last = sr + 1, er + 1
    if not touches(first, last) then
      return
    end
    local line = lines[first] or ""
    local whole = sc == (line:find("%S") or 1) - 1
      and not (lines[last] or ""):sub(ec + 1):match("%S")
    if node:named() and whole and last - first + 1 >= min and inside(first, last) then
      local name = name_of(node, text)
      -- A node with no name below the top level is a body, an argument
      -- list, a table -- the inside of something that stayed, which a
      -- similar inside elsewhere says nothing about.
      if name or top then
        table.insert(out, { first = first, last = last, name = name, kind = node:type() })
        return
      end
    end
    for child in node:iter_children() do
      if child:named() then
        visit(child, false)
      end
    end
  end
  for child in trees[1]:root():iter_children() do
    if child:named() then
      visit(child, true)
    end
  end
  return out
end

--- How alike two blocks of lines are, 0..1: the share of lines a line
--- diff matches, indentation left out -- a method lifted out of a class
--- is the same code one level further left.
local function likeness(a, b)
  local function strip(ls)
    local out = {}
    for _, l in ipairs(ls) do
      table.insert(out, (l:gsub("^%s+", "")))
    end
    return table.concat(out, "\n") .. "\n"
  end
  local hunks = vim.diff(strip(a), strip(b), { result_type = "indices", algorithm = "histogram" })
  local changed = 0
  for _, h in ipairs(hunks) do
    changed = changed + h[2]
  end
  return 2 * (#a - changed) / (#a + #b)
end

local function slice(lines, first, last)
  return vim.list_slice(lines, first, last)
end

--- The new row the backend hangs old row `r` above: its own alignment
--- where it has one, else the top of the hunk that removed it.
local function hangs_at(result, r)
  if result.anchor and result.anchor[r] then
    return result.anchor[r]
  end
  for _, h in ipairs(result.hunks) do
    if h.count_a > 0 and r >= h.start_a and r < h.start_a + h.count_a then
      return h.count_b == 0 and h.start_b + 1 or h.start_b
    end
  end
  return r
end

--- The moves in `result`, or nil. Each is
---   { name, old = { first, last }, new = { first, last }, at }
--- 1-based rows; `at` is the new row the old copy would have hung above.
function M.find(result, old_text, new_text, lang)
  local opts = config.diff.move
  if not opts.enabled or not lang or not result.hunks or #result.hunks == 0 then
    return nil
  end
  local old_lines = vim.split(old_text, "\n", { plain = true })
  local new_lines = vim.split(new_text, "\n", { plain = true })
  local gone, came = covered(result.hunks, "a"), covered(result.hunks, "b")
  if next(gone) == nil or next(came) == nil then
    return nil
  end
  local olds = candidates(old_text, old_lines, lang, gone)
  if #olds == 0 then
    return nil
  end
  local news = candidates(new_text, new_lines, lang, came)
  if #news == 0 then
    return nil
  end

  -- Not a move where the new copy sits where the old one was: that is a
  -- definition rewritten in place, which the backend had right. Between
  -- the two there has to be something that stayed.
  local function moved(at, n)
    local lo, hi
    if at < n.first then
      lo, hi = at, n.first - 1
    elseif at > n.last + 1 then
      lo, hi = n.last + 1, at - 1
    else
      return false
    end
    for r = lo, hi do
      if not came[r] and not blank(new_lines[r]) then
        return true
      end
    end
    return false
  end

  local scored = {}
  for i, o in ipairs(olds) do
    local at = hangs_at(result, o.first)
    for j, n in ipairs(news) do
      if o.kind == n.kind and moved(at, n) then
        local sim = likeness(slice(old_lines, o.first, o.last), slice(new_lines, n.first, n.last))
        local named = o.name ~= nil and o.name == n.name
        if (named and sim >= opts.named_similarity) or sim >= opts.similarity then
          table.insert(scored, { i = i, j = j, at = at, score = (named and 1 or 0) + sim })
        end
      end
    end
  end
  table.sort(scored, function(x, y) return x.score > y.score end)
  local out, taken_i, taken_j = {}, {}, {}
  for _, s in ipairs(scored) do
    if not taken_i[s.i] and not taken_j[s.j] then
      taken_i[s.i], taken_j[s.j] = true, true
      local o, n = olds[s.i], news[s.j]
      table.insert(out, {
        name = n.name or o.name,
        old = { first = o.first, last = o.last },
        new = { first = n.first, last = n.last },
        at = s.at,
      })
    end
  end
  table.sort(out, function(x, y) return x.new.first < y.new.first end)
  return #out > 0 and out or nil
end

--- `range` widened over the blank rows either side of it that the same
--- side's hunks also took: the separators that went with the definition
--- and would otherwise be drawn as two removed blank lines beside the
--- line saying where it went.
local function with_blanks(range, lines, rows)
  local first, last = range.first, range.last
  while rows[first - 1] and blank(lines[first - 1]) do
    first = first - 1
  end
  while rows[last + 1] and blank(lines[last + 1]) do
    last = last + 1
  end
  return first, last
end

--- Contiguous runs of `start..start+count-1` not in `drop`.
local function runs(start, count, drop)
  local out, cur = {}, nil
  for r = start, start + count - 1 do
    if drop[r] then
      cur = nil
    elseif cur then
      cur.count = cur.count + 1
    else
      cur = { first = r, count = 1 }
      table.insert(out, cur)
    end
  end
  return out
end

--- The backend's hunks with the rows in `drop_a`/`drop_b` taken out.
local function carve(hunks, drop_a, drop_b)
  local out = {}
  for _, h in ipairs(hunks) do
    local ra, rb = runs(h.start_a, h.count_a, drop_a), runs(h.start_b, h.count_b, drop_b)
    local na, nb = 0, 0
    for _, r in ipairs(ra) do na = na + r.count end
    for _, r in ipairs(rb) do nb = nb + r.count end
    -- Where a side with nothing left on it stands: the row after which,
    -- as `vim.diff` anchors a one-sided hunk.
    local edge_a = h.count_a > 0 and h.start_a - 1 or h.start_a
    local edge_b = h.count_b > 0 and h.start_b - 1 or h.start_b
    if na == h.count_a and nb == h.count_b then
      table.insert(out, h)
    elseif #ra <= 1 and #rb <= 1 then
      if #ra + #rb > 0 then
        table.insert(out, {
          start_a = ra[1] and ra[1].first or edge_a, count_a = na,
          start_b = rb[1] and rb[1].first or edge_b, count_b = nb,
        })
      end
    else
      for _, r in ipairs(ra) do
        table.insert(out, { start_a = r.first, count_a = r.count, start_b = edge_b, count_b = 0 })
      end
      for _, r in ipairs(rb) do
        table.insert(out, { start_a = edge_a, count_a = 0, start_b = r.first, count_b = r.count })
      end
    end
  end
  return out
end

--- The answer to draw: `result` with each move's two copies taken out
--- and its inner comparison (`inners[k]`, the backend over just the two
--- nodes) spliced in at the new copy. `moves` gains `changes`, the
--- number of places the definition was edited.
function M.rewrite(result, moves, inners, old_text, new_text)
  local old_lines = vim.split(old_text, "\n", { plain = true })
  local new_lines = vim.split(new_text, "\n", { plain = true })
  local gone, came = covered(result.hunks, "a"), covered(result.hunks, "b")
  local drop_a, drop_b = {}, {}
  for _, mv in ipairs(moves) do
    local a1, a2 = with_blanks(mv.old, old_lines, gone)
    local b1, b2 = with_blanks(mv.new, new_lines, came)
    for r = a1, a2 do drop_a[r] = true end
    for r = b1, b2 do drop_b[r] = true end
  end

  local hunks = carve(result.hunks, drop_a, drop_b)
  local spans = {}
  for _, s in ipairs(result.spans or {}) do
    if not (s.kind == "add" and drop_b[s.line]) and not (s.kind == "delete" and drop_a[s.line]) then
      table.insert(spans, s)
    end
  end
  local pairs_of, anchor_of
  if result.pairs then
    pairs_of, anchor_of = {}, {}
    for b, a in pairs(result.pairs) do
      if not drop_b[b] and not drop_a[a] then
        pairs_of[b] = a
      end
    end
    for a, b in pairs(result.anchor or {}) do
      if not drop_a[a] then
        anchor_of[a] = b
      end
    end
  end

  for k, mv in ipairs(moves) do
    local inner = inners[k]
    local da, db = mv.old.first - 1, mv.new.first - 1
    mv.changes = #(inner.hunks or {})
    -- Kept for the side-by-side window, which lines the two copies up
    -- row for row while the cursor is inside one of them.
    mv.inner = { hunks = inner.hunks or {}, pairs = inner.pairs, anchor = inner.anchor }
    for _, h in ipairs(inner.hunks or {}) do
      table.insert(hunks, {
        start_a = h.start_a + da, count_a = h.count_a,
        start_b = h.start_b + db, count_b = h.count_b,
      })
    end
    for _, s in ipairs(inner.spans or {}) do
      table.insert(spans, vim.tbl_extend("force", s, { line = s.line + (s.kind == "delete" and da or db) }))
    end
    if pairs_of then
      -- Every row of the two copies, paired: the inner answer's own
      -- pairing where it has one, and between its hunks the rows it
      -- matched one to one -- which is all `vim.diff` can say and all an
      -- `unchanged` difftastic answer says.
      local a, b = 1, 1
      local n_a, n_b = mv.old.last - mv.old.first + 1, mv.new.last - mv.new.first + 1
      local function step(to_a, to_b)
        while a < to_a and b < to_b do
          pairs_of[b + db], anchor_of[a + da] = a + da, b + db
          a, b = a + 1, b + 1
        end
      end
      for _, h in ipairs(inner.hunks or {}) do
        local ha = h.count_a > 0 and h.start_a or h.start_a + 1
        local hb = h.count_b > 0 and h.start_b or h.start_b + 1
        step(ha, hb)
        for r = ha, ha + h.count_a - 1 do
          anchor_of[r + da] = (h.count_b > 0 and hb or hb) + db
        end
        a, b = ha + h.count_a, hb + h.count_b
      end
      step(n_a + 1, n_b + 1)
      for nb, na in pairs(inner.pairs or {}) do
        pairs_of[nb + db] = na + da
      end
      for na, nb in pairs(inner.anchor or {}) do
        anchor_of[na + da] = nb + db
      end
    end
  end

  table.sort(hunks, function(x, y)
    if x.start_b ~= y.start_b then
      return x.start_b < y.start_b
    end
    return x.start_a < y.start_a
  end)
  return vim.tbl_extend("force", result, {
    hunks = hunks, spans = spans, pairs = pairs_of, anchor = anchor_of,
    moves = moves, drawn = false,
  })
end

return M
