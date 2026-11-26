-- The colours this library draws with: links, `default` so that a
-- colorscheme or a user's own `:hi` wins, and set again after every
-- `:colorscheme` -- whose `:hi clear` takes default links away too.

local M = {}

local defined = {}

local function apply()
  for name, spec in pairs(defined) do
    vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", spec, { default = true }))
  end
end

vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("CommonHighlights", { clear = true }),
  callback = apply,
})

--- Defines `groups` ({ name = spec }) now and after every colorscheme.
function M.define(groups)
  for name, spec in pairs(groups) do
    defined[name] = spec
  end
  apply()
end

--- `fn()` now and after every colorscheme, once per `name`: for groups
--- a plugin works out from the colorscheme's own (a tint of `Normal`),
--- which a fixed spec cannot say. Calling it again with the same name
--- replaces the function rather than adding a second.
function M.watch(name, fn)
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("CommonHighlights_" .. name, { clear = true }),
    callback = function()
      fn()
    end,
  })
  fn()
end

--- `a` moved `amount` of the way towards `b`, channel by channel, both
--- 0xRRGGBB integers: 0 is `a`, 1 is `b`. Where either is missing, the
--- other.
function M.mix(a, b, amount)
  if not (a and b) then
    return a or b
  end
  local out = 0
  for _, shift in ipairs({ 65536, 256, 1 }) do
    local x = math.floor(a / shift) % 256
    local y = math.floor(b / shift) % 256
    out = out + math.floor(x + (y - x) * amount + 0.5) * shift
  end
  return out
end

--- How light 0xRRGGBB `c` is, 0 to 255, weighted as the eye weighs the
--- channels.
function M.lum(c)
  return 0.2126 * (math.floor(c / 65536) % 256)
    + 0.7152 * (math.floor(c / 256) % 256)
    + 0.0722 * (c % 256)
end

--- An attribute of group `name` with links followed: `get("Normal",
--- "bg")`. nil where the group does not set it.
function M.get(name, attr)
  local ok, spec = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  return ok and spec[attr] or nil
end

return M
