-- Thin async wrappers around the LSP requests salmon needs.
local ts = require("salmon.ts")

local M = {}

local function client_for(buf, method)
  local cs = vim.lsp.get_clients({ bufnr = buf, method = method })
  if #cs > 0 then
    return cs[1]
  end
  -- Buffer loaded in the background (e.g. a caller's file): borrow a running
  -- client that handles this filetype and attach it.
  local ft = vim.bo[buf].filetype
  for _, c in ipairs(vim.lsp.get_clients({ method = method })) do
    local fts = c.config.filetypes
    if fts and vim.tbl_contains(fts, ft) then
      vim.lsp.buf_attach_client(buf, c.id)
      return c
    end
  end
end

local function line(buf, row)
  return vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
end

local function params(buf, row, col, client)
  local l = line(buf, row)
  return {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    position = {
      line = row,
      character = vim.str_utfindex(l, client.offset_encoding, math.min(col, #l), false),
    },
  }
end

--- LSP location -> { buf, row, col } (byte column), loading the file.
local function to_loc(uri, pos, client)
  local buf = vim.uri_to_bufnr(uri)
  ts.ensure_parsed(buf)
  local l = line(buf, pos.line)
  local col = vim.str_byteindex(l, client.offset_encoding, math.min(pos.character, vim.str_utfindex(l, client.offset_encoding)), false)
  return { buf = buf, row = pos.line, col = col }
end

local function request(buf, method, mk, cb)
  local client = client_for(buf, method)
  if not client then
    return cb(nil)
  end
  client:request(method, mk(client), function(err, result)
    vim.schedule(function()
      if err then
        cb(nil)
      else
        cb(result or {}, client)
      end
    end)
  end, buf)
end

--- Occurrences of the symbol in this buffer: { row, col, write }[], or nil
--- when no server supports documentHighlight.
function M.highlights(buf, row, col, cb)
  request(buf, "textDocument/documentHighlight", function(c)
    return params(buf, row, col, c)
  end, function(res, client)
    if not res then
      return cb(nil)
    end
    local out = {}
    for _, h in ipairs(res) do
      local loc = to_loc(vim.uri_from_bufnr(buf), h.range.start, client)
      out[#out + 1] = { row = loc.row, col = loc.col, write = h.kind == 3 }
    end
    cb(out)
  end)
end

local function locations(res, client)
  if res.uri or res.targetUri then
    res = { res }
  end
  local out = {}
  for _, l in ipairs(res) do
    local uri = l.uri or l.targetUri
    local range = l.range or l.targetSelectionRange or l.targetRange
    out[#out + 1] = to_loc(uri, range.start, client)
  end
  return out
end

function M.definition(buf, row, col, cb)
  request(buf, "textDocument/definition", function(c)
    return params(buf, row, col, c)
  end, function(res, client)
    cb(res and locations(res, client) or {})
  end)
end

function M.references(buf, row, col, cb)
  request(buf, "textDocument/references", function(c)
    local p = params(buf, row, col, c)
    p.context = { includeDeclaration = false }
    return p
  end, function(res, client)
    if not res then
      return cb(nil)
    end
    cb(locations(res, client))
  end)
end

return M
