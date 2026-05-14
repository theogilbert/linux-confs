local M = {}

-- LSP SymbolKind values (see LSP spec).
local SYMBOL_KIND = {
    CLASS       = 5,
    METHOD      = 6,
    CONSTRUCTOR = 9,
    FUNCTION    = 12,
}

local METHOD_KINDS = {
    [SYMBOL_KIND.METHOD]      = true,
    [SYMBOL_KIND.CONSTRUCTOR] = true,
    [SYMBOL_KIND.FUNCTION]    = true,
}

local FLOAT_MAX_WIDTH  = 100
local FLOAT_MAX_HEIGHT = 40

local function get_filetype(bufnr)
    return vim.filetype.match({
        buf = bufnr,
        filename = vim.api.nvim_buf_get_name(bufnr),
    })
end

local function find_symbol_provider(bufnr)
    for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
        if client.server_capabilities.documentSymbolProvider then
            return client
        end
    end
end

-- Filetype must be set before attaching so buf_attach_client sends
-- textDocument/didOpen with a non-empty languageId.
local function ensure_lsp_attached(def_bufnr, client)
    if vim.bo[def_bufnr].filetype == "" then
        local ft = get_filetype(def_bufnr)
        if ft then vim.bo[def_bufnr].filetype = ft end
    end
    if not vim.lsp.buf_is_attached(def_bufnr, client.id) then
        vim.lsp.buf_attach_client(def_bufnr, client.id)
    end
end

local function find_class_symbol(symbols, class_name)
    for _, sym in ipairs(symbols) do
        if sym.name == class_name and sym.kind == SYMBOL_KIND.CLASS then
            return sym
        end
        if sym.children then
            local found = find_class_symbol(sym.children, class_name)
            if found then return found end
        end
    end
end

local function visibility_rank(name)
    if name:sub(1, 2) == "__" then return 2 end -- magic
    if name:sub(1, 1) == "_"  then return 1 end -- private
    return 0                                    -- public
end

local function format_method(name, detail)
    local sig = (detail:sub(1, 1) == "(") and detail or "()"
    return "  def " .. name .. sig
end

local function format_attribute(name, detail)
    return "  " .. name .. (detail ~= "" and (": " .. detail) or "")
end

local function build_member(sym)
    local detail = sym.detail or ""
    local is_method = METHOD_KINDS[sym.kind] or false
    return {
        is_method  = is_method,
        visibility = visibility_rank(sym.name),
        display    = is_method and format_method(sym.name, detail)
                                or format_attribute(sym.name, detail),
        row        = sym.selectionRange.start.line,
        col        = sym.selectionRange.start.character,
    }
end

-- Public first, then private (_), then magic (__).
-- Within each visibility, attributes precede methods.
local function sort_members(members)
    table.sort(members, function(a, b)
        if a.visibility ~= b.visibility then return a.visibility < b.visibility end
        return (a.is_method and 1 or 0) < (b.is_method and 1 or 0)
    end)
end

-- Renders the class structure as `lines` plus a parallel `locations` array
-- mapping each line index back to its source position (for jump-to-symbol).
local function render_structure(class_sym, class_name, class_range)
    local members = {}
    for _, child in ipairs(class_sym.children) do
        table.insert(members, build_member(child))
    end
    sort_members(members)

    local lines     = { "class " .. class_name .. ":" }
    local locations = { { row = class_range.start.line, col = class_range.start.character } }
    for _, m in ipairs(members) do
        table.insert(lines, m.display)
        table.insert(locations, { row = m.row, col = m.col })
    end
    return lines, locations
end

local function open_float(lines, filetype)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype   = filetype
    vim.bo[buf].modifiable = false

    local width = 0
    for _, line in ipairs(lines) do width = math.max(width, #line) end

    local win = vim.api.nvim_open_win(buf, true, {
        relative = "cursor",
        row      = 1,
        col      = 0,
        width    = math.min(width, FLOAT_MAX_WIDTH),
        height   = math.min(#lines, FLOAT_MAX_HEIGHT),
        style    = "minimal",
        border   = "rounded",
    })
    return buf, win
end

local function setup_keymaps(buf, win, locations, source_bufnr)
    local function close()
        vim.api.nvim_win_close(win, true)
    end

    vim.keymap.set("n", "q", close,
        { buffer = buf, noremap = true, desc = "Close float" })

    vim.keymap.set("n", "<C-]>", function()
        local loc = locations[vim.api.nvim_win_get_cursor(0)[1]]
        close()
        vim.cmd("edit " .. vim.fn.fnameescape(vim.api.nvim_buf_get_name(source_bufnr)))
        vim.api.nvim_win_set_cursor(0, { loc.row + 1, loc.col })
    end, { buffer = buf, noremap = true, desc = "Jump to symbol" })
end

local function show_structure(class_name, def_range, def_bufnr, symbols)
    local class_sym = find_class_symbol(symbols, class_name)
    if not class_sym or not class_sym.children then
        vim.notify("No class structure found for: " .. class_name)
        return
    end
    local lines, locations = render_structure(class_sym, class_name, def_range)
    local buf, win = open_float(lines, get_filetype(def_bufnr) or "text")
    setup_keymaps(buf, win, locations, def_bufnr)
end

local function request_symbols(client, uri, on_symbols)
    local def_bufnr = vim.uri_to_bufnr(uri)
    vim.fn.bufload(def_bufnr)
    ensure_lsp_attached(def_bufnr, client)

    -- buf_request fires the handler once per attached client. Skip empty
    -- responses (e.g. ruff/copilot) and act on the first non-empty one.
    local done = false
    vim.lsp.buf_request(def_bufnr, "textDocument/documentSymbol",
        { textDocument = { uri = uri } },
        function(_, symbols)
            if done or not symbols or #symbols == 0 then return end
            done = true
            on_symbols(def_bufnr, symbols)
        end)
end

local function request_definition(client, bufnr, on_location)
    local position = vim.lsp.util.make_position_params(0, client.offset_encoding or "utf-16")
    local done = false
    vim.lsp.buf_request(bufnr, "textDocument/definition", position, function(_, result)
        if done then return end
        done = true
        if not result or (vim.islist(result) and #result == 0) then
            on_location(nil)
            return
        end
        local location = vim.islist(result) and result[1] or result
        on_location({
            uri   = location.targetUri or location.uri,
            range = location.targetRange or location.range,
        })
    end)
end

M.peek = function()
    local bufnr = vim.api.nvim_get_current_buf()
    local client = find_symbol_provider(bufnr)
    if not client then return end

    local class_name = vim.fn.expand("<cword>")

    request_definition(client, bufnr, function(location)
        if not location then
            vim.notify("No definition found for: " .. class_name)
            return
        end
        request_symbols(client, location.uri, function(def_bufnr, symbols)
            show_structure(class_name, location.range, def_bufnr, symbols)
        end)
    end)
end

return M
