-- Labels and sort order of apps, routers and routes (pure).
local app = require("fastapi.core.app")
local paths = require("fastapi.core.paths")

local M = {}

local METHOD_ORDER = { "GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "HEAD", "WEBSOCKET" }
local GENERIC_APP_DIRS = { src = true, app = true }
local GENERIC_ROUTER_FILES = { router = true, routes = true }

---@param file string
---@return string
local function stem(file)
    return (vim.fs.basename(file):gsub("%.py$", ""))
end

---@param path string
---@return string?  the name of the directory that contains `path`, if it has one
local function parent_name(path)
    local name = vim.fs.basename(vim.fs.dirname(path))
    if name ~= "" and name ~= "." then
        return name
    end
end

---@param a fastapi.App
---@return string
function M.app_label(a)
    if a.name ~= "app" then
        return a.name
    end
    local parent = parent_name(a.file)
    local grandparent = parent and parent_name(vim.fs.dirname(a.file))
    if parent and not GENERIC_APP_DIRS[parent] then
        return parent
    elseif parent and grandparent then
        return grandparent .. "/" .. parent
    end
    return stem(a.file)
end

---@param router fastapi.Router
---@param parent_prefix string
---@return string
function M.router_label(router, parent_prefix)
    local prefix = paths.strip_dynamic_prefix(router.prefix)
    local label = prefix
    if parent_prefix ~= "/" then
        if vim.startswith(prefix, parent_prefix .. "/") then
            label = prefix:sub(#parent_prefix + 1)
        elseif vim.startswith(prefix, parent_prefix) then
            label = prefix:sub(#parent_prefix + 1)
            label = label == "" and "/" or label
        end
    end
    if label ~= "/" then
        return label
    end
    if #router.tags > 0 then
        return "/" .. router.tags[1]
    end
    local name = stem(router.location.file)
    if GENERIC_ROUTER_FILES[name] then
        return parent_name(router.location.file) or name
    end
    return name
end

---@param route fastapi.Route
---@return string
function M.route_label(route)
    local path = paths.strip_dynamic_prefix(route.path)
    return route.method == "WEBSOCKET" and path or (route.method .. " " .. path)
end

---@generic T
---@param list T[]
---@param less fun(a: T, b: T): boolean
---@return T[]
local function stable_sorted(list, less)
    local order = {}
    for i, item in ipairs(list) do
        order[item] = i
    end
    local sorted = vim.list_slice(list)
    table.sort(sorted, function(a, b)
        if less(a, b) then
            return true
        elseif less(b, a) then
            return false
        end
        return order[a] < order[b]
    end)
    return sorted
end

---@param routers fastapi.Router[]
---@return fastapi.Router[]
function M.sort_routers(routers)
    local function key(router)
        return M.router_label(router, "/"):lower()
    end
    return stable_sorted(routers, function(a, b)
        return key(a) < key(b)
    end)
end

---@param routes fastapi.Route[]
---@return fastapi.Route[]
function M.sort_routes(routes)
    local function priority(route)
        return vim.fn.index(METHOD_ORDER, route.method)
    end
    return stable_sorted(routes, function(a, b)
        if priority(a) ~= priority(b) then
            return priority(a) < priority(b)
        end
        return M.route_label(a):lower() < M.route_label(b):lower()
    end)
end

M.collect_routes = app.collect_routes

---@type { apps: fastapi.App[]?, owners: table<fastapi.Route, string> }
local memo = { owners = {} }

-- Memoized for the last `apps` only, since callers ask once per route.
---@param apps fastapi.App[]
---@return table<fastapi.Route, string>  the label of the app that owns each route
function M.route_owners(apps)
    if memo.apps ~= apps then
        memo = { apps = apps, owners = {} }
        for _, found in ipairs(apps) do
            for _, route in ipairs(app.collect_routes({ found })) do
                memo.owners[route] = M.app_label(found)
            end
        end
    end
    return memo.owners
end

---@param router fastapi.Router
---@return integer
function M.count_routes(router)
    local count = #router.routes
    for _, child in ipairs(router.children) do
        count = count + M.count_routes(child)
    end
    return count
end

return M
