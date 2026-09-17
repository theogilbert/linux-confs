-- Every commit that has touched a file, and what each of them did to
-- it.
--
-- "Why is it like this" is the question a reviewer asks about the line
-- the merge request did not change, and `git blame` answers it for one
-- line and one commit deep. The whole answer is the file's history,
-- read one commit at a time -- which is `git log --follow -p`, in two
-- windows: the commits as a list, and the patch each of them made, in
-- a tab that steps from one to the next without going back to the
-- list.
--
-- Out of git rather than off the forge, and with or without a review
-- open: the checkout has every commit the file has ever been in, and
-- the forge's copy of the history would be a round trip to read what
-- is already on the disk. `--follow`, because a file that was renamed
-- is the same file, and the history that stops at the rename is the
-- history of the name.
--
-- Over a selection it is the history of those lines (`git log -L`):
-- the commits that touched them, and of each only the hunk that did.
-- Which is the question more often than the file's -- the file is a
-- thousand lines and the puzzling ones are six -- and `-L` follows
-- the six back through every edit around them and every rename of the
-- file, the way the eye cannot.

local config = require("nemeton.config")
local detail = require("nemeton.detail")
local log = require("nemeton.log")
local marks = require("nemeton.marks")
local session = require("nemeton.session")
local threads = require("nemeton.threads")
local win = require("nemeton.win")

local M = {}

-- The list.
M.win = nil
M.buf = nil
-- The tab a patch is read in.
M.patch = nil

-- What the list holds: the file it is about, as the title says it --
-- `src/app.lua`, or `src/app.lua:12-15` for a selection -- the commits
-- on it newest first, and which of them the patch tab is showing.
local path = nil
local root = nil
local commits = {}
local at = nil

-- One byte in front of each commit and one between its fields, both
-- outside what a patch can contain: a line of a diff starts with a
-- space, a sign or a letter, and a subject line has no control
-- characters in it.
local HEAD = "\1"
local FIELD = "\31"
local FORMAT = "--format=" .. HEAD .. "%H" .. FIELD .. "%an" .. FIELD .. "%ad" .. FIELD .. "%s"

--- `git log`'s output as commits: `{ sha, author, date, subject, from,
--- patch }` each, newest first, where `patch` is the lines of the diff
--- the commit made to the file and `from` is the name the file had
--- before, on the commit that renamed it. Read off the `---`/`+++`
--- pair rather than off `rename from`, which `-L` does not print.
---
--- Pure, and public, because it is the half of this module that can be
--- tested without a repository or a window.
function M.parse(text)
  local out = {}
  local one = nil
  for _, line in ipairs(vim.split(text or "", "\n", { plain = true })) do
    if line:sub(1, 1) == HEAD then
      local f = vim.split(line:sub(2), FIELD, { plain = true })
      one = { sha = f[1] or "", author = f[2] or "", date = f[3] or "", subject = f[4] or "" }
      one.patch = {}
      table.insert(out, one)
    elseif one then
      -- The blank line git puts between the heading and the diff is
      -- not part of either.
      if not (#one.patch == 0 and line == "") then
        table.insert(one.patch, line)
      end
      one.before = one.before or line:match("^%-%-%- a/(.+)$")
      one.after = one.after or line:match("^%+%+%+ b/(.+)$")
    end
  end
  for _, c in ipairs(out) do
    if c.before and c.after and c.before ~= c.after then
      c.from = c.before
    end
    c.before, c.after = nil, nil
    while #c.patch > 0 and c.patch[#c.patch] == "" do
      table.remove(c.patch)
    end
  end
  return out
end

--- The commits that have touched `file`, with the patch each made to
--- it -- or, with `first` and `last`, the ones that touched those
--- lines of it, with the hunk each made to them. `rev` is the
--- revision the lines are numbered at, HEAD when nil. `cb(commits)`
--- on the main loop, or `cb(nil, err)`.
---
--- One call for both the list and the patches rather than one for the
--- list and one per commit as it is read: a file's history is read by
--- stepping through it, and a step that waits on a subprocess is a
--- step you feel.
function M.commits(where, file, cb, first, last, rev)
  local cmd = { "git", "log", "--date=short", FORMAT }
  if first then
    -- No `--follow`: `-L` will not take it, and follows the lines
    -- through a rename on its own.
    vim.list_extend(cmd, { ("-L%d,%d:%s"):format(first, last or first, file), rev })
  else
    vim.list_extend(cmd, { "--follow", "-p", rev, "--", file })
  end
  local done = log.exec(cmd, { cwd = where })
  vim.system(cmd, { text = true, cwd = where }, function(res)
    done(res.code, res.stderr)
    vim.schedule(function()
      if res.code ~= 0 then
        cb(nil, vim.trim(res.stderr or "") ~= "" and vim.trim(res.stderr) or "git log failed")
        return
      end
      cb(M.parse(res.stdout))
    end)
  end)
end

--- The commits as lines: sha, subject, author, date -- the columns of
--- the changelog under the queue, in the same order, because it is the
--- same thing read at a different scope. A commit that renamed the
--- file says what from, since that is the one thing about it the
--- subject line may not.
function M.lines(list, file)
  if #list == 0 then
    return { { { ("no commit has touched %s"):format(file or "this file"), "NemetonMeta" } } }
  end
  local out = {}
  for _, c in ipairs(list) do
    local title = c.subject:sub(1, 58)
    local author = c.author:sub(1, 14)
    local line = {
      { ("%-8s  "):format(c.sha:sub(1, 8)), "NemetonMeta" },
      { title, "NemetonThread" },
      { (" "):rep(math.max(60 - vim.fn.strdisplaywidth(title), 2)) },
      { author, "NemetonAuthor" },
      { (" "):rep(math.max(15 - vim.fn.strdisplaywidth(author), 1)) },
      { c.date, "NemetonMeta" },
    }
    if c.from then
      table.insert(line, { "  was " .. c.from, "NemetonMeta" })
    end
    table.insert(out, line)
  end
  return out
end

--- The window the patch is in, in whichever tab that is.
local function patch_win()
  return M.patch and vim.api.nvim_buf_is_valid(M.patch) and vim.fn.win_findbuf(M.patch)[1] or nil
end

--- The tab the patch is read in, closed. Only the tab: the buffer goes
--- with it, and the list it was opened from is in another one.
local function close_patch()
  local w = patch_win()
  if w and #vim.api.nvim_list_tabpages() > 1 then
    vim.api.nvim_set_current_tabpage(vim.api.nvim_win_get_tabpage(w))
    vim.cmd("tabclose")
  elseif M.patch and vim.api.nvim_buf_is_valid(M.patch) then
    -- The one tab there is cannot be closed. Wiping the buffer is the
    -- same gesture in a window that has nowhere to go.
    vim.api.nvim_buf_delete(M.patch, { force = true })
  end
  M.patch = nil
end

function M.close()
  close_patch()
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    vim.api.nvim_win_close(M.win, true)
  end
  M.win, M.buf, commits, at = nil, nil, {}, nil
end

local function draw()
  local lines, hls = threads.flatten(M.lines(commits, path), 0)
  vim.bo[M.buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.bo[M.buf].modifiable = false
  marks.paint(M.buf, hls)
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    vim.api.nvim_win_set_config(M.win, {
      title = (" %s · %d commit%s "):format(path, #commits, #commits == 1 and "" or "s"),
      title_pos = "center",
    })
  end
end

--- The commit under the cursor in the list, by its row.
local function under_cursor()
  if not (M.win and vim.api.nvim_win_is_valid(M.win)) then
    return nil
  end
  return commits[vim.api.nvim_win_get_cursor(M.win)[1]]
end

--- The commit's page on the forge, in a browser. The project is asked
--- of the forge once, the way a link to a line is: a file's history
--- needs no review open, so there is no merge request to take the
--- project from.
local function browse(c)
  if not c then
    return
  end
  require("nemeton.glab").project_url(root, function(project, err)
    if not project then
      session.notify(
        "no page to open — " .. (err or "the forge did not say which project this is"),
        vim.log.levels.WARN
      )
      return
    end
    vim.ui.open(project .. "/-/commit/" .. c.sha)
  end)
end

--- Puts commit `i`'s patch in the tab, opening the tab if there is
--- none. The list's cursor follows, so that closing the tab lands on
--- the commit that was being read.
local function show(i)
  local c = commits[i]
  if not c then
    return
  end
  at = i
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    vim.api.nvim_win_set_cursor(M.win, { i, 0 })
  end

  local k = config.keys.history
  if not (M.patch and vim.api.nvim_buf_is_valid(M.patch)) then
    -- A tab rather than a float, like a job's log: a patch is read by
    -- searching it and scrolling it, and read against the code it is
    -- a patch to, which is in the tab it was opened from.
    vim.cmd("tabnew")
    M.patch = vim.api.nvim_get_current_buf()
    vim.bo[M.patch].buftype = "nofile"
    vim.bo[M.patch].bufhidden = "wipe"
    vim.bo[M.patch].swapfile = false
    vim.bo[M.patch].filetype = "diff"
    local w = vim.api.nvim_get_current_win()
    vim.wo[w].wrap = false
    vim.wo[w].number = false
    vim.wo[w].relativenumber = false
    vim.wo[w].signcolumn = "no"
    vim.wo[w].spell = false

    local bindings = {
      -- Down the list is back in time, and so is `J`: the list is
      -- newest first, and the two keys step the way the eye would
      -- move on it. Neither means anything in a buffer that cannot
      -- be edited.
      {
        k.older,
        function()
          show(at + 1)
        end,
        "the commit before this one",
      },
      {
        k.newer,
        function()
          show(at - 1)
        end,
        "the commit after this one",
      },
      {
        k.browser,
        function()
          browse(commits[at])
        end,
        "open this commit on GitLab",
      },
      { k.quit, close_patch, "close this patch" },
    }
    for _, b in ipairs(bindings) do
      if b[1] and b[1] ~= "" then
        vim.keymap.set(
          "n",
          b[1],
          b[2],
          { buffer = M.patch, nowait = true, desc = "nemeton: " .. b[3] }
        )
      end
    end
  else
    vim.api.nvim_set_current_win(patch_win())
  end

  -- Named after the commit, which is what the tabline has room for.
  vim.api.nvim_buf_set_name(M.patch, ("nemeton://history/%s/%s"):format(c.sha:sub(1, 8), path))
  vim.bo[M.patch].modifiable = true
  vim.api.nvim_buf_set_lines(M.patch, 0, -1, false, c.patch)
  vim.bo[M.patch].modifiable = false
  local w = patch_win()
  vim.api.nvim_win_set_cursor(w, { 1, 0 })
  -- Which commit this is and where in the history it stands, since
  -- the list is in another tab: a patch read on its own is a diff of
  -- something to something, and the heading is what says of what.
  vim.wo[w].winbar = ("%%#NemetonAuthor#%s%%*  %s  %%#NemetonAuthor#%s%%*  %%#NemetonMeta#%s · %d/%d%%*  %s"):format(
    c.sha:sub(1, 8),
    c.subject:gsub("%%", "%%%%"),
    c.author:gsub("%%", "%%%%"),
    c.date,
    i,
    #commits,
    detail.hint({
      { k.older, "older" },
      { k.newer, "newer" },
      { k.browser, "browser" },
      { k.quit, "quit" },
    })
  )
end

--- The commits that have touched the file in `bufnr`, in a float --
--- or, with `first` and `last`, the ones that touched those lines of
--- it.
---
--- The file is the buffer's, whichever side of a diff it is showing: a
--- buffer of the file at some revision is still a buffer of the file,
--- and its history is the same history. The lines are numbered as
--- that buffer numbers them -- at the revision an old side is showing,
--- and at HEAD otherwise, which is what git can count from: a line
--- added in the buffer and not yet committed is on no commit's side.
function M.open(bufnr, first, last)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local old = session.old_side(bufnr)
  local file = old and old.path or session.relpath(bufnr)
  if not file then
    session.notify("this buffer is not a file in the repository", vim.log.levels.WARN)
    return
  end
  local where = (session.current and session.current.root) or session.root()
  if not where then
    return
  end
  local about = file
  if first then
    last = math.max(last or first, first)
    about = last > first and ("%s:%d-%d"):format(file, first, last) or ("%s:%d"):format(file, first)
  end

  M.close()
  path, root, commits, at = about, where, {}, nil
  local width = math.min(math.floor(vim.o.columns * 0.8), 110)
  local height = math.max(4, math.floor(vim.o.lines * 0.5))
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
    title = (" %s "):format(about),
    title_pos = "center",
  })
  vim.wo[M.win].cursorline = true

  local k = config.keys.history
  vim.wo[M.win].winbar = detail.hint({
    { k.show, "patch" },
    { k.browser, "browser" },
    { k.quit, "quit" },
  })

  local bindings = {
    {
      k.quit,
      function()
        M.close()
        back()
      end,
      "close",
    },
    {
      k.show,
      function()
        show(vim.api.nvim_win_get_cursor(M.win)[1])
      end,
      "what this commit did to the file",
    },
    {
      k.browser,
      function()
        browse(under_cursor())
      end,
      "open the commit under the cursor on GitLab",
    },
  }
  for _, b in ipairs(bindings) do
    if b[1] and b[1] ~= "" then
      vim.keymap.set("n", b[1], b[2], { buffer = M.buf, nowait = true, desc = "nemeton: " .. b[3] })
    end
  end

  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, { "…" })
  vim.bo[M.buf].modifiable = false
  M.commits(where, file, function(list, err)
    if not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) then
      return
    end
    if not list then
      session.notify("could not read the history: " .. tostring(err), vim.log.levels.ERROR)
      commits = {}
    else
      commits = list
    end
    draw()
  end, first, last, old and old.sha or nil)
  return M.win
end

return M
