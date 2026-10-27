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

A rewrite refused that way still gives up its **edges**: the rows at either end
of the region that are byte-identical on both sides, read inwards from rows the
two sides agree on, are paired as unchanged. difft calls a node's opening rows
novel when the node was rebuilt around them — `follow = {` whose table gained
fields comes back red above the same `follow = {` in green. Only where that
changes a pairing: an edge difft already paired with its twin (a docstring's
first rows) is left to `quiet_unchanged`.

A region ends at the first row both sides agree on, and one such row can be a
coincidence of the damage. Taking a class header out hands its methods to the
class above: to difft they are new there and gone from below, and the agreed
rows it still finds — a blank line, a `c = Config()` — cut that into regions
too small for the line diff to see a method in one as the same method in
another. So a run of regions with ONE agreed row between each is diffed as one,
and kept as one up to the furthest such row a match crosses: a non-blank line
identical on both sides, with its old copy on one side of the row and its new
copy on the other, and difft calling the old copy removed and the new copy
added. Both conditions matter. A blank line pairs with any other, and a line
difft left unmarked was in place — a new method calling `self._write_locked()`
otherwise matched the call an old method kept, and two edits either side of it
were diffed as one with their rows paired off in order.

The majority gate steps aside for one kind of match: a line difft deleted
outright in one place and inserted outright in another, byte for byte the
same, each copy a row it gave no partner. Taking that line as unchanged
overrules nothing — difft already said it went and came back. Five rows put in
above an untouched `# Handle the request`, with the block under it collapsed to
one line, matched that comment and nothing else; refused as one row of twelve,
the comment was drawn removed above the insertion and added six rows lower.
Unpartnered, not merely marked: every row of a multi-line atom is marked and
paired by position, and a docstring's closing `"""` matched out of a rewrite
would cut the rewrite in two.

It steps aside as well for a RUN of such lines: two or more matched in order
on both sides, every copy a row difft marked. That is its positional walk
inside a multi-line atom gone wrong: a docstring whose middle paragraph went
from six lines to five paired its `Args:`, `event: ...` and closing `"""` each
against the row above its twin, and the reworded paragraph outweighed them.
A lone match stays a coincidence — inside a multi-line atom.

Outside one it does not. Where every line the line diff matches is a statement
of its own (no row of a string or comment that runs over several, read off
difft's spans: an atom of that kind reaching one row's end and the next row's
start) and difft contradicts each, the repair is taken. Two imports re-sorted
paired the untouched one with the new import above it and its twin with the
one taken out below: drawn removed above itself and lit as an edit of another
module's import. The cost is that a rewrite whose one surviving line is a bare
`return` is now drawn in two pieces around it, as git draws it.

The line diff of a region is taken twice where it matters: as is, and with no
blank line able to match anything, the second answer winning where it matches
more lines that are not blank. A blank line is text like any other to the diff,
and where one crosses a real line, the diff can keep the blank — five rows put
in above an untouched `# Get request line`, the old blank under it and the new
one above, matched the blanks (which no gate counts) and nothing else, and the
comment was drawn removed above the insertion and added under it.

### `prefer_lines` — `diff.lua`

After `realign`, the whole file is diffed by line once and the two alignments
are compared between the rows they agree on. A function split in two has two
readings that are each right about something: moving `send_response`'s body
into a new `send_response_headers` above it, difft follows the body and calls
the new function the old one renamed, so the unchanged `def` and fourteen-row
docstring were red where they were and green where they are, and the moved body
read as code the new function always had. The agreed body rows keep the two
copies of the docstring out of any one region `realign` sees.

A stretch between agreed rows takes the line diff's reading only where difft
has *misattributed* a line there — paired it with different text while its
byte-identical twin on the other side has no partner at all — and the line
diff's matches difft contradicts (misattributed, or deleted outright and
inserted outright) number at least two and outnumber difft's own agreed lines
it would undo. Misattributed, because a docstring grown in the middle is paired
by position on both sides and `realign` has it; and a swap of two functions is
unpaired on both sides, which is a move. A line paired with different text at
*both* ends is misattributed too — a test put in above another, the one after
removed, came back with each test handed to the one before it, the kept test's
`def` drawn as one renamed into it and another renamed out of it — but only a
line each file has once, and only where both partners differ past the
indentation: a `try:` or `)` paired that way is difft choosing another copy, and
a lone `return` paired with its reindented self moved into a new `try:`; counted,
the wrapped block was drawn removed and added back. difft's agreed lines count only where
they are byte-identical: a row it kept across a reindent did change, and drawn
as changed claims nothing false. With none of those in the stretch nothing true
is undone, and no misattribution is needed: two blocks that swapped places, one
pushed under a new `if`, came back with the reindented one kept and the
untouched one drawn deleted and inserted whole.

A byte-identical line both readings match, each to a *different copy* of it, is
a tie rather than an agreed line: the two agree it stayed and differ only on
which copy is the old one. A test gaining a sibling below it that repeats its
eleven-row setup came back with difft handing the setup to the sibling, under
its new name — the untouched test's body painted added, the sibling's drawn as
old. The tie goes to the reading that keeps the line in step with the agreed row
*above* the stretch, the `def` it sits under: counted with the line diff's
matches where that is the line diff, with difft's agreed lines where it is
difft (a function whose old body the line diff would hand to a new sibling
below it keeps it). Above rather than nearest, because the row below a stretch
is as often the neighbour of whatever was inserted as anything of this block's.

Two at least, as a rule; one is enough where the misattributed line is the only
copy in each file — a comment moved below a block put in above it, its first
line untouched, was drawn removed and added back twelve rows apart, and a
sentence the file says once is not the coincidence a bare `return` is. But not
where the reading it carries would split a pairing of a line with itself
reindented: one assignment moved out of a block wrapped in a new `try:` would
have had the whole block drawn removed and added back.

A stretch that fails that count is counted again over the lines its old side
has *once*. Tests in a class whose every member ends `try:` / `conn.init()` /
`finally:` / `conn.sock.close()` / `client.close()` came back with difft
pairing each old test with the new one after it, so an untouched test was
painted added and its old rows went to a new neighbour — and difft held
twenty-one identical lines to the line diff's eleven, every one of them that
trailer. A line the old side has four of is evidence for neither reading,
since either can pair it with a copy; a line it has once is where that line
went. Only as a second count: over every line is the count the cases above
were settled on, and nothing they took is given back.

In the rebuilt stretch difft's pairings
that do not cross a match stand; a pairing that does is split, and each half,
having lost the partner its marks described, is drawn whole.

### `slide_deletions` — `diff.lua`

difft matches blank lines like any others, and around a block removed whole it
tends to keep the blanks *after* the block and leave the ones before it
unpaired. Same edit either way, but the before-image hangs where the alignment
puts it: a class removed from between two others came back hung straight under
the last line of the method above, the blank rows that had separated them below
it, reading as more of that method. So the unpaired old blanks a removed run
opens with are paired with the new blank rows just below it, and the old blanks
after it go unpaired instead — the block hangs below the blank lines, as git
draws it.

Only a block that is a *sibling* of what follows, starting no deeper than the
next line kept. The removed tail of a body (`return None`, the next `def` four
columns out) belongs with the code above it, before the blank line; slid past
it, it hangs from the next definition instead.

### `slide_runs` — `diff.lua`

A block one side has whole, bordered by lines that are byte-identical on both
sides and repeat its own first or last lines, can be drawn at any of several
places that are all the same edit. A test inserted above another under the same
three `@mock.patch` decorators: difft kept the decorators paired at the top, so
the new test's own decorators read as old code and the untouched test below
was painted as though it had gained them. Among the places the identical lines
allow, the block goes to the nearest one where its first non-blank line follows
a blank line (or the top of the file), as git's slider does — only where it
does not already start that way, only across at least one non-blank line (where
blank lines go is `slide_deletions`' to say; moved for their own sake one was
banded inside an inserted block), and only for a block of lines that went or
arrived, every one, so a reflow's unchanged continuation rows are never
counted. A row taken off a pairing to join the block is marked whole, since
difft had nothing to say about one half of an unchanged pair. Measuring the
start by the first line rather than the first non-blank one slid a function
inserted after two blank lines up onto the `return` above it.

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

That still left the row swallowed wherever the hunk was drawn as a block.
`except Exception:` → `except BaseException:` over an untouched `if` and a
rewritten two-line comment is a 4-into-4 hunk in which only two rows resemble
their partners, so it went up as one block: the `if` red above itself, and the
old comment hoisted above the `except` instead of the comment that replaced it.
So a row byte for byte the same on both sides is never swallowed. A wrap
reindents what it wraps, so the row the rule is there for differs by its
whitespace; one that does not differ at all was not part of the edit, and the
two changes either side of it are two hunks.

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
Blank rows outside any hunk do not end the run: they have no indentation to
gain, and a wrapped block has them between its paragraphs. A run that stopped at
one left everything under the first blank line of a `try:` body reading as
untouched, and a block a blank line below its wrapper's hunk unmarked entirely.
`diff.indent_marks` turns it off.

### `clip_indent` / `indent_delta` — `diff.lua`

The block comparison (`block_diff`) says nothing about leading whitespace.
Indentation was a token in it like any other, and a token diff matches by
content and not by row: an eight-space indent on old row one paired with the
eight spaces on new row one — a row that had never been there — and the row
it had really become came back with its unchanged indent lit, while a row
pulled right under a `try:` had its whole twelve-space token marked rather
than the four columns it gained.

Whether a row's indentation changed is a question about that row and the row
it was a version of. Where that pairing is known — positional in a 1:1 hunk,
difft's `pairs` inside a structural hunk, `fitted` for a row re-matched for
its before-image, or `inline_diff` of one line against one — the columns it
gained go on the new row and the columns it lost on the old, and only those.
The same claim the rule above makes for a row outside any hunk.

### `joined` — `overlay.lua`

Two marked words with a space between them are drawn as one mark. difft
colours **foregrounds**, where an uncoloured space between two coloured words
is invisible; ours are **backgrounds**, where it is the most deliberate-looking
thing on the row. Applies to marks drawn on a row and to the before-image
alike — `total += self.measure(box)` losing its `total` and its `+=` came back
with the space between them at the step-back, as though a space had survived a
deletion on either side of it.

Whitespace, and **one character of punctuation** with it. A lone `.` or `(`
between two marks is difft matching it against a `.` or `(` of whatever old
row it aligned with: `uatis.showing(bufnr)` in place of `vim.fn.setreg(...)`
came back with its dot stepped back. A word, or two marks of punctuation, is
code that came through unchanged, and covering it would claim an edit that
did not happen. `atoms` keeps to whitespace: a comma between two literals is
where one ends.

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

Except where the marks are the whole edit: the hunk added nothing, and its old
rows with difft's removals cut out read as its new rows, whitespace aside
(`only_lost`). A last parameter dropped with the comma before it — `port,` /
`timeout):` becoming `port):` — lost only that comma from `port,`; refused,
the row was drawn solid red as though `port` had gone with it. The hunk and
not the row, because the `):` that survived moved up from the row below.
For a fold (`collapsed_span`) the rows compared are every old row folded and
the one row they went into: ruff joining the two parameters left onto one line
is a hunk with no new rows at all, and measured against nothing,
`fields_columns,` was drawn solid red.

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

Whether the step-back is offered at all. Five gates, in order:

1. **Nothing new in the atom** → leave it alone. There is no half for the rest
   to be the other of. (This is what keeps the closing `"""` of a reworded
   docstring from lighting up.)
2. **Only punctuation would stay pale** → tint whole. The quotes of `"old"`
   match the quotes of any string it was aligned with; that is the character
   they share, not an old half.
3. **The hunk collapsed** — several old rows became fewer new ones → tint whole.
   The new row is not a version of any one of them, it is what replaced all of
   them, and the emphasis there is computed over the whole *block*, so the pale
   text can be scavenged from a line that is not the one being drawn. Six
   `parts.append("title: " + plan.title)` lines becoming one f-string came back
   with `plan.title` and `plan.author` stepped back inside it, lifted out of two
   different old rows.
4. **Nothing was removed, and the row has an old partner** → step back. The old
   atom is on the row in one piece, so everything about to be dimmed is
   genuinely it. `"diagram"` → `"structural diagram"` is eleven of twenty
   characters new, and `diagram` still did not change. Both halves matter: a
   row with *no* partner also lost nothing, and stepping part of it back would
   say a wholly new line arrived carrying a sentence.
5. **Otherwise `diff.line.emphasis_ratio` decides.** Past half the atom being
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

The question is asked of a **node**: consecutive prose rows, carried across a
blank row only where both sides of it are a string. A docstring's paragraph
break is a row of the one atom; a blank line after a run of `#` comments ends
it, and joined through one, a comment added whole above an edited one took the
edited one's comparison and was drawn dim — five new lines reading as the part
that had not changed — and a string on a wholly new line had its words stepped
back because a comment two rows below was compared.

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

"Row for row" is the character comparison, which is offered for twenty rows at
most — and a docstring is one atom, so difft made all thirty-one rows of one a
single hunk for three trailing spaces, and they came back dim with nothing
above them. Past that, the pairing answers for a hunk that is a whitespace
cleanup and nothing else: every row its own old self, or that with spaces taken
out at the same indentation and something left on it (`lost_space`), each drawn
with only the spaces red. Nothing else, because anything more is what the
survival test is for: a paragraph reflowed *and* cleared of trailing spaces is
a reflow, and drawn for the spaces it was thirty rows of red passage.

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

### `intact` / `moved_to` — `overlay.lua`

Per row, after the hunk as a whole is found to have removed something: a
removed row whose partner is byte-identical is still on screen, and so is one
that reads exactly like a row of the **same hunk** that difft paired with
nothing (`moved_to`) — a docstring that grew lays its old sentences beside the
new ones in order, and the last comes out against unrelated text while its
twin sits four rows down drawn as new. Those rows are left out of the
before-image when they are most of it.

Same hunk only. A function moved to the top of the file and rewritten keeps
half its body; the new copy is another hunk, and its lines once excused the
same lines out of the old copy — the before-image lost its signature and the
rest hung under the function above, reading as part of it.

The unchanged rows at the TOP of a hunk are left out whatever the majority
test says: they leave no hole, and the block is hung under their own new
copies — above the row its first drawn row answers to — so it reads on from
them as the passage did. A docstring with its middle paragraph reworded was
drawn in full, its opening line and the blank under it red directly above the
identical rows. The bottom only where the top went too: the rows there sit under
the NEW block, so the old one taken off them stops short — a call reflowed down
to its unchanged `)` would be drawn opening a bracket nothing closes. With both
ends off it is the inside of something whose ends are both on screen.

### A moved definition — `moves.lua`

Before any of the above: difftastic aligns in order and so does `vim.diff`,
so a definition moved within the file comes back as a removal and an
addition, its whole body red in one place and green in the other. A
tree-sitter node lying wholly inside one side's removed rows, paired with one
wholly inside the other side's added rows — same node type, same name and a
little alike (`diff.move.named_similarity`), or no name and alike enough
(`similarity`) — is a move, provided something that stayed sits between the
two places; otherwise it is a rewrite in place, which the backend had right.

A name is a definition's only where it names something outside a function:
an assignment's target counts at the top of a file or in a class body
(`M.foo = function`, a settings class's `desc`), not inside a function, where
it is a local. A `chunk = await ...` rewritten in one method was paired with a
new `chunk = await ...` in another twelve hundred rows below, and drawn as
moved there, while the edit where it stood drew nothing.

The pair in place is still scored, and competes for both nodes: where it is
the better match it takes them and nothing is drawn. Left out, a definition
rewritten in place was free to pair with any other that shared its name. Two
settings classes whose `desc` docstrings each gained a paragraph — one atom
each, so each wholly inside its hunk — came out as each docstring moved into
the other class and rewritten into its text. `xmoves.pair` already did this
across files, pairing a file with itself and dropping the pair.

The answer to DRAW (`result.drawn`) then has both copies carved out — with
the blank separators that went with them — and the backend's comparison of
the two copies spliced in at the new one. Every rule below runs on that
answer, so inside a moved function they see an ordinary edit. The overlay
adds a line at each end and a `]c` stop at each. The counts keep the
backend's own answer: git sees a removal and an addition.

Read marks go by the stops `]c` makes (`view.stops`): the edits inside the
moved definition, and its two ends. The old end has no row on the new side,
so it stands on git's chunks by their OLD rows (`stop.old`), and is read when
it is left -- each end on its own, the move once both are. Stops nest here,
the move's spanning the edits inside it, so a step leaves every stop the
cursor is inside, not only the nearest. A stop standing on no chunk is read
only once left: counted read for having nothing under it, the old end was
read before the reader had moved. `<C-]>` off an end leaves it as `]c` would
— from the old window too, where the end left is the row the old copy's note
hangs on in the buffer — and the mark goes to the list of the view's own
review, not whichever list is in the current tab: the leave runs a tick
later, and a review in another tab can list a file of the same name.

Side by side, the old window MARKS from the rewritten answer and LINES UP by
the backend's, since one layout has one order and the rewritten answer is out
of it. Each copy stands opposite blank rows; the cursor inside the new copy
scrolls the old window to the old one, and the notes go at the end of a row,
since a virtual line in one window and not the other puts every row below it
out of step.

### A definition moved to another file — `xmoves.lua`

A move between files is in two comparisons that cannot see each other, so it
is found by the review: once per read of the list, from git's chunks, which
say which rows of every file went and came. Files with enough of either are
parsed — old text at the revision, new text off the disk, git's rows being the
disk's — and definitions are paired across files by the rules above. A pair
inside one file is made too and dropped: it is the view's, and making it keeps
a lookalike in another file from claiming either half.

With a commit on show both sides come out of git, the commit and its parent,
and an index is keyed by the revision and the commit (`across_key`): stepping
`]C` re-reads the list, and the commit just left must not draw on the next.

The end a definition moved OUT of counts what changed on the way too: the
index keeps the new copy's lines as the review read them, and that end runs
the same comparison for the count alone — the other file's view is the one
that draws it.

Each view then finds its own end again in what it draws (`apply`) — by name or
content in the buffer, which may be ahead of the disk — and rewrites its drawn
answer with it: `kind = "out"` takes the old copy out and leaves one line;
`kind = "in"` compares the new copy against the other file's old one, whose
lines are appended past the end of this file's (`drawn.old_lines`) so the
spliced hunks can point at them. Each end is a stop and a read mark in its own
file, and `<C-]>` lands on the end THAT file's view drew, not the index's
guess: the two files are compared separately and may place it a row apart.

### `collapsed_span` — `overlay.lua`

Where several old rows were folded onto one, draw the whole construct rather
than the two rows that vanished — a before-image with the `)` taken out of it
opens a bracket it never closes.

Only where the surviving row was **rewritten** by the fold. Byte for byte the
same and nothing was folded: the rows simply went, and they went *after* it. A
file whose whole body was deleted otherwise put every removed row above the one
line it had left — above the first line of the buffer, where there is nothing
to scroll to. The same past its indentation counts as the same: a row moved
sideways had nothing folded into it. Two nested `finally:` blocks merged into
one dedented the call under the inner one, and as a fold the outer `finally:`
that went was drawn above it together with the call's old self.

Nor where the row belongs to a hunk of its own. A fold leaves the row it went
into with nothing the backend calls changed, so no hunk claims it; a row that
is the last of a line-for-line rewrite was rewritten by that hunk, which already
draws its old version. A rewrite followed by two blank lines and a class header
taken out drew the rewrite's last old row a second time, above itself, with the
header.

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

A **blank** row has nothing to pick a removal out of, and is removed whole
unless it was measured and found to survive. A blank line inside a string is a
row of the string's atom, so difft has a span for it — zero columns wide — and
taken as source 3 it left the row in the dim band: a class removed whole came
back with every blank line of its docstring a stripe saying "this row stayed"
between rows that all went.

The added side has the mirror of it. A blank row of a prose node is part of the
node, and where the node was compared the blank row's comparison comes back
empty, which reads as "all of it stayed" and stepped the row back whole: a
docstring put in where a function had comments was green on every row but its
blank one. A blank row has no words to step back, and one still marked is not
the blank line it was (`quiet_unchanged` has taken the marks off one that is),
so it takes the band.

### `fitted` / `refit` — `overlay.lua`

Which row a before-image goes above is difft's alignment where the pair
resemble each other, and where they do not — a line inserted above a changed
one takes the changed line's partner — the hunk's own new rows are asked which
one the old line resembles. A row re-matched that way is re-measured against
it: the backend's spans were a comparison against a line it was never the old
version of, and they say the whole row went every time.

A line broken over several counts as resembling the piece it was anchored on:
`f(a=1, b=2)` reflowed as `f(` / `a=1, b=2` / `)` is anchored on `f(`, far too
short to resemble the old line, and re-matched to the argument row it drew
`f(` as lost. An anchored row difft put nothing on, whose trimmed text is still
inside the old line, is left where difft put it (`split_from`).

And wherever the before-image lands, it is drawn above where the old line now
*begins*: if the row above its partner is in the hunk, has no partner but this
line, and is how the old line starts, it goes above that, as far up as that
holds. A one-line docstring opened onto three rows is anchored on the opening
`"""`, but the row carries the changed atom's marks so `split_from` does not
keep it there, and the re-fit moves it onto the sentence it resembles more — the
old line hung between the two, the `"""` dim and alone above it. A sentence
broken in two that difft anchored on the second half did the same.

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

A removal that would hang below a row another hunk changed goes ABOVE that
row when that hunk drew no before-image at all. The rows between them are
old-side only, so on screen the two are adjacent and one went where the other
came. A dict reflowed onto one line left the rows under it paired by position,
the reworded comment below against a row of the old dict that survived in the
one-liner: nothing was drawn above the comment, and the comment it replaced
hung below it. A hunk that did draw a before-image -- a block above its first
row -- has answered its rows, and a removal after it stays below.

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
