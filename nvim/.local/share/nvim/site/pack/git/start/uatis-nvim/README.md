# uatis

Read a branch as code, not as a patch.

The file you are reading stays your file — same window, same undo history,
still writable — and what it replaced is drawn around it, or beside it.
The diff itself comes from [difftastic][], which compares syntax rather
than lines, so reindenting a block or moving a function reads as what it
was and not as a rewrite.

[difftastic]: https://difftastic.wilfred.me.uk/

Neovim 0.12+. `git` on your `PATH`. `difft` too, for structural diffing —
without it you get Neovim's line diff and the header says so.

## Start here

Nothing to configure: `<leader>gu` and `<leader>gB` are mapped when the
plugin loads. To move them, or anything else:

```lua
require("uatis").setup({
  keys = { global = { toggle_diff = "<leader>dr", base_branch = false } },
})
```

`<leader>gu` starts a review of your branch. The buffer you are in is
annotated against the **fork point** of your base branch —
`merge-base(base, HEAD)`, so someone else pushing to `main` does not
change what you changed — and the list of changed files comes up beside
it.

It stays on while you read. Every other file of the branch is annotated
as you arrive at it, however you got there — `]f`, a jump to definition,
a picker, `:e` — all against the same revision. Press `<leader>gu` again
and the whole thing goes: every annotated file, and the list. Turn the
following off with `pane.follow = false` and each file is annotated only
when you ask.

`:Uatis` does the same. `:Uatis <gitref>` compares against something else,
completing on your refs.

**The base** is detected: `origin/HEAD`, then `develop`, `master`,
`main`. `<leader>gB` picks another through `vim.ui.select` — the detected
default, then your tags, then your branches — with a last entry for
anything else: a remote branch, `HEAD~3`, a hash off a forge page —
`vim.ui.input`, offering completion over every ref you have, tags first,
where your input UI supports it. One choice per repository for
the editing session. Picking one re-points what is already
open — every view against the base branch, and the file list beside them,
move to the new fork point together. Views you named a revision for with
`:Uatis <gitref>` stay where you put them.

## In the diff

| key | |
| --- | --- |
| `]c` / `[c` | next / previous chunk |
| `]f` / `[f` | next / previous changed file |
| `<leader>gs` | side by side / in place |
| `<leader>gm` | structural / line diff |
| `<leader>gf` | the changed-file list, on and off |

`q` in the list closes that window and nothing else: the review goes on,
`]f` still steps it, and `<leader>gf` brings the window back to the same
list. From the file beside it, `<leader>gf` puts the cursor in the list;
from inside the list it puts the window away, which is the same thing `q`
does there. Ending a review is `<leader>gu` again, from anywhere.

These are buffer-local and handed back exactly as they were found —
including `]c` if you already had it mapped. `]f`/`[f` also work in any
file buffer while the list is open, so you can walk the branch without
going back to the pane; they are given back when it closes.

**In place**, what the branch removed is drawn as virtual lines around
your code, in the language's own colours, struck through. **Side by side**
puts the revision in a window to the left instead: a real buffer, so it
searches and yanks, with the two halves padded so a line and the line it
replaced sit on the same screen row, and the cursor and scroll kept in
step. Each window names what it shows — `main · 16859ad` on the left,
`working tree · on feature` on the right.

A file the branch **deleted** opens too: the revision on the left, nothing
opposite it.

## What the colours mean

Green is what came, red is what went, and both are your colourscheme's own
diff colours deepened — same hue, saturated up, held a fixed distance from
the editor's background, so they stay dark on a dark theme.

A line whose every token changed is painted whole. A line that kept even
one token is not: the tokens that changed are tinted and the rest is left
alone, which is what difftastic's own display does. Inside a changed
string or comment, the words that are actually new are picked out in a
stronger shade — difftastic shows those too, and its JSON does not report
them, so they are worked out here.

Structural mode is a window onto difftastic rather than a second opinion
about it. Line mode is `vim.diff` with the histogram algorithm, which
picks better hunk boundaries than git's default Myers on a restructured
file.

## Configuration

`setup()` takes the same shape as `lua/uatis/config.lua`, and you name
only the parts you mean:

```lua
require("uatis").setup({
  pane = {
    auto_open = false,                -- no file list unless you ask for it
    follow = false,                   -- ...and annotate a file only when asked
  },
  list = { width = 48 },              -- the list's width when you do open it
  diff = { default_backend = "line" },
  keys = { view = { layout = "<leader>gv" } },
})
```

Anything you leave out keeps its default, at any depth; a list you do
give — `base.fallbacks` — replaces the one underneath rather than being
appended to it. A key that is not an option is a typo, and it says so.

`lua/uatis/config.lua` is the reference for what there is: keys, colours,
the pane's width and whether it opens with the view (`pane.auto_open`),
and the diff engines. `diff.default_backend` is where a view starts, not
what it is stuck with — `<leader>gm` moves between the two at any time —
and the settings for each live under `diff.struct` and `diff.line`,
since almost all of them are about refining Neovim's line diff and none
of those touch what difftastic says. Each entry says what it is for and
what happens at the other settings.

## Checking it works

```
:checkhealth uatis
```

## Tests

```
tests/run.sh
```

Builds a throwaway repository and drives the real thing against it
headlessly — extmarks, window state, mappings, lifetimes.
