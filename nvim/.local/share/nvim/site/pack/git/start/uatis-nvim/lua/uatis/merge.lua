-- The text of a merge conflict, and what can be done with it without a
-- buffer or a git call: reading the blocks out of a file, and merging
-- one block three ways by the WORD.
--
-- git merges by the line. Two branches that touch the same line -- or
-- adjacent lines -- get a conflict block, however different the words
-- they touched are, and most of what a reader resolves by hand is
-- exactly that: one side reworded the comment, the other changed the
-- expression under it. `merge3` re-runs the merge inside one block at
-- token granularity -- base against ours, base against theirs -- and
-- where the two sides' changes touch no common token, applies both.
-- Where they do touch, it says so and applies nothing: half a block
-- merged by a program and half by hand is the one outcome worse than
-- either.
--
-- Touching is by CLOSED base ranges, so two edits to adjacent tokens
-- count as overlap, and so do two insertions at the same point. That is
-- git's own rule one level up, and it is kept on purpose: a merge that
-- guesses the order of two insertions is worse than one that asks.
--
-- Whitespace is a token like any other. The output of a merge is the
-- base with the two sides' edits applied and nothing else changed, byte
-- for byte, which is the only answer a reader can trust without reading
-- it.

local M = {}

-- ------------------------------------------------------------------
-- Blocks
-- ------------------------------------------------------------------

--- The conflict blocks in `lines`, in order. Each is
---
---   { top, sep, bottom, mid?, ours, theirs, base?, label_ours,
---     label_theirs }
---
--- with `top`/`mid`/`sep`/`bottom` the 1-based rows of the `<<<<<<<`,
--- `|||||||`, `=======` and `>>>>>>>` markers, and the three sides as
--- arrays of lines. `mid` and `base` are there only when the markers
--- carry a base (`merge.conflictStyle` diff3 or zdiff3). A run of
--- markers that does not close is not a block.
function M.blocks(lines)
  local out = {}
  local i, n = 1, #lines
  while i <= n do
    local label = lines[i]:match("^<<<<<<< ?(.*)$")
    if not label then
      i = i + 1
    else
      local top, mid, sep, bottom = i, nil, nil, nil
      local j = i + 1
      while j <= n do
        local l = lines[j]
        if not mid and not sep and l:match("^|||||||") then
          mid = j
        elseif not sep and l == "=======" then
          sep = j
        elseif sep and l:match("^>>>>>>>") then
          bottom = j
          break
        elseif l:match("^<<<<<<< ") then
          -- A block that opens inside this one: what we were reading
          -- was not a block. Start again from here.
          break
        end
        j = j + 1
      end
      if bottom then
        local function slice(from, to)
          local s = {}
          for k = from, to do
            s[#s + 1] = lines[k]
          end
          return s
        end
        table.insert(out, {
          top = top, mid = mid, sep = sep, bottom = bottom,
          ours = slice(top + 1, (mid or sep) - 1),
          base = mid and slice(mid + 1, sep - 1) or nil,
          theirs = slice(sep + 1, bottom - 1),
          label_ours = label,
          label_theirs = lines[bottom]:match("^>>>>>>> ?(.*)$") or "",
        })
        i = bottom + 1
      else
        i = j
      end
    end
  end
  return out
end

-- ------------------------------------------------------------------
-- Tokens
-- ------------------------------------------------------------------

--- `text` cut into words, runs of blank, newlines and single characters
--- of anything else. Concatenated back, the tokens are the text.
function M.tokens(text)
  local out = {}
  local i, n = 1, #text
  while i <= n do
    local word = text:match("^[%w_]+", i)
    if word then
      out[#out + 1] = word
      i = i + #word
    else
      local blank = text:match("^[ \t]+", i)
      if blank then
        out[#out + 1] = blank
        i = i + #blank
      else
        -- A newline, or one character of punctuation. Multi-byte
        -- characters are kept whole: a token cut through the middle of
        -- one would put half of it on each side of a merge.
        local c = text:match("^[%z\1-\127\194-\244][\128-\191]*", i) or text:sub(i, i)
        out[#out + 1] = c
        i = i + #c
      end
    end
  end
  return out
end

--- One token per line, for vim.diff. A newline token cannot be a line of
--- its own, so it goes as `\n` spelled out -- which no other token can
--- be, since a backslash is a token by itself.
local function encoded(tokens)
  if #tokens == 0 then
    return ""
  end
  local lines = {}
  for i, t in ipairs(tokens) do
    lines[i] = t == "\n" and "\\n" or t
  end
  return table.concat(lines, "\n") .. "\n"
end

--- The changes from token list `a` to token list `b`, as vim.diff
--- reports them over lines: `{ sa, ca, sb, cb }`, 1-based, with a
--- count of 0 for a pure insertion or deletion at that point.
function M.diff_tokens(a, b)
  local raw = vim.diff(encoded(a), encoded(b), {
    result_type = "indices",
    algorithm = "histogram",
  })
  local out = {}
  for _, h in ipairs(raw or {}) do
    out[#out + 1] = { sa = h[1], ca = h[2], sb = h[3], cb = h[4] }
  end
  return out
end

-- ------------------------------------------------------------------
-- Three-way merge
-- ------------------------------------------------------------------

--- The first base token a hunk replaces -- or, for a pure insertion,
--- the token it goes in front of. vim.diff reports an insertion by the
--- line it comes AFTER, with `sa` 0 for the very start.
local function at_token(h)
  return h.ca == 0 and h.sa + 1 or h.sa
end

--- The base tokens a hunk touches, as a closed range: the tokens it
--- replaces and the one after them, so that two edits to adjacent
--- tokens touch. An insertion touches the two tokens either side of the
--- point it goes in -- it has to sit somewhere, and those are where.
local function range(h)
  if h.ca == 0 then
    return h.sa, h.sa + 1
  end
  return h.sa, h.sa + h.ca
end

local function touch(x, y)
  local xl, xh = range(x)
  local yl, yh = range(y)
  return not (xh < yl or yh < xl)
end

local function same(x, y, o, t)
  if x.sa ~= y.sa or x.ca ~= y.ca or x.cb ~= y.cb then
    return false
  end
  for k = 0, x.cb - 1 do
    if o[x.sb + k] ~= t[y.sb + k] then
      return false
    end
  end
  return true
end

--- `base` with the changes ours and theirs each made to it applied
--- together, or nil and a reason when the two sets of changes touch.
---
--- Both sides identical is not a conflict, and neither is one side
--- having changed nothing; git resolves those by the line already, and
--- they can still arise inside a block, so they are answered the same
--- way here.
function M.merge3(base, ours, theirs)
  if ours == theirs then
    return ours
  end
  local B, O, T = M.tokens(base), M.tokens(ours), M.tokens(theirs)
  local ho = M.diff_tokens(B, O)
  local ht = M.diff_tokens(B, T)

  -- One list of edits over the base, each carrying the side whose
  -- replacement tokens it takes.
  local edits = {}
  for _, h in ipairs(ho) do
    edits[#edits + 1] = { h = h, side = O }
  end
  for _, h in ipairs(ht) do
    local dup = false
    for _, e in ipairs(edits) do
      if e.side == O and same(e.h, h, O, T) then
        dup = true
        break
      elseif e.side == O and touch(e.h, h) then
        return nil, "both sides changed the same words"
      end
    end
    if not dup then
      edits[#edits + 1] = { h = h, side = T }
    end
  end
  table.sort(edits, function(x, y)
    return at_token(x.h) < at_token(y.h)
  end)

  local out = {}
  local at = 1
  for _, e in ipairs(edits) do
    local h = e.h
    local lo = at_token(h)
    for k = at, lo - 1 do
      out[#out + 1] = B[k]
    end
    for k = 0, h.cb - 1 do
      out[#out + 1] = e.side[h.sb + k]
    end
    at = lo + h.ca
  end
  for k = at, #B do
    out[#out + 1] = B[k]
  end
  return table.concat(out)
end

return M
