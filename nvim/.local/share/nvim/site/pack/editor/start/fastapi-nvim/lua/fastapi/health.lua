-- :checkhealth fastapi
local M = {}

---@return string?
local function rg_version()
    local ok, result = pcall(function()
        return vim.system({ "rg", "--version" }, { text = true }):wait()
    end)
    return ok and vim.split(result.stdout or "", "\n", { plain = true })[1] or nil
end

local function check_requirements()
    local version = require("fastapi").version
    vim.health.ok("fastapi.nvim " .. version)
    local nvim = vim.version()
    if vim.fn.has("nvim-0.12") == 1 then
        vim.health.ok(("Neovim %d.%d.%d"):format(nvim.major, nvim.minor, nvim.patch))
    else
        vim.health.error("Neovim 0.12 or newer is required")
    end
    if require("fastapi.core.ts").has_parser() then
        vim.health.ok("python tree-sitter parser")
    else
        vim.health.error(
            "python tree-sitter parser not found",
            "Install the python parser so that `vim.treesitter.language.add('python')` succeeds, see the README"
        )
    end
    if vim.fn.executable("rg") == 1 then
        vim.health.ok(rg_version() or "ripgrep")
    else
        vim.health.error(
            "ripgrep (rg) not found in PATH",
            "Install ripgrep. Without it app discovery (unless pyproject.toml sets an entrypoint) and the test lenses and jumps do not work"
        )
    end
end

local function check_apps()
    local state = require("fastapi.state")
    state.get()
    vim.wait(5000, function()
        return state.get().status == "idle"
    end, 10)
    local snapshot = state.get()
    for _, app in ipairs(snapshot.apps) do
        vim.health.ok(
            ("%s (%s) %s"):format(app.name, app.source, vim.fn.fnamemodify(app.file, ":."))
        )
    end
    for _, err in ipairs(snapshot.errors) do
        vim.health.error(err)
    end
    if #snapshot.apps == 0 then
        vim.health.warn("No FastAPI app found in " .. snapshot.workspace)
    end
end

function M.check()
    vim.health.start("fastapi.nvim")
    check_requirements()
    vim.health.start("fastapi.nvim apps")
    check_apps()
end

return M
