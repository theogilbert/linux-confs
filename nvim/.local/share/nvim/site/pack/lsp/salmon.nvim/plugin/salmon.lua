if vim.g.loaded_salmon then
  return
end
vim.g.loaded_salmon = true

local subcommands = {
  trace = function()
    require("salmon").trace()
  end,
  toggle = function()
    require("salmon").toggle()
  end,
  close = function()
    require("salmon").close()
  end,
  derive = function()
    require("salmon").toggle_derive()
  end,
  refresh = function()
    require("salmon").refresh()
  end,
  next = function()
    require("salmon").next()
  end,
  prev = function()
    require("salmon").prev()
  end,
  next_path = function()
    require("salmon").next_path()
  end,
  prev_path = function()
    require("salmon").prev_path()
  end,
}

-- <Plug> mappings, e.g. vim.keymap.set("n", "<leader>lt", "<Plug>(salmon-trace)")
local plugs = {
  ["salmon-trace"] = "trace",
  ["salmon-toggle"] = "toggle",
  ["salmon-close"] = "close",
  ["salmon-refresh"] = "refresh",
  ["salmon-derive"] = "toggle_derive",
  ["salmon-next"] = "next",
  ["salmon-prev"] = "prev",
  ["salmon-next-path"] = "next_path",
  ["salmon-prev-path"] = "prev_path",
}
for name, fn in pairs(plugs) do
  vim.keymap.set("n", "<Plug>(" .. name .. ")", function()
    require("salmon")[fn]()
  end, { desc = "salmon: " .. fn:gsub("_", " ") })
end

vim.api.nvim_create_user_command("Salmon", function(opts)
  local fn = subcommands[opts.fargs[1] or "trace"]
  if not fn then
    vim.notify("salmon: unknown subcommand " .. opts.fargs[1], vim.log.levels.ERROR)
    return
  end
  fn()
end, {
  nargs = "?",
  complete = function(lead)
    return vim.tbl_filter(function(s)
      return s:find(lead, 1, true) == 1
    end, vim.tbl_keys(subcommands))
  end,
  desc = "Trace where the symbol under the cursor comes from",
})
