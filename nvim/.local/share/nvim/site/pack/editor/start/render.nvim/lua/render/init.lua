-- render.nvim: a file as it reads, a keypress away from the file as it
-- is written.
--
-- The engine is `render.markdown` (what each part of a text is) and
-- `render.draw` (what it looks like), and both are for anybody's use --
-- a plugin drawing markdown inside a float of its own wants exactly
-- them, with its own groups and hooks. The reader on top of them is
-- `render.view`.

local config = require("render.config")

local M = {}

local ready = false

--- The wiring the reader needs: its colours, and the colours again
--- after every `:colorscheme`. Done the first time anything is used, so
--- an editor that never reads anything never pays for it.
local function wire()
  if ready then
    return
  end
  ready = true
  require("render.highlights").setup()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("RenderColours", { clear = true }),
    callback = function()
      require("render.highlights").setup()
    end,
  })
end

--- Overlays `opts` onto the config. Every key may be set to `false` to
--- unbind it.
function M.setup(opts)
  opts = opts or {}
  -- The toggle is the one key bound at startup, so a new one replaces
  -- the old rather than joining it.
  local was = vim.g.render_toggle_key
  for k, v in pairs(opts) do
    if type(v) == "table" and type(config[k]) == "table" and not vim.islist(v) then
      config[k] = vim.tbl_deep_extend("force", config[k], v)
    else
      config[k] = v
    end
  end
  local now = config.keys.toggle
  if was and was ~= now then
    pcall(vim.keymap.del, "n", was)
    vim.g.render_toggle_key = nil
  end
  if now and now ~= "" and now ~= was then
    vim.keymap.set("n", now, function()
      M.toggle()
    end, { silent = true, desc = "render: read this file / edit it" })
    vim.g.render_toggle_key = now
  end
  wire()
end

--- The reader of the current window's file, on and off.
function M.toggle(win)
  wire()
  require("render.view").toggle(win)
end

--- Follows the link under the cursor in a reader.
function M.follow(win)
  require("render.view").follow(win)
end

return M
