-- The merge request itself, in a float: what it is for, what CI made of
-- it, who has approved it -- and the keys to act on all three.
--
-- The description float grew into this because of where the questions
-- are asked from. "Should I approve this" is asked after reading what
-- it is for and what the pipeline said, and that is one window; a key
-- for it out in the buffer, three files away, is a key nobody
-- remembers is there.

local config = require("nemeton.config")
local detail = require("nemeton.detail")
local follow = require("nemeton.follow")
local session = require("nemeton.session")

local M = {}

M.win = nil
M.buf = nil

function M.close()
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    vim.api.nvim_win_close(M.win, true)
  end
  M.win, M.buf = nil, nil
end

local function open_state()
  return M.win ~= nil and vim.api.nvim_win_is_valid(M.win)
end

local function drawn()
  return require("nemeton.threads").flatten(detail.description_chunks(session.current), 0)
end

-- The keys reached for every time, in the order they are asked for:
-- the two verdicts you came to give -- approve it, and send what you
-- wrote about it -- the thread window, and the merge the review was
-- for. The rest are `g?`'s, read out of the bindings below: naming all
-- ten across the top was a row cut off at the right-hand edge, and
-- what fell off it was the keys that end a merge request.
--
-- Reading every thread is not among the bindings. `c` is already the
-- window for what has been said off the code, and the threads that are
-- *on* the code are read where the code is -- in the gutter, on `]m`,
-- in the quickfix list. `:Nemeton conversation` still reads all of it.
--
-- Drawn again with the window, because a word changes: a merge waiting
-- on its pipeline is taken back with the key that set it.
local function hint()
  local k, mr = config.keys.detail, session.current or {}
  local open = mr.state == nil or mr.state == "opened"
  return detail.hint({
    { k.approve, "approve" },
    { k.publish, "send" },
    { k.comments, "comments" },
    { open and k.merge, mr.merge_when_pipeline_succeeds and "unmerge" or "merge" },
  }, k.help)
end

--- Rewrites the float in place, for after something it shows changes.
function M.redraw()
  if not (open_state() and session.current) then
    return
  end
  local lines, hls = drawn()
  vim.bo[M.buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.bo[M.buf].modifiable = false
  require("nemeton.marks").paint(M.buf, hls)
  vim.wo[M.win].winbar = hint()
end

--- Closes this and opens `fn`'s window in its place, handing it the
--- way back here for its `q`.
---
--- The two are floats over the middle of the editor and one is in the
--- way of the other, so this one goes. But it is where the comments,
--- the pipeline and the description were reached from, and `q` on any
--- of them is the reader done with that and not with the merge request:
--- it comes back here, and `q` here is the one that puts them back in
--- the file.
local function instead(back, fn)
  return function()
    M.close()
    local done = false
    fn(function()
      -- Once: the composer goes back from its `q` and again from the
      -- `WinClosed` that closing it fires.
      if done then
        return
      end
      done = true
      back()
      M.open()
    end)
  end
end

function M.open()
  local mr = session.current
  if not mr then
    session.notify("no merge request open — :Nemeton to pick one", vim.log.levels.WARN)
    return
  end
  M.close()

  local k = config.keys.detail
  local back = require("nemeton.win").came_from()
  local lines, hls = drawn()
  M.win, M.buf = detail.float(lines, (" !%d "):format(mr.iid), {
    winbar = hint(),
    hls = hls,
    quit = k.quit,
    help = k.help,
    keys = {
      {
        k.approve,
        function()
          -- Redrawn when the answer lands rather than now: what this
          -- window says about approvals is what GitLab says about them.
          require("nemeton").approve(nil, M.redraw)
        end,
        "approve, or take the approval back",
      },
      {
        k.publish,
        function()
          -- Same again: what this window says is unsent is on the
          -- screen, and sending it is the one thing that makes that
          -- count a lie.
          require("nemeton").publish(M.redraw)
        end,
        "send every comment kept unsent",
      },
      {
        k.comments,
        instead(back, function(again)
          require("nemeton.notes").open(nil, again)
        end),
        "every thread on the merge request, whole",
      },
      {
        k.pipeline,
        instead(back, function(again)
          require("nemeton.jobs").open(again)
        end),
        "what CI did, job by job",
      },
      {
        k.merge,
        function()
          require("nemeton").merge(M.redraw)
        end,
        "merge when the pipeline succeeds, after asking",
      },
      {
        k.close,
        function()
          require("nemeton").close_or_reopen(M.redraw)
        end,
        "close it, or reopen it, after asking",
      },
      {
        k.draft,
        function()
          require("nemeton").toggle_draft(M.redraw)
        end,
        "mark it a draft, or ready",
      },
      {
        k.retitle,
        function()
          require("nemeton").retitle(M.redraw)
        end,
        "give it a new title",
      },
      {
        k.describe,
        instead(back, function(again)
          -- Redrawn when the answer lands: the window is back up before
          -- the forge has taken the new description.
          require("nemeton").describe(M.redraw, again)
        end),
        "rewrite its description",
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
      {
        k.refresh,
        function()
          session.refresh_approvals(M.redraw)
          session.refresh_changes(M.redraw)
        end,
        "refetch",
      },
    },
  })
  return M.win
end

return M
