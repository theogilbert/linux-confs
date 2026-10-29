-- Defines :FastAPI, the <Plug> maps and the autocmds; every module is required lazily.
if vim.g.loaded_fastapi then
    return
end
vim.api.nvim_set_var("loaded_fastapi", 1)

local SUBCOMMANDS = { "explorer", "search", "refresh", "jump" }

vim.api.nvim_create_user_command("FastAPI", function(opts)
    local name = opts.fargs[1] or ""
    if not vim.tbl_contains(SUBCOMMANDS, name) then
        local message = ('fastapi.nvim: unknown subcommand "%s", expected one of: %s'):format(
            name,
            table.concat(SUBCOMMANDS, ", ")
        )
        vim.notify(message, vim.log.levels.ERROR)
        return
    end
    require("fastapi")[name]()
end, {
    nargs = "?",
    desc = "FastAPI routes: " .. table.concat(SUBCOMMANDS, ", "),
    complete = function(arglead)
        return vim.tbl_filter(function(name)
            return vim.startswith(name, arglead)
        end, SUBCOMMANDS)
    end,
})

for _, name in ipairs(SUBCOMMANDS) do
    vim.keymap.set("n", ("<Plug>(fastapi-%s)"):format(name), function()
        require("fastapi")[name]()
    end, { desc = "FastAPI: " .. name })
end

local group = vim.api.nvim_create_augroup("fastapi", { clear = true })

---@return table?  the state module, once something has loaded it and it holds a snapshot
local function active_state()
    local state = package.loaded["fastapi.state"]
    return state and state.exists() and state or nil
end

vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = { "*.py", "pyproject.toml" },
    callback = function(args)
        local state = active_state()
        if state then
            state.on_write(vim.api.nvim_buf_get_name(args.buf))
        end
    end,
})

vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "python",
    callback = function(args)
        if require("fastapi.config").options.lens.enabled then
            require("fastapi.ui.lens").attach(args.buf)
        end
    end,
})

vim.api.nvim_create_autocmd("DirChanged", {
    group = group,
    callback = function()
        local state = package.loaded["fastapi.state"]
        if state then
            state.reset()
        end
    end,
})

vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = function()
        local state = active_state()
        if state then
            state.on_focus()
        end
    end,
})
