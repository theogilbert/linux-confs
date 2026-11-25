-- A command and a key, and nothing else at startup: both resolve the
-- plugin the first time they are used.

if vim.g.loaded_render then
  return
end
vim.g.loaded_render = true

if vim.fn.has("nvim-0.10") == 0 then
  vim.notify("render: needs Neovim 0.10 or newer", vim.log.levels.ERROR)
  return
end

vim.api.nvim_create_user_command("Render", function()
  require("render").toggle()
end, { desc = "render: read this file / edit it" })

local key = require("render.config").keys.toggle
if key and key ~= "" then
  vim.keymap.set("n", key, function()
    require("render").toggle()
  end, { silent = true, desc = "render: read this file / edit it" })
  -- Which key this file bound, so that a `setup{}` moving it can take
  -- the old one back rather than leaving both.
  vim.g.render_toggle_key = key
end
