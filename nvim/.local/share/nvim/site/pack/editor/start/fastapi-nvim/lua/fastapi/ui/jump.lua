-- Opening locations and jumping between a route and the tests that call it.
local state = require("fastapi.state")

local M = {}

---@param location fastapi.Location
function M.open(location)
    vim.cmd("normal! m'")
    local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(location.file))
    if not ok then
        vim.notify("fastapi.nvim: " .. tostring(err), vim.log.levels.ERROR)
        return
    end
    vim.api.nvim_win_set_cursor(0, { location.line, location.col })
    vim.cmd("normal! zz")
end

---@param message string
local function notify(message)
    vim.notify("fastapi.nvim: " .. message, vim.log.levels.INFO)
end

---@param items { location: fastapi.Location }[]
---@param opts { prompt: string, kind: string }
---@param segments_of fun(item: any): fastapi.Segment[]
local function choose(items, opts, segments_of)
    if #items == 1 then
        M.open(items[1].location)
        return
    end
    require("fastapi.ui.picker").choose(items, opts, segments_of)
end

---@param entry { routes: fastapi.Route[], calls: fastapi.TestCall[] }
---@param line integer
---@return fastapi.TestCall[]
local function calls_on_line(entry, line)
    return vim.tbl_filter(function(call)
        return call.location.line == line
    end, entry.calls)
end

---@param buf integer
---@param pos integer[]  0-based row and column
---@return TSNode?
local function node_at(buf, pos)
    local ok, parser = pcall(vim.treesitter.get_parser, buf, "python")
    if not (ok and parser) then
        return nil
    end
    parser:parse()
    return vim.treesitter.get_node({ bufnr = buf, pos = pos })
end

---@param entry { routes: fastapi.Route[], calls: fastapi.TestCall[] }
---@param buf integer
---@param pos integer[]  0-based row and column
---@return fastapi.Route[]
local function routes_at(entry, buf, pos)
    local node = node_at(buf, pos)
    while node do
        if node:type() == "decorated_definition" then
            local line = node:start() + 1
            local found = vim.tbl_filter(function(route)
                return route.location.line == line
            end, entry.routes)
            if #found > 0 then
                return found
            end
        end
        node = node:parent()
    end
    return {}
end

---@param snapshot fastapi.Snapshot
---@param locations table<fastapi.Location, true>
---@return fastapi.TestCall[]
local function calls_at(snapshot, locations)
    local found = {}
    local files = vim.tbl_keys(snapshot.index)
    table.sort(files)
    for _, file in ipairs(files) do
        for _, call in ipairs(snapshot.index[file]) do
            if locations[call.location] then
                found[#found + 1] = call
            end
        end
    end
    return found
end

---@param snapshot fastapi.Snapshot
---@param calls fastapi.TestCall[]
local function jump_to_routes(snapshot, calls)
    local picker = require("fastapi.ui.picker")
    local routes = {}
    for _, call in ipairs(calls) do
        for _, route in ipairs(snapshot.links.routes_by_call[call] or {}) do
            if not vim.tbl_contains(routes, route) then
                routes[#routes + 1] = route
            end
        end
    end
    if #routes == 0 then
        return notify("no route matches this call")
    end
    choose(routes, { prompt = "FastAPI routes", kind = "fastapi.route" }, function(route)
        return picker.route_segments(route, snapshot.apps)
    end)
end

---@param snapshot fastapi.Snapshot
---@param routes fastapi.Route[]
local function jump_to_tests(snapshot, routes)
    local locations = {}
    for _, route in ipairs(routes) do
        for _, location in ipairs(snapshot.links.calls_by_route[route] or {}) do
            locations[location] = true
        end
    end
    local calls = calls_at(snapshot, locations)
    if #calls == 0 then
        return notify("no test calls this route")
    end
    choose(
        calls,
        { prompt = "FastAPI tests", kind = "fastapi.test_call" },
        require("fastapi.ui.picker").call_segments
    )
end

function M.jump()
    local snapshot = state.get()
    state.need_rg("tests")
    local buf = vim.api.nvim_get_current_buf()
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    local entry = snapshot.by_file[vim.api.nvim_buf_get_name(buf)]
    local calls = entry and calls_on_line(entry, row) or {}
    local routes = entry and #calls == 0 and routes_at(entry, buf, { row - 1, col }) or {}
    if #calls > 0 then
        jump_to_routes(snapshot, calls)
    elseif #routes > 0 then
        jump_to_tests(snapshot, routes)
    elseif snapshot.status == "scanning" then
        notify("still scanning, try again in a moment")
    else
        notify("no route or test call under the cursor")
    end
end

return M
