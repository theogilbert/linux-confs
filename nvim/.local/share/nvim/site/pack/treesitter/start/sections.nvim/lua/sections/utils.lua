local M = {}

M.merge_tables = function(tbl1, tbl2)
    local new_tbl = {}

    for _, val in pairs(tbl1) do
        table.insert(new_tbl, val)
    end

    for _, val in pairs(tbl2) do
        table.insert(new_tbl, val)
    end

    return new_tbl
end

return M
