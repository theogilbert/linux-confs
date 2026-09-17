local M = {}

--- Full buffer text the way neovim would send it in a `didChange`.
---@param bufnr integer
---@param lines string[]
---@return string
local function full_text(bufnr, lines)
  local text = table.concat(lines, "\n")
  local bo = vim.bo[bufnr]
  if bo.eol or (bo.fixeol and not bo.binary) then
    text = text .. "\n"
  end
  return text
end

--- Send the server a full copy of a document.
---@param client vim.lsp.Client
---@param bufnr integer
---@param uri string
---@param text string
---@param version integer
local function sync(client, bufnr, uri, text, version)
  client:notify("textDocument/didChange", {
    textDocument = { uri = uri, version = version },
    contentChanges = { { text = text } },
  }, bufnr)
end

--- Make `textDocument/completion` work with the cursor inside an identifier
--- for servers that return nothing in that situation (ty does, for attribute
--- access such as `os.pa|th`). The server is shown a copy of the buffer with
--- the rest of the identifier removed for the duration of the request, then
--- the real buffer content again. Call it from the client's `on_attach`.
---@param client vim.lsp.Client
function M.complete_inside_identifiers(client)
  if client._completes_inside_identifiers then
    return
  end
  local sync_kind = client.server_capabilities.textDocumentSync
  local change = type(sync_kind) == "table" and sync_kind.change or sync_kind
  if change ~= vim.lsp.protocol.TextDocumentSyncKind.Incremental then
    return
  end
  client._completes_inside_identifiers = true

  local changetracking = require("vim.lsp._changetracking")
  local pending = {} -- per buffer, requests whose response has not arrived yet
  -- ty only notices a change when the version differs from the previous one.
  -- Temporary documents get versions no real change will ever have.
  local throwaway = -1e6

  local orig_request = client.request
  client.request = function(self, method, params, handler, bufnr)
    if method ~= "textDocument/completion" then
      return orig_request(self, method, params, handler, bufnr)
    end
    if bufnr == nil or bufnr == 0 then
      bufnr = vim.api.nvim_get_current_buf()
    end

    local pos = params.position
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local line = lines[pos.line + 1] or ""
    local col = vim.str_byteindex(line, self.offset_encoding, pos.character, false)
    local tail = line:sub(col + 1):match("^[%w_]+")
    if not tail then
      return orig_request(self, method, params, handler, bufnr)
    end
    local uri = params.textDocument.uri

    -- Edits neovim has not sent yet must reach the server first, otherwise
    -- they would later be applied on top of the wrong document.
    changetracking.flush(self, bufnr)
    lines[pos.line + 1] = line:sub(1, col) .. line:sub(col + #tail + 1)
    throwaway = throwaway - 1
    sync(self, bufnr, uri, full_text(bufnr, lines), throwaway)
    pending[bufnr] = (pending[bufnr] or 0) + 1

    local function restore()
      pending[bufnr] = pending[bufnr] - 1
      if pending[bufnr] > 0 or self:is_stopped() or not vim.lsp.buf_is_attached(bufnr, self.id) then
        return
      end
      changetracking.flush(self, bufnr)
      -- One below the real version: differs from both the throwaway one and
      -- the version of an edit made while the request was in flight, and
      -- stays out of the way of future edits.
      local version = vim.lsp.util.buf_versions[bufnr] - 1
      sync(self, bufnr, uri, full_text(bufnr, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)), version)
    end

    local ok, id = orig_request(self, method, params, function(...)
      restore()
      return handler(...)
    end, bufnr)
    if not ok then
      restore()
    end
    return ok, id
  end
end

return M
