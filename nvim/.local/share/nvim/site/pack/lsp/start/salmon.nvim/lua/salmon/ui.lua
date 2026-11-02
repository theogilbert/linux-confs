-- Side pane rendering the provenance tree.
local trace = require("salmon.trace")

local M = {}
local ns = vim.api.nvim_create_namespace("salmon")
local ns_pos = vim.api.nvim_create_namespace("salmon_positions")

local state = { buf = nil, win = nil, origin_win = nil, root = nil, lines = {} }
M.state = state

local LEGEND = {
  SYM = "symbol being traced",
  DEF = "defined here (end of chain)",
  CND = "conditionally assigned (inside a branch/loop)",
  ALS = "alias: assigned from another variable",
  DRV = "derived from an expression (derive mode)",
  UPD = "update: new value computed from its own previous value (x = x.f(), x += 1)",
  MUT = "mutated in place (x[k] = v, x.a = v, x.m(...) as a statement)",
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

local function visible(root)
  local out = {}
  local function walk(n, depth)
    out[#out + 1] = { node = n, depth = depth }
    if n.expanded and n.children then
      for _, c in ipairs(n.children) do
        walk(c, depth + 1)
      end
    end
  end
  walk(root, 0)
  return out
end

--- Render the tree as plain lines (+ highlight spans). Pure; used by tests.
function M.render_lines(root)
  local lines, hls, map = {}, {}, {}
  for i, item in ipairs(visible(root)) do
    local n = item.node
    local icon = n.loading and "…" or (n.resolve or n.children) and (n.expanded and "▾" or "▸") or "·"
    local prefix = string.rep("  ", item.depth) .. icon .. " "
    local parts, spans = { prefix }, {}
    local col = #prefix
    for i, t in ipairs(n.tags) do
      local sep = i > 1 and " " or ""
      spans[#spans + 1] = { col + #sep, col + #sep + #t, "Salmon" .. t }
      parts[#parts + 1] = sep .. t
      col = col + #sep + #t
    end
    local text = n.text
    if #text > config().max_text then
      text = text:sub(1, config().max_text - 1) .. "…"
    end
    parts[#parts + 1] = " " .. text
    col = col + 1 + #text
    local fname = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(n.buf), ":t")
    local loc = ("  %s:%d"):format(fname, n.row + 1)
    if n.note then
      loc = loc .. "  (" .. n.note .. ")"
    end
    spans[#spans + 1] = { col, col + #loc, "SalmonLocation" }
    parts[#parts + 1] = loc
    lines[i] = table.concat(parts)
    hls[i] = spans
    map[i] = n
  end
  return lines, hls, map
end

local function cursor_node()
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
    return nil
  end
  return state.lines[vim.api.nvim_win_get_cursor(state.win)[1]]
end

function M.render()
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf) and state.root) then
    return
  end
  local current = cursor_node()
  local lines, hls, map = M.render_lines(state.root)
  state.lines = map
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  for i, spans in ipairs(hls) do
    for _, s in ipairs(spans) do
      vim.api.nvim_buf_set_extmark(state.buf, ns, i - 1, s[1], { end_col = s[2], hl_group = s[3] })
    end
  end
  if current and state.win and vim.api.nvim_win_is_valid(state.win) then
    for i, n in ipairs(map) do
      if n == current then
        vim.api.nvim_win_set_cursor(state.win, { i, 0 })
        break
      end
    end
  end
  M.update_positions()
end

-- Source-side highlights: the traced symbol's line (dim background) and the
-- node selected in the pane.
local marked = {}
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

function M.update_positions()
  clear_positions()
  local root = state.root
  if not (root and M.is_open()) then
    return
  end
  mark(root, { line_hl_group = "SalmonOrigin", priority = 100 })
  for _, occ in ipairs(state.symbol or {}) do
    mark(occ, { hl_group = "SalmonSymbol", priority = 150 })
  end
  local sel = cursor_node()
  if sel then
    mark(sel, { hl_group = "SalmonSelected", priority = 200 })
  end
end

-- Every occurrence of the traced variable in its buffer, origin included.
local function load_symbol(root)
  local ts, lsp = require("salmon.ts"), require("salmon.lsp")
  state.symbol = {}
  lsp.highlights(root.buf, root.row, root.col, function(hl)
    if state.root ~= root then
      return
    end
    local nodes = {}
    if hl then
      for _, h in ipairs(hl) do
        nodes[#nodes + 1] = ts.node_at(root.buf, h.row, h.col)
      end
    else
      local occ = ts.node_at(root.buf, root.row, root.col)
      nodes = occ and ts.same_name_occurrences(root.buf, occ) or {}
    end
    for _, n in ipairs(nodes) do
      local row, col = n:start()
      local end_row, end_col = n:end_()
      state.symbol[#state.symbol + 1] = { buf = root.buf, row = row, col = col, end_row = end_row, end_col = end_col }
    end
    M.update_positions()
  end)
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
  vim.api.nvim_win_set_buf(win, node.buf)
  vim.api.nvim_win_set_cursor(win, { node.row + 1, node.col })
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! zv")
  end)
  if not keep_focus then
    vim.api.nvim_set_current_win(win)
  end
end

--- Move the pane selection by `delta` rows and show that node in the source
--- window. Stepping down onto a collapsed node expands it first, so repeated
--- `]s` swims upstream through the chain.
function M.step(delta)
  if not M.is_open() or #state.lines == 0 then
    return
  end
  local cur = vim.api.nvim_get_current_win()
  if cur ~= state.win then
    state.origin_win = cur
  end
  local row = vim.api.nvim_win_get_cursor(state.win)[1]
  local node = state.lines[row]
  local function move()
    local target = math.max(1, math.min(#state.lines, row + delta))
    vim.api.nvim_win_set_cursor(state.win, { target, 0 })
    jump(state.lines[target], true)
  end
  if delta > 0 and node and node.resolve and not node.expanded then
    trace.expand(node, 0, M.render, move)
  else
    move()
  end
end

-- `]s`/`[s` are global while the pane is open; previous mappings restored.
local saved_maps = {}
local function set_global_maps()
  if state.global_maps then
    return
  end
  state.global_maps = true
  local km = config().keymaps
  for _, spec in ipairs({ { km.next, 1 }, { km.prev, -1 } }) do
    for _, k in ipairs(spec[1]) do
      local prev = vim.fn.maparg(k, "n", false, true)
      saved_maps[k] = (prev.lhs and prev.buffer == 0) and prev or false
      vim.keymap.set("n", k, function()
        M.step(spec[2])
      end, { desc = "salmon: step along the chain" })
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
  elseif node.parent then
    for i, n in ipairs(state.lines) do
      if n == node.parent then
        vim.api.nvim_win_set_cursor(state.win, { i, 0 })
      end
    end
  end
end

-- Fold-style tree manipulation ---------------------------------------------

local function row_of(node)
  for i, n in ipairs(state.lines) do
    if n == node then
      return i
    end
  end
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
  for _, n in ipairs(state.lines) do
    if expandable(n) and not n.expanded then
      best = math.min(best or math.huge, depth(n))
    end
  end
  for _, n in ipairs(vim.list_extend({}, state.lines)) do
    if best and expandable(n) and not n.expanded and depth(n) == best then
      trace.expand(n, 0, M.render)
    end
  end
end

-- zm: close every expanded node at the deepest expanded depth (root stays).
local function zm()
  local best = 0
  for _, n in ipairs(state.lines) do
    if n.expanded and n ~= state.root and n.children and #n.children > 0 then
      best = math.max(best, depth(n))
    end
  end
  if best == 0 then
    return
  end
  local cur = cursor_node()
  for _, n in ipairs(state.lines) do
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
  local i = row + dir
  while state.lines[i] do
    if expandable(state.lines[i]) then
      return vim.api.nvim_win_set_cursor(state.win, { i, 0 })
    end
    i = i + dir
  end
end

-- [z / ]z: start / end of the fold the cursor is in.
local function fold_start(node)
  local f = node.parent
  goto_node(f)
end

local function fold_end(node)
  local f = node.parent
  if not f then
    return
  end
  local last = f.children[#f.children]
  while last.expanded and last.children and #last.children > 0 do
    last = last.children[#last.children]
  end
  goto_node(last)
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
    local cls = n and ts.classify(n, true)
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
  local msg = { "salmon: ]s/[s step along chain  K hover  z* folds  <CR> jump  p preview  o/<Tab>/l expand  h collapse  R re-root  d derive  r refresh  q close", "" }
  for _, t in ipairs({ "SYM", "DEF", "CND", "ALS", "DRV", "UPD", "MUT", "PRM", "ARG", "FOR", "IMP", "SRC", "FN", "RET" }) do
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
  wo.signcolumn = "no"
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
  if origin_win then
    state.origin_win = origin_win
  end
  ensure_buf()
  ensure_win()
  vim.api.nvim_set_current_win(state.win)
  M.render()
  vim.api.nvim_win_set_cursor(state.win, { 1, 0 })
  set_global_maps()
  load_symbol(root)
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
