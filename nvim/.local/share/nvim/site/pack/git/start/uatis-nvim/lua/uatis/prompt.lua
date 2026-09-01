-- A one-line floating prompt, with completion, of our own.
--
-- `vim.ui.input` is the obvious thing to ask for typed input and it is
-- the wrong thing for this one. `completion` is a field a replacement is
-- free to ignore, and the common ones do -- which leaves a bare prompt
-- for exactly the input nobody types from memory: a tag three releases
-- back, a branch someone else named, `HEAD~3`. The one prompt in this
-- plugin that has to complete cannot be the one whose completion is
-- optional, so the window is ours.
--
-- Ours means small: one line in one scratch buffer, a menu of candidates
-- handed in by the caller, and everything else left to what typing in a
-- buffer already does.
--
-- The menu comes up on its own as you type, and `<Tab>` is only there
-- for anyone who reaches for it. Waiting to be asked was the first
-- version and the wrong one: `<Tab>` in insert mode belongs to whichever
-- completion engine the reader installed, and the good ones re-map it
-- buffer-locally on entry -- ours included, and after ours. A prompt
-- whose completion depends on winning that race is a prompt that
-- silently does not complete.

local M = {}

-- Keyed by buffer so `omnifunc`, which is reached through `v:lua` and is
-- handed nothing but the base, can find the candidates for the prompt it
-- is being asked about.
local state = {}

--- One candidate, however the caller spelled it: a bare string, or a
--- table with the text to insert and something to say about it.
local function item_of(item)
  if type(item) == "string" then
    return { word = item }
  end
  return { word = item.word, menu = item.menu, kind = item.kind }
end

--- How many of each kind to show before anything has been typed.
---
--- Not one flat list: git answers about a repository with three hundred
--- branches and nine tags, and a flat list of the first N is three
--- hundred branches -- from which the reader concludes, correctly for
--- what is on screen and wrongly about the prompt, that tags are not
--- offered. A slice of each kind says what there is to type towards.
local PER_KIND = 15
local LIMIT = 300

--- The candidates for what has been typed so far, best first.
---
--- Public because the command line asks the same question of the same
--- candidates and should get the same order: `:Uatis <Tab>` and this
--- prompt disagreeing about which branch comes first is two answers to
--- one question.
---
--- Three tiers. A name the text starts is the name being typed towards.
--- A name that merely contains it comes after -- branches are called
--- `feature/the-thing` and the half anyone remembers is the half after
--- the slash. Last, what the candidate says about itself: a commit is a
--- sha nobody has memorised, so it is found by its subject line.
function M.rank(items, base)
  local out = {}
  if base == "" then
    local seen = {}
    for _, item in ipairs(items) do
      local kind = item.kind or ""
      seen[kind] = (seen[kind] or 0) + 1
      if seen[kind] <= PER_KIND then
        table.insert(out, item)
      end
    end
    return vim.list_slice(out, 1, math.min(#out, LIMIT))
  end

  local lead, rest, said = {}, {}, {}
  local needle = base:lower()
  for _, item in ipairs(items) do
    local at = item.word:lower():find(needle, 1, true)
    if at == 1 then
      table.insert(lead, item)
    elseif at then
      table.insert(rest, item)
    elseif item.menu and item.menu:lower():find(needle, 1, true) then
      table.insert(said, item)
    end
  end
  vim.list_extend(lead, rest)
  vim.list_extend(lead, said)
  return vim.list_slice(lead, 1, math.min(#lead, LIMIT))
end

--- `omnifunc`, reached as `v:lua.require'uatis.prompt'.omnifunc`.
function M.omnifunc(findstart, base)
  local st = state[vim.api.nvim_get_current_buf()]
  if not st then
    return findstart == 1 and -3 or {}
  end
  if findstart == 1 then
    -- The whole line is the answer being typed -- a revision can hold
    -- slashes, dots, carets and tildes, and none of them ends a word
    -- here. Anything narrower would complete `origin/ma` against `ma`.
    return 0
  end
  return M.rank(st.items, base)
end

--- Opens the prompt. `cb(text)` on `<CR>`, `cb(nil)` on anything that
--- leaves it -- `<Esc>`, `<C-c>`, or the cursor going elsewhere.
---
--- opts: { prompt = "...", default = "...", items = { ... } }, where an
--- item is a string, or `{ word = "...", menu = "...", kind = "..." }` --
--- `word` is what is inserted, and the other two are what the menu says
--- about it: a commit's subject line, and whether this is a branch, a
--- tag or a commit.
function M.open(opts, cb)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "uatis-prompt"
  vim.bo[buf].omnifunc = "v:lua.require'uatis.prompt'.omnifunc"
  -- Buffer-local, which `completeopt` has been since 0.12: the menu is
  -- shown without taking a word the reader has not chosen, whatever the
  -- reader's own setting is. `noselect` matters twice over -- with a
  -- selection, moving through the menu writes into the line, which is
  -- another `TextChangedI` and another menu.
  vim.bo[buf].completeopt = "menuone,noselect"
  -- The completion engines that watch every buffer have nothing to say
  -- about a revision, and one of them up over this menu hides it.
  -- `b:completion` is what blink.cmp reads; anything else is welcome to
  -- read it too.
  vim.b[buf].completion = false
  state[buf] = { items = vim.tbl_map(item_of, opts.items or {}) }

  local width = math.max(30, math.min(60, vim.o.columns - 8))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = 1,
    row = math.max(0, math.floor(vim.o.lines / 2) - 2),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "rounded",
    title = " " .. (opts.prompt or "") .. " ",
    title_pos = "center",
  })
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].cursorline = false

  if opts.default and opts.default ~= "" then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { opts.default })
  end

  local done = false
  local function finish(text)
    if done then
      return
    end
    done = true
    state[buf] = nil
    -- Insert mode belongs to the prompt, and closing its window is not
    -- leaving it: without this the reader lands back in their own buffer
    -- typing into it.
    vim.cmd("stopinsert")
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    -- On the next tick: the caller's answer to this is another window --
    -- a notification, a picker, a whole review -- and it should not be
    -- opened from inside the closing of this one.
    vim.schedule(function()
      cb(text)
    end)
  end

  --- `<CR>` is one keystroke whether or not the menu is up: the entry
  --- under the cursor if there is one, and what was typed if there is
  --- not. Taking the entry by hand rather than by feeding `<C-y>` is what
  --- makes that one keystroke -- `<C-y>` over an unselected menu only
  --- closes it, and the reader presses Enter twice for a prompt they
  --- already answered.
  local function accept()
    local info = vim.fn.complete_info({ "selected", "items" })
    local selected = info.selected or -1
    local text
    if selected >= 0 and info.items and info.items[selected + 1] then
      text = info.items[selected + 1].word
    else
      text = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
    end
    text = vim.trim(text)
    finish(text ~= "" and text or nil)
  end

  -- The menu, as you type. `complete()` rather than feeding
  -- `<C-x><C-o>`: it is the same list `omnifunc` would answer with, put
  -- up without going back through a keymap that may no longer be ours.
  vim.api.nvim_create_autocmd("TextChangedI", {
    buffer = buf,
    callback = function()
      -- Not while the menu is up: it filters itself as the line grows,
      -- and replacing it mid-session would drop whatever is selected.
      if vim.fn.pumvisible() == 1 then
        return
      end
      local line = vim.api.nvim_get_current_line()
      local found = M.rank(state[buf] and state[buf].items or {}, line)
      if #found > 0 then
        pcall(vim.fn.complete, 1, found)
      end
    end,
  })

  vim.keymap.set("i", "<Tab>", function()
    return vim.fn.pumvisible() == 1 and "<C-n>" or "<C-x><C-o>"
  end, { buffer = buf, expr = true })
  for _, mode in ipairs({ "i", "n" }) do
    vim.keymap.set(mode, "<CR>", accept, { buffer = buf })
    -- `<Esc>` means the prompt, not the menu, whether or not the menu
    -- happens to be up. Taking the menu down first is the version every
    -- other buffer has, and here it is a key that appears to do nothing:
    -- the menu is opened by the text changing, and `<C-e>` puts the
    -- typed text back, which is a text change, which opens it again.
    -- One key, one meaning -- and the menu goes with the window.
    vim.keymap.set(mode, "<Esc>", function()
      finish(nil)
    end, { buffer = buf })
    vim.keymap.set(mode, "<C-c>", function()
      finish(nil)
    end, { buffer = buf })
  end

  -- Leaving the window is cancelling: a one-line prompt nobody is
  -- looking at is a window that has to be closed by hand later.
  vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave" }, {
    buffer = buf,
    once = true,
    callback = function()
      finish(nil)
    end,
  })

  vim.cmd("startinsert!")
  return win
end

return M
