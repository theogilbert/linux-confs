-- A file of the review, picked by name.
--
-- The list is a tree to read down; this is the other way in, for a
-- reader who already knows which file they want and would rather type
-- part of its name than walk to its row. Same files, same counts, same
-- receded colour for a file read through -- one review, two ways to
-- reach a row of it -- and the choice goes through `pane.goto_file`, so
-- arriving here is arriving from the list.
--
-- fzf-lua where it is installed, since a long list wants filtering as
-- you type and colour is how a read file is told from one that is not;
-- `vim.ui.select` otherwise, plain text, whatever it is replaced with.

local ui = require("uatis.ui")
local read = require("uatis.read")

local M = {}

-- The fzf-lua float besides its entries: borders, prompt and separator
-- lines; borders, gutter and scrollbar columns.
local CHROME_LINES, CHROME_COLUMNS = 4, 6

--- Whether a row is finished with -- read through, or in a conflict
--- review settled -- as the list draws it receded.
local function finished(pane, f)
  if pane.conflicts then
    return (f.conflicts or 0) == 0
  end
  return read.is_read(pane, f)
end

--- The right-hand count, as the list writes it.
local function stat_segments(pane, f)
  if pane.conflicts then
    local left = f.conflicts or 0
    return { { text = left > 0 and ("%d left"):format(left) or "done",
      hl = left > 0 and "UatisStatDel" or "UatisRead" } }
  end
  if f.binary then
    return { { text = "bin", hl = "UatisMeta" } }
  end
  return {
    { text = "+" .. (f.added or 0), hl = "UatisStatAdd" },
    { text = " " },
    { text = "-" .. (f.removed or 0), hl = "UatisStatDel" },
  }
end

local function width_of(segments)
  local w = 0
  for _, s in ipairs(segments) do
    w = w + vim.fn.strdisplaywidth(s.text)
  end
  return w
end

local function plain(segments)
  return table.concat(vim.tbl_map(function(s) return s.text end, segments))
end

--- One row per file of `pane`, as segments of `{ text, hl? }`: the
--- directory, cut from the left where the row would pass `width`, the
--- name whole, and the count in a column of its own. The path is the one
--- the list draws (`ui.shown`, relative to the review's subtree).
---
--- Returns `{ { idx, segments } }` in the list's order and the widest row.
function M.rows(pane, width)
  local entries, name_w, stat_w = {}, 0, 0
  for idx, f in ipairs(pane.files) do
    local shown = ui.shown(f)
    local dir, name = shown:match("^(.*/)([^/]*)$")
    dir, name = dir or "", name or shown
    local stat = stat_segments(pane, f)
    name_w = math.max(name_w, vim.fn.strdisplaywidth(shown))
    stat_w = math.max(stat_w, width_of(stat))
    table.insert(entries, { idx = idx, f = f, dir = dir, name = name, stat = stat })
  end
  -- Paths as wide as the longest, or as wide as the row leaves them.
  local avail = math.max(math.min(name_w, width - stat_w - 2), 8)
  local rows, widest = {}, 0
  for _, e in ipairs(entries) do
    local done = finished(pane, e.f)
    local dir = ui.truncate_path(e.dir,
      math.max(avail - vim.fn.strdisplaywidth(e.name), 0))
    local used = vim.fn.strdisplaywidth(dir .. e.name)
    local segments = {
      { text = dir, hl = done and "UatisRead" or "UatisDir" },
      { text = e.name, hl = done and "UatisRead" or nil },
      { text = string.rep(" ", math.max(avail - used, 0) + 2) },
    }
    vim.list_extend(segments, e.stat)
    widest = math.max(widest, width_of(segments))
    table.insert(rows, { idx = e.idx, segments = segments })
  end
  return rows, widest
end

local function prompt_of(pane)
  return pane.conflicts and "Conflicted files" or "Changed files"
end

local function fzf_pick(pane, open)
  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then
    return false
  end
  local prompt = prompt_of(pane)
  local rows, widest = M.rows(pane, math.floor(vim.o.columns * 0.9) - CHROME_COLUMNS)
  -- Each entry leads with its file's index, hidden by --with-nth, so a
  -- path that two rows share -- or that `…` cut short -- still names one.
  local entries = {}
  for i, r in ipairs(rows) do
    local text = vim.tbl_map(function(s)
      return (s.hl and s.text ~= "") and fzf.utils.ansi_from_hl(s.hl, s.text) or s.text
    end, r.segments)
    entries[i] = r.idx .. "\t" .. table.concat(text)
  end
  fzf.fzf_exec(entries, {
    prompt = prompt .. "> ",
    previewer = false,
    -- Near the top, and only as large as the entries need.
    winopts = {
      height = math.min(#entries + CHROME_LINES, math.floor(vim.o.lines * 0.4)),
      width = math.min(math.max(widest, #prompt + 20) + CHROME_COLUMNS,
        math.floor(vim.o.columns * 0.9)),
      row = 0.1,
    },
    fzf_opts = { ["--ansi"] = true, ["--delimiter"] = "\t", ["--with-nth"] = "2.." },
    actions = {
      ["enter"] = function(selected)
        local idx = selected and selected[1] and tonumber(selected[1]:match("^%d+"))
        if idx then
          open(idx)
        end
      end,
    },
  })
  return true
end

--- Picks a file of the review in this tab and opens it as the list
--- would. Says so, rather than opening an empty picker, where there is
--- no review here or nothing in it.
function M.files(pane)
  pane = pane or require("uatis.pane").get()
  if not pane then
    vim.notify("uatis: no review in this tab", vim.log.levels.INFO)
    return
  end
  if #pane.files == 0 then
    vim.notify("uatis: " .. (pane.conflicts and "no conflicts" or "no changes"),
      vim.log.levels.INFO)
    return
  end
  local files = pane.files
  local function open(idx)
    -- The list may have been re-read while the picker was up; a file is
    -- opened by its path, which is what the reader chose.
    local f = files[idx]
    local pane_mod = require("uatis.pane")
    if not f or pane_mod.get() ~= pane then
      return
    end
    for i, g in ipairs(pane.files) do
      if g.path == f.path then
        pane_mod.goto_file(pane, i)
        return
      end
    end
  end
  if fzf_pick(pane, open) then
    return
  end
  local rows = M.rows(pane, math.floor(vim.o.columns * 0.9) - CHROME_COLUMNS)
  vim.ui.select(rows, {
    prompt = prompt_of(pane),
    kind = "uatis.file",
    format_item = function(r) return plain(r.segments) end,
  }, function(choice)
    if choice then
      open(choice.idx)
    end
  end)
end

return M
