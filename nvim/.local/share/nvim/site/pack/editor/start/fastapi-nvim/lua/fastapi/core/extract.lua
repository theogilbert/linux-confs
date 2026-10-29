-- Extracts routes, routers and test client calls from one Python file; results are cached.
local ts = require("fastapi.core.ts")

local M = {}

---@class fastapi.Import
---@field module string
---@field level integer
---@field names { name: string, alias: string? }[]

---@class fastapi.RouteDecl
---@field owner string
---@field method string
---@field path string
---@field func string
---@field line integer
---@field col integer
---@field deprecated boolean
---@field docstring string?

---@class fastapi.RouterDecl
---@field var string
---@field kind "FastAPI"|"APIRouter"
---@field prefix string
---@field tags string[]
---@field line integer
---@field col integer

---@class fastapi.FileAnalysis
---@field file string
---@field routes fastapi.RouteDecl[]
---@field routers fastapi.RouterDecl[]
---@field includes { owner: string, router: string, prefix: string, tags: string[] }[]
---@field mounts { owner: string, path: string, app: string }[]
---@field imports fastapi.Import[]
---@field call_assignments { var: string, callee: string, prefix: string, tags: string[], line: integer, col: integer }[]

---@class fastapi.Context
---@field src string
---@field consts table<string, string>

local HTTP_METHODS = {
    get = true,
    post = true,
    put = true,
    delete = true,
    patch = true,
    options = true,
    head = true,
    websocket = true,
}

local DEFINITIONS = { function_definition = true, class_definition = true }

local BUCKETS = {
    assignment = "assignment",
    decorated_definition = "decorated_definition",
    class_definition = "class_definition",
    call = "call",
    import_statement = "import",
    import_from_statement = "import",
}

M.HTTP_METHODS = HTTP_METHODS

---@alias fastapi.CacheKind "analysis"|"calls"

---@type table<fastapi.CacheKind, table<string, { stamp: string, value: any }>>
local caches = { analysis = {}, calls = {} }

---@param root TSNode
---@return table<string, TSNode[]>
local function collect(root)
    local found = {}
    for _, bucket in pairs(BUCKETS) do
        found[bucket] = {}
    end
    local function walk(node)
        local list = found[BUCKETS[node:type()]]
        if list then
            list[#list + 1] = node
        end
        for _, child in ipairs(ts.children(node)) do
            walk(child)
        end
    end
    walk(root)
    return found
end

---@param node TSNode
---@param kinds table<string, true>
---@return boolean
local function has_ancestor(node, kinds)
    local parent = node:parent()
    while parent do
        if kinds[parent:type()] then
            return true
        end
        parent = parent:parent()
    end
    return false
end

---@param call TSNode
---@return TSNode[]
local function call_args(call)
    local args = {}
    local list = ts.field(call, "arguments")
    for _, arg in ipairs(list and ts.children(list) or {}) do
        if arg:type() ~= "comment" then
            args[#args + 1] = arg
        end
    end
    return args
end

---@param args TSNode[]
---@param index integer  1-based position among the positional arguments
---@param keyword string
---@param src string
---@return TSNode?
local function arg_at(args, index, keyword, src)
    local position = 0
    for _, arg in ipairs(args) do
        if arg:type() ~= "keyword_argument" then
            position = position + 1
            if position == index then
                return arg
            end
        end
    end
    for _, arg in ipairs(args) do
        local name = ts.field(arg, "name")
        if name and ts.text(name, src) == keyword then
            return ts.field(arg, "value")
        end
    end
end

---@param node TSNode
---@param ctx fastapi.Context
---@return string
local function path_of(node, ctx)
    local kind = node:type()
    if kind == "string" then
        return ts.string_content(node, ctx.src) or ""
    elseif kind == "concatenated_string" then
        local parts = {}
        for _, child in ipairs(ts.children(node)) do
            parts[#parts + 1] = path_of(child, ctx)
        end
        return table.concat(parts)
    end
    local text = ts.text(node, ctx.src)
    if kind == "binary_operator" then
        local op, left, right =
            ts.field(node, "operator"), ts.field(node, "left"), ts.field(node, "right")
        if op and left and right and ts.text(op, ctx.src) == "+" then
            return path_of(left, ctx) .. path_of(right, ctx)
        end
    elseif kind == "identifier" and ctx.consts[text] then
        return ctx.consts[text]
    end
    return "{" .. text .. "}"
end

---@param by_type table<string, TSNode[]>
---@param src string
---@return table<string, string>
local function string_constants(by_type, src)
    local consts = {}
    for _, node in ipairs(by_type.assignment) do
        local left, right = ts.field(node, "left"), ts.field(node, "right")
        if
            left
            and right
            and left:type() == "identifier"
            and not has_ancestor(node, DEFINITIONS)
        then
            local value = ts.string_value(right, src)
            if value then
                consts[ts.text(left, src)] = value
            end
        end
    end
    return consts
end

---@param raw string
---@return string
local function clean_docstring(raw)
    local lines = vim.split(raw, "\n", { plain = true })
    local indent
    for i = 2, #lines do
        if lines[i]:match("%S") then
            local width = #lines[i]:match("^%s*")
            indent = math.min(indent or width, width)
        end
    end
    for i = 2, #lines do
        lines[i] = lines[i]:sub((indent or 0) + 1)
    end
    return vim.trim(table.concat(lines, "\n"))
end

---@param definition TSNode
---@param src string
---@return string?
local function docstring_of(definition, src)
    local body = ts.field(definition, "body")
    local first = body and ts.children(body)[1]
    -- Older tree-sitter-python versions wrap the docstring in an expression_statement.
    local expr = first and first:type() == "expression_statement" and ts.children(first)[1] or first
    local value = expr and ts.string_value(expr, src)
    if value then
        return clean_docstring(value)
    end
end

---@param args TSNode[]
---@param src string
---@return string?
local function first_method(args, src)
    for _, arg in ipairs(args) do
        local name, value = ts.field(arg, "name"), ts.field(arg, "value")
        if
            arg:type() == "keyword_argument"
            and name
            and ts.text(name, src) == "methods"
            and value
        then
            local first = ts.children(value)[1]
            return first and ts.string_value(first, src)
        end
    end
end

---@param args TSNode[]
---@param src string
---@return boolean
local function is_deprecated(args, src)
    for _, arg in ipairs(args) do
        local name, value = ts.field(arg, "name"), ts.field(arg, "value")
        if
            arg:type() == "keyword_argument"
            and name
            and ts.text(name, src) == "deprecated"
            and value
            and ts.text(value, src) == "True"
        then
            return true
        end
    end
    return false
end

---@param decorator TSNode
---@param ctx fastapi.Context
---@return { owner: string, method: string, args: TSNode[] }?
local function route_decorator(decorator, ctx)
    local call = ts.children(decorator)[1]
    local fn = call and call:type() == "call" and ts.field(call, "function")
    local owner = fn and ts.field(fn, "object")
    local attribute = fn and ts.field(fn, "attribute")
    if not (call and owner and attribute) then
        return nil
    end
    local method = ts.text(attribute, ctx.src)
    if not HTTP_METHODS[method:lower()] and method ~= "api_route" then
        return nil
    end
    return { owner = ts.text(owner, ctx.src), method = method, args = call_args(call) }
end

---@param def TSNode
---@param ctx fastapi.Context
---@return table[]
local function extract_routes(def, ctx)
    local definition = ts.field(def, "definition")
    local name = definition and ts.field(definition, "name")
    if not definition or not name then
        return {}
    end
    local docstring = docstring_of(definition, ctx.src)
    local line, col = def:start()
    local routes = {}
    for _, decorator in ipairs(ts.children(def)) do
        local found = decorator:type() == "decorator" and route_decorator(decorator, ctx)
        if found then
            local method = found.method
            if method == "api_route" then
                method = first_method(found.args, ctx.src) or "GET"
            end
            local path = arg_at(found.args, 1, "path", ctx.src)
            routes[#routes + 1] = {
                owner = found.owner,
                method = method,
                path = path and path_of(path, ctx) or "",
                func = ts.text(name, ctx.src),
                line = line,
                col = col,
                deprecated = is_deprecated(found.args, ctx.src),
                docstring = docstring,
            }
        end
    end
    return routes
end

---@param import fastapi.Import
---@param plain boolean  whether it is an `import x` statement
---@param fastapi table<string, true>
---@param routers table<string, true>
local function note_fastapi_aliases(import, plain, fastapi, routers)
    if plain then
        local alias = import.names[1].alias
        if alias and import.module == "fastapi" then
            fastapi[alias .. ".FastAPI"] = true
            routers[alias .. ".APIRouter"] = true
        end
    elseif import.module == "fastapi" and import.level == 0 then
        for _, item in ipairs(import.names) do
            if item.alias and item.name == "FastAPI" then
                fastapi[item.alias] = true
            elseif item.alias and item.name == "APIRouter" then
                routers[item.alias] = true
            end
        end
    end
end

---@param by_type table<string, TSNode[]>
---@param src string
---@param fastapi table<string, true>
---@param routers table<string, true>
local function add_subclasses(by_type, src, fastapi, routers)
    for _, node in ipairs(by_type.class_definition) do
        local name, bases = ts.field(node, "name"), ts.field(node, "superclasses")
        for _, base in ipairs(bases and ts.children(bases) or {}) do
            local text = ts.text(base, src)
            if routers[text] and name then
                routers[ts.text(name, src)] = true
            elseif fastapi[text] and name then
                fastapi[ts.text(name, src)] = true
            end
        end
    end
end

---@param call TSNode
---@param ctx fastapi.Context
---@return string prefix, string[] tags
local function prefix_and_tags(call, ctx)
    local prefix, tags = "", {}
    for _, arg in ipairs(call_args(call)) do
        local name, value = ts.field(arg, "name"), ts.field(arg, "value")
        local key = arg:type() == "keyword_argument" and name and ts.text(name, ctx.src)
        if key == "prefix" and value then
            prefix = path_of(value, ctx)
        elseif key == "tags" and value and value:type() == "list" then
            tags = {}
            for _, item in ipairs(ts.children(value)) do
                tags[#tags + 1] = ts.string_value(item, ctx.src)
            end
        end
    end
    return prefix, tags
end

---@param node TSNode
---@param ctx fastapi.Context
---@param fastapi table<string, true>
---@param routers table<string, true>
---@param analysis fastapi.FileAnalysis
local function extract_assignment(node, ctx, fastapi, routers, analysis)
    local left, right = ts.field(node, "left"), ts.field(node, "right")
    if not (left and right and right:type() == "call") then
        return
    end
    local fn = ts.field(right, "function")
    local callee = fn and ts.text(fn, ctx.src)
    local kind = callee and ((routers[callee] and "APIRouter") or (fastapi[callee] and "FastAPI"))
    local prefix, tags = prefix_and_tags(right, ctx)
    local line, col = node:start()
    if kind then
        table.insert(analysis.routers, {
            var = ts.text(left, ctx.src),
            kind = kind,
            prefix = prefix,
            tags = tags,
            line = line,
            col = col,
        })
    elseif fn and fn:type() == "identifier" and not has_ancestor(node, DEFINITIONS) then
        table.insert(analysis.call_assignments, {
            var = ts.text(left, ctx.src),
            callee = ts.text(fn, ctx.src),
            prefix = prefix,
            tags = tags,
            line = line,
            col = col,
        })
    end
end

---@param node TSNode
---@param ctx fastapi.Context
---@param analysis fastapi.FileAnalysis
local function extract_method_call(node, ctx, analysis)
    local fn = ts.field(node, "function")
    local owner = fn and fn:type() == "attribute" and ts.field(fn, "object")
    local attribute = fn and ts.field(fn, "attribute")
    local method = attribute and ts.text(attribute, ctx.src)
    if not (owner and (method == "include_router" or method == "mount")) then
        return
    end
    local args = call_args(node)
    local owner_name = ts.text(owner, ctx.src)
    if method == "include_router" then
        local router = arg_at(args, 1, "router", ctx.src)
        local prefix, tags = prefix_and_tags(node, ctx)
        table.insert(analysis.includes, {
            owner = owner_name,
            router = router and ts.text(router, ctx.src) or "",
            prefix = prefix,
            tags = tags,
        })
    elseif #args >= 2 then
        local path, app = arg_at(args, 1, "path", ctx.src), arg_at(args, 2, "app", ctx.src)
        table.insert(analysis.mounts, {
            owner = owner_name,
            path = path and path_of(path, ctx) or "",
            app = app and ts.text(app, ctx.src) or "",
        })
    end
end

---@param node TSNode
---@param src string
---@return fastapi.Import[]
local function parse_import(node, src)
    local function names_of(nodes)
        local names = {}
        for _, item in ipairs(nodes) do
            local target = item:type() == "aliased_import" and ts.field(item, "name") or item
            local alias = item:type() == "aliased_import" and ts.field(item, "alias")
            names[#names + 1] = {
                name = ts.text(assert(target), src),
                alias = alias and ts.text(alias, src) or nil,
            }
        end
        return names
    end
    local names = names_of(node:field("name"))
    if node:type() == "import_statement" then
        return vim.tbl_map(function(item)
            return { module = item.name, level = 0, names = { item } }
        end, names)
    end
    local module = ts.field(node, "module_name")
    local dots, rest = ts.text(assert(module), src):match("^(%.*)(.*)$")
    return { { module = rest, level = #dots, names = names } }
end

---@param root TSNode
---@param src string
---@param file string
---@return fastapi.FileAnalysis
local function analyze_tree(root, src, file)
    local by_type = collect(root)
    local ctx = { src = src, consts = string_constants(by_type, src) }
    local analysis = {
        file = file,
        routes = {},
        routers = {},
        includes = {},
        mounts = {},
        imports = {},
        call_assignments = {},
    }
    for _, def in ipairs(by_type.decorated_definition) do
        vim.list_extend(analysis.routes, extract_routes(def, ctx))
    end
    local fastapi = { FastAPI = true, ["fastapi.FastAPI"] = true }
    local routers = { APIRouter = true, ["fastapi.APIRouter"] = true }
    for _, node in ipairs(by_type.import) do
        local plain = node:type() == "import_statement"
        for _, import in ipairs(parse_import(node, src)) do
            table.insert(analysis.imports, import)
            note_fastapi_aliases(import, plain, fastapi, routers)
        end
    end
    add_subclasses(by_type, src, fastapi, routers)
    for _, node in ipairs(by_type.assignment) do
        extract_assignment(node, ctx, fastapi, routers, analysis)
    end
    for _, node in ipairs(by_type.call) do
        extract_method_call(node, ctx, analysis)
    end
    return analysis
end

---@param root TSNode
---@param src string
---@return { method: string, path: string, line: integer, col: integer }[]
function M.find_test_calls(root, src)
    local by_type = collect(root)
    local ctx = { src = src, consts = string_constants(by_type, src) }
    local calls = {}
    for _, node in ipairs(by_type.call) do
        local fn = ts.field(node, "function")
        local attribute = fn and fn:type() == "attribute" and ts.field(fn, "attribute")
        local method = attribute and ts.text(attribute, src):lower()
        -- Starlette's TestClient opens websockets with websocket_connect().
        method = method == "websocket_connect" and "websocket" or method
        local path = method and HTTP_METHODS[method] and arg_at(call_args(node), 1, "url", src)
        if path then
            local line, col = node:start()
            table.insert(
                calls,
                { method = method, path = path_of(path, ctx), line = line, col = col }
            )
        end
    end
    return calls
end

---@param path string
---@return string?
local function stamp(path)
    local stat = vim.uv.fs_stat(path)
    if not stat then
        return nil
    end
    return table.concat({ stat.mtime.sec, stat.mtime.nsec, stat.size }, ":")
end

---@param kind fastapi.CacheKind
---@param path string
---@param build fun(root: TSNode, src: string, path: string): any
---@param before_parse fun()?
---@return any, string?
local function cached(kind, path, build, before_parse)
    local current = stamp(path)
    if not current then
        return nil, "cannot read " .. path
    end
    local entry = caches[kind][path]
    if entry and entry.stamp == current then
        return entry.value
    end
    if before_parse then
        before_parse()
    end
    local root, src = ts.parse_file(path)
    if not root then
        return nil, src
    end
    local value = build(root, src, path)
    caches[kind][path] = { stamp = current, value = value }
    return value
end

---@param path string
---@param before_parse fun()?  called when the file is not cached, right before it is parsed
---@return fastapi.FileAnalysis?, string?
function M.analyze(path, before_parse)
    return cached("analysis", path, analyze_tree, before_parse)
end

---@param path string
---@return { method: string, path: string, line: integer, col: integer }[]?, string?
function M.test_calls(path)
    return cached("calls", path, M.find_test_calls)
end

---@param path string
function M.invalidate(path)
    for _, store in pairs(caches) do
        store[path] = nil
    end
end

function M.clear()
    caches = { analysis = {}, calls = {} }
end

return M
