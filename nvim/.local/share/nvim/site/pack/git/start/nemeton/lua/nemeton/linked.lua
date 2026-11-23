-- A comment linked to from somewhere else, read where the link is.
--
-- An issue is where the argument that started on a merge request
-- carries on -- "see the discussion on !12" -- and the link it carries
-- is a hundred characters of URL with `#note_` on the end. `<C-]>` on
-- one used to put it on the clipboard and say which merge request it
-- was on, which is the half of the answer that sends the reader to a
-- browser for the other half.
--
-- So the thread is asked for and shown, in a float over the link:
-- every note of it, and the code it was written about as it was when it
-- was written -- out of the commit, since the branch in front of you is
-- usually another one. Nothing is checked out and no review opened to
-- read it, because reading what was said is the whole of what most
-- presses are for; `<CR>` is the press that is not, and opens that
-- review on the thread.
--
-- Only a comment of this project: one on another project's merge
-- request has no checkout here to read the code out of or to open a
-- review in, and is the page it always was.

local config = require("nemeton.config")
local glab = require("nemeton.glab")
local marks = require("nemeton.marks")
local session = require("nemeton.session")
local threads = require("nemeton.threads")
local win = require("nemeton.win")

local M = {}

M.win = nil
M.buf = nil

function M.close()
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    vim.api.nvim_win_close(M.win, true)
  end
  M.win, M.buf = nil, nil
end

--- The thread of `discussions` holding note `id`, or nil.
local function find(discussions, id)
  local parsed = threads.parse(discussions or {})
  for _, list in ipairs({ parsed.inline, parsed.overview }) do
    for _, t in ipairs(list) do
      for _, note in ipairs(t.notes or {}) do
        if tostring(note.id) == tostring(id) then
          return t
        end
      end
    end
  end
  return nil
end

--- The revision, the path and the lines of it a thread is about, as
--- `session.quoted` reads them: the branch's side, or the base for a
--- line the change took away.
local function about(t)
  if t.side == "old" and t.old_line then
    return t.base_sha or t.head_sha, t.old_path or t.path, t.old_first or t.old_line, t.old_line
  end
  return t.head_sha, t.path, t.first_line or t.line, t.line
end

--- `path` at `sha`, as lines, to `cb` -- or nil. Out of the checkout,
--- and where it has not got the commit, fetched first: a thread on
--- somebody else's branch is about a push this clone has never seen.
local function blob(root, sha, path, mr, cb)
  local function show(again)
    vim.system({ "git", "show", sha .. ":" .. path }, { text = true, cwd = root }, function(res)
      vim.schedule(function()
        if res.code == 0 then
          local lines = vim.split(res.stdout or "", "\n", { plain = true })
          if lines[#lines] == "" then
            table.remove(lines)
          end
          cb(lines)
        elseif again then
          session.fetch_commit(root, sha, function(got)
            if got then
              show(false)
            else
              cb(nil)
            end
          end, mr)
        else
          cb(nil)
        end
      end)
    end)
  end
  show(true)
end

--- Opens the review the thread is on, and goes to the thread once it
--- is open: the float's `<CR>`.
---
--- From a window with code in it. The press is usually made in an
--- issue, which is a tab of its own, and the file a thread is about
--- opened there is a file in the issue's window.
local function open_review(iid, note)
  local function code_window()
    local here = vim.api.nvim_get_current_tabpage()
    local tabs = vim.api.nvim_list_tabpages()
    table.sort(tabs, function(a, b)
      return (a == here and 0 or 1) < (b == here and 0 or 1)
    end)
    for _, tab in ipairs(tabs) do
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
        local b = vim.api.nvim_win_get_buf(w)
        if vim.bo[b].buftype == "" and vim.api.nvim_win_get_config(w).relative == "" then
          return w
        end
      end
    end
    return nil
  end
  local function land()
    local t = session.thread_of(note)
    if not t then
      session.notify(("comment %s is not drawn in !%d"):format(note, iid), vim.log.levels.WARN)
      return
    end
    local w = code_window()
    if w then
      vim.api.nvim_set_current_win(w)
    else
      vim.cmd("tabnew")
    end
    if t.path and t.line then
      session.goto_thread(t)
    else
      require("nemeton.notes").open(t)
    end
  end
  if session.current and session.current.iid == iid then
    land()
    return
  end
  require("nemeton").open(iid, { on_open = land })
end

--- Draws the float, focused: it was asked for with a key, and the
--- reason to look at a thread is to read it to the end.
local function draw(t, mr, code, iid, href)
  local most = math.max(math.min(vim.o.columns - 10, 110), 30)
  local was, paint_was = nil, nil
  if code then
    local _, path, first, last = about(t)
    local context = config.comments.context or 0
    was = {}
    for n = math.max(first - context, 1), math.min(last, #code) do
      table.insert(was, { text = code[n], line = n })
    end
    local syntax = require("nemeton.syntax")
    paint_was = syntax.painter_of(code, syntax.of_path(path))
  end
  local drawn = threads.render(t, {
    width = most,
    was = was and #was > 0 and was or nil,
    paint_was = paint_was,
  })
  local head = { { ("!%d"):format(iid), "NemetonMeta" } }
  if mr and mr.title then
    table.insert(head, { " " .. mr.title, "NemetonThread" })
  end
  if mr and mr.state and mr.state ~= "opened" then
    table.insert(head, { " · " .. mr.state, "NemetonMeta" })
  end
  if t.path then
    table.insert(head, { (" · %s:%d"):format(t.path, t.line or 0), "NemetonPath" })
  end
  local chunks = { head, {} }
  vim.list_extend(chunks, drawn)
  local ground = {}
  for i = 3, #chunks do
    ground[i] = t.resolved and "settled" or "open"
  end
  local lines, hls, refs = marks.shade_lines(chunks, 0, ground)
  local width = 30
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l) + 1)
  end

  M.close()
  M.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[M.buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.bo[M.buf].modifiable = false
  marks.paint(M.buf, hls)
  local back = win.came_from()
  local height = math.min(#lines, math.max(math.floor(vim.o.lines * 0.6), 4))
  M.win = vim.api.nvim_open_win(M.buf, true, {
    relative = "editor",
    width = math.min(width, most),
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - math.min(width, most)) / 2),
    style = "minimal",
    border = "rounded",
    title = (" !%d · comment %s "):format(iid, t.notes[1] and t.notes[1].id or "?"),
    title_pos = "center",
  })
  -- The editor's own background, as every window that draws a
  -- conversation has it: see `conversation.lua`.
  vim.wo[M.win].winhighlight = "NormalFloat:Normal"
  require("nemeton.win").wrap(M.buf)
  vim.wo[M.win].linebreak = true

  local function quit()
    M.close()
    back()
  end
  local follow = require("nemeton.follow")
  follow.set(M.buf, refs, quit)
  local k = config.keys.linked
  vim.wo[M.win].winbar = require("nemeton.detail").hint({
    { k.open, "open the review on it" },
    { k.browser, follow.browse_hint() },
  }, k.help)
  local note = t.notes[1] and t.notes[1].id
  require("nemeton.detail").bind(M.buf, {
    {
      k.open,
      function()
        quit()
        open_review(iid, note)
      end,
      "open the review it is in, on it",
    },
    {
      k.browser,
      function()
        follow.browse(href)
      end,
      "open it on GitLab",
    },
    { k.follow, follow.here, "follow what is under the cursor" },
    { k.quit, quit, "close" },
    { "<Esc>", quit, "close" },
  }, k.help, " linked comment ")
end

--- Merge request `iid` of the project in `root`, read in a float: the
--- window it would have as the review -- what it is, the state it is
--- in, what it says it is for -- without checking it out. `!12` in a
--- description is usually a question ("what did that one do?") and not
--- a decision to review it; `<CR>` is that decision.
function M.describe(iid, root)
  root = root or session.root()
  if not root then
    session.notify("not inside a git repository", vim.log.levels.ERROR)
    return
  end
  local said = session.working(("fetching !%d…"):format(iid))
  glab.mr_get(root, iid, function(mr, err)
    said()
    if type(mr) ~= "table" then
      session.notify(("could not read !%d: %s"):format(iid, tostring(err)), vim.log.levels.ERROR)
      return
    end
    local detail = require("nemeton.detail")
    local follow = require("nemeton.follow")
    local lines, hls, refs = threads.flatten(detail.description_chunks(mr), 0)
    local k = config.keys.linked
    M.close()
    local close
    M.win, M.buf = detail.float(lines, (" !%d "):format(iid), {
      hls = hls,
      filetype = false,
      help = k.help,
      quit = k.quit,
      winbar = detail.hint({
        { k.open, "open the review" },
        { k.browser, follow.browse_hint() },
      }, k.help),
      keys = {
        {
          k.open,
          function()
            close()
            require("nemeton").open(iid)
          end,
          "open the review of it",
        },
        {
          k.browser,
          function()
            if mr.web_url then
              follow.browse(mr.web_url)
            end
          end,
          "open it on GitLab",
        },
        { k.follow, follow.here, "follow what is under the cursor" },
      },
    })
    local float = M.win
    close = function()
      if vim.api.nvim_win_is_valid(float) then
        vim.api.nvim_win_close(float, true)
      end
    end
    -- What its links are measured from: this merge request's page and
    -- the branch it goes into, not the review's.
    follow.set(M.buf, refs, close, vim.tbl_extend("force", mr, { root = root }))
  end)
end

--- Shows comment `note` of merge request `iid`: `href` is the link it
--- was found as, `root` the checkout to read the code out of.
function M.show(iid, note, href, root)
  root = root or session.root()
  if not root then
    session.notify("not inside a git repository", vim.log.levels.ERROR)
    return
  end
  local said = session.working(("fetching !%d (comment %s)…"):format(iid, note))
  local mr, discussions, pending, failed = nil, nil, 2, nil
  local function done()
    pending = pending - 1
    if pending > 0 then
      return
    end
    if not discussions then
      said()
      session.notify(("could not read !%d: %s"):format(iid, tostring(failed)), vim.log.levels.ERROR)
      return
    end
    local t = find(discussions, note)
    if not t then
      said()
      session.notify(
        ("comment %s is not on !%d any more — deleted, or a system note"):format(note, iid),
        vim.log.levels.WARN
      )
      return
    end
    local sha, path = about(t)
    if not (sha and path and t.line) then
      said()
      draw(t, mr, nil, iid, href)
      return
    end
    blob(root, sha, path, mr, function(code)
      said()
      draw(t, mr, code, iid, href)
    end)
  end
  glab.mr_get(root, iid, function(data)
    mr = data
    done()
  end)
  glab.discussions(root, iid, function(data, err)
    discussions, failed = data, err
    done()
  end)
end

return M
