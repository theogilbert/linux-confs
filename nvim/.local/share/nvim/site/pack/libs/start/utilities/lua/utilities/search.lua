local tree = require("nvim-tree.api").tree
local FzfLua = require("fzf-lua")

local H = {}
local M = {}

---@class SearchOptions
---@field resume boolean|nil If true, the previously searched pattern will be used again
---@field filetype boolean|nil If true, the user will be prompted for a filetype pattern before running the search

---Search text with grep.
---This is a slight addition over the fzflua.live_grep.
---If we are focused on the NvimTree pane, we limit the search to the directory
---under the cursor.
---
---@param opts SearchOptions|nil Options
function M.grep(opts)
    local resume = opts and opts.resume or false
    local filetype = opts and opts.filetype or false
    local cwd = nil  -- By default, search globally

    if tree.is_tree_buf(0) then
        -- If we are in the nvim-tree pane, search only under selected dir
        local curnode = tree.get_node_under_cursor()
        if vim.fn.filereadable(curnode.absolute_path) == 1 then
            cwd = vim.fs.dirname(curnode.absolute_path)
        else
            cwd = curnode.absolute_path
        end
    end

    if cwd ~= nil and not vim.fn.isdirectory(cwd) then
        vim.notify("Directory " .. cwd .. " does not exist on the filesystem")
        cwd = nil  -- If for some reason cwd doesn't exist on FS, ignore it.
    end

    local search_opts = { cwd = cwd, resume = resume }

    if cwd ~= nil then
        -- A directory picked in the tree is searched for what it holds, git
        -- ignored files included.
        search_opts.rg_opts = H.rg_opts("--no-ignore-vcs", search_opts.rg_opts)
    end

    if filetype then
        H.prompt_ft_and_search(search_opts)
    else
        FzfLua.live_grep(search_opts)
    end
end

---Prepend flags to the rg options a search runs with.
---
---@param flags string The flags to prepend
---@param opts string|nil The options to prepend to, fzf-lua's defaults if nil
---@return string
function H.rg_opts(flags, opts)
    return flags .. " " .. (opts or require('fzf-lua.defaults').defaults.grep.rg_opts)
end

function H.prompt_ft_and_search(search_opts)
    vim.ui.input(
        {prompt = "Specify a filetype to search across (e.g. 'py', 'md')" },
        function(filetype)
            if filetype == nil then
                return
            end

            search_opts.rg_opts = H.rg_opts("-t " .. filetype, search_opts.rg_opts)
            FzfLua.live_grep(search_opts)
        end
    )
end


    return M
