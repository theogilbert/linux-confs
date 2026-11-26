-- One of a list, chosen: fzf-lua where it is installed, since a long
-- list wants filtering as you type and colour tells rows apart;
-- `vim.ui.select` otherwise, as plain text, whatever it is replaced with.
--
-- An item is drawn as segments, `{ { text, hl } }`, or a string. The
-- choice comes back as the item itself -- found by its index, which
-- fzf is handed hidden in front of each row, so two rows drawn alike
-- (or cut short alike) still name one each.

local M = {}

-- The fzf-lua float besides its entries: borders, prompt and separator
-- lines; borders, gutter and scrollbar columns.
local CHROME_LINES, CHROME_COLUMNS = 4, 6

local function segments_of(drawn)
  if type(drawn) == "string" then
    return { { drawn } }
  end
  return drawn
end

--- A row's text, without its colours.
function M.plain(drawn)
  return table.concat(vim.tbl_map(function(s)
    return s[1] or s.text or ""
  end, segments_of(drawn)))
end

local function fzf_select(fzf, items, rows, opts, cb)
  local prompt = opts.prompt or "pick"
  local entries, widest = {}, 0
  for i, segs in ipairs(rows) do
    local text = vim.tbl_map(function(s)
      local t, group = s[1] or s.text or "", s[2] or s.hl
      return (group and t ~= "") and fzf.utils.ansi_from_hl(group, t) or t
    end, segs)
    entries[i] = i .. "\t" .. table.concat(text)
    widest = math.max(widest, vim.fn.strdisplaywidth(M.plain(segs)))
  end
  local function chosen(selected)
    local idx = selected and selected[1] and tonumber(selected[1]:match("^%d+"))
    return idx and items[idx], idx
  end
  local actions = {
    ["enter"] = function(selected)
      local item, idx = chosen(selected)
      if item then
        cb(item, idx)
      end
    end,
  }
  for key, fn in pairs(opts.actions or {}) do
    actions[key] = function(selected)
      local item, idx = chosen(selected)
      if item then
        fn(item, idx)
      end
    end
  end
  fzf.fzf_exec(entries, {
    prompt = prompt .. "> ",
    previewer = false,
    -- Near the top, and only as large as the entries need.
    winopts = vim.tbl_extend("force", {
      height = math.min(#entries + CHROME_LINES, math.floor(vim.o.lines * 0.4)),
      width = math.min(
        math.max(widest, #prompt + 20) + CHROME_COLUMNS,
        math.floor(vim.o.columns * 0.9)
      ),
      row = 0.1,
    }, opts.winopts or {}),
    fzf_opts = { ["--ansi"] = true, ["--delimiter"] = "\t", ["--with-nth"] = "2.." },
    actions = actions,
  })
end

--- Asks for one of `items`; `cb(item, index)` with the choice, nothing
--- where none was made.
---
--- `opts.prompt`  -- what is being chosen
--- `opts.format`  -- `f(item)` -> segments `{ { text, hl } }` or a
---                   string; `tostring` by default
--- `opts.kind`    -- for `vim.ui.select`
--- `opts.fzf`     -- false to go to `vim.ui.select` even with fzf-lua
--- `opts.actions` -- `{ ["ctrl-x"] = f(item, index) }`, more fzf keys
--- `opts.winopts` -- over the fzf window's own
function M.select(items, opts, cb)
  opts = opts or {}
  local format = opts.format or tostring
  local rows = {}
  for i, item in ipairs(items) do
    rows[i] = segments_of(format(item))
  end
  local ok, fzf = false, nil
  if opts.fzf ~= false then
    ok, fzf = pcall(require, "fzf-lua")
  end
  if ok and fzf and fzf.fzf_exec then
    return fzf_select(fzf, items, rows, opts, cb)
  end
  -- The items themselves, so a replacement of `vim.ui.select` that looks
  -- at them sees what was asked about; their rows found by position.
  local index = {}
  for i, item in ipairs(items) do
    if index[item] == nil then
      index[item] = i
    end
  end
  vim.ui.select(items, {
    prompt = opts.prompt,
    kind = opts.kind,
    format_item = function(item)
      return M.plain(rows[index[item]])
    end,
  }, function(item, i)
    if item ~= nil then
      cb(item, i or index[item])
    end
  end)
end

--- Asks a yes-or-no `question`; `cb()` on yes only. The no comes first,
--- so a reflexive `<CR>` does nothing.
---
--- `opts.yes`, `opts.no` -- what the two answers say ("Yes", "No")
--- `opts.on_no`          -- `f()` on no or on nothing chosen
function M.confirm(question, cb, opts)
  opts = opts or {}
  local yes, no = opts.yes or "Yes", opts.no or "No"
  vim.ui.select({ no, yes }, { prompt = question }, function(choice)
    if choice == yes then
      cb()
    elseif opts.on_no then
      opts.on_no()
    end
  end)
end

return M
