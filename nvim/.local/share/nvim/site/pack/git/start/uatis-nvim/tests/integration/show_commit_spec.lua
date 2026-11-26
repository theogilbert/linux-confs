-- `:UatisShow` (one commit on its own) and `<leader>gS` (everything since one).
local h = require("helpers")
local uatis = require("uatis")
local config = require("uatis.config")
local ui = require("uatis.ui")
local view_mod = require("uatis.view")
local pane_mod = require("uatis.pane")
local fixture = h.repo()
local keys = config.keys.pane

local function sha_of(subject)
  return h.git("log", "--all", "--format=%H", "-1", "--grep=" .. subject)
end

local function edit(name)
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/" .. name))
  return vim.api.nvim_get_current_buf()
end

local function current_view()
  return view_mod.get(vim.api.nvim_get_current_buf())
end

-- `:UatisShow <rev>`, waited on until its list holds the commit's files.
local function show(rev, other_than)
  uatis.show_commit(rev)
  h.wait_for(function()
    local q = pane_mod.get()
    return q ~= nil and q ~= other_than and q.standalone and (q.renders or 0) > 0 and #q.files > 0
  end, "a review of " .. rev)
  return pane_mod.get()
end

local function wait_for_view(what)
  h.wait_for(function()
    local v = current_view()
    return v ~= nil and (v.renders or 0) > 0
  end, what)
  return current_view()
end

-- The float `open` puts up in this tab, its rows squeezed; closed after.
local function float_of(open)
  local wins = #vim.api.nvim_tabpage_list_wins(0)
  open()
  h.wait_for(function() return #vim.api.nvim_tabpage_list_wins(0) > wins end, "a float to open")
  local win = vim.api.nvim_get_current_win()
  local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
  vim.api.nvim_win_close(win, true)
  assert.are.equal(wins, #vim.api.nvim_tabpage_list_wins(0))
  return lines
end

-- The other question about history. Reading YOUR branch a commit at a
-- time is a mode inside a review of it; this is a commit that has
-- nothing to do with what you are working on, on a branch this checkout
-- is nowhere near -- and it opens in a tab of its own, because a review
-- is a mode over a tabpage and taking the one the reader is standing in
-- would end the review they already had.
describe("one commit, on its own", function()
  local home, p

  -- The branch checked out, because half of this is about a review of
  -- it running beside a review of one of its commits.
  it("opens in a tab of its own, named after the commit", function()
    h.git("switch", "-qf", "feature/math")
    vim.cmd("silent! tabonly")
    edit("stable.lua")
    home = vim.api.nvim_get_current_tabpage()
    p = show(sha_of("drop doomed, rename module"))
    assert.are.equal(2, #vim.api.nvim_list_tabpages())
    assert.is_true(p.owns_tab)
    -- For a tabline that shows names. The tab holds one commit and
    -- nothing else, and its number says nothing about which.
    assert.are.equal(p.commit.short, vim.fn.gettabvar(vim.api.nvim_tabpage_get_number(p.tab), "tabname", ""))
  end)

  it("measures the commit against its parent, and lists its own files", function()
    assert.are.equal(h.git("rev-parse", p.commit.sha .. "^"), p.rev)
    assert.are.equal(p.commit.short .. "^", p.target)
    assert.are.equal(p.commit.short, p.src)
    assert.are.equal(2, #p.files)
  end)

  -- Nothing else is ever in a tab `:UatisShow` opened: every window in
  -- it is this review, and a reader three files deep into it should not
  -- have to find the list again to press the key that means "done".
  it("lends q to the file being read, to close the commit", function()
    wait_for_view("the commit's first file, annotated")
    local mapped = vim.fn.maparg(keys.quit, "n", false, true)
    assert.are.equal(1, mapped.buffer)
    assert.matches("commit", mapped.desc, 1, true)
  end)

  -- `<sha>^ ← <sha>` is the same sha twice with a caret on one of them,
  -- and "against its parent" is the only thing `:UatisShow` ever means --
  -- so the sha alone, with the subject under it, which is what names a
  -- commit to a person. The header counts a commit against the walk it
  -- is one of, and there is no walk here: `1/1` would be a number
  -- answering nothing.
  it("heads the list with the sha and its date on one row, the subject under it", function()
    local head = vim.tbl_map(vim.trim, ui.build_list(p, 38).lines)
    assert.are.equal(1, head[1]:find(p.commit.short, 1, true))
    -- Sha, when, who on one row: that is one fact about a commit, and
    -- reading it off three rows is the reader assembling it.
    assert.matches(p.commit.date, head[1], 1, true)
    assert.are.equal("drop doomed, rename module", head[2])
    assert.is_false(h.contains(head, p.commit.short .. "^ ← " .. p.commit.short))
    assert.is_false(h.contains(head, "1/1"))
  end)

  -- The fixture's author does not fit beside the rest, and half a name
  -- on a row of its own -- or, in a walk, half a SHA -- is worse than a
  -- field that is simply not there.
  it("drops fields off that row in a narrow pane rather than wrapping it", function()
    local narrow = vim.tbl_map(vim.trim, ui.build_list(p, 30).lines)
    assert.are.equal(1, narrow[1]:find(p.commit.short, 1, true))
    assert.are.equal("drop doomed, rename module", narrow[2])
  end)

  -- One key in the header, and the key answers completely -- which is
  -- the trade: the hint used to name a third of them, taught the reader
  -- only that third, and did it on every render forever.
  it("lists this list's keys and the global ones on g?", function()
    local flat = table.concat(vim.tbl_map(function(l)
      return (vim.trim(l):gsub("%s+", " "))
    end, float_of(function() pane_mod.peek_keys(p) end)), " | ")
    assert.matches("<CR> open the file on this row", flat, 1, true)
    assert.matches(config.keys.global.toggle_diff .. " start or end", flat, 1, true)
    -- Searched by what the row SAYS, not by the bare letter: `C` is
    -- inside `<CR>` on the row above it.
    assert.is_nil(flat:find("read the branch one commit at a time", 1, true))
    assert.is_nil(flat:find("back to the whole branch", 1, true))
  end)

  -- A key that answers "there is only this one" is a key the reader
  -- spends a press to disbelieve.
  it("offers no walk to step and no branch to go back out to", function()
    local offered = h.offered(p)
    assert.is_nil(offered:find(keys.commit_view .. " ", 1, true))
    assert.is_nil(offered:find(keys.commit_prev .. " " .. keys.commit_next, 1, true))
  end)

  -- The body is the half of a message that says WHY, and a review is
  -- exactly the activity that wants it.
  it("puts the whole message a keypress away, under the sha it belongs to", function()
    assert.matches(keys.commit_message .. " its whole message", h.offered(p), 1, true)
    local said = float_of(function() pane_mod.peek_commit(p) end)
    assert.is_true(h.contains(said, "drop doomed, rename module"))
    assert.are.equal(1, vim.trim(said[1]):find(p.commit.short, 1, true))
  end)

  -- A finished commit is not the reader's buffer, whatever today's copy
  -- of the file happens to say.
  it("shows the file as it was, read-only, against the list's revision", function()
    h.wait_for(function() return vim.api.nvim_buf_get_name(0):match("^uatis://") ~= nil end,
      "the commit's first file to be opened")
    assert.is_false(vim.bo.modifiable)
    assert.are.equal(p.rev, current_view().rev)
  end)

  -- `C` would otherwise mean the commit's PARENT against the working
  -- tree, which is nobody's question.
  it("says there is only one commit when asked to walk, and stays on it", function()
    local said = h.notes(function()
      pane_mod.toggle_commits(p)
      pane_mod.step_commit(p, 1)
    end)
    assert.matches("one commit", said[1], 1, true)
    assert.matches("one commit", said[2], 1, true)
    assert.is_true(p.standalone)
    assert.is_not_nil(p.commit)
  end)

  -- `git diff <parent> <commit>` is a fact about two revisions, and
  -- neither of them is the tree -- so the watchers that keep a branch
  -- review honest are not even set up here.
  it("re-reads nothing on a write or a FocusGained", function()
    local turns = p.renders
    vim.cmd("tabnew " .. vim.fn.fnameescape(fixture .. "/stable.lua"))
    vim.cmd("silent write")
    vim.cmd("doautocmd FocusGained")
    vim.wait(300)
    vim.cmd("silent! tabclose")
    assert.are.equal(turns, p.renders)
  end)

  -- A commit whose parent is the fork point of a review running
  -- elsewhere -- the first commit of the branch -- is the case where one
  -- root and one revision describe two different readings.
  describe("beside a branch review at the same revision", function()
    local first, one, branch, two

    -- The change is what a commit is read for.
    it("opens the commit on what it did, not at the top of the file", function()
      first = sha_of("fix sub argument order and add mul")
      vim.api.nvim_set_current_tabpage(p.tab)
      one = show(first, p)
      local drawn = wait_for_view("the first commit's file to draw")
      assert.is_true(drawn.anchors[1] > 1)
      assert.are.equal(drawn.anchors[1], vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("is one root and one revision with it", function()
      pane_mod.close(p)
      vim.api.nvim_set_current_tabpage(home)
      edit("calc.lua")
      require("uatis.base").set(fixture, "main")
      uatis.toggle_diff()
      h.wait_for(function()
        local q = pane_mod.get()
        return q ~= nil and q ~= one and (q.renders or 0) > 0
      end, "a review of the branch beside it")
      branch = pane_mod.get()
      assert.are.equal(one.rev, branch.rev)
    end)

    -- There `q` is the reader's -- it records a macro -- and the list's
    -- own `q` puts the list down without ending anything.
    it("does not lend q in a tab the reader was already working in", function()
      assert.are.equal(0, vim.fn.maparg(keys.quit, "n", false, true).buffer or 0)
    end)

    it("leaves the commit's file a view of the commit's own review", function()
      vim.api.nvim_set_current_tabpage(one.tab)
      assert.is_true(current_view().standalone)
    end)

    -- From the commit's own tab it takes the tab with it.
    it("ends only the one you are standing in", function()
      local was = #vim.api.nvim_list_tabpages()
      uatis.toggle_diff()
      h.wait_for(function() return pane_mod.get(one.tab) == nil end, "the commit review to end")
      assert.are.equal(was - 1, #vim.api.nvim_list_tabpages())
      assert.is_not_nil(pane_mod.get(branch.tab))
    end)

    -- The one that would take a tab the reader is not even looking at.
    it("is left alone, tab and all, when the branch review ends", function()
      vim.api.nvim_set_current_tabpage(branch.tab)
      two = show(first)
      vim.api.nvim_set_current_tabpage(branch.tab)
      edit("calc.lua")
      h.wait_for(function() return current_view() ~= nil end, "a file of the branch review to stand in")
      uatis.toggle_diff()
      h.wait_for(function() return pane_mod.get(branch.tab) == nil end, "the branch review to end")
      assert.is_not_nil(pane_mod.get(two.tab))
      assert.is_true(vim.api.nvim_tabpage_is_valid(two.tab))
    end)

    -- Nothing else was ever in the tab, so "close this window" and
    -- "close this commit" are the same thing wherever in it the key is
    -- pressed.
    it("is ended by q from the file, which takes the tab it opened", function()
      vim.api.nvim_set_current_tabpage(two.tab)
      h.wait_for(function() return current_view() ~= nil end, "to be standing in the commit's own file")
      local tabs = #vim.api.nvim_list_tabpages()
      vim.api.nvim_feedkeys(vim.keycode(keys.quit), "x", false)
      h.wait_for(function() return pane_mod.get(two.tab) == nil end, "`q` in the file to end the commit review")
      assert.are.equal(tabs - 1, #vim.api.nvim_list_tabpages())
    end)
  end)

  -- Every line of it arrived, so it is measured against the empty tree
  -- -- and there is no `<sha>^` to name.
  it("measures a commit with no parent against nothing, and says so", function()
    edit("stable.lua")
    local root_commit = show(sha_of("initial"))
    pane_mod.close(root_commit)
    assert.are.equal("nothing", root_commit.target)
    assert.are.equal(0, root_commit.stat_removed)
    assert.is_true(root_commit.stat_added > 0)
  end)

  -- The answer is git's, said once, in a line the reader can read.
  it("says in one line that a rev names nothing, and opens no tab", function()
    local before = #vim.api.nvim_list_tabpages()
    local said = {}
    local real = vim.notify
    vim.notify = function(msg) table.insert(said, msg) end
    uatis.show_commit("no-such-revision")
    local fine = vim.wait(10000, function() return #said > 0 end, 20)
    vim.notify = real
    assert(fine, "uatis said nothing")
    assert.matches("no commit at no-such-revision", said[1], 1, true)
    assert.is_nil(said[1]:find("\n", 1, true))
    assert.are.equal(before, #vim.api.nvim_list_tabpages())
  end)

  -- `unrelated work on main` is not on the branch HEAD is sitting on.
  -- That is the usual case for the question this command answers --
  -- somebody else's commit, somewhere else.
  it("reads a commit off this branch the same way", function()
    edit("stable.lua")
    local elsewhere = show(sha_of("unrelated work on main"))
    pane_mod.close(elsewhere)
    assert.are.equal(1, #elsewhere.files)
    assert.are.equal("unrelated.lua", elsewhere.files[1].path)
  end)

  -- The command completes commits for any lead, where `:Uatis` takes
  -- them only for a hex-shaped one: here a commit is not the unusual
  -- answer, it is the whole question -- and `prompt.rank` matches a
  -- commit on its subject, which is how anyone remembers one.
  it("completes a commit by what it did", function()
    assert.is_true(h.contains(uatis.complete_show("clamp"), sha_of("add clamp helper"):sub(1, 7)))
  end)

  it("completes no list of hashes with nothing typed", function()
    for _, word in ipairs(uatis.complete_show("")) do
      assert.is_nil(word:match("^%x%x%x%x%x%x%x$"))
    end
  end)

  h.git("switch", "-qf", "main")
end)

-- The other half of the pair above, and the difference is what is being
-- measured: that one reads what a commit DID, against its parent, in a
-- tab of its own; this one is the ordinary review -- your buffers, where
-- you are standing -- pointed at a revision you picked instead of at the
-- fork point. `:Uatis <rev>` without typing the rev.
describe("everything since a revision", function()
  local buf, initial, v

  it("opens in the reader's tab, which keeps its own name", function()
    h.git("switch", "-qf", "feature/math")
    vim.cmd("silent! tabonly")
    vim.cmd("silent! only")
    buf = edit("calc.lua")
    if view_mod.get(buf) then
      view_mod.stop(view_mod.get(buf))
    end
    -- The reader's own tab, which they may already have named: a review
    -- that runs here names nothing.
    vim.t.tabname = "mine"
    initial = sha_of("initial")
    uatis.since_commit(initial)
    h.wait_for(function()
      v = view_mod.get(buf)
      local q = pane_mod.get()
      return v ~= nil and (v.renders or 0) > 0 and q ~= nil and (q.renders or 0) > 0
    end, "a review since the first commit")
    assert.are.equal("mine", vim.t.tabname)
  end)

  -- A revision named by hand was meant, so it is pinned rather than
  -- following the base branch.
  it("measures against the revision it was handed, pinned", function()
    assert.are.equal(initial, v.ref)
    assert.are.equal(initial, v.rev)
    assert.is_falsy(v.tracks_base)
  end)

  -- The whole premise. `<leader>gA` draws a finished commit in a buffer
  -- of its own; this is a review of where the tree has got to, so the
  -- new side is the file being edited.
  it("annotates the buffer the reader was in, still writable", function()
    assert.are.equal(buf, vim.api.nvim_get_current_buf())
    assert.is_true(vim.bo[buf].modifiable)
  end)

  it("lists every file changed since, as an ordinary review", function()
    local p = pane_mod.get()
    assert.is_falsy(p.standalone)
    assert.are.equal(initial, p.rev)
    assert.is_true(#p.files > 1)
  end)

  it("leaves the tab its name once it ends", function()
    uatis.toggle_diff()
    h.wait_for(function() return pane_mod.get() == nil end, "the review to end")
    assert.are.equal("mine", vim.t.tabname)
  end)

  vim.t.tabname = nil
  h.git("switch", "-qf", "main")
end)

h.release()
