local view = require("class-peek.view")
local V = view.VISIBILITY
local K = view.KIND

---@class class-peek.Member
---@field name       string
---@field detail     string
---@field is_method  boolean
---@field visibility integer  -- one of V.*
---@field row        integer  -- 0-indexed line in `uri`
---@field col        integer  -- 0-indexed character in `uri`
---@field uri        string
---@field overloaded boolean
---@field hover_text string?
---@field kind       string?  -- one of K.*;     set by finalize_members
---@field content    string?  -- signature/type; set by finalize_members
---@field async      boolean? -- true for `async def`; set by finalize_members

---@class class-peek.Location
---@field uri string
---@field row integer
---@field col integer

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

---@param bufnr integer
---@return string?
local function get_filetype(bufnr)
    return vim.filetype.match({
        buf = bufnr,
        filename = vim.api.nvim_buf_get_name(bufnr),
    })
end

---@param s string
---@return string
local function collapse_whitespace(s)
    return (s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

---Returns the first LSP client attached to `bufnr` that supports documentSymbol.
---@param bufnr integer
---@return vim.lsp.Client?
local function find_symbol_provider(bufnr)
    for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
        if client.server_capabilities.documentSymbolProvider then
            return client
        end
    end
end

---Attaches `client` to `bufnr` if not already. Filetype must be set first so
---buf_attach_client sends textDocument/didOpen with a non-empty languageId.
---@param bufnr integer
---@param client vim.lsp.Client
local function ensure_lsp_attached(bufnr, client)
    if vim.bo[bufnr].filetype == "" then
        local ft = get_filetype(bufnr)
        if ft then vim.bo[bufnr].filetype = ft end
    end
    if not vim.lsp.buf_is_attached(bufnr, client.id) then
        vim.lsp.buf_attach_client(bufnr, client.id)
    end
end

---Walks the DocumentSymbol tree looking for a class with the given name.
---@param symbols table[]
---@param class_name string
---@return table? class_sym
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

---True if any line in the decorator stack above `row` is `@overload`.
---@param uri string
---@param row integer  -- 0-indexed line
---@return boolean
local function is_overload_decorated(uri, row)
    if row == 0 then return false end
    local bufnr = vim.uri_to_bufnr(uri)
    if not vim.api.nvim_buf_is_loaded(bufnr) then return false end
    for r = row - 1, math.max(0, row - 10), -1 do
        local line = vim.api.nvim_buf_get_lines(bufnr, r, r + 1, false)[1]
        if not line then break end
        local trimmed = line:match("^%s*(.-)%s*$") or ""
        if trimmed:match("^@[%w_%.]*overload") then return true end
        if trimmed ~= "" and trimmed:sub(1, 1) ~= "@" then break end
    end
    return false
end

---Strips markdown code fences and kind prefixes (e.g. "(method) ") from hover text.
---@param text string?
---@return string?
local function clean_hover(text)
    if not text or text == "" then return nil end
    text = text:match("```[%w_-]*\r?\n(.-)\r?\n?```") or text
    text = text:gsub("^%s*%(%w+%)%s*", "")
    return text
end

---Parses "(params) -> Return" from a (possibly multi-line) method signature
---starting at the beginning of `text`. Returns nil if no parens are found.
---@param text string?
---@return string?
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
    -- [^:\n]+ stops at newline so multi-overload hover output doesn't bleed
    -- the next def's signature into the current one's return type.
    local return_type = text:sub(pend + 1):match("%->%s*([^:\n]+)")
    if return_type and return_type ~= "" then
        return "(" .. params .. ") -> " .. collapse_whitespace(return_type)
    end
    return "(" .. params .. ")"
end

---Extracts the type portion from hover text for an attribute named `name`.
---Accepts either "name: type" or bare-type hover output.
---@param text string?
---@param name string
---@return string?
local function parse_attr_type(text, name)
    if not text then return nil end
    local first = collapse_whitespace(text:match("^[^\n]+") or text)
    local typed = first:match("^" .. vim.pesc(name) .. "%s*:%s*(.+)$")
    if typed then return typed end
    if first == "" or first == "Unknown" then return nil end
    return first
end

---Pulls the raw text out of an LSP Hover response.
---@param result table?
---@return string?
local function extract_hover_text(result)
    if not result or not result.contents then return nil end
    local c = result.contents
    if type(c) == "string" then return c end
    return c.value
end

---Reads up to 30 lines from `row` and parses a method signature directly.
---Authoritative when the line is a `def`/`async def`: ty's hover for an
---overloaded method only shows the overload variants, so the implementation's
---signature must come from the source.
---@param uri string
---@param row integer  -- 0-indexed line
---@return string? signature
---@return boolean? is_async
local function source_signature(uri, row)
    local bufnr = vim.uri_to_bufnr(uri)
    if not vim.api.nvim_buf_is_loaded(bufnr) then return nil end
    local lines = vim.api.nvim_buf_get_lines(bufnr, row, row + 30, false)
    if #lines == 0 then return nil end
    local text = table.concat(lines, "\n")
    local is_async = text:match("^%s*async%s+def%s") ~= nil
    if not is_async and not text:match("^%s*def%s") then
        return nil
    end
    return parse_method_signature(text), is_async
end

---Classifies a member name into a visibility bucket. __init__ is grouped
---with public methods (conceptually a constructor); the view's sort then
---pins it to the top.
---@param name string
---@return integer  -- one of V.*
local function visibility_rank(name)
    if name == "__init__"     then return V.PUBLIC  end
    if name:sub(1, 2) == "__" then return V.MAGIC   end
    if name:sub(1, 1) == "_"  then return V.PRIVATE end
    return V.PUBLIC
end

---Constructs a Member from an LSP DocumentSymbol child.
---@param sym table  -- LSP DocumentSymbol
---@param uri string
---@return class-peek.Member
local function build_member(sym, uri)
    local row = sym.selectionRange.start.line
    return {
        name       = sym.name,
        detail     = sym.detail or "",
        is_method  = METHOD_KINDS[sym.kind] or false,
        visibility = visibility_rank(sym.name),
        row        = row,
        col        = sym.selectionRange.start.character,
        uri        = uri,
        overloaded = is_overload_decorated(uri, row),
    }
end

---Decides display kind (K.METHOD or K.ATTR), the corresponding content
---(signature or type), and whether the member is `async def`.
---@param m class-peek.Member
---@return string  kind     -- one of K.*
---@return string? content  -- signature for methods, type for attrs
---@return boolean async    -- true if the def is async
local function classify_member(m)
    local sig, src_async = source_signature(m.uri, m.row)
    if sig then return K.METHOD, sig, src_async == true end

    if m.detail:sub(1, 1) == "(" then return K.METHOD, m.detail, false end

    local hover = clean_hover(m.hover_text)
    local hover_sig = hover and parse_method_signature(hover)
    if hover_sig then
        return K.METHOD, hover_sig, hover:match("^async%s+def%s") ~= nil
    end

    local type_str = m.detail ~= "" and m.detail or parse_attr_type(hover, m.name)
    if type_str then return K.ATTR, type_str, false end

    -- No signal: default to method. Most class members are methods, and
    -- unresolved aliases (e.g. `agg = aggregate` when ty returns Unknown)
    -- end up here.
    return K.METHOD, nil, false
end

---Resolves display kind/content/async for every member and aligns
---`is_method` with what will actually be shown. Done once after enrichment.
---@param members class-peek.Member[]
local function finalize_members(members)
    for _, m in ipairs(members) do
        local kind, content, async = classify_member(m)
        m.kind      = kind
        m.content   = content
        m.async     = async
        m.is_method = (kind == K.METHOD)
    end
end

---Adds `m` to the list, replacing any existing entry with the same name
---when the new one is preferred. Preference: non-@overload over @overload,
---then last-seen wins.
---@param members  class-peek.Member[]
---@param index_of table<string, integer>
---@param m        class-peek.Member
local function add_member(members, index_of, m)
    local idx = index_of[m.name]
    if not idx then
        table.insert(members, m)
        index_of[m.name] = #members
        return
    end
    if members[idx].overloaded or not m.overloaded then
        members[idx] = m
    end
end

---Inserts only when the name isn't already present. Used for inherited
---members so own definitions shadow inherited ones.
---@param members  class-peek.Member[]
---@param index_of table<string, integer>
---@param m        class-peek.Member
local function add_member_if_new(members, index_of, m)
    if index_of[m.name] then return end
    table.insert(members, m)
    index_of[m.name] = #members
end

---@param client vim.lsp.Client
---@param bufnr integer
---@param on_location fun(loc: { uri: string, range: table }?)
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
        local loc = vim.islist(result) and result[1] or result
        on_location({
            uri   = loc.targetUri or loc.uri,
            range = loc.targetRange or loc.range,
        })
    end)
end

---Loads `uri`, ensures the client is attached, then requests documentSymbol.
---buf_request fires the handler once per attached client, so we skip empty
---responses (e.g. from ruff/copilot) and act on the first non-empty one.
---@param client vim.lsp.Client
---@param uri string
---@param on_symbols fun(symbols: table[])
local function fetch_document_symbols(client, uri, on_symbols)
    local bufnr = vim.uri_to_bufnr(uri)
    vim.fn.bufload(bufnr)
    ensure_lsp_attached(bufnr, client)
    local done = false
    vim.lsp.buf_request(bufnr, "textDocument/documentSymbol",
        { textDocument = { uri = uri } },
        function(_, symbols)
            if done or not symbols or #symbols == 0 then return end
            done = true
            on_symbols(symbols)
        end)
end

---@param client vim.lsp.Client
---@param uri string
---@param class_name string
---@param on_done fun(members: class-peek.Member[])
local function fetch_class_members(client, uri, class_name, on_done)
    fetch_document_symbols(client, uri, function(symbols)
        local class_sym = find_class_symbol(symbols, class_name)
        if not class_sym or not class_sym.children then
            on_done({})
            return
        end
        local members, index_of = {}, {}
        for _, child in ipairs(class_sym.children) do
            add_member(members, index_of, build_member(child, uri))
        end
        on_done(members)
    end)
end

---Recursively gathers members from all supertypes via LSP type hierarchy.
---`visited` tracks "uri:line" keys to break cycles on diamond inheritance.
---@param client vim.lsp.Client
---@param class_uri string
---@param class_pos { line: integer, character: integer }
---@param visited table<string, boolean>
---@param on_done fun(members: class-peek.Member[])
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

            local all, pending = {}, #supers
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

---For every member whose `detail` isn't already a complete method signature,
---fetches textDocument/hover and stores the raw text on `m.hover_text`.
---Calls on_done after all responses arrive.
---@param client vim.lsp.Client
---@param members class-peek.Member[]
---@param on_done fun()
local function enrich_with_hover(client, members, on_done)
    if not client.server_capabilities.hoverProvider then on_done() return end

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

---For members where neither detail nor hover yielded a parseable signature
---or type (e.g. ty returning "Unknown" for method aliases like
---`agg = aggregate`), follow textDocument/typeDefinition to find the function
---being aliased and hover there. Only commits the new location when the
---chased hover yields a method signature — bare type strings (like
---"_SpecialForm" for @overload-decorated methods) are rejected.
---@param client vim.lsp.Client
---@param members class-peek.Member[]
---@param on_done fun()
local function chase_via_type_definition(client, members, on_done)
    if not client.server_capabilities.typeDefinitionProvider then
        on_done() return
    end

    ---@param m class-peek.Member
    ---@return boolean
    local function has_signal(m)
        local hover = clean_hover(m.hover_text)
        if not hover then return false end
        return parse_method_signature(hover) ~= nil
            or parse_attr_type(hover, m.name) ~= nil
    end

    local todo = {}
    for _, m in ipairs(members) do
        if m.detail == "" and not has_signal(m) then table.insert(todo, m) end
    end
    if #todo == 0 then on_done() return end

    local pending = #todo
    local function step()
        pending = pending - 1
        if pending == 0 then on_done() end
    end

    for _, m in ipairs(todo) do
        client:request("textDocument/typeDefinition", {
            textDocument = { uri = m.uri },
            position = { line = m.row, character = m.col },
        }, function(_, result)
            if not result then step() return end
            local loc = vim.islist(result) and result[1] or result
            if not loc then step() return end

            local new_uri   = loc.targetUri or loc.uri
            local new_range = loc.targetSelectionRange or loc.targetRange or loc.range
            if not new_uri or not new_range then step() return end

            local new_row, new_col = new_range.start.line, new_range.start.character
            if new_uri == m.uri and new_row == m.row and new_col == m.col then
                step() return -- typeDef points back at itself; no new info
            end

            local target_bufnr = vim.uri_to_bufnr(new_uri)
            vim.fn.bufload(target_bufnr)
            ensure_lsp_attached(target_bufnr, client)

            client:request("textDocument/hover", {
                textDocument = { uri = new_uri },
                position = { line = new_row, character = new_col },
            }, function(_, hover_result)
                local text = extract_hover_text(hover_result)
                if text and parse_method_signature(clean_hover(text)) then
                    m.uri        = new_uri
                    m.row        = new_row
                    m.col        = new_col
                    m.hover_text = text
                end
                step()
            end)
        end)
    end
end

---Orchestrates the full pipeline: build own members → gather inherited →
---enrich with hover → chase aliases → finalize → render via view.
---@param client vim.lsp.Client
---@param class_name string
---@param location { uri: string, range: table }
---@param def_bufnr integer
---@param symbols table[]
local function show_structure(client, class_name, location, def_bufnr, symbols)
    local class_sym = find_class_symbol(symbols, class_name)
    if not class_sym or not class_sym.children then
        vim.notify("No class structure found for: " .. class_name)
        return
    end

    local members, index_of = {}, {}
    for _, child in ipairs(class_sym.children) do
        add_member(members, index_of, build_member(child, location.uri))
    end

    gather_inherited(client, location.uri, class_sym.selectionRange.start, {},
        function(inherited)
            for _, m in ipairs(inherited) do
                add_member_if_new(members, index_of, m)
            end
            enrich_with_hover(client, members, function()
                chase_via_type_definition(client, members, function()
                    finalize_members(members)
                    view.show(class_name, location.range, location.uri, members,
                        get_filetype(def_bufnr) or "text", client)
                end)
            end)
        end)
end

local M = {}

---Peeks the structure of the class whose name is under the cursor.
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
