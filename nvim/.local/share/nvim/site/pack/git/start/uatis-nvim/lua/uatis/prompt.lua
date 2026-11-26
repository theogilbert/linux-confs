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
-- Ours means small, and shared: the window is common.prompt, one line in
-- one scratch buffer with a menu of the candidates handed in by the
-- caller. What is uatis's is the shape of the answer -- nil for a prompt
-- backed out of -- and the `omnifunc` its command line shares.
--
-- The menu comes up on its own as you type, and `<Tab>` is only there
-- for anyone who reaches for it. Waiting to be asked was the first
-- version and the wrong one: `<Tab>` in insert mode belongs to whichever
-- completion engine the reader installed, and the good ones re-map it
-- buffer-locally on entry -- ours included, and after ours. A prompt
-- whose completion depends on winning that race is a prompt that
-- silently does not complete.

local M = {}

local common = require("common.prompt")

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

--- The candidates for what has been typed so far, best first
--- (common.prompt.rank): the names the text starts, then the ones that
--- contain it -- branches are called `feature/the-thing` and the half
--- anyone remembers is after the slash -- then a commit by its subject.
--- With nothing typed, a slice of each kind, so three hundred branches
--- do not hide nine tags.
---
--- Public because the command line asks the same question of the same
--- candidates and should get the same order.
M.rank = common.rank

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
--- leaves it -- `<Esc>`, `<C-c>`, or the cursor going elsewhere -- and
--- on an empty line.
---
--- opts: { prompt = "...", default = "...", items = { ... } }, where an
--- item is a string, or `{ word = "...", menu = "...", kind = "..." }` --
--- `word` is what is inserted, and the other two are what the menu says
--- about it: a commit's subject line, and whether this is a branch, a
--- tag or a commit.
function M.open(opts, cb)
  local items = vim.tbl_map(item_of, opts.items or {})
  local width = math.max(30, math.min(60, vim.o.columns - 8))
  local buf
  local function done(text)
    if buf then
      state[buf] = nil
    end
    cb(text)
  end
  local win
  win, buf = common.open({
    title = opts.prompt or "",
    text = opts.default,
    items = items,
    filetype = "uatis-prompt",
    omnifunc = "v:lua.require'uatis.prompt'.omnifunc",
    at = {
      width = width,
      row = math.max(0, math.floor(vim.o.lines / 2) - 2),
      col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    },
    on_cancel = function()
      vim.schedule(function()
        done(nil)
      end)
    end,
  }, function(text)
    done(text ~= "" and text or nil)
  end)
  state[buf] = { items = items }
  return win
end

return M
