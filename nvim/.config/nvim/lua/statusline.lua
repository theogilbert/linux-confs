-- mini.statusline sets up the vim status line
local H = {}

H.generate_status_line = function()
    local mode, mode_hl = MiniStatusline.section_mode({ trunc_width = 120 })
    local git           = MiniStatusline.section_git({ trunc_width = 40 })
    local diff          = MiniStatusline.section_diff({ trunc_width = 75 })
    local diagnostics   = MiniStatusline.section_diagnostics({ trunc_width = 75 })
    local lsp           = MiniStatusline.section_lsp({ trunc_width = 75 })
    local filename      = MiniStatusline.section_filename({ trunc_width = 140 })
    local fileinfo      = MiniStatusline.section_fileinfo({ trunc_width = 120 })
    local bytesinfo     = H.section_bytes_insight({ trunc_width = 120 })
    local location      = MiniStatusline.section_location({ trunc_width = 75 })
    local search        = MiniStatusline.section_searchcount({ trunc_width = 75 })

    return MiniStatusline.combine_groups({
        { hl = mode_hl,                  strings = { mode } },
        { hl = 'MiniStatuslineDevinfo',  strings = { git, diff, diagnostics, lsp } },
        '%<', -- Mark general truncate point
        { hl = 'MiniStatuslineFilename', strings = { filename } },
        '%=', -- End left alignment
        { hl = 'MiniStatuslineFileinfo', strings = { vim.g.bytes_info_statusline and bytesinfo or fileinfo} },
        { hl = mode_hl,                  strings = { search, location } },
    })
end

require("mini.statusline").setup({
    content = {
        active = H.generate_status_line
    }
})



H.section_bytes_insight = function(args)
    return "Off. %o (0x%O) | C%b (0x%B)"
end

