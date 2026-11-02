-- Builds the provenance tree. Nodes are expanded lazily: a node's children
-- (the points it comes from) are only computed when it is expanded.
local ts = require("salmon.ts")
local lsp = require("salmon.lsp")

local M = {}

local function config()
  return require("salmon").config
end

---@class salmon.Node
---@field tags string[]
---@field buf integer
---@field row integer
---@field col integer
---@field text string
---@field note string|nil
---@field parent salmon.Node|nil
---@field children salmon.Node[]|nil
---@field expanded boolean
---@field loading boolean
---@field resolve fun(node: salmon.Node, cb: fun(children: salmon.Node[]))|nil

local function new(tags, buf, tsnode, resolve, text)
  local row, col = tsnode:start()
  local end_row, end_col = tsnode:end_()
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  return {
    tags = tags,
    buf = buf,
    row = row,
    col = col,
    end_row = end_row,
    end_col = end_col,
    text = text or vim.trim(line),
    resolve = resolve,
    expanded = false,
    loading = false,
  }
end

local trace, expr_children, write_node

-- Children for an expression flowing into a node: a bare identifier is a
-- plain passage and is always followed; anything else is a derivation and is
-- only followed when `derive` is on.
-- `exclude`: variable whose own timeline is already shown (UPD/MUT): hide it
-- and the methods called on it.
local function wanted_sources(buf, exprs, exclude)
  return vim.tbl_filter(function(s)
    if not exclude then
      return true
    end
    if s.kind == "src" then
      return s.name ~= exclude
    end
    return s.receiver ~= exclude
  end, ts.sources(exprs, buf))
end

local function expr_resolver(buf, exprs, exclude)
  if #exprs == 1 and ts.is_identifier(exprs[1]) and ts.text(exprs[1], buf) ~= exclude then
    return function(_, cb)
      trace(buf, exprs[1], {}, cb)
    end
  end
  if config().derive and #wanted_sources(buf, exprs, exclude) > 0 then
    return function(_, cb)
      cb(expr_children(buf, exprs, exclude))
    end
  end
end

local function fn_resolver(buf, name_node)
  return function(_, cb)
    local row, col = name_node:start()
    lsp.definition(buf, row, col, function(locs)
      if #locs == 0 then
        locs = ts.find_defs(buf, ts.text(name_node, buf))
      end
      local out = {}
      for _, loc in ipairs(locs) do
        local n = ts.node_at(loc.buf, loc.row, loc.col)
        local fn = n and (ts.is_function(n) and n or (n:parent() and ts.is_function(n:parent()) and n:parent()))
        if fn then
          out[#out + 1] = new({ "DEF" }, loc.buf, n)
          local rets = ts.returns(fn)
          for _, r in ipairs(rets) do
            out[#out + 1] = new({ "RET" }, loc.buf, r.node, expr_resolver(loc.buf, r.exprs))
          end
          if #rets == 0 then
            out[#out].note = "no return"
          end
        elseif n then
          local cls = ts.classify(n, true) or { kind = "other" }
          out[#out + 1] = write_node(loc.buf, n, cls, false)
        end
      end
      cb(out)
    end)
  end
end

expr_children = function(buf, exprs, exclude)
  local out = {}
  for _, s in ipairs(wanted_sources(buf, exprs, exclude)) do
    if s.kind == "fn" then
      out[#out + 1] = new({ "FN" }, buf, s.node, fn_resolver(buf, s.node), s.name)
    else
      local node = s.node
      out[#out + 1] = new({ "SRC" }, buf, node, function(_, cb)
        trace(buf, node, {}, cb)
      end, s.name)
    end
  end
  return out
end

local function callers_resolver(buf, cls)
  return function(_, cb)
    local name = cls.fn:field("name")[1]
    if name and vim.tbl_contains({ "__init__", "constructor", "new" }, ts.text(name, buf)) then
      name = ts.enclosing_class_name(cls.fn) or name
    end
    if not name then
      return cb({}, "anonymous function")
    end
    local info = ts.param_info(cls.params, cls.param, buf)
    local row, col = name:start()
    lsp.references(buf, row, col, function(locs)
      locs = locs or ts.find_calls(buf, ts.text(name, buf))
      local out = {}
      for _, loc in ipairs(locs) do
        local n = ts.node_at(loc.buf, loc.row, loc.col)
        local call = n and ts.call_of_callee(n)
        if call then
          local arg = ts.match_arg(call, loc.buf, info)
          if arg then
            out[#out + 1] = new({ "ARG" }, loc.buf, arg, expr_resolver(loc.buf, { arg }))
          else
            local node = new({ "ARG" }, loc.buf, call)
            node.note = info.splat and "variadic" or "not passed (default?)"
            out[#out + 1] = node
          end
        end
      end
      cb(out, #out == 0 and "no call sites found" or nil)
    end)
  end
end

--- `x = f(x, ...)` / `x += ...`: a new version of the same variable.
local function is_update(buf, w, cls)
  if cls.kind ~= "assign" then
    return false
  end
  if cls.augmented then
    return true
  end
  local name = ts.text(w, buf)
  for _, s in ipairs(ts.sources(cls.rhs, buf)) do
    if s.kind == "src" and s.name == name then
      return true
    end
  end
  return false
end

write_node = function(buf, w, cls, cond)
  local tags, resolve
  if is_update(buf, w, cls) then
    local name = ts.text(w, buf)
    tags = { "UPD" }
    if config().derive and #wanted_sources(buf, cls.rhs, name) > 0 then
      resolve = function(_, cb)
        cb(expr_children(buf, cls.rhs, name))
      end
    end
  elseif cls.kind == "param" then
    tags, resolve = { "PRM" }, callers_resolver(buf, cls)
  elseif cls.kind == "fndef" then
    tags = { "DEF" }
  elseif cls.kind == "import" then
    tags = { "IMP" }
    resolve = function(_, cb)
      local row, col = w:start()
      lsp.definition(buf, row, col, function(locs)
        local out = {}
        for _, loc in ipairs(locs) do
          if not (loc.buf == buf and loc.row == row) then
            local n = ts.node_at(loc.buf, loc.row, loc.col)
            if n then
              out[#out + 1] = write_node(loc.buf, n, ts.classify(n, true) or { kind = "other" }, false)
            end
          end
        end
        cb(out)
      end)
    end
  elseif cls.kind == "for" then
    tags, resolve = { "FOR" }, expr_resolver(buf, cls.iter)
  elseif cls.kind == "assign" then
    local rhs = cls.rhs
    if #rhs == 1 and ts.is_identifier(rhs[1]) and not cls.augmented then
      tags = { "ALS" }
      resolve = function(_, cb)
        trace(buf, rhs[1], {}, cb)
      end
    elseif config().derive and #ts.sources(rhs, buf) > 0 then
      tags = { "DRV" }
      resolve = function(_, cb)
        cb(expr_children(buf, rhs))
      end
    else
      tags = { "DEF" }
    end
  else
    tags = { "DEF" }
  end
  if cond then
    table.insert(tags, 1, "CND")
  end
  return new(tags, buf, w, resolve)
end

local function mut_node(buf, o, m, cond)
  local tags = cond and { "CND", "MUT" } or { "MUT" }
  return new(tags, buf, o, expr_resolver(buf, m.exprs, ts.text(o, buf)))
end

--- Timeline of the value of `occ`: the reaching writes, walking back through
--- self-updates (`x = x.f()`, `x += 1`) so they show up as flat siblings
--- instead of nesting one level per update.
local function timeline(buf, writes, occ, known)
  local out, cur, guard = {}, occ, 0
  while cur and guard < 100 do
    guard = guard + 1
    local reach = ts.reaching(writes, cur, known)
    for i = #reach, 1, -1 do
      if cur ~= occ then
        reach[i].cond = reach[i].cond or ts.is_conditional(reach[i].node, occ)
      end
      table.insert(out, 1, reach[i])
    end
    local base = reach[1]
    cur = (base and not base.cond and is_update(buf, base.node, base.cls)) and base.node or nil
  end
  return out
end

--- In-place mutations of the variable between `lower` (exclusive) and `occ`.
local function mutations(occs, occ, lower)
  local out = {}
  for _, o in ipairs(occs) do
    if not o:equal(occ) and ts.before(o, occ) and (not lower or ts.before(lower, o)) and ts.same_scope(o, occ) then
      local m = ts.mutation(o)
      if m and not ts.contains(m.stmt, occ) then
        out[#out + 1] = { node = o, mut = m, cond = ts.is_conditional(o, occ) }
      end
    end
  end
  return out
end

--- Where does the value of identifier `occ` come from?
---@param opts { as_read: boolean|nil }
trace = function(buf, occ, opts, cb)
  if not opts.as_read then
    local cls = ts.classify(occ, false)
    if cls then
      local node = write_node(buf, occ, cls, false)
      if not is_update(buf, occ, cls) then
        return cb({ node })
      end
      -- Cursor on an update: show the history leading to it, then itself.
      return trace(buf, occ, { as_read = true }, function(children)
        children[#children + 1] = node
        cb(children)
      end)
    end
  end
  local row, col = occ:start()

  lsp.highlights(buf, row, col, function(hl)
    local writes, occs, known = {}, {}, hl ~= nil
    if hl then
      for _, h in ipairs(hl) do
        local n = ts.node_at(buf, h.row, h.col)
        if n then
          occs[#occs + 1] = n
          if h.write then
            writes[#writes + 1] = n
          end
        end
      end
    else
      writes = ts.same_name_writes(buf, occ)
      occs = ts.same_name_occurrences(buf, occ)
    end

    local tl = timeline(buf, writes, occ, known)
    local items = vim.list_extend(vim.list_extend({}, tl), mutations(occs, occ, tl[1] and tl[1].node))
    table.sort(items, function(a, b)
      return ts.before(a.node, b.node)
    end)
    local out = {}
    for _, it in ipairs(items) do
      out[#out + 1] = it.mut and mut_node(buf, it.node, it.mut, it.cond) or write_node(buf, it.node, it.cls, it.cond)
    end
    if #tl > 0 then
      return cb(out)
    end

    -- No local write reaches here (global, closure, builtin...): ask the LSP.
    lsp.definition(buf, row, col, function(locs)
      if #locs == 0 and not hl then
        for _, n in ipairs(ts.top_level_writes(buf, ts.text(occ, buf))) do
          local r, c = n:start()
          locs[#locs + 1] = { buf = buf, row = r, col = c }
        end
      end
      local defs = {}
      for _, loc in ipairs(locs) do
        if not (loc.buf == buf and loc.row == row and loc.col == col) then
          local n = ts.node_at(loc.buf, loc.row, loc.col)
          if n then
            defs[#defs + 1] = write_node(loc.buf, n, ts.classify(n, true) or { kind = "other" }, false)
          end
        end
      end
      cb(vim.list_extend(defs, out))
    end)
  end)
end

local function key(n)
  return ("%d:%d:%d:%s"):format(n.buf, n.row, n.col, table.concat(n.tags, ","))
end

local function in_ancestors(node)
  local k, p = key(node), node.parent
  while p do
    if key(p) == k then
      return true
    end
    p = p.parent
  end
end

--- Expand a node (async). `auto` > 0 keeps expanding single-child chains.
function M.expand(node, auto, on_change, done)
  if node.children then
    node.expanded = true
    on_change()
    if done then
      done()
    end
    return
  end
  if not node.resolve then
    if done then
      done()
    end
    return
  end
  node.loading = true
  on_change()
  node.resolve(node, function(children, note)
    node.loading = false
    node.expanded = true
    node.children = children
    node.note = node.note or note or (#children == 0 and "nothing found" or nil)
    for _, c in ipairs(children) do
      c.parent = node
      if in_ancestors(c) then
        c.resolve = nil
        c.note = "cycle"
      end
    end
    on_change()
    local only = children[1]
    if #children == 1 and only.resolve and auto > 0 then
      M.expand(only, auto - 1, on_change, done)
    elseif done then
      done()
    end
  end)
end

--- Root node for the identifier at (buf, row, col).
function M.root(buf, row, col)
  local occ = ts.node_at(buf, row, col)
  if not occ or occ:named_child_count() > 0 then
    return nil
  end
  local node = new({ "SYM" }, buf, occ, function(_, cb)
    trace(buf, occ, {}, cb)
  end, ts.text(occ, buf))
  node.origin = { row = row, col = col }
  return node
end

return M
