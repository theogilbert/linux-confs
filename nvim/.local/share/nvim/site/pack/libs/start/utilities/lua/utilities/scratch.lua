local fzf = require("fzf-lua")

local H = {}
local M = {}

---Root of the scratch store. Scratch files are hand-written content, not a
---cache and not configuration. They live under the XDG state dir rather than
---the data dir because the latter is the versioned plugin store, and scratch
---files must stay out of that repository.
---
---@return string
function H.root()
    return vim.fs.joinpath(vim.fn.stdpath("state"), "scratches")
end

---Scratches used to live under the data dir. Move the whole store over,
---keeping it untouched if a store already exists at the new location.
function H.migrate_from_data_dir()
    local old_root = vim.fs.joinpath(vim.fn.stdpath("data"), "scratches")
    if vim.fn.isdirectory(old_root) == 0 then
        return
    end
    if vim.fn.isdirectory(H.root()) == 1 then
        vim.notify(
            ("Old scratch store %s kept: %s already exists"):format(old_root, H.root()),
            vim.log.levels.WARN
        )
        return
    end

    vim.fn.mkdir(vim.fs.dirname(H.root()), "p")
    local ok, err = os.rename(old_root, H.root())
    if not ok then
        vim.notify(("Could not move scratch store %s to %s: %s"):format(old_root, H.root(), err), vim.log.levels.ERROR)
    end
end

---Directory holding the scratches reachable from anywhere.
---
---@return string
function H.global_dir()
    return vim.fs.joinpath(H.root(), "global")
end

---Directory holding the scratches private to the current working directory.
---The cwd is hashed so that two projects sharing a basename never collide, and
---the basename is kept as a prefix so the store stays readable from a shell.
---
---@return string
function H.project_dir()
    local cwd = vim.fn.getcwd()
    local name = vim.fn.fnamemodify(cwd, ":t"):gsub("[^%w%-_.]", "_")
    if name == "" then
        name = "root"
    end
    return vim.fs.joinpath(H.root(), name .. "-" .. vim.fn.sha256(cwd):sub(1, 8))
end

---Scratches used to live directly under the root, before scopes existed. Move
---them into the global scope, otherwise the picker would never list them again.
function H.migrate_unscoped_scratches()
    for name, type in vim.fs.dir(H.root()) do
        if type == "file" then
            local source = vim.fs.joinpath(H.root(), name)
            local target = vim.fs.joinpath(H.global_dir(), name)
            if vim.fn.filereadable(target) == 1 then
                vim.notify(
                    ("Unscoped scratch %s kept: %s already exists"):format(source, target),
                    vim.log.levels.WARN
                )
            else
                os.rename(source, target)
            end
        end
    end
end

function M.setup()
    H.migrate_from_data_dir()
    vim.fn.mkdir(H.global_dir(), "p")
    H.migrate_unscoped_scratches()
end

---List the global scratches together with the ones private to the cwd.
function M.search_scratches()
    -- fd is given the scopes as search paths, so entries stay relative to the
    -- root and read as "<scope>/<name>". A scope directory only exists once it
    -- holds something, and listing must not be what creates it: fd would
    -- otherwise be asked to search a path that is not there.
    local scopes = {}
    for _, dir in ipairs({ H.global_dir(), H.project_dir() }) do
        if vim.fn.isdirectory(dir) == 1 then
            table.insert(scopes, vim.fn.shellescape(vim.fs.basename(dir)))
        end
    end

    if #scopes == 0 then
        vim.notify("No scratch file yet", vim.log.levels.INFO)
        return
    end

    fzf.files({
        cwd = H.root(),
        cmd = "fd --color=never --type f --type l . " .. table.concat(scopes, " "),
        winopts = { title = " Scratches " },
    })
end

---Ask which scope the new scratch belongs to, then for its name.
function M.prompt_new_file()
    vim.ui.select({ "project", "global" }, {
        prompt = "Scope of the scratch file",
        format_item = function(scope)
            if scope == "project" then
                return "Project - only listed from " .. vim.fn.getcwd()
            end
            return "Global - listed from any directory"
        end,
    }, function(scope)
        if scope == nil then
            return
        end

        H.prompt_name(scope == "project" and H.project_dir() or H.global_dir())
    end)
end

---@param dir string Scope directory the scratch is created in
---@param prompt string|nil Prompt to display, a default one if nil
---@param previous_filename string|nil Name to prefill the prompt with
function H.prompt_name(dir, prompt, previous_filename)
    prompt = prompt or "Name of the scratch file"

    vim.ui.input({ prompt = prompt, default = previous_filename }, function(filename)
        if filename == nil or filename == "" then
            return
        end

        local path = vim.fs.joinpath(dir, filename)
        if vim.fn.filereadable(path) == 1 then
            H.prompt_name(dir, "Filename already used. Please pick another name", filename)
            return
        end

        -- The name may itself hold a directory, e.g. "notes/monday.md".
        vim.fn.mkdir(vim.fs.dirname(path), "p")
        vim.cmd.edit(vim.fn.fnameescape(path))
    end)
end

return M
