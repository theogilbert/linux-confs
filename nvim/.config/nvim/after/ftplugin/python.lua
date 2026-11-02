local runner = require("utilities.runner")
vim.keymap.set("n", "<leader>r", runner.run_python_file, { buf = 0, desc = "[R]un python file" })
vim.keymap.set("v", "<leader>r", runner.send_selection_to_repl, { buf = 0, desc = "[R]un selection in REPL" })
