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

---

## 4. The red rows

Old content has no line of its own to sit on. That asymmetry is the design.

### `content_survives` — `diff.lua`

No before-image where nothing was actually removed. Moving code is not
deleting it, and a full red copy of a line still visible below reads as a much
bigger change than happened. This is why a pure insertion into a line shows no
red row: the dimmed half **is** the before-image, drawn in place.

### `collapsed_span` — `overlay.lua`

Where several old rows were folded onto one, draw the whole construct rather
than the two rows that vanished — a before-image with the `)` taken out of it
opens a bracket it never closes.

Only where the surviving row was **rewritten** by the fold. Byte for byte the
same and nothing was folded: the rows simply went, and they went *after* it. A
file whose whole body was deleted otherwise put every removed row above the one
line it had left — above the first line of the buffer, where there is nothing
to scroll to.

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
