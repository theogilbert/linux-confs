-- One review of feature/math against main, read through from start to
-- finish: `:Uatis`, the list and its window, marking chunks read, folds,
-- spilling into the next file, the working tree and untracked files,
-- commit by commit, git moving underneath it, and the review following
-- the reader. One story rather than many files: a single pane is opened
-- early and every section after it reads that same review.
local h = require("helpers")
local uatis = require("uatis")
local overlay = require("uatis.overlay")
local view_mod = require("uatis.view")
local pane_mod = require("uatis.pane")
local ok, eq, wait_for, contains = h.ok, h.eq, h.wait_for, h.contains
local use_backend, marks = h.use_backend, h.marks
local removed, offered = h.removed, h.offered
local fixture = h.repo()
local base = require("uatis.base")

-- On the branch under review, which is where a base is asked about.
vim.fn.system({ "git", "-C", fixture, "switch", "-q", "feature/math" })
local root
base.root(function(r) root = r end)
wait_for(function() return root ~= nil end, "the repo root")

local function git_out(...)
  return vim.trim(vim.fn.system({ "git", "-C", root, ... }))
end

local view_buf, view
describe("diff view against the base branch", function()
  local stale
  it("the view names the base branch", function()
    vim.cmd("tabnew")
    -- On its own tab, and the only tab. Earlier sections leave calc.lua on
    -- screen elsewhere, and a buffer that is still visible in another window
    -- keeps its view when you edit past it -- which is right, and would make
    -- everything below depend on what happened to run before it.
    vim.cmd("silent! tabonly!")
    vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
    view_buf = vim.api.nvim_get_current_buf()
    -- Re-reading a file no longer ends the review on it -- which is the
    -- point of that, and not what this section is about. Any review an
    -- earlier one left here is stopped by hand, so what follows is about
    -- the one opened below.
    stale = view_mod.get(view_buf)
    if stale then
      view_mod.stop(stale)
    end

    uatis.toggle_diff()
    wait_for(function()
      local v = view_mod.get(view_buf)
      return v ~= nil and (v.renders or 0) > 0
    end, "a diff view against the base branch")
    view = view_mod.get(view_buf)

    eq(view.ref, "main", "the view names the base branch")
    eq(view.rev, git_out("merge-base", "main", "HEAD"), "and measures against the fork point")
    ok(view.added > 0 and view.removed > 0, "and finds the branch's changes")
    ok(vim.bo[view_buf].buftype == "" and vim.bo[view_buf].modifiable,
      "the buffer stays your own file")
  end)

  -- The list comes up with it: "what have I changed" is a question about
  -- the branch and not about one file, and the answer to "which file
  -- next" should be on screen before you ask for it.
  it("turning the view on puts the file list up", function()
    wait_for(function()
      local p = pane_mod.get()
      return p ~= nil and (p.renders or 0) > 0
    end, "the changed-file list to come up with the view")
    ok(pane_mod.get() ~= nil, "turning the view on puts the file list up")
    eq(vim.api.nvim_get_current_win(), vim.fn.win_getid(),
      "without taking the cursor into it")
    ok(view_mod.get(vim.api.nvim_get_current_buf()) ~= nil,
      "the cursor is still in the file you were reading")
  end)

  -- ...and off, for the sections below, which test the explicit paths.
  it("closed again for the checks below", function()
    require("uatis.config").pane.auto_open = false
    pane_mod.close(pane_mod.get())
    ok(pane_mod.get() == nil, "closed again for the checks below")
  end)

end)

-- Choosing a base branch is choosing what you are comparing against, so
-- the views and the list already on screen follow it. One left measuring
-- against the branch you stopped comparing to would be answering the
-- question you stopped asking -- and a list beside a view measuring
-- something else is the disagreement this plugin exists not to have.
describe("changing the base branch moves what is open", function()
  local list, code_win, k, named_buf, named, named_rev, renders
  local function layout()
    local m = vim.fn.maparg(k.layout, "n", false, true)
    ok(m and m.callback ~= nil, "the view binds " .. k.layout)
    if m and m.callback then
      m.callback()
    end
  end
  local function old_name()
    return vim.api.nvim_buf_get_name(view.old.buf)
  end
  -- The view from the section above is still on calc.lua, against main.
  -- Its list back, so both halves are on screen to be moved.
  it("the list is against the base branch too", function()
    pane_mod.open({ focus = false })
    wait_for(function()
      local p = pane_mod.get()
      return p ~= nil and (p.renders or 0) > 0
    end, "the list back beside the view")
    list = pane_mod.get()
    eq(list.ref, "main", "the list is against the base branch too")
    ok(#list.files > 0, "and has the branch's files in it")
  end)

  -- Side by side as well, because the old window's buffer is NAMED for
  -- the revision it holds -- and a name is a claim that has to keep up.
  it("which is named for the revision it holds", function()
    code_win = vim.api.nvim_get_current_win()
    k = require("uatis.config").keys.view
    layout()
    wait_for(function() return require("uatis.oldside").is_open(view) end,
      "the old revision in a window of its own")
    eq(old_name(), "uatis://main/calc.lua", "which is named for the revision it holds")
  end)

  -- A view pointed at a revision BY NAME, in a window of its own. It was
  -- not following the base branch and must not start now.
  it("the view names the branch just chosen", function()
    vim.cmd("vsplit " .. vim.fn.fnameescape(fixture .. "/helper.lua"))
    named_buf = vim.api.nvim_get_current_buf()
    uatis.run({ fargs = { "main" } })
    wait_for(function()
      local v = view_mod.get(named_buf)
      return v ~= nil and (v.renders or 0) > 0
    end, "a view named at a ref by hand")
    named = view_mod.get(named_buf)
    named_rev = named.rev

    renders = view.renders
    uatis.set_base_branch("feature/math")
    wait_for(function()
      return view.ref == "feature/math" and (view.renders or 0) > renders
    end, "the open view to follow the new base branch")
    eq(view.ref, "feature/math", "the view names the branch just chosen")
    -- HEAD is feature/math, so its fork point with itself is HEAD: nothing
    -- has changed since it, which is the point -- the numbers move because
    -- the comparison did.
    eq(view.rev, git_out("merge-base", "feature/math", "HEAD"),
      "and measures against the new fork point")
    ok((view.renders or 0) > renders, "and redraws rather than waiting to be asked")
  end)

  it("the list moves with it, to the same revision", function()
    wait_for(function() return list.ref == "feature/math" end,
      "the list to follow it as well")
    eq(list.rev, view.rev, "the list moves with it, to the same revision")
  end)

  it("and lists nothing changed since it", function()
    wait_for(function() return #list.files == 0 end, "the list to be re-read")
    eq(#list.files, 0, "and lists nothing changed since it")

    eq(old_name(), "uatis://feature/math/calc.lua",
      "and the old window is renamed for the revision it now holds")

    eq(named.ref, "main", "a view named at a ref by hand stays where it was put")
    eq(named.rev, named_rev, "against the revision that was named")
  end)

  -- ...and back, which is the same move in the other direction: the
  -- sections below are about the branch against main.
  it("choosing the old one back restores the old fork point", function()
    uatis.set_base_branch("main")
    wait_for(function() return view.ref == "main" and list.ref == "main" end,
      "the base branch to be put back")
    eq(view.rev, git_out("merge-base", "main", "HEAD"),
      "choosing the old one back restores the old fork point")
  end)

  it("and the list fills again", function()
    wait_for(function() return #list.files > 0 end, "the list to fill again")
    ok(#list.files > 0, "and the list fills again")
  end)

  it("closed again for the checks below", function()
    view_mod.close(named_buf)
    vim.api.nvim_set_current_win(code_win)
    layout()
    pane_mod.close(list)
    vim.cmd("silent! only")
    vim.cmd("buffer " .. view_buf)
    ok(pane_mod.get() == nil and view_mod.get(view_buf) ~= nil,
      "closed again for the checks below")
  end)

end)

-- The command and the Lua API are not two ways to one thing -- a command
-- is what you type when you already know the ref -- but they do have to
-- end in the same place.
describe(":Uatis", function()
  local buf, listed, against_main
  it(":Uatis <ref> compares against that ref", function()
    require("uatis.config").pane.auto_open = true
    vim.cmd("silent! only")
    vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
    buf = vim.api.nvim_get_current_buf()

    uatis.run({ fargs = { "main" } })
    wait_for(function()
      local v = view_mod.get(buf)
      return v ~= nil and (v.renders or 0) > 0
    end, "a view from :Uatis main")
    eq((view_mod.get(buf) or {}).ref, "main", ":Uatis <ref> compares against that ref")
  end)

  -- The list comes up here too. It is the same `on_open` the base-branch
  -- path uses, and it has to be reached by a local defined ABOVE the
  -- function that passes it -- one defined below is not a local at all,
  -- it is a nil global, and the pane silently never opens.
  it(":Uatis puts the file list up as well", function()
    wait_for(function()
      local p = pane_mod.get()
      return p ~= nil and (p.renders or 0) > 0
    end, "the file list to come up with it")
    ok(pane_mod.get() ~= nil, ":Uatis puts the file list up as well")
  end)

  it("against the ref that was named", function()
    listed = pane_mod.get()
    eq(listed.ref, "main", "against the ref that was named")
  end)

  it("listing what that ref changed", function()
    against_main = #listed.files
    ok(against_main > 0, "listing what that ref changed, got " .. against_main)
  end)

  -- Naming another revision annotates the buffer and leaves the review
  -- alone: a view pointed by hand is meant to sit beside a list
  -- measuring something else, which is what the base-branch section
  -- above relies on.
  it("while the list stays where it", function()
    uatis.run({ fargs = { "feature/math" } })
    wait_for(function()
      local v = view_mod.get(buf)
      return v ~= nil and v.ref == "feature/math" and (v.renders or 0) > 0
    end, "the view to go to the ref that was named")
    eq(pane_mod.get().ref, "main", "while the list stays where it was")
  end)

  -- `since_commit` is not that: "everything since" is about the review,
  -- and a list left on the first revision annotated every other file
  -- there, the second request looking as though it had done nothing.
  it("the list names the revision asked for since", function()
    uatis.since_commit("main")
    wait_for(function()
      local p = pane_mod.get()
      local v = view_mod.get(buf)
      return p ~= nil and v ~= nil and v.ref == "main" and p.rev == v.rev
        and (p.renders or 0) > 0
    end, "the list to follow a review-wide revision")
    eq(pane_mod.get().ref, "main", "the list names the revision asked for since")
  end)

  it("since_commit re-points the view as well", function()
    uatis.since_commit("feature/math")
    wait_for(function()
      local p = pane_mod.get()
      return p ~= nil and p.ref == "feature/math" and (p.renders or 0) > 0
    end, "the list to follow the second revision asked for since")
    eq(view_mod.get(buf).ref, "feature/math", "with the view")
  end)

  -- Back to a list on main beside a view on feature/math, for what follows.
  it("the list goes where the view went", function()
    uatis.since_commit("main")
    wait_for(function()
      local p = pane_mod.get()
      return p ~= nil and p.ref == "main" and (p.renders or 0) > 0
    end, "the list back on main")
    uatis.run({ fargs = { "feature/math" } })
    wait_for(function()
      local v = view_mod.get(buf)
      return v ~= nil and v.ref == "feature/math" and (v.renders or 0) > 0
    end, "the view back on feature/math")

    -- ...but asking for the list FROM that buffer re-reads it there. The
    -- list and the view under the cursor have to agree -- that is what
    -- `with_list` is for -- and taking the window away and putting it back
    -- is exactly what a reader does when the pane looks stale beside a
    -- buffer full of marks.
    pane_mod.hide(pane_mod.get())
    pane_mod.open({ focus = false })
    wait_for(function()
      local p = pane_mod.get()
      return p ~= nil and p.ref == "feature/math" and (p.renders or 0) > 0
    end, "the list to be re-read where the cursor is")
    eq(pane_mod.get().ref, "feature/math", "the list goes where the view went")
    eq(#pane_mod.get().files, 0,
      "and says what THAT revision changed -- here, nothing")
    -- `feature/math ← feature/math` and not `← working tree`: the fixture
    -- is checked out on that branch with nothing edited, so the new side
    -- of the comparison IS the branch and the header names it.
    eq(vim.trim(vim.api.nvim_buf_get_lines(pane_mod.get().list_buf, 0, 1, false)[1]),
      "feature/math ← feature/math", "with the header saying so")
  end)

  -- Put back, so what follows is a view and a list against main.
  uatis.run({ fargs = { "main" } })
  wait_for(function()
    local v = view_mod.get(buf)
    return v ~= nil and v.ref == "main"
  end, "the view back against main")

  -- The view stays: what follows is about a pane opened over one. Only
  -- the automatic opening goes, since those sections test the key.
  require("uatis.config").pane.auto_open = false
  pane_mod.close(pane_mod.get())
end)

-- What a review is made of, one commit at a time: the list a reader
-- steps through, and what each of those commits did on its own.
describe("the commits of a review", function()
  local git, patch, fork, commits, subjects, newest, text, touched, scratch_path, disk, again
  it("the branch's own commits are listed", function()
    git = require("uatis.git")
    patch = require("uatis.patch")
    fork = vim.trim(vim.fn.system({ "git", "-C", fixture, "merge-base", "main", "HEAD" }))

    git.commits_between(fixture, fork, "HEAD", function(list) commits = list end)
    wait_for(function() return commits ~= nil end, "the commits of the branch")
    ok(#commits >= 3, "the branch's own commits are listed, got " .. #commits)
  end)

  -- Oldest first: that is the order the work happened in, and the order
  -- `12/17` has to count in for the number to mean anything.
  it("oldest first", function()
    subjects = vim.tbl_map(function(c) return c.subject end, commits)
    eq(subjects[1], "fix sub argument order and add mul", "oldest first")
    eq(subjects[#subjects], "document clamp", "newest last")
  end)

  it("each carries a short sha", function()
    newest = commits[#commits]
    ok(newest.short ~= nil and #newest.short >= 7, "each carries a short sha, got "
      .. tostring(newest.short))
    ok(newest.date:match("^%d%d%d%d%-%d%d%-%d%d$") ~= nil,
      "the date it was made, got " .. tostring(newest.date))
    ok(newest.author ~= nil and newest.author ~= "", "and who made it, got "
      .. tostring(newest.author))
  end)

  -- ...and what one commit did, which is a range and not a comparison
  -- against the working tree: a commit is finished, and what it changed
  -- cannot depend on what is unsaved now.
  it("one commit's diff names only the files it touched", function()
    git.diff_range(fixture, newest.sha .. "^", newest.sha, function(out) text = out end)
    wait_for(function() return text ~= nil end, "the newest commit's own diff")
    touched = vim.tbl_map(function(f) return f.path end, patch.parse(text))
    eq(touched, { "helper.lua" }, "one commit's diff names only the files it touched")
  end)

  -- An unsaved edit is invisible to it, unlike the review's own list.
  it("and says the same thing while the tree moves under it", function()
    scratch_path = fixture .. "/helper.lua"
    disk = vim.fn.readfile(scratch_path)
    vim.fn.writefile(vim.list_extend({ "-- not part of any commit" }, vim.deepcopy(disk)),
      scratch_path)
    git.diff_range(fixture, newest.sha .. "^", newest.sha, function(out) again = out end)
    wait_for(function() return again ~= nil end, "the same commit read again")
    eq(again, text, "and says the same thing while the tree moves under it")
  end)

  vim.fn.writefile(disk, scratch_path)
end)

local pane
describe("the side pane", function()
  local k, mapped, before_wins, listed, lines, step, was
  local function press()
    if step and step.callback then
      step.callback()
    end
  end

  -- ]f with no list reads one, and puts no window up for it: the key
  -- asked which file comes next, not for somewhere to stand and look at a
  -- list. The list and the window onto it are separate things.
  it("the view binds", function()
    k = require("uatis.config").keys.view
    do
      local was_win = vim.api.nvim_get_current_win()
      local was_wins = #vim.api.nvim_tabpage_list_wins(0)
      local step = vim.fn.maparg(k.file_next, "n", false, true)
      ok(step and step.callback ~= nil and pane_mod.get() == nil,
        "]f is bound, and there is no list yet")
      if step and step.callback then
        step.callback()
      end
      wait_for(function()
        local p = pane_mod.get()
        return p ~= nil and (p.renders or 0) > 0
      end, "the list to be read")
      ok(pane_mod.get() ~= nil, "which reads one rather than refusing")
      eq(#vim.api.nvim_tabpage_list_wins(0), was_wins, "with no window put up for it")
      ok(pane_mod.get().list_win == nil, "the list has no window of its own")
      eq(vim.api.nvim_get_current_win(), was_win, "and the cursor stays where it was")
      pane_mod.close(pane_mod.get())
      ok(pane_mod.get() == nil, "closed again for the checks below")

      -- That press moved the list AND opened what it landed on, so put the
      -- file back: everything below is about a pane opened while reading
      -- calc.lua.
      vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
      -- Re-reading the file leaves a review on it running, so a view from
      -- an earlier section is stopped rather than waited past: `renders`
      -- is already above zero on that one, and waiting on it would go
      -- through before the revision below had been resolved.
      if view_mod.get(vim.api.nvim_get_current_buf()) then
        view_mod.stop(view_mod.get(vim.api.nvim_get_current_buf()))
      end
      view_mod.open("main", { resolve = require("uatis.base").resolve })
      wait_for(function()
        local v = view_mod.get(vim.api.nvim_get_current_buf())
        return v ~= nil and (v.renders or 0) > 0
      end, "the view back on calc.lua")
    end

    -- Opened from the view's own key, since that is where a reader reaches
    -- for it: the pane lists what changed since the revision the view is
    -- measured against, so it means nothing until one is open.
    mapped = vim.fn.maparg(k.files, "n", false, true)
    ok(mapped and mapped.callback ~= nil, "the view binds " .. k.files)
  end)

  it("and one in this buffer, a pane", function()
    before_wins = #vim.api.nvim_tabpage_list_wins(0)
    if mapped and mapped.callback then
      mapped.callback()
    end
    pane = pane_mod.get()
    ok(pane ~= nil, "and one in this buffer, a pane")
  end)

  it("which is one new window", function()
    wait_for(function() return (pane.renders or 0) > 0 end, "the pane to fill")

    eq(#vim.api.nvim_tabpage_list_wins(0), before_wins + 1, "which is one new window")
  end)

  it("and opening it again does not stack", function()
    pane_mod.open()
    eq(#vim.api.nvim_tabpage_list_wins(0), before_wins + 1, "and opening it again does not stack")
  end)

  it("every file the branch touched, in path order", function()
    listed = vim.tbl_map(function(f) return f.status .. " " .. f.path end, pane.files)
    eq(listed, {
      "M calc.lua",
      "D doomed.lua",
      "A helper.lua",
      "R renamed_to.lua",
      "A util/strings.lua",
    }, "every file the branch touched, in path order")
  end)

  it("the header names what is being compared", function()
    lines = vim.api.nvim_buf_get_lines(pane.list_buf, 0, -1, false)
    ok(vim.trim(lines[1]) == "main ← feature/math",
      "the header names what is being compared, got: " .. vim.trim(lines[1] or ""))
    ok(vim.trim(lines[#lines - 1] or ""):find(require("uatis.config").keys.pane.help, 1, true)
      ~= nil or contains(vim.tbl_map(vim.trim, lines), "g? keys"),
      "the header offers one key for the rest, got " .. table.concat(lines, " | "))
    ok(offered(pane):find("<CR> open the file on this row", 1, true) ~= nil,
      "and that key lists the ones this pane actually has, got " .. offered(pane))
  end)

  -- ...and what it names on the right depends on whether the tree is
  -- still the branch. One unwritten character and it is not: the new
  -- side is the live buffer, git reads the disk, and a header that went
  -- on saying `feature/math` would be naming a revision that does not
  -- contain what is on screen.
  it("the pane opens on the file you were reading", function()
    do
      -- The list's own window has the cursor by now, and its buffer is
      -- not modifiable. What has to be dirtied is the file.
      local buf = vim.fn.bufnr(fixture .. "/calc.lua")
      local was = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "-- typed, not written" })
      local seen = pane.renders or 0
      pane_mod.refresh(pane)
      wait_for(function() return (pane.renders or 0) > seen end, "the list to re-read")
      eq(vim.trim(vim.api.nvim_buf_get_lines(pane.list_buf, 0, 1, false)[1]),
        "main ← working tree", "an unsaved edit puts the working tree back in the header")

      vim.api.nvim_buf_set_lines(buf, 0, -1, false, was)
      vim.bo[buf].modified = false
      seen = pane.renders or 0
      pane_mod.refresh(pane)
      wait_for(function() return (pane.renders or 0) > seen end, "the list to re-read again")
      eq(vim.trim(vim.api.nvim_buf_get_lines(pane.list_buf, 0, 1, false)[1]),
        "main ← feature/math", "and taking it back out names the branch again")
    end

    eq(pane.file_idx, 1, "the pane opens on the file you were reading")
  end)

  -- A review can be about part of the tree rather than all of it. The
  -- list then counts only what is under there, says so in the header,
  -- and draws every path relative to it -- a column of rows all
  -- beginning `util/` spends the pane's width saying nothing.
  it("the view binds", function()
    do
      local base_mod = require("uatis.base")
      local ui = require("uatis.ui")
      local root = pane.root
      local was = base_mod.dir(root)

      base_mod.set_dir(root, "util")
      pane_mod.rescope(root, "util")
      eq(vim.tbl_map(function(f) return f.path end, pane_mod.get().files),
        { "util/strings.lua" }, "the list is only what is under the subtree")
      eq(vim.tbl_map(function(f) return ui.shown(f) end, pane_mod.get().files),
        { "strings.lua" }, "drawn relative to it")

      local scoped_lines = vim.api.nvim_buf_get_lines(pane.list_buf, 0, -1, false)
      eq(vim.trim(scoped_lines[2] or ""), "util/",
        "with the header saying how much of the tree this is")
      local squashed = vim.tbl_map(function(l)
        return (vim.trim(l):gsub("%s+", " "))
      end, scoped_lines)
      ok(contains(squashed, "A strings.lua +7 -0"),
        "and the row itself carrying the short path, got " .. vim.inspect(squashed))

      -- No git call is needed to take it off again: which files the branch
      -- touched has not changed, only how much of the answer is being read.
      base_mod.set_dir(root, was)
      pane_mod.rescope(root, was)
      eq(#pane_mod.get().files, 5, "and taking the scope off brings the rest back")
      eq(vim.trim(vim.api.nvim_buf_get_lines(pane.list_buf, 0, 2, false)[2] or ""),
        "5 files · +21 -4", "with no subtree row left in the header, got "
          .. vim.trim(vim.api.nvim_buf_get_lines(pane.list_buf, 0, 2, false)[2] or ""))
    end

    -- ]f/[f work from the file you are READING, not only from the pane
    -- listing them: moving between changed files is one activity, and which
    -- window you happen to be in is not part of it.
    vim.api.nvim_set_current_win(pane.code_win)
    step = vim.fn.maparg(k.file_next, "n", false, true)
    ok(step and step.callback ~= nil, "the view binds " .. k.file_next)
  end)

  it("the list moves on", function()
    was = vim.api.nvim_buf_get_name(0)
    -- Next along is `doomed.lua`, which the branch deleted. It opens too --
    -- as the revision that had it, with nothing opposite -- so the window
    -- changes even though there is no file on disk to edit.
    press()
    eq(pane.file_idx, 2, "the list moves on")
    ok(vim.api.nvim_buf_get_name(0) ~= was
      and vim.api.nvim_buf_get_name(0):find("doomed.lua", 1, true) ~= nil,
      "and a file the branch deleted opens as what it was, got "
        .. vim.api.nvim_buf_get_name(0))
  end)

  it("the next press steps to the third file", function()
    press()
    eq(pane.file_idx, 3, "and again")
    ok(vim.api.nvim_buf_get_name(0):find("helper.lua", 1, true) ~= nil,
      "which opens the next changed file, got " .. vim.api.nvim_buf_get_name(0))
    ok(vim.api.nvim_get_current_win() == pane.code_win,
      "in the window you were reading in, not in the pane")
  end)

  wait_for(function()
    local v = view_mod.get(vim.api.nvim_get_current_buf())
    return v ~= nil and (v.renders or 0) > 0
  end, "the file opened from your own buffer to be annotated too")
end)

-- Pressing `<CR>` moves the row AND re-reads the list -- the file is read
-- off disk, and that is git's answer going stale for all the pane knows.
-- Which file to keep the row on used to be settled when the read was
-- REQUESTED, and the request goes out mid-way through opening the file,
-- at a moment when the row is still on the buffer the code window is
-- being entered with. Two subprocesses later it landed and put the row
-- back there -- so `]f` off a file just opened by hand stepped from the
-- file before it, and `[f` and `]c`'s spill into the next file, which
-- step from the same row, were out by one with it.
describe("a file opened from the list", function()
  local target, line, select, seen, step
  local function index_of(path)
    for i, f in ipairs(pane.files) do
      if f.path == path then
        return i
      end
    end
  end
  it("a row to open that is not the file already being read", function()
    target = index_of("renamed_to.lua")
    ok(target ~= nil and pane.file_idx ~= target,
      "a row to open that is not the file already being read")
  end)

  it("the list binds <CR>", function()
    for l, idx in pairs(pane.list_rows or {}) do
      if idx == target then
        line = l
      end
    end
    vim.api.nvim_set_current_win(pane.list_win)
    vim.api.nvim_win_set_cursor(pane.list_win, { line, 0 })
    select = vim.fn.maparg(require("uatis.config").keys.pane.select,
      "n", false, true)
    ok(select and select.callback ~= nil, "the list binds <CR>")
  end)

  it("which opens the file on that row", function()
    seen = pane.renders or 0
    select.callback()
    ok(vim.api.nvim_buf_get_name(0):find("renamed_to.lua", 1, true) ~= nil,
      "which opens the file on that row, got " .. vim.api.nvim_buf_get_name(0))
  end)

  it("and the row it landed on is the file just opened", function()
    wait_for(function() return (pane.renders or 0) > seen end,
      "the re-read that opening it set off")
    eq(pane.file_idx, target, "and the row it landed on is the file just opened")
  end)

  it("so `]f` steps from there", function()
    step = vim.fn.maparg(require("uatis.config").keys.view.file_next,
      "n", false, true)
    if step and step.callback then
      step.callback()
    end
    eq(pane.file_idx, target + 1, "so `]f` steps from there")
    ok(vim.api.nvim_buf_get_name(0):find("util/strings.lua", 1, true) ~= nil,
      "into the file after it, got " .. vim.api.nvim_buf_get_name(0))
  end)

end)

-- The rows are drawn to a width, and the width a reader gives the window
-- is the one they mean. Drawn to `config.list.width` whatever the window
-- had, a pane dragged wider went on cutting the same paths off at the
-- same column with empty space beside them -- and one dragged narrower
-- drew its rows past its own edge, where nvim simply stops showing them.
describe("the pane resized", function()
  local full, cut
  local function rows()
    return vim.tbl_map(vim.trim,
      vim.api.nvim_buf_get_lines(pane.list_buf, 0, -1, false))
  end
  it("a path drawn in full at the width it opened at", function()
    full = rows()
    ok(contains(full, "A strings.lua"), "a path drawn in full at the width it opened at")
  end)

  it("a narrowed pane redraws to the width it now has", function()
    vim.api.nvim_win_call(pane.list_win, function() vim.cmd("vertical resize 16") end)
    -- Fired by hand: `WinResized` comes from nvim's main loop, which a
    -- headless `-l` script never reaches. What is under test is that the
    -- pane listens for it and redraws to the window it actually has.
    vim.api.nvim_exec_autocmds("WinResized", { group = pane.augroup })
    eq(pane.list_width, 16, "a narrowed pane redraws to the width it now has")
  end)

  it("with every row inside it", function()
    cut = rows()
    ok(not contains(cut, "A strings.lua")
      and #(cut[1] or "") <= 16 and #(cut[#cut] or "") <= 16,
      "with every row inside it, got " .. vim.inspect(cut))
  end)

  it("and widening it again redraws too", function()
    vim.api.nvim_win_call(pane.list_win, function()
      vim.cmd("vertical resize " .. require("uatis.config").list.width)
    end)
    vim.api.nvim_exec_autocmds("WinResized", { group = pane.augroup })
    eq(pane.list_width, require("uatis.config").list.width,
      "and widening it again redraws too")
    eq(rows(), full, "with the paths it had been cutting off back in full")
  end)

end)

-- A review is finished a chunk at a time, and which chunks are behind
-- you is not something the plugin can work out from where the cursor
-- is: arriving at a change is not having read it. So `]c` marks the
-- chunk it moves AWAY from, and a file is read when every chunk of it
-- is -- the whole row going green then, status letter and churn with
-- it, those being how you decide what to open next and there being
-- nothing left to decide.
describe("marking a chunk read", function()
  local ui, read, filelist, cfg, list_ns, calc, key, m, was_fp
  local function index_of(path)
    for i, f in ipairs(pane.files) do
      if f.path == path then
        return i
      end
    end
  end
  local function file(path)
    return pane.files[index_of(path)]
  end
  --- The highlight groups drawn on the row for `path`.
  local function groups(path)
    local line
    for l, idx in pairs(pane.list_rows or {}) do
      if pane.files[idx].path == path then
        line = l - 1
      end
    end
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(pane.list_buf, list_ns,
      { line, 0 }, { line, -1 }, { details = true })) do
      table.insert(out, m[4].hl_group)
    end
    return out
  end
  --- How many of `path`'s chunks are read, and how many it has.
  local function chunks_read(path)
    local f, n, of = file(path), 0, 0
    for _, c in ipairs(f.chunks) do
      of = of + 1
      if read.chunk_read(pane, f, c) then
        n = n + 1
      end
    end
    return n, of
  end

  --- Presses it on the row for `path`.
  local function press(path)
    local line
    for l, idx in pairs(pane.list_rows or {}) do
      if pane.files[idx].path == path then
        line = l
      end
    end
    vim.api.nvim_set_current_win(pane.list_win)
    vim.api.nvim_win_set_cursor(pane.list_win, { line, 0 })
    m.callback()
  end

  it("calc.lua's change is two chunks", function()
    ui = require("uatis.ui")
    read = require("uatis.read")
    filelist = require("uatis.filelist")
    cfg = require("uatis.config")
    list_ns = vim.api.nvim_create_namespace("uatis_list")

    -- The chunks are git's: one per hunk of the diff, with its own delta.
    -- calc.lua was changed in two places far enough apart to be two.
    calc = file("calc.lua")
    eq(#calc.chunks, 2, "calc.lua's change is two chunks")
    eq(calc.chunks[1].added + calc.chunks[2].added, calc.added,
      "which between them are the file's delta")
    ok(calc.chunks[1].fp ~= calc.chunks[2].fp and #calc.chunks[1].fp == 64,
      "each with a fingerprint of its own content")
    eq(#file("doomed.lua").chunks, 1, "a deleted file is one chunk")
    eq(#file("renamed_to.lua").chunks, 1,
      "and a file git reported no hunks for is one chunk covering all of it")
  end)

  -- Bound in the list, so it is read from inside it: a bare `x` in
  -- somebody else's file is a real key, and this one is never lent there.
  it("the list binds", function()
    vim.api.nvim_set_current_win(pane.list_win)
    key = cfg.keys.pane.mark_read
    m = vim.fn.maparg(key, "n", false, true)
    ok(m and m.callback ~= nil and m.buffer == 1,
      "the list binds " .. key .. ", and to its own buffer")
    ok(not contains(groups("calc.lua"), "UatisRead"),
      "a file nobody has said anything about is drawn as any other")
    -- The cursor stays on the row that was pressed, which is not the
    -- current file's: the reader is about to press `j` to the next one.
    ok(index_of("calc.lua") ~= pane.file_idx, "calc.lua is not the file being read")
  end)

  it("and the list's cursor stays on the row pressed, not the current file's", function()
    press("calc.lua")
    eq((pane.list_rows or {})[vim.api.nvim_win_get_cursor(pane.list_win)[1]], index_of("calc.lua"),
      "and the list's cursor stays on the row pressed, not the current file's")
    eq({ chunks_read("calc.lua") }, { 2, 2 }, "`x` marks every chunk of the file read")
    ok(read.is_read(pane, calc), "which is what a read file is")
    eq(groups("calc.lua"), { "UatisRead", "UatisStatAdd", "UatisStatDel" },
      "letter and name in the read colour, the churn in its own -- a column of counts "
        .. "that went green whenever a row did could not be read down")
  end)

  it("and again takes them all back off", function()
    press("calc.lua")
    eq({ chunks_read("calc.lua") }, { 0, 2 }, "and again takes them all back off")
    ok(contains(groups("calc.lua"), "UatisStatusM"),
      "with the row drawn as it was, got " .. vim.inspect(groups("calc.lua")))
  end)

  -- Half read is not read, and `x` on it completes rather than inverts:
  -- one press finishes a file with a chunk to go, the next takes the
  -- whole of it back.
  it("one chunk of two read is a file not yet read, and drawn so", function()
    read.mark(pane, calc, { calc.chunks[1] }, true)
    filelist.render(pane)
    ok(not read.is_read(pane, calc) and not contains(groups("calc.lua"), "UatisRead"),
      "one chunk of two read is a file not yet read, and drawn so")
  end)

  it("`x` on it finishes it", function()
    press("calc.lua")
    eq({ chunks_read("calc.lua") }, { 2, 2 }, "`x` on it finishes it")
  end)

  it("and only then takes it back", function()
    press("calc.lua")
    eq({ chunks_read("calc.lua") }, { 0, 2 }, "and only then takes it back")
  end)

  -- A mark is on the chunk's CONTENT. A commit that rewrites one chunk
  -- of a file -- which is what a changed fingerprint is -- resets that
  -- chunk and leaves the other read; and a chunk edited back to what it
  -- was is the chunk that was read.
  it("a chunk whose content moved stops being read, and the one beside it does not", function()
    press("calc.lua")
    was_fp = calc.chunks[2].fp
    calc.chunks[2].fp = "0000"
    ok(read.chunk_read(pane, calc, calc.chunks[1]) and not read.chunk_read(pane, calc, calc.chunks[2]),
      "a chunk whose content moved stops being read, and the one beside it does not")
    ok(not read.is_read(pane, calc), "so the file is not read")
  end)

  it("and is again when the chunk is back", function()
    calc.chunks[2].fp = was_fp
    ok(read.is_read(pane, calc), "and is again when the chunk is back")
  end)

  it("and binds it in Visual mode too", function()
    press("calc.lua")

    -- Over a selection, the rows are one set and one decision: a
    -- directory and a file inside it both selected is that file once, not
    -- that file twice and flipped back to where it began.
    do
      local function line_of(path, dir)
        for l, v in pairs(dir and pane.list_dirs or pane.list_rows) do
          if (dir and v == path) or (not dir and pane.files[v].path == path) then
            return l
          end
        end
      end
      vim.api.nvim_set_current_win(pane.list_win)
      local vm = vim.fn.maparg(key, "x", false, true)
      ok(vm and vm.callback ~= nil and vm.buffer == 1, "and binds it in Visual mode too")
      -- From the `util/` row down over the file inside it: both name
      -- strings.lua.
      vim.api.nvim_win_set_cursor(pane.list_win, { line_of("util", true), 0 })
      vim.cmd("normal! V")
      vim.api.nvim_win_set_cursor(pane.list_win, { line_of("util/strings.lua"), 0 })
      eq(vim.fn.mode(), "V", "a selection is on")
      vm.callback()
      eq(vim.fn.mode(), "n", "which the key leaves, as a key acting on one does")
      ok(read.is_read(pane, file("util/strings.lua")),
        "a directory and the file under it, both selected, is that file read once")
      vm = vim.fn.maparg(key, "x", false, true)
      -- ...and across files: everything in the range, decided as one.
      vim.api.nvim_win_set_cursor(pane.list_win, { line_of("calc.lua"), 0 })
      vim.cmd("normal! V")
      vim.api.nvim_win_set_cursor(pane.list_win, { line_of("util/strings.lua"), 0 })
      vm.callback()
      local all = true
      for _, f in ipairs(pane.files) do
        all = all and read.is_read(pane, f)
      end
      ok(all, "every row of a selection with something unread in it is read afterwards")
      vim.api.nvim_win_set_cursor(pane.list_win, { line_of("calc.lua"), 0 })
      vim.cmd("normal! V")
      vim.api.nvim_win_set_cursor(pane.list_win, { line_of("util/strings.lua"), 0 })
      vm.callback()
      local none = true
      for _, f in ipairs(pane.files) do
        none = none and not read.is_read(pane, f)
      end
      ok(none, "and a selection entirely read comes off as one")
    end

    -- A directory row stands for everything under it here as everywhere
    -- else in this list, so marking one completes the lot.
    do
      local flat = {
        root = "/nowhere", read = {},
        files = {
          { path = "lua/a.lua", status = "M", added = 3, removed = 1, hunks = {} },
          { path = "lua/deep/b.lua", status = "A", added = 40, removed = 0, hunks = {} },
          { path = "other.lua", status = "M", added = 2, removed = 7, hunks = {} },
        },
      }
      local function state()
        return vim.tbl_map(function(g) return read.is_read(flat, g) end, flat.files)
      end
      pane_mod.toggle_read_dir(flat, "lua")
      eq(state(), { true, true, false },
        "a directory takes everything under it, nested included, and nothing beside it")
      flat.read["lua/a.lua"] = nil
      pane_mod.toggle_read_dir(flat, "lua")
      eq(state(), { true, true, false }, "one half-read completes rather than inverting")
      pane_mod.toggle_read_dir(flat, "lua")
      eq(state(), { false, false, false }, "and entirely read, it comes off")
    end

    -- ...and the directory row says so itself, which is what makes folding
    -- a finished directory away worth doing.
    do
      local one = { path = "lua/a.lua", status = "M", added = 3, removed = 1, hunks = {} }
      local built = ui.build_list({
        target = "main", src = "working tree", hint = "", file_idx = 0,
        stat_added = 0, stat_removed = 0, collapsed = {},
        read = { ["lua/a.lua"] = { [read.fingerprint(read.chunks(one)[1])] = true } },
        files = { one },
      }, 38)
      local dir_line
      for line in pairs(built.dirs) do
        dir_line = line
      end
      local on_dir = {}
      for _, h in ipairs(built.hls) do
        if h.line == dir_line - 1 then
          table.insert(on_dir, h.hl)
        end
      end
      eq(on_dir, { "UatisRead" }, "a directory whose every file is read is drawn read too")
    end

    -- Read rows step back from the `+N` green rather than borrowing it: a
    -- finished row is the one thing on the list the eye should be able to
    -- pass over, and it cannot if it is as loud as a count still asking
    -- to be read.
    do
      local function fg(name)
        return vim.api.nvim_get_hl(0, { name = name, link = false }).fg
      end
      local function lum(c)
        return bit.rshift(c, 16) + bit.band(bit.rshift(c, 8), 0xff) + bit.band(c, 0xff)
      end
      local bg = vim.api.nvim_get_hl(0, { name = "Normal", link = false }).bg
      if fg("UatisStatAdd") and bg then
        ok(fg("UatisRead") ~= fg("UatisStatAdd"), "a read row is not the `+N` green")
        local towards = lum(bg) < lum(fg("UatisStatAdd")) and -1 or 1
        ok((lum(fg("UatisRead")) - lum(fg("UatisStatAdd"))) * towards > 0,
          "but that green stepped back towards the background")
      else
        print("  skip the read colour: the scheme has no ground to step back to")
      end
    end

    -- Then without a key at all: a chunk motion marks the chunk it moves
    -- away from, in either direction. Arriving at a change is not having
    -- read it.
    do
      local k = cfg.keys.view
      local calc_buf
      local function open_calc()
        vim.api.nvim_set_current_win(pane.code_win)
        -- A spill has just left calc.lua behind, and the view on it ends
        -- on the NEXT tick. Opened again inside this one, the arrival
        -- finds the old view still registered and attaches nothing, and
        -- the close then lands on a buffer that is back on screen. A
        -- reader cannot press two keys in one tick; a script can.
        if calc_buf and vim.api.nvim_win_get_buf(pane.code_win) ~= calc_buf then
          wait_for(function() return view_mod.get(calc_buf) == nil end,
            "the view left behind by the spill to end")
        end
        pane_mod.goto_file(pane, index_of("calc.lua"))
        local buf = vim.api.nvim_get_current_buf()
        calc_buf = buf
        wait_for(function()
          local v = view_mod.get(buf)
          return v ~= nil and (v.renders or 0) > 0 and #(v.anchors or {}) > 0
        end, "calc.lua to be annotated")
        return view_mod.get(buf)
      end
      local function press_key(lhs)
        local km = vim.fn.maparg(lhs, "n", false, true)
        if km and km.callback then
          km.callback()
        end
      end

      pane.read = {}
      local v = open_calc()
      eq(#v.anchors, 2, "the view stops twice in calc.lua, once per chunk")
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      press_key(k.hunk_next)
      eq({ chunks_read("calc.lua") }, { 0, 2 },
        "`]c` from the top of the file onto the first change marks nothing")
      press_key(k.hunk_next)
      eq({ chunks_read("calc.lua") }, { 1, 2 }, "`]c` off it onto the second marks the first")
      ok(read.chunk_read(pane, calc, calc.chunks[1]) and not read.is_read(pane, calc),
        "the first, and the file is not read on the strength of it")
      -- The file's own header says so.
      local bar = require("uatis.ui").view_winbar_text(v, 200)
        :gsub("%%#[%w]*#", ""):gsub("%%%*", ""):gsub("%%<", "")
      ok(bar:find("1/2 read", 1, true) ~= nil, "and the header counts it, got: " .. bar)
      -- In STOPS, not in git's chunks, though the marks are on the
      -- chunks. A lone unchanged row between two changes is one node to
      -- difftastic and two chunks to git: one stop, and the header read
      -- `0/2` until a single press took it to `2/2`. The stop is read
      -- when every chunk it stands on is.
      do
        local f = { path = "x.py", chunks = {
          { fp = "a", added = 1, removed = 1, start = 27, count = 1 },
          { fp = "b", added = 2, removed = 1, start = 29, count = 2 },
        } }
        local one = { { lo = 27, hi = 30, key = "s1" } }
        local marks = { read = {} }
        eq(read.stops_read(marks, f, one), { done = 0, total = 1 },
          "one stop over two chunks is one stop")
        read.mark(marks, f, { f.chunks[1] }, true)
        eq(read.stops_read(marks, f, one), { done = 0, total = 1 },
          "half its chunks read is not the stop read")
        read.mark(marks, f, { f.chunks[2] }, true)
        eq(read.stops_read(marks, f, one), { done = 1, total = 1 },
          "all of them is")
        eq(read.stops_read(marks, f, {}), nil, "and nothing to step is nothing to count")

        -- ...and the other way round: a hundred added lines is one chunk
        -- to git and, to a backend that found blank rows inside it, five
        -- stops. Marked when the first was left, the chunk took the other
        -- four with it -- the header jumped by five on one press and
        -- stood still on the next four. A chunk is marked once every stop
        -- on it has been left; until then the stops left count on their
        -- own.
        local big = { path = "y.py", chunks = {
          { fp = "c", added = 108, removed = 0, start = 609, count = 108 },
        } }
        local five = {
          { lo = 611, hi = 640, key = "k1" }, { lo = 643, hi = 646, key = "k2" },
          { lo = 649, hi = 653, key = "k3" }, { lo = 656, hi = 699, key = "k4" },
          { lo = 702, hi = 716, key = "k5" },
        }
        local m = { read = {}, left = { ["y.py"] = {} } }
        local left = m.left["y.py"]
        eq(read.leave(left, five, 1, big, 643), {}, "leaving the first of five marks no chunk")
        eq(read.stops_read(m, big, five), { done = 1, total = 5 }, "but counts as one stop left")
        read.leave(left, five, 2, big, 649)
        read.leave(left, five, 3, big, 656)
        read.leave(left, five, 4, big, 702)
        eq(read.stops_read(m, big, five), { done = 4, total = 5 }, "four, one press each")
        -- `[c` from below onto the last stop is an arrival, not a leaving.
        eq(read.leave(left, five, 5, big, 702), {}, "arriving at the fifth from below leaves nothing")
        eq(read.stops_read(m, big, five), { done = 4, total = 5 }, "and counts nothing")
        local marked = read.leave(left, five, 5, big, nil)
        eq(#marked, 1, "leaving the fifth, with nowhere to go, marks the chunk at last")
        read.mark(m, big, marked, true)
        eq(read.stops_read(m, big, five), { done = 5, total = 5 }, "and every stop is read")
        ok(read.is_read(m, big), "which is the file read")
        -- Marked from the list instead, every stop on the chunk is read at
        -- once: the mark is the chunk's, whichever way it was made.
        local fresh = { read = {} }
        read.mark(fresh, big, big.chunks, true)
        eq(read.stops_read(fresh, big, five), { done = 5, total = 5 },
          "a chunk marked from the list reads every stop on it")
      end
      press_key(k.hunk_prev)
      eq({ chunks_read("calc.lua") }, { 2, 2 }, "`[c` back off the second marks it too")
      press_key(k.hunk_next)
      press_key(k.hunk_next)
      eq({ chunks_read("calc.lua") }, { 2, 2 },
        "and `]c` off the last change, with nowhere left to go, leaves it read")
      ok(read.is_read(pane, calc), "and the file is read")
      ok(vim.api.nvim_buf_get_name(0):find("doomed.lua", 1, true) ~= nil,
        "on the way into the next file, got " .. vim.api.nvim_buf_get_name(0))

      -- Coming in at the last chunk and leaving marks that one alone: the
      -- rest of the file was never seen.
      pane.read = {}
      v = open_calc()
      vim.api.nvim_win_set_cursor(0, { v.anchors[#v.anchors], 0 })
      press_key(k.hunk_next)
      eq({ chunks_read("calc.lua") }, { 1, 2 }, "`]c` off the last chunk alone marks that chunk")
      ok(not read.is_read(pane, calc), "and not the file")

      -- Scrolled on past a change and pressed: the change being left is
      -- the last one above the cursor.
      pane.read = {}
      v = open_calc()
      vim.api.nvim_win_set_cursor(0, { math.min(v.anchors[1] + 1, v.anchors[2] - 1), 0 })
      press_key(k.hunk_next)
      ok(read.chunk_read(pane, calc, calc.chunks[1]),
        "`]c` from below a change, before the next, marks the one above")

      -- `[c` from the same place goes back ONTO that change: arriving,
      -- not leaving, and nothing is marked.
      pane.read = {}
      v = open_calc()
      vim.api.nvim_win_set_cursor(0, { math.min(v.anchors[1] + 1, v.anchors[2] - 1), 0 })
      press_key(k.hunk_prev)
      eq({ chunks_read("calc.lua") }, { 0, 2 }, "`[c` from below a change onto it marks nothing")
      eq(vim.api.nvim_win_get_cursor(0)[1], v.anchors[1], "having landed on it")
      -- ...and `[c` off the first change, with nothing before it, marks
      -- it: leaving is leaving whichever way.
      press_key(k.hunk_prev)
      ok(read.chunk_read(pane, calc, calc.chunks[1]),
        "`[c` off the first change, with nowhere to go, marks it")

      pane.read = {}
      cfg.pane.auto_read = false
      v = open_calc()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      for _ = 1, #v.anchors + 1 do
        press_key(k.hunk_next)
      end
      eq({ chunks_read("calc.lua") }, { 0, 2 },
        "`pane.auto_read = false` leaves the marking to the reader")
      cfg.pane.auto_read = true
    end

    -- What was read is read next time: the marks go to disk as they are
    -- made, per repository, and a list built later on the same one starts
    -- with them. Only the chunks the file still has are kept -- a chunk
    -- edited out from under its mark is not coming back in that shape.
    do
      pane.read = {}
      press("calc.lua")
      read.mark(pane, file("helper.lua"), file("helper.lua").chunks, true)
      pane.read["helper.lua"]["stale:0:0"] = true
      read.save(pane.root, pane.read, { file("helper.lua") })
      local again = read.load(pane.root)
      ok(again["calc.lua"] and again["calc.lua"][read.fingerprint(calc.chunks[1])]
        and again["calc.lua"][read.fingerprint(calc.chunks[2])],
        "a file marked from the list comes back from disk")
      ok(again["helper.lua"] and again["helper.lua"][read.fingerprint(file("helper.lua").chunks[1])]
        and not again["helper.lua"]["stale:0:0"],
        "with the fingerprints its chunks have and none they no longer do")
      ok(again["doomed.lua"] == nil, "and nothing for a file never marked")

      -- `remember_read = false` keeps nothing.
      local where = cfg.pane.remember_read
      cfg.pane.remember_read = false
      eq(read.load(pane.root), {}, "and off, a new list starts with nothing")
      cfg.pane.remember_read = where
    end

    pane.read = {}
    filelist.render(pane)
  end)

end)

-- `3/20` is not an answer to "how much is left" on a branch whose third
-- file is a nine-hundred-line generated blob. The foot of the pane
-- measures the review in delta LOC -- added AND removed, a line taken out
-- being as much to read as one put in -- over the chunks that are read,
-- and carries beside it how many files are read entirely.
describe("how much of the review is behind you", function()
  local ui, read, filelist, none, calc, share, one, was_idx, all, full, part, narrow, a, flat, cfg
  local function file(path)
    for _, f in ipairs(pane.files) do
      if f.path == path then
        return f
      end
    end
  end
  --- What the pane's status line says with these chunks read:
  --- `{ path = { chunk indices } }`, or a path alone for all of it.
  local function foot(spec)
    pane.read = {}
    for path, which in pairs(spec) do
      if type(path) == "number" then
        path, which = which, nil
      end
      local f = file(path)
      local chunks = {}
      for i, c in ipairs(f.chunks) do
        if which == nil or vim.tbl_contains(which, i) then
          table.insert(chunks, c)
        end
      end
      read.mark(pane, f, chunks, true)
    end
    filelist.render(pane)
    return (vim.wo[pane.list_win].statusline:gsub("%%#%w+#", ""):gsub("%%%%", "%%"))
  end

  it("nothing read is an empty bar, and says so", function()
    ui = require("uatis.ui")
    read = require("uatis.read")
    filelist = require("uatis.filelist")

    -- calc 8, doomed 2, helper 8, renamed_to 0, strings 7 -- 25 in all.
    none = foot({})
    ok(none:find("0/5 · 0%", 1, true) ~= nil and none:find("█", 1, true) == nil,
      "nothing read is an empty bar, and says so, got " .. none)
    ok(foot({ "calc.lua" }):find("1/5 · 32%", 1, true) ~= nil,
      "one of five files is 32% of the delta and not a fifth of it, got "
        .. foot({ "calc.lua" }))
    ok(foot({ "calc.lua", "helper.lua" }):find("2/5 · 64%", 1, true) ~= nil,
      "and two of them 64%, got " .. foot({ "calc.lua", "helper.lua" }))
  end)

  -- A chunk counts on its own: one of calc.lua's two read is that
  -- chunk's share of the delta behind the reader, with no file finished.
  it("one chunk of a file read moves the bar and not the file count", function()
    calc = file("calc.lua")
    share = calc.chunks[1].added + calc.chunks[1].removed
    one = foot({ ["calc.lua"] = { 1 } })
    ok(one:find(("0/5 · %d%%"):format(math.floor(share / 25 * 100 + 0.5)), 1, true) ~= nil,
      "one chunk of a file read moves the bar and not the file count, got " .. one)
  end)

  -- The cursor is not progress: arriving at the last file of a branch is
  -- not having read the branch.
  it("standing on the last file with nothing marked is still nothing read", function()
    was_idx = pane.file_idx
    pane.file_idx = #pane.files
    ok(foot({}):find("0/5 · 0%", 1, true) ~= nil,
      "standing on the last file with nothing marked is still nothing read")
  end)

  it("and the whole review read fills it", function()
    pane.file_idx = was_idx

    all = {}
    for _, f in ipairs(pane.files) do
      table.insert(all, f.path)
    end
    full = foot(all)
    ok(full:find("5/5 · 100%", 1, true) ~= nil and full:find("░", 1, true) == nil,
      "and the whole review read fills it, got " .. full)
  end)

  it("the row is drawn to the width the window has", function()
    part = foot({ "calc.lua" })
    eq(vim.fn.strdisplaywidth(part), pane.list_width,
      "the row is drawn to the width the window has")
    ok(select(2, part:gsub("█", "")) > 0 and select(2, part:gsub("░", "")) > 0,
      "a review part read is drawn as neither nothing nor done, got " .. part)
  end)

  -- Too narrow for a bar the reader could read a proportion off, so the
  -- numbers say it alone rather than four blocks pretending to.
  it("a pane too narrow for a bar keeps the numbers", function()
    narrow = (ui.progress(pane, 14):gsub("%%#%w+#", ""):gsub("%%%%", "%%"))
    ok(narrow:find("1/5 · 32%", 1, true) ~= nil and narrow:find("█", 1, true) == nil,
      "a pane too narrow for a bar keeps the numbers, got " .. narrow)
  end)

  -- Nothing to measure but the files, which is what it then measures.
  it("a review with no delta at all is measured on its files", function()
    a = { path = "a", added = 0, removed = 0, hunks = {} }
    flat = (ui.progress({
      files = { a, { path = "b", added = 0, removed = 0, hunks = {} } },
      read = { a = { [read.fingerprint(read.chunks(a)[1])] = true } },
      stat_added = 0, stat_removed = 0,
    }, 38):gsub("%%#%w+#", ""):gsub("%%%%", "%%"))
    ok(flat:find("1/2 · 50%", 1, true) ~= nil,
      "a review with no delta at all is measured on its files, got " .. flat)
  end)

  it("and off, the window is handed back to the reader's own status line", function()
    cfg = require("uatis.config")
    cfg.list.progress = false
    foot({})
    -- Read window-locally: an empty one is what hands the window back to
    -- whatever the reader set globally, and asking for the effective value
    -- would come back with theirs.
    eq(vim.api.nvim_get_option_value("statusline", { win = pane.list_win, scope = "local" }),
      "", "and off, the window is handed back to the reader's own status line")
  end)

  cfg.list.progress = true
  foot({})
end)

-- Structural mode draws nothing for a chunk that is only formatting,
-- and `]c` never stops there -- so a file read stop by stop still had
-- a chunk nobody could mark, and its row stayed unread beside a header
-- that said every stop was. The view tells the list which chunks it
-- drew nothing for, and the list stops waiting for them for as long as
-- that is how the file is drawn.
describe("a chunk the backend hides is set aside", function()
  local read, ui, patch, path, was, f, marks, before, row, buf, v
  it("a hunk standing on both chunks hides neither", function()
    read = require("uatis.read")
    ui = require("uatis.ui")
    patch = require("uatis.patch")
    path = fixture .. "/stable.lua"
    was = vim.fn.readfile(path)

    -- The hiding itself, as data: a chunk under no hunk.
    f = { path = "x.py", chunks = {
      { fp = "a", added = 1, removed = 1, start = 27, count = 1 },
      { fp = "b", added = 2, removed = 1, start = 29, count = 2 },
    } }
    eq(read.hidden(f, { { start_b = 27, count_b = 4 } }), {},
      "a hunk standing on both chunks hides neither")
    eq(read.hidden(f, { { start_b = 27, count_b = 1 } }),
      { [read.fingerprint(f.chunks[2])] = true }, "and one standing on the first hides the second")
  end)

  it("one chunk of two read is not the file read", function()
    marks = { read = { ["x.py"] = { [read.fingerprint(f.chunks[1])] = true } } }
    ok(not read.is_read(marks, f), "one chunk of two read is not the file read")
  end)

  it("unless the other is set aside", function()
    marks.hidden = { ["x.py"] = read.hidden(f, { { start_b = 27, count_b = 1 } }) }
    ok(read.is_read(marks, f), "unless the other is set aside")
  end)

  -- ...and live. stable.lua, which the branch never touched, gains
  -- spaces between its tokens: one chunk to git, nothing to difftastic.
  it("git reports it as one chunk", function()
    vim.fn.writefile({ "return {   untouched = true   }" }, path)
    before = pane.renders or 0
    pane_mod.refresh(pane)
    wait_for(function()
      return (pane.renders or 0) > before and patch.find(pane.files, "stable.lua") ~= nil
    end, "the list to pick the reformat up")
    row = patch.find(pane.files, "stable.lua")
    eq(#(row.chunks or read.chunks(row)), 1, "git reports it as one chunk")
    ok(not read.is_read(pane, row), "unread, since nothing has set it aside yet")
  end)

  it("difftastic finds nothing in it", function()
    vim.api.nvim_set_current_win(pane.code_win)
    vim.cmd("edit! " .. vim.fn.fnameescape(path))
    buf = vim.api.nvim_get_current_buf()
    wait_for(function()
      local v = view_mod.get(buf)
      return v ~= nil and (v.renders or 0) > 0 and not v.pending
    end, "the review to follow into stable.lua")
    v = view_mod.get(buf)
    if use_backend(v, "struct") then
      wait_for(function()
        return pane.hidden and pane.hidden["stable.lua"] ~= nil
      end, "the view to set the chunk aside")
      eq(#v.hunks, 0, "difftastic finds nothing in it")
      ok(read.is_read(pane, row), "so the file is read, with no mark on it at all")
      ok(ui.read_chunks(v) == nil, "and the header counts nothing rather than 0/0")

      -- Drawn as lines, the chunk is a change again, and unread.
      use_backend(v, "line")
      wait_for(function()
        return not (pane.hidden and pane.hidden["stable.lua"])
      end, "line mode to give the chunk back")
      ok(not read.is_read(pane, row), "in line mode the same file is unread")
      use_backend(v, "struct")
    end

    view_mod.close(buf)
    vim.fn.writefile(was, path)
    before = pane.renders or 0
    pane_mod.refresh(pane)
    wait_for(function()
      return (pane.renders or 0) > before and patch.find(pane.files, "stable.lua") == nil
    end, "the list to let stable.lua go again")
    pane.hidden = nil
  end)

end)

-- A branch that touched forty files in six directories is a list you
-- scroll rather than read. Folding a directory shut is how the pane
-- gets back to the size of the question you are asking of it -- and the
-- row stays, because a fold that vanished would be a list that silently
-- lost files.
describe("folding a directory away", function()
  local ui, files, was_win, idx, fold, pk, shut, open, shut_all, open_all, was_idx, shut_dirs, file_lines
  local function shape(collapsed)
    local out = {}
    for _, r in ipairs(ui.tree_rows(files, collapsed)) do
      table.insert(out, (r.kind == "dir" and (r.collapsed and "▸" or "▾") or "·") .. r.name)
    end
    return out
  end
  local function line_of(index)
    for line, i in pairs(pane.list_rows or {}) do
      if i == index then
        return line
      end
    end
  end
  local function dir_line(path)
    for line, p in pairs(pane.list_dirs or {}) do
      if p == path then
        return line
      end
    end
  end

  it("every directory is a row of its own, with its files under it", function()
    ui = require("uatis.ui")

    -- The flattening on its own: nested directories go with their parent,
    -- and a directory that is merely deeper is not swept up by a fold
    -- above it that is open.
    files = {
      { path = "README.md" },
      { path = "lua/a.lua" },
      { path = "lua/deep/b.lua" },
      { path = "tests/run.lua" },
    }
    eq(shape(nil), { "·README.md", "▾lua", "·a.lua", "▾deep", "·b.lua", "▾tests", "·run.lua" },
      "every directory is a row of its own, with its files under it")
    eq(shape({ lua = true }),
      { "·README.md", "▸lua", "▾tests", "·run.lua" },
      "a shut directory keeps its row and takes everything below it with it")
    eq(shape({ ["lua/deep"] = true }),
      { "·README.md", "▾lua", "·a.lua", "▸deep", "▾tests", "·run.lua" },
      "shutting a nested one leaves its parent's own files on screen")
    eq(ui.dirs_of("lua/uatis/x.lua"), { "lua", "lua/uatis" },
      "and a file names every directory it is under, outermost first")
  end)

  -- Shut, a directory row stands in for every row underneath it, so it
  -- carries what they were worth: the reason you would open it.
  it("the pane draws a row for util/", function()
    do
      local counted = {
        target = "main", src = "working tree", hint = "", file_idx = 0,
        stat_added = 0, stat_removed = 0, collapsed = { ["lua/deep"] = true },
        files = {
          { path = "lua/a.lua", status = "M", added = 3, removed = 1 },
          { path = "lua/deep/b.lua", status = "A", added = 40, removed = 0 },
          { path = "lua/deep/c.lua", status = "M", added = 2, removed = 7 },
        },
      }
      local built = ui.build_list(counted, 38)
      local by_dir = {}
      for line, path in pairs(built.dirs) do
        by_dir[path] = vim.trim(built.lines[line])
      end
      ok(by_dir["lua/deep"] and by_dir["lua/deep"]:match("^▸") ~= nil
        and by_dir["lua/deep"]:match("%+42 %-7$") ~= nil,
        "a shut directory says what it is hiding, everything nested under it "
          .. "included, got " .. tostring(by_dir["lua/deep"]))
      eq(by_dir["lua"], "▾ lua/",
        "and an open one says nothing: its files are on screen with their own")

      counted.collapsed = {}
      local open_all = ui.build_list(counted, 38)
      for line, path in pairs(open_all.dirs) do
        ok(vim.trim(open_all.lines[line]):match("[+-]%d") == nil,
          path .. " carries no count once it is open, got "
            .. vim.trim(open_all.lines[line]))
      end
    end

    -- ...and in the pane, on the key that folds anything else.
    was_win = vim.api.nvim_get_current_win()
    for i, f in ipairs(pane.files) do
      if f.path == "util/strings.lua" then
        idx = i
      end
    end
    ok(idx ~= nil and dir_line("util") ~= nil, "the pane draws a row for util/")
  end)

  it("the list binds", function()
    vim.api.nvim_set_current_win(pane.list_win)
    vim.api.nvim_win_set_cursor(pane.list_win, { dir_line("util"), 0 })
    fold = vim.fn.maparg(require("uatis.config").keys.pane.fold, "n", false, true)
    ok(fold and fold.callback ~= nil, "the list binds " .. require("uatis.config").keys.pane.fold)
  end)

  it("which shuts the directory under the cursor", function()
    fold.callback()
    ok(pane.collapsed["util"] == true, "which shuts the directory under the cursor")
    ok(line_of(idx) == nil, "so the file inside it has no row")
    ok(dir_line("util") ~= nil, "while the directory itself still does")
    eq(vim.api.nvim_win_get_cursor(pane.list_win)[1], dir_line("util"),
      "with the cursor left on the row that was acted on")
  end)

  -- Over a file, the same key shuts the directory the file is IN.
  it("pressing it again opens the directory back up", function()
    fold.callback()
    ok(line_of(idx) ~= nil, "pressing it again opens the directory back up")
  end)

  it("and over a file it shuts the directory that file is in", function()
    vim.api.nvim_win_set_cursor(pane.list_win, { line_of(idx), 0 })
    fold.callback()
    ok(pane.collapsed["util"] == true and line_of(idx) == nil,
      "and over a file it shuts the directory that file is in")
  end)

  -- Arriving at a file opens the way to it: a list that could hide the
  -- row it is pointing at would be a list that disagrees with the code
  -- pane, which is the one thing redrawing it on every move prevents.
  it("walking into a folded directory opens it", function()
    pane_mod.goto_file(pane, idx)
    ok(pane.collapsed["util"] == nil, "walking into a folded directory opens it")
    ok(line_of(idx) ~= nil, "so the file you are reading always has a row")
  end)

  -- ...but only on arrival. Re-opening it on every RENDER instead made
  -- the fold that matters most into the one fold that did nothing: in a
  -- repo whose files all sit under one top-level directory, the
  -- directory you are standing in is the directory you want shut.
  it("the directory the current file is in folds like any other", function()
    vim.api.nvim_set_current_win(pane.list_win)
    vim.api.nvim_win_set_cursor(pane.list_win, { dir_line("util"), 0 })
    fold.callback()
    ok(pane.collapsed["util"] == true and line_of(idx) == nil,
      "the directory the current file is in folds like any other")
    ok(dir_line("util") ~= nil, "leaving its own row to open it again by")
  end)

  -- zc/zo say which way, so neither has to be pressed twice to find out
  -- which way it went.
  it("the list binds", function()
    pk = require("uatis.config").keys.pane
    shut = vim.fn.maparg(pk.fold_close, "n", false, true)
    open = vim.fn.maparg(pk.fold_open, "n", false, true)
    ok(shut and shut.callback ~= nil and open and open.callback ~= nil,
      "the list binds " .. pk.fold_close .. " and " .. pk.fold_open)
  end)

  it("zo opens it", function()
    vim.api.nvim_win_set_cursor(pane.list_win, { dir_line("util"), 0 })
    open.callback()
    ok(pane.collapsed["util"] == nil and line_of(idx) ~= nil, "zo opens it")
  end)

  it("and opening an open one leaves it open", function()
    open.callback()
    ok(pane.collapsed["util"] == nil, "and opening an open one leaves it open")
  end)

  it("zc shuts it", function()
    shut.callback()
    ok(pane.collapsed["util"] == true, "zc shuts it")
  end)

  it("and pressing it on a shut one does not open it back up", function()
    shut.callback()
    ok(pane.collapsed["util"] == true,
      "and pressing it on a shut one does not open it back up")
  end)

  it("the list binds", function()
    open.callback()

    -- The whole tree at once, which on a branch that touched forty files
    -- is the first thing you reach for.
    shut_all = vim.fn.maparg(pk.fold_close_all, "n", false, true)
    open_all = vim.fn.maparg(pk.fold_open_all, "n", false, true)
    ok(shut_all and shut_all.callback ~= nil and open_all and open_all.callback ~= nil,
      "the list binds " .. pk.fold_close_all .. " and " .. pk.fold_open_all)
  end)

  -- Set outright rather than walked to: which file the pane is on after
  -- an open settles is the subject of other sections, and this one is
  -- about where the cursor goes when that file's row folds away.
  it("zM leaves the outermost directories and nothing under them", function()
    was_idx = pane.file_idx
    pane.file_idx = idx
    shut_all.callback()
    shut_dirs, file_lines = {}, 0
    for _, path in pairs(pane.list_dirs or {}) do
      table.insert(shut_dirs, path)
    end
    for _ in pairs(pane.list_rows or {}) do
      file_lines = file_lines + 1
    end
    eq(shut_dirs, { "util" }, "zM leaves the outermost directories and nothing under them")
    eq(file_lines, 4, "so only the files that are in no directory keep a row")
    ok(pane.collapsed["util"] == true, "with every directory marked shut, not just the top")
    eq(vim.api.nvim_win_get_cursor(pane.list_win)[1], dir_line("util"),
      "and the cursor on the row standing in for where you were")
  end)

  it("zR opens every one of them again", function()
    open_all.callback()
    eq(next(pane.collapsed), nil, "zR opens every one of them again")
    ok(line_of(idx) ~= nil, "and every file has its row back")
  end)

  pane.file_idx = was_idx

  vim.api.nvim_set_current_win(was_win)
end)

describe("opening files from the pane", function()
  local added_buf, added_view, renamed_buf, renamed_view, bar, gone_buf, gone
  local function index_of(path)
    for i, f in ipairs(pane.files) do
      if f.path == path then
        return i
      end
    end
  end

  -- A file the branch ADDED has no blob at the fork point. Treating that
  -- as a failure made a third of a merge request unreachable from the
  -- pane; the honest answer is that all of it is new.
  it("the file opens in the window beside the pane", function()
    pane_mod.goto_file(pane, index_of("helper.lua"))
    added_buf = vim.api.nvim_get_current_buf()
    wait_for(function()
      local v = view_mod.get(added_buf)
      return v ~= nil and (v.renders or 0) > 0
    end, "a view over the added file")
    -- `or {}` so a broken open reports as failed assertions rather than
    -- taking the whole run down with a nil index.
    added_view = view_mod.get(added_buf) or {}

    ok(vim.api.nvim_buf_get_name(added_buf):find("helper.lua", 1, true) ~= nil,
      "the file opens in the window beside the pane")
    ok(added_buf ~= pane.list_buf, "and never into the pane itself")
    -- Asked of the PANE and not of some other view that happens to hold the
    -- same sha: what is being claimed is that a file opened from the list
    -- is measured against the list's own revision.
    eq(added_view.rev, pane.rev, "pinned to the same revision as the pane")
    eq(added_view.removed, 0, "an added file removes nothing")
    eq(added_view.added, #vim.api.nvim_buf_get_lines(added_buf, 0, -1, false),
      "and every one of its lines is an addition")
    -- On the tick after the window let go of it, which a render served
    -- from cache does not wait through on its own.
    ok(wait_for(function() return view_mod.get(view_buf) == nil end,
      "the view on the file left behind to end"),
      "the file you left behind gives its buffer back")
    eq(vim.wo.winbar, require("uatis.ui").VIEW_WINBAR,
      "and the window it landed in describes the file that is now in it")
  end)

  -- A path is not an identity. A file the branch renamed has no blob under
  -- its NEW name at the fork point, so a view that looked only at where the
  -- file is now would report a pure `git mv` as a brand new file. The pane
  -- has the old name, because rename detection is a property of the patch
  -- it parsed.
  it("the view is told where the file came from", function()
    pane_mod.goto_file(pane, index_of("renamed_to.lua"))
    renamed_buf = vim.api.nvim_get_current_buf()
    wait_for(function()
      local v = view_mod.get(renamed_buf)
      return v ~= nil and (v.renders or 0) > 0
    end, "a view over the renamed file")
    renamed_view = view_mod.get(renamed_buf) or {}
    eq(renamed_view.old_path, "renamed_from.lua", "the view is told where the file came from")
    eq({ renamed_view.added, renamed_view.removed }, { 0, 0 }, "so a pure rename changes nothing")
  end)

  it("and the header says where it came from", function()
    local raw = require("uatis.ui").view_winbar_text(renamed_view, 200)
    -- In the rename's colour, not greyed with the counts beside it.
    ok(raw:find("%#UatisRenamed#← renamed_from.lua", 1, true) ~= nil,
      "the old name is drawn as a rename, got:" .. raw)
    bar = raw
      :gsub("%%#[%w]*#", ""):gsub("%%%*", ""):gsub("%%<", "")
    ok(bar:find("← renamed_from.lua", 1, true) ~= nil,
      "and the header says where it came from, got:" .. bar)
  end)

  -- A file the branch DELETED has nothing in your tree to annotate, and
  -- it is the one file where "what was there" is the whole question. So
  -- the window gets an empty buffer standing for the file that is gone,
  -- and the comparison says every line of it went.
  it("a deleted file opens rather than refusing", function()
    pane_mod.goto_file(pane, index_of("doomed.lua"))
    gone_buf = vim.api.nvim_get_current_buf()
    wait_for(function()
      local v = view_mod.get(gone_buf)
      return v ~= nil and (v.renders or 0) > 0
    end, "a view over the file the branch deleted")
    gone = view_mod.get(gone_buf) or {}
    ok(gone_buf ~= renamed_buf, "a deleted file opens rather than refusing")
    eq(vim.api.nvim_buf_get_lines(gone_buf, 0, -1, false), { "" },
      "with nothing in it, because there is nothing in your tree")
    eq(gone.added, 0, "nothing was added to it")
    ok(gone.removed > 0, "and every line it had is gone, got " .. tostring(gone.removed))
    eq(gone.relpath, "doomed.lua", "the view knows which file it stands for")
    ok(not vim.bo[gone_buf].modifiable, "and the buffer is not one to type in")
  end)

end)

-- The unit being read is a branch, not a buffer. `]c` off the last chunk
-- of a file carries on into the next file the list names and lands on the
-- first change in it -- the reader was asking for the next change, and
-- there is one. Off the end of the review it says so and stays, the way
-- stepping the list does.
describe("the next change is in the next file", function()
  local k, cfg, gone_buf, calc_idx, calc_buf, calc, last, said, real_notify, last_idx, tail_buf, tail, tail_last, held_buf
  local function index_of(path)
    for i, f in ipairs(pane.files) do
      if f.path == path then
        return i
      end
    end
  end

  local function press(lhs)
    local m = vim.fn.maparg(lhs, "n", false, true)
    if m and m.callback then
      m.callback()
      return true
    end
    return false
  end

  local function opened(path)
    pane_mod.goto_file(pane, index_of(path))
    local buf = vim.api.nvim_get_current_buf()
    wait_for(function()
      local v = view_mod.get(buf)
      return v ~= nil and v.relpath == path and (v.renders or 0) > 0
    end, "a view over " .. path)
    return buf, view_mod.get(buf) or {}
  end

  it("the file before the deleted one is the modified one", function()
    k = require("uatis.config").keys.view
    cfg = require("uatis.config")

    -- Backwards first, because it is the direction with something to
    -- assert: the last chunk of the file before is a line partway down it,
    -- and landing at the top would be indistinguishable from having gone
    -- nowhere.
    gone_buf = opened("doomed.lua")
    calc_idx = index_of("calc.lua")
    ok(calc_idx == index_of("doomed.lua") - 1,
      "the file before the deleted one is the modified one")
  end)

  it("[c is bound in the file it is pressed in", function()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    ok(press(k.hunk_prev), "[c is bound in the file it is pressed in")
  end)

  it("which has more than one chunk in it", function()
    wait_for(function()
      local b = vim.api.nvim_get_current_buf()
      local v = view_mod.get(b)
      return b ~= gone_buf and v ~= nil and v.relpath == "calc.lua"
        and (v.renders or 0) > 0
    end, "[c off the top of a file to open the one before it")
    calc_buf = vim.api.nvim_get_current_buf()
    calc = view_mod.get(calc_buf) or {}
    last = (calc.anchors or {})[#(calc.anchors or {})]
    ok(last ~= nil and last > 1, "which has more than one chunk in it, got "
      .. vim.inspect(calc.anchors))
  end)

  it("and `[c` lands on the LAST change in it, not on the top of the file", function()
    wait_for(function()
      return vim.api.nvim_win_get_cursor(0)[1] == last
    end, "the cursor to reach the chunk it was aimed at")
    eq(vim.api.nvim_win_get_cursor(0)[1], last,
      "and `[c` lands on the LAST change in it, not on the top of the file")

    -- ...and forwards, from that same chunk, which is the last one there is
    -- here.
    ok(press(k.hunk_next), "]c off the last chunk of a file")
  end)

  it("which is the next file, and not the next window or the list", function()
    wait_for(function()
      local b = vim.api.nvim_get_current_buf()
      local v = view_mod.get(b)
      return b ~= calc_buf and v ~= nil and v.relpath == "doomed.lua"
    end, "]c to carry on into the next file the list names")
    eq((view_mod.get(vim.api.nvim_get_current_buf()) or {}).relpath, "doomed.lua",
      "which is the next file, and not the next window or the list")
  end)

  -- The end of the review is the end. It says so rather than wrapping:
  -- running out is the answer to "what is next", and a review that came
  -- back round to the top would hide it.
  it("the last change in the last file stays put", function()
    said = {}
    real_notify = vim.notify
    vim.notify = function(msg) table.insert(said, msg) end
    last_idx = #pane.files
    tail_buf, tail = opened(pane.files[last_idx].path)
    tail_last = (tail.anchors or {})[#(tail.anchors or {})]
    vim.api.nvim_win_set_cursor(0, { tail_last or 1, 0 })
    press(k.hunk_next)
    vim.wait(200, function() return #said > 0 end, 10)
    vim.notify = real_notify
    eq(vim.api.nvim_get_current_buf(), tail_buf, "the last change in the last file stays put")
    ok(contains(said, "last change"), "and says there is nothing after it, got "
      .. vim.inspect(said))
  end)

  -- Off, `]c` is a motion again: it stops at the ends of the buffer it is
  -- in and the file list is stepped by `]f` alone.
  it("with chunk_spill off it goes nowhere", function()
    said = {}
    vim.notify = function(msg) table.insert(said, msg) end
    cfg.pane.chunk_spill = false
    held_buf = opened("doomed.lua")
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    press(k.hunk_prev)
    vim.wait(100, function() return false end, 10)
    vim.notify = real_notify
    cfg.pane.chunk_spill = true
    eq(vim.api.nvim_get_current_buf(), held_buf,
      "with chunk_spill off it goes nowhere")
    eq(said, {}, "and says nothing about it")
  end)

  -- Handed back: a later section opens calc.lua in a tab of its own and
  -- toggles a review on from it, and a view left here by a `[c` that
  -- stepped into the file is the one that toggle would turn off. Views
  -- are per buffer, and a buffer is the same buffer in every tab.
  view_mod.close(calc_buf)
end)

describe("the pane counts the working tree", function()
  local path, buf, before, counted_before, counted_after
  local function counted()
    for _, f in ipairs(pane.files) do
      if f.path == path then
        return f.added
      end
    end
  end
  -- `git diff <fork point>` with no second revision, so an unsaved-then-
  -- saved edit is counted. A range would have called the file unchanged.
  -- On the file the branch ADDED, whose count is a plain line count. A
  -- renamed file would have been the wrong subject: edit one enough and
  -- git stops calling it a rename at all, so the number moves for a
  -- reason that has nothing to do with what this is testing.
  it("a saved edit lands in the pane's counts", function()
    path = "helper.lua"
    for i, f in ipairs(pane.files) do
      if f.path == path then
        pane_mod.goto_file(pane, i)
      end
    end
    buf = vim.api.nvim_get_current_buf()
    wait_for(function()
      local v = view_mod.get(buf)
      return v ~= nil and v.relpath == path and (v.renders or 0) > 0
    end, "a view over the file about to be written")
    before = pane.renders
    counted_before = counted()
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "-- a line added while reviewing" })
    vim.cmd("silent write")
    wait_for(function() return (pane.renders or 0) > before end, "the pane to re-read after a write")
    counted_after = counted()
    eq(counted_after, counted_before + 1, "a saved edit lands in the pane's counts")
  end)

end)

-- `git diff <fork point>` cannot mention an untracked file: there is no
-- revision it existed in to be measured against. It is still part of
-- what the branch did, and a list that leaves it out answers "what have
-- I changed" with everything except the file you just wrote -- which is
-- also the one `]f` then cannot reach.
describe("a file git has never heard of", function()
  local path, full, before, row, idx, opened, listed
  it("a file git has never been told about is in the list", function()
    path = "brand_new.lua"
    full = fixture .. "/" .. path
    vim.fn.writefile({ "local M = {}", "", "function M.hello()", "end", "return M" }, full)

    before = pane.renders
    pane_mod.refresh(pane)
    wait_for(function() return (pane.renders or 0) > before end, "the list to be re-read")

    for _, f in ipairs(pane.files) do
      if f.path == path then
        row = f
      end
    end
    ok(row ~= nil, "a file git has never been told about is in the list")
    eq(row and row.status, "A", "as an addition, which is what it is")
    eq(row and row.added, 5, "with every line of it counted, since none of them was there")
    eq(row and row.removed, 0, "and nothing removed")
  end)

  -- ...and it is reachable, which is the half that matters: a row nobody
  -- can step to is a row that only says the file exists.
  it("stepping the list opens it", function()
    for i, f in ipairs(pane.files) do
      if f.path == path then
        idx = i
      end
    end
    pane_mod.goto_file(pane, idx)
    opened = vim.api.nvim_get_current_buf()
    eq(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(opened), ":t"), path,
      "stepping the list opens it")
  end)

  it("annotated as a file with no old side at all", function()
    wait_for(function()
      local v = view_mod.get(opened)
      return v ~= nil and (v.renders or 0) > 0
    end, "a view on the new file")
    ok((view_mod.get(opened) or {}).new_file == true,
      "annotated as a file with no old side at all")
  end)

  -- Ignored files are git's own answer to "not mine", and the list takes
  -- it: `--exclude-standard` is what keeps a build directory out of a
  -- review.
  it("a file .gitignore covers stays out of it", function()
    vim.fn.writefile({ "*.log" }, fixture .. "/.gitignore")
    vim.fn.writefile({ "ignored" }, fixture .. "/ignored.log")
    before = pane.renders
    pane_mod.refresh(pane)
    wait_for(function() return (pane.renders or 0) > before end, "the list once more")
    listed = vim.tbl_map(function(f) return f.path end, pane.files)
    ok(not contains(listed, "ignored.log"),
      "a file .gitignore covers stays out of it, got " .. table.concat(listed, ", "))
    ok(contains(listed, ".gitignore"),
      "while the .gitignore that says so is itself a new file of the branch")
  end)

  -- Gone from the disk AND from the editor. A buffer still holding the
  -- text is a change the list is right to keep reporting -- that is the
  -- same reason an unsaved edit is counted -- so the buffer goes first,
  -- put away by reading another file into its window rather than by
  -- wiping it out from under one: the pane remembers the window it
  -- splits off, and a window closed here is one the next section cannot
  -- step back into.
  it("and it leaves the list when it leaves the disk", function()
    vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/helper.lua"))
    vim.cmd("silent! bwipeout! " .. opened)
    vim.fn.delete(full)
    vim.fn.delete(fixture .. "/ignored.log")
    vim.fn.delete(fixture .. "/.gitignore")
    before = pane.renders
    pane_mod.refresh(pane)
    wait_for(function() return (pane.renders or 0) > before end, "the list after deleting it")
    listed = vim.tbl_map(function(f) return f.path end, pane.files)
    ok(not contains(listed, path), "and it leaves the list when it leaves the disk")
  end)

end)

-- A branch is a sequence of commits, and reviewing it is often reading
-- them in order rather than all at once. `<leader>gh` turns that on:
-- the review becomes one commit, its own files measured against the one
-- before it. `]C`/`[C` move within it. Off again, the review is what it
-- is the rest of the time -- the whole branch against the working tree.
describe("reading a review one commit at a time", function()
  local p, whole, tree_rev, keys, said, real_notify, pane_key, in_list, turns, buf, at, v, checkout, at_name, co, on
  local planted
  -- A clean tree, because half of what this section is about is the
  -- case where the reader's own file IS the commit's content, and an
  -- earlier section here has been writing to one of these files. Put
  -- back rather than worked around: "nothing has touched it since" is
  -- the precondition, and a test that cannot state its own
  -- preconditions is testing something else.
  it("the review is the whole branch to start with", function()
    vim.fn.system({ "git", "-C", fixture, "checkout", "--", "." })
    -- ...and the buffers that were holding what git just put back. A
    -- buffer is what the file IS, unsaved edits and all -- that is the
    -- rule the whole plugin rests on -- so a stale one here would make
    -- the reader's own file differ from the commit for a reason that has
    -- nothing to do with the commit.
    vim.cmd("silent! checktime")

    vim.cmd("tabnew")
    base.set(root, "main")
    vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
    uatis.toggle_diff()
    wait_for(function()
      local p = pane_mod.get()
      return p ~= nil and (p.renders or 0) > 0
    end, "a review to read commit by commit")
    p = pane_mod.get()
    whole = #p.files
    tree_rev = p.rev
    ok(whole > 1, "the review is the whole branch to start with, got " .. whole .. " files")
    ok(p.commit == nil, "with no single commit on show")
  end)

  it("and the keys say how to read it one at a time", function()
    keys = require("uatis.config").keys.pane
    ok(offered(p):find(keys.commit_view .. " read the branch one commit at a time",
      1, true) ~= nil,
      "and the keys say how to read it one at a time, got " .. offered(p))
  end)

  -- The navigation keys do not turn the mode on. A key that means "next"
  -- has no business meaning "enter" as well.
  it("stepping does not enter the mode", function()
    said = {}
    real_notify = vim.notify
    vim.notify = function(msg) table.insert(said, msg) end
    pane_mod.step_commit(p, -1)
    wait_for(function() return #said > 0 end, "uatis to say the mode is off")
    ok(p.commit == nil, "stepping does not enter the mode")
    -- The view's key, since this is pressed in a file as often as in the
    -- list -- and the list's own toggle is a bare `C`, which in a file is
    -- `c$` and could never be bound there.
    ok(said[1]:find(require("uatis.config").keys.view.commit_view, 1, true) ~= nil,
      "and says which key does, got " .. said[1])
  end)

  it("the list has a window to bind keys in", function()
    vim.notify = real_notify

    -- The list has a bare letter for it, which only a list can afford:
    -- `C` there has nothing to change, and in the file beside it that
    -- keystroke is `c$`.
    pane_key = require("uatis.config").keys.pane.commit_view
    if not p.list_buf then
      pane_mod.open({ focus = false })
    end
    ok(p.list_buf ~= nil, "the list has a window to bind keys in")
  end)

  it("the list binds", function()
    in_list = vim.api.nvim_buf_call(p.list_buf, function()
      return vim.fn.maparg(pane_key, "n", false, true)
    end)
    ok(in_list and in_list.callback ~= nil, "the list binds " .. pane_key)
    eq(vim.fn.maparg(pane_key, "n"), "",
      "and nothing binds it in the file beside it, where it is a change command")
  end)

  -- Planted before the walk makes its first checkout, which is when the
  -- folder is swept: one of an editor still running (the one that started
  -- this one, standing in for a second nvim on the same repository), one
  -- of an editor that has exited, one from before the folders carried
  -- their editor's pid.
  it("the checkouts folder holds other editors' checkouts", function()
    local gone = vim.system({ "true" })
    gone:wait()
    local folder = vim.fs.normalize(vim.fn.stdpath("cache") .. "/uatis/review/"
      .. vim.fs.basename(p.root) .. "-" .. vim.fn.sha256(p.root):sub(1, 8))
    planted = {
      live = folder .. "/" .. vim.uv.os_getppid() .. "-2-11111",
      dead = folder .. "/" .. gone.pid .. "-2-22222",
      legacy = folder .. "/2-33333",
    }
    for _, dir in pairs(planted) do
      vim.fn.mkdir(dir, "p")
    end
    ok(not require("uatis.checkout").has(p), "and this review has none of its own yet")
  end)

  -- Entering shows the first commit: where the branch starts, so `]C`
  -- reads it in the order it was written.
  it("the toggle enters at the first commit", function()
    turns = p.renders
    pane_mod.toggle_commits(p)
    wait_for(function() return p.commit ~= nil and (p.renders or 0) > turns end,
      "the first commit to be put on show")
    eq(p.commit_idx, 1, "the toggle enters at the first commit")
    eq(p.rev, p.tree_rev, "measured against the fork point, which is its parent")
  end)

  -- The date on the commit's row says the day; rested on, it says the
  -- moment, to the second and with its offset.
  it("which is the last thing the branch did", function()
    do
      require("uatis.filelist").render(p)
      local row, span
      for r, sp in pairs(p.list_dates or {}) do
        if sp.sha == p.commit.sha then
          row, span = r, sp
        end
      end
      if ok(span ~= nil, "the commit's date is a place in the list") then
        -- After the commit's file has opened, which takes the cursor to it.
        wait_for(function()
          local v = vim.api.nvim_win_is_valid(p.code_win)
            and view_mod.get(vim.api.nvim_win_get_buf(p.code_win))
          return v and (v.renders or 0) > 0
        end, "the commit's file to open")
        -- A list render still in flight puts the cursor back on the
        -- current file's row, and a date the cursor has left is not
        -- shown -- so it is put back on the date, and asked again,
        -- each time that happens.
        wait_for(function()
          if p.date_float and vim.api.nvim_win_is_valid(p.date_float) then
            return true
          end
          local at = vim.api.nvim_win_get_cursor(p.list_win)
          if vim.api.nvim_get_current_win() ~= p.list_win
            or at[1] ~= row or at[2] ~= span.col_start then
            vim.api.nvim_set_current_win(p.list_win)
            vim.api.nvim_win_set_cursor(p.list_win, { row, span.col_start })
            pane_mod.peek_date(p)
          end
          return false
        end, "the date's float")
        local said = p.date_float and vim.api.nvim_win_is_valid(p.date_float)
          and vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(p.date_float), 0, -1, false)[1] or ""
        ok(said:match("^" .. vim.pesc(p.commit.date) .. " %d%d:%d%d:%d%d [+-]%d%d%d%d") ~= nil,
          "rested on, it says the time to the second, got " .. said)
        vim.api.nvim_win_set_cursor(p.list_win, { row, 0 })
        vim.api.nvim_exec_autocmds("CursorMoved", { buffer = p.list_buf })
        ok(not (p.date_float and vim.api.nvim_win_is_valid(p.date_float)), "and moving on closes it")
        pane_mod.peek_date(p)
        vim.wait(300)
        ok(not (p.date_float and vim.api.nvim_win_is_valid(p.date_float)),
          "off the date, nothing is said")
        vim.api.nvim_set_current_win(p.code_win)
      end
    end

    -- ...and `]C` walks it to the newest, where the rest of this is read.
    for _ = 2, #p.commits do
      local at = p.commit_idx
      pane_mod.step_commit(p, 1)
      wait_for(function() return p.commit_idx == at + 1 end, "the next commit")
    end

    -- The walk's header: where you are in it, which commit, when and by
    -- whom -- all on one greyed row -- and the message under it in the
    -- buffer's own colour. Everything above the message is how you FIND a
    -- commit; the message is the thing being read.
    do
      local walk = require("uatis.ui").build_list(p, 38)
      local said = vim.trim(walk.lines[2] or "")
      ok(said:find(("%d/%d"):format(p.commit_idx, #p.commits), 1, true) == 1,
        "the count leads the row, got " .. said)
      ok(said:find(p.commit.short, 1, true) ~= nil, "with the sha on it, got " .. said)
      eq(vim.trim(walk.lines[3] or ""), p.commit.subject,
        "and the message under it, got " .. table.concat(walk.lines, " | "))
    end
    eq(p.commit.subject, "document clamp", "which is the last thing the branch did")
    eq(p.rev, p.commits[#p.commits - 1].sha,
      "measured against the commit before it, not against the base")
    eq(#p.files, 1, "and the list is that commit's own files")
  end)

  -- The newest commit on a clean tree is the one case where the file on
  -- disk IS the commit's content, so the reader keeps their own buffer.
  it("as the reader's own buffer, since nothing has moved since", function()
    wait_for(function()
      return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t") == "helper.lua"
    end, "the commit's file to be opened")
    buf = vim.api.nvim_get_current_buf()
    ok(vim.bo[buf].buftype == "", "as the reader's own buffer, since nothing has moved since")
    ok(vim.bo[buf].modifiable, "which is still a buffer they could type in")
    eq((view_mod.get(buf) or {}).at_commit, nil, "so nothing says it is a copy")
  end)

  -- `]C` at the newest stays there and says so: walking off the end of a
  -- list is a thing to be told about, not a way out of the mode.
  it("the last commit says so", function()
    said = {}
    vim.notify = function(msg) table.insert(said, msg) end
    pane_mod.step_commit(p, 1)
    wait_for(function() return #said > 0 end, "uatis to say there is no next commit")
    ok(said[1]:find("last commit", 1, true) ~= nil, "the last commit says so, got " .. said[1])
    ok(p.commit ~= nil, "and the mode is still on")
  end)

  it("the one before is on show", function()
    vim.notify = real_notify

    -- Back through the branch, one commit at a time.
    pane_mod.step_commit(p, -1)
    wait_for(function() return p.commit_idx == #p.commits - 1 end, "the commit before it")
    vim.wait(400)
    eq(p.commit.subject, "drop doomed, rename module", "the one before is on show")
    eq(#p.files, 2, "with its own two files")
  end)

  it("which added the helper", function()
    pane_mod.step_commit(p, -1)
    wait_for(function() return p.commit_idx == #p.commits - 2 end, "and the one before that")
    vim.wait(400)
    eq(p.commit.subject, "add clamp helper", "which added the helper")
  end)

  it("a file later commits touched is shown as it was, out of a checkout", function()
    at = vim.api.nvim_get_current_buf()
    v = view_mod.get(at)
    -- ...out of the review's own checkout of that commit: a real file,
    -- which a language server attaches to, holding the commit's text.
    checkout = require("uatis.checkout")
    at_name = vim.api.nvim_buf_get_name(at)
    co = checkout.owner_of(at_name)
    ok(co ~= nil, "a file later commits touched is shown as it was, out of a checkout, got "
      .. at_name)
    eq(vim.bo[at].buftype, "", "as a file on disk, for a language server to attach to")
    eq(table.concat(vim.api.nvim_buf_get_lines(at, 0, -1, false), "\n"),
      vim.fn.system({ "git", "-C", fixture, "show", p.commit.sha .. ":helper.lua" }):gsub("\n$", ""),
      "holding the commit's text")
    ok(not vim.bo[at].modifiable, "read-only, because it is not the reader's file")
    eq(v and v.at_commit, p.commit.short, "and the view says which commit it holds")
    -- A checkout is swept only where its editor is gone: one still
    -- running is reviewing out of it, and its buffers would be left
    -- standing on a folder that is not there.
    eq(vim.fn.isdirectory(planted.live), 1, "another running editor's checkout is left alone")
    eq(vim.fn.isdirectory(planted.dead), 0, "an exited editor's is swept")
    eq(vim.fn.isdirectory(planted.legacy), 0, "and so is one with no editor named")
    vim.fn.delete(planted.live, "rf")
    eq(v and v.rev, p.commits[p.commit_idx - 1].sha, "measured against the commit before it")
  end)

  -- The checkout is moved under a language server, which has only the
  -- files open in buffers re-read for it: everything else stays indexed
  -- as the last commit had it unless it is told. Moved back over the
  -- commit that added the helper, two files go; moved forward again,
  -- they come back. (Moved by hand: the first commit's file is the
  -- reader's own, and a step onto it leaves the checkout where it is.)
  it("a step tells the checkout's language server which files moved", function()
    local heard = {}
    local id = vim.lsp.start({
      name = "uatis-spec-listener",
      root_dir = co.dir,
      cmd = function()
        local closing = false
        return {
          request = function(method, _, cb)
            if method == "initialize" then
              vim.schedule(function() cb(nil, { capabilities = {} }) end)
            end
            return true, 1
          end,
          notify = function(method, params)
            if method == "workspace/didChangeWatchedFiles" then
              table.insert(heard, params.changes)
            end
            return true
          end,
          is_closing = function() return closing end,
          terminate = function() closing = true end,
        }
      end,
    }, { attach = false })
    local client = vim.lsp.get_client_by_id(id)
    wait_for(function() return client.initialized end, "the listener to start")
    local function said(n)
      local got = {}
      for _, c in ipairs(heard[n] or {}) do
        got[vim.uri_to_fname(c.uri):sub(#co.dir + 2)] = c.type
      end
      return got
    end
    local back, forth
    checkout.at(p, p.commits[1].sha, function(dir) back = dir or false end)
    wait_for(function() return back ~= nil end, "the checkout to move back")
    checkout.at(p, p.commit.sha, function(dir) forth = dir or false end)
    wait_for(function() return forth ~= nil end, "and forward again")
    client:stop(true)
    local kinds = vim.lsp.protocol.FileChangeType
    eq(said(1), { ["helper.lua"] = kinds.Deleted, ["util/strings.lua"] = kinds.Deleted },
      "a step tells the checkout's language server which files moved")
    eq(said(2), { ["helper.lua"] = kinds.Created, ["util/strings.lua"] = kinds.Created },
      "and which came back")
  end)

  -- ...and the other end of the sequence.
  it("the first commit says so", function()
    said = {}
    vim.notify = function(msg) table.insert(said, msg) end
    pane_mod.step_commit(p, -1)
    vim.wait(400)
    pane_mod.step_commit(p, -1)
    wait_for(function() return #said > 0 end, "uatis to say there is nothing further back")
    ok(said[1]:find("first commit", 1, true) ~= nil, "the first commit says so, got " .. said[1])
  end)

  it("and it stays there", function()
    vim.notify = real_notify
    eq(p.commit_idx, 1, "and it stays there")
    eq(p.target, "main", "whose parent is what the review measures from, named as such")

    -- The two keys that only mean anything in this mode are only offered
    -- in it -- and `C`, which does not go away, says what it does now.
    ok(offered(p):find(keys.commit_prev .. " " .. keys.commit_next, 1, true) ~= nil,
      "the keys offer the step pair while a commit is on show, got " .. offered(p))
    ok(offered(p):find(keys.commit_view .. " back to the whole branch", 1, true) ~= nil,
      "and say where the toggle goes from here, got " .. offered(p))
  end)

  -- `FocusGained` while a commit is on show. `recheck` drops the walk --
  -- something may have landed on the branch while nvim was not looking
  -- -- and the header counts the commit against that walk, so dropping
  -- it and rendering threw: `attempt to get length of field 'commits'`.
  -- The reader stays on the commit they were reading; only the count it
  -- is one of can have moved.
  it("a commit on show survives a recheck, with the walk it is counted against", function()
    on = p.commit
    turns = p.renders
    pane_mod.recheck(p)
    wait_for(function() return (p.renders or 0) > turns end,
      "the list to be re-read after git may have moved")
    ok(p.commit ~= nil and p.commits ~= nil,
      "a commit on show survives a recheck, with the walk it is counted against")
    eq(p.commit and p.commit.sha, on.sha, "and it is the same commit")
    eq(p.commit_idx, 1, "at its place in the walk")
  end)

  -- Another plugin's buffer being written in -- nemeton's composer, a
  -- commit message -- in a split of this tab: `acwrite`, wiped when
  -- hidden, and modified. Coming back to the editor re-opened the
  -- file on show, which took the cursor out of it; and with the code's
  -- own window gone, the composer was the window it was opened into,
  -- which threw E37 out of a `git.blob` callback.
  local composer, code_wins
  local function compose()
    local cbuf = vim.api.nvim_create_buf(false, true)
    vim.bo[cbuf].bufhidden = "wipe"
    vim.bo[cbuf].buftype = "acwrite"
    vim.api.nvim_buf_set_name(cbuf, "uatis-test://compose")
    vim.cmd("botright 6split")
    vim.api.nvim_win_set_buf(0, cbuf)
    vim.api.nvim_buf_set_lines(cbuf, 0, -1, false, { "half a description" })
    return vim.api.nvim_get_current_win()
  end

  it("coming back leaves the reader in what they were writing", function()
    composer = compose()
    turns = p.renders
    vim.cmd("doautocmd FocusGained")
    wait_for(function() return (p.renders or 0) > turns end, "the recheck to land")
    vim.wait(200)
    eq(vim.api.nvim_get_current_win(), composer,
      "coming back leaves the reader in what they were writing")
    eq(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(composer), 0, -1, false),
      { "half a description" }, "with what they wrote still in it")
  end)

  it("and a file is never opened over it", function()
    code_wins = {}
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(p.tab)) do
      if w ~= p.list_win and w ~= composer
        and vim.api.nvim_win_get_config(w).relative == "" then
        table.insert(code_wins, w)
      end
    end
    for _, w in ipairs(code_wins) do
      vim.api.nvim_win_close(w, true)
    end
    local errs = {}
    local real = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.ERROR then
        table.insert(errs, msg)
      end
    end
    local ok_call, err = pcall(pane_mod.goto_file, p, p.file_idx)
    vim.wait(400)
    vim.notify = real
    ok(ok_call, "opening a file throws nothing, got " .. tostring(err))
    eq(errs, {}, "and says nothing went wrong")
    ok(vim.api.nvim_win_is_valid(composer), "and a file is never opened over it")
    eq(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(composer)), "uatis-test://compose",
      "the composer still holds the composer")
    ok(p.code_win ~= composer and vim.api.nvim_win_is_valid(p.code_win),
      "the file has a window of its own")
    local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(p.code_win))
    ok(name ~= "" and not name:find("uatis-test://", 1, true),
      "with the file in it, got " .. name)
    vim.api.nvim_win_close(composer, true)
    vim.api.nvim_set_current_win(p.code_win)
  end)

  -- The same key turns it off, wherever in the sequence you had got to.
  it("the toggle turns it off from any commit", function()
    turns = p.renders
    pane_mod.toggle_commits(p)
    wait_for(function()
      return p.commit == nil and (p.renders or 0) > turns and #p.files == whole
    end, "the review to be the whole branch again")
    ok(p.commit == nil, "the toggle turns it off from any commit")
    eq(#p.files, whole, "and the review is the whole branch again")
    eq(p.rev, tree_rev, "against what it always measured against")
  end)

  it("with the reader in a file of their own", function()
    wait_for(function() return vim.bo[vim.api.nvim_get_current_buf()].buftype == "" end,
      "a file of the reader's own again")
    ok(vim.bo[vim.api.nvim_get_current_buf()].buftype == "",
      "with the reader in a file of their own")
    ok(checkout.owner_of(vim.api.nvim_buf_get_name(0)) == nil,
      "and not one out of the walk's checkout")
    ok(not checkout.has(p), "which the walk's end takes away")
  end)

  wait_for(function() return co and vim.fn.isdirectory(co.dir) == 0 end,
    "the walk's checkout to be removed from the disk")

  -- Taken down by hand rather than with the key: a review is one root
  -- and one revision wherever it is reached from, so ending this one
  -- would end the one the sections below are standing in.
  view_mod.close_all(root, p.rev)
  pane_mod.close(p)
  vim.cmd("silent! tabclose")
end)

-- Nothing here was written or re-read, so neither of the pane's other
-- watchers fires: the reader switched to another window, ran git there,
-- and came back. A commit would need no answer -- the list counts the
-- working tree against the fork point, and committing moves neither --
-- but a branch switched, a rebase, or the base branch pulled moves the
-- FORK POINT, and a review measuring against the old one is not stale,
-- it is wrong.
--
-- In a tab of its own, against the BASE BRANCH: only a base-tracking
-- review follows the fork point. One named by hand -- `:Uatis <ref>` --
-- was pointed at a revision by someone who meant that revision, and the
-- pane beside this section's own is one of those.
describe("the review notices git moving underneath it", function()
  local watched, path, before, disk, counted, was_rev, was_main, moved_to, v
  local function git_run(...)
    return vim.trim(vim.fn.system({ "git", "-C", fixture, ... }))
  end

  it("a change made outside nvim reaches the list", function()
    vim.cmd("tabnew")
    base.set(root, "main")
    vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
    uatis.toggle_diff()
    wait_for(function()
      local p = pane_mod.get()
      return p ~= nil and (p.renders or 0) > 0
    end, "a review against the base branch")
    watched = pane_mod.get()

    -- A change to the tree that no buffer here made.
    path = "helper.lua"
    before = watched.renders
    disk = vim.fn.readfile(fixture .. "/" .. path)
    vim.fn.writefile(vim.list_extend({ "-- written by something else" }, vim.deepcopy(disk)),
      fixture .. "/" .. path)
    vim.cmd("doautocmd FocusGained")
    wait_for(function() return (watched.renders or 0) > before end,
      "the list to be re-read on coming back")
    for _, f in ipairs(watched.files) do
      if f.path == path then
        counted = f.added
      end
    end
    ok(counted ~= nil and counted > 0,
      "a change made outside nvim reaches the list, got " .. tostring(counted))
  end)

  it("the list follows the fork point to where it moved", function()
    vim.fn.writefile(disk, fixture .. "/" .. path)

    -- ...and the fork point itself moving, which is what a branch switch
    -- or a pull on the base branch does. `main` is pointed at a commit of
    -- this branch's own, so `merge-base(main, HEAD)` is somewhere else
    -- than it was.
    was_rev = watched.rev
    was_main = git_run("rev-parse", "main")
    moved_to = git_run("rev-parse", "HEAD~1")
    git_run("branch", "-f", "main", moved_to)
    vim.cmd("doautocmd FocusGained")
    wait_for(function() return watched.rev ~= was_rev end,
      "the list to be re-pointed at the new fork point")
    eq(watched.rev, moved_to, "the list follows the fork point to where it moved")
  end)

  -- The views measuring against it move with it, or the two disagree.
  it("and the view beside it is measuring against the same one", function()
    v = view_mod.get(vim.api.nvim_get_current_buf())
    ok(v ~= nil and v.rev == watched.rev,
      "and the view beside it is measuring against the same one, got "
        .. tostring(v and v.rev))
  end)

  it("and back again when git moves back", function()
    git_run("branch", "-f", "main", was_main)
    vim.cmd("doautocmd FocusGained")
    wait_for(function() return watched.rev == was_rev end, "the fork point to be put back")
    eq(watched.rev, was_rev, "and back again when git moves back")
  end)

  -- The list of THIS tab put away, and the tab with it. Not
  -- `toggle_diff`: a review is one root and one revision wherever it is
  -- reached from, so ending it here would end the one the sections
  -- below are standing in, which is measuring against the same fork
  -- point in the tab underneath.
  pane_mod.close(watched)
  vim.cmd("silent! tabclose")
end)

-- The list is the one thing built by parsing git's own diff output, and
-- a reader's config is allowed to change what that output looks like:
-- an external differ (difftastic, on the sort of machine that has it)
-- replaces it wholesale, `color.ui = always` wraps it in escapes, the
-- prefix settings rename the `a/`/`b/` the header is found by. Every one
-- of those used to show up as an empty pane beside a buffer full of
-- highlighted changes.
describe("the reader's git config cannot empty the list", function()
  local hostile, want, before
  local function cfg(...)
    vim.system({ "git", "-C", fixture, "config", ... }):wait()
  end
  it("the list has files in it to begin with", function()
    hostile = {
      ["diff.external"] = "echo not-a-diff",
      ["diff.noprefix"] = "true",
      ["diff.mnemonicPrefix"] = "true",
      ["color.ui"] = "always",
    }
    want = #pane.files
    ok(want > 0, "the list has files in it to begin with, got " .. want)
  end)

  it("the same files are listed with git configured against us", function()
    for k, v in pairs(hostile) do
      cfg(k, v)
    end
    before = pane.renders
    pane_mod.refresh(pane)
    wait_for(function() return (pane.renders or 0) > before end, "the pane to re-read")
    eq(#pane.files, want, "the same files are listed with git configured against us")
  end)

  for k in pairs(hostile) do
    cfg("--unset", k)
  end
end)

-- The view binds ]f/[f, but a reader is not always in a file with a
-- comparison on it: a scratch buffer, a file the branch did not touch,
-- the empty buffer nvim started in. Stepping the list is about the LIST,
-- and the list is open -- so the keys are lent to whatever buffer you are
-- in, and handed back when the pane closes.
local scratch
describe("stepping the list from anywhere", function()
  local k, step, landed, borrowed
  it("a buffer with no diff view on it", function()
    k = require("uatis.config").keys.pane

    vim.api.nvim_set_current_win(pane.code_win)
    vim.cmd("enew")
    scratch = vim.api.nvim_get_current_buf()
    vim.bo[scratch].bufhidden = "hide"
    ok(view_mod.get(scratch) == nil, "a buffer with no diff view on it")
  end)

  it("still answers to", function()
    step = vim.fn.maparg(k.file_prev, "n", false, true)
    ok(step and step.callback ~= nil,
      "still answers to " .. k.file_prev .. " while the list is open")
  end)

  -- Placed deliberately: the file before this one in the list is one the
  -- branch ADDED, so stepping back has something to open. (The one before
  -- that is a file it deleted, which has nothing -- covered above.)
  it("which steps the list", function()
    pane.file_idx = 4
    if step and step.callback then
      step.callback()
    end
    eq(pane.file_idx, 3, "which steps the list")
    ok(vim.api.nvim_get_current_buf() ~= scratch
      and vim.api.nvim_buf_get_name(0):find("helper.lua", 1, true) ~= nil,
      "and opens the file it landed on, got "
        .. vim.api.nvim_buf_get_name(0):match("[^/]*$"))
  end)

  it("and a buffer that is not a file keeps its own keys", function()
    landed = vim.api.nvim_get_current_buf()

    -- A buffer of someone else's -- a terminal, a help page, another
    -- plugin's pane -- is somewhere you went for its own sake.
    -- Created as a scratch buffer BEFORE it is entered: made into one
    -- afterwards it would already have been lent the keys, which is a fact
    -- about this test rather than about the rule.
    borrowed = vim.api.nvim_create_buf(false, true)
    vim.cmd("buffer " .. borrowed)
    eq(vim.api.nvim_buf_call(borrowed, function()
      return vim.fn.maparg(k.file_prev, "n")
    end), "", "and a buffer that is not a file keeps its own keys")
  end)

  vim.cmd("buffer " .. landed)
end)

-- Reviewing a branch is a mode, not a decoration on one buffer. A file the
-- list names is annotated however you arrive at it -- `:e`, a jump to
-- definition, a picker -- and one it does not name is left alone.
describe("the review follows you", function()
  local rev, arrived, v, bystander, list_win, wins, quit, files_key, code_win
  local function press(bufnr, lhs)
    local m = vim.api.nvim_buf_call(bufnr, function()
      return vim.fn.maparg(lhs, "n", false, true)
    end)
    if not (m and m.callback) then
      return false
    end
    m.callback()
    return true
  end

  it("a changed file opened by hand is annotated on arrival", function()
    rev = pane.rev

    vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/util/strings.lua"))
    arrived = vim.api.nvim_get_current_buf()
    wait_for(function()
      local v = view_mod.get(arrived)
      return v ~= nil and (v.renders or 0) > 0
    end, "a file opened by hand to be annotated by the review")
    v = view_mod.get(arrived) or {}
    ok(v.renders ~= nil, "a changed file opened by hand is annotated on arrival")
    eq(v.rev, rev, "against the revision the review is pinned to, not one of its own")
    eq(v.tracks_base, pane.tracks_base, "and following the base branch with it")
  end)

  -- The file the branch never touched. A view here would put a winbar over
  -- every file in the repository you happened to open.
  it("a file the branch did not touch is left alone", function()
    vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/stable.lua"))
    bystander = vim.api.nvim_get_current_buf()
    ok(view_mod.get(bystander) == nil, "a file the branch did not touch is left alone")
    ok(vim.fn.maparg(require("uatis.config").keys.pane.file_next, "n") ~= "",
      "and is lent " .. require("uatis.config").keys.pane.file_next .. " instead, as any buffer is")
  end)

  -- ...unless it is asked for directly, which is what the key means in a
  -- file the list does not have. Answered by the review that is running,
  -- at its revision.
  it("asking for one by hand joins the review rather than starting a second", function()
    uatis.toggle_diff()
    wait_for(function()
      local w = view_mod.get(bystander)
      return w ~= nil and (w.renders or 0) > 0
    end, "the unlisted file to be taken in by hand")
    eq((view_mod.get(bystander) or {}).rev, rev,
      "asking for one by hand joins the review rather than starting a second")
  end)

  -- `q` is about the window. The list is what the review IS, so it stays:
  -- `]f` still steps it and the next file still arrives annotated.
  it("the list binds", function()
    list_win = pane.list_win
    wins = #vim.api.nvim_tabpage_list_wins(0)
    quit = vim.api.nvim_buf_call(pane.list_buf, function()
      return vim.fn.maparg(require("uatis.config").keys.pane.quit, "n", false, true)
    end)
    ok(quit and quit.callback ~= nil, "the list binds " .. require("uatis.config").keys.pane.quit)
  end)

  it("which closes its window", function()
    if quit and quit.callback then
      quit.callback()
    end
    ok(not vim.api.nvim_win_is_valid(list_win), "which closes its window")
    eq(#vim.api.nvim_tabpage_list_wins(0), wins - 1, "and only its window")
    ok(pane_mod.get() == pane and pane.list_win == nil,
      "while the list itself goes on, with no window of its own")
    eq(#pane.files, 5, "still listing what the branch changed")
  end)

  -- ...and the key that put it there is a toggle, so it can take it away
  -- again. Driven through the real mappings rather than through the
  -- module, because the second press of a toggle is answered by whatever
  -- buffer the first press left the cursor in -- which is the list.
  it("the view binds", function()
    files_key = require("uatis.config").keys.view.files
    ok(press(bystander, files_key), "the view binds " .. files_key)
    ok(pane_mod.get() == pane and pane.list_win ~= nil,
      "which puts a window back on the same list rather than reading a new one")
    eq(#vim.api.nvim_tabpage_list_wins(0), wins, "one window again")
    eq(vim.api.nvim_get_current_win(), pane.list_win, "with the cursor in it")
  end)

  -- Pressed while the list is up, it takes the window away wherever the
  -- cursor is: open (focused) / close, with no step in between.
  it("the file is in a window of its own", function()
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_buf(w) == bystander then
        code_win = w
      end
    end
    ok(code_win ~= nil and code_win ~= pane.list_win, "the file is in a window of its own")
  end)

  it("and the view closes it from there", function()
    vim.api.nvim_set_current_win(code_win)
    ok(press(bystander, files_key), "and the view still answers to it from there")
    eq(#vim.api.nvim_tabpage_list_wins(0), wins - 1, "which takes the window away")
    eq(vim.api.nvim_get_current_win(), code_win, "leaving the cursor where it was")
    ok(pane_mod.get() == pane and pane.list_win == nil,
      "the window, not the review -- the list goes on with no window of its own")
    eq(#pane.files, 5, "still listing what the branch changed")
  end)

  it("and once more puts it back", function()
    press(bystander, files_key)
    ok(pane.list_win ~= nil and vim.api.nvim_win_is_valid(pane.list_win),
      "and once more puts it back")
    eq(#vim.api.nvim_tabpage_list_wins(0), wins, "one window again")
  end)

end)

-- The cursor is how the list says where you are: the row it sits on is
-- the one drawn as current. So arriving at a file puts it there -- every
-- arrival, not only the ones that change which file is current, since a
-- list left on the row of the file you came back FROM points at the wrong
-- file for as long as you stay in this one.
describe("the list points at the file you are in", function()
  local back_win, back_buf, code_win, code_buf, strings_buf, was
  local function row_of(path)
    for i, f in ipairs(pane.files or {}) do
      if f.path == path then
        for line, idx in pairs(pane.list_rows or {}) do
          if idx == i then
            return line
          end
        end
      end
    end
  end
  local function cursor()
    return vim.api.nvim_win_get_cursor(pane.list_win)[1]
  end

  it("there is a window to read files in", function()
    back_win = vim.api.nvim_get_current_win()
    back_buf = vim.api.nvim_get_current_buf()

    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if w ~= pane.list_win then
        code_win = w
      end
    end
    ok(code_win ~= nil, "there is a window to read files in")
  end)

  it("arriving at a file moves the list onto its row", function()
    code_buf = vim.api.nvim_win_get_buf(code_win)
    vim.api.nvim_set_current_win(code_win)

    vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
    eq(cursor(), row_of("calc.lua"), "arriving at a file moves the list onto its row")
  end)

  it("and onto the next one's when you move on", function()
    vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/util/strings.lua"))
    eq(cursor(), row_of("util/strings.lua"), "and onto the next one's when you move on")
  end)

  -- Read the list, then go back to the file you were already in. The
  -- index has not changed, so nothing is redrawn -- and the cursor was
  -- still put back, because that is the whole of the mark.
  it("the list can be read somewhere else by hand", function()
    strings_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_set_current_win(pane.list_win)
    pcall(vim.api.nvim_win_set_cursor, pane.list_win, { row_of("helper.lua"), 0 })
    ok(cursor() ~= row_of("util/strings.lua"), "the list can be read somewhere else by hand")
  end)

  it("and coming back to the file puts the cursor back on its row", function()
    vim.api.nvim_set_current_win(code_win)
    vim.api.nvim_set_current_buf(strings_buf)
    eq(cursor(), row_of("util/strings.lua"),
      "and coming back to the file puts the cursor back on its row")
  end)

  -- A buffer the list has no row for is not a reason to move the mark off
  -- the file you were reading.
  it("an unlisted buffer leaves the list pointing where it", function()
    was = cursor()
    vim.api.nvim_set_current_buf(scratch)
    eq(cursor(), was, "an unlisted buffer leaves the list pointing where it was")
  end)

  -- Put the reader back where the section before this one left them: the
  -- suite is one session, and the next section reads the buffer it is
  -- standing in.
  vim.api.nvim_win_set_buf(code_win, code_buf)
  vim.api.nvim_set_current_win(back_win)
  vim.api.nvim_set_current_buf(back_buf)
end)

describe("closing", function()
  local list_win, wins, buf, elsewhere, left, drifted, annotated
  it("closing the pane closes its window", function()
    list_win = pane.list_win
    wins = #vim.api.nvim_tabpage_list_wins(0)
    pane_mod.close(pane)
    ok(not vim.api.nvim_win_is_valid(list_win), "closing the pane closes its window")
    eq(#vim.api.nvim_tabpage_list_wins(0), wins - 1, "and only its window")
    ok(pane_mod.get() == nil, "and unregisters it")
    eq(vim.api.nvim_buf_call(scratch, function()
      return vim.fn.maparg(require("uatis.config").keys.pane.file_prev, "n")
    end), "", "and hands back the keys it lent")
  end)

  it("the diff view is not the pane's to close", function()
    buf = vim.api.nvim_get_current_buf()
    ok(view_mod.get(buf) ~= nil, "the diff view is not the pane's to close")
  end)

  -- Every buffer the review annotated as it followed the reader around,
  -- not merely the one they happen to be standing in: a mode that had to
  -- be turned off once per file would never be all the way off.
  it("the review is on more than one buffer", function()
    elsewhere = {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if b ~= buf and view_mod.get(b) then
        table.insert(elsewhere, b)
      end
    end
    ok(#elsewhere > 0, "the review is on more than one buffer, got " .. #elsewhere)
  end)

  it("toggling again ends it", function()
    uatis.toggle_diff()
    ok(view_mod.get(buf) == nil, "toggling again ends it")
  end)

  it("and every other file it had annotated with it", function()
    left = vim.tbl_filter(function(b) return view_mod.get(b) ~= nil end, elsewhere)
    eq(#left, 0, "and every other file it had annotated with it")
    eq(#vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1, {}), 0, "and clears every mark")
    eq(vim.wo.winbar, "", "leaving no winbar line above the file")
  end)

  -- ...and the list goes with it, whatever revision the list had got to.
  -- The two can drift apart -- a view pinned by `:Uatis <ref>` beside a
  -- list that followed a base change -- and a list left up goes on
  -- annotating the next file opened, which is what the key just said to
  -- stop.
  it("a review is running, with a list", function()
    vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
    uatis.toggle_diff()
    wait_for(function()
      local p = pane_mod.get()
      return p ~= nil and (p.renders or 0) > 0
    end, "a review to end again")
    drifted = pane_mod.get()
    ok(drifted ~= nil, "a review is running, with a list")
  end)

  it("ending the review takes the list with it", function()
    drifted.rev = "0000000000000000000000000000000000000000"
    uatis.toggle_diff()
    ok(pane_mod.get() == nil, "ending the review takes the list with it")
    ok(not (drifted.list_win and vim.api.nvim_win_is_valid(drifted.list_win)),
      "and the window it was in")
  end)

  -- A review reached from two tabs is one review: the views are, since
  -- they are closed by root and revision wherever they are, and the
  -- lists have to be too. The second one used to be left running --
  -- annotating every file opened in that tab, for a review that was
  -- over.
  it("the same review, listed in two tabs", function()
    vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
    uatis.toggle_diff()
    wait_for(function()
      local p = pane_mod.get()
      return p ~= nil and (p.renders or 0) > 0
    end, "a review to reach from two tabs")
    vim.cmd("tab split")
    pane_mod.open({ focus = false })
    wait_for(function()
      local p = pane_mod.get()
      return p ~= nil and (p.renders or 0) > 0
    end, "the same review listed in the second tab")
    eq(#pane_mod.all(), 2, "the same review, listed in two tabs")
  end)

  it("ending it in one ends it in both", function()
    vim.cmd("tabprevious")
    uatis.toggle_diff()
    eq(#pane_mod.all(), 0, "ending it in one ends it in both")
  end)

  it("standing in a buffer with no file", function()
    vim.cmd("silent! tabnext")
    if vim.fn.tabpagenr("$") > 1 then
      vim.cmd("silent! tabclose")
    end

    -- The same from a buffer with nothing to compare: a scratch buffer, a
    -- terminal, the empty one nvim started in. The key means the review,
    -- not the window -- closing the window alone would leave every file it
    -- had annotated annotated, with nothing left on screen to end it by.
    vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
    annotated = vim.api.nvim_get_current_buf()
    uatis.toggle_diff()
    wait_for(function()
      local p = pane_mod.get()
      return p ~= nil and (p.renders or 0) > 0 and view_mod.get(annotated) ~= nil
    end, "a review to end from somewhere else")
    vim.cmd("enew")
    ok(view_mod.can_open(vim.api.nvim_get_current_buf()) == false,
      "standing in a buffer with no file")
  end)

  -- With no list on screen the first press shows it -- ending a review
  -- the reader cannot see changes nothing they can see -- and the next
  -- ends it, as from a list that was up all along.
  it("which ends the review from there too", function()
    local p = pane_mod.get()
    ok(not (p.list_win and vim.api.nvim_win_is_valid(p.list_win)), "no list on screen")
    uatis.toggle_diff()
    ok(pane_mod.get() == p and vim.api.nvim_win_is_valid(p.list_win), "the list comes up first")
    uatis.toggle_diff()
    ok(pane_mod.get() == nil, "which ends the review from there too")
    ok(view_mod.get(annotated) == nil, "annotations and all")
  end)

  vim.cmd("silent! tabclose")
  vim.fn.system({ "git", "-C", fixture, "switch", "-qf", "main" })
end)

-- Starting nvim in a repository and pressing the key: nothing here to
-- annotate, and nobody is here for this buffer either. The list is
-- read and the first file it names opens where the empty buffer was,
-- with the list beside it -- the same landing as a review begun from a
-- file, one `]f` earlier.
describe("a review begun from the empty buffer lands on its first file", function()
  local here, empty, p, landed, typed, typed_win
  it("standing in the empty buffer", function()
    vim.fn.system({ "git", "-C", fixture, "switch", "-qf", "feature/math" })
    vim.cmd("tabnew")
    here, empty = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    ok(vim.api.nvim_buf_get_name(empty) == "" and not vim.bo[empty].modified,
      "standing in the empty buffer")
  end)

  -- The fixture's root is not the cwd, so the question is asked of it.
  it("and it is the first file the list names", function()
    vim.cmd("lcd " .. vim.fn.fnameescape(fixture))

    uatis.toggle_diff()
    wait_for(function()
      local p = pane_mod.get()
      return p ~= nil and (p.renders or 0) > 0
        and vim.api.nvim_win_get_buf(here) ~= empty
        and view_mod.get(vim.api.nvim_win_get_buf(here)) ~= nil
    end, "the first file to open in the window the empty buffer was in")
    p = pane_mod.get()
    landed = vim.api.nvim_win_get_buf(here)
    eq(vim.api.nvim_buf_get_name(landed), fixture .. "/" .. p.files[1].path,
      "and it is the first file the list names")
    eq(p.file_idx, 1, "which the list points at")
    eq(vim.api.nvim_get_current_win(), here,
      "with the cursor in the file rather than in the list")
    ok(p.list_win and vim.api.nvim_win_is_valid(p.list_win), "and the list up beside it")
  end)

  -- A buffer someone is using is left alone: the list goes up and
  -- takes the cursor, and which file to open is the reader's call.
  it("the buffer typed into is still there", function()
    view_mod.stop(view_mod.get(landed))
    wait_for(function() return pane_mod.get() == nil end, "the review to end")
    vim.cmd("enew")
    typed = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(typed, 0, -1, false, { "notes" })
    typed_win = vim.api.nvim_get_current_win()
    uatis.toggle_diff()
    wait_for(function()
      local q = pane_mod.get()
      return q ~= nil and (q.renders or 0) > 0
    end, "the list to be read from a buffer being typed into")
    eq(vim.api.nvim_win_get_buf(typed_win), typed, "the buffer typed into is still there")
    eq(vim.api.nvim_get_current_win(), pane_mod.get().list_win, "and the list has the cursor")
  end)

  pane_mod.close(pane_mod.get())
  vim.bo[typed].modified = false

  vim.cmd("silent! tabclose")
  vim.fn.system({ "git", "-C", fixture, "switch", "-qf", "main" })
end)

-- `]f` closes one view and opens the next as a new one, and a reader who
-- put the old revision beside the first file wants it beside the second
-- too -- not the default back every time the list moves on. The choice
-- is kept on the list, which is what outlives the view, and goes when
-- the review does: the next review starts at the default like anything
-- else.
describe("the layout is the review's, and ends with it", function()
  local oldside, kv, ko, first, view, p, second, shown, revision, olds, back, third, again
  local function press(lhs)
    local m = vim.fn.maparg(lhs, "n", false, true)
    ok(m and m.callback ~= nil, "the buffer binds " .. lhs)
    if m and m.callback then
      m.callback()
    end
  end
  -- The view on the buffer under the cursor, once it is drawn in the
  -- layout the review has chosen: side by side, the old window opens
  -- off a blob fetch of its own, and a view whose marks have landed can
  -- still be waiting on it.
  local function settled(path)
    local buf = vim.api.nvim_get_current_buf()
    wait_for(function()
      local v = view_mod.get(buf)
      return v ~= nil and v.relpath == path and (v.renders or 0) > 0
        and (v.layout ~= "side" or oldside.is_open(v))
    end, "a view over " .. path .. " in the review's layout")
    return view_mod.get(buf) or {}
  end

  it("a view starts in place", function()
    oldside = require("uatis.oldside")
    kv = require("uatis.config").keys.view
    ko = require("uatis.config").keys.old

    vim.fn.system({ "git", "-C", fixture, "switch", "-qf", "feature/math" })
    vim.cmd("tabnew " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
    first = vim.api.nvim_get_current_buf()

    uatis.run({ fargs = { "main" } })
    view = settled("calc.lua")
    wait_for(function()
      local p = pane_mod.get()
      return p ~= nil and (p.renders or 0) > 0
    end, "the list to be read")
    p = pane_mod.get()
    eq(view.layout, "inline", "a view starts in place")
    eq(p.layout, nil, "and the review has no layout chosen yet")
  end)

  it("the key puts the old side in a window", function()
    press(kv.layout)
    eq(view.layout, "side", kv.layout .. " puts the old side in a window")
    eq(p.layout, "side", "which is the review's choice, not the file's")
  end)

  it("]f moves on to the next file", function()
    press(kv.file_next)
    second = settled("doomed.lua")
    ok(vim.api.nvim_get_current_buf() ~= first, "]f moves on to the next file")
    eq(second.layout, "side", "which comes up side by side too")
    ok(oldside.is_open(second), "with the old revision in a window beside it")
  end)

  -- ...holding the revision. Opened before the first render, the old
  -- window was filled while `old_text` was still nil, and the render
  -- that then landed laid it out from a cache of that: every row blank,
  -- with the removal marks drawn on the blanks. Content that appeared
  -- only on the next render -- a switch of backend and back.
  it("and the old window holds the revision's lines, not blanks", function()
    shown = {}
    for _, l in ipairs(vim.api.nvim_buf_get_lines(second.old.buf, 0, -1, false)) do
      if l ~= "" then
        table.insert(shown, l)
      end
    end
    revision = {}
    for _, l in ipairs(vim.split(second.old_text or "", "\n", { plain = true })) do
      if l ~= "" then
        table.insert(revision, l)
      end
    end
    eq(shown, revision, "and the old window holds the revision's lines, not blanks")
    ok(view_mod.get(first) == nil, "and the file left behind is closed")
  end)

  it("its old window with it: one old side on screen, not two", function()
    olds = 0
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if oldside.view_for(vim.api.nvim_win_get_buf(w)) then
        olds = olds + 1
      end
    end
    eq(olds, 1, "its old window with it: one old side on screen, not two")
  end)

  -- The commit walk is the review's, and the old window is as much a
  -- file of it as the one beside it: pressed there, it answers.
  it("the old window steps the commits too", function()
    local said = {}
    local real = vim.notify
    vim.notify = function(msg) table.insert(said, msg) end
    vim.api.nvim_set_current_win(second.old.win)
    press(kv.commit_next)
    vim.notify = real
    ok(said[1] and said[1]:find("not reading commit by commit", 1, true) ~= nil,
      kv.commit_next .. " in the old window reaches the walk, got " .. tostring(said[1]))
    vim.api.nvim_set_current_win(second.win)
  end)

  it("and back again the same way", function()
    press(kv.file_prev)
    back = settled("calc.lua")
    eq(back.layout, "side", "and back again the same way")
    eq(p.layout, "side", "the review still says so")
  end)

  -- The same key from the other window: the layout is two windows, and
  -- a toggle that answered from only one of them was half a toggle.
  -- `q` in there is the same choice under another name -- a close that
  -- left the review saying "side" had the next file come up beside a
  -- revision the reader had just dismissed.
  it("the key in the old window goes back in place", function()
    vim.api.nvim_set_current_win(back.old.win)
    press(kv.layout)
    eq(back.layout, "inline", kv.layout .. " in the old window goes back in place")
    ok(not oldside.is_open(back), "closing that window")
    eq(vim.api.nvim_get_current_win(), back.win, "and leaves the cursor in your file")
    eq(p.layout, "inline", "as the review's choice")
  end)

  it("the key in the old window is the same choice", function()
    press(kv.layout)
    wait_for(function() return oldside.is_open(back) end, "the old window to open again")
    vim.api.nvim_set_current_win(back.old.win)
    press(ko.quit)
    eq(back.layout, "inline", ko.quit .. " in the old window is the same choice")
    eq(p.layout, "inline", "for the review")
    eq(vim.api.nvim_get_current_win(), back.win, "with the cursor back in your file")
  end)

  it("pressing the key again goes back in place", function()
    press(kv.layout)
    wait_for(function() return oldside.is_open(back) end, "the old window to open once more")

    -- Switched back in one file, it is switched back for the rest.
    press(kv.layout)
    eq(back.layout, "inline", "pressing the key again goes back in place")
    eq(p.layout, "inline", "for the review")
  end)

  it("and the next file comes up in place", function()
    press(kv.file_next)
    third = settled("doomed.lua")
    eq(third.layout, "inline", "and the next file comes up in place")
    ok(not oldside.is_open(third), "with no old window")
  end)

  -- Ending the review ends the choice: the next one starts at the
  -- default, however the last one was left.
  it("left side by side", function()
    press(kv.layout)
    eq(p.layout, "side", "left side by side")
  end)

  it("a new review starts in place", function()
    view_mod.stop(view_mod.get(vim.api.nvim_get_current_buf()))
    wait_for(function() return pane_mod.get() == nil end, "the review to end")
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      ok(oldside.view_for(vim.api.nvim_win_get_buf(w)) == nil,
        "ending the review takes the old window with it")
    end

    vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
    uatis.run({ fargs = { "main" } })
    again = settled("calc.lua")
    wait_for(function()
      local q = pane_mod.get()
      return q ~= nil and (q.renders or 0) > 0
    end, "the list to be read again")
    eq(again.layout, "inline", "a new review starts in place")
    eq(pane_mod.get().layout, nil, "with no layout chosen")
  end)

  view_mod.stop(again)
  wait_for(function() return pane_mod.get() == nil end, "the review to end")

  vim.cmd("silent! tabclose")
  vim.fn.system({ "git", "-C", fixture, "switch", "-qf", "main" })
end)

-- `:e` is what a reader does when something else has written the file
-- they are reviewing. Neovim reads it back into the SAME buffer and the
-- same window, and drops every `nvim_buf_attach` doing it -- so the
-- review used to end on the one gesture most likely to be aimed at it.
--
-- Last, and on a tab and a review of its own: this section edits past a
-- file on purpose, and every section above it is about a layout.
describe("re-reading a file is not leaving it", function()
  local buf, v, rev, renders, ns, list, list_renders, again
  it("with marks on it", function()
    vim.fn.system({ "git", "-C", fixture, "switch", "-qf", "feature/math" })
    vim.cmd("tabnew " .. vim.fn.fnameescape(fixture .. "/util/strings.lua"))
    buf = vim.api.nvim_get_current_buf()

    require("uatis").run({ fargs = { "main" } })
    wait_for(function()
      local v = view_mod.get(buf)
      return v ~= nil and (v.renders or 0) > 0
    end, "a view to re-read under")
    v = view_mod.get(buf)
    rev, renders = v.rev, v.renders
    ns = require("uatis.overlay").ns
    ok(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) > 0, "with marks on it")
  end)

  it("the review survives `:e`, as the same view", function()
    list = pane_mod.get()
    wait_for(function() return list ~= nil and (list.renders or 0) > 0 end,
      "a list beside it")
    list_renders = list and list.renders or 0

    vim.cmd("edit!")
    wait_for(function()
      local now = view_mod.get(buf)
      return now ~= nil and (now.renders or 0) > renders
    end, "the view to draw itself again after the re-read")

    eq(view_mod.get(buf), v, "the review survives `:e`, as the same view")
    eq(view_mod.get(buf).rev, rev, "still measured against the same revision")
    ok(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) > 0,
      "and its marks are back -- re-reading takes the buffer's extmarks with it")
  end)

  -- The list goes with it. `:e` says the disk moved under us, and the
  -- list is `git diff` against that disk -- redrawing the buffer and
  -- leaving the counts beside it as they were says the write never
  -- happened.
  it("re-reading a file re-reads the list beside it", function()
    wait_for(function() return (list.renders or 0) > list_renders end,
      "the list to be re-read after the file was")
    ok((list.renders or 0) > list_renders,
      "re-reading a file re-reads the list beside it")
  end)

  -- The attachment has to come back with the marks, or the next edit
  -- goes unnoticed and they describe text that is no longer there.
  it("and the edit is still being watched for", function()
    again = view_mod.get(buf).renders
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "-- touched" })
    wait_for(function()
      local now = view_mod.get(buf)
      return now ~= nil and (now.renders or 0) > again
    end, "an edit after the re-read to redraw")
    ok(view_mod.get(buf) ~= nil, "and the edit is still being watched for")
  end)

  -- Leaving the buffer behind in the window still ends the review. That
  -- is what `BufWinLeave` is for, and it does not fire for a re-read.
  it("editing another file into the window still ends it", function()
    vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/stable.lua"))
    wait_for(function() return view_mod.get(buf) == nil end,
      "editing past the file to end the review on it")
    ok(view_mod.get(buf) == nil, "editing another file into the window still ends it")
  end)

  vim.fn.system({ "git", "-C", fixture, "switch", "-qf", "main" })
end)


h.release()
