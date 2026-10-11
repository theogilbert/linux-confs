-- envsubst placeholders: $VAR and ${VAR}
vim.cmd([[syntax match yamlEnvsubstVar /\$\%(\h\w*\|{\h\w*}\)/ containedin=ALL]])
vim.api.nvim_set_hl(0, "yamlEnvsubstVar", { default = true, link = "Special" })
