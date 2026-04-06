M = {}


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
	on_attach = function(client, bufnr)
		if client.supports_method("textDocument/formatting") then
			vim.api.nvim_clear_autocmds({ group = augroup, buffer = bufnr })
			vim.api.nvim_create_autocmd("BufWritePre", {
				group = augroup,
				buffer = bufnr,
				callback = function()
					vim.lsp.buf.format()
				end,
			})
		end
	end,
})
vim.lsp.enable("ruff")

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
