-- What a review IS, as one small panel: the revision it measures
-- against, and how much of the tree it is about.
--
--   <leader>gB
--
-- Two entries, each answered on its own, and neither of them applied
-- until the panel closes. That is the whole reason it is a panel rather
-- than two prompts one after the other. Asked in sequence, choosing a
-- base and then thinking better of the subtree has already re-pointed
-- every view in the repository on the way past -- and there is no way to
-- look at the two answers together before committing to them, which is
-- exactly what someone opening this wants to do: they are one statement.
-- "main, under services/billing" is a sentence; "main" and then, later,
-- "services/billing" is two decisions that happen to have been taken in
-- a row.
--
-- So the panel holds pending answers and nothing else knows about them
-- until `q`. Each row opens the picker or the prompt that row's question
-- already had -- `base.ask` and `base.ask_dir`, which are those same
-- questions with the deciding taken out.
--
-- A float in its own module, like `colors.lua`, for the same reason: it
-- owns keys and a window, and `base.lua` is where the answers live
-- rather than where they are asked for.

local base = require("uatis.base")

local M = {}

local panel = {}

--- The two entries, in the order they are read: what against, then how
--- much. A subtree with no base is not a review of anything.
local ROWS = {
  { key = "base", label = "base" },
  { key = "dir", label = "subtree" },
}

--- The keys, written out. A panel with two rows and no verbs on it is a
--- panel nobody presses anything in.
local HINT = "   <CR> change · q save · <Esc> discard"

--- What the row's answer looks like written down.
---
--- The empty subtree is spelled out rather than left blank: a row with
--- nothing after it reads as a question not yet answered, and "all of
--- it" is an answer.
local function value_of(key)
  if key == "base" then
    local name = panel.pending and panel.pending.base
    return (name and name ~= "") and name or "(none yet)"
  end
  local dir = panel.pending and panel.pending.dir or ""
  return dir ~= "" and (dir .. "/") or "(the whole repository)"
end

local function draw()
  if not (panel.buf and vim.api.nvim_buf_is_valid(panel.buf)) then
    return
  end
  local lines, hls = { "" }, {}
  panel.at = {}
  for i, r in ipairs(ROWS) do
    local head = ("   %-10s"):format(r.label)
    table.insert(lines, head .. value_of(r.key))
    panel.at[#lines] = i
    table.insert(hls, { line = #lines - 1, col = 0, to = #head, hl = "UatisMeta" })
    table.insert(hls, {
      line = #lines - 1, col = #head, to = -1,
      hl = r.key == "dir" and "UatisDir" or "UatisHeader",
    })
  end
  table.insert(lines, "")
  table.insert(lines, HINT)
  table.insert(hls, { line = #lines - 1, col = 0, to = -1, hl = "UatisHint" })

  vim.bo[panel.buf].modifiable = true
  vim.api.nvim_buf_set_lines(panel.buf, 0, -1, false, lines)
  vim.bo[panel.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(panel.buf, panel.ns, 0, -1)
  for _, h in ipairs(hls) do
    pcall(vim.api.nvim_buf_set_extmark, panel.buf, panel.ns, h.line, h.col, {
      end_col = h.to >= 0 and h.to or nil,
      end_row = h.to < 0 and h.line + 1 or nil,
      hl_group = h.hl,
    })
  end
end

--- Puts the cursor on the entry `by` rows along, and stops at the ends.
--- Two rows do not wrap: there is nowhere to wrap to that is not the
--- other one, and a cursor that jumps from the last back to the first
--- reads as having moved somewhere new.
local function move(by)
  if not (panel.win and vim.api.nvim_win_is_valid(panel.win)) then
    return
  end
  panel.row = math.min(math.max((panel.row or 1) + by, 1), #ROWS)
  for line, idx in pairs(panel.at) do
    if idx == panel.row then
      pcall(vim.api.nvim_win_set_cursor, panel.win, { line, 0 })
      return
    end
  end
end

--- Which entry the cursor is on, by the line it is sitting on rather
--- than by a count kept beside it: `j` and `k` are not the only way to
--- move in a window.
local function current()
  if not (panel.win and vim.api.nvim_win_is_valid(panel.win)) then
    return nil
  end
  local line = vim.api.nvim_win_get_cursor(panel.win)[1]
  local idx = (panel.at or {})[line] or panel.row
  panel.row = idx
  return ROWS[idx]
end

--- Back to the panel once a picker or a prompt has had its answer.
--- Those open windows of their own and take the keys; where the reader
--- came from is here, and a panel left in the background with the cursor
--- somewhere else is a panel they now have to go and find.
local function refocus()
  if panel.win and vim.api.nvim_win_is_valid(panel.win) then
    pcall(vim.api.nvim_set_current_win, panel.win)
    draw()
    move(0)
  end
end

--- Asks the question the row under the cursor stands for.
---
--- The same picker and the same prompt each of them already had --
--- `vim.ui.select` over the conventional branches with a row for the
--- rest of git, `prompt.lua` over the repository's directories. Only the
--- answer comes back here instead of being acted on.
local function edit()
  local row = current()
  if not row or not panel.root then
    return
  end
  if row.key == "base" then
    base.ask(panel.root, nil, function(name)
      if name then
        panel.pending.base = name
      end
      refocus()
    end)
  else
    base.ask_dir(panel.root, function(dir)
      if dir then
        panel.pending.dir = dir
      end
      refocus()
    end)
  end
end

function M.close()
  if panel.win and vim.api.nvim_win_is_valid(panel.win) then
    vim.api.nvim_win_close(panel.win, true)
  end
  panel.win, panel.buf, panel.at = nil, nil, nil
end

--- Closes, and this time the answers count.
---
--- Both at once, and only the ones that moved: `set` and `set_dir` write
--- to the store and re-point what is on screen, and saying "the base is
--- still main" is not a thing anybody asked for.
local function save()
  local root, pending, opened = panel.root, panel.pending, panel.opened
  local on_save = panel.on_save
  M.close()
  if not root then
    return
  end
  local moved = false
  if pending.base and pending.base ~= "" and pending.base ~= opened.base then
    base.set(root, pending.base)
    moved = true
  end
  if pending.dir ~= opened.dir then
    base.set_dir(root, pending.dir)
    moved = true
  end
  if not moved then
    return
  end
  vim.notify("uatis: " .. (pending.base or "?") .. " · "
    .. (pending.dir ~= "" and (pending.dir .. "/") or "the whole repository"))
  if on_save then
    on_save(root)
  end
end

--- True while the panel is up. For the tests, and for a second press of
--- the key, which means "let me see it" rather than "give me another".
function M.get()
  if panel.win and vim.api.nvim_win_is_valid(panel.win) then
    return panel
  end
  return nil
end

--- Opens the panel on the repository the current buffer is in.
---
--- `opts.on_save(root)` is what to do with the answers, which is not
--- this module's business: it knows what a review is set to, and
--- `init.lua` knows what is on screen.
function M.open(opts)
  opts = opts or {}
  if M.get() then
    vim.api.nvim_set_current_win(panel.win)
    return panel
  end

  base.root(function(root, path)
    if not root then
      vim.notify("uatis: " .. path .. " is not inside a git repository",
        vim.log.levels.ERROR)
      return
    end
    -- The base is asked for rather than read, because a repository that
    -- has never been told one still HAS one -- detected from
    -- `origin/HEAD` -- and a panel opening on `(none yet)` beside a
    -- review already running against `main` would be describing
    -- something other than what is on the screen.
    base.get(root, function(name)
      panel.root = root
      panel.on_save = opts.on_save
      -- What was in force when it opened, so `save` can tell an answer
      -- from an answer that did not change.
      panel.opened = { base = name or "", dir = base.dir(root) }
      panel.pending = { base = panel.opened.base, dir = panel.opened.dir }
      panel.ns = panel.ns or vim.api.nvim_create_namespace("uatis_scope")
      panel.buf = vim.api.nvim_create_buf(false, true)
      vim.bo[panel.buf].bufhidden = "wipe"
      vim.bo[panel.buf].modifiable = false
      panel.row = 1

      -- Wide enough for the row of keys, whatever else is on the
      -- screen: a hint cut off at the edge is a hint that has to be
      -- guessed at.
      local width = math.min(math.max(vim.fn.strdisplaywidth(HINT) + 4, 46),
        math.max(vim.o.columns - 8, 20))
      local height = #ROWS + 3
      panel.win = vim.api.nvim_open_win(panel.buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = math.max(0, math.floor(vim.o.lines / 2) - math.floor(height / 2) - 1),
        col = math.max(0, math.floor((vim.o.columns - width) / 2)),
        style = "minimal",
        border = "rounded",
        title = " uatis: what am I reviewing ",
        title_pos = "center",
      })
      vim.wo[panel.win].winhighlight = "NormalFloat:Normal"
      vim.wo[panel.win].cursorline = true
      vim.wo[panel.win].wrap = false

      local keys = {
        q = save,
        ["<CR>"] = edit,
        j = function() move(1) end,
        k = function() move(-1) end,
        ["<Down>"] = function() move(1) end,
        ["<Up>"] = function() move(-1) end,
        ["<Esc>"] = M.close,
        ["<C-c>"] = M.close,
      }
      for lhs, fn in pairs(keys) do
        vim.keymap.set("n", lhs, fn, { buffer = panel.buf, nowait = true, silent = true })
      end

      draw()
      move(0)
      if opts.on_ready then
        opts.on_ready(panel)
      end
    end)
  end)
end

-- For the tests, and for anyone driving the panel from a mapping.
M.rows = ROWS
M.save = save
M.edit = edit
M.move = move

return M
