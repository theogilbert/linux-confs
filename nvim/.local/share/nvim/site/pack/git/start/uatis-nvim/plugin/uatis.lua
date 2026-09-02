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

vim.api.nvim_create_user_command("UatisShow", function(opts)
  require("uatis").show_commit(opts.fargs[1])
end, {
  nargs = "?",
  complete = function(arg_lead)
    return require("uatis").complete_show(arg_lead)
  end,
  desc = "uatis: what one commit did, in a tab of its own (default: ask which)",
})

require("uatis").setup()
