local config = require("sections.config")

local M = {}

local DEFAULT_HIGHLIGHTS = {
    SectionsFunction = { fg = "#F47648", bold = true },
    SectionsClass = { fg = "#73D0FF", bold = true },
    SectionsAttribute = { fg = "#40BA93", bold = true },
    SectionsHeader = { fg = "#8ED0B2", bold = true },
    SectionsPaneHeaderDim = { fg = "#999E9B", bold = true },
    SectionsPaneHeaderWarn = { fg = "#e78a4e", bold = true },
}

local SECTIONS_HIGHLIGHTS = {
    ["function"] = "SectionsFunction",
    class = "SectionsClass",
    header = "SectionsHeader",
    attribute = "SectionsAttribute",
}

local function setup_highlights()
    M.NS_ID = vim.api.nvim_create_namespace("SectionNs")
    for group, opts in pairs(DEFAULT_HIGHLIGHTS) do
        vim.api.nvim_set_hl(M.NS_ID, group, opts)
    end
end

local function define_syntax_match_rules(buf)
    local cfg = config.get_config()

    vim.api.nvim_buf_call(buf, function()
        vim.cmd("syntax enable")
        for type, icon in pairs(cfg.icons) do
            local hl_group = SECTIONS_HIGHLIGHTS[type]
            local cmd = string.format([[syntax match %s /%s/]], hl_group, icon)
            vim.cmd(cmd)
        end
    end)
end

M.setup = function()
    setup_highlights()

    vim.api.nvim_create_autocmd("FileType", {
        pattern = "sections-pane",
        callback = function(args)
            define_syntax_match_rules(args.buf)
        end,
    })
end

return M
