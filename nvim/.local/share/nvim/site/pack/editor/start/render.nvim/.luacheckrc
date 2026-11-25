-- luacheck reads this. `luacheck lua plugin tests` -- the same command
-- the CI workflow runs.

-- Neovim's Lua is LuaJIT, and every module here runs inside it.
std = "luajit"

-- The editor itself. Not read-only: half of what a plugin does is set
-- an option on a buffer or a window, and `vim.bo[buf].filetype = ...`
-- is an assignment into `vim` as far as this is concerned.
globals = { "vim" }

-- Long string literals -- a winbar's format, the sentence a warning is
-- written as -- are the only lines past 100, and stylua cannot break
-- them. 100 is what the formatter holds the code to; this is the wall.
max_line_length = 120

-- An unused argument is usually a callback keeping the shape its caller
-- expects: `function(data, err)` reads better than `function(data, _)`,
-- and dropping the name loses what the second value is.
unused_args = false

files["tests/spec"] = {
  -- describe, it, before_each and luassert's `assert`, which plenary
  -- puts in the globals of every spec file.
  std = "+busted",
  -- A name reused in a nested scope: `config` for the issue cache's
  -- own settings inside a file that has the plugin's, `out` for a
  -- table being built inside a file whose `out` is the stub's
  -- directory. The same word for the same kind of thing a block
  -- further in, which renaming would make harder to read rather than
  -- safer.
  ignore = { "431" },
}
