-- Discussions as the rest of the plugin wants them.
--
-- What GitLab returns is a flat list of discussions, each a list of
-- notes, each note carrying a copy of the position of the thread it
-- belongs to. What a reviewer wants is "which threads are on line 42 of
-- this file". This module is the whole of that translation, and it is
-- pure -- tables in, tables out, no editor state -- so it is the part
-- that can be tested without a forge.

local config = require("nemeton.config")

local M = {}

--- A note is "real" if a person wrote it. GitLab records label changes,
--- assignments and branch pushes as notes too; they belong on the
--- activity feed, not in the gutter next to someone's code.
local function is_system(note)
  return note.system == true
end

--- Where a thread lives. Prefers the new side, because that is the side
--- the reviewer has checked out and is looking at; a thread against a
--- deleted line has only an old side, and is kept with `side = "old"` so
--- the caller can say so rather than silently dropping it.
local function anchor(position)
  if not position or position.position_type ~= "text" then
    return nil
  end
  -- A multi-line comment reports its span in `line_range`; the line it
  -- is drawn against is the last one, which is where the reviewer's
  -- cursor was when they wrote it. The first is kept as well -- not to
  -- draw the marker anywhere else, but because "the code this comment
  -- is about" is the whole of the span and not just the row it ends on.
  local range = position.line_range or {}
  local range_end = range["end"]
  local new_line = (range_end and range_end.new_line) or position.new_line
  local old_line = (range_end and range_end.old_line) or position.old_line
  if new_line then
    return {
      path = position.new_path or position.old_path,
      line = new_line,
      first = (range.start and range.start.new_line) or new_line,
      side = "new",
    }
  end
  if old_line then
    return {
      path = position.old_path or position.new_path,
      line = old_line,
      first = (range.start and range.start.old_line) or old_line,
      side = "old",
    }
  end
  -- A file-level comment: a position, but no line on either side.
  return nil
end

--- One discussion, flattened. Returns nil for a thread with nothing a
--- person said in it.
local function thread_of(discussion)
  local notes = {}
  local resolvable, resolved = false, true
  for _, note in ipairs(discussion.notes or {}) do
    if not is_system(note) then
      table.insert(notes, {
        id = note.id,
        author = (note.author and (note.author.username or note.author.name)) or "?",
        body = note.body or "",
        created_at = note.created_at,
      })
      if note.resolvable then
        resolvable = true
        if not note.resolved then
          resolved = false
        end
      end
    end
  end
  if #notes == 0 then
    return nil
  end

  local first = (discussion.notes or {})[1]
  local place = anchor(first and first.position)
  return {
    id = discussion.id,
    notes = notes,
    resolvable = resolvable,
    -- GitLab's two kinds of overall comment. One posted on its own is
    -- an "individual note" and cannot be replied to -- the API refuses
    -- it -- while one started as a thread can. The difference is
    -- invisible on the page and has to be carried here, because it
    -- decides whether the reply key does anything.
    individual_note = discussion.individual_note == true,
    -- `resolved` only means anything on a resolvable thread; an overall
    -- comment is never resolvable and must not read as "handled".
    resolved = resolvable and resolved or false,
    path = place and place.path,
    line = place and place.line,
    first_line = place and place.first,
    side = place and place.side,
    -- The shas the thread was written against. Kept because a reply is
    -- fine without them but a *comparison* -- "is this thread still
    -- pointing at the code it was written about" -- needs them. The
    -- base as well as the head: a thread on a deleted line is against
    -- the old side of the diff, and the old side is the base.
    head_sha = first and first.position and first.position.head_sha,
    base_sha = first and first.position and first.position.base_sha,
  }
end

--- Splits the API's discussions into the ones that sit on a line and the
--- ones that sit on the merge request as a whole.
function M.parse(discussions)
  local inline, overview = {}, {}
  for _, d in ipairs(discussions or {}) do
    local t = thread_of(d)
    if t then
      table.insert(t.line and inline or overview, t)
    end
  end
  return { inline = inline, overview = overview }
end

--- The draft notes, in the same shape as the threads above, so that
--- everything that draws a conversation can draw an unsent one without
--- knowing the difference.
---
--- A draft is one note and can never be more: it has no discussion to
--- be replied into until it is sent. The author is "you" because that
--- is the only person it can be -- GitLab shows a draft note to nobody
--- else, which is the whole reason the feature is safe to use in the
--- middle of somebody else's review.
---
--- ...except an unsent *reply*, which does have a discussion. GitLab
--- files it with your other drafts rather than under the note it
--- answers, and carries the discussion it belongs to: `replies` is
--- those, kept apart so that `attach_drafts` can put them back where
--- they were written. Left here they would be comments on the merge
--- request as a whole -- an answer to a question about line 42, filed
--- under "on the merge request", where nobody reading the thread would
--- ever find it.
function M.parse_drafts(drafts)
  local inline, overview, replies = {}, {}, {}
  for _, d in ipairs(drafts or {}) do
    local into = d.discussion_id or d.in_reply_to_discussion_id
    local place = anchor(d.position)
    local t = {
      id = d.id,
      draft = true,
      notes = { { id = d.id, author = "you", body = d.note or "" } },
      resolvable = false,
      resolved = false,
      individual_note = false,
      path = place and place.path,
      line = place and place.line,
      first_line = place and place.first,
      side = place and place.side,
      head_sha = d.position and d.position.head_sha,
      base_sha = d.position and d.position.base_sha,
    }
    if into then
      table.insert(replies, { id = d.id, discussion_id = into, body = d.note or "" })
    else
      table.insert(t.line and inline or overview, t)
    end
  end
  return { inline = inline, overview = overview, replies = replies }
end

--- Puts the unsent replies back into the threads they answer, as the
--- last note of each -- which is where they will be once the review
--- goes out, and where the person reading the argument looks for them.
---
--- In place, and safe to run again: the threads are rebuilt from the
--- API on every refresh, so nothing here accumulates.
function M.attach_drafts(list, replies)
  if not (list and replies and #replies > 0) then
    return
  end
  local by_id = {}
  for _, t in ipairs(list) do
    by_id[t.id] = t
  end
  for _, d in ipairs(replies) do
    local t = by_id[d.discussion_id]
    if t then
      table.insert(t.notes, { id = d.id, author = "you", body = d.body, draft = true })
    end
  end
end

--- Whether anything in a thread is yours and not sent yet -- the thread
--- itself, or a reply folded into it. What the gutter marks with a
--- pencil: an unsent comment is a state of you rather than of the
--- conversation, and it is owed an action wherever in the thread it is.
function M.unsent(thread)
  if thread.draft then
    return true
  end
  for _, note in ipairs(thread.notes or {}) do
    if note.draft then
      return true
    end
  end
  return false
end

--- by_file[path][line] = { thread, ... }, in the order they were opened.
function M.index(inline)
  local by_file = {}
  for _, t in ipairs(inline) do
    local lines = by_file[t.path]
    if not lines then
      lines = {}
      by_file[t.path] = lines
    end
    local at = lines[t.line]
    if not at then
      at = {}
      lines[t.line] = at
    end
    table.insert(at, t)
  end
  return by_file
end

--- How many lines above its own a thread reaches: 0 for a comment on
--- one line, and the rest of the span for a comment written across
--- several. The three windows that draw a thread all have to ask a file
--- for "the lines this is about", and this is the one number they need
--- to do it.
function M.span(thread)
  return math.max((thread.line or 0) - (thread.first_line or thread.line or 0), 0)
end

--- The body of a suggestion comment: GitLab's fenced block, with the
--- lines it would replace already in it.
---
--- `suggestion:-0+N` means "this line and the N below it", so a comment
--- anchored at the first line of the selection covers the whole of it.
--- The lines start out as they are rather than empty: a suggestion is
--- an edit of what is there, and retyping four lines to change one word
--- is how a reviewer decides not to suggest anything.
function M.suggestion_body(lines)
  local out = { ("```suggestion:-0+%d"):format(math.max(#lines - 1, 0)) }
  vim.list_extend(out, lines)
  table.insert(out, "```")
  return table.concat(out, "\n")
end

--- Which lines of which files the merge request touches, and what each
--- one was numbered on the other side of the diff.
---
--- `map[new_path].lines[n]` is the old line number of new line `n` when
--- the line is unchanged, `true` when the line was added, and nil when
--- the diff does not cover it at all. The three are the three cases a
--- position has to spell differently, which is the whole reason this
--- exists -- see `M.position`.
function M.line_map(changes)
  local list = changes and changes.changes or changes
  if type(list) ~= "table" then
    return nil
  end
  local map = {}
  for _, change in ipairs(list) do
    local path = change.new_path or change.old_path
    if path then
      local lines = {}
      -- `in_hunk` rather than "have we seen a line number yet": a file
      -- added by the merge request has a hunk header of `@@ -0,0 +1,N`,
      -- its old side starts at zero, and reading that zero as "no hunk
      -- yet" leaves every line of every new file out of the map -- and
      -- so refuses every comment on one.
      local in_hunk = false
      local old, new = 0, 0
      -- Split rather than iterated with a pattern: a blank context
      -- line arrives as "" in some diffs, and a `[^\n]*` match would
      -- also hand back an empty string between every pair of real
      -- lines -- which counts every line of the file twice.
      local body = vim.split(tostring(change.diff or ""), "\n", { plain = true })
      -- The diff ends in a newline, and splitting on it leaves one
      -- empty string past the end that is not a line of anything.
      if body[#body] == "" then
        table.remove(body)
      end
      for _, line in ipairs(body) do
        local a, b = line:match("^@@%s+%-(%d+)%D*%d*%s+%+(%d+)")
        if a then
          in_hunk = true
          old, new = tonumber(a), tonumber(b)
        elseif line:sub(1, 3) == "+++" or line:sub(1, 3) == "---" or line:sub(1, 1) == "\\" then -- luacheck: ignore
          -- a header, or "\ No newline at end of file"
        elseif in_hunk and line:sub(1, 1) == "+" then
          lines[new] = true
          new = new + 1
        elseif in_hunk and line:sub(1, 1) == "-" then
          old = old + 1
        elseif in_hunk and (line == "" or line:sub(1, 1) == " ") then
          lines[new] = old
          old, new = old + 1, new + 1
        end
      end
      -- A file with nothing in its map is a file whose diff did not
      -- arrive: GitLab caps the size of what `/changes` returns and
      -- sends the ones past the cap with an empty `diff`. Left out
      -- entirely, so that a comment on it is attempted rather than
      -- refused on the strength of a diff nobody has seen.
      if next(lines) then
        map[path] = { old_path = change.old_path or path, lines = lines }
      end
    end
  end
  return map
end

--- The position payload for a NEW thread on `line` of `path`, or nil
--- when the merge request's diff does not reach that line.
---
--- The new side, because you are commenting on a buffer you have
--- checked out -- but *which* fields go with it is not one answer.
--- GitLab turns a position into a "line code", and it can only do that
--- for a line it can find in the diff:
---
---   an added line   new_line alone -- there is no old line to name
---   an unchanged one BOTH lines; with only new_line GitLab answers
---                   `line_code ["can't be blank", "must be a valid
---                   line code"]` and rejects the note
---   anything else   not in the diff, and not commentable at all
---
--- `map` is `M.line_map`'s, and is optional: without it this sends what
--- it always sent, which is right for an added line and is the best
--- guess available when the diff could not be fetched.
---
--- `old_path` goes alongside `new_path` either way -- GitLab wants both,
--- and refuses the note outright if either is missing.
function M.position(diff_refs, path, line, map)
  local file = map and map[path]
  local pos = {
    base_sha = diff_refs.base_sha,
    start_sha = diff_refs.start_sha,
    head_sha = diff_refs.head_sha,
    position_type = "text",
    new_path = path,
    old_path = (file and file.old_path) or path,
    new_line = line,
  }
  if not file then
    return pos
  end
  local was = file.lines[line]
  if was == nil then
    return nil
  end
  if was ~= true then
    pos.old_line = was
  end
  return pos
end

--- "2d", "4h", "12 Mar" -- how long ago a note was written.
---
--- Relative while it is recent and absolute once it is not, because the
--- two answer different questions. Under a week, what matters is
--- whether the conversation is still warm; past that, "63d" is a number
--- nobody converts back into a date, and the date is what you wanted.
---
--- GitLab timestamps are UTC. `os.time` reads a broken-down time as
--- local, so `now` is built the same way -- `os.date("!*t")` -- and the
--- offset each of them is wrong by is the same one, and cancels.
function M.age(iso, now)
  if type(iso) ~= "string" then
    return nil
  end
  local y, mo, d, h, mi, sec = iso:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then
    return nil
  end
  local at = os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
    sec = tonumber(sec),
    isdst = false,
  })
  now = now or os.time(os.date("!*t"))
  local since = now - at
  if since < 60 then
    return "now"
  elseif since < 3600 then
    return ("%dm"):format(since / 60)
  elseif since < 86400 then
    return ("%dh"):format(since / 3600)
  elseif since < 7 * 86400 then
    return ("%dd"):format(since / 86400)
  end
  local then_ = os.date("!*t", at)
  local fmt = then_.year == os.date("!*t", now).year and "!%-d %b" or "!%-d %b %Y"
  return os.date(fmt, at)
end

--- The longest prefix of `s` that fits in `width` columns, whole
--- characters only.
local function fit(s, width)
  local out, w = "", 0
  for i = 0, vim.fn.strchars(s) - 1 do
    local ch = vim.fn.strcharpart(s, i, 1)
    local cw = vim.fn.strdisplaywidth(ch)
    if w + cw > width then
      -- A first character wider than the room it is given goes in
      -- anyway; otherwise nothing ever fits and the cut never ends.
      if out == "" then
        out = ch
      end
      break
    end
    out, w = out .. ch, w + cw
  end
  return out
end

--- `text`, cut into lines no wider than `width` columns.
---
--- Because a comment that runs off the right-hand edge cannot be read
--- at all where it is mostly drawn: a virtual line takes no `wrap` and
--- no horizontal scroll -- `zl` moves the file underneath and leaves
--- the virtual text where it was -- so whatever is past the edge of the
--- window is simply gone. A comment is prose somebody else wrote at
--- whatever width they had, and this is the only place it can be
--- broken.
---
--- Broken at spaces, and inside a word only when the word is wider than
--- a whole line on its own -- a URL in a narrow split. Cutting one is
--- ugly; the alternative is a line that stops in the middle and does
--- not say so.
---
--- The line's own leading whitespace survives on the first piece, so an
--- indented bullet keeps the shape it was written in; the pieces after
--- it start at the rail, which is where a continuation is least likely
--- to read as a new point.
local function wrap(text, width)
  if not width or width < 1 or vim.fn.strdisplaywidth(text) <= width then
    return { text }
  end
  local out = {}
  local line, empty = text:match("^%s*"), true
  for space, word in text:gmatch("(%s*)(%S+)") do
    local candidate = empty and (line .. word) or (line .. space .. word)
    if vim.fn.strdisplaywidth(candidate) <= width then
      line, empty = candidate, false
    else
      if not empty then
        table.insert(out, line)
      end
      -- A word with no line wide enough to hold it, cut into ones that
      -- are.
      while vim.fn.strdisplaywidth(word) > width do
        local head = fit(word, width)
        table.insert(out, head)
        word = word:sub(#head + 1)
      end
      line, empty = word, false
    end
  end
  if not empty then
    table.insert(out, line)
  end
  return #out > 0 and out or { text }
end

--- A thread as coloured lines, for the peek float, the overall-notes
--- window and the expanded in-buffer view. One shape for all three, so
--- the three never drift apart.
---
--- Each line is a list of `{ text, highlight }` chunks rather than a
--- string, for two reasons. Virtual lines are drawn from exactly this
--- shape, so the in-buffer view needs no translation at all; and a note
--- is two things at once -- who said it, which you skim, and what they
--- said, which you read -- so they must not arrive as one colour.
---
--- A rail down the left rather than a box around the outside: a box has
--- to close, a closing rule has to know how wide the window is, and the
--- same thread is drawn into three windows of three different widths.
--- The rail carries the same boundary and needs no width to do it.
---
--- The first note sits against the rail and every reply to it is
--- indented, so that a line carrying two conversations reads as two
--- conversations. The rail runs unbroken through a thread; what breaks
--- it -- a blank line -- is what separates one thread from the next.
--- `opts.replaced(above, below)` -- the lines a suggestion would
--- replace, counted from the line the thread sits on. Given, a
--- suggestion is drawn as the diff it is; missing -- the overall-notes
--- window, where there is no file to read -- it is drawn as the block
--- of new lines alone.
---
--- `opts.was` -- the lines the thread was written against, when they
--- are not the lines it now sits on. Drawn above the first note; see
--- `session.was`, which is what decides that they differ.
---
--- `opts.width` -- how many columns the caller has to draw into, rail
--- included. Given, the notes are wrapped to fit; missing, they are
--- returned as they were written, which is what the one-line-per-thread
--- index wants.
function M.render(thread, opts)
  opts = opts or {}
  local out = {}
  -- The width a line of this thread may reach. The window is one half
  -- of it; `config.comments.wrap` is the other -- prose set across a
  -- 200-column editor is prose nobody's eye can get back from the end
  -- of a line to the start of the next -- and the narrower of the two
  -- wins.
  local limit = opts.width
  if limit and config.comments.wrap then
    limit = math.min(limit, config.comments.wrap)
  end
  -- The rail is the one part of a thread that is a colour before it is
  -- anything else -- it runs the height of the block and carries no
  -- words -- so it is where the state goes: unsent, settled, or still
  -- owed an answer. The resolved colour rather than the dim one it used
  -- to be: "settled" is a verdict, and it is the same green the tick at
  -- the end of the first line is drawn in and the same the ground under
  -- the block is tinted towards.
  local rail = {
    config.comments.rail .. " ",
    thread.draft and "NemetonDraft" or (thread.resolved and "NemetonResolved" or "NemetonSignOpen"),
  }
  -- A resolved thread is history: it is dimmed whole, and the tick is
  -- the only part of it that keeps a colour of its own.
  local body_hl = thread.resolved and "NemetonMeta" or "NemetonThread"

  -- A reply is indented under the note it answers. Two threads on one
  -- line are drawn one after the other, and without this the second
  -- thread's opening note and the first thread's third reply arrive in
  -- the same shape: the reviewer has to read both to find out which
  -- argument they are in. The first note of a thread starts at the
  -- rail, every answer to it is set in.
  local indent = config.comments.reply_indent or ""
  local mark = config.comments.reply_mark or ""

  -- One line of text, wrapped and put down behind `lead`. `sign` is the
  -- "+ " or "- " a suggestion's lines carry, and the "was " on a line
  -- of code that has changed since: it belongs to the first piece only,
  -- and the pieces after it are indented past where it would be, so a
  -- wrapped line stays inside the column its marker put it in rather
  -- than reading as another line with no marker at all.
  local function body(lead, text, hl, sign)
    sign = sign or ""
    local pad = (" "):rep(vim.fn.strdisplaywidth(sign))
    local room = limit and (limit - vim.fn.strdisplaywidth(lead) - #pad)
    for j, piece in ipairs(wrap(text, room)) do
      table.insert(out, { { lead, rail[2] }, { (j > 1 and pad or sign) .. piece, hl } })
    end
  end

  -- What the thread is *about*, when that is no longer what is on the
  -- line it is drawn against. A comment is half of a pair and the code
  -- is the half that moves: somebody pushes, or you edit the file while
  -- you are reading it, and the note is still on line 42 while line 42
  -- has come to say something else. Drawn above the first word anybody
  -- said, because it is what they were looking at when they said it.
  --
  -- In the colour a line taken away is drawn in, which is what this is:
  -- code that was there when the comment was written and is not there
  -- now.
  for i, line in ipairs(opts.was or {}) do
    body(rail[1], line, "NemetonRemoved", i == 1 and "was  " or "     ")
  end

  -- One entry per thread rather than the whole argument: an index of
  -- what has been said is read to decide what to open, and the answers
  -- to a note are read after it is opened. The heading carries what a
  -- list needs and the block does not -- where the thread sits, and
  -- whether it is over in so many words rather than in a tick.
  local notes = opts.summary and { thread.notes[1] } or thread.notes

  for i, note in ipairs(notes) do
    -- Every line of a reply, its heading included, carries the rail and
    -- then the indent -- so the rail stays a straight edge and the
    -- nesting happens inside it. The line the reply opens with spends
    -- that indent on the mark instead: the indent is what holds the
    -- shape, the mark is what names it.
    local lead = i > 1 and (rail[1] .. indent) or rail[1]
    if i > 1 then
      -- The rail alone, unpadded: a separator that carries a trailing
      -- space is trailing whitespace in the two windows that are real
      -- buffers.
      table.insert(out, { { config.comments.rail, rail[2] } })
    end
    local head =
      { { i > 1 and (rail[1] .. mark) or lead, rail[2] }, { note.author, "NemetonAuthor" } }
    local age = M.age(note.created_at)
    if age then
      table.insert(head, { " · " .. age, "NemetonMeta" })
    end
    if i == 1 and opts.summary and thread.path then
      table.insert(head, { " · ", "NemetonMeta" })
      table.insert(head, {
        thread.line and ("%s:%d"):format(thread.path, thread.line) or thread.path,
        "NemetonPath",
      })
    end
    if note.draft or (i == 1 and thread.draft) then
      table.insert(head, { " · unsent", "NemetonDraft" })
    end
    if i == 1 and thread.resolved then
      table.insert(
        head,
        opts.summary and { " · ✓ resolved", "NemetonResolved" } or { "  ✓", "NemetonResolved" }
      )
    end
    if i == 1 and opts.summary and #thread.notes > 1 then
      -- How much of the argument is not on the screen. A thread with
      -- answers in it is a thread to open; one with none is one you
      -- have read by reading this line.
      table.insert(head, {
        ("  +%d"):format(#thread.notes - 1),
        thread.resolved and "NemetonMeta" or "NemetonSignOpen",
      })
    end
    table.insert(out, head)
    -- A GitLab suggestion is a fenced block that the forge can apply
    -- with a button, and it is the one part of a comment that is not
    -- prose: it is the code that would replace what you are looking at.
    -- Drawn as an addition, in the colour the editor already uses for
    -- one, so it reads as a diff rather than as more sentences.
    local suggesting = false
    for _, l in ipairs(vim.split(note.body, "\n", { plain = true })) do
      local fence = l:match("^%s*```(.*)$")
      if fence and suggesting then
        suggesting = false
        body(lead, l, "NemetonMeta")
      elseif fence and fence:match("^suggestion") then
        suggesting = true
        body(lead, l, "NemetonMeta")
        -- What it would replace, above what it would put there: a
        -- suggestion is a diff, and half a diff is a block of code with
        -- nothing to compare it to.
        local above = tonumber(fence:match("%-(%d+)")) or 0
        local below = tonumber(fence:match("%+(%d+)")) or 0
        for _, gone in ipairs(opts.replaced and opts.replaced(above, below) or {}) do
          body(lead, gone, "NemetonRemoved", "- ")
        end
      elseif suggesting then
        body(lead, l, "NemetonAdded", "+ ")
      else
        body(lead, l, body_hl)
      end
    end
  end
  return out
end

--- The same lines as plain strings, plus the highlights to paint over
--- them -- for the two surfaces that are real buffers rather than
--- virtual text. Rows are 0-based and offset by `first_row`; columns are
--- byte offsets, which is what extmarks want.
function M.flatten(rendered, first_row)
  local lines, hls = {}, {}
  for i, chunks in ipairs(rendered) do
    local text = ""
    for _, chunk in ipairs(chunks) do
      if chunk[2] then
        table.insert(hls, {
          row = (first_row or 0) + i - 1,
          col = #text,
          end_col = #text + #chunk[1],
          hl = chunk[2],
        })
      end
      text = text .. chunk[1]
    end
    table.insert(lines, text)
  end
  return lines, hls
end

return M
