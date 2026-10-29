-- Index of test client calls and their matching routes.
local app = require("fastapi.core.app")
local extract = require("fastapi.core.extract")
local paths = require("fastapi.core.paths")
local rg = require("fastapi.core.rg")

local M = {}

---@class fastapi.TestCall
---@field method string         lowercase, as written
---@field path string
---@field location fastapi.Location

---@alias fastapi.TestIndex table<string, fastapi.TestCall[]>

---@class fastapi.Links
---@field calls_by_route table<fastapi.Route, fastapi.Location[]>
---@field routes_by_call table<fastapi.TestCall, fastapi.Route[]>

---@param path string
---@return boolean
function M.is_test_file(path)
    local name = vim.fs.basename(path)
    return vim.endswith(name, ".py") and name:find("test", 1, true) ~= nil
end

---@param path string
---@param exclude_dirs string[]
---@return boolean
function M.is_ignored(path, exclude_dirs)
    for segment in path:gmatch("[^/]+") do
        if vim.tbl_contains(exclude_dirs, segment) then
            return true
        end
    end
    return false
end

---@param workspace string
---@param opts { exclude_dirs: string[] }
---@param cb fun(files: string[]?, err: string?)
function M.files(workspace, opts, cb)
    local args = { "--files", "--type", "py", "-g", "*test*.py" }
    for _, dir in ipairs(opts.exclude_dirs) do
        vim.list_extend(args, { "-g", "!" .. dir })
    end
    rg.files(args, workspace, cb)
end

---@param index fastapi.TestIndex
---@param path string
function M.update(index, path)
    local calls = M.is_test_file(path) and extract.test_calls(path)
    if not calls then
        index[path] = nil
        return
    end
    index[path] = vim.tbl_map(function(found)
        return {
            method = found.method,
            path = found.path,
            location = { file = path, line = found.line + 1, col = found.col },
        }
    end, calls)
end

---@param index fastapi.TestIndex
---@return string[]
local function sorted_files(index)
    local files = vim.tbl_keys(index)
    table.sort(files)
    return files
end

---@param method string
---@param other string
---@return boolean
local function same_method(method, other)
    return method:lower() == other:lower()
end

---@param index fastapi.TestIndex
---@param route fastapi.Route
---@return fastapi.Location[]
function M.calls_for_route(index, route)
    local locations = {}
    for _, file in ipairs(sorted_files(index)) do
        for _, call in ipairs(index[file]) do
            if same_method(call.method, route.method) and paths.matches(call.path, route.path) then
                locations[#locations + 1] = call.location
            end
        end
    end
    return locations
end

---@param apps fastapi.App[]
---@param call fastapi.TestCall
---@return fastapi.Route[]
function M.routes_for_call(apps, call)
    return vim.tbl_filter(function(route)
        return same_method(call.method, route.method) and paths.matches(call.path, route.path)
    end, app.collect_routes(apps))
end

---@class fastapi.LinkEntry
---@field route fastapi.Route
---@field segments string[]
---@field order integer

---@class fastapi.Bucket
---@field all fastapi.LinkEntry[]
---@field by_first table<string, fastapi.LinkEntry[]>  routes whose first segment is static
---@field dynamic fastapi.LinkEntry[]                  the others

---@param segments string[]
---@return string?  the first segment, when a route or call can be told apart by it
local function static_first(segments)
    return segments[1] and not paths.is_dynamic(segments[1]) and segments[1] or nil
end

---@param apps fastapi.App[]
---@return table<string, fastapi.Bucket>
local function bucket_routes(apps)
    local buckets = {}
    for order, route in ipairs(app.collect_routes(apps)) do
        local segments = paths.comparable_segments(route.path)
        local key = route.method:lower() .. ":" .. #segments
        local bucket = buckets[key] or { all = {}, by_first = {}, dynamic = {} }
        buckets[key] = bucket
        local entry = { route = route, segments = segments, order = order }
        table.insert(bucket.all, entry)
        local first = static_first(segments)
        local group = first and (bucket.by_first[first] or {}) or bucket.dynamic
        if first then
            bucket.by_first[first] = group
        end
        table.insert(group, entry)
    end
    return buckets
end

---@param bucket fastapi.Bucket
---@param segments string[]
---@return fastapi.Route[]
local function matching_routes(bucket, segments)
    local first = static_first(segments)
    local candidates = bucket.all
    if first and #bucket.dynamic == 0 then
        candidates = bucket.by_first[first] or {}
    elseif first then
        candidates = vim.list_extend(vim.list_slice(bucket.by_first[first] or {}), bucket.dynamic)
        table.sort(candidates, function(a, b)
            return a.order < b.order
        end)
    end
    local routes = {}
    for _, entry in ipairs(candidates) do
        if paths.segments_match(segments, entry.segments) then
            routes[#routes + 1] = entry.route
        end
    end
    return routes
end

-- Buckets by method, segment count and first segment: a call is only compared with routes that can match it.
---@param apps fastapi.App[]
---@param index fastapi.TestIndex
---@return fastapi.Links
function M.link(apps, index)
    local buckets = bucket_routes(apps)
    local links = { calls_by_route = {}, routes_by_call = {} }
    for _, file in ipairs(sorted_files(index)) do
        for _, call in ipairs(index[file]) do
            local segments = paths.comparable_segments(call.path:match("^[^?]*"))
            local bucket = buckets[call.method:lower() .. ":" .. #segments]
            local routes = bucket and matching_routes(bucket, segments) or {}
            for _, route in ipairs(routes) do
                links.calls_by_route[route] = links.calls_by_route[route] or {}
                table.insert(links.calls_by_route[route], call.location)
            end
            if #routes > 0 then
                links.routes_by_call[call] = routes
            end
        end
    end
    return links
end

return M
