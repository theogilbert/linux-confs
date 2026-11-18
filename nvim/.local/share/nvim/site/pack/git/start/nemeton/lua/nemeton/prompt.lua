-- One word, asked for in a window of this plugin's own.
--
-- `vim.ui.input` is a hook, and that is the whole of the trouble with
-- it. Half the plugins that replace it draw a pretty window and quietly
-- drop `completion` -- so a prompt that says "<Tab> completes" is a
-- prompt where <Tab> does nothing, and a reader who typed `thu` at it
-- gets no list, no picture and no reason. There is no way to ask an
-- implementation whether it kept the promise, and no way to find out
-- afterwards either: what comes back is a string in both cases.
--
-- So the prompts in this plugin that are nothing *but* completion do not
-- go through the hook. This is a one-line buffer in a float with the
-- candidates behind it and the menu coming up as it is typed -- which is
-- the composer's completion in a window the size of the answer, and the
-- same argument: this plugin has no dependencies and is not about to
-- grow one over a menu.
--
-- `completeopt` globally, and put back on the way out -- which the
-- composer refuses to do and is right to. A composer is open for
-- minutes while you read other buffers, and a global option changed
-- under those is a plugin reaching outside its own window. This is open
-- for one word and closes the moment the cursor leaves it: there is no
-- other buffer to be wrong in. That is what makes the menu work on a
-- Neovim that cannot hold the option for one buffer.

local config = require("nemeton.config")
local win = require("nemeton.win")

local M = {}

M.win = nil
M.buf = nil

-- What the editor said before the window took it, and the way back to
-- where the cursor was. Both nil while nothing is open.
local held = nil
local back = nil
-- Called with the answer, or with nothing where the prompt was
-- dismissed. Held here rather than in a closure so that `M.close` can
-- be the one place both endings go through.
local answered = nil
-- Whether the cursor is away in a window opened over the prompt
-- (`M.over`), which is not the prompt being left.
local away = false
-- The one that puts the menu up, kept so that a caller whose list has
-- changed since the window opened can ask for it again. See
-- `M.refresh`.
local menu = nil
-- Called where the prompt is dismissed rather than answered, for the
-- caller that changed something while it was being typed into and has
-- to put it back. See `opts.on_cancel`.
local cancelled = nil

--- Puts `completeopt` back, closes the window, and hands the cursor to
--- wherever it came from.
---
--- Safe to call twice: the second time there is nothing open and it is
--- the autocommand tidying up after the keymap that already did it.
local function shut()
  -- Out of insert mode first. The window is left from a mapping pressed
  -- while typing in it, and closing it there hands the cursor back to
  -- whatever it came from -- which is a file being reviewed, or one of
  -- this plugin's own windows with 'modifiable' off. Insert mode in
  -- either is a keystroke going somewhere nobody meant.
  -- Unconditionally, and not behind a `mode()` check: `startinsert` is
  -- a request the editor grants on its way back round the loop, so a
  -- prompt opened and answered inside one tick is still in normal mode
  -- here and is still about to be in insert mode out there.
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

--- Dismissed: nothing is answered, and nothing happens but what the
--- caller asked to have happen on the way out (`opts.on_cancel`).
function M.cancel()
  answered = nil
  local undo = cancelled
  cancelled = nil
  shut()
  if undo then
    undo()
  end
end

--- Accepted: what is on the line, with the spaces off both ends.
---
--- The answer is handed over *after* the window has gone, and on the
--- next tick: half of what a prompt is answered with opens a window of
--- its own, and one opened from inside a float that is still closing
--- lands underneath it.
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

--- Puts the menu up again, for a caller whose candidates have changed
--- since the window opened.
---
--- Which is what a prompt shown before its list has arrived needs: it
--- comes up on whatever was written down last time |nemeton-open|, the
--- forge answers a moment later, and the menu under the cursor should
--- then be the answer rather than the memory. Nothing happens if the
--- prompt has been dismissed, if the reader has left it, or if they are
--- already walking the list -- moving what is under somebody's cursor
--- is worse than a menu one keystroke out of date.
function M.refresh()
  if menu then
    menu(true)
  end
end

--- Runs `fn`, which opens a window over the prompt -- a help float --
--- without the cursor going to it counting as the prompt left. The
--- window must hand the cursor back when it closes, as `detail.float`
--- does.
function M.over(fn)
  away = true
  fn()
end

--- Asks for one word.
---
---   `title`     what the window is called, and the whole of the
---               question: there is no room for a sentence and the
---               menu answers "like what?" better than one would.
---   `omnifunc`  the `v:lua...` string the buffer completes through,
---               for the reader who reaches for `<C-x><C-o>`.
---   `items`     `f(line)` -> the completion items to put up as it is
---               typed, and the column they replace from (the first,
---               where it gives none). The menu is this rather than the
---               `omnifunc`, because a menu that comes up on its own has
---               to be handed to the editor and not typed at it.
---   `live`      the menu asked for again on every key, menu up or
---               not, for `items` that filter by themselves -- each
---               item `equal` so the editor does not narrow it again.
---   `menu`      `false` for no list until something has been typed.
---   `text`      what is in it to start with, if anything.
---   `on_change` `f(line)`, on every change to what is typed: for the
---               prompt whose answer is acted on as it is typed -- a
---               search, narrowing a list under it.
---   `paint`     `f(line)` -> `{ { from, to, group } }`, byte columns
---               from 0 with `to` exclusive: what is typed coloured as
---               it is typed, for a prompt whose words mean something
---               -- a search's filters.
---   `on_cancel` `f()`, where it is dismissed: what puts back what
---               `on_change` changed.
---   `keys`      `{ { lhs, fn, desc } }`, bound in normal mode: what the
---               box does besides being answered. `fn` may open a
---               window over it (`M.over`).
---   `at`        `{ row, col, width }` on the editor, for a prompt that
---               belongs to a window of its own and sits over it rather
---               than in the middle of the screen.
---
--- `cb` is called with the answer, and not at all where the prompt was
--- dismissed -- which is a different thing from being answered with
--- nothing, and the difference is whether anything should happen.
function M.open(opts, cb)
  M.cancel()
  opts = opts or {}
  answered = cb
  cancelled = opts.on_cancel
  back = win.came_from()

  M.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[M.buf].bufhidden = "wipe"
  if opts.text and opts.text ~= "" then
    vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, { opts.text })
  end

  local title = (" %s "):format(opts.title or "")
  -- Wide enough for the title and for a name longer than any of them,
  -- and never wider than the editor.
  local width = math.max(vim.fn.strdisplaywidth(title) + 2, 34)
  width = math.min(width, math.max(vim.o.columns - 4, 10))
  local at = opts.at or {}
  width = at.width or width
  M.win = vim.api.nvim_open_win(M.buf, true, {
    relative = "editor",
    width = width,
    height = 1,
    row = at.row or math.max(math.floor(vim.o.lines / 3), 1),
    col = at.col or math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
  })
  -- The same reason every other window here does it: the grounds and
  -- bands this plugin mixes are measured against `Normal`, and a float
  -- drawn on `NormalFloat` lifts them off a background they were not
  -- measured against. See `nemeton.notes`.
  vim.wo[M.win].winhighlight = "NormalFloat:Normal"
  vim.wo[M.win].wrap = false

  if opts.omnifunc then
    -- On the buffer as well as in `opts.items`, so that `<C-x><C-o>` is
    -- there for a reader who reaches for it and so that anybody with a
    -- completion engine has something to point it at.
    vim.bo[M.buf].omnifunc = opts.omnifunc
  end
  if opts.items then
    -- The menu here is this window's own, and a completion engine that
    -- also attaches to it maps `<CR>` and `<Tab>` over the ones below:
    -- nvim-cmp's `<CR>`, finding no menu of its own, hands the key to
    -- the editor's -- which takes the name chosen and nothing else, so
    -- that the next press is read as half a name typed and puts down a
    -- comma rather than answering. So the engines are told this buffer
    -- is not theirs, in each one's own spelling: `b:completion` is
    -- blink.cmp's (and the convention configs copy), the other mini's,
    -- and nvim-cmp's is a setting of the buffer it is current in.
    vim.b[M.buf].completion = false
    vim.b[M.buf].minicompletion_disable = true
    local cmp = package.loaded["cmp"]
    if cmp and cmp.setup and cmp.setup.buffer then
      pcall(cmp.setup.buffer, { enabled = false })
    end
  end
  if opts.omnifunc or opts.items then
    -- Buffer-local where the editor can hold it there (0.11 and newer),
    -- and globally where it cannot -- put back by `shut`. `noselect`
    -- because a menu that picks the first name for you is worse than no
    -- menu: what is typed stays typed until a key says otherwise.
    local wanted = "menu,menuone,noselect"
    if not pcall(function()
      vim.bo[M.buf].completeopt = wanted
    end) then
      held = vim.o.completeopt
      vim.o.completeopt = wanted
    end
  end
  if opts.items then
    --- The menu, put up over the whole line.
    ---
    --- `complete()` and not `<C-x><C-o>` fed to the editor. Those are
    --- two keys that mean "complete" only in insert mode -- read
    --- anywhere else they are "take one off the number under the
    --- cursor" and "open a line below and start typing" -- and a key put
    --- into the typeahead is a key read whenever the editor gets round
    --- to it, which may be after this window has closed and in whatever
    --- buffer was under it. Nothing is fed here at all: the list is
    --- handed straight to the editor, and if this is not the moment for
    --- one then nothing happens.
    --- `again` is the caller that has more to offer than it had when
    --- the menu went up -- a list that has just arrived from a forge --
    --- and is the one case worth interrupting a menu already on the
    --- screen for. Never while something in it has been chosen: a list
    --- replaced under a reader walking through it moves what was under
    --- their cursor, which is worse than an answer they have to ask for
    --- again.
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
      local items, col = opts.items(vim.api.nvim_get_current_line())
      items = items or {}
      -- An empty list where it is live puts the last one away: a menu
      -- of what no longer matches is a menu that lies.
      if #items > 0 or (opts.live and vim.fn.pumvisible() == 1) then
        -- From the first column unless told otherwise: the whole line
        -- is the word.
        pcall(vim.fn.complete, col or 1, items)
      end
    end
    -- `TextChangedP` too where it is live: typed with the menu up is
    -- the editor's event and not `TextChangedI`, and the editor's own
    -- narrowing is by the start of a word, not the search asked for.
    vim.api.nvim_create_autocmd(
      opts.live and { "TextChangedI", "TextChangedP" } or "TextChangedI",
      {
        buffer = M.buf,
        desc = "nemeton: what the word being typed can turn into",
        callback = function()
          menu(opts.live or false)
        end,
      }
    )
    -- ...and the whole list before a key is pressed at all, which is the
    -- answer to "like what?" and half the reason this window exists.
    -- On `InsertEnter` rather than here, because `startinsert` below is
    -- a request the editor grants on its way back round the loop and
    -- `complete()` is refused everywhere but insert mode.
    if opts.menu ~= false then
      vim.api.nvim_create_autocmd("InsertEnter", {
        buffer = M.buf,
        once = true,
        desc = "nemeton: the whole list, before a key is pressed",
        callback = function()
          vim.schedule(function()
            -- Unless it was answered in the meantime.
            if menu then
              menu(false)
            end
          end)
        end,
      })
    end
  end

  if opts.paint then
    local ns = vim.api.nvim_create_namespace("nemeton-prompt")
    local function paint()
      local line = vim.api.nvim_buf_get_lines(M.buf, 0, 1, false)[1] or ""
      vim.api.nvim_buf_clear_namespace(M.buf, ns, 0, -1)
      for _, span in ipairs(opts.paint(line) or {}) do
        pcall(vim.api.nvim_buf_set_extmark, M.buf, ns, 0, span[1], {
          end_col = math.min(span[2], #line),
          hl_group = span[3],
        })
      end
    end
    paint()
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
      buffer = M.buf,
      desc = "nemeton: what is typed, coloured as it is typed",
      callback = paint,
    })
  end

  if opts.on_change then
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      buffer = M.buf,
      desc = "nemeton: what is typed, acted on as it is typed",
      callback = function()
        opts.on_change(vim.api.nvim_buf_get_lines(M.buf, 0, 1, false)[1] or "")
      end,
    })
  end

  local function map(modes, lhs, fn)
    vim.keymap.set(modes, lhs, fn, { buffer = M.buf, nowait = true, silent = true })
  end
  -- `<CR>` takes the line as it stands. Where the menu is up with
  -- something chosen in it, that word is already on the line -- which
  -- is what choosing did -- so there is one rule and not two.
  map({ "i", "n" }, "<CR>", M.accept)
  local normal = config.keys.prompt and config.keys.prompt.normal
  if normal and normal ~= "" then
    map("i", normal, function()
      vim.cmd("stopinsert")
    end)
  end
  for _, b in ipairs(opts.keys or {}) do
    if b[1] and b[1] ~= "" then
      map("n", b[1], b[2])
    end
  end
  map({ "i", "n" }, "<Esc>", M.cancel)
  map({ "i", "n" }, "<C-c>", M.cancel)
  map("n", "q", M.cancel)
  -- A prompt the cursor has left is a prompt nobody is answering, and
  -- one left open behind a window is a keymap waiting for a buffer that
  -- is no longer on the screen.
  --
  -- Unless it was left for a window opened over it on purpose -- a
  -- help float -- which hands the cursor back when it closes.
  away = false
  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
    buffer = M.buf,
    desc = "nemeton: a prompt the cursor has left",
    callback = function()
      if away then
        return
      end
      vim.schedule(M.cancel)
      return true
    end,
  })
  vim.api.nvim_create_autocmd("WinEnter", {
    buffer = M.buf,
    desc = "nemeton: back from a window opened over the prompt",
    callback = function()
      away = false
    end,
  })

  vim.cmd(opts.text and opts.text ~= "" and "startinsert!" or "startinsert")
end

--- The names on a line of them, comma-separated: trimmed, each once,
--- in the order written.
function M.names(line)
  local out, seen = {}, {}
  for part in (line or ""):gmatch("[^,]+") do
    local n = vim.trim(part)
    if n ~= "" and not seen[n] then
      seen[n] = true
      table.insert(out, n)
    end
  end
  return out
end

--- The name being typed on a line of them with the cursor after byte
--- `col`: what follows the last comma before the cursor, the column
--- it starts in (which the menu replaces from), and `col`.
function M.typing(line, col)
  local before = line:sub(1, col)
  local start = (before:match("^.*(),") or 1)
  start = start + #before:sub(start):match("^,?%s*")
  return before:sub(start), start, col
end

--- The menu for that line: of `drawn` -- `{ { name =, text = } }` --
--- the ones not on it already, narrowed fuzzily by what is being typed
--- against what is drawn; and the column it replaces from.
function M.offered(drawn, line, col)
  local typed, start = M.typing(line, col)
  local on = {}
  for _, n in ipairs(M.names(line:sub(1, start - 1) .. line:sub(col + 1))) do
    on[n] = true
  end
  local left = vim.tbl_filter(function(d)
    return not on[d.name]
  end, drawn)
  if typed ~= "" then
    left = vim.fn.matchfuzzy(left, typed, { key = "text" })
  end
  return vim.tbl_map(function(d)
    return { word = d.name, abbr = d.text, equal = 1 }
  end, left),
    start
end

--- Asks for several of `opts.names`, on one line, comma-separated.
---
--- In place of a list ticked one name a round trip: a project's labels
--- or members are a hundred names, and finding one is a search, which
--- a picker the size of the list is bad at and a line with a menu
--- under it is what the composer's `@` already is. The menu is the
--- names not on the line yet, narrowed fuzzily by the one being typed
--- -- against what is drawn, so a member is found by their full name
--- as well. `<Tab>` and `<S-Tab>` walk it; `<CR>` on the menu puts
--- that name on the line (the first match, where none is chosen) and
--- starts the next; `<CR>` with nothing typed and nothing chosen is
--- the answer.
--- `<Esc>` changes nothing.
---
---   `title`   what is being chosen
---   `names`   what can be
---   `chosen`  what is on the line to begin with
---   `shown`   `f(name)` -> what the menu draws for it, where that is
---             more than the name
---
--- `cb(set)` with the names on the line when it is answered: what was
--- typed as well as what was picked, since a label can be new and a
--- caller with a fixed set knows which of its own it has.
function M.many(opts, cb)
  local names, shown = opts.names or {}, opts.shown or function(n)
    return n
  end
  local drawn = {}
  for _, n in ipairs(names) do
    table.insert(drawn, { name = n, text = shown(n) })
  end
  local function cursor(line)
    return M.win and vim.api.nvim_win_get_cursor(M.win)[2] or #line
  end
  local function typing(line)
    return M.typing(line, cursor(line))
  end
  local function items(line)
    return M.offered(drawn, line, cursor(line))
  end

  local chosen = opts.chosen or {}
  M.open({
    title = opts.title,
    text = #chosen > 0 and (table.concat(chosen, ", ") .. ", ") or "",
    items = items,
    live = true,
    at = { width = math.min(72, math.max(vim.o.columns - 4, 10)) },
  }, function(line)
    cb(M.names(line))
  end)

  local function expr(lhs, fn)
    vim.keymap.set("i", lhs, fn, { buffer = M.buf, expr = true, nowait = true, silent = true })
  end
  expr("<CR>", function()
    if vim.fn.pumvisible() == 1 then
      local chosen_now = (vim.fn.complete_info({ "selected" }) or {}).selected or -1
      if chosen_now >= 0 then
        return "<C-y>, "
      end
      -- The menu is up after every name, so it being up is not a
      -- question asked: half a name typed is.
      if vim.trim(typing(vim.api.nvim_get_current_line())) ~= "" then
        return "<C-n><C-y>, "
      end
    end
    -- Out of the mapping first: an answer opens and closes windows,
    -- which the editor refuses from inside one that returns keys.
    vim.schedule(M.accept)
    return ""
  end)
  expr("<Tab>", function()
    if vim.fn.pumvisible() == 1 then
      return "<C-n>"
    end
    vim.schedule(M.refresh)
    return ""
  end)
  expr("<S-Tab>", function()
    return vim.fn.pumvisible() == 1 and "<C-p>" or ""
  end)
end

return M
