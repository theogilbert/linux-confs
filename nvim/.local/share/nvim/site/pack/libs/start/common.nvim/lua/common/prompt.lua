-- One line asked for in a float, with the candidates in a menu that
-- comes up as it is typed.
--
-- Not `vim.ui.input`: that is a hook, and half of what replaces it draws
-- a pretty window and drops `completion` -- so a prompt that is nothing
-- but completion (a branch, a label, `HEAD~3`) would be a bare line for
-- exactly the input nobody types from memory. This is a one-line buffer
-- with the menu handed straight to the editor (`complete()`), and
-- everything else left to what typing in a buffer already does.
--
-- One prompt at a time: opening one dismisses the last. `M.win` and
-- `M.buf` are its window and buffer while it is up.

local pane = require("common.pane")

local M = {}

M.win = nil
M.buf = nil

-- What `completeopt` was before a prompt changed it globally (a Neovim
-- that cannot hold it per buffer), the way back to where the cursor
-- was, the answer's and the dismissal's callbacks, the menu, and
-- whether the cursor is away in a window opened over the prompt.
local held, back, answered, cancelled, menu = nil, nil, nil, nil, nil
local away = false

local ns = vim.api.nvim_create_namespace("common_prompt")

--- Puts `completeopt` back, closes the window and hands the cursor back.
--- Safe twice: the second is the autocmd tidying after the key.
local function shut()
  -- Out of insert mode, unconditionally: `startinsert` is granted on the
  -- way back round the loop, so a prompt opened and answered in one
  -- tick is still about to be in insert mode out there.
  vim.cmd("stopinsert")
  if held ~= nil then
    vim.o.completeopt = held
    held = nil
  end
  local w, b = M.win, M.buf
  M.win, M.buf, menu = nil, nil, nil
  if w and vim.api.nvim_win_is_valid(w) then
    pcall(vim.api.nvim_win_close, w, true)
  end
  if b and vim.api.nvim_buf_is_valid(b) then
    pcall(vim.api.nvim_buf_delete, b, { force = true })
  end
  if back then
    back()
    back = nil
  end
end

--- Dismissed: nothing answered, `opts.on_cancel` called.
function M.cancel()
  answered = nil
  local undo = cancelled
  cancelled = nil
  shut()
  if undo then
    undo()
  end
end

--- Answered with what is on the line, trimmed -- after the window has
--- gone and on the next tick, since what a prompt is answered with is
--- often a window of its own, and one opened from inside a float that is
--- closing lands under it.
function M.accept()
  local text = ""
  if M.buf and vim.api.nvim_buf_is_valid(M.buf) then
    text = vim.trim(vim.api.nvim_buf_get_lines(M.buf, 0, 1, false)[1] or "")
  end
  local said = answered
  answered, cancelled = nil, nil
  shut()
  if said then
    vim.schedule(function()
      said(text)
    end)
  end
end

--- Puts the menu up again, for candidates that changed since it opened
--- -- a list that has just arrived. Not while something in it is
--- chosen: a list replaced under the cursor moves what was under it.
function M.refresh()
  if menu then
    menu(true)
  end
end

--- Runs `fn`, which opens a window over the prompt (a help float),
--- without the cursor going to it counting as the prompt left. That
--- window must hand the cursor back when it closes.
function M.over(fn)
  away = true
  fn()
end

-- How many of each kind `rank` shows before anything is typed, and how
-- many at most.
local PER_KIND, LIMIT = 15, 300

local function item_of(item)
  if type(item) == "string" then
    return { word = item }
  end
  return { word = item.word, menu = item.menu, kind = item.kind, abbr = item.abbr }
end

--- `items` for what has been typed, best first: the ones it starts,
--- then the ones that contain it (the half of `feature/the-thing`
--- anyone remembers is after the slash), then the ones whose `menu`
--- does (a commit is found by its subject). With nothing typed, a slice
--- of each `kind`, so three hundred branches do not hide nine tags.
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

--- The completion engines that watch every buffer told this one is not
--- theirs, each in its own spelling: one attached over the menu maps
--- `<CR>` and `<Tab>` over the prompt's.
local function quiet_engines(buf)
  vim.b[buf].completion = false
  vim.b[buf].minicompletion_disable = true
  local cmp = package.loaded["cmp"]
  if cmp and cmp.setup and cmp.setup.buffer then
    pcall(cmp.setup.buffer, { enabled = false })
  end
end

--- Asks for one line; `cb(text)` with the answer, trimmed. Not called
--- where it is dismissed, which is not the same as answered with
--- nothing: `opts.on_cancel` is.
---
--- `opts.title`     -- the window's title, and the whole question
--- `opts.text`      -- what is on the line to start with
--- `opts.items`     -- the menu: a list (strings, or `{ word, menu,
---                     kind, abbr }`) ranked by `M.rank` against the
---                     whole line, or `f(line)` -> items and the column
---                     they replace from (1 if not given)
--- `opts.live`      -- the menu asked for again on every key, up or not,
---                     for `f(line)` items that filter themselves
--- `opts.menu`      -- false for no menu until something is typed
--- `opts.omnifunc`  -- set on the buffer, for `<C-x><C-o>`
--- `opts.on_change` -- `f(line)` on every change
--- `opts.paint`     -- `f(line)` -> `{ { from, to, group } }`, byte
---                     columns from 0: the line coloured as it is typed
--- `opts.on_cancel` -- `f()` where it is dismissed
--- `opts.keys`      -- `{ { lhs, fn } }` in normal mode
--- `opts.normal`    -- an insert-mode key that leaves insert mode
---                     without leaving the prompt
--- `opts.at`        -- `{ row, col, width }` on the editor; centred a
---                     third of the way down otherwise
--- `opts.winhighlight`, `opts.filetype`
function M.open(opts, cb)
  M.cancel()
  opts = opts or {}
  answered = cb
  cancelled = opts.on_cancel
  back = pane.came_from()

  local buf = vim.api.nvim_create_buf(false, true)
  M.buf = buf
  vim.bo[buf].bufhidden = "wipe"
  if opts.filetype then
    vim.bo[buf].filetype = opts.filetype
  end
  if opts.text and opts.text ~= "" then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { opts.text })
  end

  local title = (" %s "):format(opts.title or "")
  local width = math.max(vim.fn.strdisplaywidth(title) + 2, 34)
  width = math.min(width, math.max(vim.o.columns - 4, 10))
  local at = opts.at or {}
  width = at.width or width
  M.win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = 1,
    row = at.row or math.max(math.floor(vim.o.lines / 3), 1),
    col = at.col or math.max(math.floor((vim.o.columns - width) / 2), 0),
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
  })
  vim.wo[M.win].wrap = false
  if opts.winhighlight then
    vim.wo[M.win].winhighlight = opts.winhighlight
  end

  local items = opts.items
  if type(items) == "table" then
    local list = vim.tbl_map(item_of, items)
    items = function(line)
      return M.rank(list, line), 1
    end
  end

  if opts.omnifunc then
    vim.bo[buf].omnifunc = opts.omnifunc
  end
  if items then
    quiet_engines(buf)
  end
  if opts.omnifunc or items then
    -- Per buffer where the editor can hold it there, globally (and put
    -- back) where it cannot. `noselect`: what is typed stays typed until
    -- a key says otherwise.
    local wanted = "menu,menuone,noselect"
    if not pcall(function()
      vim.bo[buf].completeopt = wanted
    end) then
      held = vim.o.completeopt
      vim.o.completeopt = wanted
    end
  end

  if items then
    -- `complete()`, not `<C-x><C-o>` fed: a key in the typeahead is read
    -- whenever the editor gets to it, perhaps after this window has gone.
    menu = function(again)
      if not M.win or vim.api.nvim_get_current_win() ~= M.win or not vim.fn.mode():find("i") then
        return
      end
      if vim.fn.pumvisible() == 1 then
        local chosen = (vim.fn.complete_info({ "selected" }) or {}).selected or -1
        if not again or chosen >= 0 then
          return
        end
      end
      local found, col = items(vim.api.nvim_get_current_line())
      found = found or {}
      -- Empty where it is live puts the last menu away: a menu of what
      -- no longer matches lies.
      if #found > 0 or (opts.live and vim.fn.pumvisible() == 1) then
        pcall(vim.fn.complete, col or 1, found)
      end
    end
    vim.api.nvim_create_autocmd(
      opts.live and { "TextChangedI", "TextChangedP" } or "TextChangedI",
      {
        buffer = buf,
        callback = function()
          if menu then
            menu(opts.live or false)
          end
        end,
      }
    )
    -- The whole list before a key is pressed: the answer to "like
    -- what?". On `InsertEnter`, since `complete()` is refused outside
    -- insert mode and `startinsert` is only granted later.
    if opts.menu ~= false then
      vim.api.nvim_create_autocmd("InsertEnter", {
        buffer = buf,
        once = true,
        callback = function()
          vim.schedule(function()
            if menu then
              menu(false)
            end
          end)
        end,
      })
    end
    vim.keymap.set("i", "<Tab>", function()
      if vim.fn.pumvisible() == 1 then
        return "<C-n>"
      end
      vim.schedule(M.refresh)
      return ""
    end, { buffer = buf, expr = true, nowait = true, silent = true })
    vim.keymap.set("i", "<S-Tab>", function()
      return vim.fn.pumvisible() == 1 and "<C-p>" or ""
    end, { buffer = buf, expr = true, nowait = true, silent = true })
  end

  if opts.paint then
    local function paint()
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
      for _, span in ipairs(opts.paint(line) or {}) do
        pcall(vim.api.nvim_buf_set_extmark, buf, ns, 0, span[1], {
          end_col = math.min(span[2], #line),
          hl_group = span[3],
        })
      end
    end
    paint()
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
      buffer = buf,
      callback = paint,
    })
  end

  if opts.on_change then
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      buffer = buf,
      callback = function()
        opts.on_change(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "")
      end,
    })
  end

  local function map(modes, lhs, fn)
    vim.keymap.set(modes, lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  -- The line as it stands: a word chosen in the menu is on it already.
  map({ "i", "n" }, "<CR>", M.accept)
  if opts.normal and opts.normal ~= "" then
    map("i", opts.normal, function()
      vim.cmd("stopinsert")
    end)
  end
  for _, b in ipairs(opts.keys or {}) do
    if b[1] and b[1] ~= "" then
      map("n", b[1], b[2])
    end
  end
  -- `<Esc>` is the prompt's, menu up or not: taking the menu down first
  -- is a key that seems to do nothing, the menu coming back on the text
  -- `<C-e>` puts back.
  map({ "i", "n" }, "<Esc>", M.cancel)
  map({ "i", "n" }, "<C-c>", M.cancel)
  map("n", "q", M.cancel)

  -- Left is dismissed -- unless for a window opened over it on purpose
  -- (`M.over`), which hands the cursor back.
  away = false
  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
    buffer = buf,
    callback = function()
      if away then
        return
      end
      vim.schedule(function()
        if M.buf == buf then
          M.cancel()
        end
      end)
      return true
    end,
  })
  vim.api.nvim_create_autocmd("WinEnter", {
    buffer = buf,
    callback = function()
      away = false
    end,
  })

  vim.cmd(opts.text and opts.text ~= "" and "startinsert!" or "startinsert")
  return M.win, buf
end

return M
