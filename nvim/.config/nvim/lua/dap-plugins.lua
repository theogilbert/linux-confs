local M = {}

local winutils = require("utilities.buffer")

vim.api.nvim_create_autocmd("FileType", {
  pattern = "dap-repl",
  callback = function()
    require('dap.ext.autocompl').attach()
  end
})

local dap = require('dap')

dap.listeners.after.event_stopped["center_breakpoint_line"] = function(session, body)
    vim.defer_fn(function()
        vim.cmd("normal! zz")
    end, 50)
end

vim.fn.sign_define('DapBreakpoint', {text='🛑', texthl='', linehl='', numhl=''})

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
    cwd = "${workspaceFolder}"
}

local make_python_cfg = function(attrs)
    return vim.tbl_extend("error", python_cfg_preset, attrs)
end

local run_cmd_cfg = make_python_cfg( { name = "Run command" } )
setmetatable(run_cmd_cfg, {
        __call = function(cfg)
            local venv = os.getenv("VIRTUAL_ENV")
            local cmd = vim.fn.input("Command: ")
            local parts = vim.split(cmd, "%s+")

            if not vim.endswith(parts[1], ".py") and venv ~= nil then
                parts[1] = venv .. "/bin/" .. parts[1]
            end

            local program = parts[1]
            local args = vim.list_slice(parts, 2)

            return vim.tbl_extend("error", cfg, { program=program, args=args })
        end
    })


dap.configurations.python = {
    make_python_cfg( { name = "Launch file", program = "${file}" } ),
    run_cmd_cfg
}

local dapui = require('dapui')

function build_pane_layout(scope)
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
    },
})

local dapui_df = require('nvim-dap-df-pane')
dapui_df.setup()

-- Setup the new nvim-dap-df-pane plugin
local dap_df_pane = require('nvim-dap-df-pane')
dap_df_pane.setup({
  position = "bottom",
  size = 15,
  default_text = "No DAP session is currently running"
})

function M.set_bottom_pane(scope)
    dapui_df.close()
    dapui.close()
    local indices = { repl = 1, scopes = 2, watches = 3, stacks = 4, breakpoints = 5, dataframe = 6 }
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
M.show_dataframe_pane = function()
    dapui.close()
    dapui_df.open()
    winutils.focus_filetype('dap-df')
end


dap.listeners.before.attach.dapui_config = function()
  M.show_repl_pane()
end
dap.listeners.before.launch.dapui_config = function()
  M.show_repl_pane()
end
dap.listeners.before.event_terminated.dapui_config = function()
  dapui.close()
end
dap.listeners.before.event_exited.dapui_config = function()
  dapui.close()
end

require("nvim-dap-virtual-text").setup({
    virt_text_pos = 'eol'
})

return M
