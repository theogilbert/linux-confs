-- Every default, in one table.
--
-- `init.setup(opts)` folds the user's table into this one IN PLACE, since
-- every module holds a reference to it from require time. Lists are
-- replaced whole rather than merged by index; unknown keys are warned
-- about.
--
-- Comments here say what a setting CONTROLS. Why a particular value was
-- chosen belongs next to the code that acts on it.

return {
  list = {
    -- Width of the changed-file window, in columns, when it opens. The
    -- rows follow the window from there, so resizing it redraws them.
    width = 38,
    -- The characters drawn at the head of an open and a shut directory row.
    fold = { open = "▾", closed = "▸" },
    -- Show how far through the review the current file is, on the status
    -- line under the list. Obeys `laststatus` like any other window's.
    progress = true,
  },

  base = {
    -- Branch names to try, in order, when `origin/HEAD` gives no answer.
    -- Also the short list `<leader>gB` offers, minus those this repo
    -- does not have.
    fallbacks = { "develop", "master", "main" },
    -- How many recent commits the revision prompt completes over.
    prompt_commits = 1000,
    -- Where a chosen base and subtree are kept between sessions. `true`
    -- for `stdpath("state")/uatis/base.json`, a string for that path,
    -- `false` to remember nothing.
    remember = true,
  },

  keys = {
    -- Set any mapping to `false` to bind it yourself. The Lua functions
    -- behind them are the real interface.
    global = {
      -- What am I reviewing: base and subtree, in one panel.
      base_branch = "<leader>gB",
      -- Start or end a review of the branch.
      toggle_diff = "<leader>gu",
      -- Open the changed-file list. Off by default; the view binds
      -- `keys.view.files`, which toggles.
      open_pane = false,
      -- One commit against its parent, in a tab of its own.
      show_commit = "<leader>gA",
      -- Everything since a revision you pick, in your own buffers.
      since_commit = "<leader>gS",
    },
    -- Inside the changed-file list.
    pane = {
      file_next = "]f",
      file_prev = "[f",
      -- Open the file on the current row.
      select = "<CR>",
      -- Mark the file on the current row read, or a directory row and
      -- everything under it. A bare letter, so it is bound in the list
      -- only.
      mark_read = "x",
      -- Re-read the list from git.
      refresh = "R",
      -- Jump to the window the file is open in.
      focus_code = "<C-t>l",
      -- Hide the window; the review stays on.
      quit = "q",
      fold = "za",
      fold_close = "zc",
      fold_open = "zo",
      fold_close_all = "zM",
      fold_open_all = "zR",
      -- Hide the window, from inside it.
      files = "<leader>gf",
      -- Move within the commit on show.
      commit_prev = "[C",
      commit_next = "]C",
      -- Put one commit on show, or take it off. A bare letter, so it is
      -- bound in the list only.
      commit_view = "C",
      -- Read the whole message of the commit on show -- subject and
      -- body -- in a float. `K` because that is already "tell me more
      -- about this" everywhere else in the editor.
      commit_message = "K",
      -- Every key that does anything from here, in a float. `g?` is
      -- vim's own spelling of "explain this".
      help = "g?",
    },
    -- Inside a file being reviewed.
    view = {
      hunk_next = "]c",
      hunk_prev = "[c",
      -- Switch between the structural and line backends.
      diff_mode = "<leader>gm",
      -- Toggle the changed-file list.
      files = "<leader>gf",
      -- Read the branch one commit at a time.
      commit_view = "<leader>gh",
      commit_prev = "[C",
      commit_next = "]C",
      file_next = "]f",
      file_prev = "[f",
      -- Inline, or the old side in a window of its own.
      layout = "<leader>go",
      -- End the review from inside it. Off by default;
      -- `keys.global.toggle_diff` already does it from anywhere.
      quit = false,
    },
    -- Inside the side-by-side old-revision window.
    old = {
      quit = "q",
      -- Jump to the matching row in the file.
      jump = "<CR>",
    },
  },

  pane = {
    -- Show the changed-file window when a review starts. The list is
    -- read either way; this only decides whether you see it.
    auto_open = true,
    -- Size cap for counting the lines of an untracked file. Over it, the
    -- file is listed with no count.
    untracked_max_bytes = 512 * 1024,
    -- Annotate any listed file as you arrive at it.
    follow = true,
    -- `]c` off the last chunk of a file steps into the next file in the
    -- list and lands on its first change.
    chunk_spill = true,
    -- ...and `]c` / `[c` mark the chunk they move away from read -- the
    -- first and last of a file too, by a press with nowhere left to go.
    auto_read = true,
    -- Where the read marks are kept between sessions. `true` for
    -- `stdpath("state")/uatis/read.json`, a string for that path,
    -- `false` to forget them with the session.
    remember_read = true,
  },

  show = {
    -- Open `<leader>gA` / `:UatisShow` in a new tab.
    tab = true,
  },

  diff = {
    -- Which backend a view starts in: "struct" or "line". Both are
    -- reachable at any time with `keys.view.diff_mode`.
    default_backend = "struct",

    struct = {
      -- The difftastic executable. Missing, every view is a line diff
      -- and the winbar says so.
      bin = "difft",
      -- difftastic's own ceilings, passed through as DFT_GRAPH_LIMIT and
      -- DFT_PARSE_ERROR_LIMIT; past either it compares words instead
      -- and the winbar says which. nil leaves difftastic's defaults.
      graph_limit = nil,
      parse_error_limit = nil,
    },

    -- `vim.diff` and the intra-line comparison built on it. None of this
    -- touches what difftastic reports in structural mode.
    line = {
      -- Which minimal edit script `vim.diff` produces: "histogram",
      -- "myers", "patience" or "minimal".
      algorithm = "histogram",
      -- How alike two replaced words must be (0..1) before they are
      -- compared character by character rather than marked whole.
      word_similarity = 0.5,
      -- ...and how many characters of stem they must share at the front
      -- or the back for that comparison to be drawn.
      word_affix = 2,
      -- Cap on the old-rows × new-rows pairs a hunk may be re-matched
      -- over when the backend's row pairing does not fit.
      refit_pairs = 64,
      -- How many removed rows a hunk may draw one-above-the-row-they-
      -- became before they go into a single block above the hunk
      -- instead. Counted over the rows that actually get drawn.
      spread_max = 3,
      -- How many lines either side of a hunk count as "still on screen"
      -- when deciding whether code was removed or only moved.
      survives_context = 4,
      -- How much of a line the marks must cover (0..1) before it is
      -- treated as rewritten and drawn as one band.
      major_ratio = 0.85,
      -- How much of a changed prose atom the new words must cover
      -- (0..1) before the step-back is dropped and the atom is drawn at
      -- one flat tint. Higher keeps the step-back on more atoms; 0
      -- never steps anything back. Not consulted at all where nothing
      -- was removed from the row: the old text is then all there, and
      -- the step-back cannot be pointing at a coincidence.
      emphasis_ratio = 0.5,
    },

    -- Mark the leading whitespace a line gained when a block was
    -- reindented around it -- wrapping a body in a guard, say. The code
    -- on the line is left alone; only the new columns at its front are
    -- marked. Structural backend only.
    indent_marks = true,

    -- Cap on the old-tokens × new-tokens budget the intra-line
    -- comparison will pair a replacement run over. Past it, tokens are
    -- marked whole. Read by both backends.
    inline_token_limit = 400,
    -- Cap on the tokens in a block before it is not compared at all.
    inline_block_limit = 20000,
  },

  highlight = {
    -- The tints are derived from the colourscheme's own `DiffAdd` and
    -- `DiffDelete`: their hue is kept, their saturation floored or
    -- capped, and their lightness set this far from the editor's
    -- background in whichever direction the scheme already put them.
    -- Backgrounds only over real code, so syntax colouring survives.

    -- Saturation floor for the tint on a changed line.
    saturation = 0.6,
    -- How far that tint sits from the editor's background, in lightness.
    add_lightness = 0.10,
    -- The same, for a removed line.
    delete_lightness = 0.15,

    -- The two removal backgrounds named outright, as `0xrrggbb`. Set,
    -- each replaces the derivation above it. `delete_bg` is under the
    -- words that went; `delete_dim_bg` under the rest of the row.
    delete_bg = nil,
    delete_dim_bg = nil,

    -- Saturation CAP for a removal colour taken from a foreground,
    -- reached only where the scheme wrote no `DiffDelete` background.
    foreground_saturation = 0.25,

    -- The step-back: the half of a changed prose atom that is not the
    -- edit. Saturation cap, then how far it sits from the background.
    dim_saturation = 0,
    dim_lightness = 0,
    -- ...or that colour named outright, as `0xrrggbb`.
    add_dim_bg = nil,

    -- The step-back on the removal side, as a contrast from the row's
    -- own gutter. Reached only where the scheme wrote no `DiffDelete`
    -- background and `delete_dim_bg` is unset.
    delete_dim_contrast = 0.15,

    -- How far the winbar's key hints are mixed from the bar's
    -- background towards the editor's foreground.
    hint_contrast = 0.75,

    -- The `+12 -3` counts in a winbar are drawn as foregrounds, so they
    -- take their own numbers rather than the tints'.
    signal_saturation = 0.75,
    signal_lightness = 0.55,      -- on a dark bar
    signal_lightness_dark = 0.55, -- ...and on a light one

    -- How far a read row steps back from the `+N` green towards the
    -- list's background: 0 is that green, 1 is gone.
    read_recede = 0.4,
  },

  syntax = {
    -- Above this, the old side is not parsed and the before-image keeps
    -- one flat colour.
    max_bytes = 1024 * 1024,
  },

  marker = {
    -- Drawn in the gutter of a removed row, left of the number column.
    delete = "-",
  },
}
