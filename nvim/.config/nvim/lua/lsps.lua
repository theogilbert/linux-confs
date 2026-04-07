M = {}

-- Sort workspace/symbol and textDocument/references LSP responses.
-- fzf-lua's live_workspace_symbols uses --disabled (no fzf sorting),
-- so results appear in whatever order the LSP returns them.
-- References from test directories are deprioritized (+500 malus).
do
  local orig_buf_request = vim.lsp.buf_request
  vim.lsp.buf_request = function(bufnr, method, params, handler, ...)
    if method ~= "workspace/symbol" and method ~= "textDocument/references" then
      return orig_buf_request(bufnr, method, params, handler, ...)
    end
    local query = type(params) == "table" and params.query or ""
    local wrapped = function(err, result, ctx, config)
      if not err and type(result) == "table" then
        local query_lower = #query > 0 and query:lower() or nil
        local function score(item)
          local s = 0
          if query_lower then
            local name = item.name or ""
            local name_lower = name:lower()
            local pos = name_lower:find(query_lower, 1, true)
            if not pos then s = 1000 + #name else s = pos + #name end
          end
          local uri = item.uri or ""
          if uri:match("/tests?/") then s = s + 500 end
          return s
        end
        table.sort(result, function(a, b)
          return score(a) < score(b)
        end)
      end
      return handler(err, result, ctx, config)
    end
    return orig_buf_request(bufnr, method, params, wrapped, ...)
  end
end

vim.diagnostic.config({
	virtual_text = false,
	underline = true,
	signs = true,
})

local cursorHoverGroup = vim.api.nvim_create_augroup("CursorHover", {})

vim.api.nvim_clear_autocmds({ group = cursorHoverGroup })
vim.api.nvim_create_autocmd({ "CursorHoldI" }, {
	pattern = { "*.py" },
	group = cursorHoverGroup,
	callback = function(_)
            vim.lsp.buf.signature_help({focusable= false, anchor_bias= "above"})
	end,
})

vim.keymap.set("n", "K", function()
    local buf = vim.api.nvim_get_current_buf()
    local diagnostics = vim.diagnostic.get(buf, { lnum = vim.api.nvim_win_get_cursor(0)[1] - 1 })

    if vim.tbl_isempty(diagnostics) then
        -- No diagnostics, just show hover
        vim.lsp.buf.hover({ focusable = false })
    else
        -- Capture LSP hover text
        vim.lsp.buf_request(buf, "textDocument/hover", vim.lsp.util.make_position_params(), function(_, result)
            -- Show both hover and diagnostics in one window
            local contents = {}

            if result and result.contents then
                local value = type(result.contents) == 'string' and result.contents
                    or result.contents.value or ''
                vim.list_extend(contents, vim.split(value, '\n', { trimempty = true }))
            end

            -- Add a separator
            table.insert(contents, " ")

            -- Add diagnostics
            for _, diag in ipairs(diagnostics) do
                table.insert(contents, " " .. diag.message) -- Add a warning icon (nerdfont required)
            end

            -- Show everything in a floating window
            vim.lsp.util.open_floating_preview(contents, "markdown", { border = "rounded" })
        end)
    end
end, { silent = true })

local capabilities = require("cmp_nvim_lsp").default_capabilities()

vim.lsp.config("basedpyright", {
	settings = {
		basedpyright = {
			disableOrganizeImports = true, -- Using Ruff
                        typeCheckingMode = "strict",
		},
		python = {
			analysis = {
				ignore = { "*" }, -- Using Ruff
				typeCheckingMode = "on",
			},
		},
	},
	capabilities = capabilities,
})

vim.lsp.config("ty", {
    settings = {
        ty = {
        }
    },
    capabilities = capabilities,
})

vim.lsp.enable("ty")

local augroup = vim.api.nvim_create_augroup("LspFormatting", {})

vim.lsp.config("ruff", {
	capabilities = capabilities,
        init_options = {
            settings = {
                codeAction = { disableRuleComment = { enable = false}}
            }
        },
})
vim.lsp.enable("ruff")

local ruff_watcher_enabled = false

local function ruff_format_on_save(args)
    local buf = args.buf
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local input = table.concat(lines, "\n") .. "\n"
    local fixed = vim.fn.system({ "ruff", "check", "--fix-only", "-q", "--ignore", "F841,F842", "-" }, input)
    if vim.v.shell_error == 0 then input = fixed end
    local formatted = vim.fn.system({ "ruff", "format", "-" }, input)
    if vim.v.shell_error == 0 then input = formatted end
    local new_lines = vim.split(input, "\n", { trimempty = false })
    -- remove trailing empty string from split
    if new_lines[#new_lines] == "" then table.remove(new_lines) end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
end

local function toggle_ruff_watcher()
    ruff_watcher_enabled = not ruff_watcher_enabled
    if ruff_watcher_enabled then
        vim.api.nvim_create_autocmd("BufWritePre", {
            group = augroup,
            pattern = "*.py",
            callback = ruff_format_on_save,
        })
        vim.notify("Ruff file watcher enabled")
    else
        vim.api.nvim_clear_autocmds({ group = augroup, pattern = "*.py" })
        vim.notify("Ruff file watcher disabled")
    end
end

if vim.fn.executable("ruff") == 1 then
    toggle_ruff_watcher()
    vim.keymap.set("n", "<leader>lw", toggle_ruff_watcher, { desc = "Toggle ruff file[w]atcher" })
end

vim.lsp.config("yamlls", {
    filetypes = { "yaml", "yml" },
    flags = { debounce_test_changes = 150 },
    settings = {
        yaml = {
            format = {
                enable = true,
                singleQuote = true,
                printWidth = 120,
            },
            hover = true,
            completion = true,
            validate = true,
            schemas = {
                [vim.fn.stdpath("data") .. "/schemas/yaml/gitlab-ci.json"] = {
                    "/.gitlab-ci.yml",
                    "/.gitlab-ci.yaml",
                }
            },
        },
    }
})
vim.lsp.enable("yamlls")

vim.lsp.enable("ts_ls")
local cmd_utils = require("utilities.commands")

M.sort_imports = function()
    vim.lsp.buf.code_action({
        apply = true,
        filter = function(action)
            return action.kind == "source.organizeImports.ruff"
        end,
    })
end

M.run_code_actions = function()
    vim.lsp.buf.code_action({filter = function(x)
        if x.kind == "source.organizeImports.ruff" then
            local filepath = vim.fn.expand('%:p')
            return not cmd_utils.run_and_check("ruff check --select I00 " .. filepath)
        elseif x.kind == "source.fixAll.ruff" then
            local filepath = vim.fn.expand('%:p')
            local ruff_diff = vim.fn.system("ruff check --diff " .. filepath)
            return ruff_diff:match("^No errors would be fixed") == nil and ruff_diff ~= ""
        elseif x.kind == "quickfix" and x.title:match("Ignore .+ for this line") ~= nil then
            return false
        end
        return true
    end})
    if vim.bo.filetype == "python" then
        local group = vim.api.nvim_create_augroup("RuffSortImportsAfterAction", { clear = true })
        vim.api.nvim_create_autocmd("TextChanged", {
            group = group,
            buffer = 0,
            once = true,
            callback = function()
                vim.defer_fn(M.sort_imports, 100)
            end,
        })
    end
end

vim.lsp.config("lua_ls", {
  on_init = function(client)
    if client.workspace_folders then
      local path = client.workspace_folders[1].name
      if
        path ~= vim.fn.stdpath('config')
        and (vim.uv.fs_stat(path .. '/.luarc.json') or vim.uv.fs_stat(path .. '/.luarc.jsonc'))
      then
        return
      end
    end

    client.config.settings.Lua = vim.tbl_deep_extend('force', client.config.settings.Lua, {
      runtime = {
        version = 'LuaJIT',
        path = { 'lua/?.lua', 'lua/?/init.lua' },
      },
      workspace = {
        checkThirdParty = false,
        library = {
          vim.env.VIMRUNTIME
        }
      }
    })
  end,
  settings = {
    Lua = {}
  }
})

if vim.fn.executable("lua-language-server") then
    vim.lsp.enable("lua_ls")
end


return M
