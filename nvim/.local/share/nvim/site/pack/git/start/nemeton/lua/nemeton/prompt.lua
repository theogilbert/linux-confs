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
-- The one that puts the menu up, kept so that a caller whose list has
-- changed since the window opened can ask for it again. See
-- `M.refresh`.
local menu = nil

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

--- Dismissed: nothing is answered and nothing happens.
function M.cancel()
  answered = nil
  shut()
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
  answered = nil
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

--- Asks for one word.
---
---   `title`     what the window is called, and the whole of the
---               question: there is no room for a sentence and the
---               menu answers "like what?" better than one would.
---   `omnifunc`  the `v:lua...` string the buffer completes through,
---               for the reader who reaches for `<C-x><C-o>`.
---   `items`     `f(line)` -> the completion items to put up as it is
---               typed. The menu is this rather than the `omnifunc`,
---               because a menu that comes up on its own has to be
---               handed to the editor and not typed at it.
---   `menu`      `false` for no list until something has been typed.
---   `text`      what is in it to start with, if anything.
---
--- `cb` is called with the answer, and not at all where the prompt was
--- dismissed -- which is a different thing from being answered with
--- nothing, and the difference is whether anything should happen.
function M.open(opts, cb)
  M.cancel()
  opts = opts or {}
  answered = cb
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
  M.win = vim.api.nvim_open_win(M.buf, true, {
    relative = "editor",
    width = width,
    height = 1,
    row = math.max(math.floor(vim.o.lines / 3), 1),
    col = math.floor((vim.o.columns - width) / 2),
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
      local items = opts.items(vim.api.nvim_get_current_line()) or {}
      if #items > 0 then
        -- From the first column: the whole line is the word.
        pcall(vim.fn.complete, 1, items)
      end
    end
    vim.api.nvim_create_autocmd("TextChangedI", {
      buffer = M.buf,
      desc = "nemeton: what the word being typed can turn into",
      callback = function()
        menu(false)
      end,
    })
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
            menu(false)
          end)
        end,
      })
    end
  end

  local function map(modes, lhs, fn)
    vim.keymap.set(modes, lhs, fn, { buffer = M.buf, nowait = true, silent = true })
  end
  -- `<CR>` takes the line as it stands. Where the menu is up with
  -- something chosen in it, that word is already on the line -- which
  -- is what choosing did -- so there is one rule and not two.
  map({ "i", "n" }, "<CR>", M.accept)
  map({ "i", "n" }, "<Esc>", M.cancel)
  map({ "i", "n" }, "<C-c>", M.cancel)
  map("n", "q", M.cancel)
  -- A prompt the cursor has left is a prompt nobody is answering, and
  -- one left open behind a window is a keymap waiting for a buffer that
  -- is no longer on the screen.
  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
    buffer = M.buf,
    once = true,
    desc = "nemeton: a prompt the cursor has left",
    callback = function()
      vim.schedule(M.cancel)
    end,
  })

  vim.cmd(opts.text and opts.text ~= "" and "startinsert!" or "startinsert")
end

return M
