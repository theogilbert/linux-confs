-- [[ Basic Keymaps ]]
--  See `:help vim.keymap.set()`

-- Clear highlights on search when pressing <Esc> in normal mode
--  See `:help hlsearch`
vim.keymap.set("n", "<Esc>", "<cmd>nohlsearch<CR>")

-- If the number column is displayed, hide it and hide the sign column
-- Otherwise, display both.
function toggleGutter()
    isGutterDisplayed = vim.opt.number:get()

    vim.opt.number = not isGutterDisplayed
    vim.opt.signcolumn = isGutterDisplayed and "no" or "yes"
end
vim.keymap.set("n", "<Leader>n", toggleGutter)

