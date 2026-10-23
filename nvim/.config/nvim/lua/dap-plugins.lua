local M = {}

local winutils = require("utilities.buffer")
local dap = require('dap')

dap.listeners.after.event_stopped["center_breakpoint_line"] = function(session, body)
    vim.defer_fn(function()
        -- focus stayed in a terminal (e.g. stop triggered by a curl run there):
        -- :normal is not allowed in terminal mode, and there is no frame to center anyway
        if vim.api.nvim_get_mode().mode == "t" then
            return
        end
        vim.cmd("normal! zz")
    end, 50)
end

-- On an exception stop, nvim-dap requests exceptionInfo and turns the answer
-- into a diagnostic on the stopped line (readable with K); nvim-dap-virtual-text
-- renders it at eol. Both consume the response after this `before` listener,
-- so strip debugpy's noisy "(note: ... paused at: <frame>)" suffix here.
dap.listeners.before.exceptionInfo["strip_note"] = function(_, _, response)
    local details = response and response.details
    if details and details.typeName then
        details.typeName = details.typeName:gsub("%s+%(note:.*%)$", "")
    end
end


vim.fn.sign_define('DapBreakpoint', {text='🛑', texthl='', linehl='', numhl=''})
vim.fn.sign_define('DapBreakpointCondition', {text='🟡', texthl='', linehl='', numhl=''})
vim.fn.sign_define('DapStopped', {text='', texthl='', linehl='debugPC', numhl=''})

dap.adapters.python = function(cb, config)
  if config.request == 'attach' then
    ---@diagnostic disable-next-line: undefined-field
    local port = (config.connect or config).port
    ---@diagnostic disable-next-line: undefined-field
    local host = (config.connect or config).host or '127.0.0.1'
    cb({
      type = 'server',
      port = assert(port, '`connect.port` is required for a python `attach` configuration'),
      host = host,
      options = {
        source_filetype = 'python',
      },
    })
  else
    cb({
      type = 'executable',
      command = vim.fn.expand('$HOME/.local/share/uv/tools/debugpy/bin/python'),
      args = { '-m', 'debugpy.adapter' },
      options = {
        source_filetype = 'python',
      },
    })
  end
end


local python_cfg_preset = {
    type = 'python';
    request = 'launch';
    pythonPath = function()
        local venv_path = os.getenv("VIRTUAL_ENV")
        if venv_path ~= nil then
            return venv_path .. "/bin/python"
        else
            return '/usr/bin/python'
        end
    end,
    justMyCode = false,
    -- run in a terminal buffer (the dapui console pane) rather than piping
    -- output to the repl, which shows ANSI color codes as raw text
    console = "integratedTerminal",
    cwd = "${workspaceFolder}"
}

local make_python_cfg = function(attrs)
    return vim.tbl_extend("error", python_cfg_preset, attrs)
end

local run_cmd_cfg = make_python_cfg( { name = "Run command" } )
setmetatable(run_cmd_cfg, {
        __call = function(cfg)
            local ok, cmd = pcall(vim.fn.input, "Command: ")
            if not ok or cmd == "" then
                return vim.tbl_extend("error", cfg, { program = dap.ABORT })
            end
            local parts = vim.split(cmd, "%s+")

            local venv = os.getenv("VIRTUAL_ENV")
            if not vim.endswith(parts[1], ".py") and venv ~= nil then
                parts[1] = venv .. "/bin/" .. parts[1]
            end

            local program = parts[1]
            local args = vim.list_slice(parts, 2)

            return vim.tbl_extend("error", cfg, { program=program, args=args })
        end
    })


local launch_file_with_args_cfg = make_python_cfg( {
    name = "Launch file with arguments",
    program = "${file}",
    args = function()
        -- <Esc> returns cancelreturn, <C-c> raises; an empty line launches without arguments
        local ok, args = pcall(vim.fn.input, { prompt = "Arguments: ", cancelreturn = vim.NIL })
        if not ok or args == vim.NIL then
            return dap.ABORT
        end
        -- honors quotes, e.g. --name "two words"
        return require("dap.utils").splitstr(args)
    end,
} )


dap.configurations.python = {
    make_python_cfg( { name = "Launch file", program = "${file}" } ),
    launch_file_with_args_cfg,
    run_cmd_cfg
}

-- dotted module path of a python file, and the directory it is importable from:
-- climbs parent directories as long as they are packages (contain __init__.py)
local function python_module_of(path)
    local parts = { vim.fn.fnamemodify(path, ":t:r") }
    local dir = vim.fn.fnamemodify(path, ":h")
    while vim.uv.fs_stat(dir .. "/__init__.py") do
        table.insert(parts, 1, vim.fn.fnamemodify(dir, ":t"))
        dir = vim.fn.fnamemodify(dir, ":h")
    end
    return table.concat(parts, "."), dir
end

-- offers to serve each top-level `app = FastAPI(...)` of the workspace through uvicorn
dap.providers.configs["fastapi"] = function(bufnr)
    if vim.bo[bufnr].filetype ~= "python" then
        return {}
    end

    local cwd = vim.fn.getcwd()
    local res = vim.system({
        "rg", "--no-heading", "--with-filename", "--line-number", "--type", "py", "-g", "!venv",
        "--only-matching", [[^\w+\s*(:\s*[\w.]+\s*)?=\s*(fastapi\.)?FastAPI\(]],
    }, { cwd = cwd, text = true }):wait()
    if res.code ~= 0 then
        return {}
    end

    local configs = {}
    for _, line in ipairs(vim.split(res.stdout, "\n", { trimempty = true })) do
        local file, lnum, var = line:match("^(.-):(%d+):([%w_]+)")
        if file then
            local module, app_dir = python_module_of(vim.fs.joinpath(cwd, file))
            table.insert(configs, make_python_cfg({
                name = ("FastAPI: %s:%s (%s:%s)"):format(module, var, file, lnum),
                module = "uvicorn",
                args = { module .. ":" .. var, "--app-dir", app_dir },
            }))
        end
    end
    return configs
end

-- Break at the raise point instead of letting the exception unwind:
--   uncaught      -- exception reaches the top and kills the program
--   userUnhandled -- raised in project code, only handled outside it (e.g. by pytest)
-- Both use project scope, not justMyCode, so stepping into libraries stays available.
dap.defaults.python.exception_breakpoints = { "uncaught", "userUnhandled" }

local dapui = require('dapui')

local function build_pane_layout(scope)
    return {
        elements = { {
            id = scope,
            size = 1
          }},
        position = "bottom",
        size = 15
      }
end

dapui.setup({
    layouts = {
        build_pane_layout("repl"),
        build_pane_layout("scopes"),
        build_pane_layout("watches"),
        build_pane_layout("stacks"),
        build_pane_layout("breakpoints"),
        build_pane_layout("console"),
    },
})

-- Setup the new nvim-dap-df-pane plugin
local dap_df = require('nvim-dap-df-pane')
dap_df.setup({ size = 15, limit = 1000 })

function M.set_bottom_pane(scope)
    dap_df.close()
    dapui.close()
    local indices = { repl = 1, scopes = 2, watches = 3, stacks = 4, breakpoints = 5, console = 6 }
    dapui.open({layout = indices[scope]})
end

M.show_scopes_pane = function()
    M.set_bottom_pane('scopes')
end
M.show_watches_pane = function()
    M.set_bottom_pane('watches')
end
M.show_stacks_pane = function()
    M.set_bottom_pane('stacks')
end
M.show_repl_pane = function()
    M.set_bottom_pane('repl')
end
M.show_breakpoints_pane = function()
    M.set_bottom_pane('breakpoints')
end
M.show_console_pane = function()
    M.set_bottom_pane('console')
end
M.show_dataframe_pane = function()
    dapui.close()
    dap_df.open()
    winutils.focus_filetype('dap-df')
end


dap.listeners.before.attach.dapui_config = function()
  M.show_console_pane()
end
dap.listeners.before.launch.dapui_config = function()
  M.show_console_pane()
end
-- debugpy debugs spawned python subprocesses as child sessions; their exit
-- must not close the UI while the parent session is still running.
local function close_ui_on_root_end(session)
  if session.parent == nil then
    dapui.close()
  end
end
dap.listeners.before.event_terminated.dapui_config = close_ui_on_root_end
dap.listeners.before.event_exited.dapui_config = close_ui_on_root_end

require("nvim-dap-virtual-text").setup({
    virt_text_pos = 'eol'
})

-- On session end the plugin clears its extmarks but keeps the pending
-- exception/stop-reason state, which then gets redrawn at the next session's
-- first stop. Reset it the same way a `continue` does.
local function forget_stop_reason(session)
    if session.parent ~= nil then
        return
    end
    -- Slash form on purpose: the plugin requires it that way, and a dotted
    -- require would load a second module instance with its own state.
    require("nvim-dap-virtual-text/virtual_text")._on_continue({ clear_on_continue = true })
end
dap.listeners.after.event_terminated["forget_stop_reason"] = forget_stop_reason
dap.listeners.after.event_exited["forget_stop_reason"] = forget_stop_reason

return M
