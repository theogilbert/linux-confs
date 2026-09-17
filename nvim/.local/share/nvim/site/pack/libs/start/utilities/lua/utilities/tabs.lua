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

---Snapshots of the tabs closed with M.close_current_tab(), oldest first.
local closed = {}

---Turn a `winlayout()` tree into one that outlives its windows.
---
---@param node table
---@return table
local function snapshot(node)
    if node[1] == "leaf" then
        local win = node[2]
        return { "leaf", buf = vim.api.nvim_win_get_buf(win), cursor = vim.api.nvim_win_get_cursor(win) }
    end
    local children = {}
    for _, child in ipairs(node[2]) do
        table.insert(children, snapshot(child))
    end
    return { node[1], children }
end

---Rebuild a snapshot inside a window: a leaf shows its buffer again, a row
---or column splits the window as many times as it has children.
---
---@param node table
---@param win integer
local function restore(node, win)
    if node[1] == "leaf" then
        if vim.api.nvim_buf_is_valid(node.buf) then
            vim.api.nvim_win_set_buf(win, node.buf)
            pcall(vim.api.nvim_win_set_cursor, win, node.cursor)
        end
        return
    end
    local wins = { win }
    for i = 2, #node[2] do
        wins[i] = vim.api.nvim_open_win(vim.api.nvim_win_get_buf(wins[i - 1]), false, {
            split = node[1] == "row" and "right" or "below",
            win = wins[i - 1],
        })
    end
    for i, child in ipairs(node[2]) do
        restore(child, wins[i])
    end
end

---Close the current tab, remembering its name, windows and buffers so that
---M.reopen_closed_tab() can bring it back.
function M.close_current_tab()
    table.insert(closed, {
        name = vim.t.tabname,
        layout = snapshot(vim.fn.winlayout()),
    })
    vim.cmd("tabclose")
end

---Reopen the tab closed last, as a new tab at the end of the tabline with
---the same windows, buffers and name. Buffers wiped since are left empty.
function M.reopen_closed_tab()
    local tab = table.remove(closed)
    if not tab then
        vim.notify("No closed tab to reopen", vim.log.levels.INFO)
        return
    end
    vim.cmd("$tabnew")
    vim.t.tabname = tab.name
    restore(tab.layout, vim.api.nvim_get_current_win())
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
