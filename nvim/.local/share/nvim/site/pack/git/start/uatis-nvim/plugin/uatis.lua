if vim.g.loaded_uatis then
  return
end
vim.g.loaded_uatis = true

vim.api.nvim_create_user_command("Uatis", function(opts)
  require("uatis").run(opts)
end, {
  nargs = "?",
  complete = function(arg_lead)
    return require("uatis").complete(arg_lead)
  end,
  desc = "uatis: annotate this buffer against a revision (default: the base branch)",
})

require("uatis").setup()
