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

-- Where the conversation being read is anchored, drawn in the gutter of
-- the code while it is on the screen. A third namespace because it is
-- cleared and redrawn on its own clock -- the reader moves from one
-- thread to the next without the markers under them changing at all --
-- and because a redraw of those must not take it with them.
M.reading_ns = vim.api.nvim_create_namespace("nemeton-reading")

-- The buffer it was last drawn in. One conversation is read at a time,
-- so there is one of these, and clearing it is cheaper than asking
-- every buffer in the editor whether it has any.
local reading = nil

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

--- How light a colour is, on the scale everything that has to be read
--- against it cares about.
local function lum(c)
  return 0.2126 * (math.floor(c / 65536) % 256)
    + 0.7152 * (math.floor(c / 256) % 256)
    + 0.0722 * (c % 256)
end

--- `c`, put back at the lightness `want` -- its channels scaled, so the
--- colour is the colour it was and only its brightness moves.
---
--- What this is for: a band told apart from the band it sits inside by
--- being a different colour rather than a lighter one. Lighter is the
--- one direction that costs whatever is written on it, because lighter
--- means nearer the colour of the text -- and the quietest group in
--- this plugin is drawn on one of these.
local function at_lum(c, want)
  local now = lum(c)
  if now <= 0 then
    return c
  end
  local out, scale = 0, want / now
  for _, shift in ipairs({ 65536, 256, 1 }) do
    local x = math.floor(c / shift) % 256
    out = out + math.min(math.floor(x * scale + 0.5), 255) * shift
  end
  return out
end

-- Every group that has been given the ground's background, so that the
-- work is done once per colour rather than once per line drawn.
local grounded = {}

--- The two grounds a conversation is drawn on.
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

  --- The colour a ground leans towards, or nil for one that leans
  --- nowhere.
  ---
  --- `from` is the group the band would borrow from if it borrowed by
  --- state -- an open thread's colour under an open thread, a resolved
  --- one's under a resolved one. `config.comments.accent` overrules it:
  --- a name, and every ground borrows from that one group instead;
  --- `false`, and none of them borrows at all and the block is the
  --- page's own colour raised off it. Which is a different way of
  --- saying what a comment is: not a thing with a state that has a
  --- colour, but a panel with words on it, told from the code by
  --- standing above it. What state it is in the rail and the tick say
  --- outright, and the settled ground still sinks back towards the page
  --- -- the lift is halved for it either way.
  --- `pick` overrules `config.comments.accent`, for a band that leans
  --- somewhere the ground under it does not. `nil` is "wherever the
  --- grounds lean".
  local function accent_of(from, pick)
    if pick == nil then
      pick = config.comments.accent
    end
    if pick == false then
      return nil
    end
    local hl =
      vim.api.nvim_get_hl(0, { name = type(pick) == "string" and pick or from, link = false })
    return hl.fg
  end

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
    local accent = accent_of(from)
    if not (vim.o.termguicolors and normal.bg and normal.fg) then
      vim.api.nvim_set_hl(0, name, { link = "CursorLine", default = true })
      return
    end
    -- The lift decides how far off the page the band is; the tint
    -- decides which way it leans, and is then put back where the lift
    -- put it. Without that last part the tint was a second lift nobody
    -- asked for: `NemetonSignOpen` is a bright colour, and mixing a
    -- seventh of it into the ground was adding half as much again to a
    -- number `config.comments.ground` is supposed to be the whole of.
    -- The band came out light enough that the comment colour on it --
    -- the date, the file, every count in the plugin -- was most of the
    -- way to the colour behind it.
    local bg = mix(normal.bg, normal.fg, lift * share)
    vim.api.nvim_set_hl(0, name, {
      bg = accent and at_lum(mix(bg, accent, 0.14 * share), lum(bg)) or bg,
      default = true,
    })
  end
  tint("NemetonInline", "NemetonSignOpen", 1)
  tint("NemetonSettled", "NemetonResolved", 0.5)
  -- ...and the same ground out on the code, under the lines the
  -- conversation being read was written against |nemeton-reading|. The
  -- same colour on purpose: the block in the pane and the lines out
  -- here are one block read in two windows. Weaker, because this one is
  -- under code that is being read rather than under prose.
  local reading_share = config.comments.reading_ground
  if reading_share == false then
    vim.api.nvim_set_hl(0, "NemetonReading", { link = "Normal", default = true })
  else
    tint("NemetonReading", "NemetonSignOpen", reading_share or 0.6)
  end
  -- ...and the ground an answer is drawn on, which is the same ground
  -- standing further off the page.
  --
  -- An indent and an arrow said a reply was a reply, and both of them
  -- are two characters at the head of a line -- which is where the eye
  -- is not, when it has just finished reading the line above. A thread
  -- with four answers in it read as one block of prose by five people.
  -- A step in the ground says it without being read, and says it on
  -- every line of the answer rather than on the first.
  local answer = config.comments.reply_ground or 1
  tint("NemetonReply", "NemetonSignOpen", answer)
  tint("NemetonReplySettled", "NemetonResolved", answer * 0.5)
  -- ...and the band the head of each note sits on. A note is two things
  -- read two ways -- who said it and when, which is skimmed, and what
  -- they said, which is read -- and in a thread with four answers in it
  -- that is four places the eye has to find.
  --
  -- Told from the ground it sits inside by colour and by a hair of
  -- lightness, and not by lightness alone -- which is what it was, and
  -- what made the head of a note harder to read than the note. Lifting
  -- a band moves it towards the colour of the text on it, and the head
  -- carries the quietest group in the plugin: the date, in the comment
  -- colour. A heading is a different colour, not a brighter one.
  local function heading(name, base, from)
    if lift == false or not (vim.o.termguicolors and normal.bg and normal.fg) then
      vim.api.nvim_set_hl(0, name, { link = base, default = true })
      return
    end
    local under = vim.api.nvim_get_hl(0, { name = base, link = false })
    local accent = accent_of(from, config.comments.heading_accent)
    if not under.bg then
      vim.api.nvim_set_hl(0, name, { link = base, default = true })
      return
    end
    -- Into whatever the heading leans towards -- which need not be
    -- where the ground under it leans, and by default is not: a panel
    -- with no colour in it can tell its heading from its body by
    -- lightness alone, and lightness is the one direction that costs
    -- whatever is written on the band. A tint of its own is a heading
    -- that is a different colour without being a brighter one.
    --
    -- Then put back at the lightness it started from, plus the hair.
    -- Without a colour to lean into at all the hair is the whole of it.
    local bg = mix(under.bg, accent or normal.fg, accent and (config.comments.heading or 0) or 0)
    vim.api.nvim_set_hl(0, name, {
      bg = at_lum(bg, lum(under.bg) * 1.1),
      default = true,
    })
  end
  heading("NemetonHead", "NemetonInline", "NemetonSignOpen")
  heading("NemetonHeadSettled", "NemetonSettled", "NemetonResolved")
  heading("NemetonHeadReply", "NemetonReply", "NemetonSignOpen")
  heading("NemetonHeadReplySettled", "NemetonReplySettled", "NemetonResolved")

  -- ...and the band the code a thread was written against is drawn on,
  -- which is not one of the two: it is a quotation of the file inside a
  -- conversation, and what says so is that it does not look like the
  -- conversation around it. Further from the page than either ground
  -- and towards the colour of a line taken away, because that is what it
  -- is -- code that was there when the comment was written and is not
  -- there now.
  --
  -- Its text stays the colour text is: the background is carrying the
  -- verdict now, and red words on a red band are a line you have to work
  -- at to read. Nothing to mix without true colour, so there it is the
  -- red text it used to be.
  if vim.o.termguicolors and normal.bg and normal.fg then
    local gone = vim.api.nvim_get_hl(0, { name = "NemetonRemoved", link = false })
    vim.api.nvim_set_hl(0, "NemetonWas", {
      fg = normal.fg,
      bg = mix(normal.bg, gone.fg or normal.fg, 0.28),
      default = true,
    })
  else
    vim.api.nvim_set_hl(0, "NemetonWas", { link = "NemetonRemoved", default = true })
  end

  -- ...and the two bands a suggestion is drawn on: the lines it would
  -- put there, and the lines it would take away.
  --
  -- A band and not only coloured text, because the text is no longer
  -- free to carry it. The code inside a suggestion is drawn in the
  -- colours of its own language now |nemeton-syntax|, and a keyword is
  -- the colour a keyword is on both halves of the diff -- so green
  -- words and red words, which is what said which half a line was, say
  -- nothing any more. A background is the one part of a line that
  -- syntax highlighting does not use.
  --
  -- Lighter than NemetonWas, which is next to them in the same block
  -- and is a quotation rather than half of a diff.
  local function band(name, from)
    if not (vim.o.termguicolors and normal.bg and normal.fg) then
      vim.api.nvim_set_hl(0, name, { link = from, default = true })
      return
    end
    local accent = vim.api.nvim_get_hl(0, { name = from, link = false })
    vim.api.nvim_set_hl(0, name, {
      -- The foreground the half used to be drawn in, kept for what is
      -- on the band and is not code: the `+`, the `-`, and every line
      -- of a language nothing here can parse.
      fg = accent.fg or normal.fg,
      bg = mix(normal.bg, accent.fg or normal.fg, 0.18),
      default = true,
    })
  end
  band("NemetonSuggestNew", "NemetonAdded")
  band("NemetonSuggestOld", "NemetonRemoved")

  -- ...and the other two verdicts the quotation carries. `NemetonWas`
  -- above is the line that is gone; a line that has been edited since
  -- and a line that has arrived since are not the same news, and a
  -- reader who has to work out which from the words has been told
  -- nothing the words did not already say. The same three colours a
  -- diff is read in everywhere else, at the weight of a band, because
  -- that is the vocabulary already in the reader's eye.
  --
  -- A line that has not moved gets no band at all: the block is mostly
  -- those, and a ground under every line of it says "this is a
  -- quotation" at the cost of saying nothing about any one line.
  band("NemetonWasChanged", "NemetonChanged")
  band("NemetonWasAdded", "NemetonAdded")
end

-- The groups that are a ground rather than a colour of text: the code a
-- thread was written against, and the two halves of a suggestion. Each
-- is a band inside the block rather than text on it, and a line
-- carrying one is drawn on it instead of on the conversation's -- see
-- `M.shade_lines`.
local OWN_GROUND = {
  NemetonWas = true,
  NemetonWasChanged = true,
  NemetonWasAdded = true,
  NemetonSuggestNew = true,
  NemetonSuggestOld = true,
  NemetonHead = true,
  NemetonHeadSettled = true,
  NemetonHeadReply = true,
  NemetonHeadReplySettled = true,
}

--- The byte range [from, to) cut where an answer's ground starts, so a
--- chunk lying across the two is drawn on both. One piece where `inset`
--- is nil or falls outside the range, which is every line that is not
--- the front of an answer.
local function split_at(from, to, inset)
  if not inset or inset <= from or inset >= to then
    return { { from = from, to = to, outer = inset and to <= inset or false } }
  end
  return {
    { from = from, to = inset, outer = true },
    { from = inset, to = to, outer = false },
  }
end

--- Which of the four grounds a line belongs on: whether the thread is
--- over, and whether the line is an answer inside it rather than the
--- note the answers are to.
local function ground_for(state, reply)
  if state == "settled" then
    return reply and "NemetonReplySettled" or "NemetonSettled"
  end
  return reply and "NemetonReply" or "NemetonInline"
end

--- ...and whether one of them is a ground *here*.
---
--- All three are a background mixed out of the file's own, and there is
--- no mixing anything in sixteen colours: without true colour they fall
--- back to the colour of text they used to be, which is not a band and
--- must not be taken for one. Taken for one, it would be a stretch of
--- the block with no background at all -- a hole in the ground, in the
--- middle of the conversation, which is the one thing the ground is
--- there to avoid.
local function is_ground(name)
  if not OWN_GROUND[name] then
    return false
  end
  local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
  return (hl.bg or hl.ctermbg) ~= nil
end

--- The band a chunk brings with it, or nil where it brings none: a
--- chunk drawn in one, or one asking for a colour on one.
---
--- Only asked on a line that says its bands are its chunks' rather than
--- the line's -- `line.contained`, which is a suggestion inside a box.
--- Everywhere else a band is the whole line, edge to edge, because
--- there is nothing else on the line to say where it stops.
local function band_of(chunk)
  local named = type(chunk[2]) == "table" and chunk[2][1] or chunk[2]
  return is_ground(named) and named or nil
end

--- `group`, with `base` behind it.
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
local function on_ground(group, base)
  -- Nothing to put on it, or it is the ground itself: the band under
  -- quoted code arrives as the group it is drawn on.
  if not group or group == base then
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
  -- What a comment points at rather than says: the name of somebody it
  -- calls on, the commit it blames.
  link("NemetonMention", "DiagnosticInfo")
  link("NemetonCommit", "DiagnosticInfo")
  -- ...and the third of them: a page it says to go and read. The same
  -- colour as the other two, because all three are one kind of thing --
  -- a reference out of the comment -- and underlined as well, because
  -- that is what a link has looked like since before any of this: the
  -- words are the author's own sentence, and the line under them is
  -- what says they are also a door.
  --
  -- Copied from `DiagnosticInfo` rather than linked to it, because a
  -- link is all or nothing: a group that links somewhere takes that
  -- group's attributes entire, and there is nowhere to hang the
  -- underline. `Underlined` on its own was the other half of this and
  -- carried no colour at all.
  local info = vim.api.nvim_get_hl(0, { name = "DiagnosticInfo", link = false })
  vim.api.nvim_set_hl(0, "NemetonLink", {
    fg = info.fg,
    ctermfg = info.ctermfg,
    underline = true,
    cterm = { underline = true },
    default = true,
  })
  -- A heading inside a comment, drawn without the hashes that made it
  -- one. The colour a name is drawn in, because a terminal has no
  -- larger type and this plugin already spends that colour on "the
  -- line you are looking for".
  -- A reaction on a note, and one of your own. Both are a count beside
  -- a picture, and the picture carries its own colour whatever this
  -- says -- an emoji is drawn from the font's own palette. So what is
  -- left to colour is the number, and the only thing worth saying with
  -- it is which of the rows you are already in: the key that adds a
  -- reaction takes yours back, and yours are the ones it would.
  link("NemetonReaction", "Comment")
  link("NemetonReactionMine", "DiagnosticInfo")
  link("NemetonHeading", "Title")
  -- ...and which level of one, which the hashes used to say and now
  -- nothing does. A terminal cannot draw a bigger word, so the six are
  -- told apart the way the rest of this window tells anything apart:
  -- loud at the top and quiet at the bottom. Underlined and bold is a
  -- title with a rule under it; bold is a section; plain is the colour
  -- alone; and the three below that are the same fall in the quiet
  -- colour, which is where a heading nested that deep in a review
  -- comment belongs.
  --
  -- Copied rather than linked, for the reason `NemetonLink` is: a group
  -- that links somewhere takes that group's attributes entire, and
  -- there is nowhere to hang the weight. From the two groups above
  -- rather than from what they link to, so that a scheme which has
  -- said what a heading in here looks like has said it for all six.
  local title = vim.api.nvim_get_hl(0, { name = "NemetonHeading", link = false })
  local comment = vim.api.nvim_get_hl(0, { name = "NemetonMeta", link = false })
  local LEVELS = {
    { title, { bold = true, underline = true } },
    { title, { bold = true } },
    { title, {} },
    { title, { italic = true } },
    { comment, { bold = true } },
    { comment, { italic = true } },
  }
  for level, want in ipairs(LEVELS) do
    local hl = { fg = want[1].fg, ctermfg = want[1].ctermfg, cterm = {}, default = true }
    for attr in pairs(want[2]) do
      hl[attr], hl.cterm[attr] = true, true
    end
    vim.api.nvim_set_hl(0, "NemetonHeading" .. level, hl)
  end
  -- The weight a word was written with. No colour of their own and none
  -- wanted: extmarks compose, so what these do is put a weight on
  -- whatever colour the word was already drawn in -- dim inside a
  -- settled thread, blue and underlined inside a link, the language's
  -- own inside a suggestion.
  local function weight(name, attr)
    vim.api.nvim_set_hl(0, name, { [attr] = true, cterm = { [attr] = true }, default = true })
  end
  weight("NemetonBold", "bold")
  weight("NemetonItalic", "italic")
  weight("NemetonStrike", "strikethrough")
  -- ...and a code span, which is a colour and not a weight: it is the
  -- one piece of a comment that is quoting something rather than saying
  -- it, and `String` is the colour an editor already draws quoted text
  -- in.
  link("NemetonCode", "String")
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
  link("NemetonChanged", "Changed")
  link("NemetonOk", "DiagnosticOk")
  link("NemetonBad", "DiagnosticError")
  link("NemetonBusy", "DiagnosticWarn")
  -- The same colour as a job that has not finished, because it is the
  -- same fact about a different thing: this is happening, wait.
  link("NemetonSending", "DiagnosticWarn")
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
  local last = vim.api.nvim_buf_line_count(bufnr)
  for _, h in ipairs(hls) do
    -- `eol` is a ground rather than a colour of words: it runs to the
    -- right-hand edge of the window instead of stopping where the text
    -- does. `hl_eol` only carries past the end of a line for a
    -- highlight that reaches the end of it, so the span is given the
    -- next row rather than a column -- clamped, because the last line
    -- of a buffer has no next row to be given.
    vim.api.nvim_buf_set_extmark(bufnr, M.ui_ns, h.row, h.col, {
      end_row = h.eol and math.min(h.row + 1, last) or nil,
      end_col = h.eol and 0 or h.end_col,
      hl_group = h.hl,
      hl_eol = h.eol or nil,
    })
  end
end

--- A conversation as lines and highlight spans, for the windows that
--- draw one: what `threads.flatten` returns, on the ground a
--- conversation is read on.
---
--- The ground is what makes a comment look like one. Without it a
--- thread is words on the window's own background -- the same
--- background as the blank line between two threads and as everything
--- else in the float -- and four notes in a row read as one wall of
--- prose that has to be parsed to be divided. On a ground, each is a
--- block with edges, and the head of each note is a band across the top
--- of it.
---
--- Edge to edge, and by `hl_eol` rather than by padding the text: these
--- windows are real buffers, and a line padded to the width of the
--- window is a line of trailing whitespace in one.
---
--- `settled` says which lines are part of a conversation at all, and
--- which of the two grounds each is on: "open", "settled", or nil for a
--- line that is the window's own -- a heading, a file name, the blank
--- between two threads. One string for the whole of a block, or a table
--- of one per line for a window that draws its own furniture among
--- them.
---
--- Third, and passed through rather than worked out here: where each of
--- the things a comment points at ended up. See `threads.flatten`,
--- which is what these windows would be calling if they did not need a
--- ground under the words.
function M.shade_lines(rendered, first_row, settled)
  local lines, hls, refs = {}, {}, {}
  for i, chunks in ipairs(rendered) do
    -- Spelled out rather than as `and`/`or`: a table whose entry for
    -- this line is nil falls through to the table itself, which is
    -- truthy, and every heading and blank in the window comes out on a
    -- ground it is not part of.
    local want = settled
    if type(settled) == "table" then
      want = settled[i]
    end
    local base = want and ground_for(want, chunks.reply) or nil
    -- What the front of an answer's line is on: the thread's ground,
    -- because the rail belongs to the thread and not to the answer.
    local outer = base and chunks.inset and ground_for(want, false) or nil
    -- A line that brought a ground of its own -- quoted code, half of a
    -- suggestion, the head of a note -- is drawn on that instead, the
    -- whole line and the rail included.
    --
    -- ...unless the line says the band belongs to the chunks that asked
    -- for it rather than to the line: a suggestion drawn in a box, where
    -- the rules are what say where the half of the diff stops.
    if base and not chunks.contained then
      for _, chunk in ipairs(chunks) do
        base = band_of(chunk) or base
      end
    end
    local text = ""
    for _, chunk in ipairs(chunks) do
      if chunk.ref then
        table.insert(refs, {
          row = (first_row or 0) + i - 1,
          col = #text,
          end_col = #text + #chunk[1],
          ref = chunk.ref,
        })
      end
      text = text .. chunk[1]
    end
    local row = (first_row or 0) + i - 1
    -- The ground first and across the whole line: extmarks compose, and
    -- what goes over this is the colour of the words on it.
    if base then
      local from = outer and math.min(chunks.inset, #text) or 0
      if outer and from > 0 then
        table.insert(hls, { row = row, col = 0, end_col = from, hl = outer })
      end
      table.insert(hls, { row = row, col = from, end_col = #text, hl = base, eol = true })
    end
    local at = 0
    for _, chunk in ipairs(chunks) do
      local group = chunk[2]
      if type(group) == "table" then
        -- The colour it asked for, on the band it asked for -- which by
        -- now is the whole line's, so it is the same call either way.
        group = group[2]
      end
      -- The band this chunk brought, where the line handed them out
      -- chunk by chunk.
      local own = chunks.contained and band_of(chunk) or nil
      if group then
        -- A chunk that straddles the inset is two spans: the same
        -- colour, on the two grounds it lies across. The head of an
        -- answer is one -- the rail and the arrow arrive together.
        for _, part in ipairs(split_at(at, at + #chunk[1], outer and chunks.inset)) do
          local under = own or (part.outer and outer or base)
          table.insert(hls, {
            row = row,
            col = part.from,
            end_col = part.to,
            hl = under and on_ground(group, under) or group,
          })
        end
      end
      -- The weight the word was written with, on top of whatever colour
      -- it came out in and never through `on_ground`: these groups
      -- carry no colour and no background, which is the whole of what
      -- lets a bold word stay the colour the sentence around it is.
      for _, weight in ipairs(chunk.style or {}) do
        table.insert(hls, { row = row, col = at, end_col = at + #chunk[1], hl = weight })
      end
      at = at + #chunk[1]
    end
    table.insert(lines, text)
  end
  return lines, hls, refs
end

function M.clear(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  end
end

function M.clear_current()
  if reading and vim.api.nvim_buf_is_valid(reading) then
    vim.api.nvim_buf_clear_namespace(reading, M.reading_ns, 0, -1)
  end
  reading = nil
end

--- Marks rows `from`..`to` of `bufnr` -- 1-based and inclusive -- as
--- the lines the conversation now being read was written against.
---
--- What the gutter is missing when a thread is read beside the file
--- rather than under it. A comment written over a selection is about
--- several lines and anchored to the last of them, which is the only
--- one carrying a bubble: nothing on the code says where the quotation
--- in the pane begins. The rail that runs down the thread in there runs
--- up the gutter out here, in the colour of the same state, so the two
--- are the same edge of the same block.
---
--- Under the thread's own marker rather than over it: on the anchored
--- line both are in the gutter, a sign column one cell wide draws the
--- higher priority alone, and between "there is a conversation here"
--- and "and it starts three lines up" the first is the one to keep. A
--- wider one (`signcolumn=auto:2`) draws both.
function M.current(bufnr, from, to, hl)
  M.clear_current()
  local glyph = config.comments.sign_span
  local ground_it = config.comments.reading_ground ~= false
  if (not ground_it and (not glyph or glyph == "")) or not vim.api.nvim_buf_is_valid(bufnr) then
    return 0
  end
  local last = vim.api.nvim_buf_line_count(bufnr)
  local drawn = 0
  for row = math.max(from, 1), math.min(to, last) do
    vim.api.nvim_buf_set_extmark(bufnr, M.reading_ns, row - 1, 0, {
      sign_text = (glyph and glyph ~= "") and glyph or nil,
      sign_hl_group = (glyph and glyph ~= "") and (hl or "NemetonSignOpen") or nil,
      -- ...and the band the gutter cannot draw: the anchor line keeps
      -- its bubble, a thread about one line has no line above it to put
      -- a rail on, and a sign column can be off altogether. The ground
      -- says it in all three.
      line_hl_group = ground_it and "NemetonReading" or nil,
      priority = 15,
    })
    drawn = drawn + 1
  end
  reading = bufnr
  return drawn
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
--- The gutter, and at the end of the line the first words of what is on
--- it where `comments.virt_text` asks for them. The conversation itself
--- is not drawn here: it is read in a window of its own
--- |nemeton-pane-window|, where it has a width to be wrapped to and a
--- cursor that can be put in it.
function M.render(bufnr, by_line, opts)
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

      if config.comments.virt_text then
        local first = shown[1].notes[1]
        local summary = vim.split(threads.drawn(first.body), "\n", { plain = true })[1] or ""
        local count = #shown > 1 and (" (+%d)"):format(#shown - 1) or ""
        mark.virt_text = {
          { "  " .. first.author .. count .. ": ", "NemetonAuthor" },
          -- Dim: this one is a glance at what is there, not the reading
          -- of it, and it sits at the end of a line of code.
          { summary:sub(1, 60), "NemetonMeta" },
        }
        mark.virt_text_pos = "eol"
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
