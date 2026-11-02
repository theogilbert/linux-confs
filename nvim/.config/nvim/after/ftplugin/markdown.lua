local md_table = require("utilities.markdown_table")
vim.keymap.set("n", "<leader>Mf", md_table.format_at_cursor, { buffer = true, desc = "[M]arkdown - [f]ormat table" })
vim.keymap.set("x", "<leader>Mf", md_table.format_selection, { buffer = true, desc = "[M]arkdown - [f]ormat table" })

-- `=` aligns the tables it covers (e.g. gg=G for the whole file) instead of
-- C-indenting, which is what native `=` falls back to in markdown.
local function equal_operator()
    vim.o.operatorfunc = "v:lua.require'utilities.markdown_table'.equal_operator"
    return "g@"
end
vim.keymap.set({ "n", "x" }, "=", equal_operator, { buffer = true, expr = true, desc = "Align tables" })
vim.keymap.set("n", "==", function() return equal_operator() .. "_" end,
    { buffer = true, expr = true, desc = "Align the table under the cursor" })
local notes_todo = require("notes-todo")
vim.keymap.set("n", "]t", notes_todo.next, { buffer = true, desc = "Next TODO" })
vim.keymap.set("n", "[t", notes_todo.prev, { buffer = true, desc = "Previous TODO" })
vim.keymap.set("n", "<leader>T", notes_todo.show, { buffer = true, desc = "List [T]ODOs" })
