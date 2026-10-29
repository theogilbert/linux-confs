-- Turns a router tree into an app with full paths and a prefix hierarchy of routers.
local extract = require("fastapi.core.extract")
local paths = require("fastapi.core.paths")

local M = {}

---@alias fastapi.Method "GET"|"POST"|"PUT"|"PATCH"|"DELETE"|"OPTIONS"|"HEAD"|"WEBSOCKET"

---@class fastapi.Location
---@field file string    absolute path
---@field line integer   1-based
---@field col integer    0-based

---@class fastapi.Route
---@field method fastapi.Method
---@field path string           full path, prefixes included
---@field func string
---@field location fastapi.Location
---@field deprecated boolean
---@field docstring string?

---@class fastapi.Router
---@field name string
---@field prefix string         full prefix
---@field tags string[]
---@field location fastapi.Location
---@field routes fastapi.Route[]
---@field children fastapi.Router[]

---@class fastapi.App
---@field name string           variable name
---@field file string
---@field source "pyproject"|"search"
---@field routers fastapi.Router[]
---@field routes fastapi.Route[]  routes declared directly on the app

---@param route fastapi.RouteDecl
---@param prefix string
---@param file string
---@return fastapi.Route
local function to_route(route, prefix, file)
    local method = route.method:lower()
    return {
        method = extract.HTTP_METHODS[method] and method:upper() or "GET",
        path = prefix .. route.path,
        func = route.func,
        location = { file = file, line = route.line + 1, col = route.col },
        deprecated = route.deprecated == true,
        docstring = route.docstring,
    }
end

---@param node fastapi.RouterNode
---@param prefix string
---@param file string
---@return fastapi.Route[]
local function to_routes(node, prefix, file)
    return vim.tbl_map(function(route)
        return to_route(route, prefix, file)
    end, node.routes)
end

---@param node fastapi.RouterNode
---@param parent_prefix string
---@param out fastapi.Router[]
local function collect_flat(node, parent_prefix, out)
    local prefix = parent_prefix .. node.prefix
    local routes = to_routes(node, prefix, node.file)
    if node.kind == "APIRouter" and #routes > 0 then
        table.insert(out, {
            name = node.var,
            prefix = prefix,
            tags = node.tags,
            location = { file = node.file, line = node.line + 1, col = node.col },
            routes = routes,
            children = {},
        })
    end
    for _, child in ipairs(node.children) do
        collect_flat(child.node, prefix .. child.prefix, out)
    end
end

---@param prefix string  dynamic prefix already stripped
---@param by_prefix table<string, fastapi.Router>
---@return fastapi.Router?
local function find_parent(prefix, by_prefix)
    for count = paths.count_segments(prefix) - 1, 1, -1 do
        local parent = by_prefix[paths.segments(prefix, count)]
        if parent then
            return parent
        end
    end
end

---@param routers fastapi.Router[]
---@param router fastapi.Router
---@param prefix string
---@return boolean
local function has_sibling_under(routers, router, prefix)
    local group = paths.segments(prefix, 1)
    for _, other in ipairs(routers) do
        local other_prefix = paths.strip_dynamic_prefix(other.prefix)
        if
            other ~= router
            and other_prefix ~= prefix
            and paths.count_segments(other_prefix) >= 2
            and paths.segments(other_prefix, 1) == group
        then
            return true
        end
    end
    return false
end

---@param router fastapi.Router
---@return fastapi.Router
local function new_group(router)
    local prefix = paths.segments(paths.strip_dynamic_prefix(router.prefix), 1)
    return {
        name = prefix:sub(2),
        prefix = prefix,
        tags = {},
        location = router.location,
        routes = {},
        children = {},
    }
end

---@param router fastapi.Router
---@param sorted fastapi.Router[]
---@param by_prefix table<string, fastapi.Router>
---@param roots fastapi.Router[]
local function place(router, sorted, by_prefix, roots)
    local prefix = paths.strip_dynamic_prefix(router.prefix)
    local depth = paths.count_segments(prefix)
    local parent
    if depth > 0 then
        local existing = by_prefix[prefix]
        if existing then
            vim.list_extend(existing.routes, router.routes)
            vim.list_extend(existing.children, router.children)
            return
        end
        parent = find_parent(prefix, by_prefix)
        if not parent and depth >= 2 and has_sibling_under(sorted, router, prefix) then
            parent = new_group(router)
            by_prefix[parent.prefix] = parent
            table.insert(roots, parent)
        end
    end
    table.insert(parent and parent.children or roots, router)
    by_prefix[prefix] = router
end

---@param router fastapi.Router
---@return integer
local function depth_of(router)
    return paths.count_segments(paths.strip_dynamic_prefix(router.prefix))
end

---@param flat fastapi.Router[]
---@return fastapi.Router[]
local function build_hierarchy(flat)
    local order = {}
    for i, router in ipairs(flat) do
        order[router] = i
    end
    local sorted = vim.list_slice(flat)
    table.sort(sorted, function(a, b)
        if depth_of(a) ~= depth_of(b) then
            return depth_of(a) < depth_of(b)
        end
        return order[a] < order[b]
    end)
    local by_prefix, roots = {}, {}
    for _, router in ipairs(sorted) do
        place(router, sorted, by_prefix, roots)
    end
    return vim.tbl_filter(function(router)
        return #router.routes > 0 or #router.children > 0
    end, roots)
end

---@param routers fastapi.Router[]
---@param out fastapi.Route[]
local function collect_router_routes(routers, out)
    for _, router in ipairs(routers) do
        vim.list_extend(out, router.routes)
        collect_router_routes(router.children, out)
    end
end

---@param apps fastapi.App[]
---@return fastapi.Route[]
function M.collect_routes(apps)
    local routes = {}
    for _, app in ipairs(apps) do
        vim.list_extend(routes, app.routes)
        collect_router_routes(app.routers, routes)
    end
    return routes
end

---@param node fastapi.RouterNode
---@param source "pyproject"|"search"
---@return fastapi.App
function M.to_app(node, source)
    local flat = {}
    for _, child in ipairs(node.children) do
        collect_flat(child.node, node.prefix .. child.prefix, flat)
    end
    return {
        name = node.var,
        file = node.file,
        source = source,
        routers = build_hierarchy(flat),
        routes = to_routes(node, node.prefix, node.file),
    }
end

return M
