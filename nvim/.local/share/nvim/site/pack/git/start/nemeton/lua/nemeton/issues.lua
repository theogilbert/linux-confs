-- The project's issues as a thing to search, kept on this side of the
-- forge.
--
-- GitLab's own `search=` reads the title and the description and
-- nothing anybody said under them, and it is a round trip a keystroke.
-- So every issue is kept here -- its fields, and every comment on it --
-- and a search is a walk over a table: as you type, over all of it.
--
-- Pure, like `threads.lua`: what the forge answered goes in, records
-- and matches come out, and what is on the disk and when to ask again
-- are `nemeton.issue_cache`'s. Keeping it in step is three questions,
-- because an issue changes in three ways the forge reports differently
-- -- see `issue_cache.lua` for which is asked when:
--
--   * its own fields: `updated_at` moves, and `updatedAfter` finds it;
--   * a comment added: `updated_at` does *not* move, but the project's
--     events say which issue it was on;
--   * a comment edited or deleted, or the issue deleted: nothing says
--     so at all, and only comparing every id against the forge's (the
--     sweep, `M.stale`) finds out.

local M = {}

--- The number in a GraphQL id: `gid://gitlab/Note/1201` is 1201, which
--- is what REST and everything else in this plugin call it.
local function number(gid)
  return tonumber(tostring(gid or ""):match("(%d+)$"))
end

--- One comment, as the cache keeps it: enough to search and to say who
--- said the thing that matched. Drawing it is done from the forge's
--- copy, fetched whole when the issue is opened.
local function note_of(node)
  return {
    id = number(node.id),
    body = node.body or "",
    author = vim.tbl_get(node, "author", "username"),
    created_at = node.createdAt,
    updated_at = node.updatedAt,
  }
end

M.note_of = note_of

--- One issue as GraphQL's page of them (`glab.issue_page`) has it, as
--- the cache keeps it.
---
--- `notes_after` is where the comments past the first hundred start,
--- for an issue with more of them than one page; nil once they are all
--- here.
function M.record(node)
  local notes = {}
  for _, n in ipairs(vim.tbl_get(node, "notes", "nodes") or {}) do
    table.insert(notes, note_of(n))
  end
  local more = vim.tbl_get(node, "notes", "pageInfo", "hasNextPage")
  return {
    iid = tonumber(node.iid),
    title = node.title or "",
    description = node.description or "",
    state = node.state,
    web_url = node.webUrl,
    created_at = node.createdAt,
    updated_at = node.updatedAt,
    closed_at = node.closedAt,
    confidential = node.confidential == true,
    notes_count = node.userNotesCount or #notes,
    upvotes = node.upvotes or 0,
    downvotes = node.downvotes or 0,
    author = vim.tbl_get(node, "author", "username"),
    assignees = vim.tbl_map(function(a)
      return a.username
    end, vim.tbl_get(node, "assignees", "nodes") or {}),
    labels = vim.tbl_map(function(l)
      return { title = l.title, color = l.color, text_color = l.textColor }
    end, vim.tbl_get(node, "labels", "nodes") or {}),
    notes = notes,
    notes_after = more and vim.tbl_get(node, "notes", "pageInfo", "endCursor") or nil,
  }
end

--- An empty cache. `cursor` is the newest `updated_at` the forge has
--- handed over, which is what the next sync asks from -- the forge's
--- clock and never this machine's. `noted` is the same for comments,
--- `swept` when the sweep last ran (seconds since the epoch, and this
--- machine's: it is a "how long ago", not a question for the forge).
function M.empty()
  return { issues = {}, cursor = nil, noted = nil, swept = nil, complete = false }
end

--- Puts `records` into `store`, over whatever it had under the same
--- numbers, and moves the cursor on. Answers how many were new.
---
--- Overwritten whole rather than merged field by field: a record is
--- everything the forge said about the issue at once, and a field it
--- has stopped saying -- an assignee taken off -- is one a merge would
--- keep.
function M.merge(store, records)
  local fresh = 0
  for _, r in ipairs(records) do
    if r.iid then
      if not store.issues[r.iid] then
        fresh = fresh + 1
      end
      store.issues[r.iid] = r
      if r.updated_at and (not store.cursor or r.updated_at > store.cursor) then
        store.cursor = r.updated_at
      end
    end
  end
  return fresh
end

--- The issues a page of the project's events says were commented on,
--- and the newest time among them, for asking from next time.
function M.commented(events)
  local iids, seen, newest = {}, {}, nil
  for _, e in ipairs(events or {}) do
    local note = e.note or {}
    if note.noteable_type == "Issue" and note.noteable_iid and not seen[note.noteable_iid] then
      seen[note.noteable_iid] = true
      table.insert(iids, note.noteable_iid)
    end
    if e.created_at and (not newest or e.created_at > newest) then
      newest = e.created_at
    end
  end
  table.sort(iids)
  return iids, newest
end

--- What one page of the sweep (`glab.issue_sweep`) says the cache has
--- wrong: the issues whose comments are not the ones kept -- one added,
--- one gone, one edited since -- and every number the page named, for
--- `M.gone` once every page is in.
function M.stale(store, nodes)
  local refetch, named = {}, {}
  for _, node in ipairs(nodes or {}) do
    local iid = tonumber(node.iid)
    if iid then
      named[iid] = true
      local kept = store.issues[iid]
      local theirs = vim.tbl_get(node, "notes", "nodes") or {}
      local differs = not kept or #theirs ~= #kept.notes
      if not differs then
        local by_id = {}
        for _, n in ipairs(kept.notes) do
          by_id[n.id] = n.updated_at
        end
        for _, n in ipairs(theirs) do
          if by_id[number(n.id)] ~= n.updatedAt then
            differs = true
            break
          end
        end
      end
      if differs then
        table.insert(refetch, iid)
      end
    end
  end
  return refetch, named
end

--- Takes out of `store` every issue the sweep did not name, which is an
--- issue the forge no longer has -- or one this token can no longer
--- see, which from here is the same thing. Answers how many went.
function M.gone(store, named)
  local dropped = 0
  for iid in pairs(store.issues) do
    if not named[iid] then
      store.issues[iid] = nil
      dropped = dropped + 1
    end
  end
  return dropped
end

------------------------------------------------------------------ searching

-- The words a search understands besides the ones it looks for, which
-- are the forge's own: what its filter bar writes when you pick from
-- it, so a filter learned there is one that works here.
local FILTERS = { label = true, assignee = true, author = true, state = true }

--- A search as typed, as the parts it is made of.
---
--- `label:bug`, `assignee:@me`, `author:alice`, `state:closed` filter;
--- `label:"needs docs"` takes a value with a space in it; `-label:wip`
--- and `-word` take away; `"a phrase"` is looked for whole; and every
--- other word is looked for on its own, all of them in the same issue.
--- `#12` is the issue of that number, however it reads.
---
--- Anything that does not parse as one of those is a word: a search
--- box that answers a stray quote with an error is a search box that
--- has stopped searching while you finish typing.
function M.parse(text)
  local q = { words = {}, without = {}, filters = {}, exclude = {}, iid = nil }
  local s = text or ""
  local at = 1
  while at <= #s do
    local ws = s:match("^%s+", at)
    if ws then
      at = at + #ws
    else
      local negate = s:sub(at, at) == "-"
      local from = negate and at + 1 or at
      local key, rest = s:match("^(%a+):()", from)
      local value
      if key and FILTERS[key:lower()] then
        if s:sub(rest, rest) == '"' then
          local close = s:find('"', rest + 1, true)
          value = s:sub(rest + 1, (close or #s + 1) - 1)
          at = (close or #s) + 1
        else
          value = s:match("^%S*", rest)
          at = rest + #value
        end
        if value ~= "" then
          local into = negate and q.exclude or q.filters
          key = key:lower()
          into[key] = into[key] or {}
          table.insert(into[key], value)
        end
      elseif s:sub(from, from) == '"' then
        local close = s:find('"', from + 1, true)
        value = s:sub(from + 1, (close or #s + 1) - 1)
        at = (close or #s) + 1
        if value ~= "" then
          table.insert(negate and q.without or q.words, value)
        end
      else
        value = s:match("^%S+", from) or ""
        at = from + #value
        local iid = value:match("^#(%d+)$")
        if iid and not negate then
          q.iid = tonumber(iid)
        elseif value ~= "" then
          table.insert(negate and q.without or q.words, value)
        end
      end
    end
  end
  return q
end

--- What a state filter says, as the forge's two states: "open" is what
--- people type and "opened" what GitLab stores.
local function state_of(word)
  word = word:lower()
  if word == "open" or word == "opened" then
    return "opened"
  end
  if word == "closed" or word == "close" then
    return "closed"
  end
  if word == "all" or word == "any" then
    return "all"
  end
  return word
end

--- Whether `issue` passes every filter of `q`. `me` is whose token this
--- is, for `@me`; `state` is the list's own state where the search does
--- not say one.
local function passes(issue, q, me, state)
  local function person(value)
    value = value:gsub("^@", "")
    if value:lower() == "me" then
      return me
    end
    return value
  end
  local function has_label(value)
    for _, l in ipairs(issue.labels) do
      if l.title:lower() == value:lower() then
        return true
      end
    end
    return false
  end
  local function assigned(value)
    if value:lower() == "none" then
      return #issue.assignees == 0
    end
    if value:lower() == "any" then
      return #issue.assignees > 0
    end
    local who = person(value)
    for _, a in ipairs(issue.assignees) do
      if a == who then
        return true
      end
    end
    return false
  end
  local tests = {
    label = has_label,
    assignee = assigned,
    author = function(value)
      return issue.author == person(value)
    end,
    state = function(value)
      local want = state_of(value)
      return want == "all" or issue.state == want
    end,
  }
  local said_state = q.filters.state ~= nil
  if not said_state and state and state ~= "all" and issue.state ~= state then
    return false
  end
  for key, values in pairs(q.filters) do
    for _, v in ipairs(values) do
      if not tests[key](v) then
        return false
      end
    end
  end
  for key, values in pairs(q.exclude) do
    for _, v in ipairs(values) do
      if tests[key](v) then
        return false
      end
    end
  end
  return true
end

--- Where `word` is in `text`, as vim's own `smartcase` would find it:
--- regardless of case unless the word has a capital in it. Plain, not
--- a pattern -- a search for `x86_64-linux` is a search for that.
---
--- `low` is the text lowered, made once per record (`lower_of`) rather
--- than per search.
local function find(text, low, word)
  if word:find("%u") then
    return text:find(word, 1, true)
  end
  return low:find(word:lower(), 1, true)
end

-- Record -> its texts lowered, kept rather than made again: a search
-- runs on every key typed, over every comment in the project, and
-- lowering all of them each time was half of what it cost. Weak and
-- keyed by the record, so the copy goes when a sync replaces the
-- record, and none of it reaches the disk.
local lowered = setmetatable({}, { __mode = "k" })

local function lower_of(issue)
  local low = lowered[issue]
  if not low then
    low = {
      title = issue.title:lower(),
      description = issue.description:lower(),
      labels = {},
      notes = {},
    }
    for i, l in ipairs(issue.labels) do
      low.labels[i] = l.title:lower()
    end
    for i, n in ipairs(issue.notes) do
      low.notes[i] = n.body:lower()
    end
    lowered[issue] = low
  end
  return low
end

--- The line of `text` around a match at [from, to], cut to `width`
--- display columns or so, with the match where it can be seen: what a
--- row of the list says about why it is there. `{ text, from, to }`,
--- the two offsets 1-based into the excerpt's own text.
local function excerpt(text, from, to, width)
  local line_start = from
  while line_start > 1 and text:sub(line_start - 1, line_start - 1) ~= "\n" do
    line_start = line_start - 1
  end
  local line_end = text:find("\n", to, true)
  line_end = line_end and line_end - 1 or #text
  local line = text:sub(line_start, line_end)
  local lead = line:match("^%s*")
  local a, b = from - line_start + 1 - #lead, to - line_start + 1 - #lead
  line = line:sub(#lead + 1)
  width = width or 60
  if #line <= width then
    return { text = line, from = a, to = b }
  end
  -- A third of the room before the match: enough of the sentence to
  -- read it as one, and the rest after, which is where it goes on.
  local start = math.max(1, a - math.floor(width / 3))
  start = math.min(start, math.max(1, #line - width + 1))
  -- Not in the middle of a character: a byte that continues one moves
  -- the cut to where the character starts.
  while start > 1 and line:byte(start) >= 0x80 and line:byte(start) < 0xC0 do
    start = start - 1
  end
  local stop = math.min(#line, start + width - 1)
  while stop < #line and line:byte(stop + 1) >= 0x80 and line:byte(stop + 1) < 0xC0 do
    stop = stop + 1
  end
  local cut = line:sub(start, stop)
  local before = start > 1 and "…" or ""
  local after = stop < #line and "…" or ""
  return {
    text = before .. cut .. after,
    from = a - start + 1 + #before,
    to = b - start + 1 + #before,
  }
end

M.excerpt = excerpt

-- How much a word found in each place counts: the title is what the
-- issue says it is, the description what it says it is about, and a
-- comment is somebody passing by.
local WEIGHT = { title = 4, label = 3, description = 2, comment = 1 }

--- The issues `q` finds in `store`, best first: `{ issue, score, why }`,
--- where `why` is nil for a title or a label that says it (the row
--- does) and otherwise `{ kind = "description"|"comment", author, excerpt }`
--- -- where the first word was found, for the line under the row.
---
--- Without words to rank by, the most recently touched first, which is
--- how the list is ordered without a search too.
---
--- `opts.me` is whose token this is, `opts.state` the list's own state
--- for a search that names none, `opts.width` how wide an excerpt is.
function M.search(store, q, opts)
  opts = opts or {}
  if type(q) == "string" then
    q = M.parse(q)
  end
  local out = {}
  for _, issue in pairs(store.issues or {}) do
    if
      (not q.iid or issue.iid == q.iid) and passes(issue, q, opts.me, q.iid and "all" or opts.state)
    then
      local score, why, missing = 0, nil, false
      local low = lower_of(issue)
      local function look(word)
        local best = nil
        local function try(kind, text, lowtext, author)
          local from, to = find(text, lowtext, word)
          if from then
            score = score + WEIGHT[kind]
            if not best or WEIGHT[kind] > WEIGHT[best.kind] then
              best = { kind = kind, author = author, text = text, from = from, to = to }
            end
          end
        end
        try("title", issue.title, low.title)
        for i, l in ipairs(issue.labels) do
          try("label", l.title, low.labels[i])
        end
        try("description", issue.description, low.description)
        for i, n in ipairs(issue.notes) do
          try("comment", n.body, low.notes[i], n.author)
        end
        return best
      end
      for _, word in ipairs(q.words) do
        local best = look(word)
        if not best then
          missing = true
          break
        end
        if not why then
          why = best
        end
      end
      for _, word in ipairs(q.without) do
        if not missing and look(word) then
          missing = true
        end
      end
      if not missing then
        -- No line under the row for a title or a label: the row draws
        -- both, and the word is picked out where it already is.
        if why and why.kind ~= "title" and why.kind ~= "label" then
          why = {
            kind = why.kind,
            author = why.author,
            excerpt = excerpt(why.text, why.from, why.to, opts.width),
          }
        else
          why = nil
        end
        table.insert(out, { issue = issue, score = score, why = why })
      end
    end
  end
  table.sort(out, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    if (a.issue.updated_at or "") ~= (b.issue.updated_at or "") then
      return (a.issue.updated_at or "") > (b.issue.updated_at or "")
    end
    return a.issue.iid > b.issue.iid
  end)
  return out
end

--- Whether a search has anything in it to search for, rather than only
--- filters: what decides that the list is ranked rather than ordered.
function M.has_words(q)
  if type(q) == "string" then
    q = M.parse(q)
  end
  return #q.words > 0
end

return M
