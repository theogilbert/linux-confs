local tree = require("nvim-tree.api").tree
local FzfLua = require("fzf-lua")

local M = {}

---@class SearchOptions
---@field resume boolean|nil If true, the previously searched pattern will be used again

---Search text with grep.
---
---@param opts SearchOptions|nil Options
function M.grep(opts)
    local resume = opts and opts.resume or false
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

    FzfLua.live_grep({ cwd = cwd, resume = resume })
end


return M
