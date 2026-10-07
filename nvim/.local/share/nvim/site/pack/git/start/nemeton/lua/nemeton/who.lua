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
-- Tuesday": the same float, on `K` over the head, says both exactly --
-- to the second and with the day of the week. The key only: the head
-- is the line the cursor crosses on the way into every note, and a
-- float that rose on each of them was one over the words being read.
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
local function address(ref)
  if ref.href:match("^https?://") then
    return ref.href
  end
  return follow.href(ref) or ref.href
end

--- The names as one line: whoever gave it, in the order the forge
--- listed them, and "you" for the reader -- which is what the colour of
--- the row already said, so the float agrees with it.
local function names(ref)
  local session = require("nemeton.session")
  local me = session.current and session.current.me
  local out = {}
  for _, user in ipairs(ref.who or {}) do
    table.insert(out, (me and user == me) and "you" or user)
  end
  return table.concat(out, ", ")
end

-- sha -> when it was committed: asked of git once each, since a hover
-- is asked again every time the cursor rests. Only what git answered
-- is kept -- a commit this clone has not got yet is one the session
-- may fetch a moment later (`session.fetch_commit`).
local committed = {}

--- When `sha` was committed, as the clone knows it. Waited on, and only
--- briefly: this is a hover, on one commit this editor has almost
--- certainly checked out, and a float that arrives after the cursor has
--- moved on arrives over nothing.
local function commit_time(sha)
  if committed[sha] == nil then
    local session = require("nemeton.session")
    local root = session.current and session.current.root
    if root then
      local cmd = { "git", "show", "-s", "--format=%ct", sha }
      local done = log.exec(cmd, { cwd = root })
      local ok, res = pcall(function()
        return vim.system(cmd, { text = true, cwd = root }):wait(1000)
      end)
      if ok and res then
        done(res.code, res.stderr)
        committed[sha] = res.code == 0 and tonumber(vim.trim(res.stdout or "")) or nil
      end
    end
  end
  return committed[sha]
end

--- What the float over a note's head says: when it was written, and
--- when the commit it was written against was made -- or, for one this
--- clone has not got, when it was pushed, which is the other half of
--- the same question and what the merge request's versions know.
local function stamp(ref)
  local out = {}
  local written = threads.when(threads.epoch(ref.written))
  if written then
    table.insert(out, { "written ", written })
  end
  if ref.sha then
    local at = commit_time(ref.sha)
    if at then
      table.insert(out, { "commit  ", ("%s · %s"):format(ref.sha:sub(1, 8), threads.when(at)) })
    else
      local pushed = threads.when(threads.epoch(ref.pushed))
      table.insert(
        out,
        { "commit  ", pushed and ("%s · pushed %s"):format(ref.sha:sub(1, 8), pushed) or ref.sha }
      )
    end
  end
  return out
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

  local lines, hls = {}, {}
  if ref.kind == "reaction" then
    local picture = threads.emoji(":" .. ref.name .. ":")
    lines[1] = picture .. "  " .. names(ref)
    hls[1] = {
      row = 0,
      col = 0,
      end_col = #picture,
      hl = ref.mine and "NemetonReactionMine" or "NemetonReaction",
    }
  elseif link then
    lines[1] = address(ref)
  else
    for i, pair in ipairs(stamp(ref)) do
      lines[i] = pair[1] .. pair[2]
      table.insert(hls, { row = i - 1, col = 0, end_col = #pair[1], hl = "NemetonMeta" })
    end
    if #lines == 0 then
      return nil
    end
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
