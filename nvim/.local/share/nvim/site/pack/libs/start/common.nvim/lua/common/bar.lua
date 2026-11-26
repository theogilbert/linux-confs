-- Key hints for a winbar or statusline: `g? help  a approve  c comments`,
-- the keys in one colour and what they do in another.
--
-- Two colours because a hint row is searched, not read -- "what was
-- approve again" -- and letters that stand out make it a column of
-- answers with their labels beside them.

local hl = require("common.hl")

local M = {}

hl.define({
  CommonBarKey = { link = "Special" },
  CommonBarHint = { link = "Comment" },
})

--- `s` safe in a statusline expression: a bare `%` in a file name or a
--- commit subject is an item there, and corrupts all that follows it.
function M.escape(s)
  return (tostring(s):gsub("%%", "%%%%"))
end

--- The hints for `pairs` (`{ { lhs, what } }`, an lhs of false or ""
--- skipped), as a statusline string.
---
--- `opts.help`  -- the key listing all of them: first, since a narrow
---                 window must not cut the one that names the rest
--- `opts.key`, `opts.desc` -- the groups, `CommonBarKey`/`CommonBarHint`
--- `opts.width` -- the room there is: hints are dropped whole from the
---                 end until they fit, rather than cut mid-word. Without
---                 it they are cut at the end (`%<`), never the start.
--- `opts.sep`   -- between hints, two spaces
function M.hints(pairs, opts)
  opts = opts or {}
  local key, desc = opts.key or "CommonBarKey", opts.desc or "CommonBarHint"
  local sep = opts.sep or "  "
  local list = {}
  if opts.help and opts.help ~= "" then
    table.insert(list, { opts.help, "help" })
  end
  for _, h in ipairs(pairs) do
    if h[1] and h[1] ~= "" then
      table.insert(list, h)
    end
  end
  if opts.width then
    local function width_of(n)
      local w = 0
      for i = 1, n do
        w = w + vim.fn.strdisplaywidth(list[i][1] .. " " .. list[i][2])
      end
      return w + math.max(n - 1, 0) * vim.fn.strdisplaywidth(sep)
    end
    while #list > 0 and width_of(#list) > opts.width do
      table.remove(list)
    end
  end
  local out = {}
  for _, h in ipairs(list) do
    table.insert(out, ("%%#%s#%s%%#%s# %s"):format(key, M.escape(h[1]), desc, M.escape(h[2])))
  end
  return "%#" .. desc .. "#" .. table.concat(out, sep) .. "%<%*"
end

return M
