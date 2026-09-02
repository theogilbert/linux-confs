-- Threads, drawn on a buffer.
--
-- Extmarks rather than the sign API: signs are placed by line number and
-- go stale the moment you insert a line above them, while an extmark is
-- moved by the edit. A review is a session in which you *change* the
-- file you are reading, so a marker that does not follow its line is a
-- marker pointing at the wrong code.

local config = require("nemeton.config")
local threads = require("nemeton.threads")

local M = {}

M.ns = vim.api.nvim_create_namespace("nemeton")

-- A second namespace, for the text this plugin writes into windows of
-- its own -- the list, the peek float, the notes window. Separate from
-- the one above because that one is cleared and redrawn every time a
-- session refreshes, and it is cleared *by buffer*: a redraw triggered
-- by the list float opening would otherwise wipe the colours the list
-- had just painted on itself.
M.ui_ns = vim.api.nvim_create_namespace("nemeton-ui")

-- bufnr -> (extmark id -> the line its threads were written against).
-- The extmark moves with the edits; the index does not, so this is how
-- "what is under my cursor now" gets back to "which thread is that".
M.line_of_mark = {}

--- Two colours mixed: `amount` of the way from `a` to `b`, both
--- 0xRRGGBB.
local function mix(a, b, amount)
  local out = 0
  for _, shift in ipairs({ 65536, 256, 1 }) do
    local x = math.floor(a / shift) % 256
    local y = math.floor(b / shift) % 256
    out = out + math.floor(x + (y - x) * amount + 0.5) * shift
  end
  return out
end

-- Every group that has been given the ground's background, so that the
-- work is done once per colour rather than once per line drawn.
local grounded = {}

--- The two grounds an expanded conversation is drawn on.
---
--- Not CursorLine, which this used to be: CursorLine is a grey band,
--- and a grey band under every conversation in the file is the file
--- gone grey. This is the file's own background lifted towards the
--- colour its text is drawn in -- lighter in a dark colourscheme,
--- darker in a light one, and in both of them the same background
--- standing off the page rather than a colour from somewhere else.
---
--- Far enough to win an argument it is in the middle of. A conversation
--- is not the only thing painting backgrounds on these lines -- a diff
--- plugin puts red and green ones on the code above and below -- and a
--- ground that is a whisper away from the file's own reads as one more
--- band of that. `config.comments.ground` is how far, for a
--- colourscheme where this is the wrong distance.
---
--- Then towards the colour of the state, which is the second thing to
--- say: "settled" and "still owed an answer" is the one thing about a
--- thread you want to know before reading a word of it, and it was
--- being said only in the tick and in the dimness of the text -- both
--- of which have to be read. A block has a colour before it has
--- anything else, so the block says it: towards the open colour for a
--- conversation that is waiting on somebody, towards the resolved one
--- for a conversation that is over.
---
--- And half as far, both ways. Two tints of the same strength differ
--- only in hue, which at this saturation is a difference you have to
--- look for; half the distance from the file's own background is a
--- difference you cannot miss, and it is the right way round -- an
--- argument still going on stands off the page, one that is over sinks
--- back towards it. Which is what "resolved" means: there, and no
--- longer asking anything of you.
---
--- Without true colour there is nothing to mix: 16 or 256 fixed colours
--- have no "a seventh of the way", and CursorLine is what an editor has
--- always used to say "this row, not the others". There, the tick and
--- the dimming carry it alone -- as they do when `ground` is `false`
--- and there is to be no band at all.
local function ground()
  grounded = {}
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local lift = config.comments.ground
  --- `share` is how much of the ground this one gets: the whole of it
  --- for a conversation still going on, half for one that is over.
  local function tint(name, from, share)
    -- Linked to Normal rather than cleared: `default` is what leaves a
    -- `:hi` of your own standing, and a cleared group cannot be set
    -- with it. Normal's background is the file's own, which is a band
    -- nobody can see -- which is what was asked for.
    if lift == false then
      vim.api.nvim_set_hl(0, name, { link = "Normal", default = true })
      return
    end
    local accent = vim.api.nvim_get_hl(0, { name = from, link = false })
    if not (vim.o.termguicolors and normal.bg and normal.fg) then
      vim.api.nvim_set_hl(0, name, { link = "CursorLine", default = true })
      return
    end
    local bg = mix(normal.bg, normal.fg, lift * share)
    vim.api.nvim_set_hl(0, name, {
      bg = mix(bg, accent.fg or normal.fg, 0.14 * share),
      default = true,
    })
  end
  tint("NemetonInline", "NemetonSignOpen", 1)
  tint("NemetonSettled", "NemetonResolved", 0.5)
end

--- `group`, with the ground behind it.
---
--- The alternative -- the ground under the text and the group over it,
--- as two highlights on one chunk -- loses whenever the group carries a
--- background of its own, and several do: NemetonThread is the file's
--- Normal, which is the file's background, and a suggestion is drawn in
--- DiffAdd, which in most colourschemes is a green block. Both would
--- punch their own background through the ground, in the middle of the
--- block, which is the one place the ground has to be continuous.
---
--- So the colour is taken and the background is not. A group that says
--- its piece in a background alone -- DiffAdd again, which often has no
--- foreground at all -- says it in that colour as text instead.
local function on_ground(group, settled)
  local base = settled and "NemetonSettled" or "NemetonInline"
  if not group then
    return base
  end
  local key = base .. "/" .. group
  if grounded[key] then
    return grounded[key]
  end
  local name = base .. group:gsub("^Nemeton", "")
  local from = vim.api.nvim_get_hl(0, { name = group, link = false })
  local bg = vim.api.nvim_get_hl(0, { name = base, link = false })
  from.fg = from.fg or from.bg
  from.ctermfg = from.ctermfg or from.ctermbg
  from.bg, from.ctermbg = bg.bg, bg.ctermbg
  from.link = nil
  -- ...and not `default`, which is what the group we copied from was
  -- defined with so that a `:hi` of your own would win over it. Carried
  -- through to here it means something else: this group has been
  -- computed before, from a ground that has since changed, and the set
  -- that would correct it is quietly ignored. A colourscheme change
  -- left the old background in the middle of the new block.
  from.default = nil
  vim.api.nvim_set_hl(0, name, from)
  grounded[key] = name
  return name
end

function M.setup_highlights()
  local function link(from, to)
    vim.api.nvim_set_hl(0, from, { link = to, default = true })
  end
  -- An open thread is something addressed to you; a resolved one is
  -- history. Borrowed from the diagnostic groups so they sit inside the
  -- colourscheme rather than beside it.
  link("NemetonSignOpen", "DiagnosticInfo")
  link("NemetonSignResolved", "Comment")
  link("NemetonAuthor", "Title")
  -- A git ref -- the branch a merge request comes from, the one it goes
  -- to. Its own colour because a head line reading "alice ·
  -- fix/proxy → main · updated 3d ago" in one colour is a sentence to
  -- be read, and these are three facts to be picked out of it.
  link("NemetonBranch", "Directory")
  -- Where a thread sits, where a list of them has to say so. The colour
  -- an editor draws a path in, which is the colour this one is.
  link("NemetonPath", "Directory")
  link("NemetonResolved", "DiagnosticOk")
  -- What a note *is* against what it says. The first is skimmed -- who,
  -- when, and whether it is settled -- and stays out of the way; the
  -- second is the thing you opened the thread to read, and is the one
  -- part of a review that should not be dimmer than the code it is
  -- about. Same reasoning as the hint group below, one step further.
  link("NemetonMeta", "Comment")
  -- CI, and anything else with a verdict: the three states a glance is
  -- meant to separate, in the three colours an editor already uses for
  -- them.
  -- A comment you have written and not sent: not open, not settled,
  -- and owed an action by you rather than by anybody else.
  link("NemetonDraft", "DiagnosticWarn")
  -- A line added and a line taken away: counted in the list's +12 −3,
  -- shown in the suggestion inside a comment. One pair for both,
  -- because it is one fact drawn twice.
  --
  -- `Added`/`Removed` rather than DiffAdd/DiffDelete, which is what
  -- these used to be. Those two are backgrounds in most colourschemes,
  -- and a background is the wrong half of a colour in both places here:
  -- in a table it punches coloured tiles through the row, and inside a
  -- conversation it punches a hole in the ground the conversation is
  -- drawn on. Taking the background and using it as text instead is
  -- worse still -- a background green is chosen to sit *behind* text and
  -- is unreadable in front of it. `Added`/`Removed` are the pair Neovim
  -- ships that were colours of text all along.
  link("NemetonAdded", "Added")
  link("NemetonRemoved", "Removed")
  link("NemetonOk", "DiagnosticOk")
  link("NemetonBad", "DiagnosticError")
  link("NemetonBusy", "DiagnosticWarn")
  -- The colour ordinary text is -- and only the colour. This linked to
  -- Normal, and Normal carries a background as well: the editor's own.
  -- A group that carries it paints the *file's* background wherever it
  -- is drawn, which in a float is a black band behind every merge
  -- request title in the list, and on the ground under a conversation
  -- is a hole in the block. Normal is the one group here guaranteed to
  -- have a background, so it is the one that is copied from rather than
  -- linked to.
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  vim.api.nvim_set_hl(
    0,
    "NemetonThread",
    { fg = normal.fg, ctermfg = normal.ctermfg, default = true }
  )
  -- The key hints are dim on purpose, but NonText is the group a
  -- colourscheme paints to be *unseen* -- listchars, the ~ past the end
  -- of a buffer -- and on a winbar's background it disappears. Comment
  -- is the other quiet group, and the one every scheme keeps readable.
  link("NemetonHint", "Comment")
  -- The key itself, inside a hint. A row of "a approve · c comments" in
  -- one dim colour is a sentence, and the thing being looked up in it --
  -- the letter to press -- is the part that has to be found without
  -- reading the rest.
  link("NemetonKey", "Special")
  ground()
end

--- Paints `hls` (from `threads.flatten`) onto a buffer this plugin
--- owns -- the peek float, the overall-notes window. Their text is
--- written as plain lines and coloured afterwards, because a real
--- buffer takes highlights as extmarks rather than as chunks.
function M.paint(bufnr, hls)
  vim.api.nvim_buf_clear_namespace(bufnr, M.ui_ns, 0, -1)
  for _, h in ipairs(hls) do
    vim.api.nvim_buf_set_extmark(bufnr, M.ui_ns, h.row, h.col, {
      end_col = h.end_col,
      hl_group = h.hl,
    })
  end
end

function M.clear(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  end
end

--- How much room a conversation drawn into `bufnr` actually has.
---
--- The narrowest window the buffer is open in, minus whatever that
--- window spends on the gutter. Narrowest, because the same buffer can
--- be in two windows at two widths and both are drawn from these
--- marks: wrapping to the wider one leaves the narrow one with lines
--- running off its edge, and virtual text has no way back from there.
--- Wrapping to the narrower leaves the wide one with short lines, which
--- is a comment nobody has to work to read.
local function room(bufnr)
  local width
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    local info = vim.fn.getwininfo(win)[1]
    if info then
      local w = info.width - (info.textoff or 0)
      width = math.min(width or w, w)
    end
  end
  -- Drawn before it is shown anywhere -- a buffer loaded but not yet in
  -- a window -- and redrawn once it is.
  return width or vim.o.columns
end

local function visible(list, show_resolved)
  if show_resolved then
    return list
  end
  return vim.tbl_filter(function(t)
    return not t.resolved
  end, list)
end

--- Draws `by_line` (line number -> list of threads) onto `bufnr`.
---
--- `mode` is "signs" -- the gutter only -- or "expanded", which also
--- puts the conversation itself under the line as virtual lines. The
--- two are one function because they are one decision made twice a
--- minute: the gutter is always on, the text comes and goes.
--- Puts the expanded conversations on a ground of their own.
---
--- Without one they are text in the middle of a file: same background,
--- same column, and the only thing saying "you are not reading Lua any
--- more" is a rail one cell wide. A ground says it before anything is
--- read.
---
--- Padded to the width of the whole editor, which is at least the width
--- of any window the buffer is in.
---
--- Which window's width to draw to is not a question a buffer can
--- answer -- the same file is open in two of them, at two widths, and
--- both draw these marks. It does not have to be answered: a virtual
--- line longer than the window it is drawn in is cut off at the edge
--- rather than wrapped, so padding past the widest possible window
--- gives every one of them a band that reaches its own right-hand side.
--- `columns` changes when the editor is resized, which is why that is
--- one of the things a redraw hangs off.
--- `settled[i]` says which of the two grounds line `i` belongs on: the
--- threads on a line are drawn one after another, and one of them being
--- over does not settle the next.
local function shade(virt, settled)
  local widths = {}
  for i, line in ipairs(virt) do
    local w = 0
    for _, chunk in ipairs(line) do
      w = w + vim.fn.strdisplaywidth(chunk[1])
    end
    widths[i] = w
  end
  local width = vim.o.columns

  local out = {}
  for i, line in ipairs(virt) do
    -- The line between two threads is left bare: no chunks, so no
    -- ground. Two conversations on one line of code are two blocks with
    -- the file showing between them, which says "another argument"
    -- where a continuous ground would say "more of the same one". It is
    -- the same break the rail makes, made in the one other way this
    -- window has of making it.
    if #line == 0 then
      out[i] = {}
    else
      local done = settled and settled[i] or false
      local shaded = {}
      for _, chunk in ipairs(line) do
        table.insert(shaded, { chunk[1], on_ground(chunk[2], done) })
      end
      table.insert(shaded, { (" "):rep(math.max(width - widths[i], 1)), on_ground(nil, done) })
      out[i] = shaded
    end
  end
  return out
end

function M.render(bufnr, by_line, mode, opts)
  opts = opts or {}
  M.clear(bufnr)
  if not by_line or not vim.api.nvim_buf_is_valid(bufnr) then
    return 0
  end

  local last = vim.api.nvim_buf_line_count(bufnr)
  local drawn = 0
  M.line_of_mark[bufnr] = {}

  for line, list in pairs(by_line) do
    local shown = visible(list, opts.show_resolved ~= false)
    -- A thread whose line is past the end of the buffer -- the file was
    -- truncated since, or the local branch is not what the thread was
    -- written against -- is pinned to the last line rather than dropped.
    -- Silently losing a review comment is the one failure that matters.
    local row = math.min(line, last) - 1
    if #shown > 0 and row >= 0 then
      local unresolved = false
      for _, t in ipairs(shown) do
        if not t.resolved then
          unresolved = true
        end
      end

      local drafted = false
      for _, t in ipairs(shown) do
        if threads.unsent(t) then
          drafted = true
        end
      end

      -- A line carrying anything unsent says so first: it is the one
      -- state on this buffer that is waiting on *you*.
      local mark = {
        sign_text = drafted and config.comments.sign_draft
          or (unresolved and config.comments.sign_open or config.comments.sign_resolved),
        sign_hl_group = drafted and "NemetonDraft"
          or (unresolved and "NemetonSignOpen" or "NemetonSignResolved"),
        priority = 20,
      }

      -- Not when the conversation itself is drawn under the line: the
      -- summary is the first sixty characters of the first note, and
      -- the first note is the next thing on the screen. Two of it is
      -- one too many, and the one that is cut off mid-sentence is the
      -- one to lose.
      if config.comments.virt_text and mode ~= "expanded" then
        local first = shown[1].notes[1]
        local summary = vim.split(first.body, "\n", { plain = true })[1] or ""
        local count = #shown > 1 and (" (+%d)"):format(#shown - 1) or ""
        mark.virt_text = {
          { "  " .. first.author .. count .. ": ", "NemetonAuthor" },
          -- Dim: this one is a glance at what is there, not the reading
          -- of it, and it sits at the end of a line of code.
          { summary:sub(1, 60), "NemetonMeta" },
        }
        mark.virt_text_pos = "eol"
      end

      if mode == "expanded" then
        -- threads.render already returns virtual-line chunks, which is
        -- the shape it returns *because* of this line.
        -- The lines a suggestion in this thread would replace, read
        -- off the buffer at the row the marker has moved to rather than
        -- the row the thread was written against.
        local function replaced(above, below)
          local first = math.max(row - above, 0)
          return vim.api.nvim_buf_get_lines(bufnr, first, row + below + 1, false)
        end
        local virt, settled = {}, {}
        local width = room(bufnr)
        -- The lines this thread was written against, when the buffer no
        -- longer says what they said. Read off the buffer rather than
        -- the file: what is on the screen is what the comment now reads
        -- as being about, saved or not.
        local function was(t)
          return opts.was and opts.was(t, replaced(threads.span(t), 0)) or nil
        end
        for _, t in ipairs(shown) do
          -- A blank line between two threads, and nothing but a blank
          -- line: it is the one place the rail stops and the one place
          -- the ground does, which is what makes "a new argument" look
          -- different from "an answer to the one above".
          if #virt > 0 then
            table.insert(virt, {})
          end
          local drawn = threads.render(t, { replaced = replaced, width = width, was = was(t) })
          for _, line in ipairs(drawn) do
            table.insert(virt, line)
            settled[#virt] = t.resolved and true or false
          end
        end
        mark.virt_lines = shade(virt, settled)
      end

      local id = vim.api.nvim_buf_set_extmark(bufnr, M.ns, row, 0, mark)
      M.line_of_mark[bufnr][id] = line
      drawn = drawn + #shown
    end
  end
  return drawn
end

--- The threads on the cursor's line, by asking the extmarks rather than
--- the index -- so an edit that moved the marker moves the answer too.
function M.threads_at(bufnr, row, by_line)
  if not by_line then
    return {}
  end
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, M.ns, { row - 1, 0 }, { row - 1, -1 }, {})
  if #marks == 0 then
    return {}
  end
  -- The extmark says which line is *now* marked; the index still keys on
  -- the line the thread was written against. Recovering one from the
  -- other means remembering which mark belongs to which line, which is
  -- what `line_of_mark` is for.
  local known = M.line_of_mark[bufnr] or {}
  local out = {}
  for _, mark in ipairs(marks) do
    local line = known[mark[1]]
    if line and by_line[line] then
      vim.list_extend(out, by_line[line])
    end
  end
  return out
end

return M
