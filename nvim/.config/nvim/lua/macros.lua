-- [[ Basic Autocommands ]]
--  See `:help lua-guide-autocommands`

-- Highlight when yanking (copying) text
--  Try it with `yap` in normal mode
--  See `:help vim.highlight.on_yank()`
vim.api.nvim_create_autocmd("TextYankPost", {
	desc = "Highlight when yanking (copying) text",
	group = vim.api.nvim_create_augroup("highlight-yank", { clear = true }),
	callback = function()
		vim.highlight.on_yank()
	end,
})



local function set_hls()
    vim.api.nvim_set_hl(0, "Flash", { bg = "#e0af68", fg = "#1a1b26" })
    vim.api.nvim_set_hl(0, "CurrentCursorLine", { bg = "#505050" })
end

local FlashRule = "CursorLine:Flash"
local CurrentCLRule = "CursorLine:CurrentCursorLine"

local function set_winhl_rule(win, rule)
    if not vim.api.nvim_win_is_valid(win) then
        return
    end

    local prev = vim.wo[win].winhighlight

    if string.find(prev, rule, 1, true) then
        return  -- Rule already present
    end

    local flash = prev .. (prev ~= "" and "," or "") .. rule
    vim.wo[win].winhighlight = flash
end

local function clear_winhl_rule(win, rule)
    if not vim.api.nvim_win_is_valid(win) then
        return
    end

    local prev = vim.wo[win].winhighlight

    local new_rule = string.gsub(prev, rule, "")
    new_rule = string.gsub(new_rule, "^,", "")
    new_rule = string.gsub(new_rule, ",$", "")
    new_rule = string.gsub(new_rule, ",,", ",")
    vim.wo[win].winhighlight = new_rule
end


set_hls()
vim.api.nvim_create_autocmd("ColorScheme", { callback = set_hls })

vim.api.nvim_create_autocmd({"VimEnter", "WinEnter"}, {
    callback = function()
        local win = vim.api.nvim_get_current_win()

        set_winhl_rule(win, CurrentCLRule)
        set_winhl_rule(win, FlashRule)

        -- Remove flash rule after a short time, producing a flash effect
        vim.defer_fn(function() clear_winhl_rule(win, FlashRule) end, 200)
    end,
})

vim.api.nvim_create_autocmd("WinLeave", {
    callback = function()
        local win = vim.api.nvim_get_current_win()
        clear_winhl_rule(win, CurrentCLRule)
    end,
})

vim.api.nvim_create_autocmd("BufLeave", {
    callback = function()
        local win = vim.api.nvim_get_current_win()
        clear_winhl_rule(win, FlashRule)
    end,
})
