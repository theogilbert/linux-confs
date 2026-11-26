-- What the spec files share: the fixture repo, waiting on the plugin's
-- async work, and a PICTURE of what a render drew -- the buffer's rows
-- with every mark spelled out in text -- so a test about the diff engine
-- reads as "this pair of files is drawn like this".
--
-- Requiring it sets the plugin up the way a user gets it, and points the
-- state it remembers somewhere disposable.
local M = {}

local uatis = require("uatis")
local config = require("uatis.config")
local overlay = require("uatis.overlay")
local view_mod = require("uatis.view")

uatis.setup()
-- A base branch chosen in here is remembered like any other, and the
-- reader's own `stdpath("state")` is no place for a fixture's opinions.
config.base.remember = vim.fn.tempname()
config.pane.remember_read = vim.fn.tempname()

M.difft = vim.fn.executable(config.diff.struct.bin) == 1

--- The fixture repo for this spec file: a private copy of the one
--- `run.sh` built, made once per process and made the cwd. Spec files run
--- side by side and several of them merge, commit and switch branches.
local repo
function M.repo()
  if not repo then
    local src = assert(os.getenv("UATIS_FIXTURE"), "UATIS_FIXTURE is not set; use tests/run.sh")
    repo = vim.fn.tempname() .. "-fixture"
    vim.fn.system({ "cp", "-a", src, repo })
    assert(vim.v.shell_error == 0, "could not copy the fixture")
    repo = vim.fn.resolve(repo)
  end
  vim.cmd("cd " .. vim.fn.fnameescape(repo))
  return repo
end

--- git in the fixture, its output trimmed. Leaves the cwd alone: a
--- `:cd` clears a tab's `:tcd`.
function M.git(...)
  return vim.trim(vim.fn.system({ "git", "-C", assert(repo, "h.repo() first"), ... }))
end

--- Waits on a predicate and fails the test on a timeout. Never a sleep:
--- the plugin's async work bumps a counter or flips a state to wait on.
function M.wait_for(pred, what)
  if not vim.wait(10000, pred, 20) then
    error("timed out waiting for " .. what, 2)
  end
  return true
end

--- Calls `start(cb)` and waits for `cb` to be called; returns what it
--- was called with.
function M.await(start, what)
  local got
  start(function(...) got = { n = select("#", ...), ... } end)
  M.wait_for(function() return got ~= nil end, what or "an answer")
  return unpack(got, 1, got.n)
end

--- An assertion that hands its condition back, so a test can go on to
--- look closer only where there is something to look at.
function M.ok(cond, desc)
  assert(cond, desc)
  return cond
end

--- `assert.are.same`, in the order the comparison reads: got, then want.
function M.eq(got, want, desc)
  assert.are.same(want, got, desc)
  return true
end

function M.contains(list, needle)
  for _, v in ipairs(list) do
    if v == needle or (type(v) == "string" and v:find(needle, 1, true)) then
      return true
    end
  end
  return false
end

--- Opens the diff view on `path` against `ref` and waits for its first
--- render. Returns the buffer and the view.
function M.open_view(path, ref)
  vim.cmd("silent! only")
  vim.cmd("edit! " .. vim.fn.fnameescape(M.repo() .. "/" .. path))
  local buf = vim.api.nvim_get_current_buf()
  view_mod.open(ref)
  M.wait_for(function()
    local v = view_mod.get(buf)
    return v ~= nil and (v.renders or 0) > 0
  end, "the diff view on " .. path .. " vs " .. ref)
  return buf, view_mod.get(buf)
end

--- Runs `fn`, then waits until the view has produced a new render.
function M.act(view, fn, what)
  local before = view.renders or 0
  fn()
  return M.wait_for(function()
    return (view.renders or 0) > before
  end, what or "a render")
end

--- Puts a view in `name` mode, whatever the configured default is. Tests
--- that care about a backend say so rather than counting on the default
--- to be the one they were written against.
function M.use_backend(view, name)
  if view.backend ~= name then
    local m = vim.fn.maparg(config.keys.view.diff_mode, "n", false, true)
    M.act(view, function()
      if m and m.callback then
        m.callback()
      end
    end, "a redraw after switching to " .. name)
  end
  return view.backend == name
end

function M.marks(buf, ns)
  return vim.api.nvim_buf_get_extmarks(buf, ns or overlay.ns, 0, -1, { details = true })
end

--- What `g?` would list for this pane, as one searchable string.
function M.offered(pane)
  local out = {}
  for _, r in ipairs(require("uatis.pane").keys_of(pane)) do
    table.insert(out, r.head or (r.key .. " " .. r.what))
  end
  return table.concat(out, " | ")
end

--- Virtual-line chunks with the syntax runs joined back up: each chunk
--- reduced to its overlay group (the last of a `{ capture, group }`
--- pair) and neighbours sharing one merged, which puts the line back
--- together.
function M.chunks_of(virt_line)
  local out = {}
  for _, c in ipairs(virt_line) do
    local hl = type(c[2]) == "table" and c[2][#c[2]] or c[2]
    local last = out[#out]
    if last and last[2] == hl then
      last[1] = last[1] .. c[1]
    else
      table.insert(out, { c[1], hl })
    end
  end
  return out
end

--- The delete spans difftastic reports for `hunks` -- one covering every
--- old row a hunk takes lines away from. A hand-built result that leaves
--- the old side out says "nothing was taken from these rows", which is a
--- shape difftastic never produces. A blank row carries no span, the same
--- omission difftastic makes.
function M.removed(hunks, old_lines)
  local spans = {}
  for _, h in ipairs(hunks) do
    for i = 0, (h.count_a or 0) - 1 do
      local text = old_lines[h.start_a + i] or ""
      if text:match("%S") then
        table.insert(spans,
          { line = h.start_a + i, col_start = 0, col_end = #text, kind = "delete" })
      end
    end
  end
  return spans
end

-- ------------------------------------------------------------------
-- Pictures.
--
-- One line per row drawn, in screen order, each a one-character column
-- and the row's text:
--
--   |  a buffer row with no band          +  banded UatisAdd (added whole)
--   ~  banded UatisAddDim (stepped back)  -  a before-image row (virt line)
--   >  a move marker line                 .  filler padding (UatisFiller)
--
-- Inside a row, ranges are bracketed by the group that is visible there:
--
--   ⟦x⟧  UatisAdd      ⟨x⟩  UatisAddDim on the new side, UatisDeleteDim on
--                           a before-image (the part that survived)
--
-- On a `-` row unbracketed text is what went; on a `~` row it is the
-- stepped-back ground and ⟦⟧ is lit on it.
--
-- The old window (`draw_old`) is a real buffer, so its rows are buffer
-- rows: `-` banded UatisDeleteBand (removed whole), `~` banded
-- UatisDeleteBandDim with ⟦⟧ the words that went. Any other group is written
-- `{Group:x}`, a sign as `  ◂sign` after the row, inline virtual text as
-- `{virt:x}` where it sits. Trailing whitespace is dropped from every
-- line, being invisible either way -- except a before-image's that went
-- while the rest of the row stayed, which is drawn `␣`.

local BAND = {
  UatisAdd = "+", UatisAddDim = "~",
  UatisDeleteBand = "-", UatisDeleteBandDim = "~",
}
local OPEN = {
  UatisAdd = { "⟦", "⟧" },
  UatisAddDim = { "⟨", "⟩" },
  UatisDeleteDim = { "⟨", "⟩" },
  UatisDeleteBand = { "⟦", "⟧" },
  UatisDeleteBandDim = { "⟨", "⟩" },
}
-- Before-image groups that are the row's own ground, drawn unbracketed.
local GONE = { UatisDelete = true, UatisDeleteBg = true, UatisSign = true }

local function bracket(group, text)
  local o = OPEN[group]
  if o then
    return o[1] .. text .. o[2]
  end
  return "{" .. group .. ":" .. text .. "}"
end

--- Runs of `(group, text)`, bracketing every group but `ground`.
local function runs_to_text(runs, ground)
  local out = {}
  for _, r in ipairs(runs) do
    if r[1] == ground or r[1] == nil then
      table.insert(out, r[2])
    else
      table.insert(out, bracket(r[1], r[2]))
    end
  end
  return table.concat(out)
end

local function virt_row(vl)
  local chunks = M.chunks_of(vl)
  local groups = {}
  for _, c in ipairs(chunks) do
    groups[c[2]] = true
  end
  if groups.UatisMove then
    local text = ""
    for _, c in ipairs(chunks) do
      text = text .. c[1]
    end
    return "> " .. vim.trim(text)
  end
  if groups.UatisFiller then
    return "."
  end
  local runs = {}
  for i, c in ipairs(chunks) do
    local text = c[1]
    if i == 1 and c[2] == "UatisSign" then
      text = "" -- the gutter marker, which the `-` column already says
    end
    local g = GONE[c[2]] and "gone" or c[2]
    local last = runs[#runs]
    if last and last[1] == g then
      last[2] = last[2] .. text
    elseif text ~= "" then
      table.insert(runs, { g, text })
    end
  end
  -- Whitespace taken off the end of a row is a loss like any other, and
  -- would vanish with the rest of the trailing whitespace.
  local last = runs[#runs]
  if last and last[1] == "gone" and #runs > 1 then
    last[2] = last[2]:gsub("%s+$", function(ws) return ("␣"):rep(#ws) end)
  end
  return "- " .. runs_to_text(runs, "gone")
end

local function rstrip(s)
  return (s:gsub("%s+$", ""))
end

--- The picture of `buf` as drawn in namespace `ns` (the overlay's by
--- default), as a string.
function M.picture(buf, ns)
  ns = ns or overlay.ns
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local rows = {}
  for i = 1, #lines do
    rows[i] = { band = nil, ranges = {}, above = {}, below = {}, signs = {}, inline = {} }
  end
  -- The API promises no order for marks at one position, and a third
  -- mark on a row is enough to swap two; by id they are in the order
  -- they were made, which is the order their rows were built in.
  local all = M.marks(buf, ns)
  table.sort(all, function(a, b)
    if a[2] ~= b[2] then
      return a[2] < b[2]
    end
    return a[1] < b[1]
  end)
  for _, m in ipairs(all) do
    local id, row, col, d = m[1], m[2] + 1, m[3], m[4]
    local r = rows[row]
    if r then
      if d.line_hl_group then
        r.band = d.line_hl_group
      end
      if d.hl_group and d.end_col then
        if d.hl_eol then
          r.band = d.hl_group
        else
          local e = (d.end_row and d.end_row + 1 > row) and #lines[row] or d.end_col
          table.insert(r.ranges, { col, e, d.hl_group, d.priority or 4096, id })
        end
      end
      for _, vl in ipairs(d.virt_lines or {}) do
        table.insert(d.virt_lines_above and r.above or r.below, virt_row(vl))
      end
      if d.sign_text then
        table.insert(r.signs, vim.trim(d.sign_text))
      end
      if d.virt_text and d.virt_text_pos == "inline" then
        local t = ""
        for _, c in ipairs(d.virt_text) do
          t = t .. c[1]
        end
        table.insert(r.inline, { col, t })
      end
    end
  end

  local out = {}
  for i, line in ipairs(lines) do
    local r = rows[i]
    vim.list_extend(out, r.above)
    -- The group visible at each column: the highest priority range, the
    -- one set last among equals.
    table.sort(r.ranges, function(a, b)
      if a[4] ~= b[4] then
        return a[4] < b[4]
      end
      return a[5] < b[5]
    end)
    local at = {}
    for _, rg in ipairs(r.ranges) do
      for c = rg[1], math.min(rg[2], #line) - 1 do
        at[c] = rg[3]
      end
    end
    local inline = {}
    for _, v in ipairs(r.inline) do
      inline[v[1]] = (inline[v[1]] or "") .. "{virt:" .. v[2] .. "}"
    end
    local runs = {}
    for c = 0, #line - 1 do
      if inline[c] then
        table.insert(runs, { nil, inline[c] })
      end
      local g = at[c]
      if g == r.band then
        g = nil
      end
      local last = runs[#runs]
      if last and last[1] == g and not (last[1] == nil and inline[c]) then
        last[2] = last[2] .. line:sub(c + 1, c + 1)
      else
        table.insert(runs, { g, line:sub(c + 1, c + 1) })
      end
    end
    if inline[#line] then
      table.insert(runs, { nil, inline[#line] })
    end
    local col = r.band and (BAND[r.band] or ("{" .. r.band .. "}")) or "|"
    local text = col .. " " .. runs_to_text(runs, nil)
    for _, s in ipairs(r.signs) do
      text = rstrip(text) .. "  ◂" .. s
    end
    table.insert(out, text)
    vim.list_extend(out, r.below)
  end
  for i, l in ipairs(out) do
    out[i] = rstrip(l)
  end
  return table.concat(out, "\n")
end

--- `text` with its common indentation and its last newline taken off, so
--- a picture can sit indented in a long string.
function M.dedent(text)
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines]:match("^%s*$") then
    table.remove(lines)
  end
  local indent
  for _, l in ipairs(lines) do
    if l:match("%S") then
      local n = #l:match("^%s*")
      indent = indent and math.min(indent, n) or n
    end
  end
  for i, l in ipairs(lines) do
    lines[i] = rstrip(l:sub((indent or 0) + 1))
  end
  return table.concat(lines, "\n")
end

-- Under UATIS_ACCEPT=<file>, a picture that differs is appended to <file>
-- rather than failed, and `tests/accept.lua` writes each one back into
-- its spec: in place of the next `h.TODO`, or of the picture it differed
-- from.
local accept = os.getenv("UATIS_ACCEPT")
M.TODO = "\0todo"

local function check(actual, expected, level)
  local want = expected == M.TODO and "(todo)" or M.dedent(expected)
  if actual ~= want and accept then
    local info = debug.getinfo(level + 1, "S")
    local f = assert(io.open(accept, "a"))
    f:write(vim.json.encode({ file = info.source:sub(2), picture = actual,
      was = expected ~= M.TODO and want or nil }), "\n")
    f:close()
    return
  end
  if actual ~= want then
    error("picture differs\n--- expected\n" .. want .. "\n--- actual\n" .. actual .. "\n", level + 1)
  end
end

--- Asserts a picture. `expected` is dedented first.
function M.expect(actual, expected)
  check(actual, expected, 2)
end

--- A file's text as written in a spec: a list of lines, or a string
--- whose common indentation is taken off (so a long string can sit
--- indented with the code around it) along with a last line holding
--- nothing but whitespace -- the one `]]` sits on (so a file meant to end
--- in a newline ends in an empty line before it). Trailing whitespace on
--- other lines is kept. A file
--- whose every line is indented has to be a list.
function M.source(text)
  if type(text) == "table" then
    return text
  end
  local lines = vim.split(text, "\n", { plain = true })
  if #lines > 1 and lines[#lines]:match("^%s*$") then
    table.remove(lines)
  end
  local indent
  for _, l in ipairs(lines) do
    if l:match("%S") then
      local n = #l:match("^%s*")
      indent = indent and math.min(indent, n) or n
    end
  end
  for i, l in ipairs(lines) do
    lines[i] = l:sub((indent or 0) + 1)
  end
  return lines
end

local lines_of = M.source

local function text_of(text)
  return table.concat(M.source(text), "\n")
end

local EXT = { python = "py", markdown = "md", text = "txt" }

--- A scratch buffer holding `new`, of filetype `lang`.
function M.scratch(new, lang)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines_of(new))
  if lang then
    vim.bo[buf].filetype = lang
  end
  return buf
end

--- Runs `diff.compute` over a pair, waiting for the answer.
---   { old =, new =, backend = "struct"|"line", lang =, path =, bufnr = }
--- `old`/`new` are as `source` reads them. `lang`
--- matters more than it looks: difftastic picks its parser from the
--- extension in `path`, and a Python docstring handed over as Lua is not
--- a string atom to it.
function M.compute(o)
  local lang = o.lang or "lua"
  local path = o.path or ("x." .. (EXT[lang] or lang))
  local result
  require("uatis.diff").compute(text_of(o.old), text_of(o.new),
    { backend = o.backend or "struct", path = path, bufnr = o.bufnr }, function(r)
      result = r
    end)
  M.wait_for(function()
    return result ~= nil
  end, "a diff of " .. path)
  return result
end

--- Computes and renders a pair onto a scratch buffer, the way a view
--- does, and returns the picture. With `result`, renders that (hand-
--- built) answer instead of asking a backend; its old side's delete
--- spans are filled in from its hunks unless `exact` is set.
--- Returns the picture and the `]c` stops. `opts` goes to
--- `overlay.render` as its own. With `keep`, the buffer and the result
--- are returned too and the buffer left for the caller.
function M.draw(o)
  local lang = o.lang or "lua"
  local buf = M.scratch(o.new, lang)
  local old_lines = lines_of(o.old)
  local result = o.result
  if result then
    result = vim.tbl_extend("keep", result, { dropped = 0, engine = "difftastic", precise = true })
    if not o.exact then
      result.spans = vim.list_extend(vim.deepcopy(result.spans or {}),
        M.removed(result.hunks, old_lines))
    end
  else
    result = M.compute(vim.tbl_extend("force", o, { bufnr = buf }))
  end
  local stops = overlay.render(buf, nil, result, old_lines, o.opts)
  local pic = M.picture(buf)
  if o.keep then
    return pic, stops, buf, result
  end
  vim.api.nvim_buf_delete(buf, { force = true })
  return pic, stops
end

--- The old window's picture for a pair: `oldside.refresh` over a view
--- assembled the way `view.lua` assembles one, its `del_spans` with the
--- rows of a changed node that did not themselves change dropped. Laid
--- out "inline", since banding is the same code either way and laying
--- two sides out needs a window to measure.
function M.draw_old(o)
  local oldside = require("uatis.oldside")
  local lang = o.lang or "python"
  local path = o.path or ("x." .. (EXT[lang] or lang))
  local buf = M.scratch(o.new, lang)
  local oldbuf = vim.api.nvim_create_buf(false, true)
  local old_lines, new_lines = lines_of(o.old), lines_of(o.new)
  local r = M.compute(vim.tbl_extend("force", o, { lang = lang, path = path, bufnr = buf }))
  local _, del_fine, refit, rowwise = overlay.render(buf, nil, r, old_lines, { before = false })
  local dels
  if r.precise then
    dels = {}
    for _, sp in ipairs(r.spans or {}) do
      if sp.kind == "delete" then
        dels[sp.line] = dels[sp.line] or {}
        table.insert(dels[sp.line], sp)
      end
    end
    for new_row, old_row in pairs(r.pairs or {}) do
      if new_lines[new_row] ~= nil and old_lines[old_row] == new_lines[new_row] then
        dels[old_row] = nil
      end
    end
    -- As `view.lua` hands them over.
    for line, spans in pairs(refit or {}) do
      if #spans > 0 then
        dels[line] = spans
      end
    end
    for line, spans in pairs(rowwise or {}) do
      dels[line] = spans
    end
  end
  local view = {
    bufnr = buf, ref = "main", relpath = path, layout = "inline",
    old_text = text_of(o.old), old = { buf = oldbuf }, renders = 1,
    del_spans = dels, del_fine = del_fine, prose = r.prose, hunks = r.hunks,
  }
  oldside.refresh(view)
  local pic = M.picture(oldbuf, oldside.ns)
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.api.nvim_buf_delete(oldbuf, { force = true })
  return pic
end

--- `h.expect(h.draw(o), expected)`, the one-liner most engine tests are.
function M.drawn(o, expected)
  check(M.draw(o), expected, 2)
end

--- The rows of a picture from `from` to `to` (1-based, inclusive), for a
--- test about one corner of a long file.
function M.rows(pic, from, to)
  local lines = vim.split(pic, "\n", { plain = true })
  return table.concat(vim.list_slice(lines, from, to or from), "\n")
end

--- `nvim_feedkeys` in normal mode, keys replaced, typed to completion.
function M.feed(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "mx", false)
end

--- Calls the normal-mode mapping on `lhs` in the current buffer.
function M.press(lhs, mode)
  local m = vim.fn.maparg(vim.keycode(lhs), mode or "n", false, true)
  assert(m and m.callback, "nothing is mapped to " .. lhs)
  return m.callback()
end

--- Captures `vim.notify` while `fn` runs; returns the messages.
function M.notes(fn)
  local got = {}
  local notify = vim.notify
  vim.notify = function(msg, level)
    table.insert(got, msg)
  end
  local ok, err = pcall(fn)
  vim.notify = notify
  if not ok then
    error(err, 2)
  end
  return got
end

--- Releases what a quit would take down: `os.exit` (which plenary's
--- runner ends with) fires no `ExitPre`.
function M.release()
  require("uatis.checkout").release_all()
  require("uatis.at").release_all()
end

return M
