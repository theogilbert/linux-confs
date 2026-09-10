-- What a comment points at, gone to.
--
-- A review comment is half made of things that are not words: a person
-- to ask, a commit to read, a page to open, another argument to go and
-- read first. Drawn, each of them is already in a colour of its own --
-- and until now that was the whole of what the plugin did about them,
-- which left the reader copying eight digits out of a floating window
-- by hand.
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
-- they do with it. `config.comments.follow` is the kinds, and `true` in
-- any of them is that.
--
-- With one exception, which is the one destination that is not a page
-- somewhere else: a link to another comment on this merge request is a
-- link to a conversation this editor already has open, and `true` goes
-- to it. Nothing is opened that was not open, no browser is raised, and
-- the reader who pressed the key on "see !7 (comment 1234)" asked for
-- exactly this.
--
-- The refs themselves come from `threads.render`, which puts what a run
-- points at beside the run: this module only remembers where they
-- landed in a buffer it did not draw.

local config = require("nemeton.config")

local M = {}

-- Buffer -> the references drawn in it, as `threads.flatten` hands
-- them over, and the way out of the window drawing them. Replaced
-- whole on every render, because every render replaces the whole
-- buffer.
local drawn = {}

--- Remembers what `buf` now has in it. Called by every window that
--- draws a conversation, straight after it writes the lines.
---
--- `leave` is that window's way out, for the one kind of reference
--- whose destination is inside this editor: a float has to close before
--- anything else can be shown, since `:edit` from inside one opens the
--- file in the float. The window that is a split rather than a float
--- passes what it does instead, and one with nowhere to go passes
--- nothing.
---
--- ...and forgets the buffers that have gone away, here rather than on
--- an autocommand of their own: these windows wipe their buffer when
--- they close, buffer numbers are reused, and there are never more than
--- three of them to walk.
function M.set(buf, refs, leave)
  for other in pairs(drawn) do
    if not vim.api.nvim_buf_is_valid(other) then
      drawn[other] = nil
    end
  end
  drawn[buf] = { refs = refs or {}, leave = leave }
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
  for _, ref in ipairs((drawn[buf] or {}).refs or {}) do
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

--- The branch a relative link is measured against.
---
--- `main` where there is no review open, which is only reached by a
--- caller asking about a link it cannot have read anywhere.
local function branch()
  local session = require("nemeton.session")
  return (session.current and session.current.target_branch) or "main"
end

--- Where a reference points, as a URL, or nil for one that has nowhere
--- to point on this forge.
---
--- A link written in a comment is followed as it was written, except
--- for the ones that were never a URL: a reference to another merge
--- request on the same project is a path and not a URL, and a path
--- opened in a browser is a file that is not there.
---
--- What a path is measured from is the forge's decision and not this
--- one, and the forge measures three of them differently. A path from
--- the root is a page on the forge and is one. An upload -- which is
--- what GitLab writes when a file is dragged into a comment -- is
--- served off the project rather than off the root. And a link that is
--- relative to nothing at all is relative to the *repository*: GitLab
--- sends a reader who clicks `doc/design.md` to that file on the
--- branch, not to a page of that name on the forge, which is the one
--- this used to hand over and it was always a 404.
---
--- Against the target branch, where GitLab would use the project's
--- default. They are the same branch on all but a merge request
--- stacked on another one -- and on that one, the file as the branch
--- under review has it is the file being talked about.
function M.href(ref)
  if not ref then
    return nil
  end
  local host, project = forge()
  -- The three that carry where they point: a page, a page on this forge
  -- written as the path to one, and a comment anchored on a page.
  if ref.kind == "url" or ref.kind == "path" or ref.kind == "thread" then
    local href = ref.href or ""
    if href:match("^https?://") then
      return href
    end
    -- A fragment on its own is somewhere on the page it was written on,
    -- which is this merge request.
    if href:sub(1, 1) == "#" then
      local session = require("nemeton.session")
      local page = session.current and session.current.web_url
      return page and (page .. href) or nil
    end
    if href:match("^/uploads/") then
      return project and (project .. href) or nil
    end
    if href:sub(1, 1) == "/" then
      return host and (host .. href) or nil
    end
    return project and ("%s/-/blob/%s/%s"):format(project, branch(), href) or nil
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

--- The other direction: a link to a line of this branch, for pasting
--- into a comment about code somewhere else.
---
--- Against the head sha rather than the branch name. A link to a branch
--- says whatever that branch says next week, and a review comment is
--- about the code as it was argued over -- which is the whole reason
--- the forge offers a permalink on the page. `#L3-4` is GitLab's own
--- spelling of a span.
---
--- Nil where there is no page to point at: no review open, or a merge
--- request this plugin never learned the URL of.
function M.line_link(path, first, last, at)
  local session = require("nemeton.session")
  local mr = session.current
  local sha = at or (mr and mr.diff_refs and mr.diff_refs.head_sha)
  local _, project = forge()
  if not (path and sha and project) then
    return nil
  end
  local lines = (last and last > first) and ("#L%d-%d"):format(first, last)
    or ("#L%d"):format(first)
  return ("%s/-/blob/%s/%s%s"):format(project, sha, path, lines)
end

--- Puts `text` where a paste will find it.
---
--- The `+` register: the system clipboard, which is where "copied"
--- means what a reader outside this editor thinks it means. An editor
--- built without one leaves it in the unnamed register, which is still
--- a paste away.
function M.copy(text)
  pcall(vim.fn.setreg, vim.fn.has("clipboard") == 1 and "+" or '"', text)
end

--- Which merge request is open, or nil for none.
local function mine()
  local session = require("nemeton.session")
  return session.current and session.current.iid or nil
end

--- Shows `thread`, wherever this plugin shows one of its sort, and
--- leaves the window the link was read in first.
---
--- Two destinations because there are two sorts. A thread on a line is
--- read beside the code it is about -- `goto_thread` opens the file,
--- puts the cursor on the line and the pane on the thread -- and a
--- comment on the merge request itself is about no line and has no code
--- to be read beside: it is shown in the comments window, which is
--- where it was written and where the rest of them are.
local function shown(thread, leave)
  local session = require("nemeton.session")
  if thread.path and thread.line then
    return session.goto_thread(thread, leave)
  end
  if leave then
    leave()
  end
  require("nemeton.notes").open(thread)
  return true
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
--- URL is the one of them that is never typed out again by hand.
local function said(ref, href)
  if ref.kind == "mention" then
    return ("User %s"):format(ref.text)
  end
  if ref.kind == "commit" then
    return ("commit %s"):format(ref.text)
  end
  -- A comment this review cannot show. Said out loud rather than passed
  -- over in silence: the reader pressed the key expecting to be taken
  -- there, and "link copied" on its own reads as the plugin having
  -- decided not to bother.
  local why = nil
  if ref.kind == "thread" then
    why = ref.iid ~= mine() and ("comment %s is on !%s"):format(ref.text, ref.iid)
      -- Resolved while resolved threads are not being drawn, deleted
      -- since somebody linked it, or written on a merge request this
      -- editor has not got open.
      or ("comment %s is not in this review"):format(ref.text)
  end
  local url = href or ref.href
  if not url then
    return nil
  end
  M.copy(url)
  return why and (why .. " — link copied") or "Link copied to clipboard"
end

--- Follows `ref`: whatever `config.comments.follow` says to do with one
--- of its kind. False where there is nothing set for that kind.
---
--- A function of yours is called with the URL as well as the text, and
--- with it nil where this plugin cannot work one out: what to do with
--- `a1b2c3d4` is a question `git` can answer without a forge, and this
--- is not the module to decide it cannot be answered.
function M.go(ref, leave)
  if not ref then
    return false
  end
  local follow = config.comments.follow or {}
  local how = follow[ref.kind]
  -- `url` and `path` were one `link` until they were two, and a config
  -- written while they were one means both of them. The default table
  -- has no `link` in it any more, so anything there is the reader's own
  -- and is honoured; saying `link` and `url` both is a migration
  -- half-done, and the specific one is the one to write.
  if follow.link ~= nil and (ref.kind == "url" or ref.kind == "path") then
    how = follow.link
  end
  if not how then
    return false
  end
  local href = M.href(ref)
  -- The thread the comment named, where it is one this review has open:
  -- worked out before anything is done about it, because it is the
  -- difference between a place to go and a link to copy -- and it is
  -- handed to a function of yours as well, which is the whole of what
  -- one would otherwise have to go and look up.
  local thread = nil
  if ref.kind == "thread" and ref.iid == mine() then
    thread = require("nemeton.session").thread_of(ref.text)
  end
  if type(how) == "function" then
    how(ref.text, href, thread)
    return true
  end
  if thread then
    return shown(thread, leave)
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
  return M.go(M.at(buf, pos[1] - 1, pos[2]), (drawn[buf] or {}).leave)
end

return M
