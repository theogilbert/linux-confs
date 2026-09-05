-- The merge request you are about to open.
--
-- Everything `glab mr create` would ask at a prompt, on one screen and
-- in any order: what it is called, whether it is a draft, what it says,
-- where it goes, what it is labelled. A prompt asks those one at a
-- time, in an order it chose, and a change of mind three answers in
-- costs all three; a window is a thing you can go back up.
--
-- Under them, the three facts that decide whether it should go out at
-- all: what CI last made of the branch, how many files it touches and
-- how many lines that is. Nobody types those -- they are asked of the
-- forge and of git -- and they are half the reason this is a window
-- rather than five prompts. The other half is that the window can be
-- closed and opened again with everything still in it: a merge request
-- is written between two interruptions like anything else.

local config = require("nemeton.config")
local detail = require("nemeton.detail")
local glab = require("nemeton.glab")
local log = require("nemeton.log")
local marks = require("nemeton.marks")
local session = require("nemeton.session")
local win = require("nemeton.win")

local M = {}

M.win = nil
M.buf = nil

-- What has been typed and not sent, one per branch.
--
-- Per branch because that is what a merge request is of: switch to
-- another one and the title written for this is not a title for that.
--
-- For this editor session only, and written nowhere. A comment kept
-- unsent lives on the forge, which is why it is still there tomorrow;
-- a merge request that has not been opened yet exists in no place but
-- this table, and a plugin that starts writing half-finished merge
-- requests into somebody's state directory is a plugin that has to
-- decide when to delete them again.
local kept = {}

-- The branch the window on the screen is for, its form, and the two
-- lists the pickers choose from. All of it is dropped when the merge
-- request goes out.
local state = nil
-- Line number (1-based) -> the field written on it.
local rows = {}

--- The form for a branch, made the first time it is asked for.
---
--- `target` is nil rather than "main" until the forge has said which
--- branch is the default: a guess written into the window is a guess
--- the reviewer has to notice is wrong.
local function form(branch)
  kept[branch] = kept[branch]
    or {
      title = "",
      draft = false,
      description = "",
      target = nil,
      labels = {},
      -- What has been fetched about the branch, kept beside what was
      -- typed so that closing the window and opening it again shows
      -- the facts it had rather than a row of dots.
      ci = nil,
      stats = nil,
      counted = nil,
    }
  return kept[branch]
end

function M.close()
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    vim.api.nvim_win_close(M.win, true)
  end
  M.win, M.buf, rows = nil, nil, {}
end

local function up()
  return M.win ~= nil and vim.api.nvim_win_is_valid(M.win) and M.buf ~= nil
end

-- The column every value starts in, so the labels read as a column and
-- the values as another.
local GUTTER = "  "
local COLUMN = 15

--- One field: its name, dim, and what it is set to.
---
--- `nil` for a value that has not been chosen draws an em dash rather
--- than an empty column -- "nothing here" and "nothing fetched yet"
--- look the same on a blank line, and only one of them is something to
--- do about.
local function field(out, hls, name, value, hl)
  local label = GUTTER .. name
  local pad = math.max(1, COLUMN - #label)
  table.insert(hls, { row = #out, col = 0, end_col = #label, hl = "NemetonMeta" })
  local text = value
  if not text or text == "" then
    text, hl = "—", "NemetonMeta"
  end
  local first = vim.split(text, "\n", { plain = true })
  table.insert(hls, {
    row = #out,
    col = #label + pad,
    end_col = #label + pad + #first[1],
    hl = hl or "NemetonThread",
  })
  table.insert(out, label .. (" "):rep(pad) .. first[1])
  -- A description is several lines and the rest of them line up under
  -- the first: the label column is what makes this a form rather than
  -- a paragraph with a word in front of it.
  for i = 2, #first do
    table.insert(hls, {
      row = #out,
      col = COLUMN,
      end_col = COLUMN + #first[i],
      hl = hl or "NemetonThread",
    })
    table.insert(out, (" "):rep(COLUMN) .. first[i])
  end
end

--- The window's lines, its highlights, and which field each line is.
function M.lines(f, branch)
  local out, hls, map = {}, {}, {}
  --- Every line `fn` draws is a line of `name`'s field, which is how
  --- the cursor knows what <CR> is about to change.
  local function at(name, fn)
    local before = #out + 1
    fn()
    for i = before, #out do
      map[i] = name
    end
  end

  table.insert(out, "")
  at("title", function()
    field(out, hls, "title", f.title, "NemetonAuthor")
  end)
  at("draft", function()
    -- "yes" in the colour of something owed an action, because that is
    -- what a draft merge request is: one nobody is being asked to
    -- review yet.
    field(out, hls, "draft", f.draft and "yes" or "no", f.draft and "NemetonDraft" or nil)
  end)
  at("target", function()
    field(out, hls, "target", f.target, "NemetonBranch")
  end)
  at("labels", function()
    field(out, hls, "labels", #f.labels > 0 and table.concat(f.labels, ", ") or nil)
  end)
  table.insert(out, "")
  at("description", function()
    field(out, hls, "description", f.description)
  end)

  -- The facts, under a blank line: nothing below it is typed, and the
  -- gap is what says so.
  table.insert(out, "")
  local ci = f.ci
  local parts = {}
  if ci == false then
    -- Asked, and the branch has never been built -- which on a branch
    -- that has not been pushed is most of what that means.
    table.insert(parts, { { "no pipeline on this branch", "NemetonMeta" } })
  elseif ci then
    table.insert(parts, { { ci.glyph .. " " .. ci.word, ci.hl } })
  else
    table.insert(parts, { { "…", "NemetonMeta" } })
  end
  if f.counted == false then
    -- No ref to compare against: the target branch is not here, which
    -- is a fetch away and not this window's business to do.
    table.insert(
      parts,
      { { ("nothing here to compare %s against"):format(f.target or "it"), "NemetonMeta" } }
    )
  else
    -- In the colours the queue counts a merge request in, because it is
    -- the same fact about the same branch: how much of the codebase
    -- this asks somebody to read.
    table.insert(parts, detail.stats_chunks(f.stats) or { { "…", "NemetonMeta" } })
  end

  local line = GUTTER
  for i, part in ipairs(parts) do
    if i > 1 then
      table.insert(hls, { row = #out, col = #line, end_col = #line + 3, hl = "NemetonMeta" })
      line = line .. " · "
    end
    for _, chunk in ipairs(part) do
      table.insert(hls, { row = #out, col = #line, end_col = #line + #chunk[1], hl = chunk[2] })
      line = line .. chunk[1]
    end
  end
  table.insert(out, line)
  table.insert(out, "")
  local from_to = ("%sfrom %s"):format(GUTTER, branch)
  table.insert(hls, { row = #out, col = #GUTTER, end_col = #GUTTER + 4, hl = "NemetonMeta" })
  table.insert(hls, { row = #out, col = #GUTTER + 5, end_col = #from_to, hl = "NemetonBranch" })
  table.insert(out, from_to)
  return out, hls, map
end

--- Rewrites the window in place, keeping the cursor on the field it was
--- on -- editing a field and being moved off it is a window that
--- fights back.
local function draw()
  if not (up() and state) then
    return
  end
  local was = rows[vim.api.nvim_win_get_cursor(M.win)[1]]
  local lines, hls, map = M.lines(state.form, state.branch)
  rows = map
  vim.bo[M.buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.bo[M.buf].modifiable = false
  marks.paint(M.buf, hls)
  if was then
    for i, name in pairs(rows) do
      if name == was then
        pcall(vim.api.nvim_win_set_cursor, M.win, { i, 0 })
        break
      end
    end
  end
end

--- git, the way the rest of this plugin runs it: logged, and answered
--- on the main loop.
local function git(root, args, cb)
  local cmd = vim.list_extend({ "git" }, args)
  local done = log.exec(cmd, { cwd = root })
  vim.system(cmd, { text = true, cwd = root }, function(res)
    done(res.code, res.stderr)
    vim.schedule(function()
      cb(res.code == 0, res.stdout or "")
    end)
  end)
end

--- How much the branch changes, counted against the branch it would go
--- into.
---
--- git rather than the forge, which every other number in this plugin
--- comes from, and for a reason particular to this window: the merge
--- request does not exist, and neither does the diff endpoint that
--- would answer this. `compare` on the forge would answer it -- for the
--- branch as the forge last saw it, which before the push this window
--- is about to do is the wrong commits or no branch at all.
---
--- `A...B`, three dots: what this branch adds since it left the target,
--- and not everything that has happened on the target since. That is
--- the number GitLab will put on the merge request.
---
--- `origin/<target>` before `<target>`: the remote-tracking ref is what
--- the merge request will be measured against, and a local branch of
--- the same name may be months behind it. Neither being here is a real
--- answer -- said in the window rather than counted as zero.
local function count(root, target, cb)
  local tries = { "origin/" .. target, target }
  local function attempt(i)
    if i > #tries then
      cb(nil)
      return
    end
    git(root, { "diff", "--numstat", tries[i] .. "...HEAD" }, function(ok, out)
      if not ok then
        attempt(i + 1)
        return
      end
      local stats = { files = 0, added = 0, removed = 0 }
      for line in out:gmatch("[^\n]+") do
        -- A binary file is counted as a file and as no lines: git
        -- writes "-\t-\t<path>" for one, which is what it changed as
        -- far as anybody reviewing it is concerned.
        local added, removed = line:match("^(%S+)%s+(%S+)%s")
        if added then
          stats.files = stats.files + 1
          stats.added = stats.added + (tonumber(added) or 0)
          stats.removed = stats.removed + (tonumber(removed) or 0)
        end
      end
      cb(stats)
    end)
  end
  attempt(1)
end

--- Counts the change again, for after the target branch is changed.
local function recount()
  local f, root, target = state.form, state.root, state.form.target
  if not target then
    return
  end
  count(root, target, function(stats)
    f.stats, f.counted = stats, stats ~= nil
    draw()
  end)
end

--- The facts under the form: what CI made of the branch, and how much
--- it changes. Asked again on `r`, because both of them move.
local function facts()
  local f, root, branch = state.form, state.root, state.branch
  glab.branch_pipelines(root, branch, function(data)
    local newest = type(data) == "table" and data[1] or nil
    f.ci = (newest and detail.status(newest.status)) or false
    draw()
  end)
  recount()
end

--- The branches, for the target picker -- and, the first time, for the
--- target itself.
local function branches()
  local f, root = state.form, state.root
  glab.branches(root, function(data)
    local names, fallback = {}, nil
    -- A forge that would not answer leaves an empty list rather than
    -- nil: "asked, and there is nothing" is a question the picker can
    -- answer another way, and "not asked yet" is one it cannot.
    data = type(data) == "table" and data or {}
    for _, b in ipairs(data) do
      if b.name then
        table.insert(names, b.name)
        if b.default then
          fallback = b.name
        end
      end
    end
    state.branches = names
    if not f.target and fallback then
      f.target = fallback
      draw()
      recount()
    end
  end)
end

--- Strips the prefix GitLab reads a draft off, and says whether it was
--- there.
---
--- Typing "Draft: " in front of a title is how a draft merge request is
--- made on the web, and somebody who has done it a hundred times will
--- do it here. The prefix is taken off and the switch is set instead:
--- the same merge request either way, and the title stays the title.
local function undraft(title)
  local rest = title:match("^[Dd][Rr][Aa][Ff][Tt]:%s*(.*)$") or title:match("^WIP:%s*(.*)$")
  if rest then
    return rest, true
  end
  return title, false
end

local edit = {}

function edit.title()
  vim.ui.input({ prompt = "title: ", default = state.form.title }, function(text)
    if text == nil then
      return
    end
    local title, drafted = undraft(vim.trim(text))
    state.form.title = title
    state.form.draft = state.form.draft or drafted
    draw()
  end)
end

function edit.draft()
  state.form.draft = not state.form.draft
  draw()
end

function edit.description()
  require("nemeton.compose").open({
    title = ("description  ·  !%s"):format(state.form.title ~= "" and state.form.title or "new"),
    body = state.form.description,
    -- Kept, not sent: the whole window is a thing being kept until it
    -- is opened, and `<C-s>` here means what it means everywhere else
    -- in this plugin.
    default = "keep",
    -- ...and an empty one is an answer: a description written and then
    -- thought better of has to be able to go away again.
    empty = true,
    on_draft = function(text)
      state.form.description = text
      draw()
    end,
  })
end

function edit.target()
  local names = state.branches
  if not names then
    session.notify("still asking the forge which branches this project has")
    return
  end
  if #names == 0 then
    -- Nothing came back -- an old forge, a project the token cannot
    -- read the branches of -- so the question is asked plainly rather
    -- than not at all.
    vim.ui.input({ prompt = "target branch: ", default = state.form.target }, function(text)
      if text and vim.trim(text) ~= "" then
        state.form.target = vim.trim(text)
        draw()
        recount()
      end
    end)
    return
  end
  vim.ui.select(names, { prompt = "target branch" }, function(choice)
    if choice then
      state.form.target = choice
      draw()
      recount()
    end
  end)
end

function edit.labels()
  local f = state.form
  if not state.labels then
    session.notify("still asking the forge which labels this project has")
    return
  end
  local on = {}
  for _, name in ipairs(f.labels) do
    on[name] = true
  end
  local names = state.labels
  if #names == 0 then
    -- "This project has no labels" and "the forge would not say which
    -- labels this project has" are different answers, and only one of
    -- them means typing them out is the best that can be done. Said
    -- once, here, where the difference is about to cost something.
    if state.labels_error then
      session.notify(
        "could not ask which labels this project has: "
          .. state.labels_error
          .. " — type them instead",
        vim.log.levels.WARN
      )
    end
    vim.ui.input(
      { prompt = "labels (comma-separated): ", default = table.concat(f.labels, ",") },
      function(text)
        if text == nil then
          return
        end
        local out = {}
        for part in text:gmatch("[^,]+") do
          table.insert(out, vim.trim(part))
        end
        f.labels = out
        draw()
      end
    )
    return
  end
  -- One choice, one label, on or off -- and then the list again, with
  -- the tick moved, until it is dismissed. A picker that returns a set
  -- is a picker every `vim.ui.select` in the wild would have to
  -- implement; a picker that comes back is one any of them can be.
  -- Labels come in threes -- the team, the area, the release -- and
  -- pressing the key three times to say so is three times as long a
  -- way of saying it.
  local items = {}
  for _, name in ipairs(names) do
    table.insert(items, (on[name] and "✓ " or "  ") .. name)
  end
  vim.ui.select(items, {
    prompt = #f.labels > 0 and ("labels · " .. table.concat(f.labels, ", ")) or "labels",
  }, function(choice, index)
    if not choice then
      return
    end
    local name = names[index]
    if on[name] then
      for i, had in ipairs(f.labels) do
        if had == name then
          table.remove(f.labels, i)
          break
        end
      end
    else
      table.insert(f.labels, name)
    end
    draw()
    -- ...on the next tick, so the picker that is closing is closed
    -- before the next one opens: two floats fighting over the cursor is
    -- one of them left on the screen.
    vim.schedule(edit.labels)
  end)
end

--- Opens it, with everything the window collected.
local function submit()
  local f, root, branch = state.form, state.root, state.branch
  if f.title == "" then
    session.notify("a merge request needs a title", vim.log.levels.WARN)
    return
  end
  local back = win.came_from()
  M.close()
  back()
  session.notify("opening a merge request for " .. branch .. "…")
  glab.mr_create(root, {
    title = f.title,
    body = f.description,
    target = f.target,
    labels = f.labels,
    draft = f.draft,
  }, function(url, err)
    if not url then
      -- The window is gone and what was typed is not: the failure is
      -- usually the push, and the fix is a key away rather than a
      -- retype away.
      session.notify("could not open it: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    kept[branch] = nil
    session.notify(url)
    -- The queue was a list of what there is to review, and it is out of
    -- date the moment this lands -- but it is also not what is being
    -- looked at any more. What was just opened is: writing a merge
    -- request is the last thing you do to a branch, and reading what
    -- came of it is the next. So the popup goes, and the review opens
    -- on the merge request that was made.
    require("nemeton.list").close()
    local iid = tonumber(url:match("/merge_requests/(%d+)"))
    if iid then
      require("nemeton").open(iid)
    end
  end)
end

--- What the two pickers have to choose from, once the forge has said.
---
--- `nil` where it has not answered yet, which is the difference the
--- keys turn on: a project with no labels is a question to ask another
--- way, and a call still in flight is one to wait for.
function M.choices()
  return { branches = state and state.branches, labels = state and state.labels }
end

--- The window. Everything typed into it before is still in it.
function M.open()
  local root = session.root()
  if not root then
    session.notify("not inside a git repository", vim.log.levels.ERROR)
    return
  end
  local branch = session.branch()
  if not branch then
    session.notify("not on a branch — a merge request comes from one", vim.log.levels.WARN)
    return
  end

  M.close()
  state = {
    root = root,
    branch = branch,
    form = form(branch),
    branches = state and state.branch == branch and state.branches or nil,
    labels = state and state.branch == branch and state.labels or nil,
    labels_error = state and state.branch == branch and state.labels_error or nil,
  }

  local width = math.min(math.floor(vim.o.columns * 0.7), 84)
  local height = math.max(8, math.floor(vim.o.lines * 0.4))
  M.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[M.buf].bufhidden = "wipe"
  local back = win.came_from()
  M.win = vim.api.nvim_open_win(M.buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " new merge request ",
    title_pos = "center",
  })
  vim.wo[M.win].cursorline = true
  vim.wo[M.win].wrap = false

  local k = config.keys.create
  vim.wo[M.win].winbar = detail.hint({
    { k.field, "change" },
    { k.submit, "open it" },
    { k.refresh, "refetch" },
    { k.discard, "discard" },
    { k.quit, "close" },
  })

  local bindings = {
    {
      k.field,
      function()
        local name = rows[vim.api.nvim_win_get_cursor(M.win)[1]]
        if name and edit[name] then
          edit[name]()
        end
      end,
      "change the field under the cursor",
    },
    { k.submit, submit, "open the merge request" },
    { k.refresh, facts, "ask CI and git again" },
    {
      k.discard,
      function()
        kept[branch] = nil
        state.form = form(branch)
        draw()
        facts()
        branches()
      end,
      "throw away what has been typed",
    },
    -- `q` keeps it. Everything in this window is still here on the next
    -- keypress of `+`, which is the point of it being a window.
    {
      k.quit,
      function()
        M.close()
        back()
      end,
      "close it, keeping what is typed",
    },
    {
      "<Esc>",
      function()
        M.close()
        back()
      end,
      "close it, keeping what is typed",
    },
  }
  for _, b in ipairs(bindings) do
    if b[1] and b[1] ~= "" then
      vim.keymap.set("n", b[1], b[2], { buffer = M.buf, nowait = true, desc = "nemeton: " .. b[3] })
    end
  end

  draw()
  facts()
  branches()
  if not state.labels then
    glab.labels(root, function(data, err)
      local names = {}
      for _, label in ipairs(type(data) == "table" and data or {}) do
        if label.name then
          table.insert(names, label.name)
        end
      end
      state.labels = names
      state.labels_error = not data and tostring(err or "no answer") or nil
    end)
  end
  return M.win
end

return M
