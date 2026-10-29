-- Sidebar buffer listing apps, routers and routes.
local config = require("fastapi.config")
local labels = require("fastapi.ui.labels")
local paths = require("fastapi.core.paths")
local state = require("fastapi.state")

local M = {}

require("fastapi.ui.highlights").setup()

---@class fastapi.ExplorerNode
---@field kind "app"|"router"|"route"
---@field id string?
---@field app fastapi.App?
---@field router fastapi.Router?
---@field route fastapi.Route?
---@field parent fastapi.ExplorerNode?

---@class fastapi.Segment
---@field text string
---@field hl string?

local ns = vim.api.nvim_create_namespace("fastapi_explorer")
local group = vim.api.nvim_create_augroup("fastapi_explorer", { clear = true })
local NAME = "fastapi://explorer"
local WINDOW_OPTIONS =
    { "winfixwidth", "number", "relativenumber", "signcolumn", "wrap", "cursorline", "list" }

---@type integer?
local buf
---@type fastapi.ExplorerNode[]
local line_nodes = {}
---@type table<string, boolean>
local expanded = {}
local routers_expanded = false

---@return integer?
local function explorer_win()
    local win = buf and vim.fn.bufwinid(buf) or -1
    return win ~= -1 and win or nil
end

---@param node fastapi.ExplorerNode
---@return boolean
local function is_expanded(node)
    local explicit = expanded[node.id]
    if explicit ~= nil then
        return explicit
    end
    return node.kind == "app" or routers_expanded
end

---@param router fastapi.Router
---@return string
local function router_id(router)
    local at = router.location
    return ("%s:%d:%s:%s"):format(at.file, at.line, router.name, router.prefix)
end

---@param app fastapi.App
---@return string
local function app_id(app)
    return app.file .. "::" .. app.name
end

---@param snapshot fastapi.Snapshot
---@param extra string[]
---@return string[]
local function empty_lines(snapshot, extra)
    if snapshot.status == "scanning" then
        return { "Scanning…" }
    end
    local out = { "No FastAPI app found" }
    vim.list_extend(out, snapshot.errors)
    if snapshot.missing_rg.discovery then
        out[#out + 1] = "ripgrep (rg) not found in PATH, see :checkhealth fastapi"
    end
    return vim.list_extend(out, extra)
end

---@param route fastapi.Route
---@return fastapi.Segment[]
local function route_segments(route)
    local path = paths.strip_dynamic_prefix(route.path)
    local dim = route.deprecated and "FastAPIDeprecated"
    local websocket = route.method == "WEBSOCKET"
    local method_hl = websocket and "FastAPIMethodWebsocket"
        or "FastAPIMethod" .. route.method:sub(1, 1) .. route.method:sub(2):lower()
    local segments = {
        { text = websocket and "WS" or route.method, hl = method_hl },
        { text = " " },
        { text = path, hl = dim or "FastAPIPath" },
    }
    segments[#segments + 1] = { text = "  " }
    segments[#segments + 1] = { text = route.func, hl = dim or "FastAPIFunc" }
    if route.deprecated then
        segments[#segments + 1] = { text = " · deprecated", hl = dim }
    end
    return segments
end

---@param count integer
---@return string
local function count_text(count)
    return count == 1 and "1 route" or count .. " routes"
end

---@class fastapi.Rendered
---@field lines string[]
---@field marks { row: integer, col: integer, end_col: integer, hl: string }[]

---@param rendered fastapi.Rendered
---@param segments fastapi.Segment[]
local function append(rendered, segments)
    local text, col, row = "", 0, #rendered.lines
    for _, segment in ipairs(segments) do
        if segment.hl then
            table.insert(
                rendered.marks,
                { row = row, col = col, end_col = col + #segment.text, hl = segment.hl }
            )
        end
        text = text .. segment.text
        col = col + #segment.text
    end
    table.insert(rendered.lines, text)
end

---@param rendered fastapi.Rendered
---@param node fastapi.ExplorerNode
---@param segments fastapi.Segment[]
local function add_line(rendered, node, segments)
    append(rendered, segments)
    line_nodes[#line_nodes + 1] = node
end

---@param buffer integer
---@param marks { row: integer, col: integer, end_col: integer, hl: string }[]
local function set_marks(buffer, marks)
    for _, mark in ipairs(marks) do
        vim.api.nvim_buf_set_extmark(
            buffer,
            ns,
            mark.row,
            mark.col,
            { end_col = mark.end_col, hl_group = mark.hl }
        )
    end
end

---@param node fastapi.ExplorerNode
---@return string
local function arrow(node)
    return is_expanded(node) and "▾ " or "▸ "
end

---@param rendered fastapi.Rendered
---@param routers fastapi.Router[]
---@param routes fastapi.Route[]
---@param level integer
---@param parent_prefix string
---@param parent fastapi.ExplorerNode
local function add_children(rendered, routers, routes, level, parent_prefix, parent)
    local indent = string.rep("  ", level)
    for _, router in ipairs(labels.sort_routers(routers)) do
        local node = { kind = "router", id = router_id(router), router = router, parent = parent }
        add_line(rendered, node, {
            { text = indent .. arrow(node) },
            { text = labels.router_label(router, parent_prefix), hl = "FastAPIRouter" },
            { text = "  " },
            { text = count_text(labels.count_routes(router)), hl = "FastAPICount" },
        })
        if is_expanded(node) then
            local prefix = paths.strip_dynamic_prefix(router.prefix)
            add_children(rendered, router.children, router.routes, level + 1, prefix, node)
        end
    end
    for _, route in ipairs(labels.sort_routes(routes)) do
        local segments = route_segments(route)
        table.insert(segments, 1, { text = indent })
        add_line(rendered, { kind = "route", route = route, parent = parent }, segments)
    end
end

---@param snapshot fastapi.Snapshot
---@return fastapi.Rendered
local function render_snapshot(snapshot)
    line_nodes = {}
    local rendered = { lines = {}, marks = {} }
    if #snapshot.apps == 0 then
        rendered.lines = empty_lines(snapshot, {})
        return rendered
    end
    for index, app in ipairs(snapshot.apps) do
        local node = { kind = "app", id = app_id(app), app = app }
        local label = labels.app_label(app)
        local segments = { { text = arrow(node) }, { text = label, hl = "FastAPIApp" } }
        if label ~= app.name then
            segments[#segments + 1] = { text = "  " .. app.name }
        end
        if index == 1 and snapshot.status == "scanning" then
            segments[#segments + 1] = { text = "  (scanning…)" }
        end
        add_line(rendered, node, segments)
        if is_expanded(node) then
            add_children(rendered, app.routers, app.routes, 1, "/", node)
        end
    end
    return rendered
end

---@param scope { buf: integer }|{ win: integer }
---@param options table<string, any>
local function set_options(scope, options)
    for name, value in pairs(options) do
        vim.api.nvim_set_option_value(name, value, scope)
    end
end

local function render()
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then
        return
    end
    local rendered = render_snapshot(state.get())
    local win = explorer_win()
    local cursor = win and vim.api.nvim_win_get_cursor(win)[1] or 1
    set_options({ buf = buf }, { modifiable = true })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, rendered.lines)
    set_options({ buf = buf }, { modifiable = false })
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    set_marks(buf, rendered.marks)
    if win then
        vim.api.nvim_win_set_cursor(win, { math.min(cursor, #rendered.lines), 0 })
    end
end

---@return fastapi.ExplorerNode?
local function node_at_cursor()
    return line_nodes[vim.api.nvim_win_get_cursor(0)[1]]
end

---@param id string
local function focus_node(id)
    local win = explorer_win()
    if not win then
        return
    end
    for number, node in ipairs(line_nodes) do
        if node.id == id then
            vim.api.nvim_win_set_cursor(win, { number, 0 })
            return
        end
    end
end

---@param routers fastapi.Router[]
---@param out string[]
---@return string[]
local function router_ids(routers, out)
    for _, router in ipairs(routers) do
        out[#out + 1] = router_id(router)
        router_ids(router.children, out)
    end
    return out
end

---@param node fastapi.ExplorerNode?
---@param open boolean
---@param recursive? boolean  also the routers below the node
local function set_fold(node, open, recursive)
    if not (node and node.id) then
        return
    end
    expanded[node.id] = open
    if recursive then
        local below = node.app and node.app.routers or assert(node.router).children
        for _, id in ipairs(router_ids(below, {})) do
            expanded[id] = open
        end
    end
    render()
    focus_node(node.id)
end

---@param win integer
local function restore_window_options(win)
    for _, name in ipairs(WINDOW_OPTIONS) do
        local value = vim.api.nvim_get_option_value(name, { scope = "global" })
        vim.api.nvim_set_option_value(name, value, { win = win })
    end
end

---@return integer
local function target_window()
    local own = explorer_win()
    local previous = vim.fn.win_getid(vim.fn.winnr("#"))
    local candidates = { previous, unpack(vim.api.nvim_tabpage_list_wins(0)) }
    for _, win in ipairs(candidates) do
        if win ~= own and win ~= 0 and vim.api.nvim_win_get_config(win).relative == "" then
            return win
        end
    end
    vim.cmd(
        config.options.explorer.position == "left" and "rightbelow vsplit" or "leftabove vsplit"
    )
    local win = vim.api.nvim_get_current_win()
    restore_window_options(win)
    return win
end

---@param location fastapi.Location
local function open_location(location)
    vim.api.nvim_set_current_win(target_window())
    require("fastapi.ui.jump").open(location)
end

---@param app fastapi.App
---@return fastapi.Location
local function app_location(app)
    local analysis = require("fastapi.core.extract").analyze(app.file)
    for _, router in ipairs(analysis and analysis.routers or {}) do
        if router.kind == "FastAPI" and router.var == app.name then
            return { file = app.file, line = router.line + 1, col = router.col }
        end
    end
    return { file = app.file, line = 1, col = 0 }
end

local actions = {}

function actions.open()
    local node = node_at_cursor()
    if node and node.kind == "route" then
        open_location(assert(node.route).location)
    elseif node and node.id then
        expanded[node.id] = not is_expanded(node)
        render()
    end
end

function actions.definition()
    local node = node_at_cursor()
    if node and node.kind == "router" then
        open_location(assert(node.router).location)
    elseif node and node.kind == "app" then
        open_location(app_location(assert(node.app)))
    end
end

function actions.copy()
    local node = node_at_cursor()
    local text = node and node.kind == "route" and assert(node.route).path
        or node and node.kind == "router" and assert(node.router).prefix
    if not text then
        return
    end
    local register = config.options.register
    if (register == "+" or register == "*") and vim.fn.has("clipboard") == 0 then
        register = '"'
    end
    text = paths.strip_dynamic_prefix(text)
    vim.fn.setreg(register, text)
    vim.notify("fastapi.nvim: copied " .. text)
end

function actions.toggle_all()
    routers_expanded = not routers_expanded
    for id in pairs(expanded) do
        if not id:find("::", 1, true) then
            expanded[id] = nil
        end
    end
    render()
end

function actions.fold_open()
    set_fold(node_at_cursor(), true)
end

function actions.fold_open_recursive()
    set_fold(node_at_cursor(), true, true)
end

function actions.fold_close()
    local node = node_at_cursor()
    if node and node.id and is_expanded(node) then
        set_fold(node, false)
    elseif node then
        set_fold(node.parent, false)
    end
end

function actions.fold_close_recursive()
    local node = node_at_cursor()
    set_fold(node and (node.id and node or node.parent), false, true)
end

function actions.fold_toggle()
    local node = node_at_cursor()
    if node and node.id and not is_expanded(node) then
        set_fold(node, true)
    else
        actions.fold_close()
    end
end

function actions.fold_open_all()
    routers_expanded = true
    expanded = {}
    render()
end

function actions.fold_close_all()
    routers_expanded = false
    expanded = {}
    for _, app in ipairs(state.get().apps) do
        expanded[app_id(app)] = false
    end
    render()
end

function actions.refresh()
    state.refresh()
    state.need_rg("discovery")
end

function actions.search()
    require("fastapi.ui.picker").search()
end

function actions.docs()
    local node = node_at_cursor()
    if not node or node.kind ~= "route" then
        return
    end
    local route = assert(node.route)
    local workspace = state.get().workspace
    local file = paths.is_within(route.location.file, workspace)
            and route.location.file:sub(#workspace + 2)
        or route.location.file
    -- The route's explorer line and its location, highlighted once the float is open.
    local header = { lines = {}, marks = {} }
    append(header, route_segments(route))
    append(header, { { text = ("%s:%d"):format(file, route.location.line), hl = "FastAPICount" } })
    local lines = vim.list_extend(header.lines, { "" })
    vim.list_extend(
        lines,
        route.docstring and vim.split(route.docstring, "\n", { plain = true })
            or { "_No docstring._" }
    )
    local float = vim.lsp.util.open_floating_preview(lines, "markdown", { border = "rounded" })
    if float and vim.api.nvim_buf_is_valid(float) then
        set_marks(float, header.marks)
    end
end

function actions.close()
    M.close()
end

local DESCRIPTIONS = {
    open = "Open route or toggle node",
    definition = "Go to router or app definition",
    copy = "Copy route path or router prefix",
    toggle_all = "Toggle all routers",
    fold_toggle = "Toggle fold",
    fold_open = "Open fold",
    fold_open_recursive = "Open fold recursively",
    fold_close = "Close fold",
    fold_close_recursive = "Close fold recursively",
    fold_open_all = "Open all folds",
    fold_close_all = "Close all folds",
    refresh = "Refresh",
    search = "Search routes",
    docs = "Show route documentation",
    close = "Close explorer",
}

---@param buffer integer
local function map_keys(buffer)
    for name, key in pairs(config.options.explorer.keys) do
        vim.keymap.set(
            "n",
            key,
            actions[name],
            { buffer = buffer, nowait = true, desc = "FastAPI: " .. DESCRIPTIONS[name] }
        )
    end
end

---@return integer
local function ensure_buffer()
    if buf and vim.api.nvim_buf_is_valid(buf) then
        return buf
    end
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, NAME)
    set_options({ buf = buf }, {
        buftype = "nofile",
        bufhidden = "wipe",
        swapfile = false,
        filetype = "fastapi-explorer",
        modifiable = false,
    })
    map_keys(buf)
    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = { "FastAPIScanning", "FastAPIRefreshed" },
        callback = render,
    })
    return buf
end

function M.open()
    local win = explorer_win()
    if win then
        vim.api.nvim_set_current_win(win)
        return
    end
    local options = config.options.explorer
    vim.cmd(
        ("%s %dvsplit"):format(
            options.position == "left" and "topleft" or "botright",
            options.width
        )
    )
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, ensure_buffer())
    set_options({ win = win }, {
        winfixwidth = true,
        number = false,
        relativenumber = false,
        signcolumn = "no",
        wrap = false,
        cursorline = true,
        list = false,
    })
    render()
    state.need_rg("discovery")
end

function M.close()
    local win = explorer_win()
    if not win then
        return
    end
    if #vim.api.nvim_tabpage_list_wins(0) == 1 then
        vim.cmd("enew")
    else
        vim.api.nvim_win_close(win, true)
    end
end

function M.toggle()
    if explorer_win() then
        M.close()
    else
        M.open()
    end
end

return M
