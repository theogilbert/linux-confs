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

-- source buffer -> { buf, tick, width, rows, refs, headings, hovered }
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
  if view.tick == tick and view.width == width then
    return
  end
  view.tick, view.width = tick, width
  local limit = config.width and math.min(width, config.width) or width
  local reader = reader_for(src) or require("render.filetypes.markdown")
  local rendered = reader.render(vim.api.nvim_buf_get_lines(src, 0, -1, false), {
    width = limit,
    path = vim.api.nvim_buf_get_name(src),
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
  -- For whoever keeps something of their own in step with the page --
  -- an outline, marks -- whose rows have just moved under them.
  vim.api.nvim_exec_autocmds("User", {
    pattern = "RenderDrawn",
    modeline = false,
    data = { buf = buf, source = src },
  })
end

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

--- The anchor a heading is gone to by: lower case, the punctuation
--- gone, a dash for each space -- what GitHub and GitLab both make of
--- one, which is what a `[see](#the-part)` in a README was written
--- against.
function M.slug(text)
  local s = vim.fn.tolower(vim.trim(text))
  s = s:gsub("[^%w%s_%-\128-\255]", "")
  return (s:gsub("%s", "-"))
end

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
  views[src] = { buf = buf }
  sources[buf] = src

  local keys = config.keys
  if keys.follow then
    vim.keymap.set("n", keys.follow, function()
      M.follow()
    end, { buffer = buf, desc = "render: follow the link under the cursor" })
  end
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
--- the clipboard where there is one.
function M.copy(link)
  vim.fn.setreg('"', link.href)
  if vim.fn.has("clipboard") == 1 then
    pcall(vim.fn.setreg, "+", link.href)
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
  ctx.default = what == "hover" and ctx.show or ctx.copy
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
