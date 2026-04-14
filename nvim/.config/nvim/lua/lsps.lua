M = {}

local lsp_sort = require("utilities.lsp_sort")
lsp_sort.sort_workspace_symbols()
lsp_sort.deprioritize_test_references()

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
                codeAction = { disableRuleComment = { enable = false}},
                lint = {
                    unfixable = { "F841", "F842" },
                },
            }
        },
})
vim.lsp.enable("ruff")

local ruff_watcher_enabled = false

local function ruff_format_on_save(args)
    local buf = args.buf
    local clients = vim.lsp.get_clients({ bufnr = buf, name = "ruff" })
    if #clients == 0 then return end
    local client = clients[1]
    local encoding = client.offset_encoding or "utf-16"
    local timeout = 10000

    -- 1. Apply Ruff's "fix all" code action synchronously, equivalent to
    --    `ruff check --fix-only` but applied as LSP text edits so extmarks
    --    (including DAP breakpoint signs) on untouched lines survive.
    local params = vim.lsp.util.make_range_params(0, encoding)
    params.context = { only = { "source.fixAll.ruff" }, diagnostics = {} }
    local results = vim.lsp.buf_request_sync(buf, "textDocument/codeAction", params, timeout)
    for _, res in pairs(results or {}) do
        for _, action in pairs(res.result or {}) do
            -- Ruff may return the edit inline, or as an unresolved action
            -- that requires a follow-up codeAction/resolve request.
            if not action.edit and action.data then
                local resolved = vim.lsp.buf_request_sync(buf, "codeAction/resolve", action, timeout)
                for _, r in pairs(resolved or {}) do
                    if r.result then action = r.result end
                end
            end
            if action.edit then
                vim.lsp.util.apply_workspace_edit(action.edit, encoding)
            end
            if action.command then
                client:exec_cmd(action.command, { bufnr = buf })
            end
        end
    end

    -- 2. Format synchronously.
    vim.lsp.buf.format({ async = false, bufnr = buf, name = "ruff" })
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
