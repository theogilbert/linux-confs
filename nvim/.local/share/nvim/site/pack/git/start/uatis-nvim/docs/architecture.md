# Architecture

A guide for contributors: how the plugin is put together, where each
feature lives, and what to touch (and update) when you change one.

For *why* individual decisions were made, read the opening comment of the
module concerned — every module starts with one — and, for anything about
how a diff is drawn, [`rules.md`](../rules.md). The user-facing reference
is [`doc/uatis.txt`](../doc/uatis.txt).

## The premise, and the two invariants

uatis annotates the buffer you are already editing against a git revision,
instead of showing you a patch. Two rules follow from that and everything
else is built around them:

1. **The new side is the live buffer.** The user's real file — unsaved
   edits, undo history, LSP and all — is never copied into a scratch
   buffer. Only the *old* side is fetched from git (`git.blob`) and drawn
   around it, as extmarks (inline layout) or as a read-only buffer in a
   second window (side layout). A change that replaces the user's buffer
   with a rendering breaks the plugin's premise.
2. **Comparisons are against the fork point**, `merge-base(base, HEAD)`
   (three-dot semantics), so commits landing on the base branch after you
   forked never show up as reversed changes.

Requirements: Neovim 0.12+ (a hard floor, checked in `init.lua`), `git`,
and `difft` (difftastic) for structural diffing — without it the plugin
degrades to a line diff.

## Repository layout

```
plugin/uatis.lua      user commands; calls setup() with defaults
lua/uatis/*.lua       the plugin (pure Lua, no build step)
doc/uatis.txt         :help uatis — user-facing reference
rules.md              every rule layered on top of difftastic's answer
tests/fixture.sh      builds a throwaway git repo covering the hard cases
tests/run.lua         the headless suite (one script of `do ... end` blocks)
tests/run.sh          builds the fixture and runs the suite
```

## Module map

The modules fall into layers. A module only requires modules in its own
layer or below (with a few lazy `require`s inside functions to break
cycles, e.g. `ui` ↔ `pane`, `view` ↔ `pane`).

```
 entry       plugin/uatis.lua ──► init.lua
                                     │
 modes       pane.lua   view.lua   conflict.lua   at.lua   colors.lua
             (review)   (one file) (merge)        (checkout tab)
                │          │
 drawing     filelist.lua  overlay.lua  oldside.lua  ui.lua
                              │
 analysis    diff.lua ── regions.lua  moves.lua  xmoves.lua  read.lua  merge.lua
                │
 input       base.lua  scope.lua  prompt.lua
                │
 plumbing    git.lua  checkout.lua  patch.lua  syntax.lua  keys.lua  config.lua
```

| Module | Role | Pure? |
|---|---|---|
| `plugin/uatis.lua` | Defines `:Uatis`, `:UatisShow`, `:UatisHistory`, `:UatisAt`, `:UatisConflicts`, `:UatisColors`; calls `setup()` | — |
| `init.lua` | Public API, global keymaps, options merge, version floor, the revision prompt shared by `<leader>gA`/`<leader>gS`, `status()`/`review()`/`showing()` | no |
| `config.lua` | Every default in one table, merged in place by `setup()` | data |
| `view.lua` | Per-buffer state machine: blob → diff → render. Layout, backend, `]c`/`[c`, file/commit stepping, generation guard | no |
| `pane.lua` | The changed-file list and everything a *review* is: follow-on-arrival, commit walk, standalone commit, history, conflicts mode, read marks, re-reading when git moves | no |
| `overlay.lua` | Draws a diff onto a buffer as extmarks; highlight groups | no |
| `oldside.lua` | Side-by-side old-revision window, row correspondence, scroll/cursor sync | no |
| `diff.lua` | Two backends (difftastic JSON, `vim.diff` histogram) behind `compute(old, new, opts, cb)`; realignment, caching, fallback | mostly |
| `regions.lua` | Splits a file too large for difftastic into tree-sitter pieces and stitches the answers | yes |
| `moves.lua` | A definition moved within one file | yes |
| `xmoves.lua` | A definition moved between files (indexed across the review) | no |
| `read.lua` | Read marks: chunk fingerprints, stops, persistence format | mostly |
| `merge.lua` | Conflict-marker parsing and a token-level three-way merge | yes |
| `conflict.lua` | Per-buffer annotator for a conflicted file; pick/resolve keys | no |
| `base.lua` | What a review measures against: detection, picker, per-repo memory, fork point | no |
| `scope.lua` | `<leader>gB` panel: base + subtree, applied together | no |
| `prompt.lua` | Our own one-line floating input with completion | no |
| `git.lua` | Every git call, async via `vim.system`; blob/patch caches | no |
| `checkout.lua` | A review's own worktree, moved commit by commit, so LSP attaches | no |
| `at.lua` | `:UatisAt`: a read-only worktree in its own tab | no |
| `colors.lua` | `:UatisColors`: live colour tuning float | no |
| `health.lua` | `:checkhealth uatis` | no |
| `ui.lua` | Formatting: winbars, list header, progress bar, key help | yes |
| `filelist.lua` | Drawing of the list buffer | yes |
| `patch.lua` | Unified-diff parser | yes |
| `syntax.lua` | Tree-sitter highlighting of text that has no buffer | yes |
| `keys.lua` | Save/apply/restore buffer-local mappings | yes |

## Where each feature lives

| Feature | Entry point | Implemented in |
|---|---|---|
| Annotate a buffer against the base (`<leader>gu`) | `init.toggle_diff` | `view.toggle` → `view.open`/`attach`; base from `base.resolve` |
| Annotate against a named revision (`:Uatis <ref>`) | `init.run` | `view.open` with a pinned ref (not `tracks_base`) |
| Inline rendering (green on real lines, red virtual lines) | — | `overlay.render` and its helpers; the rules in `rules.md` |
| Side-by-side layout (`<leader>go`) | `view` keymap | `view.set_layout` → `oldside.lua` |
| Structural vs. line backend (`<leader>gm`) | `view` keymap | `view.toggle_backend` → `diff.compute` |
| difftastic row realignment, fallbacks | — | `diff.lua` (`realign`, `fallback_of`, `cut_first`) |
| Very large files (difftastic graph limit) | — | `regions.lua`, called from `diff.lua` |
| Moved definitions, same file | — | `moves.lua`; result hung on `result.drawn` by `diff.compute` |
| Moved definitions, across files (`<C-]>`) | — | `xmoves.build` (after a list read), `xmoves.apply` (per render), `view.move_jump`/`open_at` |
| Syntax colours in removed lines | — | `syntax.lua`, used by `overlay.lua` |
| Binary files | — | short-circuit in `view.lua` render; `ui.size` |
| Hunk navigation `]c`/`[c`, spill to next file | `view` keymap | `view.step_hunk`, `spill`, `landing` |
| Changed-file list (`<leader>gf`, `]f`/`[f`) | `init.toggle_pane` | `pane.lua` (state, git reads, `compose`), `filelist.lua` + `ui.lua` (drawing) |
| Annotating files as you open them | — | `pane.follow` (`BufEnter` watcher in `pane.lua`) |
| Untracked and unsaved files in the list | — | `compose` in `pane.lua` |
| Re-reading when git moves (commit, rebase, pull) | autocmds | `pane.recheck` and the watchers in `pane.lua` |
| Progress bar / read marks (`x`, auto-read on `]c`) | list keymap, `view` | `read.lua` (fingerprints, persistence), `pane.toggle_read*`, `view.leave_chunk`, `ui.progress` |
| Picking the base and subtree (`<leader>gB`) | `init.set_base_branch` | `scope.lua` → `base.ask`/`ask_dir`; persisted in `state/uatis/base.json` |
| Revision prompt with completion | — | `prompt.lua`; candidates from `base.items`/`candidates` |
| Commit-by-commit walk (`<leader>gh`, `C`, `[C`/`]C`) | `view`/list keymaps | `pane.toggle_commits`, `pane.step_commit`; files read through `checkout.lua` |
| One commit on its own (`<leader>gA`, `:UatisShow`) | `init.show_commit` | `pane.show_commit` (a `standalone` pane in its own tab) |
| Everything since a revision (`<leader>gS`) | `init.since_commit` | `init.run` with `replace` |
| Commit message float (`K` in list) | list keymap | `pane.peek_commit`, `git.commit_message` |
| History of a file/dir/lines (`<leader>gL`, `:UatisHistory`, `L`) | `init.history` | `pane.show_history`, `git.history`, `ui.history_list`, `committed_rows` in `init.lua` |
| Project at a revision (`<leader>gw`, `:UatisAt`) | `init.at` | `at.lua` |
| Merge conflicts (`<leader>gx`, `:UatisConflicts`) | `init.conflicts` | `pane.review_conflicts` (list), `conflict.lua` (per-buffer), `merge.lua` (parsing, word merge) |
| Key help float (`g?`) | list keymap | `pane.peek_keys`, `pane.keys_of` |
| Statusline / winbar data | `init.status`, `review`, `showing` | `ui.lua` formatting, state from `view`/`pane` |
| Colour tuning (`:UatisColors`) | `init.colors` | `colors.lua`, `overlay.setup_highlights` |
| Health check | `:checkhealth uatis` | `health.facts` (data), `health.report` (wording) |
| Closing tabs/worktrees on exit | `ExitPre` | `pane.close_owned`, `at.release_all`, `checkout.lua` |

## How a render flows

```
buffer change ─(150ms debounce: view.schedule_render)─┐
open / repoint / backend switch ──────────────────────┤
                                                      ▼
                                          view.render(view)   gen += 1
                                                      │
                     git.blob(root, rev, path) ◄──────┤  (cached by root\0rev:path)
                                                      ▼
                     diff.compute(old_text, buffer_text, opts, cb)
                       ├─ structural: difft --display json (cached by input)
                       │    ├─ realign / regions (graph limit) / moves
                       │    └─ failure → line backend, `unavailable` set
                       └─ line: vim.diff histogram
                                                      │
                                    cb: is views[buf] == view and gen == gen?
                                                      │  (else drop: stale)
                                                      ▼
                        xmoves.apply → overlay.render → oldside.refresh
                                     → winbar / pane.set_aside / counters
```

Every asynchronous callback checks the generation guard before touching
anything, so a slow difftastic answer cannot overwrite a newer one.

## State and registries

| Registry | Keyed by | Holds |
|---|---|---|
| `view.lua` `views` | bufnr | one annotated buffer: root, rev, layout, backend, hunks, `gen`, saved keymaps/winbar |
| `pane.lua` `panes` | tabpage | one review: root, ref/rev, files, scope, commit walk, read marks, mode (`standalone`, `history`, `conflicts`) |
| `oldside.lua` `owners` | old-side bufnr | which view owns a side window |
| `conflict.lua` | bufnr | one conflicted buffer |
| `at.lua` `tabs` | tabpage | a revision checkout tab; worktrees refcounted by dir |
| `git.lua` caches | `root\0rev:path` | blobs and commit patches, never evicted |
| `diff.lua` caches | input text | structural results; in-flight runs are shared |

A *review* is one root plus one revision (plus `standalone`); `view.stop`
ends every view and list belonging to it, wherever they are.

Persisted across sessions, under `stdpath("state")/uatis/`:

- `base.json` — per repo root, the chosen base and subtree.
- `read.json` — per repo, the read-chunk fingerprints.

Worktrees (`checkout.lua`, `at.lua`) live under `stdpath("cache")/uatis/`
and are removed on release and on exit.

## Conventions you must keep

- **Restore what you touched.** Keymaps (`keys.lua`), winbars, extmarks and
  windows go back exactly as found when a view closes. Only mappings that
  were already buffer-local are saved.
- **Async, never blocking.** All git and difftastic work goes through
  `vim.system` with callbacks. The `_sync` variants in `git.lua` exist only
  for command-line completion.
- **Degrade, don't raise.** A difftastic failure falls back to the line
  backend and says so.
- **Highlights over real code set a background only**, so syntax colouring
  survives.
- **`setup()` is idempotent.** It runs twice on a real install (defaults
  from `plugin/uatis.lua`, then the user's call).
- **Comments explain why**, not what. Every module opens with its purpose;
  non-obvious choices carry the finding that led to them.

## Making common changes

**A new setting.** Add it to `config.lua` with a one- or two-line comment
saying what it controls (the reasoning goes beside the code that reads it).
Read it as `config.<section>.<key>` at the use site — never copy it at
require time, since `setup()` mutates the table in place. Document it in
`doc/uatis.txt`.

**A new key.** Add it under `config.keys.global`, `.view`, `.pane`, `.old`
or `.conflict`. Bind global keys in `init.setup`, view keys in
`view.setup_keymaps`, list keys in `pane.lua`, conflict keys in
`conflict.lua`. Respect `false` (user binds it themselves). Bare letters
are bound in the list only, never lent to a file buffer. Add it to
`pane.keys_of` so `g?` lists it, and to `doc/uatis.txt`.

**A new command.** Define it in `plugin/uatis.lua`, calling a function on
`init.lua`; put the behaviour in the module that owns the mode.

**A new drawing rule** (how a change is marked). It goes in `overlay.lua`
(or `diff.lua` for alignment) **and** gets an entry in `rules.md`, in the
order it runs. Check that the side layout (`view.del_spans`, `oldside.lua`)
draws the same answer.

**A new highlight group.** Define it in `overlay.setup_highlights`; if it
has a tunable number, add it to `config.highlight` and `colors.lua`.

**A new git call.** Add it to `git.lua`, async with a callback, root passed
explicitly.

Whatever you change, if it alters a mapping, a command, a highlight group
or a documented field name, update `doc/uatis.txt` (78 columns, `*uatis*`
on line 1) and regenerate tags with `:helptags doc`.

## Tests

```sh
tests/run.sh                      # build the fixture repo and run the suite
UATIS_FIXTURE=/path tests/run.sh  # keep the fixture somewhere reusable
```

To iterate on a change, build the fixture once and run the script directly:

```sh
tests/fixture.sh /tmp/uatis-fixture
nvim --headless -u NONE --cmd 'set packpath=' --cmd "set rtp+=$PWD" \
  -l tests/run.lua /tmp/uatis-fixture
```

`packpath=` matters: without it you test whatever copy of the plugin is
installed, not your checkout.

- The fixture (`tests/fixture.sh`) is a repo with a two-chunk
  modification, added/deleted/renamed files, a comment-only commit, an
  untouched file, a commit on `main` after the fork, and a
  `feature/clash` branch for conflict tests.
- `tests/run.lua` is one script of `do ... end` blocks, each printed under
  a `[section name]` header. There is no per-test runner; search for the
  header to find the tests for a feature.
- Assert on extmarks, buffer contents, window state and mappings — never
  on anything visual. Wait with `wait_for` on a counter or predicate
  (e.g. `view.renders`), never on sleeps; new async behaviour needs
  something to wait on.
- The difftastic and tree-sitter sections are **skipped**, not failed,
  when those are missing — a green run without `difft` is not full
  coverage.

The suite must be green before a commit.
