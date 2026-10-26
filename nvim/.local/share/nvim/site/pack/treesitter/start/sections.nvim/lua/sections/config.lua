local M = {}

local _config = {
    indent = 2,
    width = 40,
    fold_markers = {
        expanded = "▾",
        collapsed = "▸",
    },
    icons = {
        ["function"] = "󰊕",
        class = "",
        attribute = "󰠲",
        header = "",
    },
    keymaps = {
        toggle_private = "p",
        select_section = "<cr>",
        collapse_section = "zc",
        expand_section = "zo",
        toggle_section_collapse = "za",
        collapse_section_recursive = "zC",
        expand_section_recursive = "zO",
        collapse_all = "zM",
        expand_all = "zR",
        show_description = "K",
        close = "q",
    },
}

M.init = function(config)
    if config then
        _config = vim.tbl_deep_extend("force", _config, config)
    end
end

M.get_config = function()
    return _config
end

return M
