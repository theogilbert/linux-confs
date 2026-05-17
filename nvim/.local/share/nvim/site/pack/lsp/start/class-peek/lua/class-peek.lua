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

-- Walks backwards from `row`, skipping blanks and other decorators, and
-- returns true if any line in the decorator stack is `@overload`.
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

local function build_member(sym, uri)
    local row = sym.selectionRange.start.line
    -- __init__ is grouped with public methods (as the constructor it conceptually
    -- belongs there) rather than buried in the Magic section.
    local visibility = sym.name == "__init__" and 0 or visibility_rank(sym.name)
    return {
        name       = sym.name,
        detail     = sym.detail or "",
        is_method  = METHOD_KINDS[sym.kind] or false,
        visibility = visibility,
        row        = row,
        col        = sym.selectionRange.start.character,
        uri        = uri,
        overloaded = is_overload_decorated(uri, row),
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

-- Parses "(params) -> Return" from a (possibly multi-line) method signature
-- starting at the beginning of `text`. The caller is responsible for slicing
-- `text` so the signature it wants is the first one.
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
    -- [^:\n]+ stops at a newline so multi-overload hover output doesn't bleed
    -- the next def's signature into the current one's return type.
    local return_type = text:sub(pend + 1):match("%->%s*([^:\n]+)")
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

-- Reads up to 30 lines starting at `row` and tries to parse a method signature
-- directly from the source. Authoritative when the line is a `def`/`async def`:
-- ty's hover for an overloaded method only shows the overload variants, so the
-- implementation's actual signature has to come from the source itself.
local function source_signature(uri, row)
    local bufnr = vim.uri_to_bufnr(uri)
    if not vim.api.nvim_buf_is_loaded(bufnr) then return nil end
    local lines = vim.api.nvim_buf_get_lines(bufnr, row, row + 30, false)
    if #lines == 0 then return nil end
    local text = table.concat(lines, "\n")
    if not text:match("^%s*def%s") and not text:match("^%s*async%s+def%s") then
        return nil
    end
    return parse_method_signature(text)
end

-- Decides how a member should be displayed and returns (kind, content) where
-- kind is "method" or "attr". For methods, content is the signature (may be
-- nil for the default "()"); for attributes, content is the type string.
-- Result is cached on `m` so this is safe to call multiple times.
local function classify(m)
    if m._classified then return m._kind, m._content end

    local kind, content
    -- 1. Authoritative: read the def line directly from source. The only way
    -- to recover the impl signature for @overloaded methods, since ty's
    -- hover only exposes the overload variants.
    local src_sig = source_signature(m.uri, m.row)
    if src_sig then
        kind, content = "method", src_sig
    elseif m.detail:sub(1, 1) == "(" then
        kind, content = "method", m.detail
    else
        local hover = clean_hover(m.hover_text)
        local hover_sig = hover and parse_method_signature(hover)
        if hover_sig then
            kind, content = "method", hover_sig
        else
            -- Explicit type annotation → attribute
            local type_str = m.detail ~= "" and m.detail or parse_attr_type(hover, m.name)
            if type_str then
                kind, content = "attr", type_str
            else
                -- No info: default to method (most class members are methods,
                -- and unresolved aliases like `agg = aggregate` end up here).
                kind, content = "method", nil
            end
        end
    end

    m._classified = true
    m._kind       = kind
    m._content    = content
    return kind, content
end

local function format_member(m)
    local kind, content = classify(m)
    if kind == "method" then
        return "  def " .. m.name .. (content or "()")
    end
    return "  " .. m.name .. ": " .. content
end

-- Public first, then private (_), then magic (__).
-- Within each visibility, attributes precede methods.
-- Within each (visibility, kind) bucket, sort alphabetically by name —
-- except __init__ which always leads its bucket.
local function sort_members(members)
    table.sort(members, function(a, b)
        if a.visibility ~= b.visibility then return a.visibility < b.visibility end
        if a.is_method ~= b.is_method then return not a.is_method end
        if a.name == "__init__" and b.name ~= "__init__" then return true end
        if b.name == "__init__" then return false end
        return a.name < b.name
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

-- For members where neither detail nor hover yielded a parseable signature
-- or type (e.g. ty returning "Unknown" for method aliases like
-- `agg = aggregate`), follow textDocument/typeDefinition to find the function
-- being aliased and hover there. Only commits the new location when the
-- chase yields an actual method signature — bare type strings are rejected.
local function chase_via_type_definition(client, members, on_done)
    if not client.server_capabilities.typeDefinitionProvider then
        on_done() return
    end

    local function has_anything_useful(m)
        local hover = clean_hover(m.hover_text)
        if not hover then return false end
        return parse_method_signature(hover) ~= nil
            or parse_attr_type(hover, m.name) ~= nil
    end

    local todo = {}
    for _, m in ipairs(members) do
        if m.detail == "" and not has_anything_useful(m) then
            table.insert(todo, m)
        end
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

            local new_row = new_range.start.line
            local new_col = new_range.start.character
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
                -- Only accept the chase result if it gives an actual method
                -- signature. Bare type strings like "_SpecialForm" (what ty
                -- returns for @overload-decorated methods) would otherwise
                -- mislead us into showing methods as attributes.
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

-- Sections are tried in order; each member is placed in the first matching
-- one. `foldable = false` keeps the section always visible (no manual fold).
local SECTIONS = {
    { title = "Public attributes", open = false,
      accept = function(m) return m.visibility == 0 and not m.is_method end },
    { title = "Public methods",    open = true,
      accept = function(m) return m.visibility == 0 and m.is_method end },
    { title = "Private",           open = false,
      accept = function(m) return m.visibility == 1 end },
    { title = "Magic",             open = false,
      accept = function(m) return m.visibility == 2 end },
}

-- Builds the lines shown in the float plus a parallel `locations` array
-- and a list of `folds` (each {start, finish, open}) for collapsible sections.
-- Section headers map to the class location so <C-]>/K on a header jump to
-- the class definition.
local function render_structure(class_name, class_range, class_uri, members)
    -- Recompute is_method from how the member will actually be displayed.
    -- LSP-assigned kinds are often wrong (e.g. ty marks `agg = aggregate`
    -- as Variable but we display it as `def agg()`); using `classify` here
    -- keeps section assignment consistent with the rendered line.
    for _, m in ipairs(members) do
        m.is_method = (classify(m) == "method")
    end
    sort_members(members)

    local class_loc = {
        uri = class_uri,
        row = class_range.start.line,
        col = class_range.start.character,
    }
    local lines     = { "class " .. class_name .. ":" }
    local locations = { class_loc }
    local folds     = {}
    local placed   = {}

    for _, section in ipairs(SECTIONS) do
        local sec_members = {}
        for _, m in ipairs(members) do
            if not placed[m] and section.accept(m) then
                table.insert(sec_members, m)
                placed[m] = true
            end
        end
        if #sec_members > 0 then
            local fold_start = #lines + 1
            table.insert(lines, section.title .. " (" .. #sec_members .. "):")
            table.insert(locations, class_loc)
            for _, m in ipairs(sec_members) do
                table.insert(lines, format_member(m))
                table.insert(locations, { uri = m.uri, row = m.row, col = m.col })
            end
            if section.foldable ~= false then
                table.insert(folds, { start = fold_start, finish = #lines, open = section.open })
            end
        end
    end

    return lines, locations, folds
end

local function apply_folds(win, folds)
    vim.api.nvim_win_call(win, function()
        vim.opt_local.foldmethod = "manual"
        vim.opt_local.foldenable = true
        vim.opt_local.foldtext   = "getline(v:foldstart)"
        vim.opt_local.fillchars:append("fold: ")
        -- `:N,Mfold` creates a closed fold; reopen the ones marked open.
        for _, f in ipairs(folds) do
            vim.cmd(string.format("%d,%dfold", f.start, f.finish))
        end
        for _, f in ipairs(folds) do
            if f.open then
                vim.cmd(string.format("%dfoldopen", f.start))
            end
        end
    end)
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

local function setup_keymaps(buf, win, locations, client)
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

    vim.keymap.set("n", "K", function()
        local loc = locations[vim.api.nvim_win_get_cursor(0)[1]]
        if not loc then return end

        -- Resolve the word under cursor (param type, return type, etc.) by
        -- locating it in the source near the member's definition. Falls back
        -- to the member's own position if the word isn't found.
        local row, col = loc.row, loc.col
        local word = vim.fn.expand("<cword>")
        if word and word ~= "" then
            local bufnr = vim.uri_to_bufnr(loc.uri)
            if vim.api.nvim_buf_is_loaded(bufnr) then
                local source_lines = vim.api.nvim_buf_get_lines(bufnr, loc.row, loc.row + 30, false)
                local pattern = "%f[%w_]" .. vim.pesc(word) .. "%f[^%w_]"
                for i, line in ipairs(source_lines) do
                    local s = line:find(pattern)
                    if s then
                        row, col = loc.row + i - 1, s - 1
                        break
                    end
                end
            end
        end

        client:request("textDocument/hover", {
            textDocument = { uri = loc.uri },
            position = { line = row, character = col },
        }, function(_, result)
            local text = extract_hover_text(result)
            if not text or text == "" then return end
            vim.lsp.util.open_floating_preview(
                vim.split(text, "\n"),
                "markdown",
                { border = "rounded" })
        end)
    end, { buffer = buf, noremap = true, desc = "Show hover" })
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
        local index_of = {}
        for _, child in ipairs(class_sym.children) do
            local m = build_member(child, uri)
            local existing_idx = index_of[m.name]
            if not existing_idx then
                table.insert(members, m)
                index_of[m.name] = #members
            elseif members[existing_idx].overloaded or not m.overloaded then
                members[existing_idx] = m
            end
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
    local index_of = {} -- name -> position in `members`

    -- Prefer the non-@overload definition (the implementation). When all
    -- candidates are @overload-decorated (typical of stub files), keep the
    -- last one seen.
    for _, child in ipairs(class_sym.children) do
        local m = build_member(child, location.uri)
        local existing_idx = index_of[m.name]
        if not existing_idx then
            table.insert(members, m)
            index_of[m.name] = #members
        elseif members[existing_idx].overloaded or not m.overloaded then
            members[existing_idx] = m
        end
    end

    gather_inherited(client, location.uri, class_sym.selectionRange.start, {},
        function(inherited)
            for _, m in ipairs(inherited) do
                -- Own members shadow inherited ones (Python override semantics).
                if not index_of[m.name] then
                    table.insert(members, m)
                    index_of[m.name] = #members
                end
            end

            enrich_with_hover(client, members, function()
                chase_via_type_definition(client, members, function()
                    local lines, locations, folds = render_structure(
                        class_name, location.range, location.uri, members)
                    local buf, win = open_float(lines, get_filetype(def_bufnr) or "text")
                    apply_folds(win, folds)
                    setup_keymaps(buf, win, locations, client)
                end)
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
