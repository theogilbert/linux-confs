-- What a comment says, told from how it was typed.
--
-- A review comment is markdown, and until now it was drawn as the
-- characters it was written with: a link as `[the docs](https://…)`, a
-- heading as `## why`, `**must**` as two asterisks and a word, a table
-- as a row of pipes that line up only if its author lined them up. The
-- forge draws every one of them as something else, and the reviewer
-- reading them here is the one person on the merge request reading the
-- source of a page everybody else is reading rendered.
--
-- So this module reads a note the way the page does. The reading is
-- render.nvim's (`render.markdown`); what is here is what only a review
-- on GitLab has -- a link to another comment, a commit's permalink, `#12`
-- and `!7` and `@name`, a label, a suggestion -- handed to it as hooks,
-- and this plugin's colours as the groups it draws in. Still strings in
-- and tables out, because the drawing is `nemeton.threads`'s and has to
-- be the same drawing in all four windows that do it. Two shapes:
--
--   `M.blocks(lines)`  the note as the blocks it is written in: prose,
--                      a heading, a citation, a table, a suggestion, a
--                      fence.
--   `M.inline(line)`   one line as the runs it is drawn as, each
--                      carrying in `ref` what it points at -- which is
--                      what `<C-]>` follows -- and in `style` the
--                      weight it was written with.
--
-- Deliberately a subset. A comment on a merge request is a paragraph, a
-- link, a word somebody leant on, a list and now and then a table; a
-- markdown implementation is a fortnight, and every part of one that is
-- not those is a part that can be wrong about somebody's code review.
-- What is not recognised is drawn as it was typed, which is where the
-- whole plugin started.

local config = require("nemeton.config")
local render = require("render.markdown")

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

--- The comment a URL names, as the merge request it is on and the note
--- it is: two values, or nil for a URL that names no comment.
---
--- `#note_<id>` is the anchor GitLab's own "copy link" gives you on a
--- comment, on the merge request's page and on its diff alike, and it
--- is the only spelling there is: the forge has a short reference for
--- an issue, a merge request, a label and a user, and none for a note.
--- So this is what a reviewer pointing at another thread has pasted,
--- and it is what is worth reading as one.
---
--- The merge request as well as the note, because the id on its own
--- says nothing about which review it is in -- and a comment on
--- somebody else's merge request is a page to open rather than a thread
--- to walk to.
local function comment_at(url)
  local iid = url:match("/%-/merge_requests/(%d+)")
  local note = url:match("#note_(%d+)")
  if iid and note then
    return iid, note
  end
  return nil
end

--- What a comment is called, for a link to one whose author wrote no
--- words of their own over it.
---
--- A note permalink is a hundred characters of which twelve are the
--- content, and the same argument as `M.short_commits`: `!7 (comment
--- 1234)` says which review and which comment in what the forge calls
--- both, and the reader who wants the page has `<C-]>` to get to it.
--- The id is kept and not dropped, because a comment pointing at two
--- threads must not draw them as the same words.
---
--- What it is deliberately *not* is "alice on src/app.lua:42", which
--- this could say by asking the session what the id resolves to. Two
--- reasons, and either would do. It is the name the forge gives the
--- thing, so it is the same string on the page everybody else is
--- reading and the one a reviewer can say out loud; and a name that
--- came from resolving the id would be one this window could not draw
--- for a comment on another merge request, leaving the same link drawn
--- two ways depending on what happened to be open.
local function called(iid, note)
  return ("!%s (comment %s)"):format(iid, note)
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
-- called by, a commit somebody is pointing at, and the issue or the
-- merge request they are pointing at -- `#12`, `!7`, and either with
-- a project in front of it, `group/proj#12`, the way GitLab spells a
-- reference to one somewhere else. Word-bounded, so an email address
-- is not a mention and a word in the middle of a sentence is not a
-- sha.
--
-- A sha needs a digit *and* a letter in it to count. Seven characters
-- of nothing but a-f is a word English happens to have -- "defaced",
-- "acceded" -- and seven of nothing but digits is a number somebody
-- wrote down; a commit is the thing that is both.
--
-- The issue and the merge request are captured whole, project and
-- all, because the project is the half that says which forge page
-- the number is on and `follow` is the one that reads it.
local REFERENCES = {
  { "@([%w][%w%._%-]*)", "mention", "NemetonMention" },
  { "([%w%._%-/]*#%d+)", "issue", "NemetonLink" },
  { "([%w%._%-/]*!%d+)", "mr", "NemetonLink" },
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

-- What each reading is drawn in: this plugin's groups rather than
-- render.nvim's, so a colourscheme of the review's own is the one used.
local GROUPS = {
  bold = "NemetonBold",
  italic = "NemetonItalic",
  strike = "NemetonStrike",
  code = "NemetonCode",
  math = "NemetonMath",
  link = "NemetonLink",
}

--- A link a review knows better than "a page": another comment, drawn
--- as what the forge calls it, and a commit, drawn as its sha.
---
--- The comment before the commit: a link to a thread on a diff carries
--- the commit it was written against as well
--- (`…/diffs?commit_id=…#note_12`), and what its author was pointing at
--- is the argument and not the push.
local function link(url, label)
  local iid, note = comment_at(url)
  if iid then
    return {
      text = label ~= "" and label or called(iid, note),
      hl = "NemetonLink",
      ref = { kind = "thread", text = note, iid = tonumber(iid), href = url },
    }
  end
  local sha = commit_sha(url)
  if sha and config.comments.short_commits then
    return {
      text = (label == "" or names(label, sha)) and sha or label,
      hl = "NemetonCommit",
      ref = { kind = "commit", text = sha, href = url },
    }
  end
  return nil
end

--- The same, for a URL written on its own.
local function bare(url)
  local c = config.comments
  local iid, note
  if c.links then
    iid, note = comment_at(url)
  end
  if iid then
    return {
      text = called(iid, note),
      hl = "NemetonLink",
      ref = { kind = "thread", text = note, iid = tonumber(iid), href = url },
    }
  end
  local sha = c.short_commits and commit_sha(url)
  if sha then
    return { text = sha, hl = "NemetonCommit", ref = { kind = "commit", text = sha, href = url } }
  end
  return nil
end

--- `#12`, `!7`, `@name` and a sha, claimed where nothing has a better
--- claim on them.
local function references(text, claim)
  for _, kind in ipairs(REFERENCES) do
    local at = 1
    while true do
      local from, to, word = text:find(kind[1], at)
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

--- `~bug` and `~"needs work"`, a label named in a sentence: a chip in
--- the label's colour, as the page draws it. Only a label the project
--- has (`nemeton.labels`) -- "~5 minutes" is an estimate -- and not the
--- opener of `~struck~`, which is GitLab's strikethrough. The one
--- reading here that asks something outside the text, because the
--- colour is the whole of what makes it a label.
local function labelled(text, claim)
  local labels = require("nemeton.labels")
  for _, shape in ipairs({ '~"([^"\n]+)"', "~([%w_][%w_%-%.:&]*)" }) do
    local at = 1
    while true do
      local from, to, name = text:find(shape, at)
      if not from then
        break
      end
      at = to + 1
      if not shape:find('"', 1, true) then
        local trimmed = name:gsub("[%.:]+$", "")
        to = to - (#name - #trimmed)
        name = trimmed
      end
      local before = from > 1 and text:sub(from - 1, from - 1) or ""
      local colour = labels.colour(name)
      if colour and not before:match("[%w_~]") and text:sub(to + 1, to + 1) ~= "~" then
        claim(
          from,
          to,
          " " .. name .. " ",
          labels.hl({ title = name, color = colour.color, text_color = colour.text_color }),
          { kind = "label", text = name }
        )
      end
    end
  end
end

--- A fence GitLab reads as something else: ```suggestion:-N+M, the
--- lines that would replace this one, the N above it and the M below
--- -- counted from the line the thread is anchored to.
local function fence(block)
  if not block.info:match("^suggestion") then
    return nil
  end
  return {
    kind = "suggestion",
    lines = block.lines,
    fence = block.fence,
    close = block.close,
    row = block.row,
    above = tonumber(block.info:match("%-(%d+)")) or 0,
    below = tonumber(block.info:match("%+(%d+)")) or 0,
  }
end

--- What render.nvim is asked to read, out of `config.comments` as it is
--- now: a spec or a user turns a reading off between two notes.
local function read()
  local c = config.comments
  local function flag(v)
    return v and true or false
  end
  return {
    links = flag(c.links),
    styles = flag(c.styles),
    math = flag(c.math),
    headings = flag(c.headings),
    tables = flag(c.tables),
    citations = flag(c.citation),
    lists = flag(c.bullets),
    groups = GROUPS,
    link = link,
    url = bare,
    claims = c.references and { references, labelled } or nil,
    fence = fence,
  }
end

M.unescaped = render.unescaped

--- One line of a comment as the runs it is drawn as (`render.markdown
--- .inline`): the drawn text, and `{ text, hl }` runs with `ref` on the
--- ones that point somewhere -- nil where the line is drawn as typed.
---
--- What the drawn text is *not* is what is sent back. Rewriting a
--- comment posts the body its author wrote -- brackets, URLs and all --
--- because that is what the forge renders and what the next person to
--- edit it has to see.
function M.inline(text)
  return render.inline(text, read())
end

--- A whole body as it is drawn, as one string: what the windows that
--- show a comment as a single line want, where there is no room for
--- colours and nothing to follow a link with.
function M.plain(text)
  return render.plain(text, read())
end

--- The lines of a note, as the blocks it is written in
--- (`render.markdown.blocks`), with a ```suggestion fence read as one:
--- `{ kind = "suggestion", lines, above, below, fence, close }`.
function M.blocks(lines)
  return render.blocks(lines, read())
end

return M
