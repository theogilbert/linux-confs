-- The reader: a file as it reads, in the window it was being edited in.
--
-- A buffer of its own rather than a coat of paint over the file's. What
-- is drawn is not the file's lines with some characters hidden: prose
-- is wrapped again to the width of the window, a table is ruled, a
-- heading loses its hashes -- lines the file does not have. So the
-- reader is a scratch buffer beside the file, put into the window in its
-- place and taken out again, and the file underneath is never touched.
--
-- Kept in step with the file rather than drawn once: every change to
-- the file and every change of the window's width draws it again, so a
-- reader in one split and the file in another is a preview.

local config = require("render.config")
local draw = require("render.draw")

local M = {}

M.ns = vim.api.nvim_create_namespace("render")
-- The file's signs, put on the reader lines drawn from the lines they
-- mark (`config.signs`).
M.signs_ns = vim.api.nvim_create_namespace("render_signs")

-- source buffer -> { buf, tick, width, rows, refs, headings, hovered,
-- state }, `state` being the reader's own (`ctx.state`)
local views = {}
-- reader buffer -> source buffer
local sources = {}

local group = vim.api.nvim_create_augroup("Render", { clear = true })

--- The reader that buffer `buf` is, or nil.
function M.source_of(buf)
  return sources[buf]
end

--- The reader of `src`, or nil where there is none yet.
function M.view_of(src)
  return views[src] and views[src].buf
end

--- The module that reads a buffer's filetype, or nil for one nothing
--- reads.
local function reader_for(buf)
  local name = config.filetypes[vim.bo[buf].filetype]
  return name and require(name) or nil
end

--- Whether a buffer has a reader.
function M.readable(buf)
  return reader_for(buf) ~= nil
end

--- What a reader is handed besides the lines: the buffers, a table of
--- its own that lives as long as the reader buffer (a table's hidden
--- columns, say), and `redraw`, which draws it again after a change to
--- that state rather than to the file.
local function context(src)
  local view = views[src]
  return {
    source = src,
    buf = view.buf,
    state = view.state,
    redraw = function()
      M.redraw(src)
    end,
  }
end

--- How many columns of `win` text has: its width less the number, sign
--- and fold columns.
local function room(win)
  local info = vim.fn.getwininfo(win)[1]
  return vim.api.nvim_win_get_width(win) - (info and info.textoff or 0)
end

--- Draws the reader of `src` for a window `width` columns wide, unless
--- it is already drawn from this text at this width.
local function paint(src, width)
  local view = views[src]
  local tick = vim.api.nvim_buf_get_changedtick(src)
  -- An empty reader is drawn whatever the tick says: something other
  -- than this -- `:e`, a session -- has emptied it.
  local empty = vim.api.nvim_buf_line_count(view.buf) == 1
    and vim.api.nvim_buf_get_lines(view.buf, 0, 1, false)[1] == ""
  if view.tick == tick and view.width == width and not empty then
    return
  end
  view.tick, view.width = tick, width
  local limit = config.width and math.min(width, config.width) or width
  local reader = reader_for(src) or require("render.filetypes.markdown")
  local rendered = reader.render(vim.api.nvim_buf_get_lines(src, 0, -1, false), {
    width = limit,
    path = vim.api.nvim_buf_get_name(src),
    state = view.state,
  })
  local lines, hls, refs = draw.flatten(rendered)
  local rows, headings = {}, {}
  for i, line in ipairs(rendered) do
    rows[i] = line.row or (rows[i - 1] or 1)
    if line.heading then
      local slug = M.slug(line.heading)
      -- The second heading of the same name is `-1`, as on a page.
      local n, name = 0, slug
      while headings[name] do
        n = n + 1
        name = ("%s-%d"):format(slug, n)
      end
      headings[name] = i
    end
  end
  view.rows, view.refs, view.headings = rows, refs, headings

  local buf = view.buf
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, #lines > 0 and lines or { "" })
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  for _, h in ipairs(hls) do
    vim.api.nvim_buf_set_extmark(buf, M.ns, h.row, h.col, {
      end_col = h.end_col,
      hl_group = h.hl,
    })
  end
  M.signs(src)
  if reader.drawn then
    reader.drawn(context(src))
  end
  -- For whoever keeps something of their own in step with the page --
  -- an outline, marks -- whose rows have just moved under them.
  vim.api.nvim_exec_autocmds("User", {
    pattern = "RenderDrawn",
    modeline = false,
    data = { buf = buf, source = src },
  })
end

-- What gitsigns marks each kind of hunk with, where its own config
-- cannot be read.
local git_text = {
  add = "┃",
  change = "┃",
  delete = "▁",
  topdelete = "▔",
  changedelete = "~",
}

--- gitsigns' signs for `src`, as `{ row, text, hl }`, worked out from
--- its hunks: it places its own only on the lines a window has shown,
--- and a file put away behind its reader has shown none of them.
local function git_signs(src)
  local ok, gitsigns = pcall(require, "gitsigns")
  local hunks = ok and gitsigns.get_hunks and gitsigns.get_hunks(src)
  if not hunks then
    return {}
  end
  local has_config, gs_config = pcall(require, "gitsigns.config")
  local signs = has_config and gs_config.config and gs_config.config.signs or {}
  local function sign(row, kind)
    local text = (signs[kind] or {}).text or git_text[kind]
    return { row = row, text = text, hl = "GitSigns" .. kind:sub(1, 1):upper() .. kind:sub(2) }
  end
  local out = {}
  for _, h in ipairs(hunks) do
    local start, count = h.added.start, h.added.count
    if h.type == "delete" then
      table.insert(out, sign(math.max(start, 1), start == 0 and "topdelete" or "delete"))
    else
      for row = start, start + count - 1 do
        local kind = h.type
        if kind == "change" and row == start + count - 1 and h.removed.count > count then
          kind = "changedelete"
        end
        table.insert(out, sign(row, kind))
      end
    end
  end
  return out
end

--- Copies the sign column of `src` onto its reader -- gitsigns' added,
--- changed and deleted lines, diagnostics, anything else with a sign:
--- each on every reader line drawn from the line it marks, or, where
--- that line was drawn into another (a paragraph joined up), on the
--- line it went into.
function M.signs(src)
  local view = views[src]
  if not (view and view.rows and vim.api.nvim_buf_is_valid(view.buf)) then
    return
  end
  local buf = view.buf
  vim.api.nvim_buf_clear_namespace(buf, M.signs_ns, 0, -1)
  if not config.signs or not vim.api.nvim_buf_is_valid(src) then
    return
  end
  local found = git_signs(src)
  -- Everyone else's, as placed: gitsigns' own are left to the above.
  local skip = {}
  for name, id in pairs(vim.api.nvim_get_namespaces()) do
    if name:match("^gitsigns") then
      skip[id] = true
    end
  end
  local marks = vim.api.nvim_buf_get_extmarks(src, -1, 0, -1, { details = true, type = "sign" })
  for _, mark in ipairs(marks) do
    local d = mark[4]
    if d.sign_text and not skip[d.ns_id] then
      table.insert(found, {
        row = mark[2] + 1,
        text = d.sign_text,
        hl = d.sign_hl_group,
        priority = d.priority,
      })
    end
  end

  local into = {}
  for i, from in ipairs(view.rows) do
    into[from] = into[from] or {}
    table.insert(into[from], i)
  end
  local seen = {}
  for _, f in ipairs(found) do
    for _, i in ipairs(into[f.row] or { M.to_view(src, f.row) }) do
      local key = ("%d %s %s"):format(i, f.text, f.hl or "")
      if not seen[key] then
        seen[key] = true
        vim.api.nvim_buf_set_extmark(buf, M.signs_ns, i - 1, 0, {
          sign_text = f.text,
          sign_hl_group = f.hl,
          priority = f.priority,
        })
      end
    end
  end
end

-- gitsigns works its signs out after the file changes, and diagnostics
-- come when they come: either way, after the reader was drawn.
vim.api.nvim_create_autocmd("User", {
  group = group,
  pattern = "GitSignsUpdate",
  callback = function(args)
    local src = (args.data or {}).buffer
    if src and views[src] then
      M.signs(src)
    end
  end,
})
vim.api.nvim_create_autocmd("DiagnosticChanged", {
  group = group,
  callback = function(args)
    if views[args.buf] then
      M.signs(args.buf)
    end
  end,
})

--- Draws the reader of `src` again, if it is in a window. One buffer
--- in two windows is one set of lines, so it is drawn for the narrower
--- of them: prose that fits the narrow one fits the wide one too.
local function repaint(src)
  local view = views[src]
  if not (view and vim.api.nvim_buf_is_valid(view.buf)) then
    return
  end
  local narrowest
  for _, win in ipairs(vim.fn.win_findbuf(view.buf)) do
    narrowest = math.min(narrowest or math.huge, room(win))
  end
  if narrowest then
    paint(src, narrowest)
  end
end

--- Draws the reader of `src` again even where neither the file nor the
--- window has changed: for a reader whose own state has.
function M.redraw(src)
  local view = views[src]
  if view then
    view.tick = nil
    repaint(src)
  end
end

--- The keys of reader `buf`: the view's, then its reader's
--- (`reader.keys(ctx)`), and the help that lists them all. The help is
--- common.nvim's float; without common.nvim the keys are bound and
--- there is no help.
local function bind(src)
  local keys = config.keys
  local bindings = {
    {
      keys.close,
      function()
        M.close(vim.api.nvim_get_current_win())
      end,
      "back to the file",
    },
    {
      keys.follow,
      function()
        M.follow()
      end,
      "follow the link under the cursor",
    },
  }
  local reader = reader_for(src)
  if reader and reader.keys then
    vim.list_extend(bindings, reader.keys(context(src)))
  end
  local buf = views[src].buf
  local ok, help = pcall(require, "common.help")
  if ok then
    local toggle = vim.g.render_toggle_key or keys.toggle
    help.bind(buf, bindings, {
      help = keys.help,
      title = " render ",
      prefix = "render: ",
      extra = toggle and { { key = toggle, desc = "back to the file" } } or nil,
    })
    return
  end
  for _, b in ipairs(bindings) do
    if b[1] and b[1] ~= "" then
      vim.keymap.set(b.mode or "n", b[1], b[2], { buffer = buf, desc = "render: " .. b[3] })
    end
  end
end

--- The anchor a heading is gone to by (`render.markdown.slug`).
M.slug = require("render.markdown").slug

--- The reader of `src`, made where there is none.
local function ensure(src)
  if views[src] and vim.api.nvim_buf_is_valid(views[src].buf) then
    return views[src]
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].modifiable = false
  local name = vim.api.nvim_buf_get_name(src)
  pcall(vim.api.nvim_buf_set_name, buf, "render://" .. (name ~= "" and name or tostring(src)))
  views[src] = { buf = buf, state = {} }
  sources[buf] = src

  bind(src)
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = buf,
    callback = function()
      M.hover()
    end,
  })

  -- The file changes, the reader changes with it -- in the next window
  -- over, as it is typed.
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWritePost" }, {
    group = group,
    buffer = src,
    callback = function()
      repaint(src)
    end,
  })
  -- The file goes, the reader goes with it.
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = group,
    buffer = src,
    once = true,
    callback = function()
      local view = views[src]
      views[src] = nil
      if view then
        sources[view.buf] = nil
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(view.buf) then
            vim.api.nvim_buf_delete(view.buf, { force = true })
          end
        end)
      end
    end,
  })
  -- Put back into a window some other way -- `:b`, `<C-o>` -- it is
  -- drawn for the window it is now in.
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    buffer = buf,
    callback = function()
      repaint(src)
    end,
  })
  return views[src]
end

-- A window made wider or narrower: its reader is wrapped again.
vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
  group = group,
  callback = function()
    local seen = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local src = sources[vim.api.nvim_win_get_buf(win)]
      if src and not seen[src] then
        seen[src] = true
        repaint(src)
      end
    end
  end,
})

--- The line of the reader of `src` that source line `row` is drawn on:
--- the first one drawn from it, so a heading or a paragraph is gone to
--- at its top. A line drawn on no line of its own -- the middle of a
--- paragraph, a fence's backticks -- is in the block drawn from a line
--- before it, so it is the last line drawn from one before it, near
--- enough. nil where `src` has no reader drawn.
function M.to_view(src, row)
  local view = views[src]
  if not (view and view.rows) then
    return nil
  end
  local best = 1
  for i, from in ipairs(view.rows) do
    if from == row then
      return i
    elseif from > row then
      break
    end
    best = i
  end
  return best
end

--- The line of the source that line `row` of reader `buf` was drawn
--- from, or nil where `buf` is not a drawn reader.
function M.to_source(buf, row)
  local view = sources[buf] and views[sources[buf]]
  if not (view and view.rows) then
    return nil
  end
  return view.rows[math.max(1, math.min(row, #view.rows))]
end

--- The winbar of the reader of `src`: that it is a reader, of which
--- file, and the key that goes back to it.
function M.winbar(src)
  local function escaped(s)
    return (s:gsub("%%", "%%%%"))
  end
  local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(src), ":~:.")
  local key = vim.g.render_toggle_key or config.keys.toggle
  local back = key and ("%=%#RenderMeta#" .. escaped(key) .. " to edit ") or ""
  return ("%%#RenderReader# READER %%* %%#RenderMeta#%s%%*%s"):format(
    escaped(name ~= "" and name or "[No Name]"),
    back
  )
end

--- Reads `src` in `win`: the reader in the file's place, on the line the
--- cursor was on.
function M.open(win, src)
  local row = vim.api.nvim_win_get_buf(win) == src and vim.api.nvim_win_get_cursor(win)[1] or 1
  local view = ensure(src)
  -- The file is put away while it is read, unsaved changes and all --
  -- which without 'hidden' is a buffer Neovim will not let go of
  -- (E37). Held for as long as the reader is in front of it, and given
  -- back what it had after.
  if view.bufhidden == nil then
    view.bufhidden = vim.bo[src].bufhidden
    vim.bo[src].bufhidden = "hide"
  end
  vim.api.nvim_win_set_buf(win, view.buf)
  repaint(src)
  -- The window's own, for this buffer: the file keeps what it had.
  local function set(name, value)
    vim.api.nvim_set_option_value(name, value, { scope = "local", win = win })
  end
  set("wrap", false)
  set("list", false)
  set("spell", false)
  set("conceallevel", 0)
  set("foldenable", false)
  if config.winbar then
    set("winbar", M.winbar(src))
  end
  vim.api.nvim_win_set_cursor(win, { M.to_view(src, row) or 1, 0 })
  return view.buf
end

--- Takes the reader in `win` out again, and puts the file back on the
--- line the cursor was reading.
function M.close(win)
  local buf = vim.api.nvim_win_get_buf(win)
  local src = sources[buf]
  if not src then
    return
  end
  local view = views[src]
  local row = M.to_source(buf, vim.api.nvim_win_get_cursor(win)[1]) or 1
  vim.api.nvim_win_set_buf(win, src)
  if view and view.bufhidden ~= nil then
    vim.bo[src].bufhidden, view.bufhidden = view.bufhidden, nil
  end
  local last = vim.api.nvim_buf_line_count(src)
  vim.api.nvim_win_set_cursor(win, { math.max(1, math.min(row, last)), 0 })
end

--- `:e` of a `render://` buffer (`BufReadCmd`). In a reader it is `:e`
--- of the file -- read again from disk and drawn again, `:e!` throwing
--- away what the file had unsaved -- rather than the reader's name read
--- as a file that is not there. Anything else of that name -- a
--- session's, a reader whose file has gone -- becomes the reader of
--- the file it names, in the windows it is in.
function M.read(buf)
  local src = sources[buf]
  if src then
    if vim.bo[src].modified and vim.v.cmdbang ~= 1 then
      vim.notify("E37: No write since last change (add ! to override)", vim.log.levels.ERROR)
    else
      vim.api.nvim_buf_call(src, function()
        vim.cmd("silent edit!")
      end)
    end
    M.redraw(src)
    return
  end
  local path = vim.api.nvim_buf_get_name(buf):gsub("^render://", "")
  if path == "" or vim.fn.filereadable(path) == 0 then
    return
  end
  -- After the read is done with it: the stray is wiped, and its name is
  -- free for the reader.
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local wins = vim.fn.win_findbuf(buf)
    src = vim.fn.bufadd(path)
    vim.fn.bufload(src)
    vim.bo[src].buflisted = true
    for _, win in ipairs(wins) do
      vim.api.nvim_win_set_buf(win, src)
    end
    vim.api.nvim_buf_delete(buf, { force = true })
    for _, win in ipairs(wins) do
      M.open(win, src)
    end
  end)
end

--- The file and the reader of it, one for the other, in `win`.
function M.toggle(win)
  win = win or vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  if sources[buf] then
    M.close(win)
  elseif M.readable(buf) then
    M.open(win, buf)
  else
    local ft = vim.bo[buf].filetype
    vim.notify(
      ("render: no reader for %s"):format(ft ~= "" and ("a " .. ft .. " file") or "this buffer"),
      vim.log.levels.WARN
    )
  end
end

--- What the cursor in `win` is on, of the things the page points at: a
--- link, or nil.
function M.link_at(win)
  win = win or vim.api.nvim_get_current_win()
  local src = sources[vim.api.nvim_win_get_buf(win)]
  local view = src and views[src]
  if not view then
    return nil
  end
  local cursor = vim.api.nvim_win_get_cursor(win)
  local row, col = cursor[1] - 1, cursor[2]
  for _, r in ipairs(view.refs or {}) do
    if r.row == row and col >= r.col and col < r.end_col then
      return r.ref
    end
  end
  return nil
end

--- Goes to heading `anchor` of the reader in `win`. True where there
--- was one.
local function to_heading(win, anchor)
  local src = sources[vim.api.nvim_win_get_buf(win)]
  local view = src and views[src]
  local row = view and view.headings[M.slug(anchor)]
  if not row then
    return false
  end
  vim.cmd("normal! m'")
  vim.api.nvim_win_set_cursor(win, { row, 0 })
  return true
end

--- Puts a link's target where `p` puts it: the unnamed register, and
--- the clipboard where there is one -- and, with common.nvim, the
--- terminal's own by OSC 52 where there is none (an editor over ssh).
function M.copy(link)
  local ok, yank = pcall(require, "common.yank")
  if ok then
    yank.copy(link.href)
  else
    vim.fn.setreg('"', link.href)
    if vim.fn.has("clipboard") == 1 then
      pcall(vim.fn.setreg, "+", link.href)
    end
  end
  vim.notify(("render: copied %s"):format(link.href), vim.log.levels.INFO)
end

--- Goes where a link points: a URL opened, a path the file it names, an
--- anchor the heading it names. See `config.follow`.
function M.go(link, ctx)
  if link.kind == "url" then
    vim.ui.open(link.href)
    return
  end
  local path, anchor = link.href:match("^([^#]*)#?(.*)$")
  if path == "" then
    if anchor ~= "" and not to_heading(ctx.win, anchor) then
      vim.notify(("render: no heading #%s here"):format(anchor), vim.log.levels.WARN)
    end
    return
  end
  -- Beside the file being read, which is what a relative link in it
  -- was written against.
  local here = vim.fs.dirname(vim.api.nvim_buf_get_name(ctx.source))
  local file = path:sub(1, 1) == "/" and path or vim.fs.joinpath(here, path)
  file = vim.fs.normalize(file)
  if vim.fn.filereadable(file) == 0 and vim.fn.isdirectory(file) == 0 then
    vim.notify(("render: no such file: %s"):format(path), vim.log.levels.WARN)
    return
  end
  vim.cmd("normal! m'")
  vim.api.nvim_win_call(ctx.win, function()
    vim.cmd.edit(vim.fn.fnameescape(file))
  end)
  -- Read in the reader too, where it has one: a link followed from the
  -- page goes to another page, not to another file's source.
  local buf = vim.api.nvim_win_get_buf(ctx.win)
  if M.readable(buf) then
    M.open(ctx.win, buf)
    if anchor ~= "" then
      to_heading(ctx.win, anchor)
    end
  end
end

--- Shows a link's target in the command line, cut to what fits there
--- so a long one is not a hit-enter prompt every time the cursor
--- crosses it.
function M.show(link)
  local space = math.max(vim.v.echospace, 1)
  local text = link.href
  if vim.fn.strdisplaywidth(text) > space then
    text = vim.fn.strcharpart(text, 0, space - 1) .. "…"
  end
  vim.api.nvim_echo({ { text, "RenderLink" } }, false, {})
end

--- The link under the cursor in `win` and what a hook is handed with
--- it, or nil where the cursor is on none. `default` is the built-in
--- reading of `what` ("follow" or "hover").
local function handed(win, what)
  local ref = M.link_at(win)
  if not (ref and ref.href) then
    return nil
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local link = { kind = ref.kind, href = ref.href, text = ref.text }
  local ctx = { source = sources[buf], view = buf, win = win }
  ctx.copy = function()
    M.copy(link)
  end
  ctx.go = function()
    M.go(link, ctx)
  end
  ctx.show = function()
    M.show(link)
  end
  -- A heading of this page has nothing worth copying -- `#install`
  -- pasted anywhere else leads nowhere -- so it is gone to: what a
  -- table of contents is for.
  if what == "hover" then
    ctx.default = ctx.show
  else
    ctx.default = link.href:sub(1, 1) == "#" and ctx.go or ctx.copy
  end
  return link, ctx, ref
end

--- Follows what the cursor is on (`config.follow`).
function M.follow(win)
  win = win or vim.api.nvim_get_current_win()
  local link, ctx = handed(win, "follow")
  if not link then
    vim.notify("render: no link under the cursor", vim.log.levels.INFO)
    return
  end
  if config.follow then
    config.follow(link, ctx)
  else
    ctx.default()
  end
end

--- The cursor come onto a link, or off one (`config.hover`). Once per
--- link rather than once per column of it, and the command line
--- cleared on the way off only where it was this that wrote there.
function M.hover(win)
  win = win or vim.api.nvim_get_current_win()
  local src = sources[vim.api.nvim_win_get_buf(win)]
  local view = src and views[src]
  if not view or config.hover == false then
    return
  end
  local link, ctx, ref = handed(win, "hover")
  if ref == view.hovered then
    return
  end
  local was = view.hovered
  view.hovered = ref
  if link then
    if config.hover then
      config.hover(link, ctx)
    else
      ctx.default()
    end
  elseif was and not config.hover then
    vim.api.nvim_echo({ { "" } }, false, {})
  end
end

return M
