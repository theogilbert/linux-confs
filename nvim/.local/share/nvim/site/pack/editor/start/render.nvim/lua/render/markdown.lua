-- Markdown, told from how it was typed.
--
-- A parser and nothing else -- strings in, tables out, no editor state
-- and no colours of its own: what comes out names the groups the
-- caller gave it, and the drawing is `render.draw`'s. Two shapes:
--
--   `M.blocks(lines, opts)`  the text as the blocks it is written in:
--                            prose, a heading, a citation, a table, a
--                            list item, a fence, a formula.
--   `M.inline(line, opts)`   one line as the runs it is drawn as, each
--                            carrying in `ref` what it points at --
--                            which is what a key that follows a link
--                            reads -- and in `style` the weight it was
--                            written with.
--
-- Deliberately a subset. A markdown implementation is a fortnight, and
-- every part of one that is not the parts people write is a part that
-- can be wrong. What is not recognised is drawn as it was typed.
--
-- `opts` is the same table for both, and every field may be left out:
--
--   links, styles, math,       which readings are made at all; each
--   headings, tables,          true unless it is `false`
--   citations, lists
--   groups                     `{ bold, italic, strike, code, math,
--                              link }`, the highlight each is drawn in
--   link(url, words, image)    a link the caller knows better than
--                              "a page": `{ text, hl, ref }` to draw it
--                              so, nil for the ordinary reading
--   url(url)                   the same, for a URL written on its own
--   claims                     functions `(text, claim)` run after the
--                              rest, for what this module has never
--                              heard of -- `#12`, `@name` -- where
--                              `claim(from, to, drawn, hl, ref)` takes
--                              bytes nothing has taken yet
--   fence(block)               a fence the caller reads as something
--                              else -- a block to put in its place, or
--                              nil

local M = {}

M.GROUPS = {
  bold = "RenderBold",
  italic = "RenderItalic",
  strike = "RenderStrike",
  code = "RenderCode",
  math = "RenderMath",
  link = "RenderLink",
}

--- Whether a reading is on: everything is, unless it was turned off.
local function on(opts, what)
  return opts[what] ~= false
end

--- Which sort of link a URL is: a page anywhere, or a path -- to a file
--- beside this one, or to a page on the site the text was written for.
local function where(url)
  return url:match("^%a[%w+.-]*://") and "url" or "path"
end

-- The markers a comment is emphasised with, longest first: `***` is one
-- marker and not a `*` beside a `**`, and a scan that took the short one
-- first would leave a lone asterisk in the middle of somebody's
-- sentence.
--
-- A single `~` as well as two, because that is what GitHub and GitLab
-- both do: `~was~` is struck through, one tilde or two. A `~` in front
-- of a path is a single tilde too, and stays what it is for the reason
-- a lone `*` does: an opener is followed by something and a closer
-- follows something.
--
-- The weights are names here and groups only once a caller has said
-- which groups it draws them in (`opts.groups`).
local EMPHASIS = {
  { "***", { "bold", "italic" } },
  { "___", { "bold", "italic" } },
  { "**", { "bold" } },
  { "__", { "bold" } },
  { "~~", { "strike" } },
  { "*", { "italic" } },
  { "_", { "italic" } },
  { "~", { "strike" } },
}

-- The groups of the call being read: set by `styled`, read by `opens`.
-- One line is read at a time, and nothing in between yields.
local weights = {}

--- Whether a marker made of underscores is a marker at all.
---
--- `_` is the one of them that turns up inside words people write down:
--- `snake_case`, `TOKEN_2`, most of the URLs a review links to.
--- Markdown's own rule is that an underscore with a word character on
--- both sides emphasises nothing, and it is the rule that keeps a
--- variable name a variable name.
local function apart(text, from, to)
  if text:sub(from, from) ~= "_" then
    return true
  end
  local before = from > 1 and text:sub(from - 1, from - 1) or ""
  return not before:match("%w") or not text:sub(to + 1, to + 1):match("%w")
end

--- How far the run of `text:sub(at, at)` reaches -- `**` and `***` are
--- one delimiter each, and a scan that reads them a character at a time
--- closes `*a **b** c*` on the first half of the `**`.
local function run_of(text, at)
  local char = text:sub(at, at)
  local stop = at
  while text:sub(stop + 1, stop + 1) == char do
    stop = stop + 1
  end
  return stop
end

--- The marker opening at `at`, or nil. `taken` is the bytes a code span
--- has already claimed, where nothing is emphasis: the `*` in
--- `` `a * b` `` is a multiplication.
local function opens(text, at, taken)
  if taken[at] then
    return nil
  end
  for _, kind in ipairs(EMPHASIS) do
    local mark = kind[1]
    if text:sub(at, at + #mark - 1) == mark and apart(text, at, at + #mark - 1) then
      local groups = {}
      for _, w in ipairs(kind[2]) do
        table.insert(groups, weights[w])
      end
      return mark, groups
    end
  end
  return nil
end

--- Where the marker opened at `from` is closed, or nil for one that
--- never is -- a lone `*` in a sentence, which is a lone `*`.
---
--- Markdown's rules, cut to the two that matter here: an opener is
--- followed by something rather than by a space, and a closer follows
--- something rather than one. `2 * 3 * 4` is arithmetic and `a *b* c`
--- is emphasis, and that is the whole of the difference between them.
local function closes(text, taken, from, mark, stop)
  local after = from + #mark
  if after > stop or text:sub(after, after):match("%s") then
    return nil
  end
  local at = after
  while at <= stop do
    if text:sub(at, at) == mark:sub(1, 1) and not taken[at] then
      local last = run_of(text, at)
      if
        last - at + 1 == #mark
        and not text:sub(at - 1, at - 1):match("%s")
        and apart(text, at, last)
      then
        return at
      end
      at = last + 1
    else
      at = at + 1
    end
  end
  return nil
end

--- Every emphasised span of [from, stop], as the bytes its markers
--- occupy (`gone`) and the bytes they emphasise (`spans`).
---
--- Nested, and the inner span carries the outer's groups as well: the
--- word inside `**bold and *both* of it**` is bold and italic, and a
--- span that knew only about its own marker would come out italic
--- alone.
local function emphasis(text, taken, from, stop, groups, spans, gone)
  local at = from
  while at <= stop do
    local mark, adds = opens(text, at, taken)
    local close = mark and closes(text, taken, at, mark, stop)
    if close then
      local inner = vim.list_extend({}, groups or {})
      vim.list_extend(inner, adds)
      table.insert(gone, { at, at + #mark - 1 })
      table.insert(gone, { close, close + #mark - 1 })
      table.insert(spans, { from = at + #mark, to = close - 1, groups = inner })
      emphasis(text, taken, at + #mark, close - 1, inner, spans, gone)
      at = close + #mark
    else
      at = at + (mark and #mark or 1)
    end
  end
end

--- `runs` with the emphasis in them drawn as emphasis: the markers
--- gone, and every run they covered carrying the groups that say so in
--- `style`.
---
--- `style` and not the run's own colour, because emphasis is not one. A
--- bold word in a settled thread is dim and bold, a bold link is blue,
--- underlined and bold, and a group that carried a colour of its own
--- would flatten all three into whatever colour it was. What is drawn
--- is the colour that was already there with a weight put on top of it,
--- which is what the page does.
local function styled(runs, named)
  weights = named
  local parts, taken, at = {}, {}, 0
  for _, run in ipairs(runs) do
    if run.code then
      for i = at + 1, at + #run[1] do
        taken[i] = true
      end
    end
    at = at + #run[1]
    table.insert(parts, run[1])
  end
  local text = table.concat(parts)
  local spans, gone = {}, {}
  -- What was written down to *not* be a marker. A backslash in front of
  -- one is markdown's way of saying the character is the character, and
  -- with the marker now drawn as weight it is the only way left of
  -- writing an asterisk in a sentence about a glob. Only the three this
  -- module reads: `\n` in a sentence about a string is a `\n`, and a
  -- path with backslashes in it is a path.
  local escaped = 1
  while escaped <= #text do
    if
      text:sub(escaped, escaped) == "\\"
      and not taken[escaped]
      and text:sub(escaped + 1, escaped + 1):match("[%*_~]")
    then
      table.insert(gone, { escaped, escaped })
      taken[escaped + 1] = true
      escaped = escaped + 2
    else
      escaped = escaped + 1
    end
  end
  emphasis(text, taken, 1, #text, nil, spans, gone)
  if #gone == 0 then
    return text, runs
  end
  -- Byte by byte, because a span is worked out over the whole line and
  -- the runs it lands on were cut by something else entirely: a link is
  -- one run, and `**see [the docs](url) first**` emphasises it and the
  -- words on either side of it.
  local groups, dropped = {}, {}
  for _, span in ipairs(spans) do
    for i = span.from, span.to do
      groups[i] = span.groups
    end
  end
  for _, mark in ipairs(gone) do
    for i = mark[1], mark[2] do
      dropped[i] = true
    end
  end
  local out, drawn = {}, {}
  at = 0
  for _, run in ipairs(runs) do
    local piece, style = {}, nil
    --- What has been gathered so far, as a run of its own.
    local function keep()
      if #piece > 0 then
        table.insert(out, { table.concat(piece), run[2], ref = run.ref, style = style })
      end
      piece = {}
    end
    for i = 1, #run[1] do
      local byte = at + i
      if not dropped[byte] then
        if groups[byte] ~= style then
          keep()
          style = groups[byte]
        end
        table.insert(piece, run[1]:sub(i, i))
      end
    end
    keep()
    at = at + #run[1]
  end
  for _, run in ipairs(out) do
    table.insert(drawn, run[1])
  end
  return table.concat(drawn), out
end

--- The trailing punctuation of a URL, which is not part of it: what
--- ends a sentence a link is at the end of.
local function undotted(url)
  return url:sub(1, #url - #(url:match("[%.,;:!%?%)%]]+$") or ""))
end

-- The character references the page would decode: `&#39;` and
-- `&#x27;` by number, and the handful of names worth knowing. A name
-- not in here is left as it was typed rather than guessed at.
local ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = "\194\160" }

--- The character `&...;` stands for, or nil for one that names none.
local function entity(ref)
  local n = ref:match("^#[xX](%x+)$")
  n = n and tonumber(n, 16) or tonumber(ref:match("^#(%d+)$") or "")
  if n then
    -- Zero and the surrogates are not characters; the page draws a
    -- replacement for them, and so does this.
    if n == 0 or n > 0x10FFFF or (n >= 0xD800 and n <= 0xDFFF) then
      return "\239\191\189"
    end
    return vim.fn.nr2char(n, 1)
  end
  return ENTITIES[ref]
end

--- `text` with its character references decoded.
local function unescaped(text)
  return (text:gsub("&(#?%w+);", function(ref)
    return entity(ref)
  end))
end

M.unescaped = unescaped

--- One line as the runs it is drawn as: `{ text, hl }`, with `ref` on
--- the ones that point somewhere.
---
--- Returns the drawn text and those runs -- which concatenate back to
--- exactly it, so a caller can wrap the string and slice the colours to
--- match. The runs are nil where the line is drawn exactly as it was
--- typed with nothing on it to point at, which is most lines: a line
--- with one chunk on it is one chunk to slice, to measure and to draw.
function M.inline(text, opts)
  if type(text) ~= "string" then
    return text, nil
  end
  opts = opts or {}
  local groups = vim.tbl_extend("force", M.GROUPS, opts.groups or {})
  local found = {}

  --- Claims bytes [from, to] of the line, unless something with a
  --- better claim already has them. In the order they are looked for: a
  --- link owns the URL inside it, a URL owns whatever is at the end of
  --- it.
  local function claim(from, to, drawn, hl, ref, code)
    for _, taken in ipairs(found) do
      if from <= taken.to and to >= taken.from then
        return
      end
    end
    table.insert(found, { from = from, to = to, text = drawn, hl = hl, ref = ref, code = code })
  end

  --- The words of a link whose `[` is at `from`, as they are drawn.
  ---
  --- A code span inside them -- [`foo()`](url), which is how a link to
  --- a function is written -- was claimed already, and would refuse the
  --- link its bytes. Inside the brackets it is the link's words: the
  --- link takes them back, and is drawn as what the span says, without
  --- its backticks. One that only starts in there and runs on past the
  --- bracket is left alone, and so is the link.
  local function worded(from, label)
    local spanned = false
    for i = #found, 1, -1 do
      local span = found[i]
      if span.code and span.from > from and span.to <= from + #label then
        table.remove(found, i)
        spanned = true
      end
    end
    if spanned then
      return (M.inline(label, opts))
    end
    return unescaped(label)
  end

  --- A formula, claimed: what is inside one is TeX and not markdown --
  --- `$x_1$` has no emphasis in it. Three spellings: $`…`$, which is
  --- GitLab's own and cannot be mistaken; `$$…$$`; and `$…$`, which
  --- can -- "$5 or $10" -- and so only where a page takes it too: no
  --- space inside either `$`, and no digit straight after the closing
  --- one.
  local function formulas(spellings)
    if not on(opts, "math") then
      return
    end
    local tex = require("render.tex")
    for _, spelling in ipairs(spellings) do
      local at = 1
      while true do
        local from, to, src = text:find(spelling[1], at)
        if not from then
          break
        end
        at = to + 1
        local fits = not spelling.loose
          or (
            not src:match("%s$")
            and not text:sub(to + 1, to + 1):match("%d")
            and text:sub(from - 1, from - 1) ~= "$"
          )
        if fits and src ~= "" then
          claim(from, to, tex.render(src), groups.math, nil, true)
        end
      end
    end
  end
  -- GitLab's own spelling before the code spans, since it is made of
  -- backticks; the other two after them, since a `$` in a code span is
  -- a dollar sign.
  formulas({ { "%$`(.-)`%$" } })

  -- `` `a_b` `` first, and before anything else looks at the line: what
  -- is inside a code span is text and not markup. A URL in one is not a
  -- link to be followed, and the underscores in one are part of an
  -- identifier. Drawn as the words without the backticks, in a colour
  -- that says it is code, which is what the backticks were for.
  --
  -- A run of them closes on a run of the same length, so `` `a` `` is
  -- how you write a backtick down.
  if on(opts, "styles") then
    local at = 1
    while true do
      local from, to = text:find("`+", at)
      if not from then
        break
      end
      at = to + 1
      local close, last = text:find("`+", at)
      while close and last - close + 1 ~= to - from + 1 do
        close, last = text:find("`+", last + 1)
      end
      if close and close > to + 1 then
        -- One space either side is how a span that starts or ends with
        -- a backtick is written, and is not part of the code.
        local inside = text:sub(to + 1, close - 1)
        if inside:match("^ .* $") and inside:match("%S") then
          inside = inside:sub(2, -2)
        end
        claim(from, last, inside, groups.code, nil, true)
        at = last + 1
      end
    end
  end
  formulas({ { "%$%$(.-)%$%$" }, { "%$([^%s$][^$]-)%$", loose = true } })

  -- `[what it is called](where it goes)`, drawn as what it is called.
  --
  -- The URL is the half nobody reads and two thirds of the width: a
  -- sentence with three links in it is drawn as three hundred columns
  -- of protocol and path, wrapped across five lines, with the words
  -- somebody wrote scattered between them. The link keeps where it
  -- goes -- in `ref`, for the key that follows it -- and gives up the
  -- room.
  if on(opts, "links") then
    local at = 1
    while true do
      local from, to, label, url = text:find("%[([^%]\n]*)%]%((%S-)%)", at)
      if not from then
        break
      end
      at = to + 1
      label = worded(from, label)
      -- `![alt](src)` is a picture, which a terminal has nowhere to
      -- put: it is drawn as what its author said it was, and the `!`
      -- that made it a picture goes with the brackets.
      local image = from > 1 and text:sub(from - 1, from - 1) == "!"
      local known = opts.link and opts.link(url, label, image)
      if known then
        claim(known.from or (image and from - 1 or from), to, known.text, known.hl, known.ref)
      else
        local drawn = label
        if drawn == "" then
          drawn = image and "image" or url
        end
        claim(image and from - 1 or from, to, drawn, groups.link, {
          kind = where(url),
          text = label,
          href = url,
        })
      end
    end
  end

  -- `[words][name]`, `[name][]` and `[name]`: a link whose address is
  -- written further down the file, in a definition. Only a name that
  -- has one -- `[x]` in a sentence is otherwise a pair of brackets.
  if on(opts, "links") and opts.definitions then
    for _, shape in ipairs({ "%[([^%]\n]*)%]%[([^%]\n]*)%]", "%[([^%]\n]+)%]" }) do
      local at = 1
      while true do
        local from, to, label, name = text:find(shape, at)
        if not from then
          break
        end
        at = to + 1
        if name == nil or name == "" then
          name = label
        end
        local href = opts.definitions[vim.fn.tolower(name)]
        local after = text:sub(to + 1, to + 1)
        local image = from > 1 and text:sub(from - 1, from - 1) == "!"
        if href and after ~= "(" and after ~= ":" then
          claim(image and from - 1 or from, to, worded(from, label), groups.link, {
            kind = where(href),
            text = label,
            href = href,
          })
        end
      end
    end
  end

  -- `<https://…>`, which is markdown's way of saying "this is a link"
  -- about a URL that would be one anyway: drawn as the URL, without
  -- the brackets, which were never part of the address.
  if on(opts, "links") then
    local at = 1
    while true do
      local from, to, url = text:find("<(https?://[^>%s]+)>", at)
      if not from then
        break
      end
      at = to + 1
      claim(from, to, url, groups.link, { kind = where(url), text = url, href = url })
    end
  end

  -- ...and a URL written on its own, which is a link whose text is
  -- where it goes.
  local at = 1
  while true do
    local from, to = text:find("https?://%S+", at)
    if not from then
      break
    end
    at = to + 1
    local url = undotted(text:sub(from, to))
    local known = opts.url and opts.url(url)
    if known then
      claim(from, from + #url - 1, known.text, known.hl, known.ref)
    elseif on(opts, "links") then
      claim(from, from + #url - 1, url, groups.link, { kind = where(url), text = url, href = url })
    end
  end

  -- `&#39;` as the `'` it stands for, before anything the caller looks
  -- for: the `#39` in it is otherwise issue 39. After the code spans,
  -- inside which it is what was typed, and after the links, which
  -- decode their own words.
  at = 1
  while true do
    local from, to, ref = text:find("&(#?%w+);", at)
    if not from then
      break
    end
    at = to + 1
    local char = entity(ref)
    if char then
      claim(from, to, char)
    end
  end

  for _, more in ipairs(opts.claims or {}) do
    more(text, claim)
  end

  table.sort(found, function(a, b)
    return a.from < b.from
  end)
  local runs, cursor = {}, 1
  for _, mark in ipairs(found) do
    if mark.from > cursor then
      table.insert(runs, { text:sub(cursor, mark.from - 1) })
    end
    table.insert(runs, { mark.text, mark.hl, ref = mark.ref, code = mark.code })
    cursor = mark.to + 1
  end
  if cursor <= #text then
    table.insert(runs, { text:sub(cursor) })
  end
  if #runs == 0 then
    runs = { { text } }
  end
  -- ...and the weight the words are drawn with, which is worked out
  -- over the line as it is drawn rather than as it was typed: the
  -- asterisks around `**[the docs](url)**` are around what the link is
  -- called by the time anything can be emphasised.
  local drawn, out
  if on(opts, "styles") then
    drawn, out = styled(runs, groups)
  else
    local parts = {}
    for _, run in ipairs(runs) do
      table.insert(parts, run[1])
    end
    drawn, out = table.concat(parts), runs
  end
  if #found == 0 and out == runs then
    return text, nil
  end
  return drawn, out
end

--- A whole text as it is drawn, as one string: for a place that shows
--- it on a single line, with no room for colours and nothing to follow
--- a link with.
function M.plain(text, opts)
  if type(text) ~= "string" then
    return text
  end
  local out = {}
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    table.insert(out, (M.inline(line, opts)))
  end
  return table.concat(out, "\n")
end

--- The cells of a table row, or nil for a line that is not one.
---
--- The outer pipes are optional in markdown and usually written; either
--- way what is between them is the row. A cell is trimmed, because the
--- spaces around it are how its author lined the source up and not
--- anything they wrote.
---
--- `\|` is a pipe in a cell and not the end of it -- inside a code span
--- too, which is GitLab's reading and the only way to write `a || b`
--- in a table at all -- so the row is walked a character at a time,
--- a backslash taking the one after it with it, and the backslash in
--- front of a pipe is dropped once the cell is cut.
local function cells(line)
  local row = vim.trim(line)
  local out, from, split = {}, 1, false
  local i = 1
  while i <= #row do
    local c = row:sub(i, i)
    if c == "\\" then
      i = i + 1
    elseif c == "|" then
      split = true
      if i > 1 then
        table.insert(out, row:sub(from, i - 1))
      end
      from = i + 1
    end
    i = i + 1
  end
  if not split then
    return nil
  end
  if from <= #row then
    table.insert(out, row:sub(from))
  end
  for k, cell in ipairs(out) do
    out[k] = vim.trim((cell:gsub("\\|", "|")))
  end
  return out
end

--- The alignments a delimiter row asks for -- `:---`, `---:`, `:---:`
--- -- or nil for a row that is not one. It is the line that makes a
--- table a table: pipes on their own are a sentence about a shell.
local function alignments(line)
  local row = line and cells(line)
  if not row or #row == 0 then
    return nil
  end
  local out = {}
  for i, cell in ipairs(row) do
    local left, right = cell:match("^(:?)%-%-*(:?)$")
    if not left then
      return nil
    end
    out[i] = (left == ":" and right == ":" and "center") or (right == ":" and "right") or "left"
  end
  return out
end

--- A prose line with its hard break taken off the end of it.
---
--- A backslash at the end of a line is markdown for "and the next line
--- goes underneath this one" -- which is what is done with every line
--- anyway, since a page here is drawn as the lines it was typed in. So the mark itself is not drawn: it did its work in
--- the source, and left whole it is a stray backslash at the end of
--- somebody's sentence.
---
--- Only where there is a line under it to break to. A backslash at the
--- end of a paragraph broke nothing and is a backslash its author
--- typed, and an even number of them is an escaped backslash and not a
--- break at all.
---
--- Second, whether it was broken: that is what keeps it off the line
--- under it where a caller joins a paragraph's lines (`opts.join`). Two
--- spaces at the end are the other way of writing a break, and are not
--- drawn either.
local function broken(line, next_line)
  if not next_line or vim.trim(next_line) == "" then
    return line, false
  end
  if line:match("%S  +$") then
    return (line:gsub("%s+$", "")), true
  end
  local slashes = line:match("\\*$") or ""
  if #slashes % 2 == 0 then
    return line, false
  end
  return line:sub(1, #line - 1), true
end

--- The link definitions of a text -- `[name]: https://…` on a line of
--- its own -- by name, which is case-blind in markdown. Outside fences:
--- inside one it is code. Handed to `M.inline` as `opts.definitions`,
--- which is what reads `[words][name]`, `[name][]` and `[name]`.
function M.definitions(lines)
  local out, inside = {}, false
  for _, l in ipairs(lines) do
    if l:match("^%s*```") or l:match("^%s*~~~") then
      inside = not inside
    elseif not inside then
      local name, href = l:match("^ ? ? ?%[([^%]]+)%]:%s*<?([^%s>]+)>?")
      if name and not name:match("^%^") then
        out[vim.fn.tolower(name)] = href
      end
    end
  end
  return out
end

--- `blocks` with each paragraph one block rather than one per line.
---
--- A file is wrapped by hand at whatever width its author's editor had,
--- and read here at whatever width this window has: kept a line per
--- line, a paragraph comes out as the author's breaks with the window's
--- inside them -- a long line and a short one, all the way down. So the
--- lines of one paragraph, and of one list item, are put back together
--- and wrapped once. Not across a blank line, which ends a paragraph,
--- nor after a hard break, which was written to be one.
local function joined(blocks)
  local out = {}
  for _, b in ipairs(blocks) do
    local last = out[#out]
    local next_to = last
      and not last.hard
      and last.last_row == b.row - 1
      and type(b.text) == "string"
      and vim.trim(b.text) ~= ""
      and type(last.text) == "string"
      and vim.trim(last.text) ~= ""
    local same = next_to
      and (
        (last.kind == "prose" and b.kind == "prose")
        or (last.kind == "item" and b.kind == "item" and b.of and (b.of == last or b.of == last.of))
      )
    if same then
      last.text = last.text .. " " .. vim.trim(b.text)
      last.hard, last.last_row = b.hard, b.row
    else
      b.last_row = b.row
      table.insert(out, b)
    end
  end
  return out
end

--- The lines of a text, as the blocks it is written in.
---
--- One pass, and greedy: a fence swallows everything up to the next
--- one, a table swallows every row under its head. What is left is
--- prose, a line at a time.
---
--- Each block is `{ kind = ..., row = ... }` -- `row` the line of
--- `lines` it starts on, counted from `base + 1`, which is what lets a
--- reader put the cursor back where it was in the source -- and carries
--- what its kind needs:
---
---   prose       `text`
---   heading     `text`, `level`
---   citation    `blocks` -- what was quoted, read the same way
---   table       `rows` (the head first), `align`
---   math        `lines`, the TeX between the `$$`s or in the fence
---   item        `text`, `depth` (0 at the top), `marker` -- "-" or
---               the number it is drawn with, "3." -- and `task`, nil
---               or whether it is ticked; or, for an indented line
---               that carries on the item above it, `text`, `depth`
---               and `of`, the item it carries on
---   code        `lines`, `fence`, `close`, `info` -- what follows the
---               backticks -- and `lang`, its first word
---   rule        a thematic break, `---`
---
--- A fence nobody closed is applied anyway, with `close` nil -- which
--- is what a page does with one, and what one looks like while it is
--- still being typed. `opts.fence` may read one as something else.
---
--- `>>>` on a line of its own opens a citation too, GitLab's own, and
--- the next `>>>` closes it: everything between is quoted, without a
--- `>` on any of it.
---
--- `opts.join` puts the lines of a paragraph back together (`joined`).
---
--- `[[_TOC_]]` (or `[TOC]`) on a line of its own is the text's own
--- headings, as the nested list a page draws them as.
---
--- A citation is the lines that start with `>`, with the `>` taken off
--- and the rest read again by this same function: what somebody quoted
--- was markdown when they quoted it, so a heading in one is a heading
--- and `> > so` is a citation inside a citation.
function M.blocks(lines, opts, base)
  opts = opts or {}
  base = base or 0
  local out, i = {}, 1
  -- The lists open at this point, outermost first: the column each
  -- one's markers stand in, whether it is numbered, the number it is
  -- on, and the last item in it. A line at a column between two of
  -- them belongs to the inner one, the way markdown reads it, and a
  -- line of prose at the margin ends all of them.
  local lists = {}
  local function add(block)
    block.row = block.row or base + i
    table.insert(out, block)
  end
  while i <= #lines do
    local line = lines[i]
    local indent, bullet, after = line:match("^(%s*)([-*+])%s+(.*)$")
    local number, delim
    if not bullet then
      indent, number, delim, after = line:match("^(%s*)(%d+)([.)])%s+(.*)$")
    end
    local column = indent and #indent:gsub("\t", "    ")
    local display = on(opts, "math") and line:match("^%s*%$%$(.*)$")
    local fenced_quote = on(opts, "citations") and line:match("^%s*>>>%s*$")
    local toc = line:match("^%s*%[%[_TOC_%]%]%s*$") or line:match("^%s*%[TOC%]%s*$")
    local fence = line:match("^%s*```(.*)$") or line:match("^%s*~~~(.*)$")
    local cited = on(opts, "citations") and line:match("^%s*>%s?(.*)$")
    local heading, said = line:match("^(#+)%s+(.*)$")
    if not heading then
      heading = line:match("^(#+)%s*$")
      said = heading and ""
    end
    -- `---`, `***`, `___`: three or more of one of them and nothing
    -- else, spaces allowed. Before the list, which `* * *` would
    -- otherwise be.
    local bare = line:gsub("%s", "")
    local ruled = line:match("^ ? ? ?[-*_]")
      and (bare:match("^%-%-%-+$") or bare:match("^%*%*%*+$") or bare:match("^___+$"))
    local align = on(opts, "tables") and alignments(lines[i + 1]) or nil
    if fenced_quote then
      local inner, j = {}, i + 1
      while j <= #lines and not lines[j]:match("^%s*>>>%s*$") do
        table.insert(inner, lines[j])
        j = j + 1
      end
      add({ kind = "citation", blocks = M.blocks(inner, opts, base + i) })
      i = j + 1
    elseif toc then
      -- The headings outside fences, a level of nesting per level of
      -- heading below the highest the text has.
      local found, top, inside = {}, 6, false
      for _, l in ipairs(lines) do
        if l:match("^%s*```") or l:match("^%s*~~~") then
          inside = not inside
        elseif not inside then
          local hashes, title = l:match("^(#+)%s+(.*)$")
          if hashes and #hashes <= 6 then
            table.insert(found, { level = #hashes, text = title })
            top = math.min(top, #hashes)
          end
        end
      end
      for _, h in ipairs(found) do
        add({ kind = "item", depth = h.level - top, marker = "-", text = h.text })
      end
      i = i + 1
    elseif display then
      -- `$$ x $$` on one line, or `$$` to the line that closes it.
      local one = display:match("^(.-)%$%$%s*$")
      local body, j = {}, i + 1
      if one then
        body = { one }
      else
        table.insert(body, display)
        while j <= #lines do
          local last = lines[j]:match("^(.-)%$%$%s*$")
          if last then
            table.insert(body, last)
            j = j + 1
            break
          end
          table.insert(body, lines[j])
          j = j + 1
        end
      end
      add({ kind = "math", lines = body })
      i = one and i + 1 or j
    elseif
      on(opts, "headings")
      and (line:match("^%s*=+%s*$") or line:match("^%s*%-+%s*$"))
      and out[#out]
      and out[#out].kind == "prose"
      and vim.trim(out[#out].text) ~= ""
      and out[#out].row == base + i - 1
    then
      -- Words underlined with `===` or `---` are a heading, the older of
      -- the two spellings: the line above, read again as one.
      local above = out[#out]
      above.kind, above.level = "heading", line:find("=", 1, true) and 1 or 2
      above.text = vim.trim(above.text)
      i = i + 1
    elseif ruled then
      add({ kind = "rule" })
      i = i + 1
    elseif on(opts, "lists") and indent and (bullet or #number <= 9) then
      while #lists > 0 and lists[#lists].column > column do
        table.remove(lists)
      end
      local top = lists[#lists]
      if top and top.column == column and top.ordered ~= (number ~= nil) then
        table.remove(lists)
        top = nil
      end
      if not (top and top.column == column) then
        top = { column = column, ordered = number ~= nil }
        table.insert(lists, top)
      end
      local item = { kind = "item", depth = #lists - 1, marker = "-" }
      if number then
        top.n = top.n and top.n + 1 or tonumber(number)
        item.marker = top.n .. delim
      end
      local box, rest = after:match("^%[([ xX])%]%s+(.*)$")
      if box then
        item.task, after = box ~= " ", rest
      end
      item.text, item.hard = broken(after, lines[i + 1])
      top.last = item
      add(item)
      i = i + 1
    elseif #lists > 0 and line:match("^%s+%S") and not fence then
      -- Indented under an item and not one itself: the item, carried
      -- on, and drawn hanging under its words.
      local top = lists[#lists]
      local text, hard = broken(vim.trim(line), lines[i + 1])
      add({ kind = "item", depth = top.last.depth, of = top.last, text = text, hard = hard })
      i = i + 1
    elseif fence then
      local closer = line:match("^%s*(```)") or "~~~"
      local body, close, j = {}, nil, i + 1
      while j <= #lines do
        if vim.startswith(vim.trim(lines[j]), closer) then
          close = lines[j]
          break
        end
        table.insert(body, lines[j])
        j = j + 1
      end
      local info = vim.trim(fence)
      local block
      if on(opts, "math") and info:match("^math$") then
        block = { kind = "math", lines = body }
      else
        block = {
          kind = "code",
          lines = body,
          fence = line,
          close = close,
          info = info,
          lang = info:match("^{?%.?([%w_+#%-]+)"),
        }
        block.row = base + i
        block = opts.fence and opts.fence(block) or block
      end
      add(block)
      i = j + 1
    elseif cited then
      local inner, j = { cited }, i + 1
      while j <= #lines do
        local more = lines[j]:match("^%s*>%s?(.*)$")
        if not more then
          break
        end
        table.insert(inner, more)
        j = j + 1
      end
      add({ kind = "citation", blocks = M.blocks(inner, opts, base + i - 1) })
      i = j
    elseif on(opts, "links") and line:match("^ ? ? ?%[[^%]^][^%]]*%]:%s*%S") then
      -- `[name]: https://…` says where a name goes and is not itself
      -- drawn, as on a page: `M.definitions` is what reads it.
      add({ kind = "definition" })
      i = i + 1
    elseif heading and on(opts, "headings") and #heading <= 6 then
      -- The closing hashes ATX allows, `## why ##`, are not words.
      add({ kind = "heading", text = (said:gsub("%s+#+%s*$", "")), level = #heading })
      i = i + 1
    elseif align and cells(line) then
      local rows = { cells(line) }
      local j = i + 2
      while j <= #lines and cells(lines[j]) do
        table.insert(rows, cells(lines[j]))
        j = j + 1
      end
      add({ kind = "table", rows = rows, align = align })
      i = j
    else
      -- A blank line does not end a list -- the items either side of
      -- one are the same list, spaced out -- and words at the margin
      -- do.
      if vim.trim(line) ~= "" then
        lists = {}
      end
      local text, hard = broken(line, lines[i + 1])
      add({ kind = "prose", text = text, hard = hard })
      i = i + 1
    end
  end
  if opts.join then
    out = joined(out)
  end
  return out
end

return M
