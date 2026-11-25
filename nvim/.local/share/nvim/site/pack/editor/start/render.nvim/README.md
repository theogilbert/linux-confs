# render.nvim

A file as it reads, a keypress away from the file as it is written.

`<leader>rv` in a markdown buffer puts the page in the window in the
file's place: headings without their hashes, `**bold**` as bold, links
as their words, tables ruled, lists with bullets, `:tada:` as 🎉, fences
in the colours of their language. `<leader>rv` again and the file is
back, with the cursor on the line you were reading.

Markdown today. CSV, JSON and the rest are a reader each, behind the
same key (`filetypes`).

Needs Neovim 0.10 or newer. `:help render` is the same ground as this
file, with tags.

## The reader

The reader is a buffer of its own rather than a coat of paint over the
file's. What is drawn is not the file's lines with some characters
hidden: prose is wrapped again to the width of the window, a table is
ruled, a heading loses its hashes. Those are lines the file does not
have, so they are drawn into a scratch buffer, `render://<path>`, that
is put into the window and taken out again. The file is never touched.

It says so: a winbar on the reader reads `READER`, the file's name and
the key back to it, on a row of its own above the page so nothing on
the page is covered (`winbar = false` for none). A plain README looks
much the same either way, and only one of the two takes an edit.

It is kept in step with the file. Every change to the file and every
change of the window's width draws it again, so the reader in one split
and the file in another is a preview as you type.

- **Prose** is wrapped to the window, or to `width` (80) where the
  window is wider: a line across a 200-column editor is a line nobody's
  eye can get back from the end of. The lines of a paragraph are put
  back together first, so a file wrapped at 72 reads the same in a
  window of 60 as in one of 100. A hard break (`\` or two spaces at the
  end of a line) stays a break.
- **Code and tables** are never folded. A fence means what it means by
  its columns, and a ruled table cannot wrap, so the reader scrolls
  sideways instead (`nowrap`).
- **Headings** are told apart by what a page has besides size, since a
  terminal has no bigger type: a title on a band across the page, a
  section under a heavy rule, a subsection under a light one, more space
  above the higher ones (`markdown.heading`) -- and each level in a
  colour of its own, the colourscheme's where it has one per level.

What it reads: headings (`#` and underlined), emphasis (`*`, `_`, `~~`),
code spans, links inline, by reference (`[words][name]`) and bare,
pictures (drawn as their words), lists (bulleted, numbered, tasks),
citations (`>`, and GitLab's `>>>`), pipe tables with their alignment,
fences, rules, formulas (`$…$`, `$$…$$`, ```` ```math ````, drawn as
the Unicode they would be printed with), character references
(`&amp;`), `:emoji:` and `[[_TOC_]]`. What it does not read is drawn as
it was typed.

## Links

The page draws a link's words, not where it leads. With the cursor on
one, its target is shown in the command line; `<C-]>` on it copies the
target, to the unnamed register and the clipboard where there is one.

Both are yours to replace. `follow` is handed the link and the reader
it was followed in, and does the whole of it; `ctx` carries the
built-ins, for the links you do not want to handle yourself:

- `ctx.copy()` -- the target to the registers (`ctx.default` for
  `follow`);
- `ctx.go()` -- where it points: a URL opened with `vim.ui.open`, a path
  the file it names, beside the one being read and in the reader too
  where it has one, `#a-heading` that heading of this page (GitHub's and
  GitLab's anchors: lower case, punctuation gone, a dash for each
  space) and `other.md#a-heading` that heading of that one;
- `ctx.show()` -- the target in the command line (`ctx.default` for
  `hover`).

```lua
require("render").setup({
  follow = function(link, ctx)
    -- link: { kind = "url" | "path", href = "...", text = "..." }
    -- ctx:  { source = <buf>, view = <buf>, win = <win>,
    --         default = fn, copy = fn, go = fn, show = fn }
    if link.kind == "path" then
      ctx.go()
    else
      ctx.default()
    end
  end,
})
```

`hover` is handed the same, once each time the cursor comes onto a
link; `false` shows nothing.

## Setup

Nothing is needed: the command and the key are there at startup, and
the first use loads the rest. `setup{}` overlays what you give it onto
the defaults:

```lua
require("render").setup({
  keys = {
    toggle = "<leader>rv", -- the reader, on and off; false unbinds it
    follow = "<C-]>",      -- in the reader: follow (copy) the link
  },
  width = 80,              -- the widest prose is set; false for the window's
  winbar = true,           -- "READER", the file and the key back, above the page
  follow = nil,            -- function(link, ctx); see Links
  hover = nil,             -- function(link, ctx), or false; see Links
  filetypes = {            -- which reader reads which filetype
    markdown = "render.filetypes.markdown",
  },
  markdown = {
    links = true, styles = true, math = true, headings = true,
    tables = true, citations = true, lists = true,
    emoji = true,          -- :tada: as 🎉
    syntax = true,         -- fences in the colours of their language
    heading = {            -- each level, H1 first; any part can be false
      { above = 2, band = true }, -- blank lines above, a band under it
      { above = 2, rule = "━" },  -- a rule across the page under it
      { above = 1, rule = "─" },
      { above = 1 }, {}, {},
    },
    bullets = { "•", "◦", "▪" },
    tasks = { "☐", "✓" },
    citation = "▎ ",
  },
})
```

`:Render` is the toggle as a command.

## Colours

Every group is set with `default`, so a colourscheme or a `:hi` of yours
wins, and every group is set again after `:colorscheme`.

| group | what | from |
|---|---|---|
| `RenderHeading1`..`6` | a heading, by level, each a colour of its own | `@markup.heading.N.markdown`, else the first unused of `Title`, `Function`, `String`, `Identifier`, `Type`, `Special`, `Constant`, `Statement` |
| `RenderHeadingBand` | the band under a heading | `Normal`'s ground towards `RenderHeading1` |
| `RenderHeadingRule1`..`6` | the rule under a heading | `RenderHeading1`..`6` |
| `RenderBold`, `RenderItalic`, `RenderStrike` | a weight, and no colour | |
| `RenderCode` | a code span, on a chip | `String` on `Normal` |
| `RenderLink` | a link | `DiagnosticInfo`, underlined |
| `RenderMath` | a formula | `Constant` |
| `RenderMeta` | the rules of a table, a fence's lines | `Comment` |
| `RenderCitation` | what was quoted, and its bar | `Comment` |
| `RenderTableHead` | a table's head | `Title` |
| `RenderOk` | a ticked task | `DiagnosticOk` |
| `RenderReader` | `READER` in the reader's winbar | `IncSearch` |

## The engine

The reader is built on two modules that are for anybody's use -- a
plugin drawing markdown inside a window of its own wants exactly them:

- `render.markdown` -- what each part of a text is: `blocks(lines,
  opts)` and `inline(line, opts)`, pure, strings in and tables out.
  Hooks for what it has never heard of: `link`/`url` for a link the
  caller knows better than "a page", `claims` for references like
  `#12` or `@name`, `fence` for a fence that is something else.
- `render.draw` -- what it looks like: `blocks(blocks, opts)` to lines
  of `{ text, hl }` chunks, the shape virtual text takes as it is, and
  `flatten` to plain lines, highlights and links for a real buffer. Its
  own groups, margin, glyphs and widths are all options, and `custom`
  draws a block it does not know.

Each module's head comment is its documentation.

For a plugin that keeps something of its own in step with the reader --
an outline of the file, say -- `render.view` says which buffer is which
and where a line went:

- `source_of(buf)` -- the file reader `buf` reads, or nil;
  `view_of(src)` -- the reader of file `src`, or nil;
- `to_view(src, row)` -- the reader's line that the file's line `row`
  is drawn on; `to_source(buf, row)` -- the file's line that the
  reader's line `row` was drawn from;
- `User RenderDrawn` -- fired each time a reader is drawn again (the
  file changed, the window was resized), with `data = { buf, source }`.

## Developing

```sh
./tests/run.sh             # headless nvim, plenary specs
./tests/check.sh           # luacheck, stylua, and the suite on the 0.10.4 floor too
```
