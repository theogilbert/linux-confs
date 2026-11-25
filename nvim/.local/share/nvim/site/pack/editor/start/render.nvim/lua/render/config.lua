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
  -- clicked through.
  --
  -- A function is handed the link and the reader it was followed in,
  -- and does the whole of it:
  --
  --   follow = function(link, ctx)
  --     -- link: { kind = "url" | "path", href = "...", text = "..." }
  --     -- ctx:  { source = <buf>, view = <buf>, win = <win>,
  --     --         default = fn,  -- the built-in: copy
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
    bullets = { "•", "◦", "▪" },
    tasks = { "☐", "✓" },
    citation = "▎ ",
  },
}
