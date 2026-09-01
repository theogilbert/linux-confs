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
end

--- Closes this and opens `fn`'s window in its place.
---
--- The two are floats over the middle of the editor and one is in the
--- way of the other; and coming back here afterwards would put a window
--- on top of the window somebody just chose to look at.
local function instead(fn)
  return function()
    M.close()
    fn()
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
  -- Everything the window can do, in the order it is asked for: the two
  -- verdicts you came to give -- approve it, and send what you wrote
  -- about it -- then the windows this one leads to, then the
  -- housekeeping.
  --
  -- Reading every thread is not among them. `c` is already the window
  -- for what has been said off the code, and the threads that are *on*
  -- the code are read where the code is -- in the gutter, on `]m`, in
  -- the quickfix list. A second key here that opened a window
  -- containing what `c` contains would be one key too many; and `t` is
  -- a motion, which is the other half of the rule this window keeps.
  -- `:Nemeton conversation` still reads all of it at once.
  local hint = detail.hint({
    { k.approve, "approve" },
    { k.publish, "send" },
    { k.comments, "comments" },
    { k.pipeline, "jobs" },
    { k.browser, "browser" },
    { k.refresh, "refetch" },
    { k.quit, "quit" },
  })

  local lines, hls = drawn()
  M.win, M.buf = detail.float(lines, (" !%d "):format(mr.iid), {
    winbar = hint,
    hls = hls,
    quit = k.quit,
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
        instead(function()
          require("nemeton.notes").open()
        end),
        "every comment on the merge request, one line each",
      },
      {
        k.pipeline,
        instead(function()
          require("nemeton.jobs").open()
        end),
        "what CI did, job by job",
      },
      {
        k.browser,
        function()
          if mr.web_url then
            vim.ui.open(mr.web_url)
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
