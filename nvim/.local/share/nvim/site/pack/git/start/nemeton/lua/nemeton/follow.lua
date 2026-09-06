-- What a comment points at, gone to.
--
-- A review comment is half made of things that are not words: a person
-- to ask, a commit to read, a page to open. Drawn, each of the three is
-- already in a colour of its own -- and until now that was the whole of
-- what the plugin did about them, which left the reader copying eight
-- digits out of a floating window by hand.
--
-- So `<C-]>` in the windows that draw a conversation. The same key vim
-- has always used for "go to the thing under the cursor", because that
-- is what it is: a tag jump, into a forge instead of a tags file.
--
-- What it does when it gets there is the reader's to decide, and that
-- is why this is a setting rather than a keymap: a commit is
-- `:DiffviewOpen` for one reviewer, `:Git show` for another and a
-- terminal for a third, and a mention is worth a message to somebody on
-- a team that reads its messages somewhere else.
--
-- So the default is the quietest thing that is still an answer: it says
-- what the thing under the cursor is, and puts a link on the clipboard.
-- Nothing is opened and no window moves -- a key that took the editor
-- somewhere would be a key pressed once by accident and never again --
-- and the URL a reader is given is worked out the same way whatever
-- they do with it. `config.comments.follow` is the three kinds, and
-- `true` in any of them is that.
--
-- The refs themselves come from `threads.render`, which puts what a run
-- points at beside the run: this module only remembers where they
-- landed in a buffer it did not draw.

local config = require("nemeton.config")

local M = {}

-- Buffer -> the references drawn in it, as `threads.flatten` hands
-- them over. Replaced whole on every render, because every render
-- replaces the whole buffer.
local drawn = {}

--- Remembers what `buf` now has in it. Called by every window that
--- draws a conversation, straight after it writes the lines.
---
--- ...and forgets the buffers that have gone away, here rather than on
--- an autocommand of their own: these windows wipe their buffer when
--- they close, buffer numbers are reused, and there are never more than
--- three of them to walk.
function M.set(buf, refs)
  for other in pairs(drawn) do
    if not vim.api.nvim_buf_is_valid(other) then
      drawn[other] = nil
    end
  end
  drawn[buf] = refs or {}
end

--- The reference at (row, col) of `buf` -- 0-based, the way the cursor
--- is reported once the row is taken off it.
---
--- The one the cursor is inside, and otherwise the next one along on
--- the same line: `<C-]>` pressed at the start of a line that carries
--- one link should follow it rather than say there is nothing here.
--- Nothing at all from a line that carries none, which is most of them.
function M.at(buf, row, col)
  local best = nil
  for _, ref in ipairs(drawn[buf] or {}) do
    if ref.row == row then
      if col >= ref.col and col < ref.end_col then
        return ref.ref
      end
      if ref.col > col and (not best or ref.col < best.col) then
        best = ref
      end
    end
  end
  return best and best.ref or nil
end

--- The forge this review is on, as the front of a URL: everything
--- before the project. Read out of the merge request's own page rather
--- than asked for, because that is a string this plugin already has and
--- is right even where `glab` is reading its host from somewhere this
--- does not know about.
local function forge()
  local session = require("nemeton.session")
  local url = session.current and session.current.web_url
  if not url then
    return nil, nil
  end
  local project = url:match("^(.*)/%-/merge_requests/%d+")
  return url:match("^(https?://[^/]+)"), project
end

--- Where a reference points, as a URL, or nil for one that has nowhere
--- to point on this forge.
---
--- A link written in a comment is followed as it was written, except
--- for the ones GitLab writes itself: a reference to another merge
--- request on the same project is a path and not a URL, and a path
--- opened in a browser is a file that is not there.
function M.href(ref)
  if not ref then
    return nil
  end
  local host, project = forge()
  if ref.kind == "link" then
    local href = ref.href or ""
    if href:match("^https?://") then
      return href
    end
    return host and (host .. (href:sub(1, 1) == "/" and href or "/" .. href)) or nil
  end
  if ref.kind == "commit" then
    return project and (project .. "/-/commit/" .. ref.text) or nil
  end
  if ref.kind == "mention" then
    -- A username is a page at the root of the forge, which is the one
    -- shape of GitLab URL that has stayed the same since it had one.
    return host and (host .. "/" .. ref.text) or nil
  end
  return nil
end

--- What `true` does with each kind: say what it is, and leave what to
--- do about it to you.
---
--- Deliberately the quietest thing that is still an answer. `<C-]>` is
--- pressed in the middle of reading a comment, and a key that takes the
--- editor somewhere -- a browser window over the top of it, a buffer in
--- the window you were reading in -- is a key pressed once by accident
--- and then never again. What the reader wanted is usually the string:
--- the sha to `git show`, the name to ask around about, the URL to send
--- to somebody. So the default hands over the string.
---
--- A link goes to the clipboard as well as to the message, because a
--- URL is the one of the three that is never typed out again by hand.
local function said(ref, href)
  if ref.kind == "mention" then
    return ("User %s"):format(ref.text)
  end
  if ref.kind == "commit" then
    return ("commit %s"):format(ref.text)
  end
  local url = href or ref.href
  if not url then
    return nil
  end
  -- The `+` register: the system clipboard, which is where "copied"
  -- means what a reader outside this editor thinks it means. An editor
  -- built without one leaves it in the unnamed register, which is
  -- still a paste away.
  pcall(vim.fn.setreg, vim.fn.has("clipboard") == 1 and "+" or '"', url)
  return "Link copied to clipboard"
end

--- Follows `ref`: whatever `config.comments.follow` says to do with one
--- of its kind. False where there is nothing set for that kind.
---
--- A function of yours is called with the URL as well as the text, and
--- with it nil where this plugin cannot work one out: what to do with
--- `a1b2c3d4` is a question `git` can answer without a forge, and this
--- is not the module to decide it cannot be answered.
function M.go(ref)
  if not ref then
    return false
  end
  local how = (config.comments.follow or {})[ref.kind]
  if not how then
    return false
  end
  local href = M.href(ref)
  if type(how) == "function" then
    how(ref.text, href)
    return true
  end
  local message = said(ref, href)
  if not message then
    return false
  end
  require("nemeton.session").notify(message)
  return true
end

--- Follows whatever the cursor in the current window is on.
---
--- Quiet on a line with nothing on it to follow: `<C-]>` is pressed
--- while reading, and a window that says "no" every time the cursor was
--- somewhere else is a window that has to be read past.
function M.here()
  local buf = vim.api.nvim_get_current_buf()
  local pos = vim.api.nvim_win_get_cursor(0)
  return M.go(M.at(buf, pos[1] - 1, pos[2]))
end

return M
