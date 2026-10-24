-- Your to-do list on the forge, in a float.
--
-- The forge keeps one list of everything that is waiting on you --
-- reviews asked of you, comments that name you, pipelines of yours
-- that broke -- across every project you are in, and its own page for
-- it is a tab you have to remember to look at. So it is here, with the
-- review queue: needs no review open and no particular repository,
-- and is narrowed a kind at a time, because "what am I asked to
-- review" and "who has said my name" are two different sittings.
--
-- A merge request or an issue of the repository you are in opens here,
-- the way the queue and the issue list open one; anything of another
-- project opens on the forge, until this editor can go to that project
-- too. Outside a GitLab repository it is the list on `glab.backup_host`,
-- and with none set it is not opened at all: which forge would be glab's
-- guess, and a list off the wrong one looks like an empty one.

local config = require("nemeton.config")
local detail = require("nemeton.detail")
local follow = require("nemeton.follow")
local glab = require("nemeton.glab")
local marks = require("nemeton.marks")
local session = require("nemeton.session")
local threads = require("nemeton.threads")
local win = require("nemeton.win")

local M = {}

M.win = nil
M.buf = nil
-- Every pending to-do, as the forge last listed them; the rows are
-- whichever of them the filter lets through.
local todos = {}
-- Row number (1-based) -> the to-do on it.
local rows = {}
-- Which kind is shown, by name in `M.FILTERS`; nil is all of them.
local filter = nil
-- Which forge the list is asked of, as `glab.todos` takes it, and the
-- project of the repository it was opened in as the forge spells it --
-- what decides whether a to-do opens here. Nil outside one.
local where = nil
local here = nil
-- Where the cursor goes back to on `q`.
local back = nil

-- What GitLab's `action_name` is, said in a word, and the colour it is
-- said in. A kind not here is said in GitLab's own words.
local ACTIONS = {
  review_requested = { "review", "NemetonKey" },
  approval_required = { "approve", "NemetonKey" },
  added_approver = { "approve", "NemetonKey" },
  mentioned = { "mention", "NemetonMention" },
  directly_addressed = { "@you", "NemetonMention" },
  assigned = { "assigned", "NemetonAuthor" },
  build_failed = { "CI failed", "NemetonBad" },
  unmergeable = { "conflict", "NemetonBad" },
  merge_train_removed = { "off train", "NemetonBad" },
  review_submitted = { "reviewed", "NemetonOk" },
  marked = { "to-do", "NemetonMeta" },
}

-- The kinds `f` walks, in that order: what is asked of you as a
-- reviewer first, because that is somebody else waiting, then what was
-- said to you, then what is yours. Anything the forge adds later is
-- `other` rather than missing.
M.FILTERS = {
  { name = "review", actions = { "review_requested", "approval_required", "added_approver" } },
  { name = "mentions", actions = { "mentioned", "directly_addressed" } },
  { name = "assigned", actions = { "assigned" } },
  { name = "build", actions = { "build_failed", "unmergeable", "merge_train_removed" } },
}

--- Which filter a to-do falls under, by name: one of `M.FILTERS`, or
--- "other".
function M.kind(todo)
  for _, f in ipairs(M.FILTERS) do
    if vim.tbl_contains(f.actions, todo.action_name) then
      return f.name
    end
  end
  return "other"
end

--- The to-dos `name` lets through, in the order they came in; nil lets
--- every one through.
function M.only(list, name)
  if not name then
    return list
  end
  return vim.tbl_filter(function(t)
    return M.kind(t) == name
  end, list)
end

--- The filters worth walking to: every one with something under it,
--- `other` last when it has, and nil -- all of them -- first. A kind
--- with nothing in it is a keypress that shows an empty window.
function M.filters(list)
  local out = { false }
  for _, name in
    ipairs(vim.list_extend(
      vim.tbl_map(function(f)
        return f.name
      end, M.FILTERS),
      { "other" }
    ))
  do
    if #M.only(list, name) > 0 then
      table.insert(out, name)
    end
  end
  return out
end

--- `group/proj!12`, `group/proj#4`: what a to-do is about, as the forge
--- writes a reference to it. A commit or anything without a number is
--- its project's path.
function M.reference(todo)
  local target = todo.target or {}
  if type(target.references) == "table" and target.references.full then
    return target.references.full
  end
  local path = todo.project and todo.project.path_with_namespace or ""
  local sigil = ({ MergeRequest = "!", Issue = "#" })[todo.target_type]
  if sigil and target.iid then
    return path .. sigil .. target.iid
  end
  return path
end

--- One row, as coloured chunks. The reference column is `width` wide,
--- which is the widest of the rows shown: these come from every
--- project you are in, and a path is as long as somebody made it.
function M.row(todo, width)
  local action = ACTIONS[todo.action_name]
    or { (todo.action_name or "?"):gsub("_", " "), "NemetonMeta" }
  local ref = M.reference(todo)
  local title = todo.target and todo.target.title or todo.body or ""
  title = vim.fn.strcharpart(title, 0, 56)
  local author = (todo.author and todo.author.username or "?"):sub(1, 14)
  return {
    { (" %-10s"):format(action[1]), action[2] },
    { ref .. (" "):rep(math.max(width - vim.fn.strdisplaywidth(ref), 0) + 2), "NemetonPath" },
    { title, "NemetonThread" },
    { (" "):rep(math.max(57 - vim.fn.strdisplaywidth(title), 1)) },
    { author, "NemetonAuthor" },
    { (" "):rep(math.max(15 - vim.fn.strdisplaywidth(author), 1)) },
    { detail.ago(todo.created_at), "NemetonMeta" },
  }
end

local function valid()
  return M.win ~= nil and vim.api.nvim_win_is_valid(M.win)
end

function M.close()
  if valid() then
    vim.api.nvim_win_close(M.win, true)
  end
  M.win, M.buf, todos, rows, filter = nil, nil, {}, {}, nil
end

local function current()
  if not valid() then
    return nil
  end
  return rows[vim.api.nvim_win_get_cursor(M.win)[1]]
end

local function set_title()
  if not valid() then
    return
  end
  -- "100+" where the page came back full: there is more on the forge
  -- than this asked for, and a count that stops at a hundred without
  -- saying so is a count that lies.
  local all = #todos >= 100 and "100+" or tostring(#todos)
  local title = filter and (" to-do · %s %d/%s "):format(filter, #rows, all)
    or (" to-do · %s "):format(all)
  vim.api.nvim_win_set_config(M.win, { title = title, title_pos = "center" })
end

--- The rows, or a line saying why there are none.
local function draw(said)
  if not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) then
    return
  end
  rows = M.only(todos, filter)
  local lines, hls
  if said then
    lines, hls, rows = { "  " .. said }, {}, {}
  elseif #rows == 0 then
    lines, hls = { "  nothing to do" }, {}
  else
    local width = 0
    for _, t in ipairs(rows) do
      width = math.max(width, vim.fn.strdisplaywidth(M.reference(t)))
    end
    local chunks = vim.tbl_map(function(t)
      return M.row(t, math.min(width, 32))
    end, rows)
    lines, hls = threads.flatten(chunks, 0)
  end
  vim.bo[M.buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.bo[M.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(M.buf, marks.ui_ns, 0, -1)
  marks.paint(M.buf, hls)
  set_title()
end

local function load()
  local mine = M.buf
  draw("…")
  glab.todos(where, function(data, err)
    if M.buf ~= mine or not valid() then
      return
    end
    if not data then
      draw("could not read the to-do list: " .. tostring(err))
      return
    end
    todos = data
    -- A filter whose last to-do went since it was picked is an empty
    -- window that looks like an empty list.
    if filter and #M.only(todos, filter) == 0 then
      filter = nil
    end
    draw()
  end)
end

--- Opens what the to-do is about: here when it is a merge request or
--- an issue of the repository the editor is in, on the forge otherwise.
local function open(todo)
  local iid = todo.target and todo.target.iid
  local ours = here and todo.project and todo.project.path_with_namespace == here
  if ours and iid and todo.target_type == "MergeRequest" then
    M.close()
    require("nemeton").open(iid)
  elseif ours and iid and todo.target_type == "Issue" then
    M.close()
    require("nemeton").issue(iid)
  elseif todo.target_url then
    follow.browse(todo.target_url)
  end
end

--- Which forge to ask: the repository's, when the editor is in one the
--- forge knows as a project, and `glab.backup_host` otherwise.
--- `cb(where, project)`, or `cb(nil)` with neither.
local function locate(cb)
  local function backup()
    local host = glab.backup_host()
    cb(host and { host = host } or nil)
  end
  local root = session.root()
  if not root then
    backup()
    return
  end
  -- Asked once a repository and kept, so this is a round trip on the
  -- first keypress only.
  glab.project_path(root, function(path)
    if path then
      cb({ root = root }, path)
    else
      backup()
    end
  end)
end

local function show()
  back = win.came_from()
  filter = nil

  local width = math.min(vim.o.columns - 4, 130)
  local height = math.max(4, math.floor(vim.o.lines * 0.6))
  M.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[M.buf].bufhidden = "wipe"
  M.win = vim.api.nvim_open_win(M.buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " to-do ",
    title_pos = "center",
  })
  vim.wo[M.win].cursorline = true
  vim.wo[M.win].wrap = false

  local k = config.keys.todos
  vim.wo[M.win].winbar = detail.hint({
    { k.open, "open" },
    { k.done, "done" },
    { k.filter, "filter" },
  }, k.help)

  local bindings = {
    {
      k.open,
      function()
        local todo = current()
        if todo then
          open(todo)
        end
      end,
      "open it: here if it is of this repository, on GitLab if not",
    },
    {
      k.body,
      function()
        local todo = current()
        if todo and todo.body and todo.body ~= "" then
          detail.float(vim.split(todo.body, "\n"), (" %s "):format(M.reference(todo)))
        end
      end,
      "what it says: the comment that named you, the title asked about",
    },
    -- Taken off the list at once rather than on a refetch: the forge
    -- has said it is done, and a row that stays until the next round
    -- trip is a row you press the key on twice.
    {
      k.done,
      function()
        local todo = current()
        if not todo then
          return
        end
        glab.todo_done(where, todo.id, function(_, err)
          if err then
            session.notify("could not mark it done: " .. tostring(err), vim.log.levels.ERROR)
            return
          end
          todos = vim.tbl_filter(function(t)
            return t.id ~= todo.id
          end, todos)
          if not valid() then
            return
          end
          local at = vim.api.nvim_win_get_cursor(M.win)[1]
          draw()
          vim.api.nvim_win_set_cursor(M.win, { math.max(math.min(at, #rows), 1), 0 })
        end)
      end,
      "mark the one under the cursor done",
    },
    {
      k.filter,
      function()
        local walk = M.filters(todos)
        local i = 1
        for n, f in ipairs(walk) do
          if f == (filter or false) then
            i = n
          end
        end
        filter = walk[i % #walk + 1] or nil
        draw()
        vim.api.nvim_win_set_cursor(M.win, { 1, 0 })
      end,
      "show one kind: review, mentions, assigned, build, other, all",
    },
    {
      k.browser,
      function()
        local todo = current()
        if todo and todo.target_url then
          follow.browse(todo.target_url)
        end
      end,
      "open it on GitLab",
    },
    { k.refresh, load, "refetch" },
    {
      k.quit,
      function()
        M.close()
        back()
      end,
      "close",
    },
  }
  detail.bind(M.buf, bindings, k.help, " to-do ")
  load()
  return M.win
end

--- The to-do list, in a float.
function M.open()
  if not glab.available() then
    session.notify("glab is not on your PATH", vim.log.levels.ERROR)
    return
  end
  if valid() then
    vim.api.nvim_set_current_win(M.win)
    return
  end
  locate(function(found, project)
    if not found then
      session.notify(
        "not in a GitLab project, and no glab.backup_host to ask instead — "
          .. "set it to the host whose to-do list to open outside one",
        vim.log.levels.ERROR
      )
      return
    end
    -- The key pressed twice while the forge was being asked.
    if valid() then
      return
    end
    where, here = found, project
    show()
  end)
end

return M
