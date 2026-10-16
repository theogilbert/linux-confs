-- Who gave a reaction, in a float over it.
--
-- The names are not drawn under the note: a row of pictures with a
-- count beside each is what the page shows, and a review is read for
-- what people wrote. But "who" is a question asked of a row -- three
-- thumbs from three maintainers is an argument being over, and three
-- from the author's friends is not -- and on the page the answer is a
-- hover. This is the hover here: the cursor resting on a reaction, or
-- `K` on it, and a float beside it that the next move takes away. No
-- state, no key to close it, nothing to leave open over the prose.
--
-- And when, on the head of a note. The head says "2d" and eight digits
-- of a sha, which is what a head has room for and not what is wanted
-- the moment the question is "was this before or after the push on
-- Tuesday": the same float, on `K` over the age, says when to the
-- second and with the day of the week, and on `K` over the sha, the
-- commit -- its time, its message and the lines it changed in each
-- file. The key only: the head is the line the cursor crosses on the
-- way into every note, and a float that rose on each of them was one
-- over the words being read.
--
-- And where, on a link. A link is drawn as the words it was given and
-- not the URL behind them, which is the right trade until the question
-- is "is that the docs, or somebody's fork of them": `K` on it says
-- the address, whole. The key only again -- a link is in the middle of
-- a sentence, and a float over the next line of it is in the way of
-- the reading the link was shortened for.
--
-- `K` again, on any of the three, goes into the float: to scroll a
-- long list of names, or to yank the URL out of it.

local config = require("nemeton.config")
local log = require("nemeton.log")
local follow = require("nemeton.follow")
local threads = require("nemeton.threads")
local win = require("nemeton.win")

local M = {}

M.win = nil
-- Where the float was opened for, so that the hold that fires after
-- `K` on the same reaction does not take it down to put it back up.
local shown = nil
-- The autocmd that takes it down on the next move, which going into it
-- has to take away first.
local dismiss = nil

function M.close()
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    vim.api.nvim_win_close(M.win, true)
  end
  M.win, shown, dismiss = nil, nil, nil
end

--- Where a link goes, whole: the address it was written with where that
--- is one, and otherwise the page `follow` would open for it -- a path
--- or a fragment is only half an address.
local function address(ref, on)
  if ref.href:match("^https?://") then
    return ref.href
  end
  return follow.href(ref, on) or ref.href
end

--- The names as one line: whoever gave it, in the order the forge
--- listed them, and "you" for the reader -- which is what the colour of
--- the row already said, so the float agrees with it.
local function names(ref, on)
  local me = on and on.me
  local out = {}
  for _, user in ipairs(ref.who or {}) do
    table.insert(out, (me and user == me) and "you" or user)
  end
  return table.concat(out, ", ")
end

-- sha -> what git says of it: asked once each, since a hover is asked
-- again every time the cursor rests. Only what git answered is kept --
-- a commit this clone has not got yet is one the session may fetch a
-- moment later (`session.fetch_commit`).
local committed = {}

--- What the clone knows of `sha`: its time, its message, and the lines
--- it changed in each file. Waited on, and only briefly: this is a
--- hover, on one commit this editor has almost certainly checked out,
--- and a float that arrives after the cursor has moved on arrives over
--- nothing.
local function commit_of(sha, on)
  if committed[sha] == nil then
    local root = on and on.root
    if root then
      local cmd = { "git", "show", "--numstat", "--format=%H%x00%ct%x00%s%x00%b%x00", sha }
      local done = log.exec(cmd, { cwd = root })
      local ok, res = pcall(function()
        return vim.system(cmd, { text = true, cwd = root }):wait(1000)
      end)
      if ok and res then
        done(res.code, res.stderr)
        local full, at, subject, body, stat = (res.stdout or ""):match(
          "^(%x+)%z(%d+)%z([^%z]*)%z([^%z]*)%z(.*)$"
        )
        if res.code == 0 and full then
          local files = {}
          for added, removed, path in stat:gmatch("([%d-]+)\t([%d-]+)\t([^\n]+)") do
            table.insert(files, { tonumber(added), tonumber(removed), path })
          end
          committed[sha] = {
            sha = full,
            at = tonumber(at),
            subject = subject,
            body = vim.trim(body),
            files = files,
          }
        end
      end
    end
  end
  return committed[sha]
end

-- More files than this and the float is a list to scroll rather than a
-- glance; the rest are counted, and `K` again goes in for the whole.
local FILES = 20

--- The float over a note's sha: the commit whole, its time, what it says
--- and what it changed -- `git show --stat` in the room of a hover. For
--- one this clone has not got, when it was pushed, which is what the
--- merge request's versions know of it.
local function commit(ref, on)
  local lines, hls = {}, {}
  local function add(text, spans)
    table.insert(lines, text)
    for _, s in ipairs(spans or {}) do
      local stop = s[2] == -1 and #text or s[2]
      table.insert(hls, { row = #lines - 1, col = s[1], end_col = stop, hl = s[3] })
    end
  end
  local c = commit_of(ref.sha, on)
  if not c then
    add(ref.sha, { { 0, #ref.sha, "NemetonMeta" } })
    local pushed = threads.when(threads.epoch(ref.pushed))
    add(pushed and ("pushed " .. pushed) or "not in this clone", { { 0, 6, "NemetonMeta" } })
    return lines, hls
  end
  add(c.sha, { { 0, #c.sha, "NemetonMeta" } })
  add(threads.when(c.at) or "", { { 0, -1, "NemetonMeta" } })
  add("")
  add(c.subject, { { 0, #c.subject, "NemetonAuthor" } })
  if c.body ~= "" then
    add("")
    for _, l in ipairs(vim.split(c.body, "\n", { plain = true })) do
      add(l)
    end
  end
  if #c.files == 0 then
    return lines, hls
  end
  add("")
  -- Binary files count no lines (`-` from git), and are named all the
  -- same: a commit's files are what it touched, not only what diffs.
  local plus, minus = 0, 0
  local cells = {}
  for _, f in ipairs(c.files) do
    plus, minus = plus + (f[1] or 0), minus + (f[2] or 0)
    table.insert(cells, { f[1] and ("+" .. f[1]) or "bin", f[2] and ("−" .. f[2]) or "" })
  end
  local a, r = "+" .. plus, "−" .. minus
  local total = ("%s %s · %d file%s"):format(a, r, #c.files, #c.files == 1 and "" or "s")
  add(total, {
    { 0, #a, "NemetonAdded" },
    { #a + 1, #a + 1 + #r, "NemetonRemoved" },
    { #a + 1 + #r, -1, "NemetonMeta" },
  })
  local wa, wr = 0, 0
  for _, cell in ipairs(cells) do
    wa = math.max(wa, vim.fn.strdisplaywidth(cell[1]))
    wr = math.max(wr, vim.fn.strdisplaywidth(cell[2]))
  end
  for i, f in ipairs(c.files) do
    if i > FILES then
      add(("… %d more"):format(#c.files - FILES), { { 0, -1, "NemetonMeta" } })
      break
    end
    local ca, cr = cells[i][1], cells[i][2]
    local left = "  " .. ca .. (" "):rep(wa - vim.fn.strdisplaywidth(ca)) .. " "
    local mid = cr .. (" "):rep(wr - vim.fn.strdisplaywidth(cr)) .. "  "
    add(left .. mid .. f[3], {
      { 2, 2 + #ca, f[1] and "NemetonAdded" or "NemetonMeta" },
      { #left, #left + #cr, "NemetonRemoved" },
      { #left + #mid, -1, "NemetonPath" },
    })
  end
  return lines, hls
end

--- Says who gave the reaction under the cursor, when the note under it
--- was written, or where the link under it goes. Nothing at all on
--- anything else: this runs on every rest of the cursor in a window of
--- prose, and a window that says "no" every time the cursor stops was
--- a window to read past. `resting` is the hover asking rather than
--- the key, and a rest answers for a reaction only.
function M.show(resting)
  local buf = vim.api.nvim_get_current_buf()
  local pos = vim.api.nvim_win_get_cursor(0)
  local ref = follow.under(buf, pos[1] - 1, pos[2])
  if resting and ref and ref.kind == "stamp" and shown == ref then
    return M.win
  end
  local link = ref and ref.href ~= nil
  if resting and link and shown == ref then
    return M.win
  end
  if not (ref and (ref.kind == "reaction" or (not resting and (ref.kind == "stamp" or link)))) then
    M.close()
    return nil
  end
  if M.win and vim.api.nvim_win_is_valid(M.win) and shown == ref then
    if not resting then
      win.enter(M.win, dismiss, M.close)
      dismiss = nil
    end
    return M.win
  end
  M.close()

  local on = follow.subject(buf)
  local lines, hls = {}, {}
  if ref.kind == "reaction" then
    local picture = threads.emoji(":" .. ref.name .. ":")
    lines[1] = picture .. "  " .. names(ref, on)
    hls[1] = {
      row = 0,
      col = 0,
      end_col = #picture,
      hl = ref.mine and "NemetonReactionMine" or "NemetonReaction",
    }
  elseif link then
    lines[1] = address(ref, on)
  elseif ref.sha then
    lines, hls = commit(ref, on)
  else
    local written = threads.when(threads.epoch(ref.written))
    if not written then
      return nil
    end
    lines[1] = written
  end
  -- Wider for a time than for names: a date that wraps is two halves
  -- of one fact, where a list of names wraps between two of them. And
  -- as wide as there is for an address, which is one word.
  local most = link and vim.o.columns - 10 or ref.kind == "stamp" and 80 or 60
  most = math.max(math.min(vim.o.columns - 10, most), 20)
  local widest, height = 1, 0
  for _, l in ipairs(lines) do
    widest = math.max(widest, vim.fn.strdisplaywidth(l))
  end
  local width = math.min(widest, most)
  for _, l in ipairs(lines) do
    height = height + math.max(1, math.ceil(vim.fn.strdisplaywidth(l) / width))
  end
  -- A commit's message can be a page; half the screen of it, and `K`
  -- again goes in to read the rest.
  height = math.max(1, math.min(height, math.floor(vim.o.lines / 2)))
  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, lines)
  require("nemeton.marks").paint(fbuf, hls)
  vim.bo[fbuf].modifiable = false
  vim.bo[fbuf].bufhidden = "wipe"
  M.win = vim.api.nvim_open_win(fbuf, false, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    -- Not until the second `K` (`win.enter`), which is the way in: a
    -- hover that `<C-w>w` stopped in on the way past is one in the way.
    focusable = false,
  })
  vim.wo[M.win].winhighlight = "NormalFloat:Normal"
  vim.wo[M.win].wrap = true
  shown = ref
  -- Dismissed by moving, like the hover it is. Once, and on this
  -- buffer: a float over a window that has just been left is a float
  -- over nothing.
  dismiss = vim.api.nvim_create_autocmd({ "CursorMoved", "InsertEnter", "BufLeave" }, {
    buffer = buf,
    once = true,
    callback = M.close,
  })
  return M.win
end

--- Puts the hover on `buf`: `CursorHold`, which is the cursor resting
--- for `updatetime` -- four seconds as Neovim ships, and a few hundred
--- milliseconds in most configs, where it is what makes a hover a
--- hover. `comments.hover = false` leaves only the key. The head of a
--- note is the key's alone (see the top of this file).
function M.attach(buf)
  if not config.comments.hover then
    return
  end
  vim.api.nvim_create_autocmd("CursorHold", {
    buffer = buf,
    callback = function()
      M.show(true)
    end,
  })
end

return M
