-- Pure formatting. Builds the side pane's contents and the winbars above
-- the two halves of the diff; owns no windows and no buffers.
--
-- What is being compared lives in the pane rather than in a winbar
-- because a winbar is a statusline expression and is therefore exactly
-- one line, with nowhere for anything that does not fit to go. In the
-- pane it is real buffer text and wraps to the width it has.

local M = {}

--- Escapes text destined for a statusline/winbar expression. A bare `%`
--- in a commit subject or a filename is an item specifier there and will
--- corrupt everything after it.
function M.escape(s)
  return (tostring(s):gsub("%%", "%%%%"))
end

--- Greedy word wrap. Falls back to a hard break for a single word longer
--- than the whole width.
function M.wrap(text, width)
  local out, line = {}, ""
  for word in tostring(text):gmatch("%S+") do
    if line == "" then
      line = word
    elseif #line + 1 + #word <= width then
      line = line .. " " .. word
    else
      table.insert(out, line)
      line = word
    end
    while #line > width do
      table.insert(out, line:sub(1, width))
      line = line:sub(width + 1)
    end
  end
  if line ~= "" then
    table.insert(out, line)
  end
  return #out > 0 and out or { "" }
end

--- Truncates a path from the left, which keeps the basename -- the part
--- that identifies the file -- when a narrow pane cannot show all of it.
function M.truncate_path(path, width)
  if #path <= width then
    return path
  end
  if width <= 1 then
    return "…"
  end
  return "…" .. path:sub(#path - width + 2)
end

local function stat_text(added, removed)
  return string.format("+%d -%d", added or 0, removed or 0)
end

--- The churn count as a winbar item: green for what came, red for what
--- went, in one item so nothing separates the two halves.
local function stat_item(added, removed)
  return {
    text = stat_text(added, removed),
    hl = "UatisMeta",
    raw = string.format("%%#UatisPlus#+%d%%*%%#UatisMeta# %%*%%#UatisMinus#-%d%%*",
      added or 0, removed or 0),
  }
end

--- Colours the two halves of a `+N -M` written at `col`. Offsets are
--- computed from the numbers rather than searched for, so a path that
--- happens to contain a `+` cannot pull the highlight onto itself.
local function stat_hl(b, line, col, added, removed)
  local plus = "+" .. tostring(added or 0)
  b:hl(line, col, col + #plus, "UatisStatAdd")
  b:hl(line, col + #plus + 1, col + #stat_text(added, removed), "UatisStatDel")
end

-- ------------------------------------------------------------------
-- Left pane
-- ------------------------------------------------------------------

-- A small builder so header and file rows can be appended with their
-- highlights without every call site tracking line numbers by hand.
local Buf = {}
Buf.__index = Buf

local function new_buf()
  return setmetatable({ lines = {}, hls = {} }, Buf)
end

function Buf:add(text, hl)
  table.insert(self.lines, text)
  if hl then
    table.insert(self.hls, { line = #self.lines - 1, col_start = 0, col_end = -1, hl = hl })
  end
  return #self.lines
end

function Buf:hl(line, col_start, col_end, hl)
  table.insert(self.hls, { line = line - 1, col_start = col_start, col_end = col_end, hl = hl })
end

--- Builds the entire left pane: the review header for the current mode,
--- then one row per changed file.
---
--- Returns { lines, hls, rows }, where `rows[buffer_line] = file_index`.
--- The caller maps cursor position to file through `rows` rather than
--- assuming a fixed header height, since the header's height depends on
--- how much of the commit subject fits.
function M.build_list(pane, width)
  local b = new_buf()
  local inner = math.max(width - 2, 10)

  local function pad(text)
    return " " .. text
  end

  -- Identity. Always first, always present: losing track of what is being
  -- compared is the failure this header exists to prevent.
  for _, l in ipairs(M.wrap(pane.target .. " ← " .. pane.src, inner)) do
    b:add(pad(l), "UatisHeader")
  end

  local added, removed = pane.stat_added, pane.stat_removed
  local head = pad(string.format("%d file%s · ", #pane.files,
    #pane.files == 1 and "" or "s"))
  local line = b:add(head .. stat_text(added, removed))
  b:hl(line, 0, -1, "UatisMeta")
  stat_hl(b, line, #head, added, removed)
  for _, l in ipairs(M.wrap(pane.hint or "", inner)) do
    b:add(pad(l), "UatisHint")
  end

  b:add(string.rep("─", width), "UatisHint")

  local rows = {}
  if #pane.files == 0 then
    b:add(pad("(no changes)"), "UatisMeta")
  end
  for _, entry in ipairs(M.tree_rows(pane.files)) do
    local indent = string.rep("  ", entry.depth)
    if entry.kind == "dir" then
      b:add(" " .. indent .. entry.name .. "/", "UatisDir")
    else
      local f = pane.files[entry.index]
      local stat = f.binary and "bin" or stat_text(f.added, f.removed)
      local head_prefix = " " .. indent .. f.status .. " "
      local avail = math.max(inner - #head_prefix - #stat, 6)
      local shown = M.truncate_path(entry.name, avail)
      local head = head_prefix .. shown .. string.rep(" ", math.max(avail - #shown, 0)) .. " "
      local line = b:add(head .. stat)
      rows[line] = entry.index
      b:hl(line, #indent + 1, #indent + 2,
        "UatisStatus" .. (f.status:match("^[AMDR]") and f.status or "M"))
      if entry.index == pane.file_idx then
        b:hl(line, #head_prefix, #head_prefix + #shown, "UatisFileCur")
      end
      -- Per-file churn, coloured the same way as everywhere else: how
      -- much a file grew or shrank is most of how you decide what to
      -- read next.
      if not f.binary then
        stat_hl(b, line, #head, f.added, f.removed)
      end
    end
  end

  return { lines = b.lines, hls = b.hls, rows = rows }
end

--- Flattens a changed-file list into directory and file rows.
---
--- A merge request's paths share most of their prefixes, so printing each
--- one in full spends the pane's width restating `lua/uatis/` on every
--- line and leaves nothing for the part that differs. Emitting each
--- directory once and indenting under it puts the width where the
--- information is.
---
--- Relies on the list already being in path order, which is how git
--- reports a diff -- so a directory's files are always contiguous and a
--- component only has to be compared against the previous row's.
function M.tree_rows(files)
  local rows, prev = {}, {}
  for i, f in ipairs(files) do
    local parts = vim.split(f.path, "/", { plain = true })
    local name = table.remove(parts)
    for d = 1, #parts do
      if prev[d] ~= parts[d] then
        table.insert(rows, { kind = "dir", name = parts[d], depth = d - 1 })
        for k = d, #prev do
          prev[k] = nil
        end
        prev[d] = parts[d]
      end
    end
    for k = #parts + 1, #prev do
      prev[k] = nil
    end
    table.insert(rows, { kind = "file", index = i, name = name, depth = #parts })
  end
  return rows
end

-- ------------------------------------------------------------------
-- The diff view's winbar
-- ------------------------------------------------------------------

--- Renders the two halves into a winbar expression at a measured width.
---
--- `left` is a list of { text, hl } -- where you are. `hints` is a list of
--- strings -- what you can press, ordered least to most droppable.
---
--- Built to a measured width rather than left to `%<`, which truncates
--- mid-item and leaves stumps like `</[c chunk`. Hints are dropped whole,
--- lowest value first, so whatever is left is always readable; the
--- identity half is never dropped, because not knowing what you are
--- looking at is the failure this header exists to prevent.
local function compose(left, hints, width)
  local left_text = ""
  for i, item in ipairs(left) do
    left_text = left_text .. (i > 1 and " · " or "") .. item.text
  end

  local sep = " │ "
  while #hints > 0 do
    local candidate = table.concat(hints, "  ")
    if vim.fn.strdisplaywidth(" " .. left_text .. sep .. candidate) <= width then
      break
    end
    table.remove(hints)
  end

  local out = " "
  for i, item in ipairs(left) do
    if i > 1 then
      out = out .. "%#UatisHint# · %*"
    end
    -- `raw` is markup the caller built itself -- a churn count is two
    -- colours in one item, and splitting it in two would put a separator
    -- through the middle of `+12 -3`. `text` is still what it measures.
    out = out .. (item.raw or ("%#" .. item.hl .. "#" .. M.escape(item.text) .. "%*"))
  end
  if #hints > 0 then
    out = out .. "%#UatisHint#" .. sep .. M.escape(table.concat(hints, "  ")) .. "%*"
  end
  -- Last-resort guard: the identity half alone can still overflow a very
  -- narrow window, and a winbar that wraps would push the code down.
  return out .. "%<"
end


--- One line, two halves: where you are, and what you can press.
---
--- Built to a measured width rather than left to `%<`, which truncates
--- mid-item and leaves stumps like `</[c chunk`. Hints are dropped whole,
--- lowest value first, so whatever is left is always readable; the
--- identity half is never dropped, because not knowing what you are
--- looking at is the failure this header exists to prevent.
---
--- The identity half says which ref the buffer is being measured against
--- and whether what you are looking at is the file on disk or your
--- unsaved edits, because in this view -- unlike a review, where every
--- buffer is a fixed revision -- the new side moves under you as you type
--- and "am I seeing my own change?" is the first question you ask.
local function view_winbar_text(view, width)
  local left = {}
  local function add(text, hl)
    table.insert(left, { text = text, hl = hl })
  end

  add(view.relpath, "UatisHeader")
  if view.old_path and view.old_path ~= view.relpath then
    add("← " .. view.old_path, "UatisMeta")
  end
  -- Which revision THIS window is showing, when there is another window
  -- showing a different one. In place there is only one window and the
  -- comparison is the thing worth naming; side by side, each window is a
  -- revision and has to say which, or the reader is left working it out
  -- from which half moved.
  if view.layout == "side" then
    add("working tree", "UatisMeta")
    if view.head then
      add(view.head, "UatisMeta")
    end
  else
    add("vs " .. view.ref, "UatisMeta")
  end
  table.insert(left, stat_item(view.added, view.removed))
  if vim.bo[view.bufnr].modified then
    add("modified", "UatisMeta")
  end
  if view.unavailable then
    -- The backend says `struct` and the answer came from `vim.diff`,
    -- which is worth a word: the reader asked for one thing and is
    -- looking at another.
    add("line · no difftastic", "UatisMeta")
  elseif view.backend ~= "line" and view.prose then
    -- difftastic answered, but with no tree: a file it has no parser for,
    -- or one that would not parse just now -- which is most files halfway
    -- through an edit. It compared words instead, so the marks are
    -- word-precise and nothing more. Worth saying, because the answer
    -- looks like a line diff and the reader would otherwise be left
    -- wondering what happened to the structural one.
    add("structural · no parser", "UatisMeta")
  else
    add(view.backend == "line" and "line" or "structural", "UatisMeta")
  end
  if view.dropped and view.dropped > 0 then
    add(string.format("%d cosmetic hidden", view.dropped), "UatisMeta")
  end

  local k = require("uatis.config").keys.view
  local hints = {
    k.hunk_next .. "/" .. k.hunk_prev .. " chunk",
    k.file_next .. "/" .. k.file_prev .. " file",
    k.diff_mode .. " " .. (view.backend == "line" and "structural" or "line"),
    k.layout .. " " .. (view.layout == "side" and "in place" or "side by side"),
    k.files .. " files",
  }
  -- How to get out, which is not always a key of the view's own: its own
  -- is off by default, because `<leader>gu` toggles the review off from
  -- anywhere including from in here. Name whichever one is actually
  -- bound rather than the one that happens to live in this table.
  local out = k.quit or require("uatis.config").keys.global.toggle_diff
  if out then
    table.insert(hints, out .. " close")
  end

  return compose(left, hints, width)
end

M.view_winbar_text = view_winbar_text

function M.view_winbar_expr()
  local win = tonumber(vim.g.statusline_winid)
  local buf = win and vim.api.nvim_win_is_valid(win)
    and vim.api.nvim_win_get_buf(win) or nil
  local view = buf and require("uatis.view").get(buf) or nil
  if not view then
    return ""
  end
  local width = (win and vim.api.nvim_win_is_valid(win))
    and vim.api.nvim_win_get_width(win) or vim.o.columns
  return view_winbar_text(view, width)
end

M.VIEW_WINBAR = "%!v:lua.require'uatis.ui'.view_winbar_expr()"

-- ------------------------------------------------------------------
-- Old-revision window
-- ------------------------------------------------------------------

--- Names the revision rather than the comparison. This window holds one
--- file at one revision and nothing is being measured in it, so a `+N -M`
--- here would be describing the window next door.
local function old_winbar_text(view, width)
  local left = {}
  local function add(text, hl)
    table.insert(left, { text = text, hl = hl })
  end

  add(view.old_path or view.relpath, "UatisHeader")
  -- Both halves of the identity: the name the reviewer asked for and the
  -- revision it resolved to. A branch moves, a tag is not a sha, and
  -- `HEAD~3` means something different by tomorrow -- naming only one of
  -- the two leaves the window ambiguous about exactly the thing it
  -- exists to pin down.
  add(view.ref, "UatisHeader")
  if view.rev then
    add(view.rev:sub(1, 7), "UatisMeta")
  end
  add(string.format("%d removed", view.removed or 0), "UatisMeta")

  local k = require("uatis.config").keys.old
  return compose(left, {
    k.jump .. " jump to now",
    k.quit .. " close",
  }, width)
end

M.old_winbar_text = old_winbar_text

function M.old_winbar_expr()
  local win = tonumber(vim.g.statusline_winid)
  local buf = win and vim.api.nvim_win_is_valid(win)
    and vim.api.nvim_win_get_buf(win) or nil
  local view = buf and require("uatis.oldside").view_for(buf) or nil
  if not view then
    return ""
  end
  local width = (win and vim.api.nvim_win_is_valid(win))
    and vim.api.nvim_win_get_width(win) or vim.o.columns
  return old_winbar_text(view, width)
end

M.OLD_WINBAR = "%!v:lua.require'uatis.ui'.old_winbar_expr()"

return M
