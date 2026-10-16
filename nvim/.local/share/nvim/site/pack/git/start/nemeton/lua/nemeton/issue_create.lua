-- The issue you are about to file.
--
-- The merge request's create window (`nemeton.create`) in its shape and
-- its keys -- a field a line, `<CR>` changes the one under the cursor,
-- `<C-s>` sends it, `X` throws it away, `q` keeps it -- with an issue's
-- fields: what it is called, what it says, how it is labelled, and who
-- has it.
--
-- Kept, like that one, for this editor session and nowhere else: what
-- has been typed is in the window again on the next `+`, and a plugin
-- that wrote half-filed issues into somebody's state directory would
-- have to decide when to delete them. One per project, since an issue
-- is of a project and not of a branch.
--
-- Filed from a selection (`:'<,'>Nemeton new-issue`), the description
-- starts with a link to those lines and the lines themselves: "this is
-- wrong, here" is how most issues filed from an editor begin, and the
-- two things it needs are the two this plugin can write without asking.

local config = require("nemeton.config")
local detail = require("nemeton.detail")
local glab = require("nemeton.glab")
local marks = require("nemeton.marks")
local session = require("nemeton.session")
local win = require("nemeton.win")

local M = {}

M.win = nil
M.buf = nil

-- root -> the form typed into for that project.
local kept = {}
-- The window's own: the project, its form, and what the pickers choose
-- from once the forge has said.
local state = nil
-- Line (1-based) -> the field on it.
local rows = {}

local function form(root)
  kept[root] = kept[root] or { title = "", description = "", labels = {}, assignees = {} }
  return kept[root]
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

local GUTTER = "  "
local COLUMN = 15

--- One field, its name dim and its value after it -- the create
--- window's column, so the two forms read alike.
local function field(out, hls, name, value, hl)
  local label = GUTTER .. name
  local pad = math.max(1, COLUMN - #label)
  table.insert(hls, { row = #out, col = 0, end_col = #label, hl = "NemetonMeta" })
  local text = value
  if not text or text == "" then
    text, hl = "—", "NemetonMeta"
  end
  local lines = vim.split(text, "\n", { plain = true })
  for i, l in ipairs(lines) do
    local lead = i == 1 and (label .. (" "):rep(pad)) or (" "):rep(COLUMN)
    table.insert(hls, { row = #out, col = #lead, end_col = #lead + #l, hl = hl or "NemetonThread" })
    table.insert(out, lead .. l)
  end
end

--- The window's lines, highlights, and which field each line is.
function M.lines(f)
  local out, hls, map = { "" }, {}, {}
  local function at(name, fn)
    local before = #out + 1
    fn()
    for i = before, #out do
      map[i] = name
    end
  end
  at("title", function()
    field(out, hls, "title", f.title, "NemetonAuthor")
  end)
  at("labels", function()
    field(out, hls, "labels", #f.labels > 0 and table.concat(f.labels, ", ") or nil)
  end)
  at("assignees", function()
    field(
      out,
      hls,
      "assignees",
      #f.assignees > 0 and table.concat(f.assignees, ", ") or nil,
      "NemetonAuthor"
    )
  end)
  table.insert(out, "")
  at("description", function()
    field(out, hls, "description", f.description)
  end)
  return out, hls, map
end

local function draw()
  if not (up() and state) then
    return
  end
  local was = rows[vim.api.nvim_win_get_cursor(M.win)[1]]
  local lines, hls, map = M.lines(state.form)
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

local edit = {}

function edit.title()
  vim.ui.input({ prompt = "title: ", default = state.form.title }, function(text)
    if text ~= nil then
      state.form.title = vim.trim(text)
      draw()
    end
  end)
end

function edit.description()
  require("nemeton.compose").open({
    title = ("description  ·  %s"):format(
      state.form.title ~= "" and state.form.title or "new issue"
    ),
    body = state.form.description,
    -- Kept into the form, not sent: the whole window is kept until it is
    -- filed.
    default = "keep",
    empty = true,
    on_draft = function(text)
      state.form.description = text
      draw()
    end,
  })
end

function edit.labels()
  if not state.labels then
    session.notify("still asking the forge which labels this project has")
    return
  end
  require("nemeton.issue").pick_set("labels", state.labels, state.form.labels, nil, function(set)
    state.form.labels = set
    draw()
  end)
end

function edit.assignees()
  if not state.users then
    session.notify("still asking the forge who is on this project")
    return
  end
  local names, full = {}, {}
  for _, u in ipairs(state.users) do
    table.insert(names, u.username)
    full[u.username] = u.name
  end
  require("nemeton.issue").pick_set("assignees", names, state.form.assignees, function(n)
    return full[n] and full[n] ~= n and ("%s  %s"):format(n, full[n]) or n
  end, function(set)
    state.form.assignees = set
    draw()
  end)
end

--- Files it, and opens what was filed.
local function submit()
  local f, root = state.form, state.root
  if f.title == "" then
    session.notify("an issue needs a title", vim.log.levels.WARN)
    return
  end
  local ids = {}
  for _, u in ipairs(state.users or {}) do
    if vim.tbl_contains(f.assignees, u.username) then
      table.insert(ids, u.id)
    end
  end
  local back = win.came_from()
  M.close()
  back()
  session.notify("filing it…")
  glab.issue_create(root, {
    title = f.title,
    description = f.description,
    labels = f.labels,
    assignee_ids = #ids > 0 and ids or nil,
  }, function(made, err)
    if not made then
      -- The window is gone and what was typed is not: `+` brings it
      -- back to try again.
      session.notify("could not file it: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    kept[root] = nil
    session.notify(("filed #%d"):format(made.iid))
    -- The list was a list of what there is, and what was just filed is
    -- what is being looked at now.
    require("nemeton.issue_list").close()
    require("nemeton.issue_cache").refresh_one(root, made.iid)
    require("nemeton.issue").open(made.iid)
  end)
end

--- The window. Everything typed into it before is still in it.
---
--- `opts.description` is what a description that is still empty starts
--- as: the link and the lines of a selection it was filed from.
function M.open(opts)
  opts = opts or {}
  local root = session.root()
  if not root then
    session.notify("not inside a git repository", vim.log.levels.ERROR)
    return
  end
  M.close()
  local f = form(root)
  if opts.description and vim.trim(f.description) == "" then
    f.description = opts.description
  end
  state = {
    root = root,
    form = f,
    labels = state and state.root == root and state.labels or nil,
    users = state and state.root == root and state.users or nil,
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
    title = " new issue ",
    title_pos = "center",
  })
  vim.wo[M.win].cursorline = true
  vim.wo[M.win].wrap = false

  local k = config.keys.issue_create
  vim.wo[M.win].winbar = detail.hint({
    { k.field, "change" },
    { k.submit, "file it" },
  }, k.help)
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
    { k.submit, submit, "file the issue" },
    {
      k.discard,
      function()
        kept[root] = nil
        state.form = form(root)
        draw()
      end,
      "throw away what has been typed",
    },
    {
      k.quit,
      function()
        M.close()
        back()
      end,
      "close it, keeping what is typed",
    },
  }
  detail.bind(M.buf, bindings, k.help, " new issue ")
  draw()

  if not state.labels then
    glab.labels(root, function(data)
      local names = {}
      for _, l in ipairs(type(data) == "table" and data or {}) do
        if l.name then
          table.insert(names, l.name)
        end
      end
      state.labels = names
    end)
  end
  if not state.users then
    glab.project_users(root, function(data)
      state.users = vim.tbl_filter(function(u)
        return u.username ~= nil
      end, type(data) == "table" and data or {})
    end)
  end
  return M.win
end

--- What the pickers have to choose from, for the suite.
function M.choices()
  return { labels = state and state.labels, users = state and state.users }
end

return M
