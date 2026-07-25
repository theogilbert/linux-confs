local M = {}

-- Assign `name` to the current tab (as a tab-local variable). Displaying it
-- is left to a tabline that reads `vim.t.tabname`.
function M.name_current_tab(name)
    vim.t.tabname = name
end

-- Clear the current tab's assigned name and notify that it was cleared.
function M.clear_current_tab_name()
    vim.t.tabname = nil
    vim.notify("Tab name cleared")
end

-- Build the tabline string: each tab shows its assigned name
-- (`vim.t.tabname`, read via `gettabvar` since it lives on tabs other than
-- the current one too), falling back to the active buffer's name.
function M.render()
    local current = vim.fn.tabpagenr()
    local parts = {}

    for i = 1, vim.fn.tabpagenr("$") do
        local name = vim.fn.gettabvar(i, "tabname", "")
        if name == "" then
            local winnr = vim.fn.tabpagewinnr(i)
            local bufnr = vim.fn.tabpagebuflist(i)[winnr]
            name = vim.fn.fnamemodify(vim.fn.bufname(bufnr), ":t")
            if name == "" then
                name = "[No Name]"
            end
        end

        table.insert(parts, "%" .. i .. "T")
        table.insert(parts, i == current and "%#TabLineSel#" or "%#TabLine#")
        table.insert(parts, " " .. i .. ": " .. name .. " ")
    end

    table.insert(parts, "%#TabLineFill#")
    return table.concat(parts)
end

function M.setup()
    vim.api.nvim_create_user_command("TabName", function(opts)
        M.name_current_tab(opts.args)
    end, {
        nargs = 1,
        desc = "Assign a name to the current tab",
    })

    vim.api.nvim_create_user_command("TabClearName", M.clear_current_tab_name, {
        desc = "Clear the current tab's assigned name",
    })

    _G.utilities_tabs_render = M.render
    vim.o.tabline = "%!v:lua.utilities_tabs_render()"
end

return M
