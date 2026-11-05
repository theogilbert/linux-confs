-- Language-agnostic tree-sitter helpers.
--
-- Rather than per-language node tables, these helpers rely on conventions most
-- tree-sitter grammars share: node type names split on "_" (if_statement,
-- call_expression, ...) and field names (left/right, name/value, function,
-- arguments, parameters, ...).
local M = {}

local function set(list)
  local s = {}
  for _, v in ipairs(list) do
    s[v] = true
  end
  return s
end

local function tokens(node)
  local s = {}
  for w in node:type():gmatch("[^_]+") do
    s[w] = true
  end
  return s
end

local function has_token(node, wanted)
  local tk = tokens(node)
  for w in pairs(wanted) do
    if tk[w] then
      return true
    end
  end
  return false
end
M.has_token = has_token

local COND = set({
  "if", "else", "elif", "elseif", "case", "match", "switch", "try", "except",
  "catch", "conditional", "ternary", "while", "for", "foreach", "loop", "when",
  "guard", "arm",
})
local FUNC = set({ "function", "method", "lambda", "closure", "func", "arrow", "constructor" })
local CLASS = set({ "class", "struct", "enum", "interface", "trait", "impl" })
local CALL = set({ "call", "invocation" })
local IMPORT = set({ "import", "require", "use", "include" })
local REQUIRE = set({ "require", "import", "dofile" })
local ASSIGN = set({ "assignment", "assign", "declarator", "declaration", "binding", "let", "named", "spec" })
local BOUNDARY = set({ "statement", "block", "module", "program", "chunk", "source", "body", "suite" })
local RETURN = set({ "return" })
local KWARG = set({ "keyword", "named" })
local SPLAT = set({ "splat", "spread", "unpacking", "variadic" })
local ARGS = set({ "arguments", "argument" })
local ACCESS = set({ "attribute", "member", "subscript", "index", "selector", "field", "dot", "bracket" })

-- Fields whose content is evaluated (read), never bound.
local READ_FIELDS = set({
  "value", "right", "default", "default_value", "type", "return_type", "arguments",
  "argument", "condition", "consequence", "alternative", "body", "function",
  "object", "subscript", "index", "operand", "start", "end", "step", "iterable",
  "table", "superclasses", "decorator",
})
-- Fields skipped when collecting the identifiers an expression depends on.
local SKIP_FIELDS = set({ "attribute", "property", "field", "key", "label", "type", "method" })

local ID_TYPES = set({ "identifier", "simple_identifier" })

function M.text(node, buf)
  return vim.treesitter.get_node_text(node, buf)
end

function M.is_identifier(node)
  return ID_TYPES[node:type()] == true
end

local function before(a, b)
  local ar, ac = a:start()
  local br, bc = b:start()
  return ar < br or (ar == br and ac < bc)
end
M.before = before

function M.contains(outer, inner)
  local osr, osc, oer, oec = outer:range()
  local isr, isc, ier, iec = inner:range()
  local starts = osr < isr or (osr == isr and osc <= isc)
  local ends = oer > ier or (oer == ier and oec >= iec)
  return starts and ends
end

function M.ensure_parsed(buf)
  if not vim.api.nvim_buf_is_loaded(buf) then
    vim.fn.bufload(buf)
  end
  if vim.bo[buf].filetype == "" then
    local ft = vim.filetype.match({ buf = buf })
    if ft then
      vim.bo[buf].filetype = ft
    end
  end
  local parser = vim.treesitter.get_parser(buf, nil, { error = false })
  if not parser then
    return nil
  end
  parser:parse()
  return parser
end

function M.node_at(buf, row, col)
  if not M.ensure_parsed(buf) then
    return nil
  end
  return vim.treesitter.get_node({ bufnr = buf, pos = { row, col } })
end

local function field_of(parent, child)
  for c, field in parent:iter_children() do
    if c:equal(child) then
      return field
    end
  end
end

function M.params_of(fn)
  return fn:field("parameters")[1] or fn:field("parameter")[1]
end

function M.is_function(node)
  return has_token(node, FUNC) and not has_token(node, CALL) and M.params_of(node) ~= nil
end

function M.enclosing_function(node)
  local p = node:parent()
  while p do
    if M.is_function(p) then
      return p
    end
    p = p:parent()
  end
end

function M.args_of(call)
  local a = call:field("arguments")[1]
  if a then
    return a
  end
  for c in call:iter_children() do
    if c:named() and has_token(c, ARGS) then
      return c
    end
  end
end

function M.is_call(node)
  return has_token(node, CALL) and M.args_of(node) ~= nil
end

function M.callee(call)
  return call:field("function")[1] or call:field("name")[1] or call:field("method")[1]
end

-- The identifier naming the called function: `f` in f(x), `m` in obj.m(x).
function M.callee_name(callee)
  if callee:named_child_count() == 0 then
    return callee
  end
  for _, f in ipairs({ "attribute", "property", "field", "method", "name" }) do
    local n = callee:field(f)[1]
    if n then
      return n
    end
  end
  return callee:named_child(callee:named_child_count() - 1)
end

-- The call whose callee contains `node`.
function M.call_of_callee(node)
  local p, depth = node:parent(), 0
  while p and depth < 4 do
    if M.is_call(p) then
      local c = M.callee(p)
      return (c and M.contains(c, node)) and p or nil
    end
    p, depth = p:parent(), depth + 1
  end
end

local function operator_child(node)
  for c in node:iter_children() do
    if not c:named() then
      local t = c:type()
      if t == "=" or t == ":=" or (t:sub(-1) == "=" and not t:match("^[=!<>]=$")) then
        return c
      end
    end
  end
end

local function rhs_of(stmt, op)
  local rhs = stmt:field("right")
  if #rhs == 0 then
    rhs = stmt:field("value")
  end
  if #rhs == 0 and op then
    rhs = {}
    for c in stmt:iter_children() do
      if c:named() and before(op, c) then
        rhs[#rhs + 1] = c
      end
    end
  end
  -- Unwrap single-element lists (lua `local a = b` -> expression_list).
  while #rhs == 1 and rhs[1]:type():match("list") and rhs[1]:named_child_count() == 1 do
    rhs = { rhs[1]:named_child(0) }
  end
  return rhs
end

local function for_iter(stmt)
  local it = stmt:field("right")[1] or stmt:field("value")[1]
  if it then
    return { it }
  end
  for c in stmt:iter_children() do
    if c:type() == "expression_list" then
      return { c }
    end
  end
  return {}
end

--- Classify an identifier as a binding site.
---@param id TSNode
---@param known_write boolean the LSP already told us this occurrence is a write
---@param buf integer|nil needed to recognise `x = require("m")` as an import
---@return table|nil { kind = "param"|"fndef"|"import"|"for"|"assign"|"other", ... }
function M.classify(id, known_write, buf)
  local child, p, depth = id, id:parent(), 0
  while p and depth < 12 do
    local field = field_of(p, child)
    if field and READ_FIELDS[field] then
      return nil
    end
    local pp = p:parent()
    if pp and M.is_function(pp) and M.params_of(pp):equal(p) then
      return { kind = "param", fn = pp, params = p, param = child }
    end
    if (M.is_function(p) or has_token(p, CLASS)) and field == "name" then
      return { kind = "fndef", def = p }
    end
    if has_token(p, IMPORT) then
      return { kind = "import", stmt = p }
    end
    if field == "alias" then
      return { kind = "other", stmt = p }
    end
    if has_token(p, set({ "for", "foreach" })) and not M.is_function(p) then
      local is_target = field == "left" or field == "pattern" or field == "name"
        or field == "variable" or child:type() == "variable_list"
      if is_target then
        return { kind = "for", stmt = p, iter = for_iter(p) }
      end
    end
    if has_token(p, ASSIGN) and not M.is_function(p) and not has_token(p, CLASS) then
      local op = operator_child(p)
      local is_lhs = field == "left" or field == "name" or field == "pattern" or field == "declarator"
        or (field == nil and op ~= nil and before(child, op))
      if is_lhs then
        local optext = op and op:type() or "="
        local rhs = rhs_of(p, op)
        -- `x = require("m")`: an import, not a derivation.
        local call = buf and #rhs == 1 and M.is_call(rhs[1]) and rhs[1]
        local callee = call and M.callee(call)
        if callee and M.is_identifier(callee) and REQUIRE[M.text(callee, buf)] then
          return { kind = "import", stmt = p, require = call }
        end
        return {
          kind = "assign",
          stmt = p,
          rhs = rhs,
          augmented = has_token(p, set({ "augmented", "compound", "update" }))
            or (optext ~= "=" and optext ~= ":="),
        }
      end
    end
    if has_token(p, BOUNDARY) or M.is_function(p) then
      return known_write and { kind = "other", stmt = child } or nil
    end
    child, p, depth = p, pp, depth + 1
  end
  return known_write and { kind = "other", stmt = id } or nil
end

--- Is write `w` guarded by a branch/loop that does not also enclose `occ`?
function M.is_conditional(w, occ)
  local anc = {}
  local p = occ:parent()
  while p do
    anc[p:id()] = true
    p = p:parent()
  end
  p = w:parent()
  while p and not anc[p:id()] do
    if has_token(p, COND) then
      return true
    end
    p = p:parent()
  end
  return false
end

--- Same-name binding sites in the scope of `occ` (fallback when no LSP).
function M.same_name_writes(buf, occ)
  local name = M.text(occ, buf)
  local scope = M.enclosing_function(occ) or occ:tree():root()
  local out = {}
  local function walk(n)
    for c in n:iter_children() do
      if c:named() then
        if M.is_identifier(c) then
          if M.text(c, buf) == name and M.classify(c, false, buf) then
            out[#out + 1] = c
          end
        elseif not M.is_function(c) then
          walk(c)
        else
          -- Nested function: its name and parameters belong to this scope's
          -- view only for its name.
          local nm = c:field("name")[1]
          if nm and M.text(nm, buf) == name then
            out[#out + 1] = nm
          end
        end
      end
    end
  end
  walk(scope)
  -- Parameters of the scope function itself.
  if scope:type() ~= occ:tree():root():type() then
    local params = M.params_of(scope)
    if params then
      for c in params:iter_children() do
        if c:named() then
          local stack = { c }
          while #stack > 0 do
            local n = table.remove(stack)
            if M.is_identifier(n) and M.text(n, buf) == name then
              out[#out + 1] = n
            end
            for cc, f in n:iter_children() do
              if cc:named() and not READ_FIELDS[f] then
                stack[#stack + 1] = cc
              end
            end
          end
        end
      end
    end
  end
  return out
end

--- Writes that may reach `occ`: the last unconditional one plus any
--- conditional ones after it.
---@return { node: TSNode, cls: table, cond: boolean }[]
function M.reaching(writes, occ, known_write, buf)
  local cands = {}
  for _, w in ipairs(writes) do
    if not w:equal(occ) and before(w, occ) then
      local cls = M.classify(w, known_write, buf)
      if cls and not (cls.kind == "assign" and M.contains(cls.stmt, occ)) then
        cands[#cands + 1] = { node = w, cls = cls }
      end
    end
  end
  table.sort(cands, function(a, b)
    return before(a.node, b.node)
  end)
  local out = {}
  for i = #cands, 1, -1 do
    local c = cands[i]
    local guarded = (c.cls.kind == "assign" or c.cls.kind == "other") and M.is_conditional(c.node, occ)
    c.cond = guarded
    table.insert(out, 1, c)
    if not guarded then
      break
    end
  end
  return out
end

--- Identifiers an expression depends on. Callees are reported as "fn".
---@return { node: TSNode, kind: "src"|"fn", name: string }[]
function M.sources(nodes, buf)
  local out, seen = {}, {}
  local function add(n, kind, callee)
    local name = M.text(n, buf)
    if not seen[kind .. name] then
      seen[kind .. name] = true
      local receiver
      if callee and callee:named_child_count() > 0 then
        local r = callee:named_child(0)
        while r and r:named_child_count() > 0 do
          r = r:named_child(0)
        end
        receiver = r and M.text(r, buf)
      end
      out[#out + 1] = { node = n, kind = kind, name = name, receiver = receiver }
    end
  end
  local walk
  local function walk_children(n)
    for c, field in n:iter_children() do
      if c:named() and not (field and SKIP_FIELDS[field])
        and not (field == "name" and has_token(n, set({ "keyword", "named", "pair", "argument" }))) then
        walk(c)
      end
    end
  end
  walk = function(n)
    if M.is_call(n) then
      local c = M.callee(n)
      if c then
        add(M.callee_name(c), "fn", c)
        if c:named_child_count() > 0 then
          walk_children(c)
        end
      end
      walk(M.args_of(n))
      return
    end
    if M.is_identifier(n) then
      add(n, "src")
      return
    end
    if M.is_function(n) then
      return
    end
    walk_children(n)
  end
  for _, n in ipairs(nodes) do
    walk(n)
  end
  return out
end

--- Position/name of a parameter, used to match call-site arguments.
function M.param_info(params, param, buf)
  local idx, offset, first, target = 0, 0, true, nil
  for c in params:iter_children() do
    if c:named() and c:type() ~= "comment" and not c:type():match("separator") then
      if first then
        local tx = M.text(c, buf)
        if c:type() == "self_parameter" or tx == "self" or tx == "cls" or tx:match("^self[:%s]") then
          offset = 1
        end
        first = false
      end
      if c:equal(param) then
        target = idx
      end
      idx = idx + 1
    end
  end
  local name_node = param
  if not M.is_identifier(param) then
    local stack = { param }
    while #stack > 0 do
      local n = table.remove(stack, 1)
      if M.is_identifier(n) then
        name_node = n
        break
      end
      for cc, f in n:iter_children() do
        if cc:named() and not READ_FIELDS[f] then
          stack[#stack + 1] = cc
        end
      end
    end
  end
  return {
    index = target and (target - offset) or nil,
    name = M.text(name_node, buf),
    splat = has_token(param, SPLAT) or has_token(param, set({ "list", "dictionary" })),
  }
end

--- The argument expression bound to a parameter at a call site.
function M.match_arg(call, buf, info)
  local args = M.args_of(call)
  if not args then
    return nil
  end
  local pos, splat, found = 0, false, nil
  for c in args:iter_children() do
    if c:named() and c:type() ~= "comment" then
      local kname = c:field("name")[1]
      if has_token(c, KWARG) and kname then
        if M.text(kname, buf) == info.name then
          return c:field("value")[1] or c
        end
      elseif has_token(c, SPLAT) then
        splat = true
      else
        if not splat and info.index and pos == info.index then
          found = c
        end
        pos = pos + 1
      end
    end
  end
  return found
end

-- Values of a return statement (Lua wraps them in an expression_list).
local function return_exprs(ret)
  local exprs = {}
  for e in ret:iter_children() do
    if e:named() and e:type() ~= "comment" then
      if e:type() == "expression_list" then
        for v in e:iter_children() do
          if v:named() then
            exprs[#exprs + 1] = v
          end
        end
      else
        exprs[#exprs + 1] = e
      end
    end
  end
  return exprs
end

--- Return expressions of a function (not of nested functions).
function M.returns(fn)
  local out = {}
  local body = fn:field("body")[1] or fn
  if not has_token(body, BOUNDARY) and not body:type():match("block") and fn:type():match("lambda") then
    return { { node = body, exprs = { body } } }
  end
  local function walk(n)
    for c in n:iter_children() do
      if c:named() then
        if has_token(c, RETURN) then
          out[#out + 1] = { node = c, exprs = return_exprs(c) }
        elseif not M.is_function(c) then
          walk(c)
        end
      end
    end
  end
  walk(body)
  return out
end

--- Module-level binding sites named `name` (globals; fallback without LSP).
function M.top_level_writes(buf, name)
  local out = {}
  local root = M.node_at(buf, 0, 0):tree():root()
  local function walk(n)
    for c in n:iter_children() do
      if c:named() then
        if M.is_identifier(c) then
          if M.text(c, buf) == name and M.classify(c, false, buf) then
            out[#out + 1] = c
          end
        elseif M.is_function(c) then
          local nm = c:field("name")[1]
          if nm and M.text(nm, buf) == name then
            out[#out + 1] = nm
          end
        else
          walk(c)
        end
      end
    end
  end
  walk(root)
  return out
end

--- Every identifier named like `occ` in its scope (fallback without LSP).
function M.same_name_occurrences(buf, occ)
  local name = M.text(occ, buf)
  local scope = M.enclosing_function(occ) or occ:tree():root()
  local out = {}
  local function walk(n)
    for c in n:iter_children() do
      if c:named() then
        if M.is_identifier(c) then
          if M.text(c, buf) == name then
            out[#out + 1] = c
          end
        elseif not M.is_function(c) then
          walk(c)
        end
      end
    end
  end
  walk(scope)
  return out
end

--- Is this occurrence mutated in place?
---   x[k] = v / x.a = v      -> the assigned value
---   x.m(args) as statement  -> the arguments (result discarded => side effect)
---@return { stmt: TSNode, exprs: TSNode[] }|nil
function M.mutation(id)
  local cur = id
  while true do
    local p = cur:parent()
    local first = p and p:named_child(0)
    if not (p and has_token(p, ACCESS) and first and first:equal(cur)) then
      break
    end
    cur = p
  end
  if cur:equal(id) then
    return nil
  end
  local cls = M.classify(cur, false)
  if cls and cls.kind == "assign" then
    return { stmt = cls.stmt, exprs = cls.rhs }
  end
  local call = cur:parent()
  if call and M.is_call(call) then
    local callee = M.callee(call)
    local holder = call:parent()
    if callee and callee:equal(cur) and holder and has_token(holder, BOUNDARY) then
      local exprs = {}
      for a in M.args_of(call):iter_children() do
        if a:named() and a:type() ~= "comment" then
          exprs[#exprs + 1] = a
        end
      end
      return { stmt = call, exprs = exprs }
    end
  end
end

--- The call this occurrence is passed to as an argument (`f(x)`, `f(k=x)`).
function M.passed_to(id)
  local a = id:parent()
  for depth = 1, 2 do
    local call = a and a:parent()
    if call and M.is_call(call) and M.args_of(call):equal(a) then
      return call
    end
    -- One wrapper allowed: a keyword/named argument.
    if depth == 1 and not (a and a:type():find("argument")) then
      return nil
    end
    a = call
  end
end

--- The statement containing `node` (stops below blocks/bodies/functions).
function M.statement(node)
  local cur = node
  while cur:parent() and not has_token(cur:parent(), BOUNDARY) and not M.is_function(cur:parent())
    and not M.is_function(cur) do
    cur = cur:parent()
  end
  return cur
end

--- Same enclosing function (or both at top level)?
function M.same_scope(a, b)
  local fa, fb = M.enclosing_function(a), M.enclosing_function(b)
  if fa == nil or fb == nil then
    return fa == nil and fb == nil
  end
  return fa:equal(fb)
end

--- Function/class definitions named `name` in this file (fallback without LSP).
function M.find_defs(buf, name)
  local out = {}
  local function walk(n)
    for c in n:iter_children() do
      if c:named() then
        if M.is_identifier(c) then
          local cls = M.text(c, buf) == name and M.classify(c, false, buf)
          if cls and cls.kind == "fndef" then
            local row, col = c:start()
            out[#out + 1] = { buf = buf, row = row, col = col }
          end
        else
          walk(c)
        end
      end
    end
  end
  walk(M.node_at(buf, 0, 0):tree():root())
  return out
end

--- Call sites of `name` in this file (fallback without LSP).
function M.find_calls(buf, name)
  local out = {}
  local function walk(n)
    for c in n:iter_children() do
      if c:named() then
        if M.is_call(c) then
          local callee = M.callee(c)
          local cn = callee and M.callee_name(callee)
          if cn and M.text(cn, buf) == name then
            local row, col = cn:start()
            out[#out + 1] = { buf = buf, row = row, col = col }
          end
        end
        walk(c)
      end
    end
  end
  walk(M.node_at(buf, 0, 0):tree():root())
  return out
end

--- Import binding `name` in this file (`from m import name`, `import name`,
--- `local name = require(...)`).
function M.find_import(buf, name)
  local found
  local function walk(n)
    for c in n:iter_children() do
      if found then
        return
      end
      if c:named() then
        if M.is_identifier(c) then
          local cls = M.text(c, buf) == name and M.classify(c, false, buf)
          if cls and cls.kind == "import" then
            found = c
          end
        elseif not M.is_function(c) then
          walk(c)
        end
      end
    end
  end
  walk(M.node_at(buf, 0, 0):tree():root())
  return found
end

local function unquote(node, buf)
  return (M.text(node, buf):gsub("^['\"`]+", ""):gsub("['\"`]+$", ""))
end

local function first_string(node, buf)
  if node:type():match("string") then
    return unquote(node, buf)
  end
  for c in node:iter_children() do
    if c:named() then
      local s = first_string(c, buf)
      if s then
        return s
      end
    end
  end
end

--- What an import identifier refers to: the module path, and the name it
--- imports from it (nil when it binds the whole module).
---@return { module: string, name: string|nil }|nil
function M.import_info(id, buf)
  local cls = M.classify(id, false, buf)
  if not cls or cls.kind ~= "import" then
    return nil
  end
  -- `import_specifier`/`aliased_import` -> the whole import statement.
  local stmt = cls.stmt
  while stmt:parent() and stmt:parent():type():match("import") do
    stmt = stmt:parent()
  end
  local mod_node = stmt:field("module_name")[1] or stmt:field("source")[1]
  local module
  if mod_node then
    module = mod_node:type():match("string") and unquote(mod_node, buf) or M.text(mod_node, buf)
  elseif cls.require then
    module = first_string(cls.require, buf)
  else
    local n = stmt:field("name")[1]
    n = n and (n:field("name")[1] or n)
    module = n and M.text(n, buf)
  end
  if not module then
    return nil
  end
  if mod_node and M.contains(mod_node, id) then
    return { module = module }
  end
  -- Named import: `from m import name [as alias]`, `import { name [as alias] }`.
  local child, p = id, id:parent()
  while p and not p:equal(stmt) do
    if p:type():match("specifier") or (stmt:type():match("from") and field_of(p, child) == "alias") then
      local nm = p:field("name")[1]
      return { module = module, name = nm and M.text(nm, buf):match("[%w_$]+$") or M.text(id, buf) }
    end
    child, p = p, p:parent()
  end
  if stmt:type():match("from") and field_of(stmt, child) == "name" then
    return { module = module, name = M.text(id, buf) }
  end
  return { module = module }
end

local EXTS = { "py", "ts", "tsx", "js", "jsx", "mjs", "cjs", "lua" }

--- File a module path resolves to, searched from the importing file (no LSP).
function M.resolve_module(buf, module)
  local file = vim.api.nvim_buf_get_name(buf)
  local dir = vim.fn.fnamemodify(file, ":p:h")
  local exts = { vim.fn.fnamemodify(file, ":e") }
  vim.list_extend(exts, EXTS)
  local bases = {}
  if module:match("^%.?%.?/") then
    bases = { vim.fs.normalize(dir .. "/" .. module) }
  elseif module:match("^%.") then
    -- Python relative import: one dot per package level.
    local dots, rest = module:match("^(%.+)(.*)$")
    local d = dir
    for _ = 2, #dots do
      d = vim.fn.fnamemodify(d, ":h")
    end
    bases = { d .. "/" .. rest:gsub("%.", "/") }
  else
    local p = module:gsub("%.", "/")
    local cwd = vim.fn.getcwd()
    bases = { dir .. "/" .. p, cwd .. "/" .. p, cwd .. "/lua/" .. p, cwd .. "/src/" .. p }
    -- Project files first, then Lua modules on the runtime path.
    for _, f in ipairs(vim.api.nvim_get_runtime_file("lua/" .. p .. ".lua", true)) do
      bases[#bases + 1] = f:sub(1, -5)
    end
  end
  for _, base in ipairs(bases) do
    local cands = {}
    for _, e in ipairs(exts) do
      cands[#cands + 1] = base .. "." .. e
    end
    for _, idx in ipairs({ "__init__.py", "init.lua", "index.ts", "index.tsx", "index.js" }) do
      cands[#cands + 1] = base .. "/" .. idx
    end
    if vim.fn.filereadable(base) == 1 then
      return base
    end
    for _, c in ipairs(cands) do
      if vim.fn.filereadable(c) == 1 then
        return c
      end
    end
  end
end

--- Top-level return statements of a module (Lua `return M`).
function M.module_returns(buf)
  local root = M.node_at(buf, 0, 0):tree():root()
  local out = {}
  for c in root:iter_children() do
    if c:named() and has_token(c, RETURN) then
      out[#out + 1] = { node = c, exprs = return_exprs(c) }
    end
  end
  return out
end

-- Enclosing class name node (for constructors).
function M.enclosing_class_name(node)
  local p = node:parent()
  while p do
    if has_token(p, CLASS) and p:field("name")[1] then
      return p:field("name")[1]
    end
    p = p:parent()
  end
end

return M
