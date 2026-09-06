-- What a comment says, told from how it was typed.
--
-- A review comment is markdown, and until now it was drawn as the
-- characters it was written with: a link as `[the docs](https://…)`,
-- a heading as `## why`, a table as a row of pipes that line up only if
-- its author lined them up. The forge draws all three as something
-- else, and the reviewer reading them here is the one person on the
-- merge request reading the source of a page everybody else is reading
-- rendered.
--
-- So this module reads a note the way the page does. It is a parser and
-- nothing else -- strings in, tables out, no editor state and no
-- colours of its own -- because the drawing is `nemeton.threads`'s and
-- has to be the same drawing in all four windows that do it. What comes
-- out is two shapes:
--
--   `M.blocks(lines)`  the note as the blocks it is written in: prose,
--                      a heading, a table, a suggestion, a fence.
--   `M.inline(line)`   one line as the runs it is drawn as, each
--                      carrying in `ref` what it points at -- which is
--                      what `<C-]>` follows.
--
-- Deliberately a subset. A comment on a merge request is a paragraph,
-- a link, a list and now and then a table; a markdown implementation
-- is a fortnight, and every part of one that is not those is a part
-- that can be wrong about somebody's code review. What is not
-- recognised is drawn as it was typed, which is where the whole plugin
-- started.

local config = require("nemeton.config")

local M = {}

--- The sha a URL names, short, or nil for a URL that names no commit.
---
--- Both shapes the forge writes. `/-/commit/<sha>` is a commit of the
--- project; `merge_requests/N/diffs?commit_id=<sha>` is one of them as
--- this merge request shows it, which is what "copy link" gives you on
--- a row of the commit list you were reading. Eight digits because that
--- is the number GitLab itself prints -- the same string is on the row
--- the link came from.
---
--- Seven at least, or this is not a sha: a link to `/commit/main` names
--- a branch, and one to `/commit/HEAD` names wherever it has got to.
local function commit_sha(url)
  local sha = url:match("/commit/(%x+)") or url:match("[?&]commit_id=(%x+)")
  if sha and #sha >= 7 then
    return sha:sub(1, 8)
  end
  return nil
end

--- Whether a link's text is the commit's own name rather than words
--- about it -- which is how GitLab writes one itself, and the one case
--- where keeping the text as well would print the sha twice.
local function names(text, sha)
  return text:match("^%x+$") ~= nil and sha:lower():find(text:lower(), 1, true) == 1
end

--- A note as it is drawn, with every link to a commit replaced by the
--- commit's short sha.
---
--- A permalink to a commit is a hundred characters whose only content
--- is the forty at the end of it. Left whole it wraps a two-line
--- comment across five and pushes what was said around it off the page;
--- as `a1b2c3d4` it says the same thing in what git would have called
--- it anyway, and the reviewer who wants the page has the sha to go to
--- it with.
---
--- Display only, and deliberately not done where a note is parsed:
--- rewriting one sends its body back to the forge, and a comment that
--- came home from a round trip through this window with its links taken
--- out of it is a comment the plugin has quietly damaged.
function M.short_commits(text)
  if type(text) ~= "string" or not config.comments.short_commits then
    return text
  end
  -- Markdown links first: the target inside one is a URL too, and taken
  -- in the other order the sha replaces it and leaves `[the fix](a1b2)`
  -- pointing at nothing. The text of the link is what the author chose
  -- to call the commit and is kept.
  text = text:gsub("%[([^%]\n]*)%]%((%S-)%)", function(label, url)
    local sha = commit_sha(url)
    if not sha then
      return nil
    end
    return (label == "" or names(label, sha)) and sha or ("%s (%s)"):format(label, sha)
  end)
  return (
    text:gsub("https?://%S+", function(url)
      -- What ends a sentence is not part of what it links to. Taken with
      -- the URL it would be swallowed by the sha that replaces it.
      local tail = url:match("[%.,;:!%?%)%]]+$") or ""
      local sha = commit_sha(url:sub(1, #url - #tail))
      if not sha then
        return nil
      end
      return sha .. tail
    end)
  )
end

-- What a comment points at rather than says: a name somebody is being
-- called by, and a commit somebody is pointing at. Word-bounded, so an
-- email address is not a mention and a word in the middle of a sentence
-- is not a sha.
--
-- A sha needs a digit *and* a letter in it to count. Seven characters
-- of nothing but a-f is a word English happens to have -- "defaced",
-- "acceded" -- and seven of nothing but digits is a number somebody
-- wrote down; a commit is the thing that is both.
local REFERENCES = {
  { "@([%w][%w%._%-]*)", "mention", "NemetonMention" },
  {
    "(%x%x%x%x%x%x%x+)",
    "commit",
    "NemetonCommit",
    function(word)
      return #word <= 40 and word:match("%d") ~= nil and word:match("[a-fA-F]") ~= nil
    end,
  },
}

--- Whether the bytes [from, to) of `text` start a word: what stops
--- `theo@example` being a mention and `1a2b3c4dfix` being a commit.
local function bounded(text, from, to)
  local before = from > 1 and text:sub(from - 1, from - 1) or ""
  return not before:match("[%w_@%-%.]") and not text:sub(to + 1, to + 1):match("[%w_]")
end

--- The trailing punctuation of a URL, which is not part of it: what
--- ends a sentence a link is at the end of.
local function undotted(url)
  return url:sub(1, #url - #(url:match("[%.,;:!%?%)%]]+$") or ""))
end

--- One line of a comment as the runs it is drawn as: `{ text, hl }`,
--- with `ref` on the ones that point somewhere.
---
--- Returns the drawn text and those runs -- which concatenate back to
--- exactly it, so a caller can wrap the string and slice the colours to
--- match. The runs are nil where the line is drawn exactly as it was
--- typed with nothing on it to point at, which is most lines: a line
--- with one chunk on it is one chunk to slice, to measure and to draw.
---
--- What the drawn text is *not* is what is sent back. Rewriting a
--- comment posts the body its author wrote -- brackets, URLs and all --
--- because that is what the forge renders and what the next person to
--- edit it has to see.
function M.inline(text)
  if type(text) ~= "string" then
    return text, nil
  end
  local c = config.comments
  local found = {}

  --- Claims bytes [from, to] of the line, unless something with a
  --- better claim already has them. In the order they are looked for: a
  --- link owns the URL inside it, a URL owns the sha at the end of it,
  --- and neither is a mention of anybody.
  local function claim(from, to, drawn, hl, ref)
    for _, taken in ipairs(found) do
      if from <= taken.to and to >= taken.from then
        return
      end
    end
    table.insert(found, { from = from, to = to, text = drawn, hl = hl, ref = ref })
  end

  -- `[what it is called](where it goes)`, drawn as what it is called.
  --
  -- The URL is the half nobody reads and two thirds of the width: a
  -- sentence with three links in it is drawn as three hundred columns
  -- of protocol and path, wrapped across five lines, with the words
  -- somebody wrote scattered between them. The link keeps where it
  -- goes -- in `ref`, for the key that follows it -- and gives up the
  -- room.
  if c.links then
    local at = 1
    while true do
      local from, to, label, url = text:find("%[([^%]\n]*)%]%((%S-)%)", at)
      if not from then
        break
      end
      at = to + 1
      -- `![alt](src)` is a picture, which a terminal has nowhere to
      -- put: it is drawn as what its author said it was, and the `!`
      -- that made it a picture goes with the brackets.
      local image = from > 1 and text:sub(from - 1, from - 1) == "!"
      local sha = commit_sha(url)
      if sha and c.short_commits then
        claim(
          from,
          to,
          (label == "" or names(label, sha)) and sha or label,
          "NemetonCommit",
          { kind = "commit", text = sha, href = url }
        )
      else
        local drawn = label
        if drawn == "" then
          drawn = image and "image" or url
        end
        claim(image and from - 1 or from, to, drawn, "NemetonLink", {
          kind = "link",
          text = label,
          href = url,
        })
      end
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
    local sha = c.short_commits and commit_sha(url)
    if sha then
      claim(from, from + #url - 1, sha, "NemetonCommit", {
        kind = "commit",
        text = sha,
        href = url,
      })
    elseif c.links then
      claim(from, from + #url - 1, url, "NemetonLink", { kind = "link", text = url, href = url })
    end
  end

  if c.references then
    for _, kind in ipairs(REFERENCES) do
      local from, to, word = 0, 0, nil
      at = 1
      while true do
        from, to, word = text:find(kind[1], at)
        if not from then
          break
        end
        at = to + 1
        if bounded(text, from, to) and (not kind[4] or kind[4](word)) then
          claim(from, to, text:sub(from, to), kind[3], { kind = kind[2], text = word })
        end
      end
    end
  end

  if #found == 0 then
    return text, nil
  end
  table.sort(found, function(a, b)
    return a.from < b.from
  end)
  local runs, drawn, cursor = {}, {}, 1
  for _, mark in ipairs(found) do
    if mark.from > cursor then
      table.insert(runs, { text:sub(cursor, mark.from - 1) })
    end
    table.insert(runs, { mark.text, mark.hl, ref = mark.ref })
    cursor = mark.to + 1
  end
  if cursor <= #text then
    table.insert(runs, { text:sub(cursor) })
  end
  for _, run in ipairs(runs) do
    table.insert(drawn, run[1])
  end
  return table.concat(drawn), runs
end

--- A whole body as it is drawn, as one string: what the windows that
--- show a comment as a single line want, where there is no room for
--- colours and nothing to follow a link with.
function M.plain(text)
  if type(text) ~= "string" then
    return text
  end
  local out = {}
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    table.insert(out, (M.inline(line)))
  end
  return table.concat(out, "\n")
end

--- The cells of a table row, or nil for a line that is not one.
---
--- The outer pipes are optional in markdown and usually written; either
--- way what is between them is the row. A cell is trimmed, because the
--- spaces around it are how its author lined the source up and not
--- anything they wrote.
local function cells(line)
  if not line:find("|", 1, true) then
    return nil
  end
  local out = {}
  for cell in (vim.trim(line):gsub("^|", ""):gsub("|%s*$", "") .. "|"):gmatch("(.-)|") do
    table.insert(out, vim.trim(cell))
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

--- The lines of a note, as the blocks it is written in.
---
--- One pass, and greedy: a fence swallows everything up to the next
--- one, a table swallows every row under its head. What is left is
--- prose, a line at a time, which is what a comment mostly is.
---
--- Each block is `{ kind = ... }` and carries what its kind needs:
---
---   prose       `text`
---   heading     `text`, `level`
---   table       `rows` (the head first), `align`
---   suggestion  `lines`, `above`, `below`, `fence`, `close`
---   code        `lines`, `fence`, `close`
---
--- A fence nobody closed is applied anyway, with `close` nil -- which
--- is what GitLab does with one, and what one looks like while it is
--- still being typed.
function M.blocks(lines)
  local c = config.comments
  local out, i = {}, 1
  while i <= #lines do
    local line = lines[i]
    local fence = line:match("^%s*```(.*)$")
    local heading, said = line:match("^(#+)%s+(.*)$")
    local align = c.tables and alignments(lines[i + 1]) or nil
    if fence then
      local body, close, j = {}, nil, i + 1
      while j <= #lines do
        if lines[j]:match("^%s*```") then
          close = lines[j]
          break
        end
        table.insert(body, lines[j])
        j = j + 1
      end
      if fence:match("^suggestion") then
        table.insert(out, {
          kind = "suggestion",
          lines = body,
          fence = line,
          close = close,
          -- `suggestion:-N+M` is "this line, the N above it and the M
          -- below" -- counted from the line the thread is anchored to.
          above = tonumber(fence:match("%-(%d+)")) or 0,
          below = tonumber(fence:match("%+(%d+)")) or 0,
        })
      else
        table.insert(out, { kind = "code", lines = body, fence = line, close = close })
      end
      i = j + 1
    elseif heading and c.headings and #heading <= 6 then
      table.insert(out, { kind = "heading", text = said, level = #heading })
      i = i + 1
    elseif align and cells(line) then
      local rows = { cells(line) }
      local j = i + 2
      while j <= #lines and cells(lines[j]) do
        table.insert(rows, cells(lines[j]))
        j = j + 1
      end
      table.insert(out, { kind = "table", rows = rows, align = align })
      i = j
    else
      table.insert(out, { kind = "prose", text = line })
      i = i + 1
    end
  end
  return out
end

return M
