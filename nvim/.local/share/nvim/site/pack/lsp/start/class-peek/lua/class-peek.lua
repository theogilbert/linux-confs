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
local function ensure_lsp_attached(bufnr, client)
    if vim.bo[bufnr].filetype == "" then
        local ft = get_filetype(bufnr)
        if ft then vim.bo[bufnr].filetype = ft end
    end
    if not vim.lsp.buf_is_attached(bufnr, client.id) then
        vim.lsp.buf_attach_client(bufnr, client.id)
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

local function build_member(sym, uri)
    return {
        name       = sym.name,
        detail     = sym.detail or "",
        is_method  = METHOD_KINDS[sym.kind] or false,
        visibility = visibility_rank(sym.name),
        row        = sym.selectionRange.start.line,
        col        = sym.selectionRange.start.character,
        uri        = uri,
    }
end

local function collapse_whitespace(s)
    return (s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Strips markdown code fences and kind prefixes like "(method) " from hover text.
local function clean_hover(text)
    if not text or text == "" then return nil end
    text = text:match("```[%w_-]*\r?\n(.-)\r?\n?```") or text
    text = text:gsub("^%s*%(%w+%)%s*", "")
    return text
end

-- Parses "(params) -> Return" from a (possibly multi-line) method signature.
-- Returns nil if no parenthesized params are found.
local function parse_method_signature(text)
    if not text then return nil end
    local pstart = text:find("%(")
    if not pstart then return nil end

    local depth, pend = 0, nil
    for i = pstart, #text do
        local c = text:sub(i, i)
        if c == "(" then
            depth = depth + 1
        elseif c == ")" then
            depth = depth - 1
            if depth == 0 then pend = i; break end
        end
    end
    if not pend then return nil end

    local params = collapse_whitespace(text:sub(pstart + 1, pend - 1)):gsub(",%s*$", "")
    local return_type = text:sub(pend + 1):match("%->%s*([^:]+)")
    if return_type and return_type ~= "" then
        return "(" .. params .. ") -> " .. collapse_whitespace(return_type)
    end
    return "(" .. params .. ")"
end

-- Extracts the type portion from hover text for an attribute named `name`.
-- Accepts either "name: type" or bare-type hover output.
local function parse_attr_type(text, name)
    if not text then return nil end
    local first = collapse_whitespace(text:match("^[^\n]+") or text)
    local typed = first:match("^" .. vim.pesc(name) .. "%s*:%s*(.+)$")
    if typed then return typed end
    if first == "" or first == "Unknown" then return nil end
    return first
end

local function format_member(m)
    local hover = clean_hover(m.hover_text)

    -- 1. Method signature recovered from detail or hover.
    local sig
    if m.detail:sub(1, 1) == "(" then
        sig = m.detail
    elseif hover then
        sig = parse_method_signature(hover)
    end
    if sig then
        return "  def " .. m.name .. sig
    end

    -- 2. Type annotation present: treat as attribute.
    local type_str = m.detail ~= "" and m.detail or parse_attr_type(hover, m.name)
    if type_str then
        return "  " .. m.name .. ": " .. type_str
    end

    -- 3. Nothing useful: default to method (typical for class members).
    return "  def " .. m.name .. "()"
end

-- Public first, then private (_), then magic (__).
-- Within each visibility, attributes precede methods.
local function sort_members(members)
    table.sort(members, function(a, b)
        if a.visibility ~= b.visibility then return a.visibility < b.visibility end
        return (a.is_method and 1 or 0) < (b.is_method and 1 or 0)
    end)
end

local function extract_hover_text(result)
    if not result or not result.contents then return nil end
    local c = result.contents
    if type(c) == "string" then return c end
    return c.value
end

-- Requests textDocument/hover for every member that doesn't already have a
-- complete method signature in `detail`. Each hover is sent to the member's
-- own URI (members from inherited classes live in different files).
local function enrich_with_hover(client, members, on_done)
    if not client.server_capabilities.hoverProvider then
        on_done() return
    end

    local todo = {}
    for _, m in ipairs(members) do
        if m.detail:sub(1, 1) ~= "(" then table.insert(todo, m) end
    end
    if #todo == 0 then on_done() return end

    local pending = #todo
    for _, m in ipairs(todo) do
        client:request("textDocument/hover", {
            textDocument = { uri = m.uri },
            position = { line = m.row, character = m.col },
        }, function(_, result)
            m.hover_text = extract_hover_text(result)
            pending = pending - 1
            if pending == 0 then on_done() end
        end)
    end
end

-- Builds the lines shown in the float plus a parallel `locations` array
-- mapping each line index back to its source uri/row/col (for jump-to-symbol).
local function render_structure(class_name, class_range, class_uri, members)
    sort_members(members)
    local lines     = { "class " .. class_name .. ":" }
    local locations = { {
        uri = class_uri,
        row = class_range.start.line,
        col = class_range.start.character,
    } }
    for _, m in ipairs(members) do
        table.insert(lines, format_member(m))
        table.insert(locations, { uri = m.uri, row = m.row, col = m.col })
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
    vim.wo[win].wrap = false
    return buf, win
end

local function setup_keymaps(buf, win, locations)
    local function close()
        vim.api.nvim_win_close(win, true)
    end

    vim.keymap.set("n", "q", close,
        { buffer = buf, noremap = true, desc = "Close float" })

    vim.keymap.set("n", "<C-]>", function()
        local loc = locations[vim.api.nvim_win_get_cursor(0)[1]]
        close()
        local target = vim.uri_to_bufnr(loc.uri)
        vim.fn.bufload(target)
        vim.cmd("edit " .. vim.fn.fnameescape(vim.api.nvim_buf_get_name(target)))
        vim.api.nvim_win_set_cursor(0, { loc.row + 1, loc.col })
    end, { buffer = buf, noremap = true, desc = "Jump to symbol" })
end

-- Loads `uri`, ensures the client is attached, then requests documentSymbol.
-- Calls on_symbols with the first non-empty response.
local function fetch_document_symbols(client, uri, on_symbols)
    local bufnr = vim.uri_to_bufnr(uri)
    vim.fn.bufload(bufnr)
    ensure_lsp_attached(bufnr, client)

    -- buf_request fires the handler once per attached client. Skip empty
    -- responses (e.g. ruff/copilot) and act on the first non-empty one.
    local done = false
    vim.lsp.buf_request(bufnr, "textDocument/documentSymbol",
        { textDocument = { uri = uri } },
        function(_, symbols)
            if done or not symbols or #symbols == 0 then return end
            done = true
            on_symbols(symbols)
        end)
end

local function fetch_class_members(client, uri, class_name, on_done)
    fetch_document_symbols(client, uri, function(symbols)
        local class_sym = find_class_symbol(symbols, class_name)
        if not class_sym or not class_sym.children then
            on_done({})
            return
        end
        local members = {}
        for _, child in ipairs(class_sym.children) do
            table.insert(members, build_member(child, uri))
        end
        on_done(members)
    end)
end

-- Recursively gathers members from all supertypes via LSP type hierarchy.
-- `visited` tracks "uri:line" keys to avoid cycles on diamond inheritance.
local function gather_inherited(client, class_uri, class_pos, visited, on_done)
    if not client.server_capabilities.typeHierarchyProvider then
        on_done({}) return
    end

    local key = class_uri .. ":" .. tostring(class_pos.line)
    if visited[key] then on_done({}) return end
    visited[key] = true

    client:request("textDocument/prepareTypeHierarchy", {
        textDocument = { uri = class_uri },
        position = class_pos,
    }, function(_, items)
        if not items or #items == 0 then on_done({}) return end

        client:request("typeHierarchy/supertypes", { item = items[1] }, function(_, supers)
            if not supers or #supers == 0 then on_done({}) return end

            local all = {}
            local pending = #supers
            for _, super in ipairs(supers) do
                fetch_class_members(client, super.uri, super.name, function(direct)
                    for _, m in ipairs(direct) do table.insert(all, m) end
                    gather_inherited(client, super.uri, super.selectionRange.start, visited,
                        function(ancestors)
                            for _, m in ipairs(ancestors) do table.insert(all, m) end
                            pending = pending - 1
                            if pending == 0 then on_done(all) end
                        end)
                end)
            end
        end)
    end)
end

local function show_structure(client, class_name, location, def_bufnr, symbols)
    local class_sym = find_class_symbol(symbols, class_name)
    if not class_sym or not class_sym.children then
        vim.notify("No class structure found for: " .. class_name)
        return
    end

    local members = {}
    local seen    = {}
    for _, child in ipairs(class_sym.children) do
        local m = build_member(child, location.uri)
        table.insert(members, m)
        seen[m.name] = true
    end

    gather_inherited(client, location.uri, class_sym.selectionRange.start, {},
        function(inherited)
            for _, m in ipairs(inherited) do
                -- Own members shadow inherited ones (Python override semantics).
                if not seen[m.name] then
                    table.insert(members, m)
                    seen[m.name] = true
                end
            end

            enrich_with_hover(client, members, function()
                local lines, locations = render_structure(
                    class_name, location.range, location.uri, members)
                local buf, win = open_float(lines, get_filetype(def_bufnr) or "text")
                setup_keymaps(buf, win, locations)
            end)
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
        fetch_document_symbols(client, location.uri, function(symbols)
            local def_bufnr = vim.uri_to_bufnr(location.uri)
            show_structure(client, class_name, location, def_bufnr, symbols)
        end)
    end)
end

return M
