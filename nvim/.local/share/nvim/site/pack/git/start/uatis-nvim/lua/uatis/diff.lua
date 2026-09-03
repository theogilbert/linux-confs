-- Diff backends behind one interface.
--
--   diff.compute(old_text, new_text, opts, cb)
--   opts: { backend, path, bufnr, filetype }
--   cb({ hunks, spans, dropped, engine })
--
--     hunks  = { { start_a, count_a, start_b, count_b }, ... }, 1-based,
--              `a` = old_text, `b` = new_text (vim.diff's own naming).
--              count_a > 0, count_b == 0 is a pure deletion; the reverse
--              is a pure addition.
--     spans  = { { line, col_start, col_end, kind }, ... } | nil
--              character ranges within a line of `b` ("add") or `a`
--              ("delete"), when the backend can produce them.
--     pairs  = { [new line] = old line } | nil
--     anchor = { [old line] = new line } | nil
--              the backend's own row alignment, where it has one: which
--              old line a new line answers to, and which new line an old
--              line belongs above. `vim.diff` has neither -- a hunk is
--              all it can say.
--     dropped = changes difftastic reported as cosmetic.
--     unavailable = true when structural was asked for and difftastic
--              could not answer -- not installed, or it failed here.
--     prose  = true when difftastic answered but had no parser for this
--              file, so what it compared were words and not a tree.
--     engine  = what actually ran, for the header.
--
-- The callback is real, not decorative: vim.diff is synchronous and
-- in-process, difftastic is a subprocess costing tens to hundreds of
-- milliseconds. Both report back through vim.schedule so callers never
-- have to care which one they got.
--
-- Failures degrade, they do not raise. A missing binary, a nonzero exit or
-- unparseable output all fall back to the line backend rather than showing
-- the reviewer a stack trace.

local config = require("uatis.config")

local M = {}

-- ------------------------------------------------------------------
-- Line backend -- vim.diff
-- ------------------------------------------------------------------

-- No `linematch`. It re-pairs lines inside a replacement block by
-- similarity, which sounds like what a reviewer wants and empirically is
-- not: rewriting one line and appending a new function below it makes it
-- pair the rewritten line with a line in the NEW function instead, so the
-- removed line is drawn several lines away from where it lived, next to
-- unrelated code.
--
-- Histogram rather than Myers, though, which is where this parts company
-- with git's default. Both are minimal; where they differ is WHICH
-- minimal edit script they pick, and Myers picks badly on a file that has
-- been restructured. A test file whose functions moved into a class comes
-- back from Myers as one hunk over the whole body -- a one-word change to
-- an import three lines above gets swallowed by it -- and from histogram
-- as three, with that import line paired 1:1 as its own hunk.
--
-- The cost of a lumpy hunk is higher here than in a patch view. Git
-- prints the unchanged lines inside a hunk with a space in front of them;
-- this renderer draws the whole old block in red above the whole new
-- block in green, so a hunk that reaches too far reads as "all of this
-- was replaced". Hunk boundaries are a rendering decision here, not just
-- a presentational one, which is what tips it -- and `diff.line.algorithm`
-- puts it back if matching the forge's default matters more.
-- Both sides get a trailing newline. Without one, `vim.diff` treats the
-- final line as incomplete and stops reporting minimal hunks at the end
-- of the text: appending a line comes back as "replace the last line with
-- these two" rather than "add one line". Verified directly -- `semaphore`
-- vs `semaphores` split per character gives `{9,1,9,2}` unterminated and
-- `{9,0,10,1}` terminated. Blob text arrives here with its trailing
-- newline already stripped, so this is always the unterminated case.
--- ...with one exception: an empty side has NO lines, and `"" .. "\n"` is
--- one empty line. That phantom line then pairs with the first blank line
--- in the other side, so a wholly new file comes back as two additions
--- with one of its blank lines left unmarked, sitting between them as
--- though it had always been there.
local function terminate(text)
  return text == "" and "" or (text .. "\n")
end

local function line_hunks(old_text, new_text)
  local indices = vim.diff(terminate(old_text), terminate(new_text), {
    result_type = "indices",
    algorithm = config.diff.line.algorithm,
  }) or {}
  local hunks = {}
  for _, h in ipairs(indices) do
    table.insert(hunks, { start_a = h[1], count_a = h[2], start_b = h[3], count_b = h[4] })
  end
  return hunks
end

local function is_word_byte(s, i0)
  local c = s:sub(i0 + 1, i0 + 1)
  return c ~= "" and c:match("[%w_]") ~= nil
end

--- The part of `new_line` that differs from `old_line`, as 0-based
--- col_start (inclusive) and col_end (exclusive), expanded outwards to
--- whole words. Returns nil when the two lines are identical.
---
--- Trimming the shared prefix and suffix is what the eye is doing anyway.
--- Expanding to word boundaries afterwards matters because a raw
--- character trim cuts inside words wherever the old and new text happen
--- to share letters -- `semaphore` becoming `semaphores` would otherwise
--- highlight a lone `s`, which points at the change without showing it.
function M.word_span(old_line, new_line)
  if old_line == new_line then
    return nil
  end
  local pre = 0
  while pre < #old_line and pre < #new_line
    and old_line:byte(pre + 1) == new_line:byte(pre + 1) do
    pre = pre + 1
  end
  local suf = 0
  while suf < (#old_line - pre) and suf < (#new_line - pre)
    and old_line:byte(#old_line - suf) == new_line:byte(#new_line - suf) do
    suf = suf + 1
  end
  local s, e = pre, #new_line - suf
  while s > 0 and is_word_byte(new_line, s - 1) and is_word_byte(new_line, s) do
    s = s - 1
  end
  while e < #new_line and is_word_byte(new_line, e - 1) and is_word_byte(new_line, e) do
    e = e + 1
  end
  if e <= s then
    return nil
  end
  return s, e
end

-- ------------------------------------------------------------------
-- Intra-line diff
-- ------------------------------------------------------------------

--- Splits a block of lines into words, whitespace runs, and single other
--- characters. Punctuation stays one token per character so that `(`,
--- `,` and `)` can be marked independently of the identifiers near them.
---
--- Every token carries the line it came from, and the line breaks
--- themselves are tokens. That is what lets a change be tracked ACROSS
--- lines: reflowing a signature onto three lines is then an insertion of
--- two line breaks and some indentation, rather than one line replaced by
--- three unrelated ones.
---
--- `limit`, where given, is a ceiling this gives up at: past that many
--- tokens it returns nil instead of finishing. Counted as it goes rather
--- than measured afterwards, because splitting the block IS the cost the
--- ceiling exists to avoid -- a rewritten fifty-thousand-line file is
--- half a second of it, and finding that out at the end means having
--- already spent it.
local function tokenize(lines, limit)
  local toks, n = {}, 0
  for ln, line in ipairs(lines) do
    local i = 1
    while i <= #line do
      local a, b = line:find("^[%w_]+", i)
      if not a then
        a, b = line:find("^%s+", i)
      end
      if not a then
        a, b = i, i
      end
      n = n + 1
      toks[n] = { text = line:sub(a, b), line = ln, col = a - 1 }
      i = b + 1
    end
    if ln < #lines then
      -- Zero width on purpose: it aligns, but there is nothing to paint.
      n = n + 1
      toks[n] = { text = "\n", line = ln, col = #line, newline = true }
    end
    if limit and n > limit then
      return nil
    end
  end
  return toks
end

--- Diffs two sequences of strings by handing them to `vim.diff` as lines.
--- Reuses the built-in implementation rather than writing an LCS by hand;
--- the tokens come from a single line, so none of them can contain the
--- newline used to join them.
---
--- Deliberately NOT `config.diff.line.algorithm`. That setting is about where
--- a HUNK should begin and end, which is a question about how a file
--- reads. This is a token stream inside one replacement, already re-paired
--- afterwards by `align_block`, and it wants the plain minimal answer
--- whatever the file-level setting says.
local function seq_diff(a, b)
  if #a == 0 and #b == 0 then
    return {}
  end
  -- An empty side is answered here rather than handed on. Joining no
  -- tokens gives `""`, and the termination below turns that into `"\n"`
  -- -- one empty line, not none -- so vim.diff reports a replacement of
  -- one token that is not there, and the caller indexes past the end of
  -- the array. Comparing an empty line against a real one is enough to
  -- reach it.
  if #a == 0 then
    return { { 0, 0, 1, #b } }
  end
  if #b == 0 then
    return { { 1, #a, 0, 0 } }
  end
  -- Terminated, for the same reason line_hunks terminates its input:
  -- otherwise an edit at the end of a line stops being reported
  -- minimally, and every intra-line diff has an end.
  return vim.diff(table.concat(a, "\n") .. "\n", table.concat(b, "\n") .. "\n", {
    result_type = "indices",
  }) or {}
end

local function levenshtein(a, b)
  if a == b then
    return 0
  end
  local prev, cur = {}, {}
  for j = 0, #b do
    prev[j] = j
  end
  for i = 1, #a do
    cur[0] = i
    local ai = a:byte(i)
    for j = 1, #b do
      local cost = (ai == b:byte(j)) and 0 or 1
      cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
    end
    prev, cur = cur, prev
  end
  return prev[#b]
end

--- How alike two tokens are, 0..1. Decides whether a replaced token is
--- worth diffing character by character: `semaphore` and `semaphores`
--- share almost everything and reward it, whereas `hello` and `goodbye`
--- share only an `o` and would produce scattered single-character marks
--- that read as noise rather than as a change.
local function similarity(a, b)
  local longest = math.max(#a, #b)
  if longest == 0 then
    return 1
  end
  return 1 - (levenshtein(a, b) / longest)
end

M.similarity = similarity

--- `partial` marks a range that is PART of a token rather than a whole
--- one -- the letters that differ inside a word. Callers that draw a
--- range where the code is, rather than beside it, ask about it: a mark
--- that narrow says what it means only while there is one of it on the
--- line.
local function push(list, line, from, to, partial)
  if to <= from then
    return
  end
  local last = list[#list]
  if last and last.line == line and last.col_end == from then
    last.col_end = to -- merge touching ranges so the mark reads as one
    last.partial = last.partial or partial or nil
  else
    table.insert(list, { line = line, col_start = from, col_end = to, partial = partial or nil })
  end
end

--- Pushes a run of tokens, split per line, skipping the line breaks --
--- they have no width to paint.
local function push_tokens(list, toks, first, count)
  for i = first, first + count - 1 do
    local t = toks[i]
    if t and not t.newline then
      push(list, t.line, t.col, t.col + #t.text)
    end
  end
end

local function chars_of(s)
  local out = {}
  for i = 1, #s do
    table.insert(out, s:sub(i, i))
  end
  return out
end

--- Char-level diff of one token against the token it replaced, pushing
--- the differing byte ranges onto `adds` and `dels`.
--- How many bytes two strings share at the front and at the back.
local function affixes(a, b)
  local limit = math.min(#a, #b)
  local pre = 0
  while pre < limit and a:byte(pre + 1) == b:byte(pre + 1) do
    pre = pre + 1
  end
  local suf = 0
  while suf < limit - pre and a:byte(#a - suf) == b:byte(#b - suf) do
    suf = suf + 1
  end
  return pre, suf
end

--- Whether marking a replaced word character by character will read as
--- anything.
---
--- Similarity alone is not enough. `closer` and `whose` share `ose` in the
--- middle and score exactly at the threshold, so they were diffed per
--- character and came out as `cl`/`r` removed against `wh` added -- three
--- fragments of two different words, pointing at nothing. `semaphore` and
--- `semaphores` share the entire stem, and marking the `s` is exactly
--- right.
---
--- The difference is WHERE the shared text is. A common prefix or suffix
--- is a stem the eye can anchor on, so the marked part reads as the edit.
--- Letters shared only in the middle are a coincidence of spelling. Below
--- the threshold both words are marked whole, which is the honest
--- statement: this word became that one.
---
--- ...unless the comparison only goes one way. A word that merely LOST a
--- character -- `and` -> `ad`, `for` -> `fr` -- shares too little at
--- either end to pass the affix test, and marking both words whole then
--- says something false: the new word is drawn as inserted text when
--- every character of it is the old word's, with the character that went
--- in red beside it, and it reads as though `and` had been replaced by
--- `ad`. There are no fragments of two different words to be misled by
--- here, because one of the two sides has no marks on it at all -- every
--- mark is a character genuinely removed, or genuinely inserted, and
--- that is exactly the edit.
--- How many bytes an edit script takes out and puts in.
local function edit_counts(ops)
  local added, removed = 0, 0
  for _, c in ipairs(ops) do
    removed = removed + c[2]
    added = added + c[4]
  end
  return added, removed
end

local function worth_char_diff(a, b, ops)
  local pre, suf = affixes(a, b)
  if math.max(pre, suf) >= config.diff.line.word_affix then
    return true
  end
  local added, removed = edit_counts(ops)
  return added == 0 or removed == 0
end

--- Pushes the byte ranges of a token that was edited rather than replaced.
---
--- A one-sided edit -- characters only removed, or only added -- is pushed
--- as the comparison found it. Every mark there is a character that
--- genuinely went or genuinely arrived, and only one of the two sides
--- carries any, so `foobar` -> `fobar` marks the `o` and nothing else
--- however scattered the losses are.
---
--- A two-sided one is pushed as ONE range per side: the stretch between
--- the shared prefix and the shared suffix, marked whole. The affix test
--- above says there is a stem for the eye to anchor on; it does not say
--- the part BETWEEN the stems is anything more than one word replacing
--- another, and taking that apart character by character lands on
--- whichever letters the two words happen to share. `report_flags` ->
--- `parsed_flags` came back as `a` and `sed` marked inside the new word,
--- with the `p` and the `r` between them left bare as though they had
--- come through the change untouched -- two fragments of `parsed` where
--- the edit is the whole of it. That is the coincidence of spelling
--- `word_affix` exists to catch, one level down: shared letters in the
--- middle of the differing part are worth no more than shared letters in
--- the middle of the word.
local function char_pair(a_tok, b_tok, ops, adds, dels)
  local added, removed = edit_counts(ops)
  if added == 0 or removed == 0 then
    for _, c in ipairs(ops) do
      if c[2] > 0 then
        push(dels, a_tok.line, a_tok.col + c[1] - 1, a_tok.col + c[1] - 1 + c[2], true)
      end
      if c[4] > 0 then
        push(adds, b_tok.line, b_tok.col + c[3] - 1, b_tok.col + c[3] - 1 + c[4], true)
      end
    end
    return
  end
  local pre, suf = affixes(a_tok.text, b_tok.text)
  push(dels, a_tok.line, a_tok.col + pre, a_tok.col + #a_tok.text - suf, true)
  push(adds, b_tok.line, b_tok.col + pre, b_tok.col + #b_tok.text - suf, true)
end

--- Re-aligns one replacement block by similarity rather than by equality.
---
--- Myers only knows whether two tokens are equal, so where a word is
--- edited AND words are inserted beside it, it is free to pair the edited
--- word with an inserted one: adding `updated ` before `semaphore` and an
--- `s` after it aligns `semaphore` with `updated`, and the whole run then
--- reads as replaced. Both alignments cost the same number of edits, so
--- there is nothing for Myers to prefer.
---
--- This re-pairs the block with a small alignment that scores a match by
--- how alike the two tokens are, so `semaphore` finds `semaphores` and
--- everything else falls out as inserted. Blocks are short -- a run
--- inside one line -- so the quadratic table is cheap.
local function align_block(A, sa, ca, B, sb, cb, adds, dels)
  local function key(i, j)
    return i * (cb + 1) + j
  end
  local score, back = { [key(0, 0)] = 0 }, {}

  for i = 0, ca do
    for j = 0, cb do
      if i > 0 or j > 0 then
        local best, from = -math.huge, nil
        if i > 0 then
          best, from = score[key(i - 1, j)], "del"
        end
        if j > 0 and score[key(i, j - 1)] > best then
          best, from = score[key(i, j - 1)], "add"
        end
        if i > 0 and j > 0 then
          local sim = similarity(A[sa + i - 1].text, B[sb + j - 1].text)
          if sim >= config.diff.line.word_similarity and score[key(i - 1, j - 1)] + sim > best then
            best, from = score[key(i - 1, j - 1)] + sim, "match"
          end
        end
        score[key(i, j)], back[key(i, j)] = best, from
      end
    end
  end

  local ops, i, j = {}, ca, cb
  while i > 0 or j > 0 do
    local from = back[key(i, j)]
    table.insert(ops, 1, { from, i, j })
    if from == "match" then
      i, j = i - 1, j - 1
    elseif from == "del" then
      i = i - 1
    else
      j = j - 1
    end
  end

  for _, op in ipairs(ops) do
    local kind, i2, j2 = op[1], op[2], op[3]
    if kind == "match" then
      local a_tok, b_tok = A[sa + i2 - 1], B[sb + j2 - 1]
      if a_tok.text ~= b_tok.text then
        local ops = seq_diff(chars_of(a_tok.text), chars_of(b_tok.text))
        if worth_char_diff(a_tok.text, b_tok.text, ops) then
          char_pair(a_tok, b_tok, ops, adds, dels)
        else
          -- Aligned, but not alike enough to take apart: one word became
          -- another, and that is what the marks should say.
          push_tokens(dels, A, sa + i2 - 1, 1)
          push_tokens(adds, B, sb + j2 - 1, 1)
        end
      end
    elseif kind == "del" then
      push_tokens(dels, A, sa + i2 - 1, 1)
    else
      push_tokens(adds, B, sb + j2 - 1, 1)
    end
  end
end

--- Character-and-word-level diff of one line against the line it
--- replaced.
---
--- Returns { adds, dels }: byte ranges (0-based, end exclusive) of what
--- was inserted into `new_line` and what was removed from `old_line`.
--- A range that came from taking a token apart carries `partial`.
---
--- Two granularities, chosen per replaced token. A token replaced by a
--- similar one is diffed character by character, so adding an `s` marks
--- the `s`. A token replaced by an unrelated one is marked whole, because
--- character-level marks between unrelated words land on whichever
--- letters they happen to share and point at nothing.
---
--- Works over a BLOCK of lines rather than a line pair, so a hunk that
--- replaces one line with three is still tracked character by character.
--- Reflowing a signature is then two inserted line breaks and some
--- indentation -- not one line vanishing and three unrelated ones
--- appearing, which is what a per-line comparison is forced to say and
--- what makes a reflow read as though the code were rewritten.
---
--- Two limits, because there are two costs. The quadratic one is
--- `align_block`, which scores every old token in a REPLACEMENT RUN
--- against every new one, and it is rationed per run rather than per
--- block: a run is only as big as the code that was actually rewritten,
--- and charging the whole block for its total token count charged the
--- wrong thing. One line appended to a forty-line SQL string is a pure
--- insertion with no alignment in it at all, and it came back as
--- nothing -- so the string was drawn emphasized end to end when a
--- single line of it was new. `inline_token_limit` squared is the
--- budget, spent across the block, which is exactly the work the old
--- block-wide cap allowed at its own worst case; past it a run is
--- marked token by token, which is what a wholesale rewrite reads as
--- anyway.
---
--- The other cost is linear and therefore easy to miss: tokenizing a
--- block and pushing a range per token is nothing on a hunk and most of
--- a second on a rewritten twenty-thousand-line file, all of it on the
--- main loop. `inline_block_limit` is where that stops being free, and
--- past it there is no comparison at all -- the caller falls back to
--- whole-line highlighting, which is what a hunk that size reads as.
function M.block_diff(old_lines, new_lines)
  local adds, dels = {}, {}

  local ceiling = config.diff.inline_block_limit
  local A, B = tokenize(old_lines, ceiling), tokenize(new_lines, ceiling)
  if not A or not B then
    return nil -- caller falls back to whole-line highlighting
  end
  local limit = config.diff.inline_token_limit
  local budget = limit * limit
  if #A == 0 and #B == 0 then
    return { adds = adds, dels = dels }
  end

  -- One entry per token, and a line break is a token whose text IS a
  -- newline -- which `seq_diff` is about to join tokens with. Left as it
  -- is, joining three tokens produces four lines, every index after a
  -- line break points at the wrong token, and a block long enough to run
  -- the drift past the end of the array crashes on the token that is not
  -- there. Stood in for by a character no source line contains, the
  -- lines and the tokens count the same.
  local a_text, b_text = {}, {}
  for i, t in ipairs(A) do
    a_text[i] = t.newline and "\1" or t.text
  end
  for i, t in ipairs(B) do
    b_text[i] = t.newline and "\1" or t.text
  end

  for _, h in ipairs(seq_diff(a_text, b_text)) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    if ca > 0 and cb > 0 and ca * cb <= budget then
      budget = budget - ca * cb
      align_block(A, sa, ca, B, sb, cb, adds, dels)
    elseif ca > 0 and cb > 0 then
      -- Too big to pair up. Both sides marked whole: these tokens went,
      -- those arrived, which is all an alignment nobody can afford to
      -- compute would have said more precisely.
      push_tokens(dels, A, sa, ca)
      push_tokens(adds, B, sb, cb)
    elseif ca > 0 then
      push_tokens(dels, A, sa, ca)
    elseif cb > 0 then
      push_tokens(adds, B, sb, cb)
    end
  end

  return { adds = adds, dels = dels }
end

--- Whether two blocks of lines correspond line for line, closely enough
--- that comparing them pairwise says something true.
---
--- Equal line counts are not enough on their own. Wrapping an expression
--- in parentheses keeps the count while moving the content down a line,
--- so pairing by position compares `region = self._client...get(` against
--- `region = (` and reports the tail as removed -- which is where the
--- before-image stops being readable as the old code and turns into red
--- fragments spread over dimmed context. Requiring every pair to be
--- similar catches that, while still allowing the common case of a few
--- consecutive lines each getting a small edit.
---
--- Skipped for large or very long blocks, where the check would cost more
--- than the precision buys.
function M.lines_correspond(old_lines, new_lines)
  if #old_lines ~= #new_lines or #old_lines == 0 or #old_lines > 20 then
    return false
  end
  for i = 1, #old_lines do
    local a, b = old_lines[i], new_lines[i]
    if #a > 400 or #b > 400 then
      return false
    end
    if similarity(a, b) < config.diff.line.word_similarity then
      return false
    end
  end
  return true
end

--- True when the code in `old_lines` is still there in `new_lines`: the
--- edit moved it, reindented it, reflowed it or wrapped it, and took none
--- of it away. What decides whether a removal gets a before-image drawn.
---
--- Compared token by token, not character by character, and that is the
--- whole of it. Characters make near-misses look like survivals: a
--- helptags line reading `:DbConnect ... /*:DbConnect*` is a character
--- subsequence of `:DbConnections ... /*:DbConnections*` one row below
--- it, so deleting the tag looked like moving it and the removal was
--- drawn nowhere at all. As tokens, `DbConnect` and `DbConnections` are
--- two different words and the answer is immediate.
---
--- Tokens also say the right thing about the edits that really are moves.
--- Reindenting and reflowing change only whitespace, which is not a
--- token; wrapping inserts tokens -- a bracket, a `self` -- BETWEEN the
--- old ones without touching them. Growing a word is the one thing it
--- refuses, which is what distinguishes a similar line from the same one.
---
--- Deliberately NOT read off the token diff. Alignment there is a guess:
--- wrapping an expression in parentheses made it pair the old opening
--- quote against `self` and report the quote as deleted, which is an
--- artifact of how the two token streams line up rather than anything
--- that happened to the code. A subsequence test cannot produce that --
--- it only ever asks whether the old tokens are all still there, in order.
local function words_of(lines)
  local out = {}
  for _, tok in ipairs(tokenize(lines)) do
    if not tok.newline and not tok.text:match("^%s") then
      table.insert(out, tok.text)
    end
  end
  return out
end

function M.content_survives(old_lines, new_lines)
  local old_toks = words_of(old_lines)
  local new_toks = words_of(new_lines)
  if #old_toks == 0 then
    return true
  end

  -- Forward pass: where does the old content finish matching, at the
  -- earliest.
  local i, to = 1, nil
  for j = 1, #new_toks do
    if i > #old_toks then
      break
    end
    if old_toks[i] == new_toks[j] then
      to = j
      i = i + 1
    end
  end
  if i <= #old_toks then
    return false
  end

  -- Backward pass from there, to find the LATEST start that still works.
  -- Matching forwards alone starts as early as some token happens to
  -- appear, so leading context stretches the span and makes a genuine
  -- move look scattered. Walking back from the end gives the tightest
  -- region the old content actually occupies.
  local k, from = #old_toks, to
  for j = to, 1, -1 do
    if k < 1 then
      break
    end
    if old_toks[k] == new_toks[j] then
      from = j
      k = k - 1
    end
  end

  -- The match also has to be TIGHT. Spread thinly enough, any short line
  -- is a subsequence of the code around it -- `return a` matches a word
  -- here and a word three rows down, which would excuse a real removal as
  -- a move. Code that genuinely moved keeps its shape, so the span it
  -- matched into should be about its own length: a quarter's growth, plus
  -- a few tokens so the allowance does not round to nothing on a short
  -- line, covers what a wrap inserts around and inside what it wrapped.
  --
  -- Three and not two, which is what a wrap actually costs: `x` becoming
  -- `str(x)` inserts a name and both brackets, and `VARCHAR2` becoming
  -- `VARCHAR2(50)` inserts the brackets and what is between them. At two
  -- the same edit was a move on a long line and a removal on a short one
  -- -- `assert by_name["VAL"].types == ["VARCHAR2"]` has sixteen tokens
  -- and a quarter of that covers three, while `assert desc.types ==
  -- ["VARCHAR2"]` has eleven and a quarter of eleven is two. One edit
  -- drawn two ways in one file, for no reason the reader can see.
  local span = to - from + 1
  return span <= #old_toks + math.max(3, math.floor(#old_toks / 4))
end

--- Single-line convenience wrapper, for callers and tests that only ever
--- compare one line against one line.
function M.inline_diff(old_line, new_line)
  local r = M.block_diff({ old_line }, { new_line })
  return r or { adds = {}, dels = {} }
end

-- Character-level spans for the even case only. A 1:1 line replacement can
-- be diffed character by character and mapped straight back onto real
-- positions; an uneven replacement (a signature reflowed from one line to
-- three, say) has no such mapping, and vim.diff does not expose the
-- internal alignment table that would give one, so those keep whole-line
-- highlighting. Structural mode is the answer for that case.
local function char_spans(old_lines, new_lines, hunks)
  local spans = {}
  for _, h in ipairs(hunks) do
    if h.count_a > 0 and h.count_a == h.count_b then
      for i = 0, h.count_a - 1 do
        local a = old_lines[h.start_a + i] or ""
        local b = new_lines[h.start_b + i] or ""
        local s, e = M.word_span(a, b)
        if s then
          table.insert(spans, {
            line = h.start_b + i, col_start = s, col_end = e, kind = "add",
          })
        end
      end
    end
  end
  return spans
end

local function line_compute(old_text, new_text, opts, cb)
  local hunks = line_hunks(old_text, new_text)
  local old_lines = vim.split(old_text, "\n", { plain = true })
  local new_lines = vim.split(new_text, "\n", { plain = true })
  cb({
    hunks = hunks,
    spans = char_spans(old_lines, new_lines, hunks),
    dropped = 0,
    engine = "vim.diff",
    precise = false,
  })
end

-- ------------------------------------------------------------------
-- Structural backend -- difftastic, with a vim.diff fallback
-- ------------------------------------------------------------------

-- difftastic's JSON output is gated behind this even though it is not in
-- the visible --help option list; it only shows up in the error message
-- when omitted.
local DIFFT_ENV = { DFT_UNSTABLE = "yes" }

local difft_cache = {}

local function write_temp(text, ext)
  local path = vim.fn.tempname() .. (ext ~= "" and ("." .. ext) or "")
  local fd = io.open(path, "wb")
  if not fd then
    return nil
  end
  fd:write(text)
  fd:close()
  return path
end

--- Builds hunks and spans from difftastic's JSON.
---
--- `chunks` gives which lines carry real changes (a line can appear in
--- `aligned_lines` as a matched pair and still be the changed side of an
--- edit within that line). `aligned_lines` gives the pairing, including
--- the gaps. Combining them classifies every aligned row as gap, changed
--- or same; runs of non-same rows coalesce into one hunk each, anchored
--- the way vim.diff anchors an addition or deletion so that the renderer
--- does not have to know which backend produced the hunk.
local function from_json(data)
  local lhs_changed, rhs_changed, spans = {}, {}, {}
  for _, chunk in ipairs(data.chunks or {}) do
    for _, entry in ipairs(chunk) do
      if entry.lhs and entry.lhs.changes and #entry.lhs.changes > 0 then
        lhs_changed[entry.lhs.line_number] = true
        for _, ch in ipairs(entry.lhs.changes) do
          table.insert(spans, {
            line = entry.lhs.line_number + 1,
            col_start = ch.start,
            col_end = ch["end"],
            kind = "delete",
            atom = ch.highlight,
          })
        end
      end
      if entry.rhs and entry.rhs.changes and #entry.rhs.changes > 0 then
        rhs_changed[entry.rhs.line_number] = true
        for _, ch in ipairs(entry.rhs.changes) do
          table.insert(spans, {
            line = entry.rhs.line_number + 1,
            col_start = ch.start,
            col_end = ch["end"],
            kind = "add",
            -- What difftastic called the thing this range is part of:
            -- `string`, `comment`, `keyword`, `type`, `normal`,
            -- `delimiter`. The only thing in the JSON that says where its
            -- own display goes further and picks out the words inside --
            -- which it does for prose atoms and nowhere else.
            atom = ch.highlight,
          })
        end
      end
    end
  end

  -- A row present on only one side is NOT automatically a change. When a
  -- signature is reflowed onto three lines, difftastic reports the two
  -- continuation lines as right-hand-only rows carrying no `changes` at
  -- all: the content is the same code, laid out differently. Treating
  -- every one-sided row as a hunk paints those lines as freshly added,
  -- which is exactly the claim a structural diff exists to avoid making.
  -- A genuinely new line always carries `changes` for its tokens --
  -- verified against a reflow and a new function in the same file, where
  -- the reflowed rows come back with none and the new function's rows
  -- come back with one per token.
  local rows = {}
  for _, pair in ipairs(data.aligned_lines or {}) do
    local lhs, rhs = pair[1], pair[2]
    local kind
    if lhs == nil and rhs == nil then
      kind = "same"
    elseif lhs == nil then
      kind = rhs_changed[rhs] and "gap" or "same"
    elseif rhs == nil then
      kind = lhs_changed[lhs] and "gap" or "same"
    elseif lhs_changed[lhs] or rhs_changed[rhs] then
      kind = "changed"
    else
      kind = "same"
    end
    table.insert(rows, { lhs = lhs, rhs = rhs, kind = kind })
  end

  -- A single unchanged row between two changed ones stays inside the run.
  -- Wrapping an expression in parentheses reports the `(` and the `)` as
  -- separate one-row changes with the untouched expression between them;
  -- kept apart, each is judged on its own and the expression looks like
  -- it was removed and replaced. Together they are one edit, which is
  -- what they are.
  local function same_at(k)
    return rows[k] ~= nil and rows[k].kind == "same"
  end

  -- difftastic's own line pairing, kept as it stated it rather than left
  -- to be re-derived from the hunk shapes below.
  --
  -- A hunk is a start and a count on each side, which is all `vim.diff`
  -- can say and less than difftastic said: it aligned the two files row
  -- by row, and knows that this new row answers to that old one. Thrown
  -- away, the renderer has to guess the correspondence back from the two
  -- counts, and guesses wrong exactly where the alignment is interesting
  -- -- a six-into-three replacement has no line-for-line anything by the
  -- counts, while difftastic paired the first three of them.
  --
  --   pairs[new row]  = the old row it answers to
  --   anchor[old row] = the new row it belongs directly above, which for
  --                     a paired row is its partner and for a row with no
  --                     partner is wherever the alignment put it: above
  --                     the next new row there is one for.
  local pairs_of, anchor_of, next_rhs = {}, {}, nil
  for i = #rows, 1, -1 do
    local r = rows[i]
    if r.rhs then
      next_rhs = r.rhs + 1
    end
    if r.lhs then
      anchor_of[r.lhs + 1] = next_rhs
      if r.rhs then
        pairs_of[r.rhs + 1] = r.lhs + 1
      end
    end
  end

  local hunks = {}
  local i = 1
  while i <= #rows do
    if rows[i].kind == "same" then
      i = i + 1
    else
      local j, a_first, a_last, b_first, b_last = i, nil, nil, nil, nil
      while j <= #rows and (rows[j].kind ~= "same" or (same_at(j) and not same_at(j + 1)
        and j + 1 <= #rows)) do
        if rows[j].lhs then
          a_first = a_first or rows[j].lhs
          a_last = rows[j].lhs
        end
        if rows[j].rhs then
          b_first = b_first or rows[j].rhs
          b_last = rows[j].rhs
        end
        j = j + 1
      end
      local start_a = a_first and (a_first + 1) or 0
      local count_a = a_first and (a_last - a_first + 1) or 0
      local start_b = b_first and (b_first + 1) or 0
      local count_b = b_first and (b_last - b_first + 1) or 0
      -- A one-sided run anchors after the last row that side did have, so
      -- "inserted here" and "deleted here" both land in the right place.
      if count_a == 0 then
        for k = i - 1, 1, -1 do
          if rows[k].lhs then
            start_a = rows[k].lhs + 1
            break
          end
        end
      end
      if count_b == 0 then
        for k = i - 1, 1, -1 do
          if rows[k].rhs then
            start_b = rows[k].rhs + 1
            break
          end
        end
      end
      table.insert(hunks, { start_a = start_a, count_a = count_a, start_b = start_b, count_b = count_b })
      i = j
    end
  end

  return hunks, spans, pairs_of, anchor_of
end

--- What structural mode falls back to when difftastic cannot answer: the
--- LINE diff, said plainly, and not an imitation of a structural one.
---
--- `vim.diff` with blank-line-only hunks suppressed was tried here. It
--- could recognise the crudest reformatting and nothing else, which meant
--- structural mode sometimes meant difftastic and sometimes meant a line
--- diff wearing its name, with nothing on screen to say which. A frontend
--- for a tool says what that tool said, or says it could not ask.
---
--- `unavailable` is how it says so: the caller puts it in the header, once
--- and quietly, rather than a notification per redraw.
local function no_difft(old_text, new_text, opts, cb)
  line_compute(old_text, new_text, opts, function(result)
    result.unavailable = true
    cb(result)
  end)
end

--- Whether difftastic parsed this file at all.
---
--- It says so in `language`, and says it the same way whether there is no
--- parser for the extension (`Text`) or the parser was there and the file
--- would not go through it (`Text (2 Lua parse errors, exceeded
--- DFT_PARSE_ERROR_LIMIT)`) -- which is the common case while a file is
--- being edited, not a rare one.
---
--- Either way what came back is a comparison of WORDS, and that changes
--- what the marks mean: in a tree, an atom is a token and a changed token
--- is new in its entirety; in text, every atom is prose, and the words
--- that actually differ are worth picking out of the line the way they
--- are inside a docstring. Without this the two are indistinguishable and
--- a text file comes back banded line by line -- a line diff, drawn by
--- the structural engine and not saying so.
local function textual(language)
  return type(language) == "string" and language:match("^Text") ~= nil
end

local function struct_compute(old_text, new_text, opts, cb)
  if vim.fn.executable(config.diff.struct.bin) ~= 1 then
    return no_difft(old_text, new_text, opts, cb)
  end

  local ck = table.concat({ old_text, new_text, opts.path or "" }, "\1")
  if difft_cache[ck] then
    cb(difft_cache[ck])
    return
  end

  -- difftastic reads paths, not stdin, and detects the language from the
  -- extension, so both sides are written out with the real extension.
  local ext = (opts.path or ""):match("%.([%w_]+)$") or ""
  local old_file = write_temp(old_text, ext)
  local new_file = write_temp(new_text, ext)
  if not old_file or not new_file then
    if old_file then os.remove(old_file) end
    if new_file then os.remove(new_file) end
    return no_difft(old_text, new_text, opts, cb)
  end

  vim.system(
    -- No --ignore-comments. difftastic can drop comment changes and once
    -- did here, on the reasoning that structural mode is about code. It is
    -- the wrong trade: a comment is where the reasoning behind the code
    -- lives, rewriting one is a real edit, and a reviewer who cannot see
    -- it has no way to know it happened -- the file simply reports as
    -- unchanged. Structural mode hides how code was *formatted*, not what
    -- was *said*.
    { config.diff.struct.bin, "--display", "json", old_file, new_file },
    { text = true, env = DIFFT_ENV },
    function(res)
      os.remove(old_file)
      os.remove(new_file)
      vim.schedule(function()
        if res.code ~= 0 or not res.stdout or res.stdout == "" then
          return no_difft(old_text, new_text, opts, cb)
        end
        -- luanil matters: without it a JSON null inside an array -- every
        -- gap in aligned_lines -- decodes to the vim.NIL sentinel rather
        -- than Lua nil, so the `pair[1] == nil` gap test silently never
        -- matches and every gap is misread as a matched pair.
        local ok, data = pcall(vim.json.decode, res.stdout, {
          luanil = { object = true, array = true },
        })
        if not ok or type(data) ~= "table" then
          return no_difft(old_text, new_text, opts, cb)
        end
        local result
        if data.status == "created" or data.status == "deleted" then
          -- One side is empty, and difftastic says so at file level and
          -- stops: no chunks, no aligned lines, nothing to align them
          -- against. The hunks are then not a matter of opinion -- every
          -- line of the side that exists -- and `precise = false` says
          -- what is true, that there is no token detail to be had here.
          local hunks = line_hunks(old_text, new_text)
          result = { hunks = hunks, spans = {}, dropped = 0,
            engine = "difftastic", precise = false,
            prose = textual(data.language) }
        elseif data.status == "unchanged" then
          -- An unchanged response omits chunks and aligned_lines entirely
          -- rather than sending empty arrays. Reaching here with texts
          -- that genuinely differ means the whole change was comments or
          -- formatting.
          local differ = old_text ~= new_text
          result = { hunks = {}, spans = {}, dropped = differ and 1 or 0,
            engine = "difftastic", precise = true,
            prose = textual(data.language) }
        else
          local hunks, spans, pairs_of, anchor_of = from_json(data)
          result = { hunks = hunks, spans = spans, dropped = 0,
            pairs = pairs_of, anchor = anchor_of,
            engine = "difftastic", precise = true,
            prose = textual(data.language) }
        end
        difft_cache[ck] = result
        cb(result)
      end)
    end
  )
end

local BACKENDS = { line = line_compute, struct = struct_compute }

function M.compute(old_text, new_text, opts, cb)
  opts = opts or {}
  local backend = BACKENDS[opts.backend or "line"] or line_compute
  backend(old_text, new_text, opts, function(result)
    vim.schedule(function()
      cb(result)
    end)
  end)
end

return M
