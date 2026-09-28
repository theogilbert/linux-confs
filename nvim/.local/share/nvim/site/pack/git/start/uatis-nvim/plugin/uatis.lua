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

vim.api.nvim_create_user_command("UatisHistory", function(opts)
  require("uatis").history({
    path = opts.fargs[1], range = opts.range, line1 = opts.line1, line2 = opts.line2,
  })
end, {
  nargs = "?",
  range = true,
  complete = "file",
  desc = "uatis: every commit that touched a file, a directory, or the lines in range",
})

vim.api.nvim_create_user_command("UatisAt", function(opts)
  require("uatis").at(opts.fargs[1])
end, {
  nargs = "?",
  complete = function(arg_lead)
    return require("uatis").complete_show(arg_lead)
  end,
  desc = "uatis: the project as it was at a revision, in a tab of its own (default: ask which)",
})

vim.api.nvim_create_user_command("UatisConflicts", function()
  require("uatis").conflicts()
end, {
  desc = "uatis: start or end a review of the files a merge stopped on",
})

vim.api.nvim_create_user_command("UatisColors", function()
  require("uatis").colors()
end, {
  desc = "uatis: tune the diff colours against this colourscheme, live",
})

require("uatis").setup()
