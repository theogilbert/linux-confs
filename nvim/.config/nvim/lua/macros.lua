-- [[ Basic Autocommands ]]
--  See `:help lua-guide-autocommands`

-- Highlight when yanking (copying) text
--  Try it with `yap` in normal mode
--  See `:help vim.highlight.on_yank()`
vim.api.nvim_create_autocmd("TextYankPost", {
	desc = "Highlight when yanking (copying) text",
	group = vim.api.nvim_create_augroup("kickstart-highlight-yank", { clear = true }),
	callback = function()
		vim.highlight.on_yank()
	end,
})



local function set_hls()
    vim.api.nvim_set_hl(0, "Flash", { bg = "#e0af68", fg = "#1a1b26" })
end

set_hls()
vim.api.nvim_create_autocmd("ColorScheme", { callback = set_hls })

vim.api.nvim_create_autocmd("WinEnter", {
    callback = function()
        local win = vim.api.nvim_get_current_win()
        if not vim.api.nvim_win_is_valid(win) then
            return
        end

        local prev = vim.wo[win].winhighlight
        local flash = prev .. (prev ~= "" and "," or "") .. "CursorLine:Flash"
        vim.wo[win].winhighlight = flash

        -- Restore after short time, producing a flash effect
        vim.defer_fn(function()
            if vim.api.nvim_win_is_valid(win) then
                vim.wo[win].winhighlight = ""
            end
        end, 200)
    end,
})
