-- The review of a merge request as the forge last answered it, on disk.
--
-- An editor started on the branch of a merge request opens its review
-- by itself (`nemeton.resume`), and until this it opened it on the
-- forge's answer: five calls and a diff, a second or several, with the
-- gutter empty in the meantime and the first `]m` a key that did
-- nothing. What it is drawn from is written down here instead, as the
-- payloads came, and drawn from the moment the editor is up; the forge
-- is asked all the same, and what it says replaces every table of it.
--
-- One file per merge request, under a directory per repository, beside
-- `merge-requests.json`: what `seen.lua` knows to be open is the only
-- thing ever read back, and a repository it forgets is one `rm -r`.
-- Written when a review has opened, when its diff lands and when the
-- editor quits -- not on every refresh, which is every note posted, and
-- the diff is the largest thing this plugin ever asks for.
--
-- Unlike `merge-requests.json` this is what people wrote, and so is
-- 0600 in a 0700 directory, like the composer's leftovers. Nothing in
-- it is a credential.

local config = require("nemeton.config")
local jsonfile = require("common.store")

local M = {}

-- What a file of an older shape is: not read, and overwritten by the
-- next write.
local VERSION = 1

local function enabled()
  return config.list.remember and config.list.resume and config.list.cache_review
end

--- The directory of `root`'s, or nil without a state directory.
function M.dir(root)
  local seen = require("nemeton.seen").path()
  local base = seen and seen:match("^(.*)/[^/]+$")
  if not (base and root) then
    return nil
  end
  return ("%s/reviews/%s"):format(base, vim.fn.sha256(root):sub(1, 16))
end

local function file(root, iid)
  local dir = M.dir(root)
  return dir and ("%s/%d.json"):format(dir, iid), dir
end

--- `review` is the open review (`session.current`): what is kept is the
--- payloads it was built from (`review.raw`) and the facts that came
--- with them, which is everything `session.open` needs to build it again.
function M.write(review)
  if not (enabled() and type(review) == "table" and review.raw and review.raw.mr) then
    return
  end
  local path = file(review.root, review.iid)
  if not path then
    return
  end
  -- The reactions are keyed by note id, which JSON would have to make
  -- an array a million entries long of.
  local reactions = {}
  for id, list in pairs(review.reactions or {}) do
    table.insert(reactions, { id = id, list = list })
  end
  local data = {
    version = VERSION,
    root = review.root,
    mr = review.raw.mr,
    discussions = review.raw.discussions,
    draft_notes = review.raw.draft_notes,
    changes = review.raw.changes,
    versions = review.versions,
    me = review.me,
    reactions = reactions,
    approvals = review.approvals,
  }
  -- Written aside and moved into place (common.store). A payload JSON
  -- cannot hold is a review opened the slow way next time, which is what
  -- it was before there was a file.
  if not jsonfile.write(path, data) then
    require("nemeton.log").note("review not kept: " .. path)
  end
end

--- What `M.write` kept of `iid` in `root`, or nil. Only one that is
--- still the merge request on `branch`: a snapshot from before the
--- branch was given to another one is not this review.
function M.read(root, iid, branch)
  if not enabled() then
    return nil
  end
  local path = file(root, iid)
  local snap = jsonfile.read(path, { luanil = true })
  if
    not (snap.version == VERSION and snap.root == root)
    or type(snap.mr) ~= "table"
    or snap.mr.iid ~= iid
    or (branch and snap.mr.source_branch ~= branch)
  then
    return nil
  end
  local reactions = {}
  for _, one in ipairs(snap.reactions or {}) do
    if type(one) == "table" and one.id then
      reactions[one.id] = one.list
    end
  end
  snap.reactions = reactions
  return snap
end

--- Forgets one: a merge request merged or closed, or moved off its
--- branch, is one no editor will be started on the review of.
function M.drop(root, iid)
  local path = root and iid and file(root, iid)
  if path then
    os.remove(path)
  end
end

--- ...and every one of a repository that is gone.
function M.drop_all(root)
  local dir = M.dir(root)
  if dir and vim.uv.fs_stat(dir) then
    vim.fn.delete(dir, "rf")
  end
end

return M
