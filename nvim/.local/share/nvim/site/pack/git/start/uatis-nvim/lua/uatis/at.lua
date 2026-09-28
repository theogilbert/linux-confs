-- The project as it was at one commit: a real checkout of it, in a tab
-- of its own, to read rather than to compare.
--
-- Everything else in this plugin draws the past over a buffer -- a
-- `uatis://at/...` copy, or the old side of a comparison -- and that is
-- right for reading a change and wrong for reading CODE: a buffer that
-- is not a file on disk has no project around it, so no language server
-- attaches, no go-to-definition, no references, no file explorer. What
-- the reader wants here is the old version as a working project, and
-- the only thing that is is a checkout. So this is `git worktree add
-- --detach` into the cache, and the tab's own working directory (`:tcd`)
-- pointed at it: the explorer, the fuzzy finder and the language server
-- all find a project there, because there is one.
--
-- Read-only in every way the editor can say so -- a checkout of the past
-- is a thing to read, and an edit made in it is an edit made to a copy
-- that is thrown away with the tab. The worktree goes when the last tab
-- on it closes, and before nvim exits.

local config = require("uatis.config")
local git = require("uatis.git")

local M = {}

local tabs = {} -- tabpage -> { root, dir, sha, short, subject }
local users = {} -- worktree dir -> how many tabs are standing in it

local augroup

--- Where the checkout of `sha` of the repository at `root` lives: one
--- per repository and commit, so two tabs on one commit share it and a
--- second open costs nothing.
local function dir_for(root, sha)
  return vim.fs.normalize(vim.fn.stdpath("cache") .. "/uatis/at/"
    .. vim.fs.basename(root) .. "-" .. vim.fn.sha256(root):sub(1, 8) .. "/" .. sha:sub(1, 12))
end

--- The at-tab a path lives in, if it lives in one.
local function owner_of(path)
  if not path or path == "" then
    return nil
  end
  path = vim.fs.normalize(path)
  for _, at in pairs(tabs) do
    if path == at.dir or path:sub(1, #at.dir + 1) == at.dir .. "/" then
      return at
    end
  end
  return nil
end

M.owner_of = owner_of

function M.get(tab)
  return tabs[tab or vim.api.nvim_get_current_tabpage()]
end

--- Every at-tab, as tabpages.
function M.all()
  local out = {}
  for tab in pairs(tabs) do
    table.insert(out, tab)
  end
  return out
end

--- Removes a worktree. `sync` on the way out of the editor, where a
--- subprocess left running is killed half done and leaves a checkout
--- behind that git still thinks it has.
---
--- The repository's folder under the cache goes too once it is empty:
--- `delete(..., "d")` refuses a folder with anything left in it, which
--- is another commit of it still open.
local function remove(root, dir, sync)
  local cmd = { "git", "-C", root, "worktree", "remove", "--force", dir }
  local parent = vim.fs.dirname(dir)
  if sync then
    vim.system(cmd):wait(10000)
    vim.fn.delete(parent, "d")
  else
    vim.system(cmd, {}, vim.schedule_wrap(function()
      vim.fn.delete(parent, "d")
    end))
  end
end

--- One tab fewer on `at.dir`, and the checkout gone with the last --
--- with the buffers read out of it and the language servers started for
--- it, which would otherwise outlive it: a server per commit browsed,
--- each indexing a directory that no longer exists.
local function release(at, sync)
  users[at.dir] = (users[at.dir] or 1) - 1
  if users[at.dir] > 0 then
    return
  end
  users[at.dir] = nil
  if not sync then
    for _, client in ipairs(vim.lsp.get_clients()) do
      local r = client.root_dir and vim.fs.normalize(client.root_dir)
      if r and (r == at.dir or r:sub(1, #at.dir + 1) == at.dir .. "/") then
        client:stop()
      end
    end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.fs.normalize(vim.api.nvim_buf_get_name(buf))
      if name == at.dir or name:sub(1, #at.dir + 1) == at.dir .. "/" then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
  end
  remove(at.root, at.dir, sync)
end

--- What a window in an at-tab says above the file: that it is the past,
--- and which. The one thing that must never be mistaken here is which
--- version of the code this is -- it looks exactly like the present.
function M.winbar()
  local at = tabs[vim.api.nvim_get_current_tabpage()]
  if not at then
    return ""
  end
  local rel = vim.api.nvim_buf_get_name(0)
  rel = vim.fs.normalize(rel):sub(#at.dir + 2)
  local ui = require("uatis.ui")
  return " %#UatisHeader#" .. ui.escape(rel ~= "" and rel or ".")
    .. "%* %#UatisMeta#· at " .. ui.escape(at.short)
    .. (at.subject ~= "" and (" · " .. ui.escape(at.subject)) or "") .. "%*%<"
end

local WINBAR = "%!v:lua.require'uatis.at'.winbar()"

--- A buffer of the checkout, made what it is: read-only, and not
--- counted as a buffer of the reader's own work.
local function take(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].buftype ~= "" then
    return
  end
  if not owner_of(vim.api.nvim_buf_get_name(bufnr)) then
    return
  end
  vim.bo[bufnr].readonly = true
  vim.bo[bufnr].modifiable = false
  -- A swap file for a copy nobody may edit is a prompt waiting to
  -- happen the next time the same commit is opened.
  vim.bo[bufnr].swapfile = false
end

--- The winbar, on every window of an at-tab showing one of its files --
--- and only where there was none, so another plugin's is left alone.
local function label(win)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  local at = tabs[vim.api.nvim_win_get_tabpage(win)]
  if not at then
    return
  end
  local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
  if owner_of(name) == at then
    if vim.wo[win].winbar == "" then
      vim.wo[win].winbar = WINBAR
    end
  elseif vim.wo[win].winbar == WINBAR then
    vim.wo[win].winbar = ""
  end
end

local function watch()
  if augroup then
    return
  end
  augroup = vim.api.nvim_create_augroup("UatisAt", { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufEnter" }, {
    group = augroup,
    callback = function(ev)
      take(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = augroup,
    callback = function()
      label(vim.api.nvim_get_current_win())
    end,
  })
  -- A tab closed any way at all -- `:tabclose`, `q` in the last window,
  -- `:tabonly` somewhere else -- is the checkout released.
  vim.api.nvim_create_autocmd("TabClosed", {
    group = augroup,
    callback = function()
      for tab, at in pairs(tabs) do
        if not vim.api.nvim_tabpage_is_valid(tab) then
          tabs[tab] = nil
          release(at, false)
        end
      end
    end,
  })
end

--- Opens the project as it was at `rev`, in a tab of its own.
---
--- `opts.root` is the repository, `opts.path` the file to land on
--- (repo-relative) where it existed then -- the directory otherwise,
--- which is the reader's own explorer's to draw. `opts.on_ready(tab)`
--- once it is up.
function M.open(rev, opts)
  opts = opts or {}
  local root = opts.root
  git.commit(root, rev, function(commit, _, err)
    if not commit then
      local why = err and err:match("^[^\r\n]*") or ""
      vim.notify("uatis: no commit at " .. rev .. (why ~= "" and (": " .. why) or ""),
        vim.log.levels.ERROR)
      return
    end
    local dir = dir_for(root, commit.sha)
    local function up()
      watch()
      vim.cmd("tabnew")
      local tab = vim.api.nvim_get_current_tabpage()
      tabs[tab] = {
        root = root, dir = dir, sha = commit.sha, short = commit.short,
        subject = commit.subject or "",
      }
      users[dir] = (users[dir] or 0) + 1
      local name = config.tab.name
      if name and name ~= "" then
        vim.api.nvim_tabpage_set_var(tab, name, "@" .. commit.short)
        vim.cmd("redrawtabline")
      end
      -- The tab's own working directory: every tool that asks "where is
      -- the project" -- an explorer, a finder, `:e` with a relative path
      -- -- asks this, and the answer here is the past.
      vim.cmd("tcd " .. vim.fn.fnameescape(dir))
      local file = opts.path and opts.path ~= "" and (dir .. "/" .. opts.path) or nil
      if file and vim.uv.fs_stat(file) then
        vim.cmd("edit " .. vim.fn.fnameescape(file))
        if opts.line then
          pcall(vim.api.nvim_win_set_cursor, 0,
            { math.min(opts.line, vim.api.nvim_buf_line_count(0)), 0 })
          vim.cmd("normal! zz")
        end
      else
        vim.cmd("edit " .. vim.fn.fnameescape(dir))
      end
      label(vim.api.nvim_get_current_win())
      if file and not vim.uv.fs_stat(file) then
        vim.notify("uatis: " .. opts.path .. " did not exist at " .. commit.short,
          vim.log.levels.INFO)
      end
      if opts.on_ready then
        opts.on_ready(tab)
      end
    end

    if users[dir] or vim.uv.fs_stat(dir .. "/.git") then
      return up()
    end
    -- Left behind by a session that did not get to remove it -- a crash,
    -- a kill -- and git still has it on its list. Pruned, so the add
    -- below is not refused for a path git believes is taken.
    vim.fn.delete(dir, "rf")
    vim.fn.mkdir(vim.fs.dirname(dir), "p")
    git.run(root, { "worktree", "prune" }, function()
      -- No hooks: a `post-checkout` that installs dependencies or
      -- rebuilds something is right for a checkout someone will work in,
      -- and seconds of surprise for one opened to be read.
      git.run(root, { "-c", "core.hooksPath=/dev/null", "worktree", "add",
        "--detach", dir, commit.sha }, function(ok, _, why)
        if not ok then
          vim.notify("uatis: could not check out " .. commit.short .. ": "
            .. (vim.trim(why or ""):match("^[^\r\n]*") or ""), vim.log.levels.ERROR)
          return
        end
        up()
      end)
    end)
  end)
end

--- Every at-tab closed and every checkout removed, before the editor
--- goes: see `pane.close_owned`, which is what closes the tabs, since a
--- quit asked from inside one needs its window kept alive.
function M.release_all()
  for tab, at in pairs(tabs) do
    tabs[tab] = nil
    release(at, true)
  end
end

return M
