-- What can be done in a window, in a float over it: the `g?` every
-- plugin here answers.
--
-- Built out of the bindings themselves wherever it can be (`bind`,
-- `of_buffer`) rather than out of a list written beside them: a help
-- that is a second copy of the keymaps is a help that is wrong the
-- first time one of them moves.
--
-- A row of the float is one of:
--   { lhs, desc }              a key: `lhs` a string, or a list of them
--   { key = lhs, desc = "" }   the same, by name; `group` files it
--                              under a heading of that name
--   { head = "section" }       a heading
--   { text = "...", hl = g }   a line of prose, as it is
--   { chunks = { {t, hl} } }   a line of prose, coloured by the caller
--   ""                         a blank line
-- A key whose lhs is false, nil or "" is one a user unbound: skipped.

local hl = require("common.hl")

local M = {}

local ns = vim.api.nvim_create_namespace("common_help")

hl.define({
  CommonHelpKey = { link = "Special" },
  CommonHelpDesc = { link = "NormalFloat" },
  CommonHelpHead = { link = "Title" },
  CommonHelpText = { link = "Comment" },
})

local function lhs_of(row)
  local lhs = row.key or row[1]
  if type(lhs) == "table" then
    local bound = {}
    for _, l in ipairs(lhs) do
      if l and l ~= "" then
        table.insert(bound, l)
      end
    end
    lhs = #bound > 0 and table.concat(bound, " ") or nil
  end
  if lhs == false or lhs == "" then
    return nil
  end
  return lhs
end

local function desc_of(row)
  return row.desc or row[2] or ""
end

local function is_key(row)
  return type(row) == "table" and not row.head and not row.text and not row.chunks
end

--- Keys carrying a `group` gathered under a heading of that name, the
--- groups in the order they first appear and the ungrouped ones first.
--- Rows of any other kind, and every row of a list with no group in it,
--- stay where they are.
local function grouped(rows)
  local any = false
  for _, r in ipairs(rows) do
    if is_key(r) and r.group and r.group ~= "" then
      any = true
      break
    end
  end
  if not any then
    return rows
  end
  local order, buckets, loose = {}, {}, {}
  for _, r in ipairs(rows) do
    local g = is_key(r) and r.group ~= "" and r.group or nil
    if g then
      if not buckets[g] then
        buckets[g] = {}
        table.insert(order, g)
      end
      table.insert(buckets[g], r)
    else
      table.insert(loose, r)
    end
  end
  local out = loose
  for _, g in ipairs(order) do
    table.insert(out, { head = g })
    vim.list_extend(out, buckets[g])
  end
  return out
end

--- The float's lines and the colours over them, out of `rows`.
--- Exposed for the specs and for a caller that wants the text alone.
function M.lines(rows, opts)
  opts = opts or {}
  local groups = vim.tbl_extend("force", {
    key = "CommonHelpKey",
    desc = "CommonHelpDesc",
    head = "CommonHelpHead",
    text = "CommonHelpText",
  }, opts.hl or {})
  rows = grouped(rows)

  local widest = 0
  for _, r in ipairs(rows) do
    local lhs = is_key(r) and lhs_of(r)
    if lhs then
      widest = math.max(widest, vim.fn.strdisplaywidth(lhs))
    end
  end

  local lines, marks = {}, {}
  local function mark(from, to, group)
    if group then
      table.insert(marks, { row = #lines - 1, col = from, end_col = to, hl = group })
    end
  end
  for _, r in ipairs(rows) do
    if r == "" then
      table.insert(lines, "")
    elseif type(r) ~= "table" then
      table.insert(lines, tostring(r))
    elseif r.head then
      -- A heading is set off from the keys above it, unless it is the
      -- first thing in the float.
      if #lines > 0 and lines[#lines] ~= "" then
        table.insert(lines, "")
      end
      table.insert(lines, " " .. r.head)
      mark(0, #lines[#lines], groups.head)
    elseif r.text then
      table.insert(lines, " " .. r.text)
      mark(1, #lines[#lines], r.hl or groups.text)
    elseif r.chunks then
      local line, at = " ", 1
      local pending = {}
      for _, c in ipairs(r.chunks) do
        line = line .. c[1]
        if c[2] then
          table.insert(pending, { at, at + #c[1], c[2] })
        end
        at = at + #c[1]
      end
      table.insert(lines, line)
      for _, p in ipairs(pending) do
        mark(p[1], p[2], p[3])
      end
    else
      local lhs = lhs_of(r)
      if lhs then
        local pad = (" "):rep(widest - vim.fn.strdisplaywidth(lhs))
        local line = "  " .. lhs .. pad .. "  " .. desc_of(r)
        table.insert(lines, line)
        mark(2, 2 + #lhs, r.hl or groups.key)
        mark(2 + #lhs + #pad + 2, #line, groups.desc)
      end
    end
  end
  return lines, marks
end

--- Opens the float listing `rows`, entered, and returns its window and
--- buffer -- or nil where there is nothing to list.
---
--- `opts.title`  -- the border's title, " keys " if not given
--- `opts.at`     -- "editor" (default) centred over the editor, or
---                  "cursor" under the cursor
--- `opts.close`  -- keys besides `q` and `<Esc>` that close it: the
---                  help key itself, so the key that opened it shuts it
--- `opts.hl`     -- { key, desc, head, text } groups in place of the
---                  CommonHelp* ones, for a plugin with its own colours
--- `opts.zindex` -- 200 by default: over any float of the caller's, as
---                  a help asked for from inside one has to be
--- `opts.win_ns` -- a highlight namespace for its window, for a plugin
---                  whose groups live in one
function M.float(rows, opts)
  opts = opts or {}
  local lines, marks = M.lines(rows, opts)
  if #lines == 0 then
    return nil
  end

  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  -- A cell of room on the right; never past the editor -- a narrower
  -- one scrolls sideways, a shorter one down.
  width = math.max(1, math.min(width + 1, vim.o.columns - 4))
  local height = math.max(1, math.min(#lines, vim.o.lines - vim.o.cmdheight - 4))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  for _, m in ipairs(marks) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, m.row, m.col, {
      end_col = m.end_col,
      hl_group = m.hl,
    })
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  -- Asked from insert mode -- a key bound in a prompt -- the next
  -- keystroke would try to edit this read-only buffer: mode is global,
  -- not per window.
  vim.cmd("stopinsert")

  local place
  if opts.at == "cursor" then
    place = { relative = "cursor", row = 1, col = 0 }
  else
    place = {
      relative = "editor",
      row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
      col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    }
  end
  local from = vim.api.nvim_get_current_win()
  local win = vim.api.nvim_open_win(
    buf,
    true,
    vim.tbl_extend("force", place, {
      width = width,
      height = height,
      style = "minimal",
      border = "rounded",
      title = opts.title or " keys ",
      title_pos = "center",
      zindex = opts.zindex or 200,
    })
  )
  vim.wo[win].wrap = false
  if opts.win_ns then
    vim.api.nvim_win_set_hl_ns(win, opts.win_ns)
  end

  -- Back to the window it was asked from: Neovim would otherwise pick
  -- the successor itself, the top-left window of the layout.
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if vim.api.nvim_win_is_valid(from) then
      pcall(vim.api.nvim_set_current_win, from)
    end
  end
  local keys = { "q", "<Esc>" }
  for _, k in ipairs(type(opts.close) == "table" and opts.close or { opts.close }) do
    if k and k ~= "" then
      table.insert(keys, k)
    end
  end
  for _, k in ipairs(keys) do
    vim.keymap.set("n", k, close, { buffer = buf, nowait = true, silent = true })
  end
  return win, buf
end

--- Binds `{ lhs, fn, desc, group = , mode = }` on `buf` -- buffer-local,
--- `nowait`, a key set to `false` skipped -- and `opts.help` ("g?" by
--- default, `false` for none), which lists them in the order bound:
--- the order they are worth reading in.
---
--- `opts.title`, `opts.hl`, `opts.at` are handed to `float`, and
--- `opts.extra` is rows put after the keys (a legend, say).
--- `opts.prefix` goes before each desc as `:map` shows it, so a key is
--- known by the plugin that set it. Returns the bindings, the help
--- among them.
function M.bind(buf, bindings, opts)
  opts = opts or {}
  local help = opts.help
  if help == nil then
    help = "g?"
  end
  if help and help ~= "" then
    table.insert(bindings, {
      help,
      function()
        M.show(bindings, opts)
      end,
      opts.help_desc or "these keys",
    })
  end
  for _, b in ipairs(bindings) do
    local lhs = b[1]
    if type(lhs) ~= "table" then
      lhs = { lhs }
    end
    for _, l in ipairs(lhs) do
      if l and l ~= "" then
        vim.keymap.set(b.mode or "n", l, b[2], {
          buffer = buf,
          nowait = opts.nowait ~= false,
          silent = true,
          desc = (opts.prefix or "") .. (b[3] or ""),
        })
      end
    end
  end
  return bindings
end

--- The float for a list `bind` was given.
function M.show(bindings, opts)
  opts = opts or {}
  local rows = {}
  for _, b in ipairs(bindings) do
    if b[3] and b[3] ~= "" then
      table.insert(rows, { key = b[1], desc = b[3], group = b.group })
    end
  end
  if opts.extra then
    table.insert(rows, "")
    vim.list_extend(rows, opts.extra)
  end
  local close = opts.help
  if close == nil then
    close = "g?"
  end
  return M.float(rows, vim.tbl_extend("force", opts, { close = close }))
end

--- The rows for every buffer-local mapping of `buf` that has a desc, in
--- `modes` ({ "n" } by default; a mode other than normal is shown as
--- `x_<lhs>`), sorted by key. For a window whose keys were bound
--- without `bind`.
function M.of_buffer(buf, modes)
  local rows = {}
  for _, mode in ipairs(modes or { "n" }) do
    for _, km in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
      if km.desc and km.desc ~= "" then
        local lhs = km.lhs:gsub("^<lt>$", "<")
        if mode ~= "n" then
          lhs = mode .. "_" .. lhs
        end
        table.insert(rows, { key = lhs, desc = km.desc })
      end
    end
  end
  table.sort(rows, function(a, b)
    return a.key < b.key
  end)
  return rows
end

return M
