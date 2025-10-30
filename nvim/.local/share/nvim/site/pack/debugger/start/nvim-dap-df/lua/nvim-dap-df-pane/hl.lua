local M = {}

local EXPR_BG = "#95A1F5"
local EXPR_FG = "#000000"
local BORDER_FG = "#555555"
local ERROR_FG = "#CA2722"
local TYPE_FG = "#96DDF5"

local function build_highlights()
    local bg = vim.api.nvim_get_hl(0, { name = "Normal" }).bg

    return {
        DapDfBorder = { fg = BORDER_FG },
        DapDfError = { fg = ERROR_FG },
        DapDfPrompt = { fg = EXPR_FG, bg = EXPR_BG },
        DapDfHeaderRow = { bold = true },
        DapDfTypeRow = { fg = TYPE_FG }
    }
end

local function setup_highlights()
    M.NS_ID = vim.api.nvim_create_namespace("DapDfNs")

    for group, opts in pairs(build_highlights()) do
        vim.api.nvim_set_hl(M.NS_ID, group, opts)
    end
end


M.setup = function()
    setup_highlights()

    vim.api.nvim_create_autocmd("ColorScheme", {
      callback = setup_highlights,
    })
end

M.setup_static_hl_rules = function(buf_id)
    vim.api.nvim_buf_call(buf_id, function()
      vim.cmd "syntax match TableBorder /[│├┼─┤]/"
    end)
    vim.cmd [[highlight link TableBorder DapDfBorder]]
end

return M
