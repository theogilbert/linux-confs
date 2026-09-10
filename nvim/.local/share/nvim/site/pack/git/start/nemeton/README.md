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
- shows the conversations: one at a time in a float under the cursor, and
  in a pane beside the code that reads whatever `]m` walks to — on a
  ground of their own so they do not read as more code;
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
ground a conversation is drawn on is `NemetonInline`: your own
background lifted towards the colour your text is drawn in — lighter in
a dark colourscheme, darker in a light one. A panel raised off the page and
leant towards `comments.accent` — `DiagnosticHint`, the colour every
scheme keeps for "here is something to know about, and nothing is
wrong", which is a review comment exactly, and reliably the quieter half
of the diagnostic palette. `false` there is a neutral panel with no hue
at all; `true` leans each ground towards the colour of the thread it is
under, which says the most and costs the most. Far enough to hold its own against whatever
else paints these lines: a diff plugin's red and green sit on the code
above and below, and a ground a whisper away from the file's own reads
as one more band of that. `comments.ground` (0.15, or `false` for no
band at all) is how far. A settled conversation gets `NemetonSettled`
instead — half as far, towards the resolved colour, so an argument still
going on stands off the page and one that is over sinks back towards it.
Both grounds are used under the code where the conversations are
expanded *and* inside the three windows that draw one — `:Nemeton
notes`, `:Nemeton conversation` and the peek float — where a block on a
ground of its own, running to the right-hand edge with a bare line
between it and the next, is what makes each comment read as its own box.
Those windows take the editor's own background rather than
`NormalFloat`, since this band and every band inside it are mixed out of
`Normal`. An answer inside a thread sits on `NemetonReply`, the same
ground standing `comments.reply_ground` (1.7) times as far off the page
and starting after the rail, so it reads as a panel set inside the block
rather than a stripe across it:
an indent and an arrow are two characters at the head of a line, which
is where the eye is not when it has just finished the line above, and a
step in the ground says it without being read. `comments.head_band` puts
the head of each note on a band as well, leaning towards
`comments.heading_accent` — which is deliberately *not* where the
grounds lean. `true` there is the colour of the thread the head belongs
to, which is nearly free to say on that one line: it is the line naming
who is talking, which is the line you are on when you want to know
whether the argument is over. The ground under it stays the calmer
colour the whole conversation is on. Backgrounds are the one signal here
that cannot be stacked, so `comments.heading` is small — a sixteenth of
the way, a heading you find without reading rather than a bar across the
note.
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
| `:Nemeton open` | ask which, completing over what is open by number and by title |
| `:Nemeton comments` | markers on/off |
| `:Nemeton expand` | the conversations themselves: one at a time in a pane beside the code, or all of them under their lines |
| `:Nemeton description` | the merge request's own window: what it is for, and the keys to act on it |
| `:Nemeton peek` | the thread under the cursor, in a float |
| `:Nemeton create` | a window for a merge request of your own, for the branch you are on |
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

`<leader>ml` opens the list, from anywhere. `:Nemeton open` is the other
way in — it asks for a number and completes over what is open, by number
and by title, for when you already know it is "the proxy one" and the
number is the thing you would have to go and look up.
`<leader>mo` (`keys.global.open`) is the same thing on a key. Both
halves say what they are waiting for while they wait — the prompt
cannot go up until the forge has said what is open, and nothing is on
the screen between the number being given and the branch being checked
out. The rest are bound while a
review is on and taken away when it ends — everywhere, not only on the
files of the repository: `]m` means "the next thing owed an answer", and
that is asked as often from the quickfix list, the terminal the tests ran
in or a file of another project as it is from the code itself. The ones
that are about the line under the cursor are out there too, and say so
when there is no line to be about.

| | |
|---|---|
| `<leader>mx` | expand the conversations: the pane beside the code |
| `<leader>mp` | peek at the thread here |
| `<leader>ma` | comment on this line, or on the lines selected in visual mode |
| `<leader>ms` | in visual mode: suggest a change to these lines |
| `<leader>mL` | a link to this line, or to the selection, on the clipboard |
| `<leader>md` | the merge request itself, in a float — the one review key that is not about the line under the cursor |
| `<leader>mq` | end the review: the markers and these keys go away |
| `]m` `[m` | next / previous comment, across the whole merge request |

What is bound out on the code is what the pane cannot do: read the
review, walk it, and start a comment where the cursor is. Acting on a
conversation that is already there — replying, resolving, rewriting or
deleting a comment in it — happens in the pane, where the thread is on
the screen and the cursor can be put on the comment being talked about:
`r`, `x`, `e` and `d`. They were four `<leader>m` keys out on the code,
and each of them asked a question the pane answers by being open — which
thread on this line, and which comment in it. Answering out of a picker
what you could have answered by putting the cursor on it is the long way
round. Each is still a `:Nemeton` verb, and each still has a
`keys.session.*` entry: give one a string and it is out on the code
again.

A queue with nothing in it still carries the keys across the top: what
to do about "no opened merge requests" — look at the merged ones, or
write one of your own — is the one thing a reader cannot guess from an
empty window.

In the list: `<CR>` opens one, `c` shows its commits under the list,
`d` what it says it is for and `p` what CI made of it — the jobs of the
head pipeline under their stages, the same table the merge request's own
window draws on the same key, because "failed" in a column is where the
question starts and "which job" is usually the answer to whether to open
it at all. `s` walks the queue through opened → merged
→ closed → all (the title says which, and every row that is not open
says so beside its title), `]` puts another page of them under the ones
on the screen, `+` writes one of your own for the branch you are on,
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

`<C-]>` follows what is under the cursor — there, in the pane and in the
every-thread window. It is vim's own key for "go to the thing under the
cursor" doing what it has always done: a tag jump, into a forge instead
of a tags file.

What it does by default is the quietest thing that is still an answer:
it says what is under the cursor — `User alice`, `commit a1b2c3d4` — and
puts a link on the clipboard. Nothing is opened and no window moves; a
key that took the editor somewhere would be a key pressed once by
accident and then never again, and what you usually wanted is the string
anyway: the sha to `git show`, the name to ask around about, the URL to
send to somebody.

**A link to another comment on this merge request is the exception**,
because it is the one kind whose destination is not a page somewhere
else: it is a conversation this editor already has open, so `<C-]>` goes
to it. A thread on a line opens its file, puts the cursor on the line
and the conversation in the pane; a comment on the merge request itself
opens the comments window with it under the cursor. The window you read
the link in is left first, so a float closes behind you and the pane
stays where it is. A comment this review cannot show — one on another
merge request, one resolved while resolved threads are hidden, one
deleted since it was linked — falls back to the clipboard and says which
of those it was.

`comments.follow` is one entry per kind — `mention`, `commit`, `thread`,
`path` (a link written as a path) and `url` (a page anywhere) — with
`false` for nothing at all and a function of your own for anything else,
called with what is written and where it points:

```lua
comments = {
  follow = {
    commit = function(sha)
      vim.cmd("Git show " .. sha)
    end,
    -- the forge's own pages in a browser, and somebody else's
    -- website on the clipboard
    path = function(_, href)
      vim.ui.open(href)
    end,
  },
}
```

`url` and `path` were one `link` until they were two; a config that
still says `link` is read as both.

A path is measured from wherever the forge measures it from, which is
not one place: `/group/proj/-/issues/3` from the root, `/uploads/…`
off the project, `#anchor` on the merge request's own page — and a link
relative to nothing at all from the *repository*, since clicking
`doc/design.md` on the page takes you to that file on the target branch
rather than to a page of that name on the forge.

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

`+` in the list, or `:Nemeton create`, is a window for a merge request
that does not exist yet: the title, whether it is a draft, the
description, the branch it goes to and the labels, each a field the
cursor sits on and `<CR>` changes — a title in a prompt, the description
in the composer, the branch and the labels picked from what the project
has. The labels are a dropdown that comes back with the tick moved until
you dismiss it: labels come in threes — the team, the area, the release
— and pressing the key three times to say so is three times as long a
way of saying it. Under them are the three facts nobody types: what CI
last made of the branch, and how many files and lines it changes —
counted by git against the branch it would go into, because the merge
request whose diff GitLab would answer with does not exist yet, and
drawn in the colours the queue counts a merge request in, because it is
the same fact about the same branch. `<C-s>` opens it — the branch is
pushed on the way and nothing is asked at a prompt — `r` asks CI and git
again, `X` throws away what has been typed, and `q` closes the window
with everything still in it: come back to it on the next `+`, in the
same editor session, and nothing is lost. A title beginning `Draft:`
sets the switch and leaves the title alone.

What the forge answers with is the merge request that was made, so that
is what opens: the queue it was written from closes — it was a list of
what there is to review, and what there is to review now is this — and
the review starts on the new one, discussions and all.

In every-thread (`:Nemeton conversation`): `<CR>` goes to the code the
thread under the cursor is about, `r` replies, `e` edits one of its
comments, `d` deletes one, `R` refetches, `q` closes.

The pane's own header is the one line of it that does not scroll, so it
carries what stays true while the conversation is read: its state, in
the glyph the gutter marks that line with and in the same colour; the
file and line it sits on; how many answers there are, and whether the
line carries a second argument as well. The keys sit on the right of it.
All of it is fitted to the width of the window rather than left to the
winbar's own truncation — the keys go first when there is no room (a
pane thirty columns wide is one where the file name is worth more than a
reminder that `q` closes windows), then how much of it there is, and
last the head of the path, which goes as `…app.lua:3` because the end of
a path is the half that says which file it is. The heads inside the
block are trimmed the same way, in their own order: the commit first,
then the date, and the name of who said it only when dropping both was
not enough.

In the pane (`<leader>mx`): the same keys again — `<CR>` goes to the code
the thread being read is about, `r` replies, `e` edits, `d` deletes, `+`
reacts, `R` refetches — and `q` folds the conversations away rather than only closing
the window, because while it is open the pane *is* what expanded means.
Closing it any other way says the same thing: the mode follows the
window. `]m` and `[m` work in there too: out in the code they move the
cursor and the pane follows, and in the pane they move the cursor of the
window it was opened from, so the walk happens without your reading
position leaving the prose.

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
it is not. The code itself is drawn in the colours of the language the
file is in, on both halves of the diff and in the composer while it is
being written: a suggestion is the one part of a comment that is not
prose, and in one colour end to end it is the only code on the screen
your editor has not helped you read. Not where the thread sits inside a
docstring, a long string or a block comment: what a suggestion replaces
there is prose, and prose lifted out of the file and parsed on its own
comes back as a keyword here and a function call there — confidently
wrong about what you are reading, which is worse than plain. It uses the
treesitter parser you already have for that language, a file whose
language has none is drawn plainly, and `comments.syntax = false` turns
it off. Which half of the
diff a line is then has to be said some other way — a keyword is the
colour a keyword is on both of them — so each half is drawn on a band of
its own, with the `+` and the `-` in the colour that half used to be.

In a box, and without the fence that made it one. ```` ```suggestion:-1+0 ````
is not something anybody wrote to be read: it is markup GitLab invented
so a button on the page can apply the block, and the block underneath
already says everything it says. What the fence did do was mark where the
code started and stopped, and the box says that better — two bands with a
ragged right edge in the middle of a paragraph are a stain rather than a
block. Every line is padded to the same width inside the rule.

On the top rule are the two things the fence said that the diff under it
does not: what it is, and `-1 +0` — how far it reaches, counted from the
line the thread sits on. The red half shows those lines where there is a
file to read them out of; where there is not, the two numbers are all
there is to say how much would be replaced.

The band stops at the rules, and is the one band in a conversation that
does — every other one runs the width of the editor, because there is
nothing on its line to say where it ends. Here the box says it, and red
running out through a rule and on to the right-hand side of the window is
the colour escaping the thing drawn to hold it.
`comments.suggest_box = false` draws the fence lines again, and the band
is the whole line again with them.

The head of every note says what commit it was written against as well
as when — eight digits after the date, the ones GitLab itself prints.
That is the other half of "when": a review comment is about code at a
moment, "27 Aug" says which afternoon and the sha says which push, and
`git show` on it says what the file said then. A comment on the merge
request as a whole was written against no commit and gets none.
`comments.head_commit = false` leaves the date to say it alone.

The head of every note — who said it and when — is drawn on a band told
apart from the ground the conversation is on by colour rather than by
being lighter: lighter is nearer the colour of the text, and the date on
that line is drawn in the quietest colour there is. A note
is two things read two ways: a line of bookkeeping you skim and a thing
somebody said that you read, and in a thread with four answers in it
that is four places the eye would otherwise have to find by reading. In
the comments window the same band says where one entry ends and the next
begins.

Above the first note, a thread quotes the code it is about: the lines
it is anchored to, and `comments.context` lines above them — two by
default, because a comment on one line is a comment about a line that
had something before it, and the window where that matters most is the
one read with no file open at all. Nothing is written in front of the
quotation; the rail runs down its left and keeps only its colour, which
is what says which conversation it is inside.

What has happened to each of those lines since is on the line rather
than on the block. A comment is half of a pair and the code is the half
that moves — someone pushes while you are reading, or you edit the file
you are reviewing — and the question a reader has is whether the thing
being talked about is still there. So: a line that has not moved is
drawn plain, one edited since is on a yellow band (`NemetonWasChanged`),
one that has arrived since on a green one (`NemetonWasAdded`), and one
the file no longer has is quoted from the revision that had it, on a
red one (`NemetonWas`). The three colours a diff is read in everywhere
else.

The pane draws the quotation whether anything has changed or not: the
floats are drawn over the file and you can see the line underneath
them, but the pane is read beside it, and the line a comment is about
is the one thing you cannot look at from in there without looking away
from what you are reading.

The old lines are read out of the checkout
with `git show`, not from the forge — the commit the note was written
against is one the repository already has — and a commit that is not
there any more is asked about once and then left alone, with the
quotation drawn plain since there is nothing to compare it to.

`<leader>mx` expands the conversations into a pane, and
`comments.expand` says which side it opens on: `"right"` or `"bottom"`.
A comment drawn under the line it is about is the comment where the code
is — read down the file and you read the review with it — and it is also
four blocks between you and the next function, wrapped to whatever width
the window happens to be, with nowhere in it to put a cursor, so nothing
in it can be acted on. The pane leaves the code its shape, gives the
prose a width of its own, and makes the thread you are reading one you
can answer where you are sitting.

The pane holds **one conversation at a time**. It is where a thread is
read, and a window holding every thread in the file is a window you have
to navigate before you can read anything — so the navigation is `]m` and
`[m`, which is the walk through what the review is owed anyway, and they
are the only thing that changes what is in there. Not the cursor:
reading a comment and reading the code it is about are the same activity
— you go to the line it names, then to the function that line calls,
then back through three files, and half of that is standing on lines
other people have commented on too. A pane that answered the cursor
would spend that walk showing everything except the thing being read. So
it holds still, and the comment stays on the screen while the code under
it moves. It opens on the thread under the cursor, or the next one in
the file if there is none there, and `<CR>` on a thread from the
every-thread window, the comments window or the quickfix list puts that
one in it.

It is also where the review is answered: `r` replies, `x` resolves the
thread or reopens it, `e` edits the comment the cursor is on, `d`
deletes it after asking, `<CR>` goes to the code it is about and `q`
folds the conversations away. `e` and `d` act on the comment you are
pointing at rather than on one picked out of a list — the whole
conversation is drawn in here, so you have already answered the question
a picker would ask. The head of a note counts as part of it; on a line
that is nobody's comment, the list is still asked.

`g?` prints all eleven of them in a float, which is what the header says
about the keys: it used to spend its right-hand side on `]m next · r
reply · <CR> code · q close`, said in full and then as the letters alone
for a narrow pane, and that was a reminder for the first afternoon and a
column of the file name's room for ever after. The help is read out of
the bindings themselves, so it cannot drift from them. `q` or `<Esc>`
closes it and puts the cursor back.

What the gutter does while a conversation is being read is say which
lines it was written against: the bubble marks the line a thread is
anchored to, and a comment written over a selection is about the lines
above that too — which nothing on the code says once the words are in a
window next door. Those lines get the rail the thread carries down its
left in the pane (`comments.sign_span`, `false` to leave the gutter to
the bubbles), in the colour of the same state, under the bubble's own
priority so a one-cell sign column still shows the bubble.

The code itself gets a band under those lines as well
(`NemetonReading`, at `comments.reading_ground` of the strength of the
ground a conversation is drawn on — the two are one block read in two
windows, and this is the stronger of the two: the band in the pane has
only to hold a block together, and this one has to be found in a
screenful of code). That is the part the gutter could not do: every line carrying
a thread has the same bubble on it, so with three conversations in a
file nothing out here says which is the one you are reading, and a
thread about a single line has no line above it to put a rail on at
all. The band says it in every case, and says it with the sign column
turned off. `comments.reading_ground = false` leaves the gutter to do
what it can.

`comments.expand_anchor` is which window the pane is a split of:
`"window"` splits the one the code is in, so the pane arrives beside it
and the rest of the screen keeps the layout you built; `"editor"` puts
it against the edge of the whole editor — full height down the right,
full width along the bottom, where the quickfix window already opens.
`comments.pane_width` (60) and `comments.pane_height` (15) are where it
starts — never more than half the screen, whatever they are set to,
since sixty columns is most of an eighty-column terminal and a pane that
leaves nineteen columns of code is a pane you open once. It is an
ordinary window afterwards, resized like any other.

A comment is wrapped to the window it is drawn in, and to
`comments.wrap` — 80 columns by default — wherever the window is wider
than that. The floats have to wrap: they are drawn over the code and
there is nowhere for a long line to go. The second limit is for the
other end of it — prose set across the whole of a wide editor is prose
the eye loses its place in. `comments.wrap = false` wraps to the window
and nothing narrower.

In the pane the words always wrap; `comments.pane_wrap` is about the
code. It is off by default: the pane is a real window with a real
buffer, so a line too long for it is a line to scroll sideways to
rather than a line lost — and a fenced block, a ruled table and the two
halves of a suggestion all mean what they mean by their columns, none
of which survives being folded at the edge of a sixty-column pane. The
other half of it is the rail: a wrapped line comes back at column zero,
outside it, so the one part of the block that says where the thread
starts and stops goes missing from exactly the lines that needed it.
Neither argument is about prose — nobody scrolls sideways to read
English, and a sentence broken at a space is the same sentence — so a
comment is wrapped either way. `comments.pane_wrap = true` wraps the
code with it.

A comment written over a selection is anchored to its last line and
carries the rest as a line range — which is what GitLab draws as
"Comment on lines 57 to 59". **On GitLab older than 18.6 that range goes
without its two line numbers**: up to 18.5 the API declares them as
strings, coerces the integers a client sends into them, and then
validates the position it built against its own schema, which says
integers — so it refuses its own payload with
`position: ["must be a valid json schema"]` and names no field. nemeton
asks the forge its version before the first one and leaves those two out
where they will not be taken; the line codes are what anchor the
comment, and only GitLab's own range label is the poorer for it. A forge
that will not say what it is gets the whole payload and is sent it again
without them if it refuses — once, and remembered for the session.

### A line the change deleted

A deleted line is in no buffer of the branch — that's what deleted
means — so there is nowhere to put the cursor. nemeton doesn't draw a
second copy of your file to fix that; reviewing in the buffer you are
editing is the whole shape of the plugin. It takes an old side from
whoever drew one instead.

Any buffer showing the file at the revision the merge request is
measured against will do, and there are three ways to say which:
`comments.old_side`, a function of yours given the buffer number and
returning `{ path = …, sha = … }`; `b:nemeton_old`, the same table on
the buffer; or the buffer's own name, `<scheme>://…/<sha>/<path>`, which
is how fugitive, diffview and gitsigns each name one — so those work
with no configuration at all. The name is a guess and is taken only when
the sha is one this merge request is compared with; a buffer showing
some other revision is refused with what it is showing, rather than
building a position against a diff GitLab has never seen.

There, `<leader>ma` comments on the old line — a removed line is
anchored on the old side alone, a line the change left alone on both.
`<leader>ms` is refused, since a suggestion patches the branch and there
is nothing on the old side to patch, and `<leader>mL` links to that
revision.

```lua
require("nemeton").setup({
  comments = {
    -- the example is uatis, which puts the old revision in a window of
    -- its own; neither plugin has to have heard of the other
    old_side = function(bufnr)
      local view = require("uatis.oldside").view_for(bufnr)
      if view then
        return { path = view.old_path or view.relpath, sha = view.rev }
      end
    end,
  },
})
```

A comment is markdown, and wherever one is read it is drawn as the page
the forge would have drawn rather than as the characters it was typed
with. The composer is the other half of that promise: what you write
there is the source, because the source is what is posted.

A **link** is drawn as the words it was given.
`[the failing job](https://…/-/jobs/1234)` is four words and a hundred
characters of where they point, and the hundred are what wraps a
two-line comment across five. `NemetonLink` — the colour a reference is
drawn in here, underlined the way a link has always been — and where it
goes is not lost: `<C-]>` on it follows it. A picture, `![alt](src)`, is
drawn as its alt text: a terminal has nowhere to put a picture, and the
alt text is the sentence its author wrote for exactly this case.
`comments.links = false` leaves the brackets.

A **heading** is drawn without the hashes. There is no larger type in a
terminal, so a heading here is a colour and a line of its own — which is
what says "heading" everywhere else in this plugin — and the level it
was is a weight rather than a size: `NemetonHeading1` is underlined and
bold, `NemetonHeading2` is bold, `NemetonHeading3` is the colour alone,
and `4` to `6` fall away through italic to the quiet colour, so a
comment with two levels of heading in it reads as two levels. All six
take their colour from `NemetonHeading`, which is `Title`.
`comments.headings = false` leaves them.

**Emphasis** is drawn as emphasis: `**must**` in bold, `*maybe*` and
`_perhaps_` in italic, `***both***` as both, `~~was~~` struck through.
These are the marks a reviewer reaches for to say which word of a
sentence carries it, and read as the asterisks they were typed with they
say it about the punctuation instead. `NemetonBold`, `NemetonItalic` and
`NemetonStrike` carry no colour of their own — a bold word in a settled
thread is dim and bold, and a bold link is still blue and underlined.
An underscore inside a word emphasises nothing, so `snake_case_name` is
a name; a marker nobody closed is the character it is, so `2 * 3` is
arithmetic; and one written `\*like this\*` is drawn as the characters
it escapes, which is how you write an asterisk in a sentence about a
glob.

A line that ends in a **backslash** is markdown's hard break — "and the
next line goes under this one" — which is what these windows do with
every line of a comment anyway, so the backslash itself is not drawn.
Only where there is a line under it to break to: one at the end of a
paragraph broke nothing and is a backslash its author typed.

A **code span** is drawn without its backticks, in `NemetonCode`
(`String`), and nothing inside one is markup: `` `a_b` `` is an
identifier, a URL in backticks is a string somebody quoted rather than a
page to go to, and `` `@alice` `` is not somebody to notify. A run of
backticks closes on a run of the same length, so `` ``a `b` c`` `` is
one span. `comments.styles = false` leaves every marker as it was typed.

A **link to another comment** — the `…#note_1234` permalink GitLab's
own "copy link" gives you — is drawn as `!7 (comment 1234)`, what the
forge calls the review and the comment in it, and `<C-]>` on it goes to
that conversation rather than copying a URL. It is the same argument as
a commit permalink: a hundred characters of which twelve are the
content. Words of your own win, as ever —
`[why we dropped it](…#note_1234)` is drawn as "why we dropped it" and
still goes there.

A **table** is ruled and its columns are lined up, with the alignments
its delimiter row asked for. Markdown's own is a table only in the sense
that the columns are named: the cells line up in the source when its
author lined them up by hand, and what you are reading is somebody else's
hand. Too wide for the window, the columns give up room from the widest
first and a cell that still does not fit is cut with an ellipsis — a
ruled table cannot wrap, because a rule that wraps is two rules.
`comments.tables = false` leaves the pipes.

None of it changes what is sent: `:Nemeton edit` posts back the text its
author wrote, brackets and hashes and pipes and all, because that is what
the forge renders and what the next person to edit it has to see. Inside
a fenced block nothing is rendered at all — code that says `[a](b)` says
`[a](b)`.

A link to a commit is drawn as the eight digits GitLab itself prints —
`a1b2c3d4` where a permalink was, since a permalink is a hundred
characters whose only content is the forty at the end of it, and a
comment carrying two of them is mostly URL. Both shapes the forge
writes: a commit of the project, and a commit of this merge request
(`…/merge_requests/7/diffs?commit_id=…`). A markdown link keeps the
words its author chose in front of the sha. This is how a comment is
*drawn* and nothing else — `:Nemeton edit` sends back the text its
author wrote, links and all. `comments.short_commits = false` leaves
them whole.

What a comment *points at* rather than says is drawn in a colour of its
own: `@somebody` in `NemetonMention` and the commit it blames in
`NemetonCommit`, both `DiagnosticInfo` — the same colour as a link, since
all three are one kind of thing: a reference out of the comment. They are
the things in a comment that point somewhere else — a person to ask, a
commit to go and read, a page — and all of them are looked for by
scanning rather than by reading the sentence around them. An address is not a mention and a word is not
a sha: a name has to start where a word starts, and a run of hex counts
as a commit only if it has both digits and letters in it, since seven
characters of nothing but a-f is a word English happens to have and
seven of nothing but digits is a number somebody wrote down. In a settled
thread as well as an open one: the rest of one is dimmed because it is
history, and the commit it names is not history — it is what somebody
reading a resolved argument came for. `comments.references = false` turns
it off, and takes those two out of what `<C-]>` can find with them.

`:tada:` is drawn as 🎉, the way the forge would have drawn it — a
comment read with the colons still in it has a word missing out of the
middle of a sentence. Drawn only, on the same promise: what is sent when
a comment is written or rewritten is the text its author typed, colons
and all, because that is what GitLab renders and what the next person to
edit it has to see. A suggestion is left alone as well — it is code, and
code that says `:tada:` says `:tada:`. `lua/nemeton/emoji.lua` holds the
names, which are what a review is written with rather than the whole
eighteen hundred of gemoji; one it does not know is left as it was
typed, which is what a forge does with an unknown name too.
`comments.emoji = false` leaves all of them alone.

**Reactions** are the emoji people put *on* a comment rather than in
one, and they are drawn under the note they were given to — a picture
per emoji with a count beside it, in the order they were first given.
Three thumbs on a suggestion is an argument being over, and nobody
writes "agreed" three times. `+` in the pane gives one to the comment
under the cursor, and picking an emoji you have already given takes it
back, which is GitLab's own gesture and the only one there is; yours
are drawn in a colour of their own so the picker and the row agree
about what the key will do. `comments.reaction_names` is what it
offers, plus whatever is already on the note.

That list is short on purpose and it is not the limit.
`vim.ui.select` is a numbered list unless you have replaced it, and a
numbered list of all 258 names `emoji.lua` knows is a wall rather than
a picker — so the ten you actually react with are the picker, and its
last row, "another emoji", is a prompt that completes over the rest.

That prompt is a window of this plugin's own rather than
`vim.ui.input`: it is the one place here that is nothing *but*
completion, and `completion` is the half of the `input` contract that
half its replacements quietly drop — a prompt that says "`<Tab>`
completes" where `<Tab>` does nothing, with no way to tell from either
side. So it is a one-line float with the names behind it and the
menu coming up as you type, each with its picture beside it. The
buffer's `omnifunc` is set too, for `<C-x><C-o>` and for a completion
engine to point at. The
whole list is up before you press a key, which is the answer to "like
what?"; `<C-n>` and `<C-p>` walk it, `<CR>` takes the line as it
stands, and `<Esc>` dismisses it.

A name it knows is the reaction, a prefix only one name answers is that
name, and anything else goes to the forge as you typed it — gemoji has
eighteen hundred names and this knows two hundred and fifty of them.
The name is taken off the front of the answer, so a candidate chosen
out of the menu, a bare `rocket` and a pasted `:rocket:` are one
answer.

The whole of it is one
GraphQL call beside the discussions — REST publishes reactions one note
at a time, which would be a request per comment — and it fails quietly,
because an instance too old for the field is a review drawn without
pictures rather than an error after every post.
`comments.reactions = false` turns it off and saves the call.

In the composer: `<C-s>` or `:w` **keeps** the comment for the review
you are writing, `<C-p>` posts it to the merge request there and then,
`<C-b>` turns it into a suggestion, `q` puts it away, and two sigils
complete — `@` the people on the project
and `:` the emoji GitLab draws as pictures. The menu comes up as you
type either, `<C-x><C-o>` asks for it where it does not, and what goes in
is `@username` and `:tada:`, sigils and all, because that is what GitLab
turns into a notification and into a picture. Keeping is the default
because a review is written as a whole: a comment posted the moment it
is typed cannot be taken back after reading the next file.

`<C-b>` — in insert mode, which is the mode you are in when it happens
— is there because a comment turns into a suggestion halfway
through writing it — you get as far as "it should be" and notice that
showing it is shorter than saying it. It drops GitLab's fence in under
what you have already written, with the lines the comment is about
already inside it, and leaves the cursor on the first of them: a
suggestion is an edit of what is there, and retyping four lines to
change one word is how a reviewer decides not to suggest anything. It
is bound only where there are lines to put in the block — not on a
comment about the merge request as a whole, and not on the old side of
the diff, where a suggestion would be a patch of code the branch does
not have.

`q` puts it **away**, not out: closing the composer with something in
it keeps that something, and the next time you write the same comment —
the same lines of the same merge request, the same thread answered — it
comes back. Across restarts too, which is the point of it: `nvim` gets
restarted between reading a merge request and finishing the sentence
about it more often than anyone would like, and a comment that vanishes
because you went to check something is a comment written twice. What is
remembered is what is in the buffer, so emptying it and closing is how
you throw one away; it is also forgotten once the comment is sent or
kept on the forge, and after `compose.remember_days` (30). They live in
`$XDG_STATE_HOME/nemeton/composing.json` at 0600 — the one thing here
that writes what you typed to disk, and `compose.remember = false` is
that off.

A write the forge **refused** says what the forge said — its own words,
taken out of the JSON body `glab` prints whole, so `position: must be a
valid json schema` rather than the braces around it — and then refetches
anyway. "It failed" and "nothing happened" are not the same thing: a
call can land, be written down, and still come back an error, and the
editor is then holding a picture the forge does not agree with — the
comment you can see in `glab` is the one that is not on your screen.

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
  markdown.lua   a comment read as the page rather than as the source:
                 links, headings, emphasis, code, tables, fences -- pure,
                 and a parser only, since the drawing is threads.lua's
  follow.lua     what <C-]> goes to: where each kind of reference has a
                 page, and the one kind that is a thread in here instead
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
  pane.lua       the threads of the file you are reading, beside it
  qf.lua         every thread, into the quickfix list
  jobs.lua       what CI did, job by job
  trace.lua      what one job printed, in a tab
  compose.lua    the buffer you write a comment in
  prompt.lua     one word asked for in a window of this plugin's own,
                 with the menu of what it can be under it
  edit.lua       rewriting and deleting a comment already posted
  log.lua        every subprocess, into ~/.local/state, with the token
                 scrubbed out on the way
  mentions.lua   the people you can put an @ in front of
  emoji.lua      the names between two colons, and what they draw as
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
memory of the API docs. 955 checks — parsing, indexing, the gutter, the
toggles, `]m`/`[m`, that a thread follows its line through an edit, the
two POST payloads, the list, that the host and token reach glab, that a
token function is read once rather than per call, that a 401 prompts
once and retries, and that the log records every call without recording
either the token or what a comment said.

Colour is the one thing here a test cannot settle, because every number
in `comments` means something different against every colourscheme. Open
a merge request and `:luafile dev/dial.lua` for a float that turns the
knobs — `accent`, `ground`, `reply_ground`, `head_band`,
`heading_accent`, `heading` —
with the comments window redrawing behind it on every keypress, and `p`
to print a `setup{}` block for whatever you stopped on. It is not on the
runtime path and writes nothing; quitting reverts all of it.

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
