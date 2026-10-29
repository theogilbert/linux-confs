-- Asynchronous ripgrep wrapper; the only async code in core.
local M = {}

M.NOT_FOUND = "ripgrep (rg) not found in PATH"

---@param args string[]
---@param cwd string
---@param cb fun(paths: string[]?, err: string?)
function M.files(args, cwd, cb)
    local function finish(paths, err)
        vim.schedule(function()
            cb(paths, err)
        end)
    end
    if vim.fn.executable("rg") ~= 1 then
        return finish(nil, M.NOT_FOUND)
    end
    local command = vim.list_extend({ "rg" }, args)
    local ok, err = pcall(vim.system, command, { cwd = cwd, text = true }, function(result)
        local paths = {}
        for line in vim.gsplit(result.stdout or "", "\n", { plain = true, trimempty = true }) do
            paths[#paths + 1] = vim.fs.joinpath(cwd, line)
        end
        -- Exit 1 is "no match"; exit 2 with output is a partial failure such as an unreadable file.
        if result.code == 0 or result.code == 1 or (result.code == 2 and #paths > 0) then
            finish(paths)
        else
            finish(
                nil,
                vim.trim(result.stderr or "") ~= "" and vim.trim(result.stderr) or "rg failed"
            )
        end
    end)
    if not ok then
        finish(nil, tostring(err))
    end
end

return M
