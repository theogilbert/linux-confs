-- `:checkhealth uatis`
--
-- Three things decide whether this plugin can do its job, and all three
-- are outside it: the Neovim version, git, and difftastic. Each failure
-- has a different consequence, so each says what you lose rather than
-- just what is missing.

local config = require("uatis.config")

local M = {}

local FLOOR = { 0, 12, 0 }

function M.check()
  vim.health.start("uatis")

  local v = vim.version()
  if vim.version.ge({ v.major, v.minor, v.patch }, FLOOR) then
    vim.health.ok(("Neovim %d.%d.%d"):format(v.major, v.minor, v.patch))
  else
    vim.health.error(
      ("Neovim %d.%d.%d is too old"):format(v.major, v.minor, v.patch),
      { ("uatis needs %d.%d or newer: the rendering uses inline virtual text, "):format(FLOOR[1], FLOOR[2])
        .. "multiline hl_eol ranges, statuscolumn and nvim_win_text_height" })
  end

  if vim.fn.executable("git") == 1 then
    vim.health.ok("git")
  else
    vim.health.error("git is not on your PATH", { "nothing works without it" })
  end

  local difft = config.diff.struct.bin
  if vim.fn.executable(difft) == 1 then
    local out = vim.system({ difft, "--version" }, { text = true }):wait()
    local version = vim.trim((out.stdout or ""):match("^[^\n]*") or "")
    vim.health.ok(version ~= "" and version or difft)
  else
    vim.health.warn(("%s is not on your PATH"):format(difft), {
      "structural diffing is difftastic, and there is no substitute for it here",
      "without it the diff is `vim.diff`, which cannot tell reindentation from a rewrite",
      "https://difftastic.wilfred.me.uk/",
    })
  end

  -- Neovim's parsers, and nothing to do with the diff: difftastic brings
  -- its own and this plugin never sees them. These colour the lines the
  -- branch REMOVED, which are drawn as virtual text -- and nothing
  -- highlights virtual text, so the old side is parsed separately to get
  -- the colours back. Missing one costs colour on those lines and
  -- nothing else, which is why this is not a warning.
  local parsers = {}
  for _, lang in ipairs({ "lua", "python", "c" }) do
    if pcall(vim.treesitter.language.add, lang) then
      table.insert(parsers, lang)
    end
  end
  if #parsers > 0 then
    vim.health.ok(("removed lines keep their colours (tree-sitter: %s…)")
      :format(table.concat(parsers, ", ")))
  else
    vim.health.info("removed lines will be drawn in one flat colour", {
      "they are virtual text, which no highlighter touches, so uatis parses",
      "the old side itself with Neovim's tree-sitter -- and found no parsers",
      "the diff itself does not use these: difftastic brings its own",
    })
  end
end

return M
