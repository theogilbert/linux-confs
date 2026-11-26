-- Everything a user might want to change, in one table. `setup{}`
-- overlays theirs onto it. One table with no requires and no side
-- effects, so `plugin/render.lua` can read the keys out of it at
-- startup without loading anything else.
return {
  keys = {
    -- Turns the reader on and off in the current window: the file as it
    -- is written, and the file as it reads. From any buffer whose
    -- filetype is in `filetypes`, and from the reader itself. `false`
    -- unbinds it; `:Render` does the same thing.
    toggle = "<leader>rv",
    -- In the reader: what the cursor is on, followed (`follow`).
    follow = "<C-]>",
    -- In the reader: every key it answers, in a float. Needs
    -- common.nvim on the runtime path.
    help = "g?",
    -- In a table reader (csv, tsv): the next column whole into view,
    -- the previous one, hide the column under the cursor, and the
    -- picker that shows, hides and orders them all.
    column_next = "L",
    column_prev = "H",
    column_hide = "x",
    columns = "c",
  },

  -- The widest a line of prose is set. The window is the other half of
  -- the answer, and the narrower wins: prose set across a 200-column
  -- editor is prose nobody's eye can get back from the end of a line
  -- to the start of the next. `false` for the window's width alone.
  -- Code and tables are never folded -- the reader scrolls sideways.
  width = 80,

  -- A winbar on the reader saying it is one: the file's name and the
  -- key back to it, on a row of its own above the page rather than over
  -- any of it. A page and its source can look alike -- a plain README
  -- is nearly the same either way -- and only one of them takes an
  -- edit. `false` for none.
  winbar = true,

  -- What a link does when it is followed. nil is the built-in: its
  -- target is copied, to the unnamed register and the clipboard -- a
  -- page read in a terminal is as often read to be pasted from as
  -- clicked through -- and a `#heading` of this page is gone to.
  --
  -- A function is handed the link and the reader it was followed in,
  -- and does the whole of it:
  --
  --   follow = function(link, ctx)
  --     -- link: { kind = "url" | "path", href = "...", text = "..." }
  --     -- ctx:  { source = <buf>, view = <buf>, win = <win>,
  --     --         default = fn,  -- the built-in: copy, or go to `#a-heading`
  --     --         copy = fn,     -- the target to the registers
  --     --         go = fn,       -- the target opened: a URL with
  --     --                        -- `vim.ui.open`, a path its file (in
  --     --                        -- the reader too), `#a-heading` that
  --     --                        -- heading of this page
  --     --         show = fn }    -- the target in the command line
  --   end
  follow = nil,

  -- What the cursor coming onto a link does. nil is the built-in: its
  -- target in the command line, since the page draws the words and not
  -- where they lead. A function is handed what `follow` is (`default`
  -- is `show` here), once per link the cursor comes onto; `false` for
  -- nothing.
  hover = nil,

  -- Which reader each filetype is read in: a module with
  -- `render(lines, opts)`, returning lines of chunks as
  -- `render.draw.blocks` does. A filetype not here has no reader.
  filetypes = {
    markdown = "render.filetypes.markdown",
    csv = "render.filetypes.csv",
    tsv = "render.filetypes.tsv",
  },

  -- The table readers. Both need common.nvim on the runtime path.
  csv = {
    -- What a csv file's fields are separated by. nil guesses it from
    -- the first lines, out of `,`, tab, `;` and `|`: a file saved by a
    -- spreadsheet in a comma-decimal locale is `;`-separated and still
    -- called .csv. A tsv file is always tab-separated.
    delimiter = nil,
    -- Whether the first record names the columns. `false` numbers them.
    header = true,
    -- A column wider than this is left-aligned rather than centred, so
    -- a short value does not float in the middle of a long one.
    left_align = 40,
  },

  markdown = {
    -- Each reading on its own, so a page that means its asterisks can
    -- keep them.
    links = true,
    styles = true,
    math = true,
    headings = true,
    tables = true,
    citations = true,
    lists = true,
    -- `:tada:` as 🎉.
    emoji = true,
    -- A fence in the colours of its language, where treesitter has a
    -- parser for it.
    syntax = true,
    -- How each level of heading stands out, H1 first, since a terminal
    -- has no bigger type: `above`, the blank lines before it at the
    -- least; `band`, a ground across the page under it; `rule`, a
    -- character ruled across the page under it. Each part may be
    -- `false`, and a level `false` is its colour alone.
    heading = {
      { above = 2, band = true },
      { above = 2, rule = "━" },
      { above = 1, rule = "─" },
      { above = 1 },
      {},
      {},
    },
    bullets = { "•", "◦", "▪" },
    tasks = { "☐", "✓" },
    citation = "▎ ",
  },
}
