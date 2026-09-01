-- Every thread on the merge request, read as conversation.
--
-- The quickfix list answers "where do I have to go" and the comments
-- window answers "what is there" -- an opening note per line, to scan.
-- This is the one that answers "what was actually said": every note of
-- every thread, in order, so a reviewer coming back to a merge request
-- can read the argument without their file windows being taken away
-- and replaced one jump at a time.
--
-- So: one window, every thread in it, threads on lines headed by the
-- line they are on, threads on the merge request headed as such -- and
-- the keys to answer any of them from where you are sitting. <CR> is
-- the way *into* the code, for the one thread that turns out to need
-- it.

local config = require("nemeton.config")
local edit = require("nemeton.edit")
local marks = require("nemeton.marks")
local session = require("nemeton.session")
local threads = require("nemeton.threads")

local M = {}

M.win = nil
M.buf = nil
-- Line number (1-based) -> the thread drawn on it.
local rows = {}

function M.close()
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    vim.api.nvim_win_close(M.win, true)
  end
  M.win, M.buf, rows = nil, nil, {}
end

--- Everything there is to read, in reading order: the threads on the
--- code by file and line, then the ones on the merge request as a
--- whole. Unsent comments of your own sit among them, where they will
--- be once they are sent.
local function everything(mr)
  local inline = vim.list_extend(vim.list_slice(mr.inline or {}), mr.drafts or {})
  table.sort(inline, function(a, b)
    if a.path ~= b.path then
      return (a.path or "") < (b.path or "")
    end
    return (a.line or 0) < (b.line or 0)
  end)
  return inline, vim.list_extend(vim.list_slice(mr.overview or {}), mr.draft_overview or {})
end

local function render()
  if not (M.buf and vim.api.nvim_buf_is_valid(M.buf) and session.current) then
    return
  end
  local inline, overall = everything(session.current)
  local chunks, map = {}, {}

  -- What a suggestion would replace, read out of the file it is about.
  --
  -- Out of the buffer where the file is open -- that is what is on the
  -- screen, and what the same thread expanded under the code shows --
  -- and off the disk otherwise, because this window is read with no
  -- file windows open at all, which is half of why it exists. Without
  -- it a suggestion here is the green half of a diff: what the code
  -- would become, and no sign of what it is now.
  local root = session.current.root
  local on_disk = {}
  local function file_lines(path)
    local full = root .. "/" .. path
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b) == full then
        return vim.api.nvim_buf_get_lines(b, 0, -1, false)
      end
    end
    -- Once per file, however many suggestions are in it, and `false`
    -- for a file that is not there to read -- a thread on something the
    -- branch has since deleted.
    if on_disk[path] == nil then
      local ok, lines = pcall(vim.fn.readfile, full)
      on_disk[path] = (ok and lines) or false
    end
    return on_disk[path] or nil
  end

  local function replaced_in(t)
    if not (t.path and t.line) then
      return nil
    end
    return function(above, below)
      local all = file_lines(t.path)
      if not all then
        return {}
      end
      return vim.list_slice(all, math.max(t.line - above, 1), t.line + below)
    end
  end

  local function heading(text)
    if #chunks > 0 then
      table.insert(chunks, {})
    end
    table.insert(chunks, { { text, "NemetonAuthor" } })
  end

  local function thread(t)
    for _, line in ipairs(threads.render(t, { replaced = replaced_in(t) })) do
      table.insert(chunks, line)
      map[#chunks] = t
    end
  end

  local seen = nil
  for _, t in ipairs(inline) do
    if t.path ~= seen then
      heading(t.path or "?")
      seen = t.path
    end
    table.insert(chunks, { { ("  line %d"):format(t.line or 0), "NemetonMeta" } })
    map[#chunks] = t
    thread(t)
  end
  if #overall > 0 then
    heading("on the merge request")
    for _, t in ipairs(overall) do
      thread(t)
      table.insert(chunks, {})
    end
  end
  if #chunks == 0 then
    chunks = { { { "nothing has been said on this merge request yet.", "NemetonMeta" } } }
  end

  local lines, hls = threads.flatten(chunks, 0)
  rows = map
  vim.bo[M.buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.bo[M.buf].modifiable = false
  marks.paint(M.buf, hls)
end

--- The thread the cursor is in. A conversation is several lines tall
--- and the cursor lands anywhere in it, so the search walks upwards --
--- the thread you are inside is the last one that started above you.
local function thread_at()
  if not (M.win and vim.api.nvim_win_is_valid(M.win)) then
    return nil
  end
  for i = vim.api.nvim_win_get_cursor(M.win)[1], 1, -1 do
    if rows[i] then
      return rows[i]
    end
  end
  return nil
end

--- Closes the window and does `fn`, which is how every key that opens
--- something else behaves: this is a float over the middle of the
--- editor and it is in the way of whatever comes next.
local function instead(fn)
  return function()
    local thread = thread_at()
    if not thread then
      return
    end
    M.close()
    fn(thread)
  end
end

function M.open()
  if not session.current then
    session.notify("no merge request open — :Nemeton to pick one", vim.log.levels.WARN)
    return
  end
  M.close()

  local width = math.min(math.floor(vim.o.columns * 0.7), 100)
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
    title = (" !%d · every thread "):format(session.current.iid),
    title_pos = "center",
  })
  vim.wo[M.win].wrap = true
  vim.wo[M.win].linebreak = true
  vim.wo[M.win].cursorline = true

  local k = config.keys.conversation
  local hint = "%%#NemetonHint#%s code · %s reply · %s edit"
    .. " · %s delete · %s refresh · %s quit%%*"
  vim.wo[M.win].winbar = hint:format(k.code, k.reply, k.edit, k.delete, k.refresh, k.quit)

  local bindings = {
    { k.quit, M.close, "close" },
    -- Not `instead`: the window closes only once the thread turns out
    -- to have somewhere to go, and a thread on the merge request
    -- itself does not.
    {
      k.code,
      function()
        session.goto_thread(thread_at(), M.close)
      end,
      "go to the code this is about",
    },
    { k.reply, instead(edit.reply), "reply to the thread here" },
    { k.edit, instead(edit.thread), "edit a comment in the thread here" },
    { k.delete, instead(edit.delete), "delete a comment in the thread here" },
    {
      k.refresh,
      function()
        session.refresh(render)
      end,
      "refetch",
    },
  }
  for _, b in ipairs(bindings) do
    if b[1] and b[1] ~= "" then
      vim.keymap.set("n", b[1], b[2], { buffer = M.buf, nowait = true, desc = "nemeton: " .. b[3] })
    end
  end

  render()
  return M.win
end

return M
