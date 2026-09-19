-- A conflicted file, annotated in place: the buffer git left the markers
-- in, with each block's sides banded, the markers dimmed, a motion
-- between blocks and a key for each way of settling one.
--
-- A sibling of `view.lua`, not a mode of it. A view compares a buffer
-- against a revision -- two texts, a diff, an old side to draw. A
-- conflicted buffer is one text carrying three, already laid out by git,
-- and what the reader needs is not a comparison but a way to move
-- through the blocks and take a side. What the two share is the
-- premise: this is the reader's own buffer, still writable, and every
-- pick is an ordinary edit -- `u` takes it back.
--
-- The blocks are re-read from the buffer on every change, since a pick
-- is a change and so is a hand edit inside a block. That is a line scan
-- (`merge.blocks`), so unlike a view there is no diff to wait on and no
-- generation to guard; the one thing fetched is the BASE of the file
-- out of the index, for the blocks whose markers do not carry one, and
-- only the wand waits on that.

local config = require("uatis.config")
local keys = require("uatis.keys")
local merge = require("uatis.merge")
local git = require("uatis.git")
local ui = require("uatis.ui")

local M = {}

-- bufnr -> state. One annotator per buffer, like a view.
local conflicts = {}

M.ns = vim.api.nvim_create_namespace("uatis_conflict")

function M.get(bufnr)
  local c = conflicts[bufnr]
  if c and not vim.api.nvim_buf_is_valid(bufnr) then
    conflicts[bufnr] = nil
    return nil
  end
  return c
end

function M.all()
  local out = {}
  for bufnr, c in pairs(conflicts) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      table.insert(out, c)
    end
  end
  return out
end

--- Where `]x` stepped off the end of one file and into the next: the
--- direction it was going, collected by the next file's first render
--- (see `spill` in view.lua, which this mirrors).
local landing

-- ------------------------------------------------------------------
-- Reading
-- ------------------------------------------------------------------

local function lines_of(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

local function join(lines)
  return table.concat(lines, "\n")
end

--- The block the cursor row is inside, or nil.
local function block_at(c, row)
  for i, b in ipairs(c.blocks) do
    if row >= b.top and row <= b.bottom then
      return i
    end
  end
  return nil
end

--- The rows of the buffer that are one side's version of the file --
--- every row outside a block, and that side of each -- as a list of
--- lines, with the buffer row each came from. `side` is "ours" or
--- "theirs".
local function projection(c, side)
  local lines = lines_of(c.bufnr)
  local skip = {}
  for _, b in ipairs(c.blocks) do
    skip[b.top] = true
    if side == "ours" then
      for row = (b.mid or b.sep), b.bottom do
        skip[row] = true
      end
    else
      for row = b.top + 1, b.sep do
        skip[row] = true
      end
      skip[b.bottom] = true
    end
  end
  local out, rows = {}, {}
  for row, l in ipairs(lines) do
    if not skip[row] then
      out[#out + 1] = l
      rows[row] = #out
    end
  end
  return out, rows
end

local function ours_projection(c)
  return projection(c, "ours")
end

--- A function from a line of `from` to the line of `to` it is a copy
--- of, or nil where it is inside a change, off a line diff of the two.
local function line_map(from, to)
  local hunks = vim.diff(table.concat(to, "\n") .. "\n", table.concat(from, "\n") .. "\n", {
    result_type = "indices", algorithm = "histogram",
  }) or {}
  return function(i)
    local offset = 0
    for _, h in ipairs(hunks) do
      local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
      local lo = cb == 0 and sb + 1 or sb
      if i < lo then
        return i + offset
      end
      if i < lo + cb then
        return nil
      end
      offset = offset + (ca - cb)
    end
    return i + offset
  end
end

--- The lines of the base that stood where block `b` now stands, read
--- off a line diff of the base against our version of the file: the
--- rows just above and below a block are lines all three versions
--- share -- that is what makes them the edges of the block -- so the
--- base between their counterparts is the block's base.
---
--- Not `git merge-file --diff3` over the three stages, which was the
--- first idea: it draws its own block boundaries, and they are not
--- git's -- two blocks where the merge that wrote the file coalesced
--- one -- so its blocks matched the buffer's by content only some of
--- the time.
local function projected_base(c, b)
  local ours, rows = ours_projection(c)
  local base = c.base_lines
  local base_row = line_map(ours, base)
  local lo, hi = 1, #base
  local above = b.top - 1
  while above >= 1 and not rows[above] do
    above = above - 1
  end
  if above >= 1 then
    local r = base_row(rows[above])
    if not r then
      return nil
    end
    lo = r + 1
  end
  local below = b.bottom + 1
  local n = vim.api.nvim_buf_line_count(c.bufnr)
  while below <= n and not rows[below] do
    below = below + 1
  end
  if below <= n then
    local r = base_row(rows[below])
    if not r then
      return nil
    end
    hi = r - 1
  end
  local out = {}
  for i = lo, hi do
    out[#out + 1] = base[i]
  end
  return out
end

--- The base of a block: what the markers carry, or what the index
--- says, projected onto the block. nil when neither has one -- before
--- the index has answered, or for a file both sides added.
local function base_of(c, b)
  if b.base then
    return b.base
  end
  if not c.base_lines then
    return nil
  end
  c.projected = c.projected or {}
  if c.projected[b.top] == nil then
    c.projected[b.top] = projected_base(c, b) or false
  end
  return c.projected[b.top] or nil
end

--- Whether the wand can take this block, memoised on its content --
--- `merge3` is cheap, but it is asked on every render for every block.
local function resolvable(c, b)
  local base = base_of(c, b)
  if not base then
    return nil
  end
  local k = join(b.ours) .. "\0" .. join(base) .. "\0" .. join(b.theirs)
  c.resolvable = c.resolvable or {}
  if c.resolvable[k] == nil then
    local text = merge.merge3(join(base), join(b.ours), join(b.theirs))
    c.resolvable[k] = text and { text = text } or false
  end
  return c.resolvable[k]
end

-- ------------------------------------------------------------------
-- Drawing
-- ------------------------------------------------------------------

--- Marks the tokens `from`..`to` (1-based, inclusive) of `tokens` in
--- the rows starting at `row0` (0-based) with `hl`: one mark per row,
--- from the first non-blank token to the last, so that `or 0)` is one
--- run and not three -- the blank between two changed words is not the
--- buffer showing through but part of the same change (the rule
--- `paint_row` follows in overlay.lua). A run of blank alone is not
--- marked: a highlighted run of spaces says nothing.
local function mark_tokens(bufnr, row0, tokens, from, to, hl)
  local row, col = row0, 0
  local first, last
  local function flush()
    if first then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row, first, {
        end_col = last,
        hl_group = hl,
        priority = 110,
      })
    end
    first, last = nil, nil
  end
  for i, t in ipairs(tokens) do
    if i > to then
      break
    end
    if t == "\n" then
      flush()
      row, col = row + 1, 0
    else
      if i >= from and not t:match("^[ \t]*$") then
        first = first or col
        last = col + #t
      end
      col = col + #t
    end
  end
  flush()
end

local function band(bufnr, from_row, to_row, hl)
  for row = from_row, to_row do
    vim.api.nvim_buf_set_extmark(bufnr, M.ns, row - 1, 0, {
      line_hl_group = hl,
      priority = 100,
    })
  end
end

--- Diagnostics off while the file has blocks in it, and back once it
--- has none. A file with markers in it does not parse, so every
--- diagnostic a server reports on it is about the markers -- an
--- unexpected token on row 4, and a cascade of them under it -- and
--- none of it is a thing the reader can act on before the block is
--- settled. What was on before is what is put back: a reader who had
--- them off keeps them off.
local function quiet(c, on)
  if not config.conflict.quiet_diagnostics or not vim.api.nvim_buf_is_valid(c.bufnr) then
    return
  end
  if on and c.diagnostics == nil then
    c.diagnostics = vim.diagnostic.is_enabled({ bufnr = c.bufnr })
    vim.diagnostic.enable(false, { bufnr = c.bufnr })
  elseif not on and c.diagnostics ~= nil then
    vim.diagnostic.enable(c.diagnostics, { bufnr = c.bufnr })
    c.diagnostics = nil
  end
end

local function render(c)
  local bufnr = c.bufnr
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local lines = lines_of(bufnr)
  c.blocks = merge.blocks(lines)
  c.projected = nil
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  local n = #c.blocks
  for i, b in ipairs(c.blocks) do
    band(bufnr, b.top, b.top, "UatisMarker")
    band(bufnr, b.sep, b.sep, "UatisMarker")
    band(bufnr, b.bottom, b.bottom, "UatisMarker")
    band(bufnr, b.top + 1, (b.mid or b.sep) - 1, "UatisOurs")
    if b.mid then
      band(bufnr, b.mid, b.mid, "UatisMarker")
      band(bufnr, b.mid + 1, b.sep - 1, "UatisBase")
    end
    band(bufnr, b.sep + 1, b.bottom - 1, "UatisTheirs")

    -- What each side changed. Against the base where there is one --
    -- that is the question the reader is asking, what did THIS side do
    -- -- and against each other where there is not, which at least says
    -- where the two differ.
    local ours, theirs = merge.tokens(join(b.ours)), merge.tokens(join(b.theirs))
    local base = base_of(c, b)
    if base then
      local bt = merge.tokens(join(base))
      for _, h in ipairs(merge.diff_tokens(bt, ours)) do
        mark_tokens(bufnr, b.top, ours, h.sb, h.sb + h.cb - 1, "UatisOursMark")
      end
      for _, h in ipairs(merge.diff_tokens(bt, theirs)) do
        mark_tokens(bufnr, b.sep, theirs, h.sb, h.sb + h.cb - 1, "UatisTheirsMark")
      end
    else
      for _, h in ipairs(merge.diff_tokens(ours, theirs)) do
        mark_tokens(bufnr, b.top, ours, h.sa, h.sa + h.ca - 1, "UatisOursMark")
        mark_tokens(bufnr, b.sep, theirs, h.sb, h.sb + h.cb - 1, "UatisTheirsMark")
      end
    end

    -- `HEAD` is the one label git writes that names nothing: which
    -- branch that is, is the first thing a reader asks of a block, and
    -- it is drawn in after the word, as text the buffer does not hold.
    if b.label_ours == "HEAD" and c.head then
      vim.api.nvim_buf_set_extmark(bufnr, M.ns, b.top - 1, #lines[b.top], {
        virt_text = { { " (" .. c.head .. ")", "UatisMeta" } },
        virt_text_pos = "inline",
        priority = 100,
      })
    end

    -- Which block this is, and whether the wand can take it: the one
    -- fact that decides whether the reader has to read it.
    local text = string.format("conflict %d of %d", i, n)
    local can = resolvable(c, b)
    if can then
      text = text .. " · resolvable by the word"
    elseif can == false then
      text = text .. " · both sides changed the same words"
    end
    vim.api.nvim_buf_set_extmark(bufnr, M.ns, b.top - 1, 0, {
      virt_text = { { text, "UatisMeta" } },
      virt_text_pos = "eol",
      priority = 100,
    })
  end
  quiet(c, n > 0)
  c.renders = (c.renders or 0) + 1
  require("uatis.pane").recount_conflicts(c)
  vim.cmd("redrawstatus")
end

--- Debounced, like a view's render: a keystroke inside a block is a
--- change, and re-reading the file on every one of them is a scan the
--- reader cannot see the result of until they stop typing.
local function schedule_render(c)
  if not c.timer then
    c.timer = vim.uv.new_timer()
  end
  c.timer:stop()
  c.timer:start(150, 0, vim.schedule_wrap(function()
    if conflicts[c.bufnr] == c then
      render(c)
    end
  end))
end

-- ------------------------------------------------------------------
-- The base, from the index
-- ------------------------------------------------------------------

--- Fetches stage 1 -- the base of the file -- so every block has a
--- base to be merged by the word against, whatever conflict style
--- wrote the file. Asked once per annotator; anything waiting on the
--- answer (`with_base`) is run when it lands. A file with no stage 1
--- was added by both sides, and gets `false`: asked, and no base.
local function fetch_base(c)
  if c.base_lines ~= nil or c.fetching then
    return
  end
  c.fetching = true
  git.stage(c.root, 1, c.relpath, function(text)
    if conflicts[c.bufnr] ~= c then
      return
    end
    c.fetching = false
    c.base_lines = text and vim.split(text, "\n", { plain = true }) or false
    local waiting = c.waiting or {}
    c.waiting = nil
    for _, fn in ipairs(waiting) do
      fn()
    end
    render(c)
  end)
end

--- Runs `fn` once the index has been asked about this file -- now, if
--- it already has been, or if none of `blocks` needs it: a block whose
--- markers carry the base waits on nothing.
local function with_base(c, blocks, fn)
  local needed = false
  for _, b in ipairs(blocks) do
    if not b.base then
      needed = true
      break
    end
  end
  if not needed or c.base_lines ~= nil then
    fn()
    return
  end
  c.waiting = c.waiting or {}
  table.insert(c.waiting, fn)
  fetch_base(c)
end

-- ------------------------------------------------------------------
-- Settling a block
-- ------------------------------------------------------------------

--- Replaces block `b` with `lines`: one edit, one undo step, and the
--- cursor on the first row of what replaced it. The blocks are re-read
--- straight away rather than on the debounce, since the reader's next
--- key is likely `]x` and it has to know where the next block now is.
local function replace(c, b, lines)
  -- Its own undo step. An edit made through the API joins whatever
  -- undo block is still open, and after `:e` that is the reload
  -- itself (`undoreload`), so `u` after a pick put back the file as
  -- it was BEFORE the merge. Setting 'undolevels' to itself is the
  -- documented way to close the block.
  vim.api.nvim_buf_call(c.bufnr, function()
    vim.cmd("let &undolevels = &undolevels")
  end)
  vim.api.nvim_buf_set_lines(c.bufnr, b.top - 1, b.bottom, false, lines)
  if c.win and vim.api.nvim_win_is_valid(c.win) then
    local row = math.min(b.top, math.max(vim.api.nvim_buf_line_count(c.bufnr), 1))
    pcall(vim.api.nvim_win_set_cursor, c.win, { row, 0 })
  end
  if c.timer then
    c.timer:stop()
  end
  render(c)
  if #c.blocks == 0 then
    local rest = require("uatis.pane").conflicts_left(c)
    vim.notify("uatis: " .. c.relpath .. " resolved" .. (rest or ""), vim.log.levels.INFO)
  end
end

local function current_block(c)
  if not (c.win and vim.api.nvim_win_is_valid(c.win)) then
    return nil
  end
  local i = block_at(c, vim.api.nvim_win_get_cursor(c.win)[1])
  if not i then
    vim.notify("uatis: not inside a conflict", vim.log.levels.INFO)
  end
  return i
end

local function pick(c, side)
  local i = current_block(c)
  if not i then
    return
  end
  local b = c.blocks[i]
  if side == "ours" then
    replace(c, b, b.ours)
  elseif side == "theirs" then
    replace(c, b, b.theirs)
  elseif side == "both" then
    local both = vim.list_extend(vim.list_extend({}, b.ours), b.theirs)
    replace(c, b, both)
  elseif side == "base" then
    with_base(c, { b }, function()
      if conflicts[c.bufnr] ~= c or c.blocks[i] ~= b then
        return
      end
      local base = base_of(c, b)
      if not base then
        vim.notify("uatis: no base for this conflict", vim.log.levels.INFO)
        return
      end
      replace(c, b, base)
    end)
  end
end

--- The wand, over one block: both sides' changes applied to the base
--- where they touch no common word.
local function resolve_block(c, b)
  local can = resolvable(c, b)
  if not can then
    return false
  end
  replace(c, b, vim.split(can.text, "\n", { plain = true }))
  return true
end

local function resolve(c)
  local i = current_block(c)
  if not i then
    return
  end
  local b = c.blocks[i]
  with_base(c, { b }, function()
    if conflicts[c.bufnr] ~= c or c.blocks[i] ~= b then
      return
    end
    if not base_of(c, b) then
      vim.notify("uatis: no base for this conflict, nothing to merge against", vim.log.levels.INFO)
      return
    end
    if not resolve_block(c, b) then
      vim.notify(string.format("uatis: conflict %d is a real overlap -- both sides changed the same words", i),
        vim.log.levels.INFO)
    end
  end)
end

--- The wand over every block of the file, last to first so the rows of
--- the ones still to do are not moved by the ones done.
local function resolve_all(c)
  with_base(c, c.blocks, function()
    if conflicts[c.bufnr] ~= c then
      return
    end
    local total = #c.blocks
    if total == 0 then
      vim.notify("uatis: no conflicts in this file", vim.log.levels.INFO)
      return
    end
    local done = 0
    for i = total, 1, -1 do
      local b = c.blocks[i]
      if resolvable(c, b) then
        replace(c, b, vim.split(resolvable(c, b).text, "\n", { plain = true }))
        done = done + 1
      end
    end
    local msg = string.format("uatis: resolved %d of %d", done, total)
    if done < total then
      msg = msg .. " -- the rest overlap"
    end
    vim.notify(msg, vim.log.levels.INFO)
  end)
end

-- ------------------------------------------------------------------
-- The commit a marker names
-- ------------------------------------------------------------------

--- What a marker row stands for: which side, the revision that side
--- is, and the float's title. Ours is HEAD, theirs is whatever git
--- wrote after `>>>>>>>` -- a branch in a merge, `sha (subject)` in a
--- rebase -- and the base is the sha diff3 wrote, where it wrote one.
--- `=======` names nothing.
local function named_by(c, row)
  for _, b in ipairs(c.blocks) do
    if row == b.top then
      return "ours", "HEAD", "HEAD" .. (c.head and (" (" .. c.head .. ")") or ""), b
    elseif row == b.bottom then
      local rev = b.label_theirs:match("^(%S+)")
      return "theirs", rev, b.label_theirs, b
    elseif row == b.mid then
      local rev = (vim.api.nvim_buf_get_lines(c.bufnr, row - 1, row, false)[1] or "")
        :match("^|||||||%s*(%S+)")
      return "base", rev, "base", b
    end
  end
  return nil
end

--- The lines block `b`'s `side` occupies in that side's own version
--- of the file -- stage 2 for ours, 3 for theirs -- as `from, to`, or
--- nil where the side has no lines or they cannot be placed. The
--- buffer's rows are not that file's rows: the other side and the
--- markers are in between, and a block settled higher up has moved
--- everything under it.
local function lines_at(c, b, side, text)
  local first = side == "ours" and b.top + 1 or b.sep + 1
  local last = side == "ours" and (b.mid or b.sep) - 1 or b.bottom - 1
  if last < first then
    return nil
  end
  local proj, rows = projection(c, side)
  local map = line_map(proj, vim.split(text, "\n", { plain = true }))
  local from, to = map(rows[first]), map(rows[last])
  if not (from and to) then
    return nil
  end
  return from, to
end

--- The commit behind the marker under the cursor, in a float beside
--- it, gone when the cursor moves. For ours and theirs that is the
--- last commit ON THAT SIDE to touch the block's lines -- `git log -L`
--- over that side's version of the file -- which is the commit the
--- reader is deciding about; the tip of the branch is as often "fix
--- typo" as not. The base is one commit by definition. Off a marker
--- row the key is not ours: it does whatever it did before this
--- buffer was annotated.
local function peek(c, fallback)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local side, rev, title, b = named_by(c, row)
  if not side then
    return fallback()
  end
  local function show(commit, err)
    if conflicts[c.bufnr] ~= c then
      return
    end
    if not commit then
      vim.notify("uatis: no commit at " .. tostring(rev)
        .. (err and err ~= "" and (": " .. err:match("^[^\r\n]*")) or ""), vim.log.levels.INFO)
      return
    end
    git.commit_message(c.root, commit.sha, function(text)
      if conflicts[c.bufnr] ~= c or vim.api.nvim_get_current_buf() ~= c.bufnr
        or vim.api.nvim_win_get_cursor(0)[1] ~= row then
        return -- the reader has moved on; a float now would land on nothing
      end
      require("uatis.pane").commit_float(commit, text, {
        at_cursor = true, from = c.bufnr, title = " " .. title .. " ",
      })
    end)
  end
  if side == "base" or not rev then
    return git.commit(c.root, rev or "", function(commit, _, err) show(commit, err) end)
  end
  git.stage(c.root, side == "ours" and 2 or 3, c.relpath, function(text)
    if conflicts[c.bufnr] ~= c then
      return
    end
    local from, to
    if text then
      from, to = lines_at(c, b, side, text)
    end
    if not from then
      -- Nothing on that side to have been touched -- the side deleted
      -- the lines -- or lines that cannot be placed: the tip, then.
      return git.commit(c.root, rev, function(commit, _, err) show(commit, err) end)
    end
    git.touched(c.root, rev, c.relpath, from, to, function(commit, err)
      if commit then
        return show(commit)
      end
      git.commit(c.root, rev, function(tip, _, why) show(tip, err or why) end)
    end)
  end)
end

--- Runs the mapping `lhs` had in this buffer before ours -- the one
--- `keys.apply` saved -- or the global one, or the key's own meaning.
--- For a key borrowed on some rows only: `K` on a marker row is ours,
--- and on every other row it is the reader's hover, which an LSP maps
--- buffer-locally and which this must not take away from a whole file
--- for the sake of three rows of it.
local function fall_through(c, lhs)
  local prev = c.saved_keys and c.saved_keys[lhs]
  if not prev then
    for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
      if m.lhs == lhs then
        prev = m
        break
      end
    end
  end
  if prev and prev.callback then
    return prev.callback()
  end
  if prev and prev.rhs and prev.rhs ~= "" then
    return vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(prev.rhs, true, false, true),
      prev.noremap == 1 and "n" or "m", false)
  end
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(lhs, true, false, true), "n", false)
end

-- ------------------------------------------------------------------
-- Motion
-- ------------------------------------------------------------------

local function jump(c, i)
  local b = c.blocks[i]
  if b and c.win and vim.api.nvim_win_is_valid(c.win) then
    pcall(vim.api.nvim_win_set_cursor, c.win, { math.min(b.top + 1, b.bottom), 0 })
    vim.cmd("redrawstatus")
  end
end

--- Off the end of this file, into the next one the list names -- the
--- shape of `]c` spilling into the next file.
local function spill(c, dir)
  local pane = require("uatis.pane")
  local list = pane.get()
  if not (list and list.conflicts and (list.renders or 0) > 0) then
    vim.notify("uatis: " .. (dir > 0 and "last" or "first") .. " conflict", vim.log.levels.INFO)
    return
  end
  local idx = (list.file_idx or 0) + dir
  if idx < 1 or idx > #list.files then
    vim.notify("uatis: " .. (dir > 0 and "last" or "first") .. " conflict", vim.log.levels.INFO)
    return
  end
  landing = { dir = dir, from = c.bufnr }
  pane.goto_file(list, idx)
  vim.schedule(function()
    local win = c.win
    if not (win and vim.api.nvim_win_is_valid(win)) then
      return
    end
    local dest = conflicts[vim.api.nvim_win_get_buf(win)]
    if dest then
      M.land(dest)
    end
  end)
end

function M.land(c)
  if not landing or landing.from == c.bufnr or (c.renders or 0) == 0 then
    return
  end
  local dir = landing.dir
  landing = nil
  jump(c, dir > 0 and 1 or #c.blocks)
end

local function step(c, dir)
  if not (c.win and vim.api.nvim_win_is_valid(c.win)) then
    return
  end
  local cur = vim.api.nvim_win_get_cursor(c.win)[1]
  local target
  if dir > 0 then
    for i, b in ipairs(c.blocks) do
      if b.top + 1 > cur then
        target = i
        break
      end
    end
  else
    for i = #c.blocks, 1, -1 do
      if c.blocks[i].top + 1 < cur then
        target = i
        break
      end
    end
  end
  if not target then
    return spill(c, dir)
  end
  jump(c, target)
end

-- ------------------------------------------------------------------
-- Lifetime
-- ------------------------------------------------------------------

local function setup_keymaps(c)
  local k = config.keys.conflict
  local v = config.keys.view
  c.saved_keys = keys.apply(c.bufnr, "n", {
    { lhs = k.next, rhs = function() step(c, 1) end,
      opts = { desc = "uatis: next conflict" } },
    { lhs = k.prev, rhs = function() step(c, -1) end,
      opts = { desc = "uatis: previous conflict" } },
    { lhs = k.ours, rhs = function() pick(c, "ours") end,
      opts = { desc = "uatis: take our side of this conflict" } },
    { lhs = k.theirs, rhs = function() pick(c, "theirs") end,
      opts = { desc = "uatis: take their side of this conflict" } },
    { lhs = k.both, rhs = function() pick(c, "both") end,
      opts = { desc = "uatis: take both sides, ours first" } },
    { lhs = k.base, rhs = function() pick(c, "base") end,
      opts = { desc = "uatis: take the base of this conflict" } },
    { lhs = k.resolve, rhs = function() resolve(c) end,
      opts = { desc = "uatis: merge this conflict by the word" } },
    { lhs = k.resolve_all, rhs = function() resolve_all(c) end,
      opts = { desc = "uatis: merge the whole file by the word" } },
    { lhs = k.peek, rhs = function() peek(c, function() fall_through(c, k.peek) end) end,
      opts = { desc = "uatis: the commit this marker names" } },
    -- The list's keys, bound here as the view binds them, so that a
    -- conflicted file has the same walk a reviewed one has.
    { lhs = v.files, rhs = function() require("uatis.pane").toggle() end,
      opts = { desc = "uatis: show or hide the conflicted files" } },
    { lhs = v.file_next, rhs = function() require("uatis.pane").step_from(1) end,
      opts = { desc = "uatis: next conflicted file" } },
    { lhs = v.file_prev, rhs = function() require("uatis.pane").step_from(-1) end,
      opts = { desc = "uatis: previous conflicted file" } },
  })
end

local function setup_watchers(c)
  local function attach()
    vim.api.nvim_buf_attach(c.bufnr, false, {
      on_lines = function()
        if conflicts[c.bufnr] ~= c then
          return true
        end
        schedule_render(c)
      end,
      -- `:e` drops every attachment and reads the file back into the
      -- same buffer; a buffer still loaded on the next tick came back
      -- and gets its marks again. See the same handler in view.lua.
      on_detach = function()
        vim.schedule(function()
          if conflicts[c.bufnr] ~= c then
            return
          end
          if vim.api.nvim_buf_is_valid(c.bufnr) and vim.api.nvim_buf_is_loaded(c.bufnr) then
            attach()
            render(c)
            return
          end
          M.close(c.bufnr)
        end)
      end,
    })
  end
  attach()

  c.augroup = vim.api.nvim_create_augroup("UatisConflict" .. tostring(c.bufnr), { clear = true })

  -- The winbar says which block the cursor is in.
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = c.augroup,
    buffer = c.bufnr,
    callback = function()
      if conflicts[c.bufnr] == c then
        vim.cmd("redrawstatus")
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "BufWinLeave", "BufUnload" }, {
    group = c.augroup,
    buffer = c.bufnr,
    callback = function(ev)
      vim.schedule(function()
        if ev.event == "BufUnload" and conflicts[c.bufnr] == c
          and vim.api.nvim_buf_is_valid(c.bufnr)
          and vim.api.nvim_buf_is_loaded(c.bufnr) then
          return
        end
        M.close(c.bufnr)
      end)
    end,
  })

  -- The window moved on to another file while this one is still on
  -- screen elsewhere: the annotator goes with the window, as a view does.
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = c.augroup,
    callback = function()
      if conflicts[c.bufnr] ~= c
        or not (c.win and vim.api.nvim_win_is_valid(c.win))
        or vim.api.nvim_win_get_buf(c.win) == c.bufnr then
        return
      end
      vim.schedule(function()
        if conflicts[c.bufnr] == c
          and c.win and vim.api.nvim_win_is_valid(c.win)
          and vim.api.nvim_win_get_buf(c.win) ~= c.bufnr then
          M.close(c.bufnr)
        end
      end)
    end,
  })
end

--- Annotates `bufnr`, shown in `win`, as `relpath` under `root`. A
--- buffer already annotated is re-pointed at the window and redrawn.
function M.attach(bufnr, win, root, relpath)
  local existing = conflicts[bufnr]
  if existing then
    existing.win = win
    render(existing)
    return existing
  end
  local c = {
    bufnr = bufnr,
    win = win,
    root = root,
    relpath = relpath,
    blocks = {},
    renders = 0,
    -- Never our own expression: see `saved_winbar` in view.lua.
    saved_winbar = (vim.wo[win].winbar ~= ui.CONFLICT_WINBAR and vim.wo[win].winbar ~= ui.VIEW_WINBAR)
      and vim.wo[win].winbar or "",
  }
  conflicts[bufnr] = c
  require("uatis.overlay").setup_highlights()
  setup_keymaps(c)
  setup_watchers(c)
  vim.wo[win].winbar = ui.CONFLICT_WINBAR
  -- Said out loud, for a config that wants to do something with a
  -- buffer the moment it is in a conflict review -- a which-key group
  -- over `<leader>x`, say -- without polling `status()`. Fired after
  -- the keys are bound, so what it announces is already true.
  vim.api.nvim_exec_autocmds("User", {
    pattern = "UatisConflictAttach",
    data = { buf = bufnr, root = root, path = relpath },
  })
  -- Which branch HEAD is, for the marker rows. Asked once: the
  -- checkout does not move under a merge in progress. Detached -- a
  -- rebase, where HEAD is the upstream being replayed onto -- has no
  -- name to give, and the label stays as git wrote it.
  git.abbrev_ref(root, "HEAD", function(name)
    if conflicts[bufnr] ~= c then
      return
    end
    if name and name ~= "" and name ~= "HEAD" then
      c.head = name
      render(c)
    end
  end)
  render(c)
  -- How many blocks the file had when the reader arrived: what
  -- `resolved` counts against, since a settled block leaves the file.
  c.total = #c.blocks
  -- The base is wanted for the marks and the wand alike, and the index
  -- is the only place to get it where the markers carry none.
  local missing = false
  for _, b in ipairs(c.blocks) do
    if not b.base then
      missing = true
      break
    end
  end
  if missing then
    fetch_base(c)
  end
  M.land(c)
  return c
end

function M.close(bufnr)
  local c = conflicts[bufnr]
  if not c then
    return
  end
  conflicts[bufnr] = nil
  if c.timer then
    c.timer:stop()
    c.timer:close()
    c.timer = nil
  end
  if c.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, c.augroup)
  end
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
    keys.restore(bufnr, "n", c.saved_keys)
    quiet(c, false)
  end
  if c.win and vim.api.nvim_win_is_valid(c.win)
    and vim.api.nvim_win_get_buf(c.win) == bufnr then
    vim.wo[c.win].winbar = c.saved_winbar
  end
end

function M.close_all(root)
  for bufnr, c in pairs(conflicts) do
    if c.root == root then
      M.close(bufnr)
    end
  end
end

--- What the winbar and `status()` say about this buffer: which block
--- the cursor is in, how many there are, how many there were.
function M.state(c)
  local row = (c.win and vim.api.nvim_win_is_valid(c.win))
    and vim.api.nvim_win_get_cursor(c.win)[1] or 0
  return {
    conflicts = #c.blocks,
    resolved = math.max((c.total or #c.blocks) - #c.blocks, 0),
    conflict = block_at(c, row),
  }
end

return M
