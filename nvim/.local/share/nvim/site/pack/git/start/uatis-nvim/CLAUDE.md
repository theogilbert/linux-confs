# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Neovim plugin (pure Lua, no build step) that annotates the buffer you are
already editing against a git revision, instead of showing a patch. Requires
Neovim 0.12+, `git`, and `difft` (difftastic) for structural diffing.

## Commands

```sh
tests/run.sh                      # build a fixture repo + run the headless suite
UATIS_FIXTURE=/path tests/run.sh  # reuse/place the fixture elsewhere
tests/fixture.sh <dir>            # build the fixture only
```

There is no single-test runner: `tests/run.lua` is one script of `do ... end`
blocks, each printed under a `[section name]` header. To iterate on one
section, build the fixture once and drive the script directly:

```sh
nvim --headless -u NONE --cmd 'set packpath=' --cmd "set rtp+=$PWD" \
  -l tests/run.lua /tmp/uatis-fixture
```

`packpath=` matters — without it the suite runs against whatever copy of the
plugin is installed in the user's site packages, not this checkout.

The suite exits nonzero on any failure and prints `N passed, M failed`. It
skips (not fails) the difftastic and tree-sitter sections when those are
absent, so a green run without `difft` on PATH is not full coverage.

`:checkhealth uatis` covers the three external requirements, then what
this repository says about itself — base, fork point, and the git config
that rewrites `git diff`. `health.facts(dir)` gathers that as data (and
is what the suite asserts on); `health.report(facts)` says what each fact
means.

## Architecture

### The invariant everything else follows from

The **new side of the diff is the live buffer** — the user's real file, with
unsaved edits, still writable, same undo history, same LSP. It is never
copied into a scratch buffer. Only the *old* side is fetched (`git.blob`) and
drawn around it as extmarks, or beside it in a second window. Any change that
would replace the user's buffer with a rendering breaks the premise of the
plugin.

The comparison is always against the **fork point**, `merge-base(base, HEAD)`
— three-dot semantics — so commits landing on the base branch after the fork
never appear as reversed changes.

### Layers

- `plugin/uatis.lua` — `:Uatis`, `:UatisShow` and `:UatisColors` commands
  + `setup()`. Not sourced under `-l`,
  so `tests/run.lua` calls `uatis.setup()` itself.
- `init.lua` — the public API (`setup`, `run`, `toggle_diff`,
  `set_base_branch`, `open_pane`/`close_pane`, `show_commit`,
  `since_commit`, `colors`, `complete`/`complete_show`, and
  `status`/`review`/`showing`, which answer in plain data -- the first two
  for a statusline, the third for a tool that has to know which file and
  which side a buffer is before acting on a line in it -- and are the
  only field names outside this repo's control). Owns the
  global keymaps, the options merge and the 0.12 version floor. `setup()`
  runs twice on a real install — `plugin/uatis.lua` with the defaults, then
  the user's own call — so it is idempotent and re-points the global
  mappings instead of stacking them.
- `base.lua` — what a view measures against. Usually a branch, but any
  revision git resolves: the `vim.ui.select` picker offers the base in
  force and whichever of `config.base.fallbacks` this repo has, then one
  row — `type a revision...` — that opens `prompt.lua` over every ref and
  the last `base.prompt_commits` commits, for a hash, a tag or anything
  else. One choice per repo root, kept across sessions in
  `stdpath("state")/uatis/base.json` (`config.base.remember`) — a CHOICE
  only, verified once before it is used and dropped if the ref is gone;
  detection (`origin/HEAD`, then `config.base.fallbacks`) is redone every
  session, and `base.source(root)` says which of the three an answer is.
  `resolve()` returns `(label, sha)` for the fork point.
- **How much of the tree.** `<leader>gB` opens `scope.lua` — a float
  with TWO entries, base and subtree, each answered by the picker or
  prompt that question already had (`base.ask`/`base.ask_dir`, which are
  `select`/`select_dir` with the deciding taken out). Neither is applied
  until `<C-s>`: they are one statement, and asked in sequence the first
  is already in force by the time the second is put. `q` and `<Esc>`
  discard, as `q` closes every other float here.
  `set_base_branch(name)` with a name given skips the panel entirely.
  The second answer is the review's SUBTREE, kept in the same
  `base.json` entry
  (`{ base, dir }`; a bare string from before it is still read as the
  base). `""` is the whole repository. It does two things at once: the
  list counts only what is under it and `pane.follow` only annotates
  files under it (`under`/`scoped_row` in `pane.lua`), and every path is
  drawn relative to it — the row keeps its real repo-relative `path` for
  opening and buffer matching and gains a `shown` that the tree rows,
  the fold keys and the header read (`ui.shown`). `pane.rescope` moves a
  live list to a new one without a git call, since which files the
  branch touched has not changed; folds go with it, being keyed on the
  path as drawn, and views on files the scope dropped are closed.
- `base.items`/`candidates`/`candidates_sync` — the one set of
  candidates for "which revision", offered by both the prompt and
  `:Uatis` completion. `git.refs_sync`/`commits_sync` are the waiting
  versions, and exist only for the command line, which cannot be
  answered later.
- `prompt.lua` — a one-line floating input of our own. The menu opens
  from `TextChangedI` (`<Tab>` and `omnifunc` are there too, but a
  completion engine may own `<Tab>` by the time the prompt has it) over
  candidates handed in: a string, or `{ word, menu, kind }`. Matching is
  word-prefix, then word-substring, then `menu` — which is how a commit
  is found by its subject. With nothing typed it shows a slice per
  `kind`, so branches cannot bury the tags. Not `vim.ui.input`:
  `completion` is a field a replacement may ignore, and the only prompt
  here is the one that is unusable without it.
- `git.lua` — every git call, async via `vim.system` + callback, never
  blocking. Blobs and commit patches are cached content-addressably by
  `root\0rev:path` and never evicted. Root is resolved once and passed
  explicitly to everything downstream.
- `diff.lua` — two backends behind one async interface,
  `compute(old_text, new_text, opts, cb)`. Structural = `difft --display
  json` (subprocess, cached by input text); line = `vim.diff` with the
  histogram algorithm. Failures **degrade to the line backend and set
  `unavailable`**, they never raise. The result carries `hunks`, plus
  optional `spans` / `pairs` / `anchor` / `precise` that only difftastic can
  produce. difftastic's row alignment is **not taken at face value**: a
  changed node's rows are paired by position, so a docstring that gained
  four lines comes back with its last old row paired against the first
  inserted one and an identical copy of that row below, drawn as an
  addition -- removed and added back at once. `realign` re-diffs each
  changed region by line and takes that answer only where it matches
  rows difftastic left unmatched, most of the region comes back matched,
  and the pairing actually differs; a genuine rewrite is left as
  difftastic read it, since its pairing is the better one there.
- `regions.lua` — the rescue for a file difftastic will not take whole.
  Past `DFT_GRAPH_LIMIT` difftastic compares words (`result.fallback =
  "graph limit"`, the reason read off its own `language` string by
  `diff.fallback_of`); the file is then cut at tree-sitter's top-level
  nodes (`units`), one piece per run of line-diff hunks widened to the
  units they fall in and brought back into step through the line diff's
  own matching (`pieces`), each piece run through difftastic on its own
  and the answers sewn into one JSON (`stitch`) for `from_json`. A piece
  with nothing on one side is written as all-added/all-removed rather
  than sent. Whole first, pieces as the rescue; a path that needed the
  rescue is cut first from then on (`cut_first` in `diff.lua`), since
  the whole-file attempt is three seconds per keystroke. `result.pieces`
  puts `in N pieces` on the winbar. Needs `syntax.lang_of` to find a
  parser; without one the text fallback stands.
- `moves.lua` — a definition moved within the file. Both backends
  align in order, so it arrives as a removal plus an addition; a
  tree-sitter node wholly inside one side's removed rows paired (by
  name, else by content, `config.diff.move`) with one wholly inside the
  other's added rows is a move. `diff.compute` runs the backend again
  over just the two copies and hangs `result.drawn` on the answer: both
  copies carved out, that comparison spliced in at the new place, and
  `moves` for the overlay, which draws a line at each end and a `]c`
  stop at each. `drawn` is for drawing ONLY: `view.hunks`, the read
  marks and the side window's ALIGNMENT keep the backend's answer,
  which is git's and in order. The side window marks from `drawn`
  (`view.del_spans`/`del_hunks`), so the old copy is not red, and
  `oldside` reaches across a move by asking (`move_of`/`across`, over
  the inner comparison kept on each move) rather than by looking
  across: cursor sync, `<CR>` and `<C-]>` land on the other copy.
  Read marks go by `]c`'s stops, a move's two ends among them: the old
  end stands on git's chunks by their OLD rows (`stop.old`, `on` in
  `read.lua`), and each end is read when it is left.
- `xmoves.lua` — a definition moved to ANOTHER file. Neither view can
  see it, so the review finds it: `build` runs after every read of the
  list (every mode but conflicts), parses the files whose git chunks
  removed or added enough (old at the revision, new off the disk -- or
  out of git at the commit on show) and pairs
  across files by `moves.lua`'s rules into `pane.moves_across`, then
  `view.redraw`s the files whose moves changed. An index answers for one
  revision and one commit (`across_key`) and is never handed to a view
  measuring another, since `]C` re-reads the list. `apply`, in every
  render, finds this file's end again in the buffer and rewrites the
  drawn answer: `kind = "out"` (old copy carved, one line), `kind =
  "in"` (new copy compared against the other file's old one, appended
  past this file's own old lines as `drawn.old_lines`). `<C-]>` goes
  through `view.open_at`, landing on the other view's own end
  (`move_landing`, by path: a commit's file opens a git call later).
- `view.lua` — per-buffer state machine, registry `views[bufnr]`. Drives
  blob → diff → `overlay.render` → `oldside.refresh`. Holds `layout`
  (`"inline"` | `"side"`), `backend`, and `tracks_base`. `close(bufnr)` is
  one buffer; `stop(view)` is the review — every view on the same
  `root`+`rev` (`close_all`) plus every list of it (`pane.all()`), in
  whichever tab. A review is one root and one revision wherever it is
  reached from; the list in the current tab is closed on the root alone,
  since its revision may have drifted from the view's. `]c` off the last
  chunk of a file steps into the next file the list names and lands on
  the first change in it (`config.pane.chunk_spill`): the intent is
  parked in `landing` and collected by whichever view draws next, since
  the anchors it is aimed at are two git subprocesses away. `view.pending`
  is set while a structural diff is out — a subprocess that has not
  answered looks exactly like a file with nothing in it, so the winbar
  and `status()` say which of the two it is.
- `overlay.lua` — inline rendering as extmarks. New-side content is
  highlighted on its real line; old-only content has no line to sit on and is
  drawn as `virt_lines` above where it used to be. That asymmetry is the
  design. Which row a before-image goes above is difftastic's alignment
  where the pair resembles each other, and where it does not — a line
  inserted above a changed one takes the changed line's partner — the
  hunk's own new rows are asked which one the old line resembles
  (`fitted`, bounded by `diff.line.refit_pairs`).
  A pure deletion whose old rows the alignment says were folded INTO
  the surviving row is drawn above it (`collapsed_span`) — but only
  where the fold rewrote that row. Byte for byte the same and nothing
  was folded: the rows simply went, and they went AFTER it, so the
  before-image hangs below. Read as a fold, a file whose whole body was
  deleted put every removed row above the one line it had left, which
  is above the first line of the buffer, where there is nothing to
  scroll to. A row re-matched that
  way is re-measured with it (`refit`): the backend's spans for it are a
  comparison against a line it was never the old version of, and they
  say the whole row went every time. The old window is handed the same
  answer through `view.del_spans`, since one edit cannot read two ways
  in two layouts. What a removed row LOST has four sources, tried in
  order: the per-row character diff, `refit`, difftastic's own spans for
  that old row, and last `del_fine` — the block comparison the
  side-by-side window draws from. Last because it is the coarsest (the
  backend knows `self.measure(box)` survived a line whose `total +=`
  went); but it is the only answer left for a sentence reworded inside a
  multi-line node, where the backend's spans cover the whole atom,
  `rewritten` throws them out, and the inline before-image drew the
  sentence solid red beside a side window that stepped it back. The last
  two both go through `names` and `rewritten`.
  A row a before-image is drawn above that carries no
  mark of its own — the backend reported nothing added to it — is
  banded `UatisAddDim`: nothing on it is new, but a red row over an
  unmarked line reads as a deletion rather than as a replacement.
  Marks laid OVER a row -- the new words of a prose atom drawn on the
  dim -- are joined across whitespace by `paint_row` the same way the
  tokens drawn straight onto a row are, and so is the before-image
  (`joined`): the gap is not the buffer showing through but the other
  half of the comparison, so a rewritten paragraph came back striped,
  every space between two new words reading as the half that did not
  change, and a removed `total +=` came back with the space between its
  two halves stepped back as though it had survived.
  The step-back itself is offered only while it is a comparison
  (`narrowed_atoms`): past `diff.line.emphasis_ratio` of an atom the
  new words are not a half of anything, and what is left is whatever
  the old block happened to contain -- a backtick, a hyphen, a common
  word, matched because the character was somewhere in it.
  The ratio measures the wrong side, though, and `lost` is the escape:
  where NOTHING was removed from a row that HAS an old half, the whole
  old atom is on the row in one piece and the claim cannot be false --
  there is no coincidental remainder, because nothing went missing for
  the matcher to find debris in place of. `"diagram"` -> `"structural
  diagram"` is eleven of twenty characters new, so the ratio called it
  a rewrite and lit a word that never changed. Both halves are load-
  bearing: a row with no partner also lost nothing, and stepping part
  of it back would say a wholly new line arrived carrying a sentence.
  And `collapsed` overrules the ratio the other way: a hunk that folds
  several old rows into fewer new ones offers no pairing at all — the
  new row is not a version of any one of them, it is what replaced all
  of them — and the emphasis there is computed over the whole BLOCK, so
  the pale text can be scavenged from a line that is not the one being
  drawn. Six `parts.append(...)` lines becoming one f-string came back
  with `plan.title` and `plan.author` stepped back inside it, lifted out
  of two different old rows. The block is drawn above the replacement,
  which is where the comparison belongs. `install`
  greyed in the middle of a rewritten README paragraph sends the reader
  hunting for the line it answers to, which is the cost a patch already
  charges. Below the ratio the pale half IS the sentence the reader
  knows, so it stays: `'alpha'` gaining a `2` keeps its quotes stepped
  back. A row left with no step-back at all is banded whole rather than
  drawn dim and lit again on top.
  None of it reaches a row of the node that did not itself change.
  difftastic reports ATOMS and a docstring, a regex literal or any
  multi-line string is ONE atom however many rows it spans, so an edit
  to one line of it comes back with every row tinted on both sides --
  drawn, a seven-line paragraph gone pale with three words lit in it,
  six rows the reader must read to learn they did not move. A row whose
  two sides are byte-identical refutes that on its own:
  `quiet_unchanged` drops the marks on it, and `view.lua` drops the
  matching `del_spans` so the old window reads the same. The MARKS
  only -- the alignment stands, so the hunk and its before-image go on
  reading the node as the one thing it is, and the row draws as what it
  is, unchanged code in its own colours. `]c` does NOT: a hunk spanning
  a seven-row docstring anchored the cursor on its opening `"""`, with
  nothing on that row and the edit three rows below, so the stop is
  pulled forward to the first row of the hunk carrying a mark (the pass
  over `spanned` at the end of `render`). A hunk with nothing drawn on
  it anywhere keeps its own row — a pure deletion is anchored where the
  before-image hangs. Not out of `result.spans`,
  where the old side's spans are what say a row was removed at all and
  `del_marked` picks the before-image out of them.
  Indentation is the exception to "unmarked means unchanged". A block
  wrapped in a guard is reindented and the backend rightly reports
  nothing for it -- but where the language counts the column, that IS
  what the wrapping did, so the columns the row GAINED at its front are
  marked (`diff.indent_marks`) and nothing else on it is. Gated on
  the rest of the line being byte-identical, and on a hunk sitting
  directly ABOVE the run: a wrapper opens above the block it wraps, and
  a file reindented throughout reports no hunks at all -- but one
  reindented throughout AND edited once would otherwise light up every
  row and bury the edit under the reformat.
  Spread at all only while the hunk draws at most
  `diff.line.spread_max` removed rows: one row above the row it became
  is a comparison the reader can check, a whole passage drawn that way
  is stripes, and the old block cannot then be read back as code. Past
  it they go into one block above the hunk — old together, new together.
- `oldside.lua` — the side-by-side left window: a real, read-only buffer of
  the old revision, so it searches and yanks. Owns row correspondence
  (`old_row`/`new_row`/`alignment`) and cursor/scroll sync.
- **Commit by commit.** `<leader>gh` in a file, `C` in the list
  (`pane.toggle_commits`) puts ONE commit on show, starting at the
  first (oldest), and `[C`/`]C`
  (`pane.step_commit`) move within that — they neither enter nor leave
  it, and at either end they say so and stay. The list's toggle is a
  bare letter and so is bound there only — never lent to a file buffer,
  where `C` is `c$`. State: `pane.commit`/`commit_idx` over `pane.commits`
  (`git.commits_between`, first-parent, oldest first), the list read from
  `git.diff_range(parent, sha)`, and `ref`/`rev` moved off
  `tree_ref`/`tree_rev` — which is what they are put back from on the way
  out. The new side is the reader's buffer where its content
  equals the file at that commit, and otherwise the file read out of the
  review's own checkout of the commit (`checkout.lua`, `show.checkout`;
  a read-only `uatis://at/<short>/…` copy where that is off), so a
  language server attaches (`view.at_commit`, shown in the winbar).
  One worktree per review, MOVED with `git checkout --detach` as `]C`
  steps -- one server for the walk, not one per commit -- its buffers
  reloaded and the ones the new commit lacks wiped after a placeholder
  is put in their windows (a wipe closes the windows showing a buffer).
  Opened with `bufadd`, not `:edit`, which reuses a fresh tab's empty
  buffer and drops the keys the list lent it. Released when the walk or
  the review ends, on `TabClosed`, and synchronously on `ExitPre`; the
  first checkout a review makes clears ones no live review holds. `follow` is
  off while a commit is on show: a file arrived at by hand holds the
  working tree, not the commit.

- **One commit on its own.** `<leader>gA` / `:UatisShow [<rev>]`
  (`pane.show_commit`) is the same shape reached from outside a review:
  one commit against its parent, `standalone` on the pane, its walk
  seeded to that one commit in `build`, in a tab of its own
  (`owns_tab`, `config.show.tab`). It never re-reads — what a finished
  commit did cannot move — and its files are ALWAYS the `uatis://at/…`
  buffer, never the reader's own. `C` and `[C`/`]C` say there is
  nowhere to go, and the header names the sha and stops -- `<sha>^ ←
  <sha>` is the same sha twice, and "against its parent" is the only
  thing `:UatisShow` ever means. Sha, date and author go on ONE greyed
  row (`names` in `ui.lua`, which drops fields off the end rather than
  wrapping — half a sha on a row of its own is not a sha) and the
  message sits under it in the buffer's own colour: above is how you
  find a commit, below is what it says. `K` in the list
  (`pane.peek_commit`, `git.commit_message`) opens the whole message in
  a float drawn the same way, read on demand because a walk holds a
  thousand and draws none. No `gitcommit` filetype on it — that syntax
  is for WRITING a message and flags an overlong subject. A commit with no parent is measured against the empty
  tree, which `git.commit` asks git to name. One root and one revision
  can now be two readings at once — a commit's parent IS the fork point
  when it is the branch's first commit — so views and panes carry
  `standalone` and `view.matching`/`close_all`/`stop` match on it:
  neither review counts or closes the other's buffers.
  Tabs a review owns are closed on `ExitPre` (`pane.close_owned`), ahead
  of any `VimLeavePre` session save. The window the quit came from is
  moved into a kept tab rather than closed: `:qa` refuses to quit when
  an `ExitPre` closed it.

- **Everything since one.** `<leader>gS` (`init.since_commit`) is
  `:Uatis <rev>` reached from a prompt rather than the command line:
  the ordinary review, in the reader's own buffers, pinned to the
  revision picked. `ask_revision` in `init.lua` is the one prompt both
  it and `<leader>gA` open, over `base.candidates`; the difference is
  only what is done with the answer — `pane.show_commit` for a commit
  against its parent, `M.run` for the tree against a revision.

- **History.** `<leader>gL` / `:[range]UatisHistory [<path>]`
  (`init.history` → `pane.show_history`), `L` on a list row
  (`pane.history_at_cursor`): every commit that touched a file, a
  directory or a run of lines, as a `standalone` pane with a walk longer
  than one and `pane.history` = the subject `{ path, dir, from, to, rev }`.
  `git.history` reads it oldest first -- `--follow` for a file (each
  commit's `path` is the name it had then), `-L` for lines (the first
  hunk's `+row` is where they stood, and the cursor lands there), a plain
  pathspec for a directory -- and every commit carries its own `parent`,
  since the one before it in the list is not what it was made on
  (`parent_of`). The list draws COMMITS, newest on top (`history_list` in
  `ui.lua`, `pane.list_commits`), the one on show expanded under its row;
  a directory is the pane's `scope` while it lasts (and `rescope` leaves
  it alone), a file filters each commit's diff to its own row. Lines of
  the reader's own buffer are mapped back to HEAD's rows first
  (`committed_rows` in `init.lua`), since `-L` counts in a commit.
  The commits either side of the one on show are diffed ahead
  (`prefetch_around`, on every read of a commit's list), the file picked
  and measured exactly as the view will, so the cache key matches; a
  view that asks while the run is still out joins it (`inflight` in
  `diff.lua`) rather than starting difftastic twice.

- **The project at a revision.** `<leader>gw` / `:UatisAt [<rev>]`
  (`init.at` → `at.lua`): NOT a comparison and not a pane -- a
  `git worktree add --detach` into `stdpath("cache")/uatis/at/<repo>/<sha>`,
  a tab of its own with `:tcd` into it, the file under the cursor opened
  there. A real checkout because a `uatis://` buffer has no project around
  it and no language server attaches to one. Registry `tabs[tabpage]`,
  checkouts refcounted by dir (`users`). Every buffer under it is
  read-only; a window of the tab showing one gets a winbar naming the
  revision (only where its winbar was empty). `TabClosed` releases: stops
  the LSP clients rooted there, wipes its buffers, removes the worktree.
  On exit `pane.close_owned` closes these tabs as well and
  `at.release_all` removes the worktrees synchronously -- an async
  removal is killed half done when the editor goes.

- **One key under the header.** The hint row is `g?` and nothing else;
  `pane.peek_keys` opens a float over `keys_of(pane)`, which is where
  the mode-awareness lives — a standalone commit review is offered no
  walk to step and no branch to go back to, and a key set to `false`
  is left out entirely. Naming the keys in the hint itself was right at
  four of them and wrong at twenty: it taught the reader only the third
  that fitted and spent three rows of the pane doing it on every render
  forever.
- `pane.lua` — the changed-file list, registry `panes[tabpage]`. Takes its
  revision from the view that was on screen when it opened and stays
  pinned to that sha. The list and its window are separate: `list()` reads
  one without showing it, `open()` gives it a window, `hide()` takes the
  window away and keeps the list, `close()` ends it. The rows are drawn to
  the width the WINDOW has, not to `config.list.width` — which is only
  where it opens — so `WinResized`/`VimResized` redraws when the drawn
  width (`pane.list_width`) no longer holds. Under them, on the window's
  own status line, `ui.progress` says how much of the review is behind
  the reader: a bar, `x/y` files, and a percentage of delta LOC (added
  AND removed, a line taken out being as much to read as one put in —
  `3/20` says nothing true about a branch whose third file is
  generated). A status line rather than a last row of the buffer, which
  scrolls away in exactly the review whose progress is worth reading; the
  window is ours, so there is nothing to hand back.
- **Read, and what it fills.** The unit is a CHUNK — one hunk of `git
  diff --unified=0`, a run of changed lines and nothing else (the flag is
  in `git.lua`'s `DIFF_FLAGS` for exactly this) — and a mark is on the
  chunk's CONTENT: `read.lua` fingerprints each hunk's lines (header
  left out, so a base branch growing above the change shifts nothing),
  `pane.read[path]` is a set of those fingerprints, `read.chunk_read` /
  `read.is_read` (every chunk) answer over it, and the marks are kept
  per repository in `state/uatis/read.json` (`pane.remember_read`),
  saved on every change and pruned to the fingerprints the file still
  has. So a commit resets the chunks it touched and no others, an edit
  resets a chunk on write, undo brings it back, and a branch chunk is
  read in the commit that made it where the bytes are the same. Arriving
  at a change is not reading it: `]c` and `[c` mark the chunk they move
  AWAY from (`leave_chunk` in `view.lua` → `pane.leave_stop` →
  `read.leave`, by new-side position overlap between the STOP being
  left — `view.stops`, the view's hunks keyed by content — and git's
  chunks, minus any chunk the target row is still inside — which is
  what makes `[c` from below a change an arrival and not a leaving).
  One git chunk can carry several stops (a hundred added lines with
  blank rows inside), so a chunk is marked only once every stop on it
  has been left; which stops were left is `pane.left[path]`, memory
  only, cleared when `x` takes a row's marks off. The first and last
  chunks of a file go by a press with nowhere to go (`pane.auto_read`). `x` in the
  list marks every chunk of a row, completing rather than inverting a
  row half done, and a directory row takes everything under it
  (`toggle_read`/`toggle_read_dir`); in Visual mode the range is one
  deduplicated set decided once (`toggle_read_rows`), and the mark's
  redraw (`settle`) leaves the list cursor where it was pressed. A file
  whose every chunk is read has its letter and name drawn `UatisRead` —
  the `+N` green mixed toward the background by `highlight.read_recede`,
  so it recedes on light and dark alike — with the `+N -M` keeping its
  own colours, a column to read down; so is a directory whose every
  file is; the bar
  counts delta LOC over read chunks, `x/y` files read entirely. `x` is
  a bare letter and so is bound in the list only, like `C`; nothing is
  bound in a file for it. The file's header counts in STOPS -- the
  view's hunks -- not git's chunks (`read.stops_read`; a stop is read
  when it has been left this session or every chunk under it is
  marked, `read.covering` deciding both the count and the mark). A chunk no stop stands on -- formatting
  structural mode draws nothing for -- is SET ASIDE, not marked: the
  view hands the list `read.hidden(f, view.hunks)` on every render
  (`pane.set_aside` → `pane.hidden[path]`, memory only), `is_read` and
  the bar leave those out, and a render in line mode gives them back.
- **Conflicts.** `<leader>gx` / `:UatisConflicts` (`init.conflicts` →
  `pane.review_conflicts`) is the same premise applied to a merge in
  progress, and the pane's THIRD mode (`pane.conflicts`, beside
  `commit`/`standalone`): the list is `git diff --diff-filter=U`
  (`git.unmerged`), each row counting the blocks left in its file --
  off the buffer where one is annotated, so a pick moves the row
  before the file is written -- and `done` at zero; the bar counts
  blocks settled against `pane.conflict_total`, the most blocks a file
  was ever seen with (memory only). No revision is measured against, so
  `ref`/`rev` are the string `"conflicts"` and nothing a view is
  matched on can match it. In the reader's own tab: they are here to
  fix the tree they stand in, so a branch review there is ended first,
  and `<leader>gu` ends a conflict review too. `x` in the list refuses:
  a conflicted file is done when its blocks are, not when it is marked.
- `merge.lua` — pure: `blocks(lines)` reads git's markers (with the
  base where the style is diff3/zdiff3), `merge3(base, ours, theirs)`
  merges one block three ways BY THE TOKEN -- words, blank runs,
  newlines, single characters -- applying both sides where their
  changes touch no common token and refusing outright where they do.
  Touching is by closed base ranges: adjacent tokens touch, two
  insertions at one point touch, the blank between two words is a
  token and so is context. Whole block or nothing -- half a block
  merged by a program and half by hand is the one outcome worse than
  either.
- `conflict.lua` — the per-buffer annotator, registry by bufnr, a
  sibling of `view.lua` and not a mode of it (no old side, no backend,
  no diff to wait on: the blocks are a line scan, re-read on every
  change). Bands the sides (`UatisOurs`/`UatisTheirs`/`UatisBase`),
  dims the markers, marks the tokens each side changed against the
  base, and binds `keys.conflict.*` plus the list's walk. Every pick
  is `nvim_buf_set_lines` over the block and its own undo step -- an
  API edit joins whatever undo block is open, and after `:e` that is
  the reload (`undoreload`), so `u` after a pick put back the file as
  it was before the merge; 'undolevels' set to itself closes it. The
  base a block lacks comes from stage 1 (`git.stage`, never through
  `blob`'s cache: the index moves) projected onto the block by a line
  diff of the base against our version of the file -- the rows either
  side of a block are lines all three versions share. Not `git
  merge-file --diff3`: it draws its own block boundaries, two where
  the merge that wrote the file coalesced one. `]x` off the end spills
  into the next listed file through `landing`, as `]c` does.
- `colors.lua` — `:UatisColors`, a float that turns every number in
  `config.highlight` with the screen following. It needs no re-render to
  do it: groups are set by name and extmarks carry the name, so
  `overlay.setup_highlights` + `redraw` repaints every mark already
  drawn, in both layouts, the list and the winbar. In the plugin rather
  than in a `dev/` script because the numbers are statements about the
  reader's colourscheme, not about this code: `p` hands back a
  `setup{}` block of every number, since a partial one drifts when a
  default here moves. The three colours a reader can name outright
  (`delete_bg`, `delete_dim_bg`, `add_dim_bg`) are shown, not dialled —
  each switches off a derivation, and the row it replaces says so.

- `rules.md` — every rule this repo layers on top of difftastic's answer,
  in the order they run, with what difftastic does and does not report.
  The reference to reach for before changing anything in `overlay.lua`'s
  marking or `diff.lua`'s alignment; a new rule there belongs in it.
- `doc/uatis.txt` — the vim help doc, and the only user-facing prose
  besides the README: what it is, the mappings, the two layouts and two
  backends, what the marks MEAN, the config and the `status`/`review`
  field names. Keep it to 78 columns, keep `*uatis*` on line 1, and
  regenerate `doc/tags` with `:helptags doc` (gitignored). A change that
  alters a mapping, a command, a highlight group or a documented field
  name is not finished until this file says so.
- `syntax.lua`, `ui.lua`, `filelist.lua`, `patch.lua` — pure helpers:
  tree-sitter highlighting of text with no buffer, statusline/winbar and list
  formatting, list drawing, unified-diff parsing.
- `keys.lua` — mapping save/restore. Only mappings already buffer-local to
  the target buffer are saved; restoring a global one would permanently shadow it.
- `config.lua` — one table of defaults read by every use site.
  `init.setup(opts)` folds the user's table into it **in place** (every
  module holds a reference from require time), lists replaced whole rather
  than merged by index, unknown keys warned about. New settings go in this
  table with a comment saying what they CONTROL — one or two lines, and
  no argument for the value. This file is the reference a reader opens to
  find a knob; the reasoning behind a number belongs beside the code that
  acts on it. Nothing else writes to this table.

### Cross-cutting rules

- **The header names the branch when the tree is on it.** `main ←
  working tree` reads the same on every branch anyone is ever on, so
  where the working tree has not moved off HEAD the right-hand side is
  HEAD's branch instead (`src_of` in `pane.lua`). Moved means an
  unstaged edit, a staged one, an untracked file — all of which
  `git.head_state` reads in one `git status --porcelain --branch` — or a
  buffer typed into and not written, which git cannot see and the pass
  over loaded buffers is for. A detached HEAD stays `working tree`.

- **A file of bytes is not compared.** Both backends would answer about
  a PNG and both answers are marks over noise, so `view.lua` short-
  circuits on a NUL byte near the start of either side: no diff, no
  marks, no before-image, counts zero, and the winbar says `binary ·
  <old> → <new>` (`ui.size`). The new size comes from `fs_stat` and not
  from the buffer — Neovim stores a NUL as a newline and splits on the
  rest, so a PNG read back out of buffer lines is a different length
  than the file.

- **The list counts three sources.** `git diff <fork point>` for what git
  can see, `git ls-files --others --exclude-standard` for the files it
  has never been told about (counted by reading them, capped at
  `pane.untracked_max_bytes`), and the open views for what is still
  unsaved — the last wins where they disagree, since it is what is drawn
  on screen. See `compose` in `pane.lua`.

- **The list is the review.** A comparison is a mode over a branch, not a
  decoration on one buffer: while `panes[tab]` exists, its `BufEnter`
  watcher annotates any file it lists as you arrive at it, at the pane's
  own revision (`pane.follow`, `follow`/`follow_visible` in `pane.lua`).
  So the list is read whenever a comparison is turned on — window or no
  window, `auto_open` only decides whether you see it — and turning the
  review off means `view.stop`, not `view.close`. `q` in the list hides
  the window and leaves the review running.

- **git can move while nvim is not looking.** The list re-reads on
  `BufWritePost` and on `BufReadPost` of a file it already knew; on
  `FocusGained`/`TermLeave`/`TermClose` it goes further and calls
  `pane.recheck`, which re-resolves the fork point first. A commit needs
  none of this (`git diff <fork point>` counts commits and tree
  together), but a branch switch, a rebase or a pull on the base branch
  moves the fork point itself, and a base-tracking review then has the
  wrong answer rather than an old one. Pinned reviews keep their
  revision.

- **Async with a generation guard.** Every render bumps `view.gen`; callbacks
  check `views[view.bufnr] == view and view.gen == gen` before touching
  anything, so a slow difftastic result from three keystrokes ago cannot land
  on a fast one from now. Buffer changes are debounced 150ms
  (`schedule_render`).
- **Restore what you touched.** Mappings, `winbar`, extmarks and windows are
  all handed back exactly as found on close — including `]c` if the user
  already had it. Never save the plugin's own winbar expression as
  "what was here before".
- **`tracks_base` vs. a named ref.** `toggle_diff` opens a base-tracking view;
  `:Uatis <ref>` opens one pinned to that revision. Changing the base branch
  re-points the first kind (`view.repoint` + `pane.repoint`, both handed one
  resolved sha) and leaves the second alone.
- **Line highlights over real code take the background only.** A foreground
  would replace the syntax colouring underneath, which is the one thing this
  plugin exists to preserve.
- Registries are keyed deliberately: views by bufnr, panes by tabpage,
  `oldside.owners` by old bufnr, base choices by repo root.

### Comment style

Every module opens with a comment saying what it is *for* and why it is
shaped that way, and non-obvious decisions carry the empirical finding that
led to them (why not `linematch`, why histogram over Myers, why a trailing
newline is added before `vim.diff`). Match that: explain the reason, not the
mechanics.

## Tests

`tests/fixture.sh` builds a throwaway repo covering the cases that break a
review renderer: a modification with two separate chunks, added files
(one nested), a deletion, a rename, a comment-only commit, a file the
branch never touches (`stable.lua`, which a following review must leave
alone), and a commit landing on `main` *after* the fork — the last is what
distinguishes a three-dot diff from a two-dot one. It is left checked out on `main`.
`feature/clash` is for the conflict review: merged into `feature/math` it
stops on `calc.lua` (different words of adjacent lines — what the wand
takes) and `helper.lua` (added by both — no base, nothing can). The
sections that use it run the merge themselves and `merge --abort` after.

`tests/run.sh` gives the run a cache of its own (`XDG_CACHE_HOME`), since
`checkout.lua` and `at.lua` check commits out under `stdpath("cache")`, and
the suite releases both before `os.exit`, which fires no `ExitPre`.

The suite asserts on extmarks, buffer contents, window state and mappings —
never on anything visual. It waits on the `view.renders` counter via
`wait_for`, never on wall-clock sleeps; new async behaviour needs a
counter or predicate to wait on rather than a timeout.

## Committing

Commit your changes when a piece of work is finished — don't leave the tree
dirty for the user to clean up. Run `tests/run.sh` first; a commit that
leaves the suite red is not finished work.

Follow the existing message style: a lowercase subject line naming what
changed (not what file was touched), then a blank line and prose explaining
*why* — the reasoning that would otherwise be lost. Trivial changes can be a
subject line alone.
