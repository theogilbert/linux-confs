-- Lenses: test counts on routes, matching routes on test client calls, above or after the line.
local config = require("fastapi.config")
local labels = require("fastapi.ui.labels")
local state = require("fastapi.state")
local testindex = require("fastapi.core.testindex")

local M = {}

require("fastapi.ui.highlights").setup()

local ns = vim.api.nvim_create_namespace("fastapi_lens")
local autocmds_ready = false

---@param buf integer
---@return boolean
local function is_python(buf)
    return vim.api.nvim_buf_is_valid(buf)
        and vim.api.nvim_get_option_value("filetype", { buf = buf }) == "python"
end

---@param buf integer
---@param location fastapi.Location
---@param text string
local function draw(buf, location, text)
    local row = location.line - 1
    if row >= vim.api.nvim_buf_line_count(buf) then
        return
    end
    if config.options.lens.position == "eol" then
        vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
            virt_text = { { text, "FastAPILens" } },
            virt_text_pos = "eol",
            -- Keeps the background of the line, e.g. the cursorline's.
            hl_mode = "combine",
        })
    else
        vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
            virt_lines = { { { string.rep(" ", location.col) .. text, "FastAPILens" } } },
            virt_lines_above = true,
        })
    end
end

---@param count integer
---@return string
local function test_count_text(count)
    return count == 1 and "1 test" or count .. " tests"
end

---@param routes fastapi.Route[]
---@param apps fastapi.App[]
---@return string
local function route_labels_text(routes, apps)
    local owners = labels.route_owners(apps)
    local first_owner, several = owners[routes[1]], false
    for _, route in ipairs(routes) do
        several = several or owners[route] ~= first_owner
    end
    local parts = vim.tbl_map(function(route)
        local label = labels.route_label(route)
        return several and ("[%s] %s"):format(owners[route], label) or label
    end, routes)
    return "→ " .. table.concat(parts, ", ")
end

-- Only matters without rg: say so once when a test file with client calls opens.
---@param buf integer
---@param snapshot fastapi.Snapshot
local function check_rg(buf, snapshot)
    local ok, checked = pcall(vim.api.nvim_buf_get_var, buf, "fastapi_rg_checked")
    if snapshot.status ~= "idle" or not snapshot.missing_rg.tests or (ok and checked) then
        return
    end
    vim.api.nvim_buf_set_var(buf, "fastapi_rg_checked", true)
    if not testindex.is_test_file(vim.api.nvim_buf_get_name(buf)) then
        return
    end
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    local root = require("fastapi.core.ts").parse_string(text)
    if root and #require("fastapi.core.extract").find_test_calls(root, text) > 0 then
        state.need_rg("tests")
    end
end

---@param buf integer
function M.render(buf)
    if not config.options.lens.enabled or not is_python(buf) then
        return
    end
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    local snapshot = state.get()
    local entry = snapshot.by_file[vim.api.nvim_buf_get_name(buf)]
    for _, route in ipairs(entry and entry.routes or {}) do
        local calls = snapshot.links.calls_by_route[route]
        if calls then
            draw(buf, route.location, test_count_text(#calls))
        end
    end
    for _, call in ipairs(entry and entry.calls or {}) do
        local routes = snapshot.links.routes_by_call[call]
        if routes then
            draw(buf, call.location, route_labels_text(routes, snapshot.apps))
        end
    end
    check_rg(buf, snapshot)
end

local function setup_autocmds()
    if autocmds_ready then
        return
    end
    autocmds_ready = true
    local group = vim.api.nvim_create_augroup("fastapi_lens", { clear = true })
    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "FastAPIRefreshed",
        callback = function()
            for _, win in ipairs(vim.api.nvim_list_wins()) do
                M.render(vim.api.nvim_win_get_buf(win))
            end
        end,
    })
    vim.api.nvim_create_autocmd("BufWinEnter", {
        group = group,
        pattern = "*.py",
        callback = function(args)
            M.render(args.buf)
        end,
    })
end

---@param buf integer
function M.attach(buf)
    if not config.options.lens.enabled or not is_python(buf) then
        return
    end
    setup_autocmds()
    M.render(buf)
end

return M
