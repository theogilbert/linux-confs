-- Default highlight links, applied again after a colorscheme change.
local M = {}

local LINKS = {
    FastAPIApp = "Title",
    FastAPIRouter = "Directory",
    FastAPIPath = "Identifier",
    FastAPIFunc = "Function",
    FastAPIMethodGet = "DiagnosticInfo",
    FastAPIMethodPost = "DiagnosticOk",
    FastAPIMethodPut = "DiagnosticWarn",
    FastAPIMethodPatch = "DiagnosticHint",
    FastAPIMethodDelete = "DiagnosticError",
    FastAPIMethodOptions = "Comment",
    FastAPIMethodHead = "Comment",
    FastAPIMethodWebsocket = "Special",
    FastAPIDeprecated = "DiagnosticDeprecated",
    FastAPILens = "Comment",
    FastAPICount = "Comment",
}

local function link_all()
    for name, target in pairs(LINKS) do
        vim.api.nvim_set_hl(0, name, { link = target, default = true })
    end
end

function M.setup()
    link_all()
    vim.api.nvim_create_autocmd("ColorScheme", {
        group = vim.api.nvim_create_augroup("fastapi_highlights", { clear = true }),
        callback = link_all,
    })
end

return M
