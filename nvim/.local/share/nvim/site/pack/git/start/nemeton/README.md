# nemeton

Review GitLab merge requests where you read the code.

A *nemeton* was the sacred grove a Gaulish tribe assembled in to
deliberate. This is where the argument about your branch happens.

GitLab only, through the [`glab`][glab] CLI — there is no HTTP client in
here and no token in a config file. GitHub is deliberately not here yet;
see [What is not done](#what-is-not-done).

Needs Neovim 0.10 or newer, `git`, and `glab`. `:help nemeton` is the
same ground as this file, with tags.

[glab]: https://gitlab.com/gitlab-org/cli

## What it does

- lists the open merge requests on the project this repository points at,
  in a float you can read as a table — number, CI, approvals, title,
  size, author, staleness, comment count, and how many comments on it
  are yours and still unsent — with the commits of the one under the
  cursor, or what it says it is for, in a pane under it;
- opens one: checks its source branch out with `glab mr checkout`, then
  fetches every discussion on it;
- marks the lines that carry a thread in the gutter, in every file you
  open for as long as the review is on — open threads and resolved ones
  get different glyphs, because you navigate by the first;
- shows the conversations: one at a time in a float under the cursor, or
  all of them at once as virtual lines under the code they are about, on
  a ground of their own so they do not read as more code;
- posts a new thread against the line under the cursor, with the position
  GitLab needs (the three diff shas, the path on both sides, the line);
- replies into an existing thread, and resolves or reopens one;
- gathers every comment on the merge request into one window, an
  opening note per line — where it sits, whether it is settled, how many
  answers it has — to read them in, answer them from, and add your own.

The markers are extmarks, not signs: you edit the file while you review
it, and a marker that does not follow its line points at the wrong code.

Every colour is a `Nemeton*` highlight group linked to one your
colourscheme already defines, so all of them are one `:hi` away. The
ground under an expanded conversation is `NemetonInline`: your own
background lifted towards the colour your text is drawn in — lighter in
a dark colourscheme, darker in a light one — and then tinted towards the
colour an open thread is drawn in, so it is a shade of the file rather
than a grey band across it. Far enough to hold its own against whatever
else paints these lines: a diff plugin's red and green sit on the code
above and below, and a ground a whisper away from the file's own reads
as one more band of that. `comments.ground` (0.15, or `false` for no
band at all) is how far. A settled conversation gets `NemetonSettled`
instead — half as far, towards the resolved colour, so an argument still
going on stands off the page and one that is over sinks back towards it.
`:hi NemetonInline guibg=…` picks another, and `:hi link NemetonInline
Normal` takes it away. The colours drawn *on* either are
derived from it — `NemetonInlineAuthor`, `NemetonSettledAuthor` and the
rest — so nothing in the block carries a background of its own through
the middle of it.

## Try it

```
glab auth login                       # nemeton does nothing without this
cd <a repo with a GitLab remote>
nvim
:Nemeton                              # the list; <CR> checks one out
```

Install it however you install plugins. Calling `setup()` is optional:
`:Nemeton` and `<leader>ml` are registered when Neovim starts and load
nothing until one of them is used, and the first one used wires up the
rest.

`:checkhealth nemeton` says whether git, glab and a token are all there.

## Commands

`:Nemeton` on its own opens the list. Otherwise:

| | |
|---|---|
| `:Nemeton open 42` | check !42 out and load its threads |
| `:Nemeton comments` | markers on/off |
| `:Nemeton expand` | the conversations themselves, under their lines |
| `:Nemeton description` | the merge request's own window: what it is for, and the keys to act on it |
| `:Nemeton peek` | the thread under the cursor, in a float |
| `:Nemeton create` | open a merge request for the branch you are on |
| `:Nemeton comment` | a new thread on this line |
| `:Nemeton reply` | a reply into the thread under the cursor |
| `:Nemeton edit` | rewrite a comment in the thread under the cursor |
| `:Nemeton delete` | delete one, after asking |
| `:Nemeton suggest` | suggest a change to the line under the cursor |
| `:Nemeton jobs` | what CI did, job by job |
| `:Nemeton resolve` | resolve or reopen it |
| `:Nemeton note` | an overall comment, on the MR rather than a line |
| `:Nemeton publish` | send every comment kept unsent |
| `:Nemeton notes` | every comment, one line each, in a window that answers them |
| `:Nemeton threads` | every thread on the merge request, in the quickfix list |
| `:Nemeton conversation` | the same threads, to read rather than to walk |
| `:Nemeton approve` | approve the open merge request |
| `:Nemeton unapprove` | take the approval back |
| `:Nemeton refresh` | refetch the discussions |
| `:Nemeton status` | what is open, and how many threads |
| `:Nemeton close` | end the review; the branch stays checked out |
| `:Nemeton token` | type a token in for this editor session |
| `:Nemeton forget-token` | drop it again |

## Keys

`<leader>ml` opens the list, from anywhere. The rest are buffer-local and
exist only on files in the repository while a review is on:

| | |
|---|---|
| `<leader>mx` | expand the conversations inline |
| `<leader>mp` | peek at the thread here |
| `<leader>ma` | comment on this line, or on the lines selected in visual mode |
| `<leader>mr` | reply |
| `<leader>mR` | resolve / reopen |
| `<leader>me` | edit a comment in the thread here |
| `<leader>mD` | delete one, after asking |
| `<leader>ms` | in visual mode: suggest a change to these lines |
| `<leader>md` | the merge request itself, in a float — bound globally too, so it works from the quickfix list, a window of this plugin, or a buffer that is not a file at all |
| `<leader>mq` | end the review: the markers and these keys go away |
| `]m` `[m` | next / previous comment, across the whole merge request |

In the list: `<CR>` opens one, `c` shows its commits under the list and
`d` what it says it is for, `s` walks the queue through opened → merged
→ closed → all (the title says which, and every row that is not open
says so beside its title), `]` puts another page of them under the ones
on the screen, `+` opens one of your own for the branch you are on,
`r` refetches, `o` opens it in a browser, `q` closes. The window opens on the keypress rather than when the forge
answers, and `<CR>` leaves it up, saying which merge request it is
opening, until the review is loaded. A checkout that fails says so in
the window, folded to fit and whole — what git said was in the way and
what to do about it, not the nine lines `glab` wrapped around it — and
`<CR>` puts the queue back.

A row's CI, its approvals and how much it changes are three questions
GitLab's list payload does not answer, asked one row at a time and drawn
where the row stands as the answers land — and asked only about the
merge requests that are still open. On one that is merged or closed
those three are history, the columns stay empty, and the queue is drawn
without asking the forge anything. The approvals are the tick and the
count, `✓2/2` or `◌0/1`; who has approved it is a name, and names are
`<leader>md`.

In the comments window: `<CR>` goes to the code the comment under the
cursor is about, `r` replies to it, `a` writes a comment on the merge
request, `t` writes one people can reply to, `e` edits one of its
comments, `d` deletes one, `R` refetches, `q` closes. Every thread is
there, the ones on code saying which line they sit on, and each is its
opening note and nothing else — the answers to it are what
`:Nemeton conversation` is for.

What is bound out in the buffer is what acts on the line under the
cursor. A dozen keys under one prefix is a menu nobody has learnt, so
everything else a review needs is one letter further in, on the window
it belongs to, or a `:Nemeton` verb typed once in a review: approving,
the comments window, the pipeline's jobs and sending the review are
keys on `<leader>md`; `:Nemeton threads` fills the quickfix list and
`:Nemeton comments` turns the markers off. Each has a `keys.session.*`
entry set to `false` in the config — give one a string and it is out in
the buffer again.

`<leader>md` is where a merge request is looked at and acted on: what
it is for, how big it is, what CI made of it, who has approved it, how
much conversation is on it and how much of that is yours and unsent.
In it: `a` approves it or takes the approval back, `s` sends every
comment you have kept unsent, `c` opens every comment on it, `p` the
pipeline's jobs, `o` opens it in a browser, `r` refetches, `q` closes. None of them is a key you read with — it is a window of
prose, and `hjkl`, `/` and the rest work in it as they do anywhere. The
threads that are on the code are read where the code is: in the gutter,
on `]m`, in the quickfix list.

In every-thread (`:Nemeton conversation`): `<CR>` goes to the code the
thread under the cursor is about, `r` replies, `e` edits one of its
comments, `d` deletes one, `R` refetches, `q` closes.

In the pipeline's jobs: `<CR>` opens what the job under the cursor
printed, `o` opens the job on GitLab, `r` refetches, `q` closes.

A job's log opens in a **tab** rather than a float — a build log is
thousands of lines read by searching them, and it is the one thing here
you want open while you go back to the code it is complaining about. The
cursor starts at the end, where a failure is; `R` refetches (a running
job has more of it every second), `o` opens the job on GitLab, `q`
closes the tab and puts you back in front of the jobs it came from. What
the runner wrote for a terminal — colour escapes, GitLab's
`section_start:` markers, the carriage returns a progress bar was drawn
with — is taken out on the way in.

A suggestion is drawn as the diff it is wherever you read it — expanded
under the code, in the peek float, in the every-thread window — the
lines it would replace in red above the lines it would put there in
green, read off the buffer where the file is open and off the disk where
it is not.

When the line a thread sits on no longer says what it said — someone
pushed while you were reading, or you edited the file you are reviewing
— the thread carries the code it *was* written against, above the first
note and on a band of its own (`NemetonWas`: your background moved
towards the colour a line taken away is drawn in), running the width of
the editor from the rail out — the rail is on the band too and keeps
only its colour, which is what says which conversation the quotation is
inside.
Nothing is written in front of it — it is a quotation of the file, and
the background says so without a word to read on every line. A comment is half of a pair and the code is the
half that moves; without this the note reads as a remark about whatever
happens to be under it now. The old lines are read out of the checkout
with `git show`, not from the forge — the commit the note was written
against is one the repository already has — and a commit that is not
there any more is asked about once and then left alone.

A comment is wrapped to the window it is drawn in, and to
`comments.wrap` — 80 columns by default — wherever the window is wider
than that. It has to be wrapped somewhere: a conversation under the code
is virtual text, and virtual text takes no `wrap` and no horizontal
scroll, so a line that runs past the right-hand edge is a line that
cannot be read at all. The second limit is for the other end of it —
prose set across the whole of a wide editor is prose the eye loses its
place in. `comments.wrap = false` wraps to the window and nothing
narrower.

In the composer: `<C-s>` or `:w` **keeps** the comment for the review
you are writing, `<C-p>` posts it to the merge request there and then,
`q` discards it, and `@` completes the people on the project — the menu
comes up as you type it, `<C-x><C-o>` asks for it where it does not, and
what goes in is `@username`, sigil and all, because that is what GitLab
turns into a notification. Keeping is the default because a review is written as
a whole: a comment posted the moment it is typed cannot be taken back
after reading the next file.

A **reply** is the other way round — `<C-s>` sends it, `<C-p>` keeps it
— because a reply is half of a conversation somebody else is already
in. GitLab files an unsent reply with your other drafts rather than
under the note it answers, so a kept reply is invisible to the person
waiting for it and invisible in the thread until the whole review goes
out. (Nemeton puts one back in the thread it belongs to wherever it
draws it, so a reply kept by the other key — or in GitLab's own web
interface — is at least visible to you.) A kept comment is drawn on its line in its
own colour with a pencil in the gutter, and `s` on `<leader>md` sends
every one of them at once — which is what submitting a review is, and
which is why it sits beside the approval and the count of what is still
unsent.

All of it is in `lua/nemeton/config.lua`, one table, and every key can be
set to `false` to bind the function yourself.

CI states are drawn with the glyphs in `config.ci` — `✓` passed, `✗`
failed, `◐` running, and so on. They are text-presentation codepoints on
purpose: `U+2714 HEAVY CHECK MARK`, which the tick used to be, is in
Unicode's emoji set, and a terminal with an emoji font draws it from
there — a picture in that font's own colour rather than a tick in the
green nemeton asked for. Nerd Font icons go in that table just as well.

## Configuration

Everything lives in one table, `lua/nemeton/config.lua`, and
`setup{}` overlays yours onto it:

```lua
require("nemeton").setup({
  glab = {
    host = "gitlab.example.com",
    token = function()
      return vim.trim(vim.fn.system("pass show gitlab/token"))
    end,
  },
})
```

`host` and `token` are exported to every `glab` call as `GITLAB_HOST` and
`GITLAB_TOKEN`. Both default to `nil`, which is usually what you want:
glab infers the host from the repository's git remote, and `glab auth
login` keeps a token in the system keyring.

- **`host`** — a string or a function. Set it only for a self-managed
  instance glab cannot infer. One sharp edge, and it is glab's: with
  `GITLAB_HOST` set, glab refuses to work in a repository whose remotes
  point elsewhere ("none of the git remotes configured for this
  repository correspond to the GITLAB_HOST environment variable"). If you
  review across two instances, leave it nil.
- **`token`** — a string or a function. A function is the point: it is
  called once per editor session, cached, and never written anywhere, so
  it is where you shell out to a password manager rather than putting a
  `glpat-…` in a dotfile that ends up in a backup, a screen share, and
  eventually a repository.
- **`prompt_for_token`** (default `true`) — when glab answers 401, or
  when there is no token anywhere, nemeton asks for one with
  `inputsecret` (masked, no `:history`), keeps it in memory for this
  Neovim session only, and retries the call that failed. Nothing is
  written to disk and nothing is handed to `glab auth login`. Several
  calls failing at once share one prompt. Set it to `false` to have calls
  simply fail instead.

A 403 never prompts: that is a token that works and an account that may
not touch the project, and asking for a different token at a permission
error trains exactly the wrong reflex.

`:checkhealth nemeton` says which host and which token source are in
effect, without printing the token.

- **`track`** (default `true`) — `glab mr checkout` points the branch it
  leaves you on at `refs/merge-requests/<iid>/head` so that `git pull`
  follows the merge request. Nothing on this side has a remote-tracking
  branch then, so git answers "no upstream" to every question about
  being ahead or behind — and so does everything else reading the
  repository: a statusline, or lazygit, which draws such a branch with a
  purple `?` where the counts go. For a merge request from this project
  the two are the same commits under two names, so nemeton puts the
  ordinary upstream back after the checkout (`git fetch <remote>
  <branch>`, then `git branch --set-upstream-to`). Never for one from a
  fork, whose source branch is not on this remote at all. `false` leaves
  what glab wrote alone.

## The log

Every subprocess nemeton runs — every `glab` call, so every API call, and
the two `git rev-parse`s — is written to

```
~/.local/state/nemeton/nemeton.log      # $XDG_STATE_HOME if you set it
```

two lines per command, one when it starts and one when it ends:

```
2026-08-30T14:27:13.747 [4] run  glab api --paginate projects/:fullpath/merge_requests/1/discussions?per_page=100  cwd=/home/you/src/thing  env=GITLAB_HOST=gitlab.example.com GITLAB_TOKEN=<set>
2026-08-30T14:27:13.752 [4] exit 0  5ms
```

Both ends, because the call worth reading about afterwards is often the
one that never came back. The number in brackets pairs them up: several
requests are in flight at once and their lines interleave.

The token is not in there. It is passed in the environment and the
environment is logged by name and by presence — `GITLAB_TOKEN=<set>` —
because whether a token was exported at all is the question the log has
to answer and which one it was is the question it must not. Arguments and
the first line of a failure's stderr are scrubbed on the way in as well,
against the day something puts a `glpat-…` somewhere it does not belong.
What you write in a comment does not go in either: a POST is logged as
`stdin=301B`.

```lua
log = {
  enabled = true,
  path = nil,               -- nil: $XDG_STATE_HOME/nemeton/nemeton.log
  max_bytes = 1024 * 1024,  -- past this: nemeton.log.old, and a fresh one
},
```

`:checkhealth nemeton` prints the path in effect.

## Shape

```
plugin/nemeton.lua   the command and the one global key, and nothing
                     else at startup: both resolve the plugin the first
                     time they are used
doc/nemeton.txt      :help nemeton
lua/nemeton/
  config.lua     one table: keys, glyphs, sizes
  glab.lua       the only module that spawns glab -- one file to change
                 for a different forge, or a different flag spelling;
                 also the host/token environment and the 401 retry
  threads.lua    GitLab's discussions -> "which threads are on line 42",
                 pure, and the part the tests lean on hardest
  session.lua    one merge request at a time, and everything hanging off it
  marks.lua      extmarks: gutter signs, and conversations as virt_lines
  list.lua       the merge request picker
  detail.lua     what a merge request says about itself -- the commits
                 it carries, the state it is in, the description written
                 for it -- fetched once each, drawn both in the pane
                 under the list and in the merge request's own window
  overview.lua   that window: the description, and the keys to act on it
  peek.lua       one thread, in a float
  notes.lua      the comments about the merge request rather than about
                 a line of it -- read, answered, written
  conversation.lua  every thread at once, to read rather than to walk
  qf.lua         every thread, into the quickfix list
  jobs.lua       what CI did, job by job
  trace.lua      what one job printed, in a tab
  compose.lua    the buffer you write a comment in
  edit.lua       rewriting and deleting a comment already posted
  log.lua        every subprocess, into ~/.local/state, with the token
                 scrubbed out on the way
  mentions.lua   the people you can put an @ in front of
  win.lua        where the cursor was before a window of this took it
  sha1.lua       the digest GitLab names a line of a diff with
  health.lua     :checkhealth nemeton
  init.lua       commands, keymaps, the buffer attach/detach bookkeeping
```

## Tests

```
./tests/run.sh
```

Headless, no network: a stub `glab` (`tests/stub-glab.sh`) answers from
`tests/fixtures/` and records what it was asked to POST, so the shape of
a new thread's position payload is pinned by a test rather than by a
memory of the API docs. 397 checks — parsing, indexing, the gutter, the
toggles, `]m`/`[m`, that a thread follows its line through an edit, the
two POST payloads, the list, that the host and token reach glab, that a
token function is read once rather than per call, that a 401 prompts
once and retries, and that the log records every call without recording
either the token or what a comment said.

`.github/workflows/ci.yml` runs the same suite on the oldest Neovim this
supports, on stable and on nightly, and lints with
[luacheck](https://github.com/lunarmodules/luacheck) and
[stylua](https://github.com/JohnnyMorganz/StyLua) — both configured in
the repository root, both runnable by hand:

```
luacheck lua plugin tests
stylua --check lua plugin tests/run.lua
```

## What is not done

- **GitHub.** `glab.lua` is the seam — same six operations, different
  binary — but GitHub's review model is not GitLab's (a review is a
  batch of pending comments, submitted together), and pretending
  otherwise in the data model now would cost more than waiting.
- **The diff.** You review the branch as it stands, in ordinary buffers.
  Seeing the change itself is `uatis`'s job, and the two should meet:
  nemeton knows the base sha, which is exactly what uatis wants to
  compare against.
- **Threads on the old side.** Fetched and indexed with `side = "old"`,
  but there is no old side on screen to draw them against, so they are
  drawn on the new line number.
- **Line drift.** If someone pushes while you are reviewing, the local
  HEAD stops being the revision the threads were written against. Nemeton
  says so once, on checkout, and otherwise draws the threads where they
  claim to be. Following them through the intervening diff is the real
  fix.
- **Resolving an overall thread.** The notes window reads and answers
  them; resolving is still the gutter's, because GitLab only makes diff
  notes resolvable in practice.
- **Resolvable state per note.** A thread is "resolved" here when every
  resolvable note in it is; GitLab is slightly more subtle.
- **Pagination in the list.** First 30, ordered by last touched.

## License

GPL-3.0-or-later. Copyright (C) 2026 T Gilbert. See [LICENSE](LICENSE).
