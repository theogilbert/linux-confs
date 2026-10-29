-- Finds FastAPI apps of a workspace: a pyproject entrypoint, else a ripgrep search.
local extract = require("fastapi.core.extract")
local graph = require("fastapi.core.graph")
local imports = require("fastapi.core.imports")
local paths = require("fastapi.core.paths")
local rg = require("fastapi.core.rg")
local testindex = require("fastapi.core.testindex")

local M = {}

---@class fastapi.DiscoveredApp
---@field file string
---@field var string
---@field source "pyproject"|"search"

---@param path string
---@return string?
local function read(path)
    local file = io.open(path, "r")
    if not file then
        return nil
    end
    local text = file:read("*a")
    file:close()
    return text
end

-- Understands only the `entrypoint` key of the `[tool.fastapi]` table.
---@param toml string
---@return string?
local function entrypoint_value(toml)
    local in_table = false
    for line in vim.gsplit(toml, "\n", { plain = true }) do
        local header = line:match("^%s*%[([^%]]+)%]")
        if header then
            in_table = vim.trim(header) == "tool.fastapi"
        elseif in_table then
            local quote, value = line:match("^%s*entrypoint%s*=%s*([\"'])(.-)%1")
            if quote then
                return value
            end
        end
    end
end

---@param workspace string
---@param module string  dotted
---@return string?
local function module_file(workspace, module)
    local rel = module:gsub("%.", "/")
    for _, base in ipairs({ workspace, workspace .. "/src" }) do
        for _, candidate in ipairs({
            base .. "/" .. rel .. ".py",
            base .. "/" .. rel .. "/__init__.py",
        }) do
            if vim.uv.fs_stat(candidate) then
                return candidate
            end
        end
    end
end

---@param workspace string
---@return fastapi.DiscoveredApp?, string?
function M.entrypoint(workspace)
    local toml = read(workspace .. "/pyproject.toml")
    local value = toml and entrypoint_value(toml)
    if not value then
        return nil
    end
    local module, var = value:match("^([^:]+):?(.*)$")
    local file = module_file(workspace, module)
    if not file then
        return nil, ("fastapi entrypoint %s not found"):format(value)
    end
    if var == "" then
        local analysis = extract.analyze(file)
        for _, router in ipairs(analysis and analysis.routers or {}) do
            if router.kind == "FastAPI" then
                return { file = file, var = router.var, source = "pyproject" }
            end
        end
        return nil, ("no FastAPI app in %s"):format(file)
    end
    return { file = file, var = var, source = "pyproject" }
end

---@param workspace string
---@param opts { exclude_dirs: string[] }
---@param cb fun(files: string[]?, err: string?)
function M.candidates(workspace, opts, cb)
    local args = { "--files-with-matches", "--type", "py" }
    for _, dir in ipairs(opts.exclude_dirs) do
        vim.list_extend(args, { "-g", "!" .. dir })
    end
    vim.list_extend(args, { "-e", "\\bFastAPI\\b" })
    rg.files(args, workspace, function(files, err)
        if not files then
            return cb(nil, err)
        end
        cb(vim.tbl_filter(function(file)
            return not testindex.is_test_file(file)
        end, files))
    end)
end

---@param path string
---@return fastapi.DiscoveredApp[]
function M.apps_in_file(path)
    local analysis = extract.analyze(path)
    local apps = {}
    for _, router in ipairs(analysis and analysis.routers or {}) do
        if router.kind == "FastAPI" then
            apps[#apps + 1] = { file = path, var = router.var, source = "search" }
        end
    end
    return apps
end

---@param node fastapi.RouterNode
---@param mounted table<string, true>
local function collect_sub_apps(node, mounted)
    for _, child in ipairs(node.children) do
        if child.node.kind == "FastAPI" then
            mounted[child.node.file .. "#" .. child.node.var] = true
        end
        collect_sub_apps(child.node, mounted)
    end
end

---@param app fastapi.DiscoveredApp
---@return string
local function key_of(app)
    return app.file .. "#" .. app.var
end

---@param apps fastapi.DiscoveredApp[]
---@param workspace string
---@param tick fun()?  see `graph.build`
---@return fastapi.DiscoveredApp[]
function M.finalize(apps, workspace, tick)
    local unique, seen = {}, {}
    for _, app in ipairs(apps) do
        if not seen[key_of(app)] then
            seen[key_of(app)] = true
            unique[#unique + 1] = app
        end
    end
    local mounted = {}
    for _, app in ipairs(unique) do
        local node = graph.build(app.file, imports.project_root(app.file, workspace), app.var, tick)
        if node then
            collect_sub_apps(node, mounted)
        end
    end
    local kept = vim.tbl_filter(function(app)
        return not mounted[key_of(app)]
    end, unique)
    table.sort(kept, function(a, b)
        local depth_a, depth_b = paths.count_segments(a.file), paths.count_segments(b.file)
        if depth_a ~= depth_b then
            return depth_a < depth_b
        end
        return a.file < b.file
    end)
    return kept
end

return M
