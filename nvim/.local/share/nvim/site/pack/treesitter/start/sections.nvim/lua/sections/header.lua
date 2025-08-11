local M = {}

M.get_lines = function(show_private)
    if show_private then
        return { "󰈈 - Private sections are visible" }
    else
        return { "󰈉 - Private sections are hidden" }
    end
end

M.get_hl_rules = function(show_private)
    local hl_group = show_private and "SectionsPaneHeaderDim" or "SectionsPaneHeaderWarn"
    return {
        { higroup = hl_group, start = { 0, 0 }, finish = { 0, -1 } },
    }
end

return M
