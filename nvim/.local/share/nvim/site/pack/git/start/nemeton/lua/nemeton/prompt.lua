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
-- The window itself is common.prompt, shared with the author's other
-- plugins; what is here is nemeton's: its colours, its keys, and the
-- several-names prompt (`M.many`).
--
-- `completeopt` globally on a Neovim that cannot hold it for one buffer,
-- and put back on the way out -- which the composer refuses to do and is
-- right to. A composer is open for minutes while you read other buffers;
-- this is open for one word and closes the moment the cursor leaves it.

local config = require("nemeton.config")
local common = require("common.prompt")

local M = {}

-- `M.win` and `M.buf`: the prompt's window and buffer while it is up.
setmetatable(M, {
  __index = function(_, k)
    if k == "win" or k == "buf" then
      return common[k]
    end
  end,
})

--- Dismissed: nothing is answered, and nothing happens but what the
--- caller asked to have happen on the way out (`opts.on_cancel`).
M.cancel = common.cancel

--- Accepted: what is on the line, with the spaces off both ends -- handed
--- over after the window has gone, and on the next tick.
M.accept = common.accept

--- Puts the menu up again, for a caller whose candidates have changed
--- since the window opened: a prompt shown before its list has arrived
--- comes up on whatever was written down last time |nemeton-open|, and
--- the forge answers a moment later.
M.refresh = common.refresh

--- Runs `fn`, which opens a window over the prompt -- a help float --
--- without the cursor going to it counting as the prompt left. The
--- window must hand the cursor back when it closes, as `detail.float`
--- does.
M.over = common.over

--- Asks for one word (common.prompt).
---
---   `title`     what the window is called, and the whole of the
---               question: there is no room for a sentence and the
---               menu answers "like what?" better than one would.
---   `omnifunc`  the `v:lua...` string the buffer completes through,
---               for the reader who reaches for `<C-x><C-o>`.
---   `items`     `f(line)` -> the completion items to put up as it is
---               typed, and the column they replace from (the first,
---               where it gives none).
---   `live`      the menu asked for again on every key, menu up or
---               not, for `items` that filter by themselves -- each
---               item `equal` so the editor does not narrow it again.
---   `menu`      `false` for no list until something has been typed.
---   `text`      what is in it to start with, if anything.
---   `on_change` `f(line)`, on every change to what is typed.
---   `paint`     `f(line)` -> `{ { from, to, group } }`: what is typed
---               coloured as it is typed.
---   `on_cancel` `f()`, where it is dismissed.
---   `keys`      `{ { lhs, fn, desc } }`, bound in normal mode. `fn` may
---               open a window over it (`M.over`).
---   `at`        `{ row, col, width }` on the editor.
---
--- `cb` is called with the answer, and not at all where the prompt was
--- dismissed -- which is a different thing from being answered with
--- nothing, and the difference is whether anything should happen.
function M.open(opts, cb)
  opts = vim.tbl_extend("force", {}, opts or {})
  -- The grounds and bands this plugin mixes are measured against
  -- `Normal`, and a float drawn on `NormalFloat` lifts them off a
  -- background they were not measured against. See `nemeton.notes`.
  opts.winhighlight = "NormalFloat:Normal"
  opts.normal = config.keys.prompt and config.keys.prompt.normal
  common.open(opts, cb)
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
