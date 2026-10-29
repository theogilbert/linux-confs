-- Project root detection and static resolution of Python imports to files.
local extract = require("fastapi.core.extract")
local paths = require("fastapi.core.paths")

local M = {}

---@param path string
---@return boolean
local function is_file(path)
    local stat = vim.uv.fs_stat(path)
    return stat ~= nil and stat.type == "file"
end

---@param dir string
---@param workspace string
---@return string?
local function nearest_pyproject(dir, workspace)
    while paths.is_within(dir, workspace) do
        if is_file(dir .. "/pyproject.toml") then
            return dir
        end
        if dir == workspace then
            return nil
        end
        dir = vim.fs.dirname(dir)
    end
end

---@param entry_file string
---@param workspace string
---@return string
function M.project_root(entry_file, workspace)
    workspace = vim.fs.normalize(workspace)
    local dir = vim.fs.dirname(entry_file)
    if not is_file(dir .. "/__init__.py") then
        return nearest_pyproject(dir, workspace) or dir
    end
    while paths.is_within(dir, workspace) and dir ~= workspace do
        local parent = vim.fs.dirname(dir)
        if not is_file(parent .. "/__init__.py") then
            return parent
        end
        dir = parent
    end
    return workspace
end

---@param base string
---@return string?
local function module_file(base)
    for _, candidate in ipairs({ base .. ".py", base .. "/__init__.py" }) do
        if is_file(candidate) then
            return candidate
        end
    end
end

---@param import fastapi.Import
---@param from_file string
---@param root string
---@return string
local function module_dir(import, from_file, root)
    local dir = root
    if import.level > 0 then
        dir = vim.fs.dirname(from_file)
        for _ = 2, import.level do
            dir = vim.fs.dirname(dir)
        end
    end
    if import.module == "" then
        return dir
    end
    return dir .. "/" .. import.module:gsub("%.", "/")
end

---@param import fastapi.Import
---@param from_file string
---@param root string
---@return string?
function M.resolve(import, from_file, root)
    local found = module_file(module_dir(import, from_file, root))
    if found or import.level > 0 then
        return found
    end
    return module_file(module_dir(import, from_file, root .. "/src"))
end

---@param file string
---@param name string
---@return fastapi.Import?
local function reexporting_import(file, name)
    local analysis = extract.analyze(file)
    for _, import in ipairs(analysis and analysis.imports or {}) do
        for _, item in ipairs(import.names) do
            if (item.alias or item.name) == name then
                return import
            end
        end
    end
end

---@param init_file string  a package's __init__.py
---@param name string
---@param root string
---@return string?
function M.resolve_reexport(init_file, name, root)
    local import = reexporting_import(init_file, name)
    return import and M.resolve(import, init_file, root)
end

---@param import fastapi.Import
---@param name string
---@param from_file string
---@param root string
---@return string?
function M.resolve_named(import, name, from_file, root)
    local base = M.resolve(import, from_file, root)
    local is_init = base ~= nil and vim.endswith(base, "/__init__.py")
    if base == nil or is_init then
        local dir = base and vim.fs.dirname(base) or module_dir(import, from_file, root)
        local submodule = module_file(dir .. "/" .. name:gsub("%.", "/"))
        if submodule then
            return submodule
        end
    end
    return is_init and M.resolve_reexport(assert(base), name, root) or base
end

return M
