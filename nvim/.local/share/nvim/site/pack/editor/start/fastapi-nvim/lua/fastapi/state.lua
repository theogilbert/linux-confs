-- Current apps and test index. Refreshes run in a coroutine, one parsed file per event-loop tick.
local app = require("fastapi.core.app")
local config = require("fastapi.config")
local discovery = require("fastapi.core.discovery")
local extract = require("fastapi.core.extract")
local graph = require("fastapi.core.graph")
local imports = require("fastapi.core.imports")
local paths = require("fastapi.core.paths")
local rg = require("fastapi.core.rg")
local testindex = require("fastapi.core.testindex")

local M = {}

---@class fastapi.Snapshot
---@field apps fastapi.App[]
---@field index fastapi.TestIndex
---@field links fastapi.Links
---@field by_file table<string, { routes: fastapi.Route[], calls: fastapi.TestCall[] }>
---@field workspace string
---@field status "idle"|"scanning"
---@field errors string[]
---@field missing_rg { discovery: boolean, tests: boolean }

---@class fastapi.Job
---@field await fun(start: fun(cb: fun(...))): ...
---@field tick fun()

---@type fastapi.Snapshot?
local current
local generation = 0
local notified_rg = false
---@type uv.uv_timer_t?
local timer
---@type { full: boolean, rediscover: boolean, paths: table<string, true> }
local pending = { full = false, rediscover = false, paths = {} }

---@param workspace string
---@return fastapi.Snapshot
local function empty_snapshot(workspace)
    return {
        apps = {},
        index = {},
        links = { calls_by_route = {}, routes_by_call = {} },
        by_file = {},
        workspace = workspace,
        status = "scanning",
        errors = {},
        missing_rg = { discovery = false, tests = false },
    }
end

---@param apps fastapi.App[]
---@param index fastapi.TestIndex
---@param workspace string
---@param errors string[]
---@param missing { discovery: boolean, tests: boolean }
---@return fastapi.Snapshot
local function build_snapshot(apps, index, workspace, errors, missing)
    local by_file = {}
    local function entry(file)
        by_file[file] = by_file[file] or { routes = {}, calls = {} }
        return by_file[file]
    end
    for _, route in ipairs(app.collect_routes(apps)) do
        table.insert(entry(route.location.file).routes, route)
    end
    for file, calls in pairs(index) do
        entry(file).calls = calls
    end
    return {
        apps = apps,
        index = index,
        links = testindex.link(apps, index),
        by_file = by_file,
        workspace = workspace,
        status = "idle",
        errors = errors,
        missing_rg = missing,
    }
end

---@param event string
local function fire(event)
    vim.api.nvim_exec_autocmds("User", { pattern = event, modeline = false })
end

---@param snapshot fastapi.Snapshot
---@param previous fastapi.Snapshot?
local function publish(snapshot, previous)
    for _, err in ipairs(snapshot.errors) do
        if not (previous and vim.tbl_contains(previous.errors, err)) then
            vim.notify("fastapi.nvim: " .. err, vim.log.levels.WARN)
        end
    end
    current = snapshot
    fire("FastAPIRefreshed")
end

-- Superseded jobs stop silently: `resume` ignores them once `generation` has moved on.
---@param body fun(job: fastapi.Job)
local function spawn(body)
    generation = generation + 1
    local mine = generation
    local co = coroutine.create(body)
    local function resume(...)
        if mine ~= generation then
            return
        end
        local ok, err = coroutine.resume(co, ...)
        if not ok then
            if current then
                current.status = "idle"
            end
            vim.notify("fastapi.nvim: " .. debug.traceback(co, tostring(err)), vim.log.levels.ERROR)
        end
    end
    ---@type fastapi.Job
    local job = {
        await = function(start)
            start(resume)
            return coroutine.yield()
        end,
        -- A timer, not vim.schedule: chained scheduled callbacks starve the event loop.
        tick = function()
            vim.defer_fn(resume, 0)
            coroutine.yield()
        end,
    }
    resume(job)
end

---@param errors string[]
---@param err string
local function add_error(errors, err)
    if not vim.tbl_contains(errors, err) then
        errors[#errors + 1] = err
    end
end

---@param err string?
---@param part "discovery"|"tests"
---@param errors string[]
---@param missing { discovery: boolean, tests: boolean }
local function note_rg_failure(err, part, errors, missing)
    if err == rg.NOT_FOUND then
        missing[part] = true
    else
        add_error(errors, err or "rg failed")
    end
end

---@param job fastapi.Job
---@param workspace string
---@param errors string[]
---@param missing { discovery: boolean, tests: boolean }
---@return fastapi.DiscoveredApp[]
local function discover(job, workspace, errors, missing)
    local entry, err = discovery.entrypoint(workspace)
    if err then
        add_error(errors, err)
        return {}
    elseif entry then
        return { entry }
    end
    local files, rg_err = job.await(function(cb)
        discovery.candidates(workspace, { exclude_dirs = config.options.exclude_dirs }, cb)
    end)
    if not files then
        note_rg_failure(rg_err, "discovery", errors, missing)
        return {}
    end
    local found = {}
    for _, file in ipairs(files) do
        job.tick()
        vim.list_extend(found, discovery.apps_in_file(file))
    end
    return discovery.finalize(found, workspace, job.tick)
end

---@param job fastapi.Job
---@param workspace string
---@param discovered fastapi.DiscoveredApp[]
---@param errors string[]
---@return fastapi.App[]
local function build_apps(job, workspace, discovered, errors)
    local apps = {}
    for _, found in ipairs(discovered) do
        local root = imports.project_root(found.file, workspace)
        local node = graph.build(found.file, root, found.var, job.tick)
        if node then
            apps[#apps + 1] = app.to_app(node, found.source)
        elseif found.source == "pyproject" then
            add_error(errors, ("fastapi entrypoint: no app %s in %s"):format(found.var, found.file))
        end
    end
    return apps
end

---@param job fastapi.Job
---@param workspace string
---@param errors string[]
---@param missing { discovery: boolean, tests: boolean }
---@return fastapi.TestIndex
local function build_index(job, workspace, errors, missing)
    local index = {}
    local files, err = job.await(function(cb)
        testindex.files(workspace, { exclude_dirs = config.options.exclude_dirs }, cb)
    end)
    if not files then
        note_rg_failure(err, "tests", errors, missing)
        return index
    end
    for _, file in ipairs(files) do
        job.tick()
        testindex.update(index, file)
    end
    return index
end

local function clear_pending()
    if timer then
        timer:stop()
        timer:close()
        timer = nil
    end
    pending = { full = false, rediscover = false, paths = {} }
end

function M.refresh()
    clear_pending()
    local workspace = vim.fn.getcwd()
    local previous = current
    if current then
        current.status = "scanning"
    else
        current = empty_snapshot(workspace)
    end
    fire("FastAPIScanning")
    spawn(function(job)
        local errors, missing = {}, { discovery = false, tests = false }
        local apps = build_apps(job, workspace, discover(job, workspace, errors, missing), errors)
        local index = #apps > 0 and build_index(job, workspace, errors, missing) or {}
        publish(build_snapshot(apps, index, workspace, errors, missing), previous)
    end)
end

---@param previous fastapi.Snapshot
---@param written string[]
---@param rediscover boolean
local function refresh_incrementally(previous, written, rediscover)
    local workspace = previous.workspace
    spawn(function(job)
        local errors = rediscover and {} or vim.list_slice(previous.errors)
        local missing = vim.deepcopy(previous.missing_rg)
        local discovered = rediscover and discover(job, workspace, errors, missing)
            or vim.tbl_map(function(known)
                return { file = known.file, var = known.name, source = known.source }
            end, previous.apps)
        local apps = build_apps(job, workspace, discovered, errors)
        local index = {}
        if #apps > 0 and #previous.apps == 0 then
            index = build_index(job, workspace, errors, missing)
        elseif #apps > 0 then
            index = vim.tbl_extend("force", {}, previous.index)
            for _, path in ipairs(written) do
                if not testindex.is_ignored(path, config.options.exclude_dirs) then
                    testindex.update(index, path)
                end
            end
        end
        publish(build_snapshot(apps, index, workspace, errors, missing), previous)
    end)
end

local function flush()
    local written, rediscover, full = vim.tbl_keys(pending.paths), pending.rediscover, pending.full
    clear_pending()
    if not current then
        return
    end
    if full or current.status == "scanning" then
        M.refresh()
    else
        refresh_incrementally(current, written, rediscover)
    end
end

local function arm_timer()
    timer = timer or vim.uv.new_timer()
    assert(timer):stop()
    assert(timer):start(config.options.refresh.debounce_ms, 0, vim.schedule_wrap(flush))
end

---@param path string
---@return boolean
local function mentions_fastapi(path)
    local file = io.open(path, "r")
    if not file then
        return false
    end
    local text = file:read("*a")
    file:close()
    return text:find("FastAPI", 1, true) ~= nil
end

---@return fastapi.Snapshot
function M.get()
    if not current then
        M.refresh()
    end
    return assert(current)
end

---@return boolean
function M.exists()
    return current ~= nil
end

---@param path string
function M.on_write(path)
    extract.invalidate(path)
    if not current or not paths.is_within(path, current.workspace) then
        return
    end
    local rediscover = vim.endswith(path, "pyproject.toml") or mentions_fastapi(path)
    if #current.apps == 0 and not rediscover then
        return
    end
    pending.paths[path] = true
    pending.rediscover = pending.rediscover or rediscover
    pending.full = pending.full or current.status == "scanning"
    arm_timer()
end

function M.on_focus()
    if current then
        pending.full = true
        arm_timer()
    end
end

function M.reset()
    generation = generation + 1
    current = nil
    clear_pending()
    extract.clear()
end

---@param part "discovery"|"tests"
function M.need_rg(part)
    if notified_rg then
        return
    end
    if not current or current.status == "scanning" then
        vim.api.nvim_create_autocmd("User", {
            pattern = "FastAPIRefreshed",
            once = true,
            callback = function()
                M.need_rg(part)
            end,
        })
    elseif current.missing_rg[part] then
        notified_rg = true
        vim.notify(
            "fastapi.nvim: ripgrep (rg) not found in PATH, see :checkhealth fastapi",
            vim.log.levels.ERROR
        )
    end
end

return M
