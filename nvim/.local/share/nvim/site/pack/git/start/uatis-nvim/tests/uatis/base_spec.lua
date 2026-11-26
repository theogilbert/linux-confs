-- `base.lua`: what a review measures against, detected, chosen and remembered.
local h = require("helpers")
local base = require("uatis.base")
local config = require("uatis.config")
local root = h.repo()

-- On the branch under review, which is where a base is asked about.
h.git("switch", "-q", "feature/math")

local function select(name)
  return h.await(function(cb) base.select(name, cb) end, "base.select")
end

local function resolve()
  return h.await(function(cb) base.resolve(root, cb) end, "the base to resolve")
end

local function get()
  return h.await(function(cb) base.get(root, cb) end, "the base to be worked out")
end

local function back_to_main()
  base.forget(root)
  base.set(root, "main")
end

describe("the base branch", function()
  -- The fixture was `git init`ed, so there is no `origin/HEAD` to read and
  -- the conventional-name fallback is the whole answer. That is the case
  -- on every repository that was never cloned, which is most of them.
  it("is detected without being told", function()
    base.forget(root)
    assert.are.equal("main", get())
  end)

  it("sticks when set by name", function()
    select("feature/math")
    assert.are.equal("feature/math", base.current(root))
  end)

  it("refuses an unknown branch, keeping the previous choice", function()
    assert.is_nil(select("no-such-branch"))
    assert.are.equal("feature/math", base.current(root))
  end)

  -- The fixture lands a commit on main AFTER the fork. Comparing against
  -- main's TIP would drag that commit into every diff view as a change to
  -- account for, reversed -- the same failure three-dot diffing exists to
  -- avoid in the review.
  it("resolves to the branch as label and the fork point as revision", function()
    base.set(root, "main")
    local label, sha = resolve()
    assert.are.equal("main", label)
    assert.are.equal(h.git("merge-base", "main", "HEAD"), sha)
    assert.are_not.equal(h.git("rev-parse", "main"), sha)
  end)
end)

-- What the picker offers: the base in force, then `base.offer` --
-- HEAD, main or origin/main, develop or origin/develop -- where this
-- repository actually has them. Not every tag and
-- every branch -- in a repo with a hundred of either that is a list
-- nobody reads, and `vim.ui.select` may be a plain cursor list with
-- nothing to filter it by. Anything else is `:Uatis <ref>`.
describe("the base picker", function()
  local real_select, real_input = vim.ui.select, vim.ui.input
  local items, shown
  vim.ui.select = function(list, opts, on_choice)
    items = list
    shown = vim.tbl_map(opts.format_item, list)
  end
  vim.ui.input = function()
    error("the picker asks nothing by hand")
  end

  local function offer()
    items = nil
    base.select(nil, function() end)
    h.wait_for(function() return items ~= nil end, "the picker to be offered a list")
  end

  it("offers the default branch in force, and a row for everything else", function()
    base.forget(root)
    offer()
    assert.are.same({ "main  (current)", "HEAD", "type a revision..." }, shown)
  end)

  -- The fixture has no `develop` and no `master`: a short list that names
  -- branches which are not there is wrong rather than merely short.
  -- `feature/math` and both tags exist and are left out, which is the
  -- point.
  it("leaves out the conventional names this repo lacks, its tags and other branches", function()
    local names = vim.tbl_map(function(item) return item.name end, items)
    assert.are.same({ "main", "HEAD" }, names)
  end)

  -- A row of alternatives offers the first that exists and no other:
  -- `main` and `origin/main` are one branch to the reader.
  it("offers the first of a row's alternatives that this repo has", function()
    local config = require("uatis.config")
    local kept_offer = config.base.offer
    config.base.offer = { { "nope", "feature/math", "v0.1" }, { "gone", "also-gone" } }
    offer()
    config.base.offer = kept_offer
    local names = vim.tbl_map(function(item) return item.name end, items)
    assert.are.same({ "main", "feature/math" }, names)
  end)

  -- The base still need not be a branch -- a tag is the answer to "what
  -- has changed since the release". It is set by name rather than picked
  -- out of a list, and resolves like any other base.
  it("takes a tag named by hand, resolved to its fork point like a branch", function()
    select("v0.1")
    assert.are.equal("v0.1", base.current(root))
    local _, sha = resolve()
    assert.are.equal(h.git("merge-base", "v0.1", "HEAD"), sha)
  end)

  -- A base you cannot see is a base you cannot get back off.
  it("offers whatever is in force first, the default still under it", function()
    offer()
    assert.are.equal("v0.1  (current)", shown[1])
    assert.is_true(h.contains(shown, "main"))
  end)

  vim.ui.select, vim.ui.input = real_select, real_input
  back_to_main()
end)

-- Choosing a base is a fact about the project, not about this hour: a
-- repository reviewed against `develop`, or against the last release
-- tag, is that way tomorrow too. Being asked again every morning is the
-- plugin forgetting something it has already been told.
describe("a chosen base", function()
  local was = config.base.remember
  local file = vim.fn.tempname()
  config.base.remember = file

  local function kept()
    if vim.fn.filereadable(file) == 0 then
      return nil
    end
    return vim.json.decode(table.concat(vim.fn.readfile(file), "\n"))[root]
  end

  it("is in force, as a choice rather than a detection", function()
    base.forget(root)
    select("feature/math")
    assert.are.equal("feature/math", base.current(root))
    assert.are.equal("chosen", base.source(root))
  end)

  it("is written down under the repository it is about", function()
    assert.are.same({ base = "feature/math" }, kept())
  end)

  -- The subtree rides in the same entry, and the two are set apart: a
  -- base chosen after a scope must not throw the scope away.
  it("keeps a subtree beside it, the slashes taken off", function()
    base.set_dir(root, "util/")
    assert.are.equal("util", base.dir(root))
    assert.are.same({ base = "feature/math", dir = "util" }, kept())
  end)

  it("is read back, subtree and all, by a later session", function()
    base.forget(root)
    assert.are.equal("util", base.dir(root))
    assert.are.equal("feature/math", base.current(root))
  end)

  -- The whole repository is what no subtree means.
  it("writes nothing for an empty subtree", function()
    base.set_dir(root, "")
    assert.are.equal("", base.dir(root))
    assert.are.same({ base = "feature/math" }, kept())
  end)

  -- A file written before there was a subtree holds a bare string. It is
  -- read as the base rather than discarded: adding a field is no reason
  -- to make everyone choose their base branch again.
  it("reads an entry from before the subtree as the base", function()
    vim.fn.writefile({ vim.json.encode({ [root] = "v0.1" }) }, file)
    base.forget(root)
    assert.are.equal("v0.1", base.current(root))
    assert.are.equal("", base.dir(root))
  end)

  it("is reviewed against in a new session without being asked again", function()
    vim.fn.writefile({ vim.json.encode({ [root] = { base = "feature/math" } }) }, file)
    base.forget(root)
    assert.are.equal("feature/math", base.current(root))
    assert.are.equal("remembered", base.source(root))
    assert.are.equal("feature/math", get())
  end)

  -- A branch that was the base last week can have been merged and
  -- deleted since, and a base that is not there fails at the fork point,
  -- two steps from the cause.
  it("is dropped and forgotten once it no longer exists", function()
    h.git("branch", "gone-tomorrow", "main")
    base.forget(root)
    select("gone-tomorrow")
    h.git("branch", "-D", "gone-tomorrow")
    base.forget(root)
    assert.are.equal("main", get())
    assert.is_nil(kept())
  end)

  -- What was worked out from origin/HEAD or the conventional names is
  -- worked out again, since that answer can change without anyone
  -- deciding anything.
  it("is not what a detected base is: that says so and is not written down", function()
    base.forget(root)
    get()
    assert.are.equal("detected", base.source(root))
    assert.is_nil(kept())
  end)

  it("is not written down when remembering is off", function()
    config.base.remember = false
    base.forget(root)
    select("v0.1")
    assert.are.equal("v0.1", base.current(root))
    assert.is_nil(kept())
  end)

  vim.fn.delete(file)
  config.base.remember = was
  back_to_main()
end)

-- The short list is the answer you almost always want; the row under it
-- is everything else -- a tag, another branch, a hash, `HEAD~3`. It goes
-- through the plugin's own prompt rather than `vim.ui.input`, because
-- what makes that input usable is completion and `completion` is the
-- field a `vim.ui.input` replacement is free to ignore.
describe("typing a revision the picker does not offer", function()
  local prompt = require("uatis.prompt")
  local real_open, real_select = prompt.open, vim.ui.select
  local asked, answer
  prompt.open = function(opts, cb)
    asked = opts
    cb(answer)
  end
  -- The picker always picks the last row, which is the one that asks.
  vim.ui.select = function(list, _, on_choice) on_choice(list[#list]) end

  local function typed(text)
    answer = text
    return select(nil)
  end

  -- The first menu entry of each kind.
  local function menus()
    local said = {}
    for _, item in ipairs(asked.items) do
      said[item.kind] = said[item.kind] or item.menu
    end
    return said
  end

  it("makes what was typed the base", function()
    back_to_main()
    typed("feature/math")
    assert.are.equal("feature/math", base.current(root))
  end)

  -- A base is not always a name. The commit before a refactor landed has
  -- no ref pointing at it and no sha anyone has memorised, so it is
  -- offered with the subject line it is remembered by.
  it("completes every branch, the tags, and the recent commits", function()
    local words = vim.tbl_map(function(item) return item.word end, asked.items)
    assert.is_true(h.contains(words, "feature/math"))
    assert.is_true(h.contains(words, "v0.1"))
    assert.is_not_nil(menus().commit)
  end)

  -- A sha says nothing on its own, and neither does a tag nobody
  -- remembers cutting.
  it("dates each completion, and gives a commit's subject after it", function()
    local said = menus()
    assert.matches("^%d%d%d%d%-%d%d%-%d%d  %S", said.commit)
    assert.matches("^%d%d%d%d%-%d%d%-%d%d$", said.tag)
    assert.matches("^%d%d%d%d%-%d%d%-%d%d$", said.branch)
  end)

  -- The typed row is another way to say a name, not another set of
  -- rules about what a name is.
  it("refuses one git cannot resolve, as a named branch is", function()
    assert.is_nil(typed("no-such-thing"))
    assert.are.equal("feature/math", base.current(root))
  end)

  it("chooses nothing when the prompt is backed out of", function()
    assert.is_nil(typed(nil))
    assert.are.equal("feature/math", base.current(root))
  end)

  prompt.open, vim.ui.select = real_open, real_select
  back_to_main()
end)
