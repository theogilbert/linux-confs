-- Highlight overrides on top of the colorscheme, re-applied when it changes.
local function set_hls()
    -- Window-enter flash and current window cursorline (see macros.lua)
    vim.api.nvim_set_hl(0, "Flash", { bg = "#e0af68", fg = "#1a1b26" })
    vim.api.nvim_set_hl(0, "CurrentCursorLine", { bg = "#505050" })
    vim.api.nvim_set_hl(0, "MiniStatuslineInactive", { fg = "#b0adb5", bg = "#49464e" })

    -- nvim-tree, colors from the sonokai palette.
    -- Folder groups link to these file groups by default.
    vim.api.nvim_set_hl(0, "NvimTreeGitFileDirtyHL", { fg = "#f39660" })   -- modified: orange
    vim.api.nvim_set_hl(0, "NvimTreeGitFileNewHL", { fg = "#9ed072" })     -- new: green
    vim.api.nvim_set_hl(0, "NvimTreeGitFileStagedHL", { fg = "#76cce0" })  -- staged: blue
    vim.api.nvim_set_hl(0, "NvimTreeGitFileIgnoredHL", { fg = "#e7c664" }) -- ignored: yellow
    vim.api.nvim_set_hl(0, "NvimTreeHiddenFileHL", { fg = "#7f8490" })    -- dotfiles: grey
end

set_hls()
vim.api.nvim_create_autocmd("ColorScheme", { callback = set_hls })
