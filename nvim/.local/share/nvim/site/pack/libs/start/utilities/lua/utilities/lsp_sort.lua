local M = {}

--- Wrap vim.lsp.buf_request so `handler` is replaced with a sorting wrapper
--- for the given LSP method.
---@param method string  LSP method name
---@param score_fn fun(item: table, params: table): number
local function install(method, score_fn)
  local orig = vim.lsp.buf_request
  vim.lsp.buf_request = function(bufnr, m, params, handler, ...)
    if m ~= method then
      return orig(bufnr, m, params, handler, ...)
    end
    local wrapped = function(err, result, ctx, config)
      if not err and type(result) == "table" then
        table.sort(result, function(a, b)
          return score_fn(a, params) < score_fn(b, params)
        end)
      end
      return handler(err, result, ctx, config)
    end
    return orig(bufnr, m, params, wrapped, ...)
  end
end

--- Sort workspace/symbol results by match quality against the query.
function M.sort_workspace_symbols()
  install("workspace/symbol", function(item, params)
    local query = (params and params.query or ""):lower()
    if #query == 0 then return 0 end
    local name = (item.name or ""):lower()
    local pos = name:find(query, 1, true)
    if not pos then return 1000 + #name end
    return pos + #name
  end)
end

--- Deprioritize textDocument/references from test directories.
function M.deprioritize_test_references()
  install("textDocument/references", function(item)
    if (item.uri or ""):match("/tests?/") then return 500 end
    return 0
  end)
end

return M
