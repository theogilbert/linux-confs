-- The defaults, and the documentation for them. Every key, width and
-- tunable is read from here rather than written inline at its use site,
-- so there is one place to look up what a setting does and one place a
-- user's own value has to reach.
--
-- `require("uatis").setup(opts)` folds that value in here, at whatever
-- depth it was named. It writes INTO this table rather than replacing it:
-- every module took its reference at require time, so a fresh table would
-- be read by nobody. Nothing else in the plugin writes to it.

return {
  list = {
    -- Left pane width. The by-commit header wraps to as many lines as it
    -- needs at this width -- that is why the header lives in this pane and
    -- not in the code pane's winbar, which is a statusline expression and
    -- is strictly one line.
    width = 38,
    -- The twisty on a directory row. A collapsed directory is the only
    -- row in the pane that hides something, so it is the one row that has
    -- to say so -- and it says it in the same column whether open or
    -- shut, because a marker that changes width makes the tree wander
    -- as you fold it.
    fold = { open = "▾", closed = "▸" },
  },

  base = {
    -- Tried in order when the repository has no `origin/HEAD` to read a
    -- default branch off -- a repo that was `git init`ed rather than
    -- cloned, which is most of them on a laptop. First one that exists
    -- wins; asking the user is the last resort, not the first move.
    --
    -- The same list is what `<leader>gB` offers, minus the ones this
    -- repository does not have. A picker is for the answer you almost
    -- always want, and in a repo with a hundred branches or tags a list
    -- of all of them is one nobody reads; `:Uatis <ref>` takes anything
    -- else, on the command line, where there is real ref completion.
    fallbacks = { "develop", "master", "main" },

    -- How many recent commits the `type a revision...` prompt completes
    -- over, newest first across every ref. A base is usually a branch or
    -- a tag, and when it is neither it is a commit somebody named -- the
    -- one before a refactor landed, the one raised in review, which on a
    -- busy repository is a long way down. Far enough back to still have
    -- it: the list is never read end to end, it is typed at, and only a
    -- slice of it is on screen before anything is typed. One `git log`
    -- when the prompt opens, then matching is a table scan. 0 leaves
    -- commits out.
    prompt_commits = 1000,

    -- Whether a base chosen by hand outlives the editor. `true` keeps
    -- one line per repository in `stdpath("state")/uatis/base.json`; a
    -- string keeps them in that file instead; `false` forgets at exit.
    --
    -- `state` rather than `data`: the file is per-machine, since every
    -- key in it is an absolute path, and losing it costs one
    -- `<leader>gB` per repository. That is what the XDG distinction is
    -- for, and where Neovim keeps its own shada and undo history.
    --
    -- On, because choosing a base is a fact about the project and not
    -- about this hour: a repository whose default branch is `develop`,
    -- or whose review is always against a release tag, is that way
    -- tomorrow too, and being asked again every morning is the plugin
    -- forgetting something the reader has already told it. Only a
    -- CHOICE is kept -- what was merely detected is detected again,
    -- since that answer can change without anyone deciding anything.
    remember = true,
  },

  keys = {
    -- Set anywhere, for the two things you do before there is anything to
    -- press a buffer-local key in: choosing what to compare against, and
    -- turning the comparison on. Set an entry to false to bind it
    -- yourself; the Lua functions behind them are the real interface.
    global = {
      base_branch = "<leader>gB",
      -- `u` for uatis, and deliberately not a verb: `<leader>g` is a
      -- crowded namespace in most configs -- `gs` stages, `gr` resets,
      -- `gd` diffs, `gb` blames -- and a key named after the tool is the
      -- one that cannot collide in meaning with a hunk operation.
      toggle_diff = "<leader>gu",
      -- No GLOBAL mapping for the side pane: it only does anything once
      -- a comparison is open, so its key lives in the view instead --
      -- `keys.view.files`. This is here for anyone who wants it on a
      -- global key anyway; it opens, where the view's key toggles. The
      -- toggle is `require("uatis").toggle_pane()`.
      open_pane = false,
      -- One commit, in a tab of its own -- `:UatisShow`, which with no
      -- argument asks which commit through the same prompt the base
      -- branch is typed into.
      --
      -- The capital of the key that reads YOUR branch a commit at a
      -- time, because it is the same gesture one size up: `<leader>gh`
      -- steps the commits you wrote since you forked, `<leader>gA` is
      -- any commit in the repository, on its own. Global rather than in
      -- the view, since somebody else's commit is something you look up
      -- from wherever you happen to be standing.
      show_commit = "<leader>gA",
      -- The same prompt, the other question: `<leader>gA` asks what one
      -- commit DID, against its parent; this asks what has changed
      -- SINCE one, against the buffers you are editing -- `:Uatis
      -- <rev>` without typing the rev. Pinned to what you pick, since
      -- naming a revision by hand is saying you meant that one.
      --
      -- Beside its neighbour on the shift of a free key: `<leader>gs`
      -- stages a hunk in most configs, and the capital is the review
      -- one size up from a hunk.
      since_commit = "<leader>gS",
    },
    -- The side pane: files changed since the fork point, beside the file
    -- you are reading. The same keys the view lends out -- ]f/[f -- so
    -- that moving between changed files is one gesture wherever you
    -- happen to be standing.
    pane = {
      file_next = "]f",
      file_prev = "[f",
      select = "<CR>",
      refresh = "R",
      focus_code = "<C-t>l",
      quit = "q",
      -- Folding a directory away, on the keys that fold anything else:
      -- the toggle and the pair that say which way. On a directory row
      -- they act on that directory; on a file row, on the directory the
      -- file is in, which is what they mean over a line inside a fold.
      -- `zc` over a directory already shut closes its parent, so it
      -- walks out of a tree the way it does everywhere else. `<CR>` on a
      -- directory row toggles too, since there is nothing else for "open
      -- this row" to mean there.
      fold = "za",
      fold_close = "zc",
      fold_open = "zo",
      -- ...and the whole tree at once, which on a branch that touched
      -- forty files is the first thing you reach for: shut, the list is
      -- the directories that changed, and you open your way in.
      fold_close_all = "zM",
      fold_open_all = "zR",
      -- The view's own key for the list, bound in here too, because it
      -- is a toggle and opening the list moves the cursor into it: the
      -- second press has to be answered by the window it is asking to
      -- close. Same key, same meaning as `q` -- this window is in my
      -- way -- so changing `keys.view.files` alone leaves the toggle
      -- half-bound.
      files = "<leader>gf",
      -- The same stepping keys the view binds, for the same reason `]f`
      -- is in both: which commit the review is showing is about the
      -- review, and which window the reader happens to be in is not
      -- part of it.
      commit_prev = "[C",
      commit_next = "]C",
      -- ...and a bare letter for the toggle, which only a list can
      -- afford: `C` in a scratch buffer of rows has nothing to change,
      -- while in the file beside it that keystroke is `c$` and cannot
      -- be taken. It reads as the capital of the two keys next to it --
      -- `C` to look at commits, `]C`/`[C` to move between them -- and
      -- the file's own way in stays `keys.view.commit_view`.
      commit_view = "C",
    },
    -- The diff view: a real file buffer of your own, annotated where it
    -- stands. `]c`/`[c` and `]f`/`[f` are what they already mean in a
    -- diff, so they carry over; everything else is a leader chord, and
    -- `q` deliberately does NOT carry over -- it has to stay macro
    -- recording. All of them are saved and put back on exit.
    view = {
      hunk_next = "]c",
      hunk_prev = "[c",
      -- Two keys, not three. `<leader>gdm` was the obvious name and the
      -- wrong shape: anyone with `<leader>gd` bound -- most people, it
      -- is the usual diff chord -- sits through `timeoutlen` every time
      -- they press it in a reviewed buffer, waiting to see whether an
      -- `m` is coming. A leader chord this plugin owns must not be a
      -- prefix of, or prefixed by, one the user already has.
      diff_mode = "<leader>gm",
      -- The changed-file list, beside the file you are reading. Bound
      -- here rather than globally because it only means anything once a
      -- comparison is open: pressed in the view it has a revision to
      -- list against, and pressed anywhere else it would have nothing to
      -- say. A toggle -- the window, not the review -- so it is also
      -- bound inside the list itself, as `keys.pane.files`.
      files = "<leader>gf",
      -- Reading the review one commit at a time. `<leader>gh` turns
      -- that on and off -- on, the review is a single commit, its own
      -- files measured against the commit before it; off, it is the
      -- whole branch against the working tree, which is what a review
      -- is the rest of the time.
      --
      -- `h` for history, which is what a branch read one commit at a
      -- time is, and typed by the right hand: `<leader>g` is a
      -- left-index roll, and a chord that asks that finger for the next
      -- key too is one nobody presses twice. `c` for commit was the
      -- obvious letter and is a left-index key for anyone who types it
      -- that way; `l` for log is lazygit's in most configs.
      --
      -- `[C`/`]C` move WITHIN it, and say how to get in when it is off:
      -- a mode has to be entered by something that means "enter", or
      -- the reader who presses a navigation key once finds themselves
      -- somewhere they did not ask to be.
      --
      -- Capitals of the chunk keys, because it is the same gesture one
      -- size up: `]c` is the next change in this file, `]C` the next
      -- commit of the branch.
      commit_view = "<leader>gh",
      commit_prev = "[C",
      commit_next = "]C",
      -- ...and stepping through that list without leaving the file you
      -- are reading. The same keys the pane itself uses, because they
      -- mean the same thing in both places -- moving between changed
      -- files is one activity, and which window you happen to be in is
      -- not part of it.
      file_next = "]f",
      file_prev = "[f",
      -- The same comparison drawn two ways: the old side around your
      -- buffer, or beside it in a window of its own -- `o` for the old
      -- side, which is what the second window holds.
      --
      -- Not `gs`: that is the stage-hunk key in every git plugin people
      -- already have, and the reason the toggle above is named after the
      -- tool applies here too. Not `gv` either -- `<leader>g` is already
      -- rolled with the left index finger, and a chord that asks it for
      -- both keys in a row is one nobody presses twice.
      layout = "<leader>go",
      -- Ending the review from inside it. Off, because the review is a
      -- toggle and `keys.global.toggle_diff` already ends it from
      -- anywhere, including from here -- a second key for one gesture is
      -- a second key to remember and a chord taken out of the user's own
      -- namespace for nothing. Set it to a string to have one; the
      -- winbar names whichever key is actually the way out.
      quit = false,
    },
    -- The old revision's window, the left half of side by side. A
    -- scratch buffer of ours, so `q` is free here in a way it is not in
    -- the buffer you are working in: there is no macro to record in a
    -- read-only copy of a revision.
    old = {
      quit = "q",
      jump = "<CR>",
    },
  },

  -- The changed-file list. It is read whenever a comparison is turned on,
  -- window or no window, because it is what a review is made of rather
  -- than a view onto one: which files the branch touched, the revision
  -- they are measured against, what `]f` steps through, and what decides
  -- whether the file you just opened gets annotated.
  pane = {
    -- Whether turning the diff view on puts that list up beside it. On,
    -- because "what have I changed" is a question about the branch and not
    -- about one file -- and the answer to "which file next" should be on
    -- screen before you ask it. Off leaves the window to `keys.view.files`
    -- and changes nothing else.
    auto_open = true,

    -- Files git has never been told about are part of what a branch did
    -- -- `git diff` cannot say so, because there is no revision to
    -- measure them against, so they are asked for separately and counted
    -- here. Above this many bytes a file is listed without a count
    -- rather than read to find one: nobody reviews a 2MB blob by its
    -- line total, and the read is on every re-read of the list. 0 leaves
    -- untracked files out of the list altogether.
    untracked_max_bytes = 512 * 1024,

    -- Whether the comparison follows you: a file the list names, opened
    -- while a review is running, is annotated on arrival however you got
    -- there -- `]f`, a jump to definition, a picker, `:e`.
    --
    -- On, because reviewing a branch is a mode and not a property of one
    -- buffer. Off, each file is annotated only when you ask for it with
    -- `<leader>gu`, and the review is whatever you have turned on by hand.
    follow = true,

    -- Whether `]c` off the last chunk of a file carries on into the next
    -- file the list names, and `[c` off the first one back into the
    -- previous.
    --
    -- On, for the same reason the list exists: the unit being read is a
    -- branch, not a buffer, and "the next change" has an answer past the
    -- end of this file. Stopping there left the reader pressing `]f` and
    -- then `]c` to reach a change the review could have gone to itself
    -- -- and `]f` alone lands at the top of a file rather than on
    -- anything that changed in it.
    --
    -- Off restores the motion: `]c` stays inside the buffer and stops at
    -- its ends. `]f`/`[f` are unaffected either way -- they are still
    -- how you move a whole file at a time without reading what is in it.
    chunk_spill = true,
  },

  -- One commit on its own: `:UatisShow [<rev>]`.
  show = {
    -- Whether that opens a tab of its own. On, because a review is a
    -- mode over a tab -- one list per tabpage -- so showing a commit
    -- where the reader is standing would take the review they already
    -- had, and looking up what somebody else did is usually a detour
    -- from work you mean to come back to. Off shows it in place, and
    -- then it does end whatever review that tab was holding.
    tab = true,
  },

  diff = {
    -- Which engine a view starts in. Both are reachable at any time with
    -- <leader>gm, so this is where you begin rather than what you are
    -- stuck with.
    --
    -- Structural by default because it answers the question a reviewer is
    -- actually asking: a line diff cannot tell reindentation from a
    -- rewrite, so a branch that moved code -- into a class, out of a
    -- conditional, across a reflow -- reads as though all of it were new.
    default_backend = "struct",

    -- difftastic, and nothing else. Without it installed there is no
    -- structural diff to be had here: an imitation would leave the reader
    -- unable to tell which of the two they were reading, so the answer is
    -- the line diff and the header says so.
    struct = {
      bin = "difft",
    },

    -- `vim.diff`, the line diff Neovim already has, refined a little.
    -- None of this touches structural mode, where what difftastic says is
    -- what is drawn.
    line = {
      -- Which minimal edit script to pick. Both this and git's default
      -- (`myers`) are minimal; they differ in which of the many equally
      -- short answers they choose, and Myers chooses badly on a
      -- restructured file -- a test file whose functions moved into a
      -- class comes back as ONE hunk over the whole body, so a one-word
      -- change to an import three lines above is drawn as part of a
      -- wholesale replacement. Histogram isolates it.
      --
      -- "myers" matches what a forge shows by default; "patience" and
      -- "minimal" are the other two vim.diff knows.
      algorithm = "histogram",

      -- How alike a replaced word has to be (0..1) before it is worth
      -- diffing character by character. Below this it is marked whole:
      -- character marks between unrelated words land on whichever letters
      -- they happen to share and point at nothing.
      word_similarity = 0.5,

      -- ...and how much of a stem they have to share, at the front or the
      -- back, before that character diff is drawn. Similarity alone let
      -- `closer` -> `whose` through: they share `ose` in the MIDDLE, so
      -- the marks came out as `cl`/`r` against `wh` -- fragments of two
      -- different words. A shared prefix or suffix is something the eye
      -- can anchor on; letters shared only in the middle are a
      -- coincidence of spelling. Below this, both words are marked whole.
      word_affix = 2,

      -- How many candidate pairs a hunk may be re-matched over when the
    -- backend's own row pairing does not fit -- a line inserted above a
    -- changed one takes the changed line's partner, and the removed row
    -- is then drawn above a line it has nothing to do with.
    --
    -- Bounded because the answer is measured: an edit distance per pair,
    -- old rows times new rows. Past a handful either way it is not the
    -- case this exists for -- a block that size is a substitution, where
    -- the alignment is an order rather than a correspondence and "these
    -- lines became those" is the whole of what there is to say -- so the
    -- cheap answer and the right one agree.
    refit_pairs = 64,

      -- How many removed rows a hunk may draw before they stop being
      -- spread over the new side and go back into one block above it.
      --
      -- A removed row drawn directly above the row it became gives the
      -- reader a comparison they can check without looking anywhere
      -- else. A whole passage drawn that way gives them stripes
      -- instead: every line of the old code with a line of the new code
      -- between it and the next, so the block that was there cannot be
      -- read back AS code, which is what a before-image exists to show.
      -- Two or three rows are lines you check; more than that is a
      -- passage you read.
      --
      -- Counted over the rows that actually get one, so a long hunk
      -- most of whose old rows are already on screen -- unchanged, or
      -- carried into the line below -- still spreads the few that are
      -- not.
      spread_max = 3,

    -- How many lines either side of a hunk count as "still on screen"
      -- when deciding whether an edit removed code or merely moved it --
      -- but not so far that a genuinely deleted line is excused by
      -- similar code elsewhere.
      survives_context = 4,


      -- How much of a line the marks have to cover before the line stops
      -- being a line with marks on it and becomes a rewritten line, drawn
      -- as one band. Deliberately close to all of it: a single surviving
      -- word is something the reader recognises and navigates by, and
      -- taking the marks away to say "this line is new" throws that away.
      --
      -- A line where nothing but punctuation survived is over the line
      -- whatever this says: `var = func(foo, bar)` rewritten to a
      -- different call with different arguments keeps its brackets, its
      -- comma and its `=`, and marking around them leaves green wrapped
      -- round islands of punctuation that read as "unchanged" -- true of
      -- the character, false of the line.
      major_ratio = 0.85,

      -- ...and how much of a changed PROSE atom the new words have to
      -- cover before the emphasis stops being worth drawing.
      --
      -- The step-back says "changed, but not the part that is new",
      -- which is a sentence with two halves, and the second half has to
      -- be a half. Past this the atom is a new one: what is left is
      -- whatever the old block happened to contain -- a backtick, a
      -- hyphen, a common word -- matched because the character was
      -- somewhere in it and not because anything survived. A README
      -- paragraph rewritten from `pip install grannos-py` came back
      -- with `install` greyed in the middle of a new sentence, and the
      -- reader goes looking for the old line it answers to. That hunt
      -- is what a patch charges and what this plugin is for not
      -- charging.
      --
      -- A majority, and not the 0.85 above, because the two decisions
      -- are different. That one is about taking marks AWAY from a line
      -- the reader could still navigate by, so it is nearly all of it;
      -- this one is about whether a comparison is being offered at all,
      -- and half a sentence rewritten is a sentence rewritten.
      --
      -- Higher narrows more: at 1.0 every atom with one surviving
      -- character keeps its step-back. Lower narrows less; at 0 nothing
      -- is ever stepped back and a changed string is one flat tint.
      emphasis_ratio = 0.5,
    },

    -- How big a replacement run the intra-line comparison will pair up
    -- token by token: this many old tokens against this many new ones,
    -- squared, as a budget spent across the whole block. That scoring is
    -- the quadratic part; the token diff around it is linear, so a long
    -- block whose edits are small still gets the fine answer and only a
    -- wholesale rewrite falls back to marking tokens whole. It serves
    -- both engines: line mode marks with it, and structural mode picks
    -- the novel words inside a changed string out of it.
    inline_token_limit = 400,

    -- ...and how many tokens a whole block may hold before it is not
    -- compared at all. That pass is linear, which is why it went
    -- unnoticed for a long time: tokenizing a hunk and pushing a range
    -- per token costs nothing until the hunk is a rewritten file, where
    -- it is most of a second spent on the main loop to produce marks
    -- that cover every line and are drawn as a band regardless. About
    -- fifteen hundred lines of ordinary code, well past any hunk a
    -- reader reads token by token.
    inline_block_limit = 20000,
  },

  highlight = {
    -- The tints are the colourscheme's own diff colours, deepened: the
    -- same hue, saturated to at least this, sitting `lightness` away from
    -- the editor's background in whichever direction the scheme already
    -- put them -- so a dark theme's tints stay dark and a light theme's
    -- stay light.
    --
    -- Deepened rather than brightened, and separately from the lightness,
    -- because those are different things. Some schemes make the diff
    -- groups very quiet -- habamax's `DiffAdd` is `#273923` against a
    -- `#1c1c1c` background, 24% saturation, easy to miss on a line you
    -- are skimming -- and scaling that away from the background in RGB
    -- moves every channel at once, which turns a quiet green into a pale
    -- one rather than a deep one.
    --
    -- A floor and not a target: it is there to rescue a scheme whose diff
    -- colours are too quiet to see, not to make every scheme's loud. Kept
    -- low enough that what it produces still reads as a tint under code
    -- -- a saturated block behind a line of syntax-coloured text is a
    -- highlighter pen drawn over it, and the code is what the reader came
    -- for.
    saturation = 0.4,

    -- ...and how far each sits from the background in lightness. Two
    -- numbers, because the two sides are read differently: the added tint
    -- lies under code you are reading line after line and wants to stay
    -- out of the way, while the removed tint is under text that is not
    -- in your file at all -- a before-image, or the window beside it --
    -- where being a shade lighter reads as "look here, this is gone"
    -- rather than as noise under something you are trying to read.
    add_lightness = 0.05,
    delete_lightness = 0.11,

    -- ...or the two removal backgrounds outright, as `0xrrggbb`, for a
    -- reader who would rather name them than tune the derivation.
    -- `delete_bg` is under the words that went, `delete_dim_bg` under
    -- the rest of the line they were taken out of; `nil` derives both
    -- from `DiffDelete` as described above. Nothing else in this table
    -- is a colour: these are here because a scheme's `DiffDelete` is a
    -- weaker source than its `DiffAdd` -- often a foreground alone --
    -- and taste about how loud a removal should be varies more than the
    -- rest of the palette does.
    delete_bg = nil,
    delete_dim_bg = nil,

    -- The ceiling for a tint read out of a FOREGROUND, which is how a
    -- removal is coloured by a scheme that leaves `DiffDelete` without a
    -- background. `saturation` above is a floor because a diff
    -- background arrives muted; a foreground arrives the other way up --
    -- it was picked to be legible ON the background, and every pale tint
    -- reads as fully saturated in HSL -- so the same number applied to
    -- one makes a red that shouts. This is where a background of that
    -- hue would have been if the scheme had written one.
    foreground_saturation = 0.25,

    -- The emphasis: the part of a banded line that is the actual edit,
    -- where the backend only knows lines and the band only means "this
    -- line changed". Further along both axes, so the two read as one
    -- colour at two strengths rather than as two colours.
    --
    -- Not much further, though. This is a background under code, and a
    -- vivid one stops being a tint and becomes a marker pen: the eye
    -- reads the block instead of the words in it, which is the failure
    -- this whole file is written to avoid. The separation it needs is
    -- from the tint beside it, not from the buffer -- and against a
    -- step-back that has had its colour taken out, a soft green at a
    -- different lightness is already unmistakable.
    emphasis_saturation = 0.48,
    emphasis_lightness = 0.09,

    -- The other direction, for a changed prose atom -- a docstring, a
    -- comment, a long literal -- where difftastic calls every word
    -- changed and only some of them are the edit. The words that are new
    -- keep the ordinary tint and the sentence around them steps back to
    -- this, which is the same hue with almost none of the colour left in
    -- it: a grey that remembers it was green.
    --
    -- Back rather than forward because the strongest colour on screen
    -- should always mean the same thing. Emphasising instead would make
    -- a reworded comment louder than the changed code beside it, which
    -- is the wrong way round.
    --
    -- Greyed rather than darkened, which is what it used to be. The pair
    -- is read ACROSS a line -- `["VARCHAR2"]` becoming `["VARCHAR2(50)"]`
    -- puts the step-back and the tint a few columns apart -- and a mix
    -- towards the editor's background moves every channel together, so
    -- what comes out is the tint at lower contrast: a darker green under
    -- a green, one shade with a seam in it, however far the mix is
    -- taken. Dropping the saturation instead separates them by the thing
    -- the eye is being asked about, and it is what the removed side has
    -- always done -- its dim is the scheme's own `DiffDelete`
    -- background, a muted grey-red, with the band that colour deepened.
    --
    -- A CAP, unlike `saturation` above, which is a floor: this is the
    -- one group here meant to be quiet, so a scheme whose `DiffAdd` is
    -- already grey-green keeps its own answer and only a vivid one is
    -- brought down.
    dim_saturation = 0.12,

    -- ...and how far it sits from the editor's background, in the
    -- direction the scheme already put its diff colours.
    --
    -- Its own number rather than `add_lightness`, and a longer one: the
    -- two are told apart by colour, so the one with the colour taken out
    -- of it needs the other axis to be seen at all -- at the tint's own
    -- lightness a grey-green is a shade off the buffer and reads as
    -- nothing. Past the tint AND past the emphasis, which is the same
    -- way round the removed side has always had it: a pale ground with
    -- the words that went drawn on it in a deeper colour.
    --
    -- Only just past them, though. This is the half of a changed line
    -- the reader is meant to skim, and taken far enough to be plainly
    -- pale it becomes the brightest thing on the row -- the eye lands on
    -- the context before it lands on the edit, which is the wrong way
    -- round and the reason the number is not simply "as light as it
    -- reads clearly".
    dim_lightness = 0.18,

    -- ...or that colour outright, as `0xrrggbb`, for a reader who would
    -- rather name it than tune the derivation -- the same escape the two
    -- removal backgrounds have, and for the same reason: how loud the
    -- quiet half of a changed line should be is taste, and it varies
    -- more than the rest of the palette does. `nil` derives it as above.
    add_dim_bg = nil,

    -- The same step back on the removed side, which is a shorter one.
    --
    -- Both dims mean "part of what the backend called changed, but not
    -- the part that IS the change", and the number is different because
    -- of where each one lands. The added dim is a band on a real line
    -- with more of the same tint above and below it, and it has to stay
    -- clear of the tint to say anything. The removed dim is the ground
    -- of a virtual row -- the whole width of it, since the before-image
    -- is padded to the window edge -- sitting between two lines of the
    -- reader's own file. There is nothing beside it to be mistaken for,
    -- so it can be much quieter and still be read as a colour, and at
    -- the added dim's distance a replaced line is the loudest thing on
    -- the screen.
    --
    -- Reached only where the scheme wrote no `DiffDelete` background for
    -- the ground to be taken from directly, so this is aiming at where
    -- that background would have been rather than at a step back from
    -- the tint. It is measured against the GUTTER of the same row --
    -- `UatisSign`, which is the editor's own surface in exactly the case
    -- that gets here -- since that is the nearest thing on the line to
    -- be a shade off.
    delete_dim_contrast = 0.15,

    -- How far the winbar's key hints are mixed from the bar's own
    -- background towards the editor's foreground. They are hints, so they
    -- should sit behind the text beside them -- but `NonText`, which is
    -- what they used to borrow, is meant for the parts of the screen that
    -- are not text at all and can be near-invisible on a bar.
    hint_contrast = 0.75,

    -- The churn counts in a winbar take the diff hues as FOREGROUNDS: a
    -- background the width of `+12` in a one-line bar reads as a smudge.
    -- Light enough to read on the bar, which is the opposite of what the
    -- tints want -- hence its own numbers.
    signal_saturation = 0.6,
    signal_lightness = 0.62,      -- on a dark bar
    signal_lightness_dark = 0.34, -- ...and on a light one
  },

  -- Removed code is drawn as virtual text, which neither the syntax
  -- engine nor the tree-sitter highlighter touches: both run over real
  -- buffer lines. The old side is parsed on its own instead, so a
  -- before-image is coloured the same way the code below it is.
  syntax = {
    -- Above this, the before-image keeps one flat colour. Parsing the old
    -- side of a generated or vendored file costs more than the colour is
    -- worth, and nobody is reading it closely anyway.
    max_bytes = 1024 * 1024,
  },

  -- Deleted-line marker, drawn in the gutter (left of the number column)
  -- rather than prefixed onto the text: a "- " prefix shifts the deleted
  -- code's visible indentation relative to real buffer lines, which makes
  -- indentation comparisons between the old and new side look wrong even
  -- when they aren't.
  marker = {
    delete = "-",
  },
}
