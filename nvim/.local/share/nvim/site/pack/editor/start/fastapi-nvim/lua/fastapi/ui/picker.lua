-- Route search through vim.ui.select.
local app = require("fastapi.core.app")
local labels = require("fastapi.ui.labels")
local paths = require("fastapi.core.paths")
local state = require("fastapi.state")

local M = {}

require("fastapi.ui.highlights").setup()

-- Size of the fzf-lua float besides its entries: borders, prompt and separator lines, and
-- borders, gutter and scrollbar columns.
local CHROME_LINES, CHROME_COLUMNS = 4, 6

---@param file string
---@param line integer
---@return string
local function location_text(file, line)
    return ("%s:%d"):format(vim.fn.fnamemodify(file, ":."), line)
end

---@param route fastapi.Route
---@param apps fastapi.App[]
---@return fastapi.Segment[]
function M.route_segments(route, apps)
    local owner = #apps > 1 and labels.route_owners(apps)[route]
    local segments = owner and { { text = ("[%s] "):format(owner), hl = "FastAPIApp" } } or {}
    local websocket = route.method == "WEBSOCKET"
    local method_hl = websocket and "FastAPIMethodWebsocket"
        or "FastAPIMethod" .. route.method:sub(1, 1) .. route.method:sub(2):lower()
    local location = route.location
    vim.list_extend(segments, {
        { text = websocket and "WS" or route.method, hl = method_hl },
        { text = " " },
        {
            text = paths.strip_dynamic_prefix(route.path),
            hl = route.deprecated and "FastAPIDeprecated" or "FastAPIPath",
        },
        { text = "  " },
        { text = route.func, hl = "FastAPIFunc" },
        { text = "  " },
        { text = location_text(location.file, location.line), hl = "FastAPICount" },
    })
    return segments
end

---@param segments fastapi.Segment[]
---@return string
local function plain(segments)
    return table.concat(vim.tbl_map(function(segment)
        return segment.text
    end, segments))
end

---@param file string
---@param line integer
---@return string?
local function source_line(file, line)
    local buffer = vim.fn.bufnr(file)
    if buffer ~= -1 and vim.api.nvim_buf_is_loaded(buffer) then
        return vim.api.nvim_buf_get_lines(buffer, line - 1, line, false)[1]
    end
    local ok, lines = pcall(vim.fn.readfile, file, "", line)
    return ok and lines[line] or nil
end

---@param call fastapi.TestCall
---@return fastapi.Segment[]
function M.call_segments(call)
    local at = call.location
    local text = source_line(at.file, at.line)
    return {
        { text = location_text(at.file, at.line), hl = "FastAPICount" },
        { text = "  " },
        { text = text and vim.trim(text) or (call.method:upper() .. " " .. call.path) },
    }
end

---@param items { location: fastapi.Location }[]
---@param prompt string
---@param segments_of fun(item: any): fastapi.Segment[]
---@return boolean  false when fzf-lua is not installed
local function fzf_choose(items, prompt, segments_of)
    local ok, fzf = pcall(require, "fzf-lua")
    if not ok then
        return false
    end
    -- Each entry starts with the index of its item, hidden by --with-nth.
    local entries, widest = {}, #prompt + 20
    for index, item in ipairs(items) do
        local segments = segments_of(item)
        local text = vim.tbl_map(function(segment)
            return segment.hl and fzf.utils.ansi_from_hl(segment.hl, segment.text) or segment.text
        end, segments)
        entries[index] = index .. "\t" .. table.concat(text)
        widest = math.max(widest, vim.fn.strdisplaywidth(plain(segments)))
    end
    fzf.fzf_exec(entries, {
        prompt = prompt .. "> ",
        previewer = false,
        -- Like VS Code's quick pick: near the top, only as large as the entries need.
        winopts = {
            height = math.min(#entries + CHROME_LINES, math.floor(vim.o.lines * 0.4)),
            width = math.min(widest + CHROME_COLUMNS, math.floor(vim.o.columns * 0.9)),
            row = 0.1,
        },
        fzf_opts = { ["--ansi"] = true, ["--delimiter"] = "\t", ["--with-nth"] = "2.." },
        actions = {
            ["enter"] = function(selected)
                local index = selected[1] and tonumber(selected[1]:match("^%d+"))
                local item = index and items[index]
                if item then
                    require("fastapi.ui.jump").open(item.location)
                end
            end,
        },
    })
    return true
end

-- Opens the chosen item's location, picked with fzf-lua (colored) when it is installed, or with
-- vim.ui.select (plain) otherwise.
---@param items { location: fastapi.Location }[]
---@param opts { prompt: string, kind: string }
---@param segments_of fun(item: any): fastapi.Segment[]
function M.choose(items, opts, segments_of)
    if fzf_choose(items, opts.prompt, segments_of) then
        return
    end
    vim.ui.select(items, {
        prompt = opts.prompt,
        kind = opts.kind,
        format_item = function(item)
            return plain(segments_of(item))
        end,
    }, function(choice)
        if choice then
            require("fastapi.ui.jump").open(choice.location)
        end
    end)
end

function M.search()
    local snapshot = state.get()
    state.need_rg("discovery")
    local routes = app.collect_routes(snapshot.apps)
    if #routes == 0 then
        local message = snapshot.status == "scanning" and "still scanning, try again in a moment"
            or "no FastAPI routes found"
        vim.notify("fastapi.nvim: " .. message, vim.log.levels.INFO)
        return
    end
    M.choose(routes, { prompt = "FastAPI routes", kind = "fastapi.route" }, function(route)
        return M.route_segments(route, snapshot.apps)
    end)
end

return M
