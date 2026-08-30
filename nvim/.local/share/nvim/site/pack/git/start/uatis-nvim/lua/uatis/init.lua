-- What a user touches: one command, four functions, two mappings.
--
--   :Uatis [<gitref>]         annotate this buffer against a revision
--   require("uatis").setup([opts])
--   require("uatis").toggle_diff()
--   require("uatis").set_base_branch([name])
--   require("uatis").toggle_pane() / open_pane() / close_pane()
--
-- The command and the functions are not two ways to do one thing. A
-- command is what you type when you know the ref you want and you are
-- typing anyway; a function is what a keymap calls, and reviewing your
-- own branch is something you do a hundred times a day.

local config = require("uatis.config")
local base = require("uatis.base")
local git = require("uatis.git")
local overlay = require("uatis.overlay")
local pane = require("uatis.pane")
local view = require("uatis.view")

local M = {}

-- Neovim 0.12 is the floor, and it is a real one rather than caution: the
-- rendering leans on `virt_lines` with `leftcol`, inline virtual text,
-- multiline `hl_eol` ranges, `statuscolumn`, `nvim_win_text_height` and
-- `vim.uv`. On anything older this does not degrade, it errors.
local FLOOR = { 0, 12, 0 }

local function supported()
  local v = vim.version()
  return vim.version.ge({ v.major, v.minor, v.patch }, FLOOR)
end

--- The changed-file list, once the view is up.
---
--- Read either way, and shown when `config.pane.auto_open` says so: the
--- list is what a review is made of, not merely a window onto one. It
--- holds which files the branch touched and the revision they are measured
--- against, it is what `]f` steps, and it is what annotates the next file
--- you open. `auto_open` decides whether you are looking at it.
---
--- "What have I changed" is a question about the branch, not about one
--- file, and the answer to "which file next" should be on screen before
--- you ask it. Passed to the view as `on_open` rather than called after
--- it: opening a view is two git subprocesses deep, and the pane takes
--- its revision from a view that does not exist yet.
local function follow_up()
  if pane.get() then
    return
  end
  if config.pane.auto_open then
    pane.open({ focus = false })
  else
    pane.list()
  end
end

--- Annotates the current buffer against `ref`, or against the base branch
--- when none is given -- which is the answer to "what have I changed", and
--- what you want often enough that typing a ref for it is a tax.
function M.run(opts)
  local args = opts.fargs or {}
  if #args > 1 then
    vim.notify("uatis: :Uatis [<gitref>]", vim.log.levels.ERROR)
    return
  end
  if #args == 0 then
    return M.toggle_diff()
  end
  -- Nothing here to annotate -- a scratch buffer, a terminal, the empty
  -- buffer nvim started in -- but the question is still a good one, and
  -- the file list answers it. Pick a file from it and you are in a view.
  if not view.can_open() then
    return pane.open({ resolve = view.ref_resolver(args[1]) })
  end
  view.open(args[1], { on_open = follow_up })
end

--- Everything already open against the base branch, re-pointed at the
--- fork point it now means.
---
--- Resolved once and handed to both, rather than letting each view and
--- each list work it out for itself: one choice of base branch is one
--- fork point, and two answers to that question on screen at once is the
--- disagreement this plugin exists not to have.
---
--- Views named by hand -- `:Uatis <gitref>` -- are left alone. They were
--- pointed at a revision by someone who meant that revision.
local function repoint(root)
  base.resolve(root, function(label, sha)
    if label and sha then
      view.repoint(root, label, sha)
      pane.repoint(root, label, sha)
    end
  end)
end

--- Chooses the branch every diff view measures against.
---
--- With a name, sets it. Without one, asks through `vim.ui.select` --
--- whatever picker the user already has. Until it is called the base
--- branch is detected: `origin/HEAD`, then the conventional names in
--- `config.base.fallbacks`, so on almost every repository it never has to
--- be called at all.
---
--- One choice per repository, held for the editing session -- and what is
--- on screen follows it. Choosing a base branch is choosing what you are
--- reviewing against, and a view that went on measuring against the last
--- one until you closed and reopened it would be answering the question
--- you stopped asking.
function M.set_base_branch(name)
  base.select(name, function(picked, root)
    if picked then
      repoint(root)
    end
  end)
end

--- Starts a review of the branch, or ends the one that is running.
---
--- The buffer stays yours -- same window, same undo history, still
--- writable -- and what it replaced is drawn around it, or beside it. The
--- comparison is against `merge-base(base branch, HEAD)`, so it says "what
--- have I changed since I branched" and goes on saying it when someone
--- else pushes to the base branch.
---
--- A review, and not one annotated buffer, because that is the unit the
--- reader is working in: while it is on, every file of the branch you open
--- is annotated as you arrive -- through the list, through `gd`, through a
--- picker -- and this key turns all of it off again in one press.
function M.toggle_diff()
  local bufnr = vim.api.nvim_get_current_buf()
  local current = view.get(bufnr)
  if current then
    view.stop(current)
    return false
  end
  -- No file here to annotate: the list is the whole answer, and toggling
  -- it is what the key means from a buffer that has nothing to compare.
  if not view.can_open(bufnr) then
    if pane.get() then
      pane.close()
      return false
    end
    pane.open()
    return true
  end
  -- A review already running takes this file in at ITS revision, rather
  -- than working out a second one that could differ by whatever landed in
  -- between.
  if pane.include(bufnr, vim.api.nvim_get_current_win()) then
    return true
  end
  view.open(nil, { resolve = base.resolve, tracks_base = true, on_open = follow_up })
  return true
end

--- Opens the side pane on its own, for when `auto_open` is off or it has
--- been closed. A no-op when the current buffer has no diff view: the
--- pane takes what it lists, and the revision it lists against, from
--- that view.
function M.open_pane()
  return pane.open()
end

--- Puts the window away again. `q` in the pane does this too; a mapping
--- that opens something wants a mapping that shuts it.
---
--- The window, not the review: the list goes on listing, `]f` goes on
--- stepping it and the files you open go on being annotated. `toggle_diff`
--- is what ends a review.
function M.close_pane()
  return pane.hide()
end

--- Both of those on one key, which is what `keys.view.files` is bound to:
--- a window you asked for is a window you can ask to go away again,
--- without having to remember which of the two you are looking at. From
--- outside the list it puts you in it rather than closing it -- see
--- `pane.toggle`.
function M.toggle_pane()
  return pane.toggle()
end

--- Completion for `:Uatis`. Refs are fetched asynchronously and cached on
--- first use, so the very first <Tab> may offer nothing and the next one
--- offers everything -- better than blocking the UI on a subprocess
--- mid-keystroke.
local ref_cache = nil

local function refs()
  if ref_cache == nil then
    ref_cache = {}
    git.root(vim.fn.getcwd(), function(root)
      if root then
        git.refs(root, function(list)
          ref_cache = list
        end)
      end
    end)
  end
  return ref_cache
end

function M.complete(arg_lead)
  return vim.tbl_filter(function(s)
    return s:find(arg_lead, 1, true) == 1
  end, refs())
end

--- The global mappings, from `config.keys.global`.
---
--- Global rather than buffer-local because of when they are pressed: you
--- pick a base branch and turn a diff view on from a buffer that has
--- nothing to do with uatis yet, so there is no buffer for the plugin to
--- have attached anything to. An entry set to `false` is skipped, for
--- anyone who would rather bind the functions themselves.
---
--- What the last call bound is deleted first, because `setup` runs twice
--- on a normal install: `plugin/uatis.lua` sources with the defaults and
--- the user's own call arrives after it. Rebinding without undoing would
--- leave a default still mapped after it had been turned off -- which is
--- the one outcome someone setting a key to `false` is trying to avoid.
local mapped = {}

local function setup_keymaps()
  for _, lhs in ipairs(mapped) do
    pcall(vim.keymap.del, "n", lhs)
  end
  mapped = {}

  local k = config.keys.global
  local mappings = {
    { lhs = k.base_branch, rhs = M.set_base_branch, desc = "uatis: set the base branch" },
    { lhs = k.toggle_diff, rhs = M.toggle_diff, desc = "uatis: toggle the diff view" },
    { lhs = k.open_pane, rhs = M.open_pane, desc = "uatis: open the changed-file pane" },
  }
  for _, m in ipairs(mappings) do
    if m.lhs and m.lhs ~= "" then
      vim.keymap.set("n", m.lhs, m.rhs, { silent = true, desc = m.desc })
      table.insert(mapped, m.lhs)
    end
  end
end

--- Folds `opts` into `config`, in place.
---
--- In place, and not `tbl_deep_extend` into a new table, because every
--- module took its reference to that table at require time: a replacement
--- would leave all of them still reading the defaults.
---
--- Whether a table is merged into or replaced is decided by the DEFAULT
--- and not by what the user wrote. A default that is a list is replaced
--- whole: `base.fallbacks = { "main" }` names the branches to try, and
--- merging it into `{ "develop", "master", "main" }` by index would answer
--- with `{ "main", "master", "main" }` -- an order nobody asked for, and
--- `fallbacks = {}` would mean nothing at all. A default that is a table
--- of named settings is merged into, so `keys = { global = {} }` changes
--- no keys rather than removing every one of them.
---
--- A key the defaults do not have is a typo, and saying so is the only
--- useful thing to do with one: accepted in silence it looks like a
--- setting that had no effect, which is where the next hour goes.
local function merge(into, from, path)
  for key, v in pairs(from) do
    local at = path and (path .. "." .. tostring(key)) or tostring(key)
    if into[key] == nil then
      vim.notify("uatis: unknown option '" .. at .. "'", vim.log.levels.WARN)
    elseif type(v) == "table" and type(into[key]) == "table"
      and not vim.islist(into[key]) then
      merge(into[key], v, at)
    else
      into[key] = v
    end
  end
end

--- Applies `opts` over `config`, then installs the command's neighbours:
--- the global keys and the highlight groups.
---
--- Called for you by `plugin/uatis.lua`, so the plugin works with nothing
--- in your config at all. Calling it yourself with a table is how you
--- change anything -- naming only the keys you mean, at any depth:
---
---   require("uatis").setup({
---     keys = { global = { toggle_diff = "<leader>dr", base_branch = false } },
---     pane = { auto_open = false },
---     diff = { default_backend = "line" },
---   })
---
--- Safe to call more than once, and expected to be: the second call is the
--- user's, arriving after the one that ran with the defaults, and it
--- re-points the mappings rather than adding to them.
function M.setup(opts)
  if opts ~= nil then
    if type(opts) ~= "table" then
      vim.notify("uatis: setup() takes a table of options", vim.log.levels.ERROR)
      return
    end
    merge(config, opts)
  end

  if not supported() then
    vim.notify(
      ("uatis: needs Neovim %d.%d or newer"):format(FLOOR[1], FLOOR[2]),
      vim.log.levels.ERROR)
    return
  end

  local group = vim.api.nvim_create_augroup("Uatis", { clear = true })
  setup_keymaps()
  overlay.setup_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = overlay.setup_highlights,
  })
end

return M
