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
`main`. `<leader>gB` picks another through `vim.ui.select`, offering the
one in force and whichever of those conventional names this repository
actually has — a short list, because a picker is for the answer you
almost always want. Its last row, `type a revision…`, is for the rest:
a one-line prompt whose menu comes up as you type, over every branch,
tag and remote-tracking ref, and the last thousand commits. Each row
carries the date it was made, and a commit its subject line after it —
which is what a commit is matched on, since a sha is not something
anyone remembers.
`HEAD~3` and a hash off a forge page are simply typed. That prompt is
the plugin's own window rather than `vim.ui.input`, because completion
is the half of it that matters and a `vim.ui.input` replacement is free
to drop it.
One choice per repository, kept between sessions: a base chosen by hand
is written to `stdpath("state")/uatis/base.json` and read back next time,
because a project reviewed against `develop` or against the last release
tag is that way tomorrow too. What was merely *detected* is detected
again, and a remembered branch that has since been deleted is dropped
rather than failing at the fork point. `base.remember = false` turns it
off; a string puts the file somewhere else. Picking one re-points what is already
open — every view against the base branch, and the file list beside them,
move to the new fork point together. Views you named a revision for with
`:Uatis <gitref>` stay where you put them.

## In the diff

| key | |
| --- | --- |
| `]c` / `[c` | next / previous chunk |
| `]f` / `[f` | next / previous changed file |
| `<leader>go` | side by side / in place |
| `<leader>gm` | structural / line diff |
| `<leader>gf` | the changed-file list, on and off |

In the list, `za` folds the directory under the cursor away, `zc` and
`zo` say which way, and `<CR>` on a directory row toggles it. Over a
file row they act on the directory that file is in, the same thing they
mean over a line inside a fold anywhere else; `zc` over a directory
already shut closes its parent, so it walks back out of a nested tree.
`zM` folds the whole tree shut and `zR` opens it again — after `zM` the
list is the directories that changed and you open your way in, a level
per `zo`. The row stays; only what is under it goes. Walking into a
folded directory opens it, so the file you are reading always has a row.

Every directory row carries what changed beneath it — its whole subtree,
nested directories included — in the same `+N -M` the files use. Folded
shut, that count is the reason you would open it again.

The list counts the working tree, not the commits: a saved edit is in it
straight away, an unsaved one as soon as the buffer says so, and a file
git has never been told about is in it too — `.gitignore` decides what
that leaves out. It re-reads itself when you save, when something else
writes a file you are reading, and when you come back to nvim from a
terminal or another window, where git may have moved under it: switch a
branch or pull the base branch and the fork point moves with it.

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

## In a statusline

`status()` answers about the buffer, `review()` about the whole review,
both in plain data — numbers and strings, no highlight groups, nothing
to parse:

```lua
local uatis = require("uatis")

-- +12 -3 · main
local function component()
  local s = uatis.status()
  if not s then return "" end
  return ("+%d -%d · %s"):format(s.added, s.removed, s.base)
end
```

`status()` also carries `path`, `old_path` on a rename, `rev` (the fork
point it resolved to), `backend`, `layout`, `tracks_base` and `degraded`
— the last when difftastic was asked for and could not answer.
`review()` carries `files`, the totals across them, and the file the
list is standing on. Both return `nil` when there is nothing to say.

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
  keys = { view = { layout = "<leader>gS" } },
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
