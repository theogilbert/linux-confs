local M = {}

local FLOAT_MAX_WIDTH  = 100
local FLOAT_MAX_HEIGHT = 40

M.VISIBILITY = {
    PUBLIC  = 0,
    PRIVATE = 1,
    MAGIC   = 2,
}
local V = M.VISIBILITY

M.KIND = {
    METHOD = "method",
    ATTR   = "attr",
}
local K = M.KIND

---@class class-peek.Fold
---@field start  integer  -- 1-indexed line number
---@field finish integer  -- 1-indexed line number
---@field open   boolean

local SECTIONS = {
    { title = "Public attributes", open = false,
      accept = function(m) return m.visibility == V.PUBLIC and not m.is_method end },
    { title = "Public methods",    open = true,
      accept = function(m) return m.visibility == V.PUBLIC and m.is_method end },
    { title = "Private",           open = false,
      accept = function(m) return m.visibility == V.PRIVATE end },
    { title = "Magic",             open = false,
      accept = function(m) return m.visibility == V.MAGIC end },
}

---@param result table?
---@return string?
local function extract_hover_text(result)
    if not result or not result.contents then return nil end
    local c = result.contents
    if type(c) == "string" then return c end
    return c.value
end

---@param m class-peek.Member
---@return string
local function format_member(m)
    if m.kind == K.METHOD then
        local prefix = m.async and "async def " or "def "
        return "  " .. prefix .. m.name .. (m.content or "()")
    end
    return "  " .. m.name .. ": " .. m.content
end

---Public first, then private (_), then magic (__). Within each visibility,
---attributes precede methods. Within each (visibility, kind) bucket,
---alphabetical, with __init__ leading.
---@param members class-peek.Member[]
local function sort_members(members)
    table.sort(members, function(a, b)
        if a.visibility ~= b.visibility then return a.visibility < b.visibility end
        if a.is_method  ~= b.is_method  then return not a.is_method end
        if a.name == "__init__" and b.name ~= "__init__" then return true end
        if b.name == "__init__" then return false end
        return a.name < b.name
    end)
end

---Builds the lines shown in the float, a parallel `locations` array mapping
---each line to source uri/row/col, and a list of folds for collapsible
---sections. Section header lines map to the class location so <C-]>/K on a
---header target the class definition.
---@param class_name string
---@param class_range table   -- LSP Range
---@param class_uri string
---@param members class-peek.Member[]
---@return string[] lines
---@return class-peek.Location[] locations
---@return class-peek.Fold[] folds
local function render_structure(class_name, class_range, class_uri, members)
    sort_members(members)

    local class_loc = {
        uri = class_uri,
        row = class_range.start.line,
        col = class_range.start.character,
    }
    local lines     = { "class " .. class_name .. ":" }
    local locations = { class_loc }
    local folds     = {}
    local placed    = {}

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
            table.insert(folds, { start = fold_start, finish = #lines, open = section.open })
        end
    end

    return lines, locations, folds
end

---@param lines string[]
---@param filetype string
---@return integer buf
---@return integer win
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

---@param win integer
---@param folds class-peek.Fold[]
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

---Maps `word` (typically <cword> from the float) to its source (row, col)
---near `loc`, so hover requests resolve the word in its actual scope rather
---than always hitting the enclosing method's position.
---@param loc class-peek.Location
---@param word string?
---@return integer row
---@return integer col
local function resolve_word_position(loc, word)
    if not word or word == "" then return loc.row, loc.col end
    local bufnr = vim.uri_to_bufnr(loc.uri)
    if not vim.api.nvim_buf_is_loaded(bufnr) then return loc.row, loc.col end
    local source_lines = vim.api.nvim_buf_get_lines(bufnr, loc.row, loc.row + 30, false)
    local pattern = "%f[%w_]" .. vim.pesc(word) .. "%f[^%w_]"
    for i, line in ipairs(source_lines) do
        local s = line:find(pattern)
        if s then return loc.row + i - 1, s - 1 end
    end
    return loc.row, loc.col
end

---@param buf integer
---@param win integer
---@param locations class-peek.Location[]
---@param client vim.lsp.Client
local function setup_keymaps(buf, win, locations, client)
    local function close() vim.api.nvim_win_close(win, true) end

    local function jump_to_symbol()
        local loc = locations[vim.api.nvim_win_get_cursor(0)[1]]
        if not loc then return end
        close()
        local target = vim.uri_to_bufnr(loc.uri)
        vim.fn.bufload(target)
        vim.cmd("edit " .. vim.fn.fnameescape(vim.api.nvim_buf_get_name(target)))
        vim.api.nvim_win_set_cursor(0, { loc.row + 1, loc.col })
    end

    local function show_hover()
        local loc = locations[vim.api.nvim_win_get_cursor(0)[1]]
        if not loc then return end
        local row, col = resolve_word_position(loc, vim.fn.expand("<cword>"))
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
    end

    ---@param lhs string
    ---@param fn function
    ---@param desc string
    local function bind(lhs, fn, desc)
        vim.keymap.set("n", lhs, fn, { buffer = buf, noremap = true, desc = desc })
    end
    bind("q",     close,           "Close float")
    bind("<C-]>", jump_to_symbol,  "Jump to symbol")
    bind("K",     show_hover,      "Show hover")
end

---Renders `members` (already finalized with kind/content/is_method) into a
---floating window with collapsible sections and navigation keymaps.
---@param class_name string
---@param class_range table   -- LSP Range
---@param class_uri string
---@param members class-peek.Member[]
---@param filetype string
---@param client vim.lsp.Client
M.show = function(class_name, class_range, class_uri, members, filetype, client)
    local lines, locations, folds = render_structure(
        class_name, class_range, class_uri, members)
    local buf, win = open_float(lines, filetype)
    apply_folds(win, folds)
    setup_keymaps(buf, win, locations, client)
end

return M
