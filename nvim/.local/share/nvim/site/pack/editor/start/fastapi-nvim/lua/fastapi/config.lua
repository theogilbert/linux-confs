-- Defaults, merging and validation of the user options.
local M = {}

---@class fastapi.Config
---@field explorer { position: "left"|"right", width: integer, keys: table<string, string> }
---@field lens { enabled: boolean, position: "above"|"eol" }
---@field refresh { debounce_ms: integer }
---@field register string
---@field exclude_dirs string[]

---@type fastapi.Config
local defaults = {
    explorer = {
        position = "right",
        width = 40,
        keys = {
            open = "<CR>",
            definition = "gd",
            copy = "y",
            toggle_all = "E",
            fold_toggle = "za",
            fold_open = "zo",
            fold_open_recursive = "zO",
            fold_close = "zc",
            fold_close_recursive = "zC",
            fold_open_all = "zR",
            fold_close_all = "zM",
            refresh = "R",
            search = "s",
            docs = "K",
            close = "q",
        },
    },
    lens = { enabled = true, position = "above" },
    refresh = { debounce_ms = 300 },
    register = "+",
    exclude_dirs = {
        ".venv",
        "venv",
        "__pycache__",
        "node_modules",
        ".git",
        ".mypy_cache",
        ".pytest_cache",
    },
}

---@type fastapi.Config
M.options = vim.deepcopy(defaults)

---@param value any
---@return boolean
local function is_string_list(value)
    return vim.islist(value)
        and vim.iter(value):all(function(item)
            return type(item) == "string"
        end)
end

---@param opts table
local function validate(opts)
    vim.validate("opts", opts, "table")
    local explorer, lens, refresh = opts.explorer or {}, opts.lens or {}, opts.refresh or {}
    vim.validate("explorer", opts.explorer, "table", true)
    vim.validate("explorer.position", explorer.position, function(value)
        return value == nil or value == "left" or value == "right"
    end, '"left" or "right"')
    vim.validate("explorer.width", explorer.width, "number", true)
    vim.validate("explorer.keys", explorer.keys, "table", true)
    for name, key in pairs(explorer.keys or {}) do
        vim.validate("explorer.keys." .. name, key, "string")
        vim.validate(
            "explorer.keys." .. name,
            defaults.explorer.keys[name],
            "string",
            false,
            "a known key name"
        )
    end
    vim.validate("lens", opts.lens, "table", true)
    vim.validate("lens.enabled", lens.enabled, "boolean", true)
    vim.validate("lens.position", lens.position, function(value)
        return value == nil or value == "above" or value == "eol"
    end, '"above" or "eol"')
    vim.validate("refresh", opts.refresh, "table", true)
    vim.validate("refresh.debounce_ms", refresh.debounce_ms, "number", true)
    vim.validate("register", opts.register, "string", true)
    vim.validate("exclude_dirs", opts.exclude_dirs, function(value)
        return value == nil or is_string_list(value)
    end, "a list of strings")
end

---@param opts? table
function M.setup(opts)
    opts = opts or {}
    validate(opts)
    M.options = vim.tbl_deep_extend("force", defaults, opts)
end

return M
