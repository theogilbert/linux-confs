# What this adds on top of difftastic

difftastic decides *what changed*. Everything about **how it is drawn** is
here, and most of it exists because a terminal diff and an annotated buffer
are not the same medium.

References are by function name rather than line number, so they survive edits.

## What difftastic actually hands us

Its `--display json` gives three things:

- `aligned_lines` — which old row pairs with which new row.
- `chunks` — per changed line, the column ranges that changed, each tagged
  with what kind of thing it is (`string`, `comment`, `keyword`, `normal`,
  `delimiter`).
- the language, and whether it parsed the file at all.

It does **not** give:

- **which words inside a changed thing are new.** Its own terminal display
  bolds them; the JSON reports only that the thing changed.
- **a trustworthy pairing inside a multi-line node.** It walks the node's rows
  in order and pairs them by position.
- anything about whitespace.

So every rule below is ours.

---

## 1. Fixing what difftastic said about rows

### `realign` — `diff.lua`

difft walks a changed block top to bottom and pairs row 1 with row 1, row 2
with row 2. Add a line in the middle and everything below is off by one, so a
line comes back **removed here and added back three rows down** — both of which
cannot be true.

We re-diff the region by line, which aligns on identical text and cannot get
this wrong, and take that answer only where it repairs rows difft left
unmatched. A genuine rewrite is left as difft read it: there its pairing is
the better one, and a line diff over a rewritten file is exactly the
re-pairing-by-coincidence we turn `linematch` off to avoid.

### A lone unchanged row between a deletion and an insertion — `diff.lua`

A single unchanged row between two changed ones normally stays inside the hunk,
so that wrapping an expression in parentheses reads as one edit rather than as
the expression being replaced.

Between a row only the *old* side has and a row only the *new* side has, that
is the wrong reading: one line went, one line arrived, and the untouched line
between them ends up inside the hunk's old range — where the before-image draws
it in red, directly above the identical green row it never left.

Between two rows that do have both sides the row is swallowed, and where the
hunk then fails to pair up line for line — a row added under the second change
— neither `carried` nor `intact` excuses it (see §4), and it came out pale red
above itself with a dim band on itself: removed and added back at once, by a
third route. `intact` now keeps a row anchored on its own identical line
whenever the rows are going to be drawn one above their partner: the majority
test there protects a passage, and rows spread each above the line they became
are no passage.

---

## 2. Deciding which rows get marked at all

### `quiet_unchanged` — `overlay.lua`

A docstring, a regex literal, any multi-line string is **one atom** to difft.
Fix a typo in the middle of one and every row of it comes back tinted, on both
sides — a seven-line paragraph gone pale with three words lit in it, and six
rows the reader must read to learn they did not move.

A row whose two sides are byte-identical refutes that on its own. The marks
come off it, on both sides (`view.lua` drops the matching `del_spans`, since
one edit cannot read two ways in two layouts). The **marks only** — the
alignment stands, so the hunk and its before-image go on reading the node as
the one thing it is.

### Rows the backend said nothing about — `overlay.lua`

A row inside a structural hunk that difft reported no changes for is unchanged
code that *moved*. Marking it — banded, or from a comparison of our own —
claims an edit the backend explicitly did not report.

### `rewritten` (`diff.line.major_ratio`) — `overlay.lua`

Where the marks cover nearly the whole line, stop marking words and band the
line instead. `var = func(foo, bar)` rewritten to a different call keeps its
brackets, its comma and its `=`, and marking around them leaves green wrapped
round islands of punctuation that read as "unchanged" — true of the character,
false of the line.

### Indentation a wrapping pushed a block by — `overlay.lua`

The one exception to *unmarked means unchanged*. Wrap a body in a guard and
every line of it moves right; difft rightly reports nothing, but where the
language counts the column that IS what the wrapping did. The columns the row
**gained** at its front are marked and nothing else on it is.

Two gates: the rest of the line must be byte-identical, and a hunk must sit
directly **above** the run — which is what a wrapper is (`if`, `for`, `with`,
`try`, a brace all open above the block they take in). A file reindented
throughout reports no hunks at all; one reindented throughout *and* edited once
would otherwise light up every row and bury the edit under the reformat.
`diff.indent_marks` turns it off.

### `joined` — `overlay.lua`

Two marked words with a space between them are drawn as one mark. difft
colours **foregrounds**, where an uncoloured space between two coloured words
is invisible; ours are **backgrounds**, where it is the most deliberate-looking
thing on the row. Applies to marks drawn on a row and to the before-image
alike — `total += self.measure(box)` losing its `total` and its `+=` came back
with the space between them at the step-back, as though a space had survived a
deletion on either side of it.

Whitespace only. Anything else between two marks is code that came through
unchanged, and covering it would claim an edit that did not happen.

---

## 3. The emphasis — the pale-and-lit thing

Entirely ours. difft's JSON reports the tint and never the words inside it.

### `atoms` — `overlay.lua`

difft reports a changed sentence as one range **per word**, with the spaces
between them unmarked. We glue them back into the sentence, because the
sentence is what the reader sees and what the emphasis is a statement about.

### `block_diff` / `inline_diff` — `diff.lua`

Work out which characters are actually new, which is the half difft's JSON
leaves out.

### `word_span`, `worth_char_diff` (`word_similarity`, `word_affix`) — `diff.lua`

Only take two replaced words apart character by character when they are alike
enough **and** share a stem at the front or the back. `closer` → `whose` shares
`ose` in the middle, and marking that gives `cl`/`r` against `wh` — fragments of
two different words. A shared prefix or suffix is something the eye can anchor
on; letters shared only in the middle are a coincidence of spelling.

### `reads_as_words` — `overlay.lua`

Only in prose — a docstring, a comment, a long literal, or any line of a file
difft could not parse. On a line of code every atom is a token, and a changed
token is novel in its entirety: there is no "half you already know" inside
`sum(`.

### `names` — `overlay.lua`

Picking removals out of a line means dimming the rest of it, and that is worth
doing only when what is picked out is something the reader can **name**. A call
reflowed across three lines has honestly lost a bracket and two commas —
dimming four lines to point at four punctuation marks is not a comparison
anyone can use.

### `refit_new` — `overlay.lua`

The emphasis is a block comparison, old rows against new, so that a
docstring gaining a line still gets an answer. But a block can match a
character against *any* old row: a docstring folded from five rows to one,
gaining its closing `"""`, found those three characters on the old closing
row and reported nothing new on the line — a pale row with nothing lit,
which reads as a change the reader cannot find.

Where difft paired the new row with one old row of the same hunk, and that
old row is on the new one whole, the row is measured against that row
instead. Only where nothing was lost: a partner the per-row comparison finds
removals on may be a positional pairing across a reflowed paragraph, where
the block's answer — which sees the words that survived the reflow — is the
better one. A row re-measured this way is not `collapsed` for the gate below:
nothing on it can have been lifted from another row.

### `narrowed_atoms` — `overlay.lua`

Whether the step-back is offered at all. Four gates, in order:

1. **Nothing new in the atom** → leave it alone. There is no half for the rest
   to be the other of. (This is what keeps the closing `"""` of a reworded
   docstring from lighting up.)
2. **The hunk collapsed** — several old rows became fewer new ones → tint whole.
   The new row is not a version of any one of them, it is what replaced all of
   them, and the emphasis there is computed over the whole *block*, so the pale
   text can be scavenged from a line that is not the one being drawn. Six
   `parts.append("title: " + plan.title)` lines becoming one f-string came back
   with `plan.title` and `plan.author` stepped back inside it, lifted out of two
   different old rows.
3. **Nothing was removed, and the row has an old partner** → step back. The old
   atom is on the row in one piece, so everything about to be dimmed is
   genuinely it. `"diagram"` → `"structural diagram"` is eleven of twenty
   characters new, and `diagram` still did not change. Both halves matter: a
   row with *no* partner also lost nothing, and stepping part of it back would
   say a wholly new line arrived carrying a sentence.
4. **Otherwise `diff.line.emphasis_ratio` decides.** Past half the atom being
   new, what is left is whatever the old block happened to contain — a
   backtick, a hyphen, a common word, matched because the character was
   somewhere in it. A README paragraph rewritten from `pip install grannos-py`
   came back with `install` greyed in the middle of a new sentence.

The two errors this trades between are not the same size. Tinting whole is a
coarse claim *inside a region difft already said changed*, so the atom-level
statement still holds and only the subdivision is lost. Stepping back wrongly
is a positive claim about **which half is old**, and when that is false it
sends the reader hunting for a correspondence that is not there — the cost a
patch already charges. So when in doubt, tint whole.

### Prose mode — `overlay.lua`

In a file difft has no parser for, every atom is a word, so narrowing to the
spans something was inserted into keeps the new word and throws the sentence
away. The row goes through whole and is narrowed as the sentence it is —
otherwise one word changed in a README read as a single lit word on a bare row
while the same edit in a docstring read as a pale sentence.

### A file of bytes is not compared — `view.lua`

Both backends would answer about a PNG: difftastic falls back to comparing
words where it has no parser, and `vim.diff` will happily split one on whatever
newline bytes it contains. Both answers are true of the bytes and useless —
marks over noise, a before-image of noise above them, counts that mean nothing.

Nothing is drawn, and the winbar says the one honest thing: `binary · 2.0 KB →
3.5 KB`. Detected from the **content** the way git detects it, a NUL byte near
the start, since the question is whether this can be read as lines and an
extension does not answer it.

The new size is read off the **disk**, not the buffer. Neovim stores a NUL as a
newline and splits on the rest, so a PNG round-tripped through buffer lines
comes back a different length than the file is — 3592 bytes read back as 5427.

---

## 4. The red rows

Old content has no line of its own to sit on. That asymmetry is the design.

### `content_survives` — `diff.lua`

No before-image where nothing was actually removed. Moving code is not
deleting it, and a full red copy of a line still visible below reads as a much
bigger change than happened. This is why a pure insertion into a line shows no
red row: the dimmed half **is** the before-image, drawn in place.

It compares tokens, and whitespace is not one — right for the moves it
excuses, where whitespace changing *is* the move. But a comment with the space
taken off its end is a change difft reports, and nothing arrived on the row to
be lit: it came out as a dim band with no before-image, changed for a reason
the reader could not see, while side by side had the space in red on the left.
So where the two sides correspond row for row, a row that lost something and
gained nothing overrules the survival test: the before-image is the only place
that loss can be shown.

It is asked against a window of rows around the hunk, not the hunk alone,
because a wrap can come back as a deletion here and an insertion three rows
down. Two kinds of row are left out of that window: rows another hunk claims
(it is painting them as added, so they cannot also be where this code went),
and — where the backend paired the rows — rows it matched with an old row
*outside* this hunk. Those stood there before the edit and answer to their
own old selves. Two tests four rows apart both opened on
`Widget(name="a", width=2.0, height=3.0)`; the first changed its `3.0` and
lost its before-image, because every token of the row it used to be was found
on the second, which nobody touched.

### `collapsed_span` — `overlay.lua`

Where several old rows were folded onto one, draw the whole construct rather
than the two rows that vanished — a before-image with the `)` taken out of it
opens a bracket it never closes.

Only where the surviving row was **rewritten** by the fold. Byte for byte the
same and nothing was folded: the rows simply went, and they went *after* it. A
file whose whole body was deleted otherwise put every removed row above the one
line it had left — above the first line of the buffer, where there is nothing
to scroll to.

### Where the red comes from — `overlay.lua`

Four sources, tried in order, for what a removed row lost:

1. the per-row character comparison (`inline.dels`),
2. the re-measurement against the row it was fitted to (`refit`),
3. **difftastic's own spans** for that old row — it reports the old side
   token by token, and knows `self.measure(box)` survived a line whose
   `total +=` went,
4. the block-level character comparison (`del_fine`) — the coarsest, and the
   one the side-by-side window draws from.

`del_fine` is last precisely because it is coarsest; taken earlier it overruled
better answers. But it is the only one left for a sentence reworded inside a
multi-line node, where the backend's spans cover the whole atom and `rewritten`
throws them out — and without it the inline before-image drew the sentence
solid red while the side-by-side window, reading that same table, stepped it
back and picked out the one word that went. **One edit cannot read two ways in
two layouts.**

Sources 3 and 4 both go through `names` and `rewritten`: a range that covers
the row says nothing, and a range that picks out a bracket and two commas is
not worth dimming a block for.

An **empty** `del_fine` for a row is not a missing answer, it is a negative
one: the block comparison was made and found nothing taken out of that row, so
the whole of the row is the part that did not change and it steps back rather
than banding. `prose_marks` has had this state all along — it tests `fine ~=
nil`, not `#fine > 0` — so without it a docstring that only gained a clause
came out solid red inline and pale side by side. Two conditions on it: the
answer must be *empty*, not merely unnameable (a row that lost a bracket and
two commas did lose them, and `names` refusing to dim a block for punctuation
leaves the row drawn as removed); and the row must be drawn as its own
comparison, directly above the row it became. A before-image given as a
**block** is one passage of old code, and greying the one row of four that
kept its closing bracket says the passage came apart rather than that it moved.

Source 4 goes through one more, `narrows_span` at `diff.line.emphasis_ratio` —
the test the side-by-side window is already applying to that same table. Being
a comparison over the whole *block*, `del_fine` is the one source whose pale
text can be scavenged out of a row that is not the one being drawn. Five rows
of comment rewritten as six came back with the `th` of `the` stepped back and
its `e` lit, matched against a `th` two sentences away. `rewritten` passes
that — the marks cover two thirds of the row, under `major_ratio`, and `is`,
`group` and `this` did survive whole — so the same edit read as three words
inline and as a banded line side by side. See `narrowed_atoms` below, which
asks the same question per atom.

### `fitted` / `refit` — `overlay.lua`

Which row a before-image goes above is difft's alignment where the pair
resemble each other, and where they do not — a line inserted above a changed
one takes the changed line's partner — the hunk's own new rows are asked which
one the old line resembles. A row re-matched that way is re-measured against
it: the backend's spans were a comparison against a line it was never the old
version of, and they say the whole row went every time.

### `diff.line.spread_max` — `overlay.lua`

One removed row directly above the row it became buys the reader a comparison
they can check without looking anywhere else. A whole passage drawn that way is
stripes: every line of the old code with a line of new code between it and the
next, so the block that was there cannot be read back **as code**. Past three
they go into one block above the hunk — old together, new together.

Counted over the rows that actually get drawn, so a long hunk most of whose old
rows are already on screen still spreads the few that are not.

### `atom_tail` — the block split at an atom's edge — `overlay.lua`

A block is one passage above the hunk, old together, new together. But a
docstring folded from five rows to one, with the two code rows under it taken
out too, is not one passage that became another: the docstring became the new
docstring, and the code rows went from where they were, which was under it.
As one block the old code sat above the docstring it used to follow.

Where the block opens with a multi-row atom (`string` or `comment`; every row
but the last runs to its line's end, every row but the first starts at column
0, blank rows read through) whose first row difft paired with the hunk's first
new row, and the two resemble each other, the atom's rows go above that new
row as one block and the rest go where the alignment puts them — above the
next new row there is one for, which is below the new atom. Two blocks, not a
row-by-row spread, and split only at the atom's own edge. The second block is
not `answered`: those rows are not what the row they hang above became.

The first row of the first block is the exception to "no step-back inside a
block" (above): the block is where it is *because* that row is the one the
new row became, so it sits directly above its own new version, and an empty
`del_fine` steps it back — this row stayed, the rows under it went. The rest
of the block is still the passage, and stays one colour.

### `UatisAddDim` on a row with a red row above it — `overlay.lua`

A row a before-image is drawn above that carries no mark of its own gets a
faint band. Nothing on it is new, but a red row over an unmarked line reads as
a deletion rather than as a replacement.

### `delete_anchor` — `overlay.lua`

Where the red rows hang: above the row they became, below the row they
followed, and above the first line for a deletion at the top of a file.

---

## 5. Navigation and colour

### `]c` stops on a row that has something on it — `overlay.lua`

A hunk can span a whole docstring while only two rows of it differ, so
anchoring on the hunk put the cursor on an opening `"""` with the edit three
rows below — a key whose whole job is to take you to the change, telling you to
go and find it. The stop is the first row of the hunk carrying a mark. A hunk
with nothing drawn on it anywhere keeps its own row: a pure deletion is
anchored where its before-image hangs.

### Backgrounds only over real code — `overlay.lua`

A foreground would replace the syntax colouring underneath, which is the one
thing this plugin exists to preserve.

### Colours derived, never invented — `setup_highlights`

Every group takes your colourscheme's own `DiffAdd`/`DiffDelete` hue, saturated
to a floor or capped, and set a distance from *your* background in whichever
direction the scheme already put it. `:UatisColors` turns every number with the
screen following.

### The caps

`inline_token_limit`, `inline_block_limit`, `diff.line.refit_pairs`,
`syntax.max_bytes`. Past these the expensive comparison is skipped, because on
a rewritten file its answer is "all of it is new" and the cheap answer agrees.

---

## Shape of it

- **§1** repairs difftastic's alignment.
- **§2** decides which rows are allowed to carry anything.
- **§3** is a comparison engine difftastic does not expose through its JSON.
- **§4** is the old side, which has no lines of its own to live on.
- **§5** is what the reader does with the result.
