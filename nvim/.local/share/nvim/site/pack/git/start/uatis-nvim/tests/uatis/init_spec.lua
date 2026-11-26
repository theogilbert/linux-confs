-- `init.lua`: setup, completion, the statusline API and the global keys.
local h = require("helpers")
local uatis = require("uatis")
local config = require("uatis.config")
local view_mod = require("uatis.view")
local pane_mod = require("uatis.pane")
local fixture = h.repo()

-- On the branch under review.
h.git("switch", "-q", "feature/math")

-- mapleader is unset under `-u NONE`, so <leader> is a backslash.
local function mapping(lhs, mode)
  return vim.fn.maparg((lhs:gsub("<leader>", "\\")), mode or "n", false, true) or {}
end

-- The options a user actually writes. The merge goes INTO the live config
-- table -- every module took its reference at require time -- so this
-- section deep-copies it first and puts it back at the end: everything
-- below reads the same table.
describe("setup(opts)", function()
  local defaults = vim.deepcopy(config)

  it("takes an option that is named, and keeps the defaults beside it at every depth", function()
    uatis.setup({
      pane = { auto_open = false },
      base = { fallbacks = { "trunk" } },
      keys = { global = { toggle_diff = "<leader>zz", base_branch = false } },
    })
    assert.is_false(config.pane.auto_open)
    assert.are.equal(defaults.list.width, config.list.width)
    assert.are.equal(defaults.keys.view.hunk_next, config.keys.view.hunk_next)
    assert.are.equal(defaults.diff.line.algorithm, config.diff.line.algorithm)
  end)

  it("replaces a list rather than merging into it by index", function()
    assert.are.same({ "trunk" }, config.base.fallbacks)
  end)

  -- Merge or replace is decided by the default, not by what was written:
  -- an empty table against a list means an empty list, and against a
  -- table of settings it means none of them.
  it("empties a list given an empty table, and changes no settings with one", function()
    uatis.setup({ base = { fallbacks = {} }, keys = { view = {} } })
    assert.are.same({}, config.base.fallbacks)
    assert.are.equal(defaults.keys.view.hunk_next, config.keys.view.hunk_next)
  end)

  it("moves a global key to where it was put, and unbinds one set false", function()
    assert.is_not_nil(mapping("<leader>zz").callback)
    assert.is_nil(next(mapping(defaults.keys.global.toggle_diff)))
    assert.is_nil(next(mapping(defaults.keys.global.base_branch)))
  end)

  -- A key the defaults do not have is a typo. Accepted in silence it looks
  -- like a setting that had no effect.
  it("names a misspelt option by its path, and writes none of it", function()
    local warned = h.notes(function()
      uatis.setup({ pane = { auto_opne = true }, nonsens = 1 })
    end)
    assert.is_true(h.contains(warned, "'pane.auto_opne'"))
    assert.is_true(h.contains(warned, "'nonsens'"))
    assert.is_nil(rawget(config, "nonsens"))
    assert.is_nil(rawget(config.pane, "auto_opne"))
  end)

  it("takes down what the last call bound when the defaults come back", function()
    for k in pairs(config) do
      config[k] = nil
    end
    for k, v in pairs(defaults) do
      config[k] = v
    end
    uatis.setup()
    assert.is_not_nil(mapping(defaults.keys.global.toggle_diff).callback)
    assert.is_nil(next(mapping("<leader>zz")))
  end)
end)

-- The command line asks the same question the base prompt does, so it
-- offers the same candidates -- and, unlike the prompt, it has to answer
-- now: a completion that arrives after the reader has stopped pressing
-- <Tab> is not an answer, it is a command that does not complete.
describe("completing :Uatis", function()
  local function shas(words)
    return vim.tbl_filter(function(w) return w:match("^%x%x%x%x%x%x%x+$") end, words)
  end

  it("knows the branches and tags on the very first press, and no bare hashes", function()
    local first = uatis.complete("")
    assert.is_true(h.contains(first, "main"))
    assert.is_true(h.contains(first, "v0.1"))
    assert.are.same({}, shas(first))
  end)

  it("narrows to what a lead starts", function()
    assert.are.equal("feature/math", uatis.complete("feature/m")[1])
  end)

  -- Commits are candidates here for the reason they are in the prompt --
  -- a base is often a commit nobody has memorised -- but only for a lead
  -- that looks like a sha: the command line has no menu column to put a
  -- subject line in, and a thousand bare hashes would bury the branches.
  it("completes commits for a lead that looks like a sha", function()
    local sha = h.git("rev-parse", "--short", "HEAD")
    assert.is_true(h.contains(uatis.complete(sha:sub(1, 4)), sha))
  end)

  it("offers refs alone for an ordinary lead", function()
    local plain = uatis.complete("m")
    assert.is_true(h.contains(plain, "main"))
    assert.are.same({}, shas(plain))
  end)
end)

-- The winbar belongs to the window a review is in. A reader who wants
-- the same numbers in lualine had no way to them that did not mean
-- reaching into `view.lua`, whose field names are nobody else's to
-- depend on. These answer in plain data.
describe("what a statusline can ask for", function()
  local buf, v

  it("status() describes a buffer being compared", function()
    vim.cmd("silent! only")
    vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
    buf = vim.api.nvim_get_current_buf()
    uatis.toggle_diff()
    h.wait_for(function()
      v = view_mod.get(buf)
      local p = pane_mod.get()
      return v ~= nil and (v.renders or 0) > 0 and p ~= nil and (p.renders or 0) > 0
    end, "a review to ask about")

    local st = uatis.status(buf)
    assert.are.equal("calc.lua", st.path)
    assert.is_true(st.added > 0 and st.removed > 0)
    assert.are.equal("main", st.base)
    assert.are.equal(v.rev, st.rev)
    -- Not pinned, so it follows the base branch.
    assert.is_true(st.tracks_base)
    assert.is_true(st.backend == "struct" or st.backend == "line")
    assert.are.equal("inline", st.layout)
    assert.is_false(st.pending)
  end)

  it("review() describes the review, over every file of the branch", function()
    local rv = uatis.review()
    assert.are.equal("main", rv.base)
    assert.is_true(rv.files > 1)
    assert.is_true(rv.added >= uatis.status(buf).added)
    assert.is_true(rv.window)
  end)

  -- Which is what an outside tool has to know before it can say anything
  -- about the line under the cursor. A line this branch deleted is in no
  -- buffer but the one `<leader>go` opens.
  it("showing() calls the annotated buffer the new side", function()
    local sh = uatis.showing(buf)
    assert.are.same({ "new", "calc.lua", v.rev, v.root }, { sh.side, sh.path, sh.rev, sh.root })
  end)

  it("showing() calls the window beside it the old side", function()
    require("uatis.oldside").open(v)
    h.wait_for(function()
      return v.old and v.old.buf ~= nil and vim.api.nvim_buf_is_valid(v.old.buf)
    end, "the old side to open")
    local sh = uatis.showing(v.old.buf)
    require("uatis.oldside").close(v)
    assert.are.same({ "old", "calc.lua", v.rev }, { sh.side, sh.path, sh.rev })
  end)

  -- A structural diff is a subprocess, and a file it has not answered
  -- about yet looks exactly like a file with nothing in it: no marks, no
  -- counts, a header naming a backend as though it had spoken. Both
  -- answers say which of the two it is.
  it("says a comparison is still running, rather than naming a backend", function()
    v.pending = true
    local bar = require("uatis.ui").view_winbar_text(v, 200)
      :gsub("%%#[%w]*#", ""):gsub("%%%*", ""):gsub("%%<", "")
    local pending = uatis.status(buf).pending
    v.pending = false
    assert.matches("comparing", bar, 1, true)
    assert.is_nil(bar:find("structural", 1, true))
    assert.is_true(pending)
  end)

  -- A buffer nothing is being compared in says so by saying nothing.
  it("answers nil for a buffer with no comparison", function()
    vim.cmd("enew")
    assert.is_nil(uatis.status(vim.api.nvim_get_current_buf()))
  end)

  it("answers nil for the review once it is over", function()
    uatis.toggle_diff()
    h.wait_for(function() return pane_mod.get() == nil end, "the review to end")
    assert.is_nil(uatis.review())
  end)
end)

-- Read from the config rather than written out here: these are the
-- user's to change, and a test that hardcodes them fails for the one
-- reason that is not a bug.
describe("the global keys", function()
  uatis.setup()
  local k = config.keys.global

  -- Brackets and case taken out: a description marks its key letter,
  -- `[G]it - [L]og of ...`, and the words are what is asserted on.
  local function desc(name, mode)
    return ((mapping(k[name], mode).desc or ""):gsub("[%[%]]", ""):lower())
  end

  it("are described by what they do", function()
    assert.matches("base branch", desc("base_branch"), 1, true)
    assert.matches("diff view", desc("toggle_diff"), 1, true)
    assert.matches("project as it was", desc("at"), 1, true)
  end)

  -- What a commit did, and what has happened since one. Both global,
  -- since neither is asked from inside a review.
  it("ask about one commit, and about everything since one", function()
    assert.matches("one commit", desc("show_commit"), 1, true)
    assert.matches("since", desc("since_commit"), 1, true)
  end)

  -- ...and the third question about history: everything that ever
  -- happened to one file, or to the lines selected in it.
  it("read the history of this file, or in Visual mode of these lines", function()
    assert.matches("this file", desc("history"), 1, true)
    assert.matches("these lines", desc("history", "x"), 1, true)
  end)
end)

-- A session reset -- a new empty buffer, `only!`, every other buffer
-- deleted, the list's own among them -- leaves a review running with
-- nothing of it on screen. The key from there has to bring it back:
-- ending it changes nothing the reader can see, and they press again.
describe("toggle_diff() over a review with nothing on screen", function()
  it("shows the list again, and ends the review on the next press", function()
    vim.cmd("silent! only")
    vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
    uatis.toggle_diff()
    h.wait_for(function()
      local p = pane_mod.get()
      return p ~= nil and (p.renders or 0) > 0 and p.list_win ~= nil
    end, "a review with its list on screen")

    local old = vim.api.nvim_list_bufs()
    vim.api.nvim_win_set_buf(0, vim.api.nvim_create_buf(true, false))
    vim.cmd("silent! only!")
    for _, b in ipairs(old) do
      if vim.api.nvim_buf_is_valid(b) then
        vim.api.nvim_buf_delete(b, { force = true })
      end
    end
    local p = pane_mod.get()
    h.wait_for(function() return p.list_win == nil end, "the list to be hidden")

    assert.is_true(uatis.toggle_diff())
    assert.are.equal(p, pane_mod.get())
    assert.is_true(vim.api.nvim_win_is_valid(p.list_win))
    assert.is_true(vim.api.nvim_buf_is_valid(p.list_buf))
    assert.are.equal(p.list_buf, vim.api.nvim_win_get_buf(p.list_win))

    assert.is_false(uatis.toggle_diff())
    assert.is_nil(pane_mod.get())
  end)
end)
