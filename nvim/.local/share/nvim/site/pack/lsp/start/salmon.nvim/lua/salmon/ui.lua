-- Side pane rendering the provenance tree.
local trace = require("salmon.trace")

local M = {}
local ns = vim.api.nvim_create_namespace("salmon")
local ns_pos = vim.api.nvim_create_namespace("salmon_positions")

local state = { buf = nil, win = nil, origin_win = nil, root = nil, lines = {}, rows = {} }
M.state = state

local LEGEND = {
  SYM = "symbol being traced",
  DEF = "defined here (end of chain)",
  CND = "conditionally assigned (inside a branch/loop)",
  ALS = "alias: assigned from another variable",
  DRV = "derived from an expression (derive mode)",
  UPD = "update: new value computed from its own previous value (x = x.f(), x += 1)",
  MUT = "mutated in place (x[k] = v, x.a = v, x.m(...) as a statement)",
  RD = "read on the way (passed to a function, used in an expression)",
  PRM = "function parameter",
  ARG = "argument passed at a call site",
  FOR = "loop variable",
  IMP = "imported",
  SRC = "variable an expression depends on",
  FN = "function an expression calls",
  RET = "return statement of that function",
}

local function config()
  return require("salmon").config
end

-- What each step means, in words, shown above it in the chain.
local SAYS = {
  SYM = "traced",
  DEF = "defined",
  ALS = "copied from another variable",
  DRV = "computed from an expression",
  UPD = "updated from its previous value",
  MUT = "mutated in place",
  RD = "read",
  PRM = "function parameter",
  ARG = "passed as argument",
  FOR = "loop variable",
  IMP = "imported",
  SRC = "uses variable",
  FN = "calls function",
  RET = "returned",
}

local function is_cond(n)
  return n.tags[1] == "CND"
end

local function main_tag(n)
  return n.tags[#n.tags]
end

local function has_upstream(n)
  return n.expanded and n.children ~= nil and #n.children > 0
end

-- A line is a list of { text, hl } segments plus the node it belongs to;
-- `step` marks the node's own line (as opposed to its label or graph lines).
local function says_line(n, ch)
  local words = n.passed and "passed to a function" or SAYS[main_tag(n)] or main_tag(n)
  local segs = { { ch .. " ", "SalmonGraph" } }
  if is_cond(n) then
    segs[#segs + 1] = { "maybe ", "SalmonCND" }
    segs[#segs + 1] = { words, "Salmon" .. main_tag(n) }
    segs[#segs + 1] = { " (in a branch)", "SalmonCND" }
  else
    segs[#segs + 1] = { words, "Salmon" .. main_tag(n) }
  end
  return { node = n, segs = segs }
end

local function step_line(n, is_root)
  -- Markers are junctions the line runs through, so the chain stays one
  -- uninterrupted line.
  local icons = config().icons
  local marker
  if n.loading then
    marker = icons.loading
  elseif is_root then
    marker = icons.traced
  elseif has_upstream(n) then
    marker = icons.expanded
  elseif not n.expanded and (n.resolve or n.children) then
    marker = icons.collapsed
  else
    marker = icons.done
  end
  local text = n.text
  if #text > config().max_text then
    text = text:sub(1, config().max_text - 1) .. "…"
  end
  local fname = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(n.buf), ":t")
  local loc = ("%s:%d"):format(fname, n.row + 1)
  if n.note then
    loc = loc .. "  (" .. n.note .. ")"
  end
  return {
    node = n,
    step = true,
    segs = { { marker .. " ", "Salmon" .. main_tag(n) }, { text, nil } },
    loc = loc,
  }
end

-- Shift lines one column right (the main line keeps running on the left)
-- and join them back into it.
local function side(lines)
  local out = {}
  for _, l in ipairs(lines) do
    local segs = { { "│ ", "SalmonGraph" } }
    vim.list_extend(segs, l.segs)
    out[#out + 1] = { node = l.node, step = l.step, segs = segs, loc = l.loc }
  end
  out[#out + 1] = { node = lines[#lines].node, segs = { { "├─╯", "SalmonGraph" } } }
  return out
end

local block

-- Everything that feeds into `n`, drawn above it in its own column. The
-- first child continues the main line; a timeline (successive versions of
-- one variable) stays on it, while parallel inputs and the inputs of later
-- versions branch off and merge back in.
local function upstream(n)
  local out = {}
  if not has_upstream(n) then
    return out
  end
  local cs = n.children
  vim.list_extend(out, block(cs[1], true))
  if n.seq then
    for i = 2, #cs do
      local c = cs[i]
      local up = upstream(c)
      if #up > 0 then
        vim.list_extend(out, side(up))
      end
      out[#out + 1] = says_line(c, "│")
      out[#out + 1] = step_line(c)
    end
  else
    -- Parallel inputs are in priority order: the first continues the main
    -- line, the next ones branch off closest to `n`.
    for i = #cs, 2, -1 do
      vim.list_extend(out, side(block(cs[i], true)))
    end
  end
  return out
end

block = function(n, top, is_root)
  local out = upstream(n)
  local ch = (top and #out == 0 and not is_root) and "╷" or "│"
  out[#out + 1] = says_line(n, ch)
  out[#out + 1] = step_line(n, is_root)
  return out
end

--- Render the chain as plain lines (+ highlight spans). The earliest point
--- is at the top, the traced symbol at the bottom. Pure; used by tests.
---@return string[] lines, table[] spans, salmon.Node[] line_to_node, table<salmon.Node, integer> node_to_row
function M.render_lines(root)
  local lines, hls, map, rows = {}, {}, {}, {}
  local all = block(root, true, true)
  -- Line the file:line locations up in one column.
  local width = 0
  for _, l in ipairs(all) do
    if l.loc then
      local w = 0
      for _, seg in ipairs(l.segs) do
        w = w + vim.fn.strdisplaywidth(seg[1])
      end
      l.width = w
      width = math.max(width, w)
    end
  end
  for _, l in ipairs(all) do
    if l.loc then
      l.segs[#l.segs + 1] = { string.rep(" ", width - l.width + 2) .. l.loc, "SalmonLocation" }
    end
  end
  for i, l in ipairs(all) do
    local parts, spans, col = {}, {}, 0
    for _, seg in ipairs(l.segs) do
      parts[#parts + 1] = seg[1]
      if seg[2] then
        spans[#spans + 1] = { col, col + #seg[1], seg[2] }
      end
      col = col + #seg[1]
    end
    lines[i], hls[i], map[i] = table.concat(parts), spans, l.node
    if l.step then
      rows[l.node] = i
    end
  end
  return lines, hls, map, rows
end

local function cursor_node()
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
    return nil
  end
  return state.lines[vim.api.nvim_win_get_cursor(state.win)[1]]
end

--- Nodes in display order (top to bottom), each once.
local function shown_nodes()
  local out = {}
  for i, n in ipairs(state.lines) do
    if state.rows[n] == i then
      out[#out + 1] = n
    end
  end
  return out
end

function M.render()
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf) and state.root) then
    return
  end
  local current = cursor_node()
  local lines, hls, map, rows = M.render_lines(state.root)
  state.lines, state.rows = map, rows
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  for i, spans in ipairs(hls) do
    for _, s in ipairs(spans) do
      vim.api.nvim_buf_set_extmark(state.buf, ns, i - 1, s[1], { end_col = s[2], hl_group = s[3] })
    end
  end
  if current and rows[current] and state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_set_cursor(state.win, { rows[current], 0 })
  end
  M.update_positions()
end

-- Source-side highlights: the traced symbol's line (dim background) and the
-- node selected in the pane.
local marked = {}
-- Above the LSP's own reference highlights (`vim.hl.priorities.user`), which
-- would otherwise paint their background over the traced symbol while the
-- cursor sits on it.
local PRIO = vim.hl.priorities.user
local function clear_positions()
  for buf in pairs(marked) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, ns_pos, 0, -1)
    end
  end
  marked = {}
end

local function mark(node, opts)
  if not vim.api.nvim_buf_is_valid(node.buf) then
    return
  end
  opts.end_row, opts.end_col = node.end_row, node.end_col
  pcall(vim.api.nvim_buf_set_extmark, node.buf, ns_pos, node.row, node.col, opts)
  marked[node.buf] = true
end

-- The flow is a graph where each step feeds exactly one later step (its
-- successor) but may be fed by several (its predecessors). A path is chosen
-- by its top step; it then runs down through successors to the traced symbol.

local function index_in(list, x)
  for i, v in ipairs(list) do
    if v == x then
      return i
    end
  end
end

--- Steps that feed into `n`, main line first: the previous version of the
--- variable (timeline), then the inputs drawn above it. A timeline parent is
--- fed by its last version only.
function M.predecessors(n)
  local out = {}
  local p = n.parent
  if p and p.seq then
    local i = index_in(p.children, n)
    if i and i > 1 then
      out[#out + 1] = p.children[i - 1]
    end
  end
  if has_upstream(n) then
    if n.seq then
      out[#out + 1] = n.children[#n.children]
    else
      vim.list_extend(out, n.children)
    end
  end
  return out
end

--- Follow the main line up from `n` to the top of the chain.
function M.extend_up(n)
  local pred = M.predecessors(n)[1]
  while pred do
    n = pred
    pred = M.predecessors(n)[1]
  end
  return n
end

--- Every top step whose path runs through `n`, main line first.
function M.tops(n)
  local out = {}
  local function go(x)
    local preds = M.predecessors(x)
    if #preds == 0 then
      out[#out + 1] = x
    end
    for _, p in ipairs(preds) do
      go(p)
    end
  end
  go(n)
  return out
end

--- The flow from `node` down to the traced symbol: the node, the later
--- versions of the same variable (timeline siblings), then where that flows
--- into, and so on. Without a node, starts at the top of the main chain.
function M.flow_path(root, node)
  if not node or node == root then
    node = M.extend_up(root)
  end
  local path, n = { node }, node
  while n.parent do
    local p = n.parent
    if p.seq then
      local after = false
      for _, c in ipairs(p.children) do
        if after then
          path[#path + 1] = c
        end
        after = after or c == n
      end
    end
    path[#path + 1] = p
    n = p
  end
  return path
end

--- The path shown in the gutter, top first. It is kept while the selection
--- stays on it; selecting a step off it switches to the main line through
--- that step. A top that gained upstream (expanded) is followed further up.
function M.current_path()
  local root = state.root
  local sel = cursor_node() or root
  local top = state.top
  if not (top and (top == root or state.rows[top])) then
    top = M.extend_up(sel)
  end
  local path = M.flow_path(root, top)
  if not index_in(path, sel) then
    top = M.extend_up(sel)
  elseif #M.predecessors(top) > 0 then
    top = M.extend_up(top)
  end
  if top ~= path[1] then
    path = M.flow_path(root, top)
  end
  state.top = top
  return path
end

-- Gutter: number each step of the flow and draw lines between consecutive
-- steps in the same buffer; the heavy half of the last segment (╽/╿) points
-- at the destination. Where the flow leaves for another file, the line turns
-- off to the left below the step (─╯); where it arrives from one, it comes in
-- from the left above the step (─╮). Lines run in the right cell, numbers are
-- right-aligned onto them.
local GLYPH = { ud = "│", ul = "╯", dl = "╮", udl = "┤", u = "│", d = "│", l = "─" }

local function draw_flow(path)
  local nums, cells = {}, {} -- buf -> row -> text / { u, d, l, heavy }
  -- Several steps can sit on one line (`count += offset` reads `offset` and
  -- updates `count`): show the first one, with a `+` for the others.
  local first, more = {}, {}
  for i, n in ipairs(path) do
    local key = n.buf .. ":" .. n.row
    if first[key] then
      more[key] = true
    else
      first[key] = i
    end
  end
  for i, n in ipairs(path) do
    local key = n.buf .. ":" .. n.row
    if first[key] == i and vim.api.nvim_buf_is_valid(n.buf) then
      local text = i > 99 and "··" or tostring(i)
      if #text < 2 then
        text = (more[key] and "+" or " ") .. text
      end
      nums[n.buf] = nums[n.buf] or {}
      nums[n.buf][n.row] = text
    end
  end
  local function cell(buf, row)
    cells[buf] = cells[buf] or {}
    cells[buf][row] = cells[buf][row] or {}
    return cells[buf][row]
  end
  -- A row next to `n` for a line to/from another file: `prefer` (+1 below,
  -- -1 above) unless that is off the buffer or holds a step number.
  local function beside(n, prefer)
    local count = vim.api.nvim_buf_line_count(n.buf)
    for _, d in ipairs({ prefer, -prefer }) do
      local r = n.row + d
      if r >= 0 and r < count and not (nums[n.buf] and nums[n.buf][r]) then
        return r, d
      end
    end
  end
  for i, n in ipairs(path) do
    local nxt = path[i + 1]
    if nxt and vim.api.nvim_buf_is_valid(n.buf) and vim.api.nvim_buf_is_valid(nxt.buf) then
      if nxt.buf == n.buf then
        if nxt.row ~= n.row then
          local dir = nxt.row > n.row and 1 or -1
          for r = n.row + dir, nxt.row - dir, dir do
            local c = cell(n.buf, r)
            c.u, c.d = true, true
            if r == nxt.row - dir then
              c.heavy = dir > 0 and "╽" or "╿"
            end
          end
        end
      else
        local r, d = beside(n, 1)
        if r then
          local c = cell(n.buf, r)
          c.l = true
          if d > 0 then c.u = true else c.d = true end
        end
        r, d = beside(nxt, -1)
        if r then
          local c = cell(nxt.buf, r)
          c.l = true
          if d < 0 then c.d = true else c.u = true end
        end
      end
    end
  end
  local function put(buf, row, text, hl)
    pcall(vim.api.nvim_buf_set_extmark, buf, ns_pos, row, 0, { sign_text = text, sign_hl_group = hl, priority = 100 })
    marked[buf] = true
  end
  for buf, rows in pairs(cells) do
    for row, c in pairs(rows) do
      if not (nums[buf] and nums[buf][row]) then
        local key = (c.u and "u" or "") .. (c.d and "d" or "") .. (c.l and "l" or "")
        local g = (key == "ud" and c.heavy) or GLYPH[key]
        put(buf, row, (c.l and "─" or " ") .. g, "SalmonFlow")
      end
    end
  end
  for buf, rows in pairs(nums) do
    for row, text in pairs(rows) do
      put(buf, row, text, "SalmonFlowStep")
    end
  end
end

local function number_pane(path)
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
    return
  end
  vim.api.nvim_buf_clear_namespace(state.buf, ns_pos, 0, -1)
  -- Dim the steps off the active path (other paths), so it stands out.
  local on = {}
  for _, n in ipairs(path) do
    on[n] = true
  end
  for i, n in ipairs(state.lines) do
    if not on[n] then
      local len = #(vim.api.nvim_buf_get_lines(state.buf, i - 1, i, false)[1] or "")
      vim.api.nvim_buf_set_extmark(state.buf, ns_pos, i - 1, 0,
        { end_col = len, hl_group = "SalmonOffPath", priority = 5000 })
    end
  end
  for i, n in ipairs(path) do
    local row = state.rows[n]
    if row then
      vim.api.nvim_buf_set_extmark(state.buf, ns_pos, row - 1, 0, {
        sign_text = i > 99 and "··" or tostring(i),
        sign_hl_group = "SalmonFlowStep",
      })
    end
  end
end

local load_occurrences

function M.update_positions()
  clear_positions()
  local root = state.root
  if not (root and M.is_open()) then
    return
  end
  -- Not `line_hl_group`: that is painted over every other highlight on the
  -- line and would hide the symbol highlights below.
  if vim.api.nvim_buf_is_valid(root.buf) then
    pcall(vim.api.nvim_buf_set_extmark, root.buf, ns_pos, root.row, 0,
      { end_row = root.row + 1, end_col = 0, hl_eol = true, hl_group = "SalmonOrigin", priority = 100 })
    marked[root.buf] = true
  end
  for _, occ in ipairs(load_occurrences(root)) do
    mark(occ, { hl_group = "SalmonSymbol", priority = PRIO + 10 })
  end
  mark(root, { hl_group = "SalmonSymbolOrigin", priority = PRIO + 20 })
  local sel = cursor_node()
  -- In another file, the variable followed there stands in for the traced
  -- symbol: highlight its occurrences the same way.
  if sel and sel.buf ~= root.buf and vim.api.nvim_buf_is_loaded(sel.buf) then
    for _, occ in ipairs(load_occurrences(sel)) do
      mark(occ, { hl_group = "SalmonSymbol", priority = PRIO + 10 })
    end
  end
  -- Inside a derivation source's upstream, that source's variable is the one
  -- being followed: highlight its occurrences too.
  local src = sel
  while src and src ~= root and main_tag(src) ~= "SRC" do
    src = src.parent
  end
  if src and src ~= root then
    for _, occ in ipairs(load_occurrences(src)) do
      mark(occ, { hl_group = "SalmonSource", priority = PRIO + 5 })
    end
  end
  local path = M.current_path()
  draw_flow(path)
  number_pane(path)
  if sel and sel ~= root then
    mark(sel, { hl_group = "SalmonSelected", priority = PRIO + 30 })
  end
end

-- Every occurrence of the variable at `node` in its buffer, cached on the
-- node as `occ`; `M.update_positions` runs once they are known.
load_occurrences = function(node)
  if node.occ then
    return node.occ
  end
  local ts, lsp = require("salmon.ts"), require("salmon.lsp")
  node.occ = {}
  lsp.highlights(node.buf, node.row, node.col, function(hl)
    if not vim.api.nvim_buf_is_valid(node.buf) then
      return
    end
    local nodes = {}
    if hl then
      for _, h in ipairs(hl) do
        nodes[#nodes + 1] = ts.node_at(node.buf, h.row, h.col)
      end
    else
      local occ = ts.node_at(node.buf, node.row, node.col)
      nodes = occ and ts.same_name_occurrences(node.buf, occ) or {}
    end
    for _, n in ipairs(nodes) do
      local row, col = n:start()
      local end_row, end_col = n:end_()
      node.occ[#node.occ + 1] = { buf = node.buf, row = row, col = col, end_row = end_row, end_col = end_col }
    end
    if state.root then
      M.update_positions()
    end
  end)
  return node.occ
end

local function target_win()
  if state.origin_win and vim.api.nvim_win_is_valid(state.origin_win) then
    return state.origin_win
  end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if w ~= state.win then
      return w
    end
  end
end

local function jump(node, keep_focus)
  local win = target_win()
  if not win then
    return
  end
  vim.bo[node.buf].buflisted = true
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! m'")
  end)
  local other_file = vim.api.nvim_win_get_buf(win) ~= node.buf
  vim.api.nvim_win_set_buf(win, node.buf)
  vim.api.nvim_win_set_cursor(win, { node.row + 1, node.col })
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! zv")
    -- Center when landing in another file or near the top/bottom edge, so
    -- the step is shown with its context.
    local height = vim.api.nvim_win_get_height(win)
    -- 'scrolloff' keeps the cursor that far from the edge: count it as edge.
    local margin = math.max(1, math.floor(height / 5), vim.wo[win].scrolloff + 1)
    local line = vim.fn.winline()
    if other_file or line <= margin or line > height - margin then
      vim.cmd("normal! zz")
    end
  end)
  -- The step's buffer may only be loaded now: draw its highlights.
  M.update_positions()
  if not keep_focus then
    vim.api.nvim_set_current_win(win)
  end
end

--- Move the selection by `delta` steps along the path shown in the gutter
--- and show that step in the source window. Negative goes back up the path
--- (`[s`), towards the definition; a collapsed step is expanded first, so
--- repeated `[s` swims all the way upstream. Positive goes forward (`]s`),
--- towards the traced symbol.
function M.step(delta)
  if not M.is_open() or #state.lines == 0 then
    return
  end
  local cur = vim.api.nvim_get_current_win()
  if cur ~= state.win then
    state.origin_win = cur
  end
  local node = cursor_node() or state.root
  local function move()
    local path = M.current_path()
    local idx = index_in(path, node) or #path
    local target = path[math.max(1, math.min(#path, idx + delta))]
    if not state.rows[target] then
      return
    end
    vim.api.nvim_win_set_cursor(state.win, { state.rows[target], 0 })
    jump(target, true)
  end
  -- Expanding a step in the middle of the path keeps the path (its inputs
  -- become other paths for `]r`); expanding the top extends it upwards.
  if delta < 0 and node.resolve and not node.expanded then
    trace.expand(node, 0, M.render, move)
  else
    move()
  end
end

--- Switch the gutter path to the next (`delta` 1) or previous (-1) of the
--- paths leading to the selected step; `[s` then follows it.
function M.cycle_path(delta)
  if not M.is_open() or not state.root then
    return
  end
  local node = cursor_node() or state.root
  M.current_path()
  local tops = M.tops(node)
  if #tops < 2 then
    vim.api.nvim_echo({ { "salmon: only one path leads here" } }, false, {})
    return
  end
  local i = ((index_in(tops, state.top) or 1) - 1 + delta) % #tops + 1
  state.top = tops[i]
  M.update_positions()
  vim.api.nvim_echo({ { ("salmon: path %d/%d"):format(i, #tops) } }, false, {})
end

-- `]s`/`[s` and `]r`/`[r` are global while the pane is open; previous
-- mappings restored.
local saved_maps = {}
local function set_global_maps()
  if state.global_maps then
    return
  end
  state.global_maps = true
  local km = config().keymaps
  local specs = {
    { km.next, M.step, 1, "salmon: step along the path" },
    { km.prev, M.step, -1, "salmon: step along the path" },
    { km.next_path or {}, M.cycle_path, 1, "salmon: next path to this step" },
    { km.prev_path or {}, M.cycle_path, -1, "salmon: previous path to this step" },
  }
  for _, spec in ipairs(specs) do
    for _, k in ipairs(spec[1]) do
      local prev = vim.fn.maparg(k, "n", false, true)
      saved_maps[k] = (prev.lhs and prev.buffer == 0) and prev or false
      vim.keymap.set("n", k, function()
        spec[2](spec[3])
      end, { desc = spec[4] })
    end
  end
end

local function clear_global_maps()
  if not state.global_maps then
    return
  end
  state.global_maps = false
  for k, prev in pairs(saved_maps) do
    pcall(vim.keymap.del, "n", k)
    if prev then
      vim.fn.mapset(prev)
    end
  end
  saved_maps = {}
end

local function on_closed()
  state.win = nil
  clear_positions()
  clear_global_maps()
end

local function toggle(node)
  if node.expanded then
    node.expanded = false
    M.render()
  else
    trace.expand(node, config().auto_expand, M.render)
  end
end

local function collapse_or_parent(node)
  if node.expanded then
    node.expanded = false
    M.render()
  elseif node.parent and state.rows[node.parent] then
    vim.api.nvim_win_set_cursor(state.win, { state.rows[node.parent], 0 })
  end
end

-- Fold-style tree manipulation ---------------------------------------------

local function row_of(node)
  return state.rows[node]
end

local function goto_node(node)
  local row = node and row_of(node)
  if row then
    vim.api.nvim_win_set_cursor(state.win, { row, 0 })
  end
end

local function depth(node)
  local d, p = 0, node.parent
  while p do
    d, p = d + 1, p.parent
  end
  return d
end

local function expandable(node)
  return node.resolve ~= nil or (node.children ~= nil and #node.children > 0)
end

--- Expand `node` and its descendants, `levels` deep (lazy nodes are resolved).
local function open_rec(node, levels)
  if levels <= 0 or not expandable(node) then
    return
  end
  trace.expand(node, 0, M.render, function()
    for _, c in ipairs(node.children or {}) do
      open_rec(c, levels - 1)
    end
  end)
end

local function close_rec(node)
  node.expanded = false
  for _, c in ipairs(node.children or {}) do
    close_rec(c)
  end
end

-- The "fold" the cursor is in: the node itself when expanded, else its parent.
local function fold_of(node)
  if node.expanded then
    return node
  end
  return node.parent
end

local function zo(node)
  if expandable(node) and not node.expanded then
    trace.expand(node, 0, M.render)
  end
end

local function zc(node, recursive)
  local f = fold_of(node)
  if not f or f == state.root then
    if f == state.root and recursive then
      for _, c in ipairs(f.children or {}) do
        close_rec(c)
      end
      M.render()
    end
    return
  end
  if recursive then
    close_rec(f)
  else
    f.expanded = false
  end
  M.render()
  goto_node(f)
end

local function za(node, recursive)
  if not node.expanded and expandable(node) then
    if recursive then
      open_rec(node, config().fold_depth)
    else
      zo(node)
    end
  else
    zc(node, recursive)
  end
end

local function zR()
  state.all_open = true
  open_rec(state.root, config().fold_depth)
end

local function zM()
  state.all_open = false
  for _, c in ipairs(state.root.children or {}) do
    close_rec(c)
  end
  M.render()
end

-- zr: open every visible collapsed node at the shallowest collapsed depth.
local function zr()
  local best
  local nodes = shown_nodes()
  for _, n in ipairs(nodes) do
    if expandable(n) and not n.expanded then
      best = math.min(best or math.huge, depth(n))
    end
  end
  for _, n in ipairs(nodes) do
    if best and expandable(n) and not n.expanded and depth(n) == best then
      trace.expand(n, 0, M.render)
    end
  end
end

-- zm: close every expanded node at the deepest expanded depth (root stays).
local function zm()
  local best = 0
  local nodes = shown_nodes()
  for _, n in ipairs(nodes) do
    if n.expanded and n ~= state.root and n.children and #n.children > 0 then
      best = math.max(best, depth(n))
    end
  end
  if best == 0 then
    return
  end
  local cur = cursor_node()
  for _, n in ipairs(nodes) do
    if n.expanded and depth(n) == best then
      n.expanded = false
    end
  end
  M.render()
  -- Keep the cursor on the nearest still-visible ancestor.
  while cur and not row_of(cur) do
    cur = cur.parent
  end
  goto_node(cur)
end

-- zj / zk: next / previous node that can be expanded or collapsed.
local function zj(dir)
  local row = vim.api.nvim_win_get_cursor(state.win)[1]
  local found
  for _, n in ipairs(shown_nodes()) do
    if expandable(n) and (dir > 0 and state.rows[n] > row or dir < 0 and state.rows[n] < row) then
      found = found and dir > 0 and found or n
    end
  end
  goto_node(found)
end

-- [z / ]z: start / end of the fold the cursor is in. A fold is a node and
-- everything drawn above it (its upstream), so it starts at the top of its
-- main line and ends at the node itself.
local function fold_start(node)
  local top = node.parent
  while top and has_upstream(top) do
    top = top.children[1]
  end
  goto_node(top)
end

local function fold_end(node)
  goto_node(node.parent)
end

local FOLD_KEYS = {
  zo = zo,
  zO = function(n)
    open_rec(n, config().fold_depth)
  end,
  zc = function(n)
    zc(n, false)
  end,
  zC = function(n)
    zc(n, true)
  end,
  za = function(n)
    za(n, false)
  end,
  zA = function(n)
    za(n, true)
  end,
  zv = function() end,
  zR = zR,
  zM = zM,
  zr = zr,
  zm = zm,
  zx = zM,
  zX = zM,
  zn = zR,
  zN = zM,
  zi = function()
    if state.all_open then
      zM()
    else
      zR()
    end
  end,
  zj = function()
    zj(1)
  end,
  zk = function()
    zj(-1)
  end,
  ["[z"] = fold_start,
  ["]z"] = fold_end,
}

local HOVER_MAX_LINES = 12

local function hover(node)
  local ts = require("salmon.ts")
  local md = {}
  for _, t in ipairs(node.tags) do
    md[#md + 1] = ("**%s**: %s  "):format(t, LEGEND[t] or "?")
  end
  md[#md + 1] = ""

  local fname = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(node.buf), ":~:.")
  md[#md + 1] = ("`%s:%d:%d`  "):format(fname, node.row + 1, node.col + 1)

  local crumbs, p = {}, node
  while p do
    table.insert(crumbs, 1, p.parent and table.concat(p.tags, " ") or p.text)
    p = p.parent
  end
  if #crumbs > 1 then
    md[#md + 1] = "Path: " .. table.concat(crumbs, " › ") .. "  "
  end

  local status
  if node.loading then
    status = "loading…"
  elseif node.children then
    status = ("%d %s%s"):format(#node.children, #node.children == 1 and "child" or "children",
      node.expanded and "" or " (collapsed)")
  elseif node.resolve then
    status = "not expanded yet"
  else
    status = "end of chain"
    local n = not require("salmon").config.derive and node.tags[#node.tags] == "DEF"
      and ts.node_at(node.buf, node.row, node.col)
    local cls = n and ts.classify(n, true, node.buf)
    if cls and cls.kind == "assign" and #ts.sources(cls.rhs, node.buf) > 0 then
      status = status .. " (derived: press `d` to follow derivations)"
    end
  end
  md[#md + 1] = "Upstream: " .. status .. "  "
  if node.note then
    md[#md + 1] = "Note: " .. node.note .. "  "
  end

  local tsnode = ts.node_at(node.buf, node.row, node.col)
  if tsnode then
    local stmt = ts.statement(tsnode)
    local sr, _, er = stmt:range()
    local last = math.min(er, sr + HOVER_MAX_LINES - 1)
    local src = vim.api.nvim_buf_get_lines(node.buf, sr, last + 1, false)
    if er > last then
      src[#src + 1] = "…"
    end
    local indent = math.huge
    for _, l in ipairs(src) do
      if l:match("%S") then
        indent = math.min(indent, #l:match("^%s*"))
      end
    end
    md[#md + 1] = ""
    md[#md + 1] = "```" .. vim.bo[node.buf].filetype
    for _, l in ipairs(src) do
      md[#md + 1] = l:sub(indent + 1)
    end
    md[#md + 1] = "```"
  end
  vim.lsp.util.open_floating_preview(md, "markdown", {
    border = "rounded",
    focus_id = "salmon_hover",
    max_width = 90,
  })
end

local function help()
  local msg = {
    "salmon: the value flows top to bottom; the traced symbol is at the bottom.",
    ("%s traced  %s end of chain  %s more upstream (expand)  %s expanded"):format(
      config().icons.traced, config().icons.done, config().icons.collapsed, config().icons.expanded),
    "[s/]s step back/forward  [r/]r other path  K hover  z* folds  <CR> jump  p preview  o/<Tab>/l expand  h collapse  R re-root  d derive  r refresh  q close",
    "",
  }
  for _, t in ipairs({ "SYM", "DEF", "CND", "ALS", "DRV", "UPD", "MUT", "RD", "PRM", "ARG", "FOR", "IMP", "SRC", "FN", "RET" }) do
    msg[#msg + 1] = ("%-3s  %s"):format(t, LEGEND[t])
  end
  vim.api.nvim_echo({ { table.concat(msg, "\n") } }, false, {})
end

local function map(lhs, fn)
  vim.keymap.set("n", lhs, function()
    local n = cursor_node()
    if n then
      fn(n)
    end
  end, { buffer = state.buf, nowait = true, silent = true })
end

local function ensure_buf()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    return
  end
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(state.buf, "salmon://trace")
  vim.bo[state.buf].bufhidden = "hide"
  vim.bo[state.buf].filetype = "salmon"
  vim.bo[state.buf].modifiable = false
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = state.buf,
    callback = function()
      M.update_positions()
    end,
  })
  local km = config().keymaps
  local salmon = require("salmon")
  for _, k in ipairs(km.jump) do
    map(k, function(n)
      jump(n, false)
    end)
  end
  for _, k in ipairs(km.preview) do
    map(k, function(n)
      jump(n, true)
    end)
  end
  for _, k in ipairs(km.toggle) do
    map(k, toggle)
  end
  for _, k in ipairs(km.collapse) do
    map(k, collapse_or_parent)
  end
  for _, k in ipairs(km.reroot) do
    map(k, function(n)
      salmon.trace_at(n.buf, n.row, n.col)
    end)
  end
  for _, k in ipairs(km.derive) do
    map(k, function()
      salmon.toggle_derive()
    end)
  end
  for _, k in ipairs(km.refresh) do
    map(k, function()
      salmon.refresh()
    end)
  end
  for _, k in ipairs(km.close) do
    map(k, function()
      M.close()
    end)
  end
  for _, k in ipairs(km.help) do
    map(k, help)
  end
  for _, k in ipairs(km.hover) do
    map(k, hover)
  end
  for lhs, fn in pairs(FOLD_KEYS) do
    map(lhs, fn)
  end
end

-- Close the pane when the source window it is tied to closes. If the pane
-- would be the last window left in its tab, quit it as well, like `:q` on
-- the last window would.
local source_group = vim.api.nvim_create_augroup("salmon_source", { clear = true })
vim.api.nvim_create_autocmd("WinClosed", {
  group = source_group,
  callback = function(ev)
    if tonumber(ev.match) ~= state.origin_win or not M.is_open() then
      return
    end
    vim.schedule(function()
      if not M.is_open() then
        return
      end
      local wins = vim.tbl_filter(function(w)
        return vim.api.nvim_win_get_config(w).relative == ""
      end, vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(state.win)))
      if #wins > 1 then
        return M.close()
      end
      vim.api.nvim_set_current_win(state.win)
      local ok, err = pcall(vim.cmd, "quit")
      if not ok then
        vim.notify("salmon: " .. tostring(err), vim.log.levels.WARN)
      end
    end)
  end,
})

local function ensure_win()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    return
  end
  local cfg = config()
  state.win = vim.api.nvim_open_win(state.buf, false, {
    split = cfg.position == "left" and "left" or "right",
    win = -1,
    width = cfg.width,
  })
  local wo = vim.wo[state.win]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "auto"
  wo.foldcolumn = "0"
  wo.wrap = false
  wo.list = false
  wo.spell = false
  wo.cursorline = true
  wo.winfixwidth = true
  local win = state.win
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      if state.win == win then
        on_closed()
      end
    end,
  })
end

function M.is_open()
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

function M.open(root, origin_win, focus)
  state.root = root
  state.top = nil
  if origin_win then
    state.origin_win = origin_win
  end
  ensure_buf()
  ensure_win()
  vim.api.nvim_set_current_win(state.win)
  M.render()
  vim.api.nvim_win_set_cursor(state.win, { 1, 0 })
  set_global_maps()
  load_occurrences(root)
  trace.expand(root, config().auto_expand, M.render)
  if focus == false and state.origin_win and vim.api.nvim_win_is_valid(state.origin_win) then
    vim.api.nvim_set_current_win(state.origin_win)
  end
end

function M.close()
  if M.is_open() then
    vim.api.nvim_win_close(state.win, true)
  end
  on_closed()
end

return M
