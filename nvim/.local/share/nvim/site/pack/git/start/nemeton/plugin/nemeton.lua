-- The two ways in, and nothing else at startup.
--
-- A command and a key, both of which resolve the plugin the first time
-- they are used: `require("nemeton")` pulls in ten modules, and a
-- reviewer who has not asked to review anything yet should not pay for
-- them at every `nvim`. The wiring the plugin needs to work -- the
-- highlight groups, the autocommands, the buffer-local keys -- is
-- `setup()`'s, and whichever of these is touched first calls it.
--
-- `nemeton.config` is the exception: it is one table with no requires
-- and no side effects, and the key below is in it.

if vim.g.loaded_nemeton then
  return
end
vim.g.loaded_nemeton = true

-- vim.system, vim.ui.open, extmark `sign_text` and `virt_lines` are all
-- 0.10-or-later, and none of them degrade. Said here, once, rather than
-- letting the first command fail somewhere inside a module.
if vim.fn.has("nvim-0.10") == 0 then
  vim.notify("nemeton: needs Neovim 0.10 or newer", vim.log.levels.ERROR)
  return
end

vim.api.nvim_create_user_command("Nemeton", function(opts)
  require("nemeton").command(opts)
end, {
  nargs = "*",
  complete = function(arg_lead)
    return require("nemeton").complete(arg_lead)
  end,
  desc = "nemeton: review merge requests",
})

local key = require("nemeton.config").keys.global.list
if key and key ~= "" then
  vim.keymap.set("n", key, function()
    require("nemeton").list()
  end, { silent = true, desc = "nemeton: merge requests" })
  -- Which key this file bound, so that a `setup{}` moving it can take
  -- the old one back rather than leaving both.
  vim.g.nemeton_global_key = key
end
