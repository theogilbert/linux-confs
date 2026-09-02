-- One table, hardcoded, read from here rather than written inline at its
-- use site -- so adding a real config layer later is "make this table
-- overridable" instead of "find every hardcoded string across nine
-- modules".

return {
  -- Which merge requests the list asks for. A reviewer wants the ones
  -- that are open and not yet merged; everything else is history.
  list = {
    per_page = 30,
    -- "opened" | "merged" | "closed" | "all". What a queue *opens* on:
    -- `s` in the window walks the four, for the merged one you are
    -- reading to find out how something came to be done that way.
    state = "opened",
    -- Passed to `glab mr list --order`. Recently touched first is the
    -- order a review queue is actually worked in.
    order = "updated_at",
    -- The floating window, as a fraction of the editor.
    width = 0.7,
    height = 0.6,

    -- Whether the rows say what CI made of each merge request.
    --
    -- On, and it costs one API call per open row: GitLab's merge
    -- request list carries no pipeline, so the only way to fill that
    -- column is to ask per merge request. The calls go out together
    -- and each row is redrawn as its answer lands, so the list is
    -- usable throughout -- but on a slow forge, or a queue of thirty,
    -- this is the switch.
    ci = true,

    -- Whether the rows say how far each merge request has got through
    -- its approvals.
    --
    -- On, and it costs one API call per open row: GitLab's list
    -- carries no approvals either. The glyph and the count only -- who
    -- has been in is `<leader>md`, or the pane under the list.
    approvals = true,

    -- Whether the rows say how many comments you have written on each
    -- merge request and not sent.
    --
    -- On, and it costs a second call per row: a draft note is yours
    -- and GitLab puts it in no list payload. Worth it, because of
    -- where an unsent comment lives -- on the forge, not in this
    -- editor. It is still there tomorrow, and on a machine you are not
    -- sitting at, and this queue is the only place you would ever be
    -- told about it.
    drafts = true,

    -- How many of the per-row calls above are allowed to be in flight
    -- at once. Each is a process that starts, authenticates and opens
    -- its own connection: thirty together are slower end to end than
    -- six at a time, and take the machine down with them while they
    -- run. One number for both questions rather than one each, or a
    -- queue of thirty rows is twelve processes rather than six.
    concurrency = 6,

    -- Whether the rows say how much each merge request changes.
    --
    -- One call for the open rows, through GraphQL -- the only GraphQL
    -- in this plugin, and worth the exception: REST publishes no line
    -- totals anywhere, so the REST way to put "+120 −34" on thirty rows
    -- is to fetch thirty entire diffs. Off is one line, and a GitLab
    -- whose GraphQL will not answer leaves the column empty by itself.
    stats = true,

    -- Rows of the pane under the list -- the changelog, or the
    -- description, of whichever merge request the cursor is on. At most
    -- this many: the list stays where it is when the pane opens, and
    -- the pane takes the room under it, which on a short screen is less
    -- than this. The list gives up rows of its own first, from the
    -- bottom, so that its top edge -- and the row you were reading --
    -- does not move.
    preview_height = 14,
  },

  comments = {
    -- What sits in the gutter on a line that carries a thread. Two
    -- glyphs, because "there is a conversation here" and "there is an
    -- unanswered conversation here" are different facts and a reviewer
    -- navigates by the second one.
    --
    -- Nerd Font speech bubbles: filled for a thread still owed an
    -- answer, hollow for one that is settled. Filled and hollow rather
    -- than two different shapes -- the gutter is read at a glance and in
    -- the corner of the eye, where weight carries and detail does not.
    -- Without a Nerd Font these render as a box; "●" and "○" are the
    -- pair to fall back to.
    sign_open = "", -- nf-fa-comment
    sign_resolved = "", -- nf-fa-comment_o

    -- ...and a comment you have written and not sent yet. A pencil
    -- rather than a third bubble: an unsent comment is not a state of
    -- the conversation, it is a state of you. "✎" without a Nerd Font.
    sign_draft = "", -- nf-fa-pencil

    -- Whether a line with a thread also gets its first line of text at
    -- the end of the line. Off by default: the gutter says where to
    -- look, and the eye should not have to read a truncated sentence to
    -- decide whether to open it. Ignored while the conversations are
    -- expanded, where the note it summarises is the next line down.
    virt_text = false,

    -- Whether resolved threads are drawn at all. They are still fetched
    -- either way -- toggling this is a redraw, not a refetch.
    show_resolved = true,

    -- The left rail drawn down a thread, in place of a box around it.
    -- A box has to close, a closing rule has to know how wide the
    -- window is, and the same thread is drawn into the buffer, the peek
    -- float and the overall-notes window at three different widths.
    -- U+258E; "│" is the fallback for a font without it.
    rail = "▎",

    -- What a reply is indented by, in front of the rail's own space.
    -- A thread on a busy line is a conversation among conversations:
    -- without this, the second thread's opening note and the first
    -- thread's third reply are the same shape, and the only way to tell
    -- an answer from a new argument is to read both. Set it to "" to
    -- have every note start in the same column again.
    reply_indent = "  ",

    -- ...and what stands in that indent on the line a reply opens with.
    -- Indentation alone is a weak signal: it is two spaces, it is the
    -- same two spaces a wrapped line gets, and on a narrow float it is
    -- gone. The mark says outright that this note answers the one
    -- above. U+21B3; make it the same display width as `reply_indent`,
    -- or the author of a reply stops lining up with what they said.
    reply_mark = "↳ ",

    -- How far the ground under an expanded conversation stands off the
    -- page: 0 is the file's own background, 1 is the colour its text is
    -- drawn in. Lighter in a dark colourscheme, darker in a light one,
    -- and either way the same background rather than a colour from
    -- somewhere else.
    --
    -- Enough of it to win an argument it is in the middle of: a
    -- conversation is not the only thing painting backgrounds on these
    -- lines -- a diff plugin puts red and green ones on the code above
    -- and below -- and a ground a whisper away from the file's own
    -- reads as one more band of that. A settled conversation gets half
    -- as much, so that an argument still going on stands off the page
    -- and one that is over sinks back towards it. `false` for no band
    -- at all, where the rail and the dimming carry it alone.
    ground = 0.15,

    -- The widest a line of a comment is drawn, in columns.
    --
    -- Wrapping happens whatever this is set to -- a conversation is
    -- drawn as virtual lines, and virtual lines cannot be scrolled
    -- sideways, so a line past the edge of the window is a line that
    -- cannot be read at all. This is the *other* limit: prose set
    -- across the whole of a wide editor is prose the eye loses its
    -- place in on the way back to the next line. `false` to wrap to
    -- the window and nothing narrower.
    wrap = 80,

    -- Height cap on the peek float, in lines.
    peek_height = 20,
  },

  -- What a pipeline or a job's state is drawn as. One glyph per state,
  -- and the several GitLab words that mean the same thing share one:
  -- there are four spellings of "it has not started yet".
  --
  -- Text-presentation codepoints, on purpose. U+2714 HEAVY CHECK MARK
  -- -- which the tick used to be -- is in Unicode's emoji set, and a
  -- terminal with an emoji font will draw it from there: a picture, in
  -- that font's own colour, in place of a tick in the green this plugin
  -- asked for. U+2713 is the same shape with no emoji in it. Same for
  -- the cross (U+2717, not U+2716) and the triangle (U+25B8, not
  -- U+25B6). Nerd Font icons go here just as well.
  ci = {
    passed = "✓",
    failed = "✗",
    running = "◐",
    waiting = "◌",
    manual = "▸",
    canceled = "⊘",
    skipped = "⊙",
    -- A status this plugin has never heard of: drawn, with GitLab's own
    -- word beside it, rather than left out.
    unknown = "•",
  },

  compose = {
    -- Rows of the split you write a comment in. Small on purpose: a
    -- review comment is a paragraph, and a window the size of the file
    -- invites an essay.
    height = 10,

    -- Completion for the `@` in front of a name, from the people on
    -- this project. On `<C-x><C-o>` in the composer, and the list is
    -- fetched when the window opens so that the keystroke does not wait
    -- for a forge.
    mentions = true,

    -- ...and the menu on its own, as the `@` is typed.
    --
    -- Needs a Neovim that can hold `completeopt` for one buffer (0.11
    -- and newer): a menu that chooses for you is worse than no menu,
    -- and this plugin will not set a global option to get one. On an
    -- older Neovim the key above still completes.
    mention_menu = true,
  },

  keys = {
    -- Global, for the one thing you do before there is a session to
    -- have buffer-local keys in.
    global = {
      list = "<leader>ml",
    },
    -- Buffer-local, bound on every file buffer inside the repository
    -- once an MR is open, and taken away again when it is closed.
    -- What is bound out here is what acts on the line under the cursor.
    -- Everything else a review needs is a window, and the window it is
    -- in is `description` -- which is why that is the only one of these
    -- that opens one.
    session = {
      expand = "<leader>mx", -- the conversations themselves, under the lines
      peek = "<leader>mp", -- the thread under the cursor, in a float
      comment = "<leader>ma", -- a new thread on this line
      reply = "<leader>mr", -- a reply into the thread under the cursor
      resolve = "<leader>mR", -- resolve/unresolve the thread under the cursor
      edit = "<leader>me", -- rewrite a comment in the thread under the cursor
      delete = "<leader>mD", -- delete a comment in the thread under the cursor
      suggest = "<leader>ms", -- visual mode: suggest a change to these lines
      description = "<leader>md", -- the merge request itself, in a float
      -- Out here rather than one letter further in, unlike the rest of
      -- the verbs below: ending a review is not something you go to a
      -- window to do, and a mode you cannot leave from where you are
      -- standing is a mode you leave by restarting the editor.
      close = "<leader>mq", -- put the review away: markers, keys and all
      next = "]m",
      prev = "[m",

      -- The rest are here, unbound, because a review is a dozen keys
      -- under one prefix and a dozen keys under one prefix is a menu
      -- nobody has learnt. Each of these is either a key on the merge
      -- request's own window -- `<leader>md`, and then one letter --
      -- or a `:Nemeton` verb typed once in a review, which is about as
      -- often as any of them is wanted. Give one a string to have it
      -- out here as well; nothing else has to change.
      notes = false, -- `c` on <leader>md -- every comment, one line each
      approve = false, -- `a` there -- approve it, or take it back
      jobs = false, -- `p` there -- what CI did, job by job
      publish = false, -- `s` there -- send every comment kept unsent
      threads = false, -- :Nemeton threads -- every thread, as a quickfix list
      toggle = false, -- :Nemeton comments -- the markers on and off
    },
    -- The MR list window.
    list = {
      select = "<CR>",
      -- Open, merged, closed, all -- in that order, round and round.
      -- A review queue is what is open, which is what the window opens
      -- on; "how did we end up doing it this way" is a question about
      -- one that is merged, and it is asked often enough to want a key
      -- and rarely enough not to want a setting.
      state = "s",
      -- One more page of them, under the ones on the screen. A queue
      -- of what is open is a page long; a queue of what is merged is a
      -- history, and what is being looked for in a history is usually
      -- further down than thirty rows.
      more = "]",
      -- A merge request of your own, for the branch you are on. `+`
      -- rather than a letter: nothing in this window is a motion, and
      -- the one key here that writes rather than reads should not look
      -- like the ones that read.
      create = "+",
      refresh = "r",
      browser = "o",
      quit = "q",
      commits = "c", -- the changelog of the row under the cursor
      description = "d", -- what the row under the cursor says it is for
    },
    -- The window holding every comment on the merge request, one line
    -- each. The same keys as the every-thread window below, because it
    -- is the same threads read at a different depth: <CR> is the way
    -- *into* the code and `r` answers where you are sitting.
    notes = {
      code = "<CR>", -- go to the line this comment is about
      reply = "r",
      add = "a", -- a comment on the merge request, posted on its own
      thread = "t", -- one people can reply to
      edit = "e", -- rewrite one of the comments in this thread
      delete = "d", -- delete one of them, after asking
      refresh = "R",
      quit = "q",
    },
    -- The merge request's own window: what it is for, what CI made of
    -- it, who has approved it, and the keys to act on all three.
    -- Deliberately none of hjkl, and nothing that starts a motion you
    -- would use to read with: this is a window of prose, it is scrolled
    -- and searched like any other, and a key here that moves the cursor
    -- somewhere else instead is a window you cannot read.
    detail = {
      approve = "a", -- approve it, or take the approval back
      -- The other verdict, and the one the whole review has been
      -- written towards: sending it. Beside `a` because they are the
      -- two things you come to this window to *do*, and a review is
      -- approved and sent in the same breath as often as not.
      publish = "s", -- send every comment kept unsent
      comments = "c", -- every comment on it, one line each
      pipeline = "p", -- what CI did, job by job
      browser = "o",
      refresh = "r",
      quit = "q",
    },

    -- Every thread on the merge request, read as conversation rather
    -- than as a list of places to jump to.
    conversation = {
      code = "<CR>", -- go to the code the thread under the cursor is about
      reply = "r",
      edit = "e",
      delete = "d",
      refresh = "R",
      quit = "q",
    },

    -- The pipeline's jobs.
    jobs = {
      log = "<CR>", -- what the job under the cursor printed, in a tab
      browser = "o", -- the job under the cursor, on GitLab
      refresh = "r",
      quit = "q",
    },
    -- One job's log. A tab of its own rather than a float: a build log
    -- is thousands of lines that are read by searching, and a window
    -- over the middle of the editor is the wrong shape for that -- so
    -- what is bound here is only what a float would have needed.
    log = {
      refresh = "R", -- a running job has more of it every second
      browser = "o",
      quit = "q", -- closes the tab
    },

    -- The composer.
    -- Writing a comment ends one of two ways, and the usual one is
    -- keeping it: a review is written as a whole and sent as a whole,
    -- and a comment posted the moment it is typed is a comment its
    -- author cannot take back after reading the next file.
    --
    -- So `keep` is what `:w` does, and what <C-s> does, and posting on
    -- the spot is the other key. Swap the two strings to swap them
    -- back: nothing else knows which is which.
    compose = {
      keep = "<C-s>", -- into the review, to go out with the rest of it
      post = "<C-p>", -- straight to the merge request, now
      cancel = "q",
    },
  },

  -- Every subprocess this plugin runs, written down -- what was run,
  -- where, how long it took, and what it said if it failed. Off is one
  -- line away, but on by default: the failures worth debugging in a
  -- review are the ones that happened twenty minutes ago.
  --
  -- Never the token: the environment is logged by name and by presence,
  -- `GITLAB_TOKEN=<set>`, and arguments and error output are scrubbed on
  -- the way in. See lua/nemeton/log.lua.
  log = {
    enabled = true,

    -- nil is $XDG_STATE_HOME/nemeton/nemeton.log, and
    -- ~/.local/state/nemeton/nemeton.log where XDG_STATE_HOME is unset.
    -- A string overrides it, `~` and all.
    path = nil,

    -- One rotation, at this size: past it the file becomes
    -- nemeton.log.old and a new one starts. Two files bound the disk.
    -- 0 or nil never rotates.
    max_bytes = 1024 * 1024,
  },

  -- Everything reaches GitLab through this one binary. Named here so a
  -- user with it somewhere odd has one line to change.
  glab = {
    bin = "glab",

    -- Whether to point the branch a checkout leaves you on at the
    -- branch it came from.
    --
    -- `glab mr checkout` tracks it against
    -- `refs/merge-requests/<iid>/head` instead, so that `git pull`
    -- follows the merge request. Nothing on this side has a remote
    -- branch: git can no longer say whether you are ahead or behind,
    -- and neither can anything that reads git -- a statusline, lazygit,
    -- which draws a branch with no upstream it can count against as a
    -- question mark.
    --
    -- For a merge request from this project the two are the same
    -- commits under two names, so this sets the ordinary upstream
    -- afterwards: one `git fetch`, one `git branch --set-upstream-to`.
    -- Never for one from a fork -- its source branch is not on this
    -- remote, and a branch of the same name that happens to be is a
    -- different branch entirely -- and never for a checkout under a
    -- name of your own, which is not a branch this configured.
    --
    -- `false` to leave what glab wrote alone.
    track = true,
    -- Seconds before a call is considered hung. The forge is on the far
    -- side of a network and an editor that never answers is worse than
    -- one that says it gave up.
    timeout = 30,

    -- Which GitLab. Left nil, glab works it out for itself -- from the
    -- git remote of the repository you are in, then from `glab auth
    -- login`'s config -- which is right on nearly every machine, and is
    -- why this is nil rather than "gitlab.com".
    --
    -- Set it for a self-managed instance that glab cannot infer:
    -- "gitlab.example.com", or a full URL if it is not https. Exported
    -- as GITLAB_HOST for every call.
    --
    -- One sharp edge, and it is glab's: with GITLAB_HOST set, glab
    -- refuses to work in a repository whose remotes point somewhere else
    -- -- "none of the git remotes configured for this repository
    -- correspond to the GITLAB_HOST environment variable". So a value
    -- here is a statement that every repository you review lives on that
    -- host. If you work across two instances, leave this nil and let the
    -- remote decide, or make it a function of `vim.fn.getcwd()`.
    --
    -- string | fun(): string | nil
    host = nil,

    -- The token, exported as GITLAB_TOKEN. Also nil by default: `glab
    -- auth login` puts one in the system keyring, and a token in a
    -- dotfile is a token in a backup, in a screen share, and eventually
    -- in a repository.
    --
    -- Set it to a FUNCTION to read it from somewhere that is not a
    -- dotfile -- it is called once per editor session and cached:
    --
    --   token = function()
    --     return vim.trim(vim.fn.system("pass show gitlab/token"))
    --   end
    --
    -- A plain string works too, for a scratch machine or a value you
    -- pull out of your own environment:
    --
    --   token = os.getenv("WORK_GITLAB_TOKEN")
    --
    -- string | fun(): string | nil
    token = nil,

    -- What to do when glab says the credentials are no good -- a 401,
    -- or no token anywhere at all. On, nemeton asks for one (masked, and
    -- kept in memory for this editor session only) and retries the call
    -- that failed. Off, the call just fails and says why.
    --
    -- On by default because of when it happens: a token expires in the
    -- middle of a review, and the alternative is a failed comment, a
    -- trip to a terminal, `glab auth login`, and a lost train of thought.
    prompt_for_token = true,
  },
}
