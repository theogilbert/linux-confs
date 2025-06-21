local M = {}

vim.api.nvim_create_autocmd("FileType", {
  pattern = "dap-repl",
  callback = function()
    require('dap.ext.autocompl').attach()
  end
})

local dap = require('dap')
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

local dap = require('dap')

dap.configurations.python = {
  {
    -- The first three options are required by nvim-dap
    type = 'python'; -- the type here established the link to the adapter definition: `dap.adapters.python`
    request = 'launch';
    name = "Launch file";

    -- Options below are for debugpy, see https://github.com/microsoft/debugpy/wiki/Debug-configuration-settings for supported options

    program = "${file}"; -- This configuration will launch the current file if used.
    pythonPath = function()
      -- debugpy supports launching an application with a different interpreter then the one used to launch debugpy itself.
      -- The code below looks for a `venv` or `.venv` folder in the current directly and uses the python within.
      -- You could adapt this - to for example use the `VIRTUAL_ENV` environment variable.
      local cwd = vim.fn.getcwd()
      if vim.fn.executable(cwd .. '/venv/bin/python') == 1 then
        return cwd .. '/venv/bin/python'
      elseif vim.fn.executable(cwd .. '/.venv/bin/python') == 1 then
        return cwd .. '/.venv/bin/python'
      else
        return '/usr/bin/python'
      end
    end;
  },
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
        build_pane_layout("scopes"),
        build_pane_layout("watches"),
        build_pane_layout("stacks"),
        build_pane_layout("repl"),
        build_pane_layout("breakpoints"),
    },
})

function M.set_bottom_pane(scope)
    dapui.close()
    indices = { scopes = 1, watches = 2, stacks = 3, repl = 4, breakpoints = 5 }
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
    -- TODO in this specific case, focus repl pane
end
M.show_breakpoints_pane = function()
    M.set_bottom_pane('breakpoints')
end


dap.listeners.before.attach.dapui_config = function()
  M.show_scopes_pane()
end
dap.listeners.before.launch.dapui_config = function()
  M.show_scopes_pane()
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
