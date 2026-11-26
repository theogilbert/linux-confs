-- `health.lua`: what :checkhealth uatis can say about this repository.
local h = require("helpers")
local health = require("uatis.health")
local fixture = h.repo()

-- On the branch under review, which is where a base is asked about.
h.git("switch", "-q", "feature/math")

-- The three binaries were never the whole story: "the pane says nothing
-- changed" has as many causes in the repository as in the plugin -- no
-- base branch to be found, a fork point that IS HEAD, a `git diff` the
-- reader's own config rewrites. Gathered as data so this can check the
-- questions being asked; `vim.health` has nowhere to put an answer a
-- test can read.
describe("health.facts", function()
  it("finds the repository from a directory inside it, and what it has out", function()
    local f = health.facts(fixture)
    assert.are.equal(fixture, f.root)
    assert.are.equal("feature/math", f.head)
  end)

  it("names the base a review here would take, and its fork point", function()
    local f = health.facts(fixture)
    assert.are.equal(require("uatis.base").current(fixture) or "main", f.base)
    assert.are.equal(40, #f.fork_point)
    -- On a branch with work on it, the fork point is not HEAD.
    assert.are_not.equal(f.head_sha, f.fork_point)
  end)

  -- What the reader's own git config does to `git diff`, reported
  -- because it is the first thing to look at when a list is empty --
  -- and reported honestly, without the overrides this plugin passes on
  -- every call being read back as if the repository had asked for them.
  it("names a setting that rewrites the diff, and not uatis's own overrides", function()
    h.git("config", "diff.noprefix", "true")
    local f = health.facts(fixture)
    h.git("config", "--unset", "diff.noprefix")
    assert.are.equal("true", f.diff_config["diff.noprefix"])
    assert.is_nil(f.diff_config["core.quotepath"])
  end)

  it("has nothing to report outside a repository", function()
    assert.is_nil(health.facts(vim.fn.tempname()).root)
  end)
end)
