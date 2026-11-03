-- Builds the router tree of an app by following include_router, mount and imports.
local extract = require("fastapi.core.extract")
local imports = require("fastapi.core.imports")

local M = {}

---@class fastapi.RouterNode
---@field file string
---@field var string
---@field kind "FastAPI"|"APIRouter"
---@field prefix string
---@field tags string[]
---@field line integer
---@field col integer
---@field routes fastapi.RouteDecl[]
---@field children { node: fastapi.RouterNode, prefix: string, tags: string[] }[]

---@class fastapi.GraphContext
---@field root string
---@field visited table<string, true>
---@field tick fun()?  called before each file that has to be parsed

---@param routers fastapi.RouterDecl[]
---@param var string?
---@return fastapi.RouterDecl?
local function find_app_router(routers, var)
    local fallback
    for _, router in ipairs(routers) do
        if var then
            if router.var == var then
                return router
            end
        elseif router.kind == "FastAPI" then
            return router
        elseif not fallback then
            fallback = router
        end
    end
    return fallback
end

---@param analysis fastapi.FileAnalysis
---@param var string
---@return fastapi.RouterDecl?
local function infer_included_router(analysis, var)
    for _, call in ipairs(analysis.call_assignments) do
        if call.var == var then
            return {
                var = call.var,
                kind = "APIRouter",
                prefix = call.prefix,
                tags = call.tags,
                line = call.line,
                col = call.col,
            }
        end
    end
end

---@param router fastapi.RouterDecl
---@param analysis fastapi.FileAnalysis
---@param file string
---@return fastapi.RouterNode
local function new_node(router, analysis, file)
    local routes = vim.tbl_filter(function(route)
        return route.owner == router.var
    end, analysis.routes)
    return {
        file = file,
        var = router.var,
        kind = router.kind,
        prefix = router.prefix,
        tags = vim.list_slice(router.tags),
        line = router.line,
        col = router.col,
        routes = routes,
        children = {},
    }
end

---@param tags string[]
---@param extra string[]
---@return string[]
local function merge_tags(tags, extra)
    local merged = vim.list_slice(tags)
    for _, tag in ipairs(extra) do
        if not vim.tbl_contains(merged, tag) then
            merged[#merged + 1] = tag
        end
    end
    return merged
end

---@param analysis fastapi.FileAnalysis
---@param name string
---@return fastapi.Import?, { name: string, alias: string? }?
local function find_import(analysis, name)
    for _, import in ipairs(analysis.imports) do
        for _, item in ipairs(import.names) do
            if (item.alias or item.name) == name then
                return import, item
            end
        end
    end
end

local build_internal, resolve_reference, expand

---@param ctx fastapi.GraphContext
---@param file string
---@return fastapi.FileAnalysis?
local function analyze(ctx, file)
    return extract.analyze(file, ctx.tick)
end

---@param analysis fastapi.FileAnalysis
---@param owner fastapi.RouterNode
---@param file string
---@param ctx fastapi.GraphContext
local function process_includes(analysis, owner, file, ctx)
    for _, include in ipairs(analysis.includes) do
        if include.owner == owner.var then
            local child = resolve_reference(include.router, analysis, file, ctx, "included")
            if child then
                if #include.tags > 0 then
                    child.tags = merge_tags(child.tags, include.tags)
                end
                table.insert(
                    owner.children,
                    { node = child, prefix = include.prefix, tags = include.tags }
                )
            end
        end
    end
end

-- Mounts owned by `owner`; with `all`, also the mounts whose owner is not another app of the file,
-- so that a root reached through a factory keeps the mounts of its inner variable.
---@param analysis fastapi.FileAnalysis
---@param owner fastapi.RouterNode
---@param file string
---@param ctx fastapi.GraphContext
---@param all boolean?
local function process_mounts(analysis, owner, file, ctx, all)
    local apps = {}
    for _, router in ipairs(analysis.routers) do
        if router.kind == "FastAPI" then
            apps[router.var] = true
        end
    end
    for _, mount in ipairs(analysis.mounts) do
        if mount.owner == owner.var or (all and not apps[mount.owner]) then
            local child = resolve_reference(mount.app, analysis, file, ctx, "mounted")
            if child then
                table.insert(owner.children, { node = child, prefix = mount.path, tags = {} })
            end
        end
    end
end

---@param node fastapi.RouterNode
---@param analysis fastapi.FileAnalysis
---@param file string
---@param ctx fastapi.GraphContext
---@return fastapi.RouterNode
function expand(node, analysis, file, ctx)
    process_includes(analysis, node, file, ctx)
    if node.kind == "FastAPI" then
        process_mounts(analysis, node, file, ctx)
    end
    return node
end

-- The app that a function of the file creates, for `app = create_app()`.
---@param analysis fastapi.FileAnalysis
---@param callee string
---@return fastapi.RouterDecl?
local function local_factory_app(analysis, callee)
    for _, router in ipairs(analysis.routers) do
        if router.kind == "FastAPI" and router.factory == callee then
            return router
        end
    end
end

-- `app.mount("/api", create_api())`: the app that the factory, local or imported, builds.
---@param callee string  `create_api` or `module.create_api`
---@param analysis fastapi.FileAnalysis
---@param file string
---@param ctx fastapi.GraphContext
---@return fastapi.RouterNode?
local function resolve_factory_call(callee, analysis, file, ctx)
    local router = local_factory_app(analysis, callee)
    if router then
        local key = file .. "#" .. router.var
        if ctx.visited[key] then
            return nil
        end
        ctx.visited[key] = true
        return expand(new_node(router, analysis, file), analysis, file, ctx)
    end
    local import, item = find_import(analysis, (callee:match("^[^.]+")))
    local target = import and item and imports.resolve_named(import, item.name, file, ctx.root)
    return target and build_internal(target, ctx)
end

---@param reference string  `router`, `module.router`, or for a mount `factory()`
---@param analysis fastapi.FileAnalysis
---@param file string
---@param ctx fastapi.GraphContext
---@param kind "included"|"mounted"
---@return fastapi.RouterNode?
function resolve_reference(reference, analysis, file, ctx, kind)
    local callee = reference:match("^([%w_.]+)%s*%(.*%)$")
    if callee then
        return kind == "mounted" and resolve_factory_call(callee, analysis, file, ctx) or nil
    end
    local name, attribute = reference:match("^([^.]+)%.?(.*)$")
    for _, router in ipairs(analysis.routers) do
        if router.var == name and router.kind == "APIRouter" then
            return expand(new_node(router, analysis, file), analysis, file, ctx)
        elseif router.var == name and kind == "mounted" and attribute == "" then
            local key = file .. "#" .. name
            if ctx.visited[key] then
                return nil
            end
            ctx.visited[key] = true
            return expand(new_node(router, analysis, file), analysis, file, ctx)
        end
    end
    local import, item = find_import(analysis, name)
    if not (import and item) then
        return nil
    end
    local target, original = imports.resolve_named(import, item.name, file, ctx.root)
    if not target then
        return nil
    end
    if attribute ~= "" then
        local target_analysis = analyze(ctx, target)
        local router = target_analysis and find_app_router(target_analysis.routers, attribute)
        if not router and kind == "included" and target_analysis then
            router = infer_included_router(target_analysis, attribute)
        end
        if router and target_analysis then
            local key = target .. "#" .. attribute
            if ctx.visited[key] then
                return nil
            end
            ctx.visited[key] = true
            return expand(new_node(router, target_analysis, target), target_analysis, target, ctx)
        end
    end
    return build_internal(target, ctx, original or item.name)
end

---@param analysis fastapi.FileAnalysis
---@param var string
---@return fastapi.RouterDecl?
local function infer_factory_app(analysis, var)
    for _, route in ipairs(analysis.routes) do
        if route.owner == var then
            return { var = var, kind = "FastAPI", prefix = "", tags = {}, line = 0, col = 0 }
        end
    end
    for _, call in ipairs(analysis.call_assignments) do
        if call.var == var then
            return local_factory_app(analysis, call.callee)
        end
    end
end

-- `app = build_server()` with `build_server` imported: a declaration for `app`, and the graph of the
-- app that the factory creates, when the factory assigns it to a variable.
---@param entry string
---@param analysis fastapi.FileAnalysis
---@param var string
---@param ctx fastapi.GraphContext
---@return fastapi.RouterDecl?, fastapi.RouterNode?
local function imported_factory(entry, analysis, var, ctx)
    for _, call in ipairs(analysis.call_assignments) do
        local import, item = find_import(analysis, call.callee)
        if call.var == var and import and item then
            local decl = {
                var = var,
                kind = "FastAPI",
                prefix = "",
                tags = {},
                line = call.line,
                col = call.col,
            }
            local file = imports.resolve_named(import, item.name, entry, ctx.root)
            local target = file and analyze(ctx, file)
            local made = target and local_factory_app(target, item.name)
            return decl, made and build_internal(assert(file), ctx, made.var)
        end
    end
end

---@param init_file string
---@param ctx fastapi.GraphContext
---@return string?, fastapi.FileAnalysis?
local function router_file_behind_init(init_file, ctx)
    local analysis = analyze(ctx, init_file)
    if not analysis or #analysis.routers > 0 then
        return nil
    end
    local file = imports.resolve_reexport(init_file, "router", ctx.root)
    if file and not ctx.visited[file] then
        ctx.visited[file] = true
        return file, analyze(ctx, file)
    end
end

---@param entry string
---@param ctx fastapi.GraphContext
---@param var string?
---@return fastapi.RouterNode?
function build_internal(entry, ctx, var)
    local key = entry .. "#" .. (var or "")
    if not vim.uv.fs_stat(entry) or ctx.visited[key] then
        return nil
    end
    ctx.visited[key] = true
    local analysis = analyze(ctx, entry)
    if not analysis then
        return nil
    end
    local file = entry
    local router = find_app_router(analysis.routers, var)
    if not router and vim.endswith(entry, "__init__.py") then
        local behind, behind_analysis = router_file_behind_init(entry, ctx)
        local behind_router = behind_analysis and find_app_router(behind_analysis.routers)
        if behind and behind_analysis and behind_router then
            file, analysis, router = behind, behind_analysis, behind_router
        end
    end
    local factory
    if not router and var then
        router, factory = imported_factory(entry, analysis, var, ctx)
        router = router or infer_factory_app(analysis, var)
    end
    if not router then
        return nil
    end
    ctx.visited[file .. "#" .. router.var] = true
    local root = new_node(router, analysis, file)
    if factory then
        table.insert(root.children, { node = factory, prefix = "", tags = {} })
    end
    process_includes(analysis, root, file, ctx)
    process_mounts(analysis, root, file, ctx, true)
    return root
end

---@param entry_file string
---@param root string  project root, from `imports.project_root`
---@param var string?
---@param tick fun()?  called before each file that has to be parsed, so that a caller can yield
---@return fastapi.RouterNode?
function M.build(entry_file, root, var, tick)
    return build_internal(entry_file, { root = root, visited = {}, tick = tick }, var)
end

return M
