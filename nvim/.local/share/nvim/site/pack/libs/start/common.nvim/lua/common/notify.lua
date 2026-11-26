-- Messages that say which plugin they are from.
--
--   local log = require("common.notify").new("grannos")
--   log.warn("no active connection")      -- "grannos: no active connection"
--   log.error(err)                         -- an error object, as text
--
-- The name as a prefix, since `vim.notify` itself prints a bare line,
-- and as `title` for a notifier (nvim-notify, fidget) that shows one.

local M = {}

local L = vim.log.levels

--- A notifier for plugin `name`: `info`, `warn`, `error`, `debug`, each
--- `f(msg, opts)`, and the table itself callable as `f(msg, level,
--- opts)`. `msg` is passed through `tostring`; `opts` goes to
--- `vim.notify` with the title added.
function M.new(name)
  local prefix = name .. ": "
  local function say(msg, level, opts)
    msg = tostring(msg)
    if msg:sub(1, #prefix) ~= prefix then
      msg = prefix .. msg
    end
    vim.notify(msg, level or L.INFO, vim.tbl_extend("keep", opts or {}, { title = name }))
  end
  local n = {}
  for method, level in pairs({ debug = L.DEBUG, info = L.INFO, warn = L.WARN, error = L.ERROR }) do
    n[method] = function(msg, opts)
      say(msg, level, opts)
    end
  end
  return setmetatable(n, {
    __call = function(_, msg, level, opts)
      say(msg, level, opts)
    end,
  })
end

return M
