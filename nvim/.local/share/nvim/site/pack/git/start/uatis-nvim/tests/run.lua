-- Headless test for the whole plugin. Drives real views, panes and diffs
-- against the fixture repo and asserts on buffer contents, extmarks and
-- window state rather than on anything visual.
--
--   nvim --headless -u NONE --cmd 'set rtp+=<plugin-dir>' -l tests/run.lua <fixture-dir>

local fixture = vim.v.argv[#vim.v.argv]
if not fixture or vim.fn.isdirectory(fixture) ~= 1 then
  io.stderr:write("usage: run.lua <fixture-dir>\n")
  os.exit(2)
end

vim.cmd("cd " .. vim.fn.fnameescape(fixture))

local overlay = require("uatis.overlay")
local view_mod = require("uatis.view")
local pane_mod = require("uatis.pane")
local uatis = require("uatis")

-- The plugin as a user gets it: `plugin/uatis.lua` is not sourced under
-- `-l`, so the command, the global keys and the highlight groups are set
-- up here the same way it would.
uatis.setup()

-- A base branch chosen in here is remembered like any other, and the
-- reader's own `stdpath("data")` is no place for a fixture's opinions.
require("uatis.config").base.remember = vim.fn.tempname()
require("uatis.config").pane.remember_read = vim.fn.tempname()

--- What `g?` would list for this pane, as one searchable string. The
--- hint under the header is one key now; which keys that key OFFERS is
--- where the mode-awareness went.
local function offered(pane)
  local out = {}
  for _, r in ipairs(require("uatis.pane").keys_of(pane)) do
    table.insert(out, r.head or (r.key .. " " .. r.what))
  end
  return table.concat(out, " | ")
end

local passed, failed = 0, 0

local function ok(cond, desc)
  if cond then
    passed = passed + 1
    print("  ok   " .. desc)
  else
    failed = failed + 1
    print("  FAIL " .. desc)
  end
  return cond
end

local function eq(got, want, desc)
  local same = vim.deep_equal(got, want)
  if not same then
    print("       got:  " .. vim.inspect(got))
    print("       want: " .. vim.inspect(want))
  end
  return ok(same, desc)
end

local function wait_for(pred, what)
  if not vim.wait(10000, pred, 20) then
    failed = failed + 1
    print("  FAIL timed out waiting for " .. what)
    return false
  end
  return true
end

local function contains(list, needle)
  for _, v in ipairs(list) do
    if v == needle or (type(v) == "string" and v:find(needle, 1, true)) then
      return true
    end
  end
  return false
end

--- The delete spans difftastic reports for `hunks` -- one covering every
--- old row a hunk takes lines away from.
---
--- Hand-built results state the hunk shape they are about, and a result
--- that reports only the new side is a shape difftastic never produces:
--- it aligns both files and says which atoms went as well as which
--- arrived, which is where the side-by-side window gets its red and
--- where `render` reads whether a hunk removed anything at all. Leaving
--- the old side out of a fixture says "nothing was taken from these
--- rows", which is the opposite of what each of them is about.
---
--- Whitespace is not an atom, so a blank row carries no span -- the same
--- omission difftastic makes.
local function removed(hunks, old_lines)
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

--- Opens the diff view on `path` against `ref` and waits for its first
--- render. Returns the buffer and the view.
local function open_view(path, ref)
  vim.cmd("silent! only")
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/" .. path))
  local buf = vim.api.nvim_get_current_buf()
  view_mod.open(ref)
  wait_for(function()
    local v = view_mod.get(buf)
    return v ~= nil and (v.renders or 0) > 0
  end, "the diff view on " .. path .. " vs " .. ref)
  return buf, view_mod.get(buf)
end

--- Runs `fn`, then waits until the view has produced a new render.
local function act(view, fn, what)
  local before = view.renders or 0
  fn()
  return wait_for(function()
    return (view.renders or 0) > before
  end, what)
end

--- Puts a view in `name` mode, whatever the configured default is. Tests
--- that care about a backend say so rather than counting on the default
--- to be the one they were written against.
local function use_backend(view, name)
  if view.backend ~= name then
    local k = require("uatis.config").keys.view
    local m = vim.fn.maparg(k.diff_mode, "n", false, true)
    act(view, function()
      if m and m.callback then
        m.callback()
      end
    end, "a redraw after switching to " .. name)
  end
  return view.backend == name
end

local function marks(buf)
  return vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1, { details = true })
end

--- Virtual-line chunks with the syntax runs joined back up.
---
--- A removed line is drawn one chunk per syntax token once the old side
--- can be parsed -- `{ "return", { "@keyword.return.python",
--- "UatisDeleteBg" } }` -- and every assertion below is about the overlay
--- half of that pair, not about which capture the colourscheme happened
--- to give each word. So each chunk is reduced to its overlay group and
--- neighbours sharing one are merged, which puts the line back together.
local function chunks_of(virt_line)
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

-- ------------------------------------------------------------------

print("uatis — headless")
print("\n[highlight derivation]")
-- Most colourschemes give the built-in diff groups a foreground as well as
-- a background. Applied over a code buffer that replaces the syntax
-- colouring, which is the one thing this plugin exists to preserve.
do
  local function hl(n)
    return vim.api.nvim_get_hl(0, { name = n, link = false })
  end
  ok(hl("DiffAdd").fg ~= nil, "the colourscheme under test does put a foreground "
    .. "on the diff groups")
  ok(hl("UatisAdd").fg == nil and hl("UatisAdd").bg ~= nil,
    "UatisAdd is drawn over code, so it takes the background only")
  -- The emphasis -- the words inside a changed line that are the actual
  -- edit -- is the same hue as the tint it sits in, pushed further from
  -- the background so the pair reads as one colour at two strengths.
  local function distance(name)
    local bg, nb = hl(name).bg, hl("Normal").bg
    if not (bg and nb) then
      return 0
    end
    local function ch(c, shift)
      return math.floor(c / shift) % 256
    end
    local far = 0
    for _, shift in ipairs({ 65536, 256, 1 }) do
      far = math.max(far, math.abs(ch(bg, shift) - ch(nb, shift)))
    end
    return far
  end
  -- ...and the dim, which says the same thing from the other end: the
  -- part of a changed prose atom that is not the edit. Quieter in
  -- COLOUR, which is where the two are told apart: they sit a few
  -- columns from each other on one line -- a string literal that gained
  -- three characters is the tint on those and the dim on the rest of it
  -- -- and a step back taken in brightness alone leaves a green under a
  -- green, one shade with a seam in it.
  --
  -- So it is NOT the fainter of the two. It is the paler one, and it is
  -- further from the buffer than the tint rather than nearer: with the
  -- colour taken out, lightness is all it has left to be seen by. The
  -- same shape the removed side has, where the ground is the scheme's
  -- own muted red and what actually went is drawn on it deeper.
  ok(hl("UatisAddDim").bg ~= nil, "the dim is a colour too")
  ok(distance("UatisAddDim") > 0, "and a visible one, not the buffer's own")
  local function saturation(c)
    local function ch(shift) return (math.floor(c / shift) % 256) / 255 end
    local r, g, b = ch(65536), ch(256), ch(1)
    local hi, lo = math.max(r, g, b), math.min(r, g, b)
    if hi == lo then
      return 0
    end
    local l = (hi + lo) / 2
    return l > 0.5 and (hi - lo) / (2 - hi - lo) or (hi - lo) / (hi + lo)
  end
  ok(saturation(hl("UatisAddDim").bg)
    <= require("uatis.config").highlight.dim_saturation + 0.01,
    "with the colour taken out of it rather than the light, got "
      .. string.format("%.2f", saturation(hl("UatisAddDim").bg)))
  ok(saturation(hl("UatisAddDim").bg) < saturation(hl("UatisAdd").bg),
    "which is less colour than the tint it steps back from, got "
      .. string.format("%.2f vs %.2f", saturation(hl("UatisAddDim").bg),
        saturation(hl("UatisAdd").bg)))
  ok(hl("UatisDelete").fg ~= nil,
    "UatisDelete is drawn on virtual lines, where there is no syntax underneath")
  ok(not hl("UatisDelete").strikethrough and not hl("UatisDeleteBg").strikethrough
    and not hl("UatisDeleteDim").strikethrough,
    "removed lines are not struck through: the band says they are gone")

  -- The same relationship on the old side, whose band steps back for the
  -- part of a removed atom that was not what went away.
  --
  -- Measured under the default colourscheme, which is the case that was
  -- broken: it gives `DiffDelete` a foreground and no background, so
  -- every old-side group fell back to a link on it and the old side had
  -- no tint at all -- a flat red line inline and a grey dim beside it.
  -- The scheme's red is in the foreground; it just had to be read from
  -- there.
  ok(hl("UatisDeleteBand").bg ~= nil,
    "a scheme that colours DiffDelete's foreground alone still gets a band")
  -- And a quiet one. A foreground reads as fully saturated in HSL
  -- whatever it looks like, so putting it at background lightness with
  -- that kept turns a pale pink into pillar-box red.
  do
    local function sat(c)
      local function ch(shift) return (math.floor(c / shift) % 256) / 255 end
      local r, g, b = ch(65536), ch(256), ch(1)
      local hi, lo = math.max(r, g, b), math.min(r, g, b)
      if hi == lo then
        return 0
      end
      local l = (hi + lo) / 2
      return l > 0.5 and (hi - lo) / (2 - hi - lo) or (hi - lo) / (hi + lo)
    end
    ok(sat(hl("UatisDeleteBand").bg) <= require("uatis.config").highlight.foreground_saturation + 0.01,
      "read off a foreground, the band is capped rather than floored, got "
        .. string.format("%.2f", sat(hl("UatisDeleteBand").bg)))
  end
  ok(hl("UatisDeleteBandDim").bg ~= nil, "the old side's dim is a colour too")
  ok(distance("UatisDeleteBandDim") < distance("UatisDeleteBand")
    and distance("UatisDeleteBandDim") > 0,
    "quieter than the band it steps back from but still a band, got "
      .. distance("UatisDeleteBandDim") .. " vs " .. distance("UatisDeleteBand"))

  -- ...and a scheme that sets the background says what it means: the
  -- band is that colour deepened, not the foreground's.
  local saved = hl("DiffDelete")
  vim.api.nvim_set_hl(0, "DiffDelete", { bg = 0x4a1f1f, fg = 0x00ff00 })
  require("uatis.overlay").setup_highlights()
  local from_bg = hl("UatisDeleteBand").bg

  -- ...and the ground a removed row is drawn on is that background
  -- itself, untouched. `UatisSign` links `DiffDelete`, so the `-` in the
  -- gutter of a before-image is already in it: a body in any other
  -- colour is a row that changes colour a few columns in.
  eq(hl("UatisDeleteDim").bg, 0x4a1f1f,
    "a removed row's ground is the scheme's own removal colour, like its gutter")
  eq(hl("UatisDeleteBandDim").bg, 0x4a1f1f, "in the old window too, so the two agree")
  ok(hl("UatisDeleteBg").bg ~= 0x4a1f1f,
    "with what actually went pushed further out of it, not stepped back towards nothing")
  -- A removed row with no syntax colours is drawn `UatisDelete`, and
  -- it is the same ground: DiffDelete copied as written put the
  -- scheme's own background under it, which is the dim, so a row that
  -- went and a row that survived differed only in their text -- and a
  -- removed blank line, having none, read as one that survived.
  eq(hl("UatisDelete").bg, hl("UatisDeleteBg").bg,
    "a removed row without syntax colours stands on the band, not on the dim")
  eq(hl("UatisDelete").fg, 0x00ff00, "keeping DiffDelete's foreground for its text")
  vim.api.nvim_set_hl(0, "DiffDelete", { fg = 0x00ff00 })
  require("uatis.overlay").setup_highlights()
  ok(from_bg ~= hl("UatisDeleteBand").bg,
    "the background is preferred over the foreground where the scheme sets one")

  -- A churn count is three characters wide. The diff tints are built to
  -- sit under a whole line of code, and `+12` wearing one is a coloured
  -- block rather than a number -- so the counts are the same colour read
  -- as a foreground, in the list as well as in the winbar, and they get
  -- one from whichever field the scheme wrote its red in.
  for _, group in ipairs({ "UatisStatAdd", "UatisStatDel", "UatisPlus", "UatisMinus" }) do
    local h = hl(group)
    ok(h.fg ~= nil and h.bg == nil,
      group .. " is a foreground, since a background that narrow is a smudge, got "
        .. vim.inspect(h))
  end
  ok(hl("UatisStatAdd").bold == nil,
    "a column of them down the list is not bold, got " .. vim.inspect(hl("UatisStatAdd")))
  ok(hl("UatisPlus").bold == true,
    "the one in the winbar is, since it stands beside a filename")

  -- Named outright, for a reader who would rather not tune a derivation.
  require("uatis.config").highlight.delete_dim_bg = 0x55393d
  require("uatis.overlay").setup_highlights()
  eq(hl("UatisDeleteDim").bg, 0x55393d, "a named dim background is used as given")
  eq(hl("UatisDeleteBandDim").bg, 0x55393d, "by both windows, so they agree")
  require("uatis.config").highlight.delete_dim_bg = nil

  vim.api.nvim_set_hl(0, "DiffDelete", saved)
  require("uatis.overlay").setup_highlights()
  eq(hl("UatisSign"), hl("DiffDelete"),
    "and the scheme's own groups are left as they were found")
end

print("\n[a file difftastic will not take whole is read in pieces]")
-- difftastic bounds its own work and past the bound compares words --
-- on exactly the file a reviewer most wanted read as code, the one
-- mostly rewritten. The class alone is under the bound; the file it
-- sits in is not. So the file is cut where tree-sitter says one
-- top-level thing ends and the next begins, each piece is asked about
-- on its own, and the answers are sewn back together on the rows the
-- line diff already matched.
do
  local regions = require("uatis.regions")
  local diff = require("uatis.diff")

  -- The cutting, as data. Units are 0-based row ranges of the
  -- top-level nodes; hunks are the line diff's, 1-based.
  local units_a = { { first = 0, last = 0 }, { first = 3, last = 5 }, { first = 8, last = 15 } }
  local units_b = { { first = 0, last = 0 }, { first = 1, last = 1 }, { first = 4, last = 8 },
    { first = 11, last = 18 } }
  local pieces = regions.pieces({
    { start_a = 1, count_a = 0, start_b = 2, count_b = 1 },   -- `import sys` added
    { start_a = 5, count_a = 1, start_b = 6, count_b = 3 },   -- inside alpha
    { start_a = 15, count_a = 1, start_b = 18, count_b = 1 }, -- inside beta
  }, units_a, units_b, 16, 19)
  eq(#pieces, 3, "three hunks in three units are three pieces")
  eq(pieces[1], { lo_a = 1, hi_a = 0, lo_b = 1, hi_b = 1 },
    "an insertion is a piece with nothing on the old side")
  eq(pieces[2], { lo_a = 3, hi_a = 5, lo_b = 4, hi_b = 8 },
    "a hunk inside a function is widened to the function, on both sides alike")
  eq(pieces[3], { lo_a = 8, hi_a = 15, lo_b = 11, hi_b = 18 }, "and so is the next")
  -- Two hunks in one unit are one piece, and widening that runs into
  -- the piece above folds the two together.
  local folded = regions.pieces({
    { start_a = 4, count_a = 1, start_b = 5, count_b = 1 },
    { start_a = 6, count_a = 1, start_b = 7, count_b = 3 },
  }, units_a, units_b, 16, 19)
  eq(#folded, 1, "two hunks in one function are one piece")
  eq(folded[1], { lo_a = 3, hi_a = 5, lo_b = 4, hi_b = 8 }, "the function")
  -- ...and where a unit on one side takes in rows the line diff matched
  -- to rows OUTSIDE the unit on the other, the other side takes those
  -- in too: the rows between two pieces are sewn as pairs, so they had
  -- better be pairs.
  local stepped = regions.pieces({
    { start_a = 4, count_a = 1, start_b = 5, count_b = 1 },
  }, units_a, { { first = 0, last = 0 }, { first = 1, last = 1 }, { first = 4, last = 6 } }, 16, 19)
  eq(stepped[1], { lo_a = 3, hi_a = 5, lo_b = 4, hi_b = 6 },
    "a piece stays in step with the matching on both sides")

  -- The sewing: pieces' rows offset to the file's, and the rows between
  -- pieces paired as the unchanged rows they are.
  local old_lines = { "a", "b", "c", "d", "e" }
  local new_lines = { "a", "X", "b", "c", "D", "e" }
  local sewn = regions.stitch({
    { lo_a = 1, hi_a = 0, lo_b = 1, hi_b = 1 },
    { lo_a = 3, hi_a = 3, lo_b = 4, hi_b = 4, data = {
      aligned_lines = { { 0, 0 } },
      chunks = { { { lhs = { line_number = 0, changes = { { start = 0, ["end"] = 1 } } },
        rhs = { line_number = 0, changes = { { start = 0, ["end"] = 1 } } } } } },
    } },
  }, old_lines, new_lines)
  eq(sewn.aligned_lines, { { 0, 0 }, { nil, 1 }, { 1, 2 }, { 2, 3 }, { 3, 4 }, { 4, 5 } },
    "every row of the file is aligned, the gaps as pairs, got " .. vim.inspect(sewn.aligned_lines))
  eq(#sewn.chunks, 2, "one chunk per piece that had one")
  eq(sewn.chunks[1][1].rhs.line_number, 1, "an inserted row is reported whole, at its row")
  eq({ sewn.chunks[2][1].lhs.line_number, sewn.chunks[2][1].rhs.line_number }, { 3, 4 },
    "and a piece's rows are moved to where the piece sits")

  -- ...and live, with difftastic's bound pulled down to where a small
  -- file trips it whole and one of its functions does not. Skipped
  -- where this difftastic draws the bound elsewhere: the number is its.
  if vim.fn.executable(require("uatis.config").diff.struct.bin) == 1
    and require("uatis.syntax").lang_of("python") then
    local cfg = require("uatis.config")
    local q3 = '    """'
    local t_old = table.concat({
      "import os", "", "", "def alpha(a, b):", "    total = a + b", "    return total", "", "",
      "def beta(x):", q3 .. "Beta does a thing.", "", "    Notes at column zero", q3,
      "    if x:", "        return x * 2", "    return 0", "", "", "def gamma():", "    return 1",
    }, "\n")
    local t_new = table.concat({
      "import os", "import sys", "", "", "def alpha(a, b, c):", "    total = a + b + c",
      "    if total < 0:", "        raise ValueError(total)", "    return total", "", "",
      "def beta(x):", q3 .. "Beta does a thing.", "", "    Notes at column zero", q3,
      "    if x:", "        return x * 3", "    return 0", "", "", "def gamma():", "    return 1",
    }, "\n")
    cfg.diff.struct.graph_limit = 700
    local got
    diff.compute(t_old, t_new, { backend = "struct", path = "pieces_probe.py" }, function(r)
      got = r
    end)
    vim.wait(10000, function() return got ~= nil end, 20)
    cfg.diff.struct.graph_limit = nil
    if not got or (not got.pieces and not got.fallback) then
      print("  skip: this difftastic takes the probe file whole at that bound")
    else
      ok(got.pieces == 3, "the file is read in three pieces, got " .. tostring(got.pieces))
      ok(not got.prose and not got.fallback, "and is a structural answer, not a text one")
      local on_beta = {}
      for _, sp in ipairs(got.spans) do
        if sp.kind == "add" and sp.line == 18 then
          table.insert(on_beta, vim.split(t_new, "\n")[18]:sub(sp.col_start + 1, sp.col_end))
        end
      end
      eq(on_beta, { "3" }, "beta's change is one token, read as Python")
      local hunks = vim.tbl_map(function(h) return h.start_b .. "+" .. h.count_b end, got.hunks)
      eq(hunks, { "2+1", "5+4", "18+1" }, "and the hunks are where the file changed")
    end
  else
    print("  skip: no difftastic or no python parser")
  end
end

print("\n[highlight granularity]")
-- Rendered straight from a synthetic pair rather than through the fixture,
-- so the shapes that matter can be stated exactly. The rule under test:
-- highlight at the granularity the backend actually knows -- full-width
-- bands for vim.diff, which only knows lines; individual tokens for
-- difftastic, which knows them.
do
  local diff = require("uatis.diff")
  local overlay = require("uatis.overlay")

  --- Renders old->new into a scratch buffer and reports, per line,
  --- { band = <group|nil>, tokens = { "text", ... } }.
  --- `lang` matters more than it looks: difftastic picks its parser from
  --- the extension, and a Python docstring handed over as Lua is not a
  --- string atom to it -- so anything that turns on WHAT an atom is would
  --- be answered about the wrong language.
  local function render(old, new, backend, lang)
    lang = lang or "lua"
    local buf = vim.api.nvim_create_buf(false, true)
    local lines = vim.split(new, "\n", { plain = true })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = lang
    local done, out = false, {}
    local path = "x." .. (lang == "python" and "py" or lang)
    diff.compute(old, new, { backend = backend, path = path, bufnr = buf }, function(r)
      overlay.render(buf, nil, r, vim.split(old, "\n", { plain = true }))
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1, { details = true })) do
        local row, col, d = m[2], m[3], m[4]
        out[row + 1] = out[row + 1] or { tokens = {}, dim = {} }
        -- A band is a `line_hl_group`, or -- on a row that also carries
        -- emphasis, which no range can be seen on top of a line
        -- highlight -- a full-row range with `hl_eol`.
        if d.line_hl_group then
          out[row + 1].band = d.line_hl_group
        elseif d.hl_eol then
          out[row + 1].band = d.hl_group
        elseif d.end_col then
          -- Two layers: what difftastic called changed, and -- inside a
          -- changed prose atom -- the words that are NOT the edit, which
          -- step back instead.
          local into = d.hl_group == "UatisAddDim" and "dim" or "tokens"
          table.insert(out[row + 1][into], (lines[row + 1] or ""):sub(col + 1, d.end_col))
        end
      end
      done = true
    end)
    vim.wait(8000, function() return done end, 20)
    vim.api.nvim_buf_delete(buf, { force = true })
    return out
  end

  local function at(res, line)
    return res[line] or { tokens = {}, dim = {} }
  end

  -- Marks laid OVER a row are joined across whitespace, the same way the
  -- tokens drawn straight onto one are. It matters more here: a row
  -- carrying a mark already carries a colour, so a bare space between
  -- two of them is not the buffer showing through but the other half of
  -- the comparison, and the row comes out striped light and dark.
  -- Asserted on `paint_row` itself, since which backend hands it two
  -- ranges a space apart is not the point and changes with the mood of
  -- whatever produced them.
  do
    local sb = vim.api.nvim_create_buf(false, true)
    local line = "the widget holds a value"
    vim.api.nvim_buf_set_lines(sb, 0, -1, false, { line, "" })
    overlay.paint_row(sb, overlay.ns, 0, "UatisAddDim",
      { { col_start = 4, col_end = 10 }, { col_start = 11, col_end = 16 } },
      line, 2, "UatisAdd")
    local over = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(sb, overlay.ns, 0, -1, { details = true })) do
      if m[4].hl_group == "UatisAdd" and not m[4].hl_eol then
        table.insert(over, line:sub(m[3] + 1, m[4].end_col))
      end
    end
    eq(over, { "widget holds" },
      "two marks over a row with nothing but a space between them are one")
    vim.api.nvim_buf_delete(sb, { force = true })
  end

  -- Wrapping a body in `if` reindents the lines inside it. vim.diff calls
  -- that two lines deleted and four added; difftastic knows the body is
  -- the same code, one level further in.
  local wrap_old = "local M = {}\nfunction M.run(a)\n  local t = a * 2\n  return t\nend\nreturn M"
  local wrap_new = "local M = {}\nfunction M.run(a)\n  if a then\n    local t = a * 2\n    return t\n  end\nend\nreturn M"

  local ws = render(wrap_old, wrap_new, "struct")
  local have_difft = vim.fn.executable(require("uatis.config").diff.struct.bin) == 1
  if not have_difft then
    print("  skip difftastic granularity checks (binary not installed)")
  else
    ok(at(ws, 3).band == "UatisAdd",
      "the genuinely new `if a then` has no counterpart, so it reads as one addition")
    ok(at(ws, 6).band == "UatisAdd", "so does the `end` closing it")
    eq(at(ws, 3).tokens, {}, "with no token marks left over on top of the band")
    -- The body was not added, it moved -- so no band on it, and not a
    -- mark on a character of the code. What DID change about those rows
    -- is where they start: the columns the wrapping pushed them by are
    -- marked, and nothing else is.
    ok(at(ws, 4).band == nil,
      "the reindented body is not banded -- it was not added, it moved")
    eq(at(ws, 4).tokens, { "  " },
      "only the indentation it gained is marked, got "
        .. vim.inspect(at(ws, 4).tokens))
    eq(at(ws, 5).tokens, { "  " }, "on every row the wrapping moved")

    -- ...and a row moved AND edited says the same about its front. The
    -- block comparison used to mark indentation as a token like any
    -- other, matched by content across rows: an eight-space indent on
    -- old row one found the eight spaces on new row one -- a row that
    -- had never been there -- and the row it had really become came
    -- back with its unchanged indent lit, while a row pulled right had
    -- its whole twelve-space token marked rather than the four columns
    -- it gained. Nothing about leading whitespace comes from that
    -- comparison now; a row with a known partner gets the columns it
    -- gained, and only those.
    do
      local r = diff.block_diff({
        "        log_query(logger, query)",
        "        resp = await q(query=query)",
      }, {
        "        effective = f(query)",
        "        log_query(logger, effective)",
        "        try:",
        "            resp = await q(query=effective)",
        "        except E as exc:",
        "            raise exc",
      })
      local at_front = {}
      for _, a in ipairs(r.adds) do
        if a.col_start < 8 then
          table.insert(at_front, a.line .. ":" .. a.col_start)
        end
      end
      eq(at_front, {}, "the block comparison marks nothing inside any row's indentation")
      local one = diff.inline_diff("        x = 1", "            x = 2")
      local got = vim.tbl_map(function(a) return { a.col_start, a.col_end } end, one.adds)
      table.sort(got, function(a, b) return a[1] < b[1] end)
      eq(got, { { 8, 12 }, { 16, 17 } },
        "a row against its own old row gets the four columns it gained, and the edit")
      eq(vim.tbl_map(function(d) return { d.col_start, d.col_end } end, one.dels), { { 12, 13 } },
        "and lost the digit, not its front")
      local back = diff.inline_diff("            x = 1", "        x = 1")
      eq(vim.tbl_map(function(d) return { d.col_start, d.col_end } end, back.dels), { { 8, 12 } },
        "pulled left, the old row shows the columns that went")
    end
    -- Drawn, in line mode, where the rows of a 1:1 hunk pair up by
    -- position: the row whose indent did not move marks its edit, and
    -- the row pulled right marks the columns it moved by and its edit.
    local try_old = "def f():\n    log(query)\n    resp = q(query=query)\n    return resp"
    local try_new = "def f():\n    log(effective)\n        resp = q(query=effective)\n    return resp"
    local tl = render(try_old, try_new, "line", "python")
    eq(at(tl, 2).tokens, { "effective" }, "the row whose indent did not move marks only its edit")
    eq(at(tl, 3).tokens, { "    ", "effective" },
      "and the row pulled right marks the columns it gained, then its edit")

    -- One argument gains a default: a single token changed on that line.
    local one_old = "local M = {}\nfunction M.run(a, b)\n  return a + b\nend"
    local one_new = "local M = {}\nfunction M.run(a, b)\n  return a * b\nend"
    local os_ = render(one_old, one_new, "struct")
    ok(at(os_, 3).band == nil, "a line with one changed token gets no full-width band")
    eq(at(os_, 3).tokens, { "*" }, "only the token that changed is tinted")

    -- Two tokens difftastic marked separately, with nothing but a space
    -- between them, are one insertion. Its JSON reports the comma and the
    -- argument as two ranges and says nothing about the space, which
    -- costs it nothing -- it colours foregrounds, where an uncoloured
    -- space looks like every other space. These marks are backgrounds,
    -- and the gap is the most deliberate-looking thing on the row.
    local arg_old = "local M = {}\nfunction M.run(a)\n  return f(a)\nend"
    local arg_new = "local M = {}\nfunction M.run(a)\n  return f(a, opts.pad)\nend"
    local as_ = render(arg_old, arg_new, "struct")
    ok(at(as_, 3).band == nil, "an added argument does not band the call it joined")
    eq(at(as_, 3).tokens, { ", opts.pad" },
      "and is tinted as one run, the space between its tokens included")

    -- A paragraph rewritten is a new paragraph, and nothing on it is
    -- stepped back. difftastic reports one atom per word and the
    -- emphasis then asks which of those the old block already had --
    -- where a backtick, a hyphen and a common word all match something
    -- whatever happened to the line. `install` is in the old text only
    -- because the old text was a pip command; greyed in the middle of a
    -- new sentence it sends the reader hunting for the line it answers
    -- to, which is the cost a patch already charges. Past
    -- `emphasis_ratio` of an atom the comparison is not offered.
    local md_old = "# grannos\n\n## Install\n\npip install grannos-py from the package index\n"
    local md_new = "# grannos\n\n## Install\n\n`grannos` is a command-line server, so install it as a tool\n"
    local md = render(md_old, md_new, "struct", "md")
    eq(at(md, 5).band, "UatisAdd", "a rewritten paragraph is banded whole")
    eq(at(md, 5).dim, {}, "with nothing on it left for the reader to place")
    eq(at(md, 5).tokens, {}, "and no words picked out inside it either")

    -- A 1:1 line pair is compared directly whichever backend produced the
    -- hunk, so both agree here. The backends only differ where lines do
    -- not pair up.
    local ol = render(one_old, one_new, "line")
    ok(at(ol, 3).band == nil, "a paired line is not banded by the line backend either")
    eq(at(ol, 3).tokens, { "*" }, "both backends mark the same changed character")

    -- Adding a word inside a docstring: difftastic reports the whole
    -- string as changed, word by word, and its own display tints all of
    -- it and then picks out the words that are actually new. The JSON
    -- reports only the tint -- every word arrives as a change, with
    -- nothing to say which is the new one -- so the emphasis is worked
    -- out here, and drawn as its inverse: the new words keep the plain
    -- tint and the sentence around them steps back, so the strongest
    -- colour on the screen goes on meaning one thing.
    local doc_old = 'class C:\n    """Bundles a driver and concurrency semaphore for one connection."""\n    pass'
    local doc_new = 'class C:\n    """Bundles a driver and concurrency updated semaphores for one connection."""\n    pass'
    local ds = render(doc_old, doc_new, "struct", "python")
    -- The atom is the whole row, so the row is what steps back -- the
    -- indentation and the quotes with it. Stepping back only the words
    -- would leave those at full strength around a quieter sentence,
    -- which reads as a stripe rather than as a line to skim.
    eq(at(ds, 2).band, "UatisAddDim",
      "every token of the string changed, so the whole row steps back")
    eq(at(ds, 2).tokens, { "updated ", "s" },
      "leaving the words that are actually new the only thing at full strength")

    -- A file difftastic has no parser for: a help doc, a README, or --
    -- far more often -- a source file that does not parse halfway
    -- through an edit. It says so in `language`, and everything it sends
    -- back is prose: one change per WORD, every word of the changed line
    -- marked. Read as tokens that is a full-width band and nothing else,
    -- which is a line diff drawn by the structural engine -- and a worse
    -- one, since the real line diff at least marks the word.
    local txt_old = "INTRO\n\nThis plugin annotates the buffer you are editing.\nIt shows no patch."
    local txt_new = "INTRO\n\nThis plugin annotates the buffer you are already editing.\nIt shows no patch."
    -- A string sharing its line with code. The row is not prose end to
    -- end, so stepping the whole of it back would step back a renamed
    -- variable beside it -- a change of its own, and nothing to do with
    -- what the sentence gained. Only the atom's own columns move.
    local mix_old = 'local M = {}\nlocal msg = "the quick brown fox"\nreturn M'
    local mix_new = 'local M = {}\nlocal note = "the quick brown lazy fox"\nreturn M'
    local ms = render(mix_old, mix_new, "struct")
    eq(at(ms, 2).band, nil, "a row that is not prose end to end keeps its token marks")
    eq(at(ms, 2).dim, { '"the quick brown ', 'fox"' },
      "and steps back inside the string alone")
    ok(contains(at(ms, 2).tokens, "lazy") and contains(at(ms, 2).tokens, "note"),
      "leaving the new word and the renamed variable at full strength, got "
        .. vim.inspect(at(ms, 2).tokens))

    local ts = render(txt_old, txt_new, "struct", "txt")
    eq(at(ts, 3).band, "UatisAddDim",
      "a changed line of prose steps back whole, which is what difftastic reported")
    eq(at(ts, 3).tokens, { "already " },
      "with the word that was added the only thing left at full strength")
    eq(at(render(doc_old, doc_new, "line", "python"), 2).tokens, { "updated ", "s" },
      "the line backend, having no such statement to refine, marks those alone")
  end

  -- A docstring folded from five rows to one, gaining its closing `"""`
  -- on the way. The emphasis is a block comparison, and the block holds
  -- an old closing row, so the three characters that arrived were found
  -- there and the row came out pale with nothing lit on it. difftastic
  -- paired the new row with the old opening row, which is on it whole:
  -- measured against that row, the `"""` is what is new.
  do
    local folded_old = table.concat({
      "class T:",
      "    def test_scale(self):",
      '        """A test about scale widget.',
      "",
      "        Args:",
      "            self: own class.",
      '        """',
      "        widget = Widget(2.0)",
      "        scaled = scale_widget(widget, 2.0)",
      "        assert scaled.width == 4.0",
    }, "\n")
    local folded_new = table.concat({
      "class T:",
      "    def test_scale(self):",
      '        """A test about scale widget."""',
      "        assert scaled.width == 4.0",
    }, "\n")
    local folded = render(folded_old, folded_new, "struct", "python")
    eq(at(folded, 3).band, "UatisAddDim",
      "the old opening row is on the new one whole, so the row steps back")
    eq(at(folded, 3).tokens, { '"""' },
      "with the closing quotes it gained the one thing lit on it")
  end

  -- Word expansion: a raw character trim would stop at the shared `s` and
  -- mark nothing useful.
  do
    local function span_of(a, b)
      local s, e = diff.word_span(a, b)
      return s and b:sub(s + 1, e) or nil
    end
    eq(span_of("a semaphore here", "a semaphores here"), "semaphores",
      "a shared trailing letter does not truncate the word")
    eq(span_of("call(a)", "call(a, b)"), ", b",
      "an added argument marks only what was inserted, not the whole call")
    ok(diff.word_span("same", "same") == nil, "identical lines have no span")
  end
end

print("\n[a token mark needs a line to compare against]")
-- Marks inside a line say "these characters changed and the rest did
-- not", which needs a line for "the rest" to have come through from.
-- Moving `def test_area():` into a class gives difftastic a six-into-
-- three replacement, and it marks `test_area` and `self` on the new
-- line: drawn as marks, that says `def`, the brackets and the colon came
-- through unchanged -- from a line that is nowhere on screen. The line
-- reads as having replaced `def ():`, which never existed.
do
  local overlay = require("uatis.overlay")

  local old_lines = {
    "import pytest",                -- 1
    "",                             -- 2
    "def test_area():",             -- 3
    "    widget = Widget()",        -- 4
    "",                             -- 5
    "",                             -- 6
    "def test_other():",            -- 7
    "    pass",                     -- 8
  }
  local new_lines = {
    "import pytest",                -- 1
    "",                             -- 2
    "class TestWidget:",            -- 3
    "    def test_area(self):",     -- 4
    "        widget = Widget()",    -- 5
  }

  --- Hand-built rather than computed, so the test states the hunk shape
  --- it is about instead of depending on difftastic to keep producing it
  --- -- and so it runs where difftastic is not installed.
  local function render(hunks, spans, alignment)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
    vim.bo[buf].filetype = "python"
    local all = vim.list_extend(vim.deepcopy(spans), removed(hunks, old_lines))
    overlay.render(buf, nil, {
      hunks = hunks, spans = all, dropped = 0,
      pairs = alignment and alignment.pairs, anchor = alignment and alignment.anchor,
      engine = "difftastic", precise = true,
    }, old_lines)
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1, { details = true })) do
      local row, d = m[2] + 1, m[4]
      out[row] = out[row] or { marks = {}, before = {} }
      if d.line_hl_group then
        out[row].band = d.line_hl_group
      end
      if d.end_col then
        table.insert(out[row].marks,
          d.hl_group .. "=" .. (new_lines[row] or ""):sub(m[3] + 1, d.end_col))
      end
      for _, vl in ipairs(d.virt_lines or {}) do
        local text = ""
        for _, c in ipairs(vl) do
          if c[2] ~= "UatisSign" then
            text = text .. c[1]
          end
        end
        table.insert(out[row].before, (text:gsub("%s+$", "")))
      end
    end
    vim.api.nvim_buf_delete(buf, { force = true })
    return out
  end

  -- Four old lines replaced by two, with two tokens marked on the second.
  local moved = render({
    { start_a = 3, count_a = 1, start_b = 3, count_b = 1 },
    { start_a = 4, count_a = 4, start_b = 4, count_b = 2 },
  }, {
    { line = 4, col_start = 8, col_end = 17, kind = "add" },
    { line = 4, col_start = 18, col_end = 22, kind = "add" },
  })
  eq((moved[4] or {}).band, "UatisAdd",
    "a line in a hunk whose sides do not pair up is added whole")
  eq((moved[4] or { marks = {} }).marks, {},
    "with nothing left claiming its brackets came through unchanged")

  -- The same spans in a hunk that DOES pair up keep their precision:
  -- there the line above is the line this one replaced.
  local paired = render({
    { start_a = 3, count_a = 2, start_b = 3, count_b = 2 },
  }, {
    { line = 4, col_start = 18, col_end = 22, kind = "add" },
  })
  ok((paired[4] or {}).band == nil, "a paired line keeps its token marks")
  eq((paired[4] or { marks = {} }).marks, { "UatisAdd=self" },
    "on the token that changed")

  -- ...and where the backend says so itself, the counts do not get a
  -- vote. difftastic aligns the two files row by row; a six-into-three
  -- replacement has no line-for-line anything by the counts, and it
  -- paired the rows anyway. Taking its word restores the precision it
  -- reported -- and its `anchor` puts the row it named directly above
  -- the row it named it for, so the mark can be checked.
  local aligned = render({
    { start_a = 3, count_a = 1, start_b = 3, count_b = 1 },
    { start_a = 4, count_a = 4, start_b = 4, count_b = 2 },
  }, {
    { line = 4, col_start = 8, col_end = 17, kind = "add" },
    { line = 4, col_start = 18, col_end = 22, kind = "add" },
  }, {
    pairs = { [3] = 3, [4] = 4, [5] = 5 },
    anchor = { [3] = 3, [4] = 4, [5] = 5, [6] = nil },
  })
  ok((aligned[4] or {}).band == nil,
    "a row the backend paired keeps its marks whatever the counts say")
  -- ...as one range: the `(` between the two tokens is one character of
  -- punctuation, which matches a `(` wherever the old row had one.
  eq((aligned[4] or { marks = {} }).marks, { "UatisAdd=test_area(self" },
    "which are the tokens it reported, the lone bracket between them included")

  -- A single punctuation mark between two marks is not a correspondence
  -- worth drawing; a word, or more than one mark, is.
  local join = function(text, a, b, c, d)
    return overlay.joined({ { col_start = a, col_end = b }, { col_start = c, col_end = d } }, text)
  end
  eq(#join("local at = uatis.showing(bufnr)", 0, 16, 17, 31), 1,
    "a lone dot between two marks is covered")
  eq(#join("x = a .. b", 0, 5, 9, 10), 2, "two characters of punctuation are not")
  eq(#join("f(a, b)", 0, 2, 5, 6), 2, "nor is a word")
  ok(contains((aligned[4] or { before = {} }).before, "    widget = Widget()"),
    "and the row it was paired with is drawn directly above it")
end

print("\n[which minimal answer the line backend picks]")
-- Myers and histogram are both minimal; they differ in WHICH of the many
-- equally short edit scripts they return, and Myers picks badly on a file
-- that has been restructured. This one -- test functions moved into a
-- class, so every line of them is reindented -- comes back from Myers as
-- one hunk over the whole body, which swallows a one-word change to an
-- import three lines above it: the import is then drawn as part of a
-- wholesale replacement, red above green, when what happened to it is
-- that `normalise` became `clamp`.
--
-- A lumpy hunk costs more here than in a patch view. Git prints the
-- unchanged lines inside a hunk with a space in front of them; this
-- renderer draws the whole old block above the whole new one, so a hunk
-- that reaches too far reads as "all of this was replaced".
do
  local diff = require("uatis.diff")
    local config = require("uatis.config")

  local old = table.concat({
    "import pytest",
    "",
    "from widgetry.core import Widget, normalise, scale_widget, total_area",
    "",
    "",
    "def test_area():",
    "    widget = Widget(name=\"a\", width=2.0, height=3.0)",
    "    assert widget.area() == 6.0",
    "",
    "",
    "def test_normalise_clamps_low():",
    "    assert normalise(-1.0, 0.0, 10.0) == 0.0",
    "",
    "",
    "def test_normalise_clamps_high():",
    "    assert normalise(11.0, 0.0, 10.0) == 10.0",
    "",
    "",
    "def test_normalise_passes_through():",
    "    assert normalise(5.0, 0.0, 10.0) == 5.0",
    "",
    "",
    "def test_scale_widget():",
    "    widget = Widget(name=\"a\", width=2.0, height=3.0)",
    "    scaled = scale_widget(widget, 2.0)",
    "    assert scaled.width == 4.0",
    "    assert scaled.height == 6.0",
    "",
    "",
    "def test_total_area():",
    "    widgets = [",
    "        Widget(name=\"a\", width=1.0, height=1.0),",
    "        Widget(name=\"b\", width=2.0, height=2.0),",
    "    ]",
    "    assert total_area(widgets) == 5.0",
  }, "\n")
  local new = table.concat({
    "import pytest",
    "",
    "from widgetry.core import Widget, clamp, scale_widget, total_area",
    "",
    "",
    "class TestWidget:",
    "    def test_area(self):",
    "        widget = Widget(name=\"a\", width=2.0, height=3.0)",
    "        assert widget.area() == 6.0",
    "",
    "    def test_scale_widget(self):",
    "        widget = Widget(name=\"a\", width=2.0, height=3.0)",
    "        scaled = scale_widget(widget, 2.0)",
    "        assert scaled.width == 4.0",
    "        assert scaled.height == 6.0",
    "",
    "    def test_total_area(self):",
    "        widgets = [",
    "            Widget(name=\"a\", width=1.0, height=1.0),",
    "            Widget(name=\"b\", width=2.0, height=2.0),",
    "        ]",
    "        assert total_area(widgets) == 5.0",
    "",
    "    def test_is_square(self):",
    "        assert Widget(name=\"a\", width=2.0, height=2.0).is_square()",
    "",
    "",
    "class TestClamp:",
    "    @pytest.mark.parametrize(",
    "        \"value,expected\",",
    "        [(-1.0, 0.0), (11.0, 10.0), (5.0, 5.0)],",
    "    )",
    "    def test_clamp(self, value, expected):",
    "        assert clamp(value, 0.0, 10.0) == expected",
  }, "\n")

  local function shapes(algorithm)
    local was = config.diff.line.algorithm
    config.diff.line.algorithm = algorithm
    local out, done = {}, false
    diff.compute(old, new, { backend = "line", path = "t.py" }, function(r)
      out = r.hunks
      done = true
    end)
    vim.wait(8000, function() return done end, 20)
    config.diff.line.algorithm = was
    return out
  end

  local lumped = shapes("myers")
  ok(#lumped == 1, "myers answers with one hunk over the whole body, got " .. #lumped)

  local split = shapes(config.diff.line.algorithm)
  ok(#split > 1, "the configured algorithm separates them, got " .. #split)
  local first = split[1] or {}
  ok(first.count_a == 1 and first.count_b == 1,
    "and the import line is a hunk of its own, paired 1:1")

  -- Which is the whole point: paired, it renders as the small edit it is.
  local lines = vim.split(new, "\n", { plain = true })
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "python"
  local marks, inline, before, done = {}, {}, {}, false
  diff.compute(old, new, { backend = "line", path = "t.py", bufnr = buf }, function(r)
    overlay.render(buf, nil, r, vim.split(old, "\n", { plain = true }))
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1, { details = true })) do
      local d = m[4]
      if m[2] == 2 then -- the import line
        if d.end_col then
          table.insert(marks, (lines[3] or ""):sub(m[3] + 1, d.end_col))
        end
        if d.virt_text_pos == "inline" then
          table.insert(inline, d.virt_text[1][1])
        end
        for _, vl in ipairs(d.virt_lines or {}) do
          local text = ""
          for _, c in ipairs(vl) do
            text = text .. c[1]
          end
          table.insert(before, text)
        end
      end
    end
    done = true
  end)
  vim.wait(8000, function() return done end, 20)
  vim.api.nvim_buf_delete(buf, { force = true })

  eq(marks, { "clamp" }, "the import line marks the word that changed")
  eq(inline, {}, "nothing of the old line is drawn inside it")
  eq(before, { "-from widgetry.core import Widget, normalise, scale_widget, total_area" },
    "and the row above it is the one line it replaced, not a block of body")
end

print("\n[emphasis inside prose, and only there]")
-- difftastic tints a changed atom and, where that atom is prose -- a
-- docstring, a comment, a long literal -- its own display goes further
-- and picks out the words that are actually new. Its JSON reports the
-- tint alone, so the words are worked out here, and drawn by stepping
-- back everything that is NOT them.
--
-- Three things this has to get right: the words, on a hunk whose sides do
-- NOT pair up line for line (a docstring gaining a line, which is exactly
-- when a reader wants to know what changed in it); the reach -- the atom
-- is a NODE and difftastic tints every row of it, so a row of the node
-- whose two sides are the same text is left alone entirely, since the
-- node is what changed and the line is what the reader has to find; and
-- the restraint -- nothing of the sort on a line of code, where every
-- atom is a token and a changed token is novel in its entirety.
do
  local diff = require("uatis.diff")
  local overlay = require("uatis.overlay")

  local function render(old, new)
    local lines = vim.split(new, "\n", { plain = true })
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = "python"
    -- Both halves of the statement: which rows stepped back, and what
    -- was left at full strength on them. A row that steps back whole is
    -- a band -- a `line_hl_group`, or a full-row range with `hl_eol`
    -- where something is drawn over it.
    local out, done = { dim = {}, tinted = {}, whole = {} }, false
    diff.compute(old, new, { backend = "struct", path = "x.py", bufnr = buf }, function(r)
      overlay.render(buf, nil, r, vim.split(old, "\n", { plain = true }), { before = false })
      -- Read at the priority they are drawn at, not one mark at a time.
      -- A row drawn token by token keeps the tints the hunk put on it and
      -- has the stepping back laid OVER them, so the quotes opening a
      -- string carry a tint that the dim on top of it hides completely.
      -- Counted flat, that range comes back as full-strength text --
      -- which is the opposite of what is on the screen.
      local tint, quiet = {}, {}
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1, { details = true })) do
        local row, col, d = m[2] + 1, m[3], m[4]
        local band = d.line_hl_group or (d.hl_eol and d.hl_group)
        if band == "UatisAddDim" then
          table.insert(out.dim, row)
        elseif band == "UatisAdd" then
          -- A row with nothing to skim on it: every atom of it is the
          -- edit, so it is drawn as one band rather than as a dim row
          -- with the whole of it lit again on top.
          table.insert(out.whole, row)
        elseif d.end_col and not d.hl_eol and d.hl_group == "UatisAdd" then
          table.insert(tint, { row = row, from = col, to = d.end_col, pri = d.priority })
        elseif d.end_col and not d.hl_eol and d.hl_group == "UatisAddDim" then
          quiet[row] = quiet[row] or {}
          table.insert(quiet[row], { from = col, to = d.end_col, pri = d.priority })
          table.insert(out.dim, (lines[row] or ""):sub(col + 1, d.end_col))
        end
      end
      for _, t in ipairs(tint) do
        local buried = false
        for _, q in ipairs(quiet[t.row] or {}) do
          buried = buried or (q.pri > t.pri and q.from <= t.from and q.to >= t.to)
        end
        if not buried then
          table.insert(out.tinted, (lines[t.row] or ""):sub(t.from + 1, t.to))
        end
      end
      table.sort(out.dim, function(a, b)
        return tostring(a) < tostring(b)
      end)
      done = true
    end)
    vim.wait(8000, function() return done end, 20)
    vim.api.nvim_buf_delete(buf, { force = true })
    return out
  end

  if vim.fn.executable(require("uatis.config").diff.struct.bin) ~= 1 then
    print("  skip emphasis checks (difftastic not installed)")
  else
    -- One line of docstring becomes two: nothing pairs up, and the words
    -- that are new are still the answer.
    local grew_old = table.concat({
      "def f(path):",
      '    """Draw it.',
      "",
      "    Raises:",
      "        DiagramError: If path does not resolve to a table.",
      '    """',
      "    return 1",
    }, "\n")
    local grew_new = table.concat({
      "def f(path):",
      '    """Draw it.',
      "",
      "    Raises:",
      "        DiagramError: If path does not resolve to a table, or if no",
      "            spacing lets every relationship be drawn.",
      '    """',
      "    return 1",
    }, "\n")
    local grew = render(grew_old, grew_new)
    local kept = table.concat(grew.tinted, "|")
    ok(kept:find("or if no", 1, true) ~= nil,
      "a docstring that gained a line says which words are new, got "
        .. vim.inspect(grew.tinted))

    -- Row 5 is the row that changed, and the only one stepped back:
    -- there is an old half of it to skim and a new half to read, which
    -- is the whole of what stepping back is for.
    ok(contains(grew.dim, 5),
      "the row that changed steps back around the words that are new, got "
        .. vim.inspect(grew.dim))

    -- Rows 2, 3, 4 and 7 are the rest of the docstring, and they carry
    -- nothing. difftastic tints every row of a changed atom and a
    -- docstring is ONE atom, so all of them arrived claiming to have
    -- changed -- and every one of them is the same text it always was.
    -- Drawn, that was a seven-line paragraph gone pale with three words
    -- lit in the middle of it, and six rows the reader has to read to
    -- find out they did not move. Row 3 is the blank line in the middle,
    -- which is the same statement about nothing.
    for _, row in ipairs({ 2, 3, 4, 7 }) do
      ok(not contains(grew.dim, row),
        "row " .. row .. " of the docstring did not change and is left alone, got "
          .. vim.inspect(grew.dim))
    end
    -- Row 6 is the line the docstring gained, and it is the exception:
    -- there is nothing on it that is not the edit, so there is nothing
    -- to step back FROM. Stepped back with its neighbours it read as
    -- the part to skim -- the one row the reader is there for, drawn as
    -- context -- and asking which words of it are new sends them
    -- looking for an old line it never had.
    ok(contains(grew.whole, 6),
      "the line it gained is at full tint, having no old half to compare with, got "
        .. vim.inspect(grew.whole))
    ok(not contains(grew.dim, 6), "and is not stepped back with the rest of the node")
    ok(not contains(grew.dim, 1) and not contains(grew.dim, 8),
      "and the code around it is left alone, got " .. vim.inspect(grew.dim))

    -- ...and a string far too big for one replacement run to be paired
    -- up token by token, which is the size real ones come in. The
    -- intra-line comparison used to refuse a block of more than
    -- `inline_token_limit` tokens outright, so a forty-line SQL query
    -- with one line appended came back with no emphasis at all and was
    -- drawn at full tint end to end -- the whole query announced as new
    -- because one line of it was. The cap belongs on the pairing, which
    -- an appended line does not use.
    local sql = { "import db", "", "", 'QUERY = """', "SELECT id, name, email", "FROM users" }
    for i = 1, 25 do
      table.insert(sql, ("JOIN accounts_%d ON accounts_%d.user_id = users.id AND accounts_%d.active = true")
        :format(i, i, i))
    end
    table.insert(sql, "ORDER BY users.created_at DESC")
    local closing = { '"""', "", "", "def run(conn):", "    return conn.execute(QUERY)" }
    local big_old = table.concat(vim.list_extend(vim.deepcopy(sql), closing), "\n")
    table.insert(sql, "LIMIT 100")
    local big_new = table.concat(vim.list_extend(sql, closing), "\n")
    ok(#big_old > 400, "the fixture is bigger than one run may be paired over")

    local big = render(big_old, big_new)
    eq(big.whole, { 33 },
      "one line appended to a long string is the only thing at full tint")
    eq(big.tinted, {}, "and it is the row that is new, not words picked out of it")
    -- ...and the thirty rows of query it was appended to are untouched.
    -- Not one of them differs by a character, so there is nothing on any
    -- of them for a reader to compare, and a page of pale SQL around one
    -- green line is a page of text saying nothing happened in it.
    eq(big.dim, {}, "and nothing else on the query is marked at all")

    -- And nothing at all on a line of code, however much of it changed:
    -- there is no atom there whose parts could be told apart.
    local code = render(
      "def f(nodes, edges):\n    result = place(nodes, edges)\n    return result",
      "def f(nodes, edges):\n    undrawn = len(edges) - len(routed)\n    return undrawn")
    eq(code.dim, {}, "a line of code is never stepped back, since its atoms are tokens")

    -- ...and nothing on a string that is neither. Stepping an atom back
    -- says "changed, but not the part that is new", which needs two
    -- halves: other words for the new ones to stand out from, or
    -- something new inside it to stand out. A separator hoisted onto a
    -- line of its own has neither -- difftastic labels `"|"` a `string`
    -- exactly as it labels a docstring one, reports it changed with the
    -- rest of the line it landed on, and not one character of it is new
    -- -- so it came out greyed in the middle of a green row.
    local hoisted = render(
      'def f(col, rows):\n    rows.append((col.name, "|".join(col.types)))\n    return rows',
      'def f(col, rows):\n    types = "|".join(_base_type(t) for t in col.types)\n'
        .. "    rows.append((col.name, types))\n    return rows")
    eq(hoisted.dim, {}, "a short literal with nothing new in it is not stepped back")

    -- The half that does hold: no sentence either, but the `2` is there
    -- to point at, so the rest of the literal steps back around it.
    local grew = render(
      "def f():\n    name = 'alpha'\n    return name",
      "def f():\n    name = 'alpha2'\n    return name")
    eq(grew.tinted, { "'alpha2'" },
      "while a literal that gained something is still tinted whole")
    eq(grew.dim, { "'", "'alpha" },
      "with everything but the `2` stepped back around it")
    -- Including the quotes, which is the other way up from the sentence
    -- above: there the atom was new nearly all through and its
    -- punctuation went with the change, here it is a literal almost all
    -- of which is old. Its closing quote sits where it always did, and
    -- stepping the end of the literal forward to point at one digit
    -- would say the quote moved. `diff.line.major_ratio` is the line
    -- between the two, and draws it for `rewritten` as well.
  end
end

print("\n[the old side steps back too]")
-- The same statement, made about the side the words were taken from. A
-- reworded docstring reports every word of itself changed on BOTH sides,
-- so the old window answered a two-word edit with a solid red block --
-- the very thing the new side stopped doing.
--
-- Driven through `oldside.refresh` over a view assembled by hand, the
-- way `view.lua` assembles one: the old buffer is a real buffer of the
-- revision, and what is asserted is the marks it carries.
do
  local diff = require("uatis.diff")
  local overlay = require("uatis.overlay")
  local oldside = require("uatis.oldside")

  --- Returns, per row of the old revision, { band = <group|nil>,
  --- red = { "text", ... } } -- what stayed at full strength on it.
  local function render_old(old, new, lang)
    lang = lang or "python"
    local path = "x." .. (lang == "python" and "py" or lang)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(new, "\n", { plain = true }))
    vim.bo[buf].filetype = lang
    local oldbuf = vim.api.nvim_create_buf(false, true)
    local old_lines = vim.split(old, "\n", { plain = true })
    local view = {
      bufnr = buf,
      ref = "main",
      relpath = path,
      -- Not "side": the banding is the same code either way, and laying
      -- the two sides out needs a window to measure.
      layout = "inline",
      old_text = old,
      old = { buf = oldbuf },
      renders = 1,
    }
    local out, done = {}, false
    diff.compute(old, new, { backend = "struct", path = path, bufnr = buf }, function(r)
      local _, del_fine = overlay.render(buf, nil, r, old_lines, { before = false })
      -- What `view.lua` hands the old window, assembled the same way.
      local dels = {}
      for _, sp in ipairs(r.spans or {}) do
        if sp.kind == "delete" then
          dels[sp.line] = dels[sp.line] or {}
          table.insert(dels[sp.line], sp)
        end
      end
      view.del_spans = r.precise and dels or nil
      -- ...including the rows a changed node covers that did not
      -- themselves change, which `view.lua` drops before the old window
      -- ever sees them.
      if view.del_spans then
        local now = vim.split(new, "\n", { plain = true })
        for new_row, old_row in pairs(r.pairs or {}) do
          if now[new_row] ~= nil and old_lines[old_row] == now[new_row] then
            view.del_spans[old_row] = nil
          end
        end
      end
      view.del_fine, view.prose, view.hunks = del_fine, r.prose, r.hunks
      oldside.refresh(view)
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(oldbuf, oldside.ns, 0, -1, { details = true })) do
        local row, col, d = m[2] + 1, m[3], m[4]
        out[row] = out[row] or { red = {} }
        local band = d.line_hl_group or (d.hl_eol and d.hl_group)
        if band then
          out[row].band = band
        elseif d.end_col and d.hl_group == "UatisDeleteBand" then
          table.insert(out[row].red, (old_lines[row] or ""):sub(col + 1, d.end_col))
        end
      end
      done = true
    end)
    vim.wait(8000, function() return done end, 20)
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.api.nvim_buf_delete(oldbuf, { force = true })
    return out
  end

  local function at(res, row)
    return res[row] or { red = {} }
  end

  if vim.fn.executable(require("uatis.config").diff.struct.bin) ~= 1 then
    print("  skip old-side checks (difftastic not installed)")
  else
    -- A docstring that only GAINED a word. Nothing was taken out of the
    -- old sentence, so none of it is a removal -- all of it steps back,
    -- and the reader looks right for what is new. This is the case the
    -- row-by-row rule could not express: no removal to compare against
    -- was read as "everything here was removed".
    local gained_old = 'class C:\n    """Bundles a driver and a semaphore."""\n    pass'
    local gained_new = 'class C:\n    """Bundles a driver and a fresh semaphore."""\n    pass'
    local g = render_old(gained_old, gained_new)
    eq(at(g, 2).band, "UatisDeleteBandDim",
      "a docstring that only gained words has nothing removed to point at")
    eq(at(g, 2).red, {}, "so nothing on the old row stays at full strength")

    -- ...and one that lost words: those keep the red, the sentence they
    -- were taken out of steps back around them.
    local lost_old = 'class C:\n    """Bundles a driver and concurrency semaphore for one connection."""\n    pass'
    local lost_new = 'class C:\n    """Bundles a driver and one connection."""\n    pass'
    local l = render_old(lost_old, lost_new)
    eq(at(l, 2).band, "UatisDeleteBandDim", "a reworded docstring steps back on the old side")
    eq(at(l, 2).red, { "concurrency semaphore for " },
      "with the words that actually went left at full strength")

    -- ...and the rest of a multi-line one is not touched at all. The
    -- atom is the NODE, so every row of a seven-line docstring comes
    -- back reported as removed when one line of it was reworded -- and
    -- this window would draw the six that did not move as a block of
    -- red. It is the same edit the new side draws, seen in the other
    -- layout, and it has to read the same way.
    local node_old = table.concat({
      "def f(t):",
      [[    """Drop a modifier.]],
      "",
      "    The diagram is a structural overview.",
      "    It widens every box that carries one.",
      [[    """]],
      "    return t",
    }, "\n")
    local node_new = node_old:gsub("carries one", "carries two")
    local n = render_old(node_old, node_new)
    eq(at(n, 5).band, "UatisDeleteBandDim",
      "the docstring row that was reworded steps back on the old side")
    eq(at(n, 5).red, { "one" }, "with the word that went left at full strength")
    for _, row in ipairs({ 2, 3, 4, 6 }) do
      eq(at(n, row).band, nil,
        "row " .. row .. " of the node did not change and is left alone here too")
    end

    -- A line with no counterpart at all is not a rewording, and nothing
    -- about it steps back: the whole of it went.
    local gone = render_old(
      'def f():\n    """The old sentence."""\n    return 1',
      "def f():\n    return 1")
    eq(at(gone, 2).band, "UatisDeleteBand",
      "a docstring that was simply deleted stays red end to end")

    -- The paragraph break inside one. difftastic covers it with an empty
    -- span rather than saying nothing about it, and the empty span used
    -- to fall through every branch here: nothing to band, nothing to
    -- range, so the one unmarked row in the old window was the blank
    -- line in the middle of the change.
    --
    -- It is unmarked again now, and for the opposite reason: it is the
    -- same blank line it always was. So is every other row of the node
    -- except the one that grew -- the whole paragraph coming back
    -- reported as removed is the atom talking, not the edit.
    local para_old = table.concat({
      "def f():",
      '    """Draw it.',
      "",
      "    Raises:",
      "        DiagramError: If path does not resolve.",
      '    """',
      "    return 1",
    }, "\n")
    local para_new = table.concat({
      "def f():",
      '    """Draw it.',
      "",
      "    Raises:",
      "        DiagramError: If path does not resolve to a table, or if no",
      "            spacing lets every relationship be drawn.",
      '    """',
      "    return 1",
    }, "\n")
    local para = render_old(para_old, para_new)
    eq(at(para, 5).band, "UatisDeleteBandDim",
      "the row of the docstring that grew steps back")
    for _, row in ipairs({ 2, 3, 4, 6 }) do
      eq(at(para, row).band, nil,
        "and row " .. row .. ", which did not change, carries nothing -- the blank"
          .. " line in the middle of it included")
    end
  end
end

print("\n[reflow is not a rewrite]")
-- A reformat that moves code across line breaks. The two modes are meant
-- to answer differently: a line diff can only say "this line became those
-- lines", and should say exactly that; a structural diff knows the code
-- did not change and should say nothing at all.
do
  local diff = require("uatis.diff")
  local overlay = require("uatis.overlay")

  local old = table.concat({
    "class S3Driver:",
    "    @classmethod",
    '    async def create(cls, params: dict[str, Any], settings: DriverSettings) -> "S3Driver":',
    "        return cls()",
    "",
    "    def close(self):",
    "        self._closed = True",
  }, "\n")
  local new = table.concat({
    "class S3Driver:",
    "    @classmethod",
    "    async def create(",
    "        cls, params: dict[str, Any], settings: DriverSettings",
    '    ) -> "S3Driver":',
    "        return cls()",
    "",
    "    def close(self):",
    "        self._shutdown = True",
  }, "\n")

  --- Renders and reports per line: whether it is banded, its sub-line
  --- marks, and the before-image drawn above it.
  local function render(backend)
    local lines = vim.split(new, "\n", { plain = true })
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = "python"
    local out, done = {}, false
    diff.compute(old, new, { backend = backend, path = "d.py", bufnr = buf }, function(r)
      overlay.render(buf, nil, r, vim.split(old, "\n", { plain = true }))
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1, { details = true })) do
        local row, col, d = m[2], m[3], m[4]
        out[row + 1] = out[row + 1] or { marks = {}, before = {}, inline = {} }
        if d.line_hl_group then
          out[row + 1].band = d.line_hl_group
        end
        if d.virt_text_pos == "inline" then
          for _, c in ipairs(d.virt_text or {}) do
            table.insert(out[row + 1].inline, c[1])
          end
        end
        if d.end_col then
          table.insert(out[row + 1].marks,
            d.hl_group .. "=" .. (lines[row + 1] or ""):sub(col + 1, d.end_col))
        end
        for _, vl in ipairs(d.virt_lines or {}) do
          for _, c in ipairs(chunks_of(vl)) do
            table.insert(out[row + 1].before, c[2] .. "=" .. c[1])
          end
        end
      end
      done = true
    end)
    vim.wait(8000, function() return done end, 20)
    vim.api.nvim_buf_delete(buf, { force = true })
    return out
  end

  local function at(res, line)
    return res[line] or { marks = {}, before = {}, inline = {} }
  end

  local L = render("line")
  ok(at(L, 3).band == "UatisAdd" and at(L, 4).band == "UatisAdd" and at(L, 5).band == "UatisAdd",
    "line mode marks all three new lines as added")
  ok(contains(at(L, 3).before, "UatisDeleteBg=    async def create(cls, params: dict[str, Any], "
    .. 'settings: DriverSettings) -> "S3Driver":'),
    "and shows the whole line they replaced, in full, as removed")

  -- The real edit further down is a 1:1 pair, so it still gets characters.
  ok(contains(at(L, 9).marks, "UatisAdd=_shutdown"), "a paired line still marks inserted characters")
  ok(contains(at(L, 9).before, "UatisDeleteBg=_closed")
    and contains(at(L, 9).before, "UatisDeleteDim=        self."),
    "and the line it replaced above it, with the part that went picked out of it, got "
      .. vim.inspect(at(L, 9).before))

  local S2 = render("struct")
  for _, line in ipairs({ 3, 4, 5 }) do
    ok(at(S2, line).band == nil and #at(S2, line).marks == 0 and #at(S2, line).before == 0,
      "structural mode says nothing about reflowed line " .. line)
  end
  ok(contains(at(S2, 9).marks, "UatisAdd=_shutdown"),
    "while still reporting the real change in the same file")
end

print("\n[wrapping is not removing]")
-- Wrapping an expression in parentheses moves code without deleting any
-- of it. The old rendering paired the lines by position anyway, which
-- reported the tail of each as removed and left a before-image of red
-- fragments over dimmed context -- unreadable as the code that was there.
do
  local diff = require("uatis.diff")
  local overlay = require("uatis.overlay")

  local function render(old, new, backend)
    local lines = vim.split(new, "\n", { plain = true })
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = "python"
    local out, done = { before = {}, groups = {}, anchors = {}, bands = {} }, false
    diff.compute(old, new, { backend = backend, path = "r.py", bufnr = buf }, function(r)
      overlay.render(buf, nil, r, vim.split(old, "\n", { plain = true }))
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1, { details = true })) do
        if m[4].line_hl_group then
          out.bands[m[2] + 1] = m[4].line_hl_group
        end
        -- How many rows each extmark carries: one mark holding all of
        -- them is a block above the hunk, one row each is a before-image
        -- spread against the alignment.
        if m[4].virt_lines and #m[4].virt_lines > 0 then
          table.insert(out.anchors, #m[4].virt_lines)
        end
        for _, vl in ipairs(m[4].virt_lines or {}) do
          local text = ""
          for _, c in ipairs(chunks_of(vl)) do
            text = text .. c[1]
            out.groups[c[2]] = true
          end
          table.insert(out.before, text)
        end
      end
      done = true
    end)
    vim.wait(8000, function() return done end, 20)
    vim.api.nvim_buf_delete(buf, { force = true })
    return out
  end

  local call = '        region = self._client.get_bucket_location(Bucket=bucket).get("LocationConstraint")'
  local flat = "class S3:\n    def region_for(self, bucket):\n" .. call .. "\n        return region"
  local wrapped = "class S3:\n    def region_for(self, bucket):\n        region = (\n    "
    .. call .. "\n        )\n        return region"

  local st = render(flat, wrapped, "struct")
  eq(st.before, {}, "structural mode shows no before-image for a pure wrap")

  -- The same wrap where the call already spanned lines: the old first
  -- line ends mid-call, which is the shape that produced a full red copy
  -- of code still sitting two rows below it.
  local split = "class S3:\n    def region_for(self, bucket):\n"
    .. "        region = self._client.get_bucket_location(Bucket=bucket).get(\n"
    .. '            "LocationConstraint"\n        )\n        return region'
  local split_wrapped = "class S3:\n    def region_for(self, bucket):\n        region = (\n"
    .. '            self._client.get_bucket_location(Bucket=bucket).get("LocationConstraint")\n'
    .. "        )\n        return region"
  eq(render(split, split_wrapped, "struct").before, {},
    "nor when the call it wraps already spanned lines")

  -- The decision cannot come from the token diff: aligning those two
  -- blocks pairs the old opening quote against `self` and calls the quote
  -- deleted, which is an artifact of the alignment, not an edit.
  ok(diff.content_survives(
    { '        region = self._client.get_bucket_location(Bucket=bucket).get(',
      '            "LocationConstraint"', "        )" },
    { "        region = (",
      '            self._client.get_bucket_location(Bucket=bucket).get("LocationConstraint")',
      "        )" }),
    "the survival test sees the code is all still there")
  ok(not diff.content_survives({ "    self._closed = True" }, { "    self._shutdown = True" }),
    "and sees a real replacement as a removal")
  ok(not diff.content_survives({ 'x.get("k", "v")' }, { 'x.get("k") or "v"' }),
    "including one that only drops a comma")

  -- ...and the same edit has to get the same answer whatever line it
  -- happens to be on. Both of these gained `(50)` -- three tokens, the
  -- brackets and what is between them -- and at a floor of two the long
  -- one was a move and the short one a removal: a quarter of sixteen
  -- tokens covers three, a quarter of eleven covers two. One file, one
  -- edit, drawn two ways.
  ok(diff.content_survives({ '        assert desc.types == ["VARCHAR2"]' },
    { '        assert desc.types == ["VARCHAR2(50)"]' }),
    "a short line that gained a type parameter is still the line it was")
  ok(diff.content_survives({ '        assert by_name["VAL"].types == ["VARCHAR2"]' },
    { '        assert by_name["VAL"].types == ["VARCHAR2(50)"]' }),
    "and so is the longer one beside it, which is the whole point")

  local ln = render(flat, wrapped, "line")
  ok(#ln.before == 1, "line mode still states the substitution, got " .. #ln.before .. " lines")
  ok(ln.before[1]:find(call, 1, true) ~= nil,
    "and the removed line is shown whole, readable as the code that was there")

  -- A real edit that happens to keep the line count must NOT be compared
  -- line by position: the content shifts down a line, and pairing anyway
  -- produces a before-image nobody can read back.
  local before4 = "class S3:\n    def f(self, b):\n"
    .. "        region = self._client.get_bucket_location(Bucket=b).get(\n"
    .. '            "LocationConstraint",\n            "us-east-1",\n        )\n        return region'
  local after4 = "class S3:\n    def f(self, b):\n        region = (\n"
    .. '            self._client.get_bucket_location(Bucket=b).get("LocationConstraint")\n'
    .. '            or "us-east-1"\n        )\n        return region'
  local sh = render(before4, after4, "struct")
  ok(#sh.before == 4, "an equal line count still yields the whole old block, got " .. #sh.before)
  ok(not sh.groups["UatisDeleteDim"],
    "and it is not dimmed into fragments: all difftastic reports gone from those"
      .. " rows is a bracket and two commas, which is not worth quietening a block for")
  ok(sh.groups["UatisDeleteBg"], "the old code is shown as removed, in full")

  -- ...but where NAMES went, saying which is the whole point. The old
  -- line reads through, dimmed, with the two words that are actually
  -- gone left at full strength -- the same statement the side-by-side
  -- window makes, from the same spans.
  local renamed = render(
    "class D:\n    def go(self, sql, binds):\n        cur = self._conn.execute(sql, binds)",
    "class D:\n    def go(self, sql, binds):\n        cur = self._sql(sql, binds, private=True)",
    "struct")
  ok(#renamed.before == 1 and renamed.before[1]:find("_conn.execute", 1, true) ~= nil,
    "a line whose call was renamed still shows the call it had, got "
      .. vim.inspect(renamed.before))
  ok(renamed.groups["UatisDeleteDim"],
    "with the rest of it stepped back rather than red end to end")

  -- ...but a docstring that GREW is not a substitution. Its old tokens
  -- are all still there, spread across the paragraph that was added to
  -- them, which is wider than the survival test allows for a move -- so
  -- the block reported as gone and every line of it was drawn in red
  -- directly above the identical line below it.
  local doc = table.concat({
    "class C:",
    "    def reset(self, path):",
    '        """Clear cached results at or below path.',
    "",
    "        Args:",
    "            path: Path prefix to reset. Entries whose keys start with it",
    "                are removed, along with any ancestor entries.",
    '        """',
    "        self._drop(path)",
  }, "\n")
  local grown = table.concat({
    "class C:",
    "    def reset(self, path):",
    '        """Clear cached results at or below path.',
    "",
    "        Args:",
    "            path: Path prefix to reset. Entries whose keys start with it",
    "                are removed, along with any ancestor entries. Cached finds",
    "                are dropped in full whatever the path: they are keyed by",
    "                search, not by path, so a reset invalidates them both ways.",
    '        """',
    "        self._drop(path)",
  }, "\n")
  -- An import list reflowed onto its own lines, gaining a name on the
  -- way. difftastic splits that into a 1:1 replacement of the old line
  -- and an insertion below it, so the words that survived are spread
  -- across rows the survival window either excludes as another hunk's or
  -- never reaches -- and the old line came back as a full red copy of
  -- code every word of which is on screen underneath it, unmarked.
  -- difftastic reports no removal anywhere on that row, and that answer
  -- is the one that counts.
  local flat_import = "from .drivers.base import BaseDriver, DriverSettings, ReadResult\n"
    .. "from .protocol import Connection"
  local wrapped_import = table.concat({
    "from .drivers.base import (",
    "    BaseDriver,",
    "    DriverSettings,",
    "    FindNotSupported,",
    "    ReadResult,",
    ")",
    "from .protocol import Connection",
  }, "\n")
  eq(render(flat_import, wrapped_import, "struct").before, {},
    "an import list that gained a name and moved onto its own lines removed nothing")

  -- The survival window asks whether the old tokens are still on
  -- screen, and a row nobody touched can answer yes for them. Two tests
  -- four rows apart both build the same widget; the first changes its
  -- height, and every token of the row it used to be sits on the second,
  -- byte for byte -- a row difftastic paired with its own old self, which
  -- is where the hunk's content cannot have gone.
  -- A lone untouched row between two changed ones is swallowed into
  -- the hunk, so that a wrap reads as one edit. Where the hunk then
  -- fails to pair up line for line -- a row added under the second
  -- change -- nothing excused it from the before-image, and it came out
  -- pale red above itself with a dim band on itself: removed and added
  -- back at once. Drawn each above its own partner, an identical pair
  -- says nothing, and the row is left alone.
  do
    local swallowed_old = table.concat({
      "def clamp(value, lower, upper):",
      "    if value < lower:",
      "        return lower",
      "    if value > upper:",
      "        return upper",
      "    return value",
    }, "\n")
    local swallowed_new = table.concat({
      "def clamp(value, lower, upper):",
      "    if value < lower:",
      "        return float(lo)",
      "    if value > upper:",
      "        return float(hi)",
      "    assert value is not None",
      "    return value",
    }, "\n")
    local sw = render(swallowed_old, swallowed_new, "struct")
    local shown = vim.tbl_map(function(l) return vim.trim(l:sub(2)) end, sw.before)
    eq(shown, { "return lower", "return upper" },
      "an untouched row swallowed between two changes gets no before-image")
    eq(sw.bands[4], nil, "and no band of its own")
  end

  -- The same untouched row between a changed row and a rewritten
  -- comment. Swallowed, the hunk was 4-into-4 with only half its rows
  -- resembling their partners, so it went up as one block above the
  -- `except`: the `if` red above itself, and the old comment above the
  -- wrong line. Byte for byte the same, the row is no part of either.
  do
    local guard_old = table.concat({
      "def handle(resp):",
      "    try:",
      "        work()",
      "    except Exception:",
      "        if resp and resp.headers_sent:",
      "            # If the requests have already been sent, we should close the",
      "            # connection to indicate the error.",
      "            raise",
    }, "\n")
    local guard_new = table.concat({
      "def handle(resp):",
      "    try:",
      "        work()",
      "    except BaseException:",
      "        if resp and resp.headers_sent:",
      "            # Timeout abort is SystemExit. If we already started the",
      "            # response, writing a 500 on the same socket corrupts it.",
      "            raise",
    }, "\n")
    local g = render(guard_old, guard_new, "struct")
    local shown = vim.tbl_map(function(l) return vim.trim(l:sub(2)) end, g.before)
    ok(not contains(shown, "if resp and resp.headers_sent:"),
      "an untouched row between a changed row and a rewritten comment gets no before-image")
    eq(#g.anchors, 2, "and the two changes either side of it are drawn apart")
  end

  -- A docstring folded from five rows to one, with the two code rows
  -- under it taken out as well. One hunk, seven rows removed, and as
  -- one block it put the old code ABOVE the docstring it used to
  -- follow. The docstring became the new docstring; the code rows went
  -- from under it. So the atom's rows go above the row it became and
  -- the rest go where they were: below it, above the next row kept.
  do
    local kept_old = table.concat({
      "class T:",
      "    def test_scale(self):",
      '        """A test about scale widget.',
      "",
      "        Args:",
      "            self: own class.",
      '        """',
      "        widget = Widget(2.0)",
      "        scaled = scale_widget(widget, 2.0)",
      "        assert scaled.width == 4.0",
      "        assert scaled.height == 6.0",
    }, "\n")
    local kept_new = table.concat({
      "class T:",
      "    def test_scale(self):",
      '        """A test about scale widget."""',
      "        assert scaled.width == 4.0",
    }, "\n")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(kept_new, "\n", { plain = true }))
    vim.bo[buf].filetype = "python"
    local blocks, done = {}, false
    diff.compute(kept_old, kept_new, { backend = "struct", path = "r.py", bufnr = buf }, function(r)
      overlay.render(buf, nil, r, vim.split(kept_old, "\n", { plain = true }))
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1, { details = true })) do
        if m[4].virt_lines and #m[4].virt_lines > 0 then
          local rows = {}
          for _, vl in ipairs(m[4].virt_lines) do
            local text = ""
            for _, c in ipairs(chunks_of(vl)) do
              text = text .. c[1]
            end
            table.insert(rows, (vim.trim(text:sub(2))))
          end
          local groups = {}
          for _, c in ipairs(chunks_of(m[4].virt_lines[1])) do
            groups[c[2]] = true
          end
          table.insert(blocks, { line = m[2] + 1, above = m[4].virt_lines_above == true, rows = rows, first = groups })
        end
      end
      done = true
    end)
    vim.wait(8000, function() return done end, 20)
    vim.api.nvim_buf_delete(buf, { force = true })
    table.sort(blocks, function(a, b)
      if a.line ~= b.line then return a.line < b.line end
      return a.above and not b.above
    end)
    eq(#blocks, 3, "three blocks")
    eq({ blocks[1].line, blocks[1].above, blocks[1].rows[1], #blocks[1].rows },
      { 3, true, '"""A test about scale widget.', 5 },
      "the old docstring, whole, above the row it became")
    -- The first row of that block is on the row it hangs above, whole:
    -- it is that row's old version, drawn directly above it, so it
    -- steps back the way any row drawn above its own new version does
    -- -- and the way the side window already draws it. A block is
    -- otherwise all one colour, and this row is the one it was split
    -- above for.
    ok(blocks[1].first["UatisDeleteDim"] and not blocks[1].first["UatisDelete"]
      and not blocks[1].first["UatisDeleteBg"],
      "its first row stepped back, since every character of it is on the row below")
    ok(blocks[2].first["UatisDelete"] or blocks[2].first["UatisDeleteBg"],
      "while the code rows that went are drawn as gone")
    eq({ blocks[2].line, blocks[2].above, blocks[2].rows },
      { 4, true, { "widget = Widget(2.0)", "scaled = scale_widget(widget, 2.0)" } },
      "the code rows that went from under it, below it")
    eq({ blocks[3].line, blocks[3].above, blocks[3].rows },
      { 4, false, { "assert scaled.height == 6.0" } },
      "and the assertion taken off the end, where it was")
  end

  local twin = '        widget = Widget(name="a", width=2.0, height=3.0)'
  local twins = table.concat({
    "class TestWidget:",
    "    def test_area(self):",
    twin,
    "        assert widget.area() == 6.0",
    "",
    "    def test_scale_widget(self):",
    twin,
    "        scaled = scale_widget(widget, 2.0)",
  }, "\n")
  local retwinned = twins:gsub("height=3%.0", "height=4.0", 1)
  local twinned = render(twins, retwinned, "struct")
  ok(#twinned.before == 1 and twinned.before[1]:find("height=3.0", 1, true) ~= nil,
    "a row edited beside an identical one keeps its before-image, got "
      .. vim.inspect(twinned.before))
  ok(twinned.groups["UatisDeleteBg"] and twinned.groups["UatisDeleteDim"],
    "with the digit that went lit and the rest stepped back")

  -- A docstring REWRITTEN, rather than one that grew. difftastic still
  -- reports an alignment -- it does for every hunk -- but between blocks
  -- of different lengths with nothing in common it is the two laid
  -- alongside each other in order, not a row-for-row answer. Spread on
  -- that, every line of the old prose is drawn directly above a line of
  -- the new prose it has nothing to do with.
  local four = table.concat({
    "class C:",
    "    def find(self, name):",
    '        """Resolve a symbol, preferring the cache over any round trip.',
    "",
    "        Four passes, cheapest first:",
    "",
    "        1. The find cache, answered before and kept on disk.",
    "        2. The generic walk over tree levels already cached.",
    "        3. The inner driver's own catalog lookup, in one query.",
    "        4. The generic walk over the live listing, for the rest.",
    "",
    "        Only pass 3 is written back, since it is the only one that",
    "        leaves nothing behind for the others to find.",
    '        """',
    "        return self._find(name)",
  }, "\n")
  local two = table.concat({
    "class C:",
    "    def find(self, name):",
    '        """Resolve a symbol, preferring the find cache over any round trip.',
    "",
    "        Two passes:",
    "",
    "        1. The find cache, keyed by the search itself.",
    "        2. The wrapped driver, whichever way it can answer.",
    '        """',
    "        return self._find(name)",
  }, "\n")
  local rewrote = render(four, two, "struct")
  ok(#rewrote.before > 4,
    "a rewritten docstring is still shown in full, got " .. #rewrote.before .. " rows")
  eq(#rewrote.anchors, 1,
    "and in ONE block, since the rows it was aligned against are not what it became, got "
      .. vim.inspect(rewrote.anchors))

  local gr = render(doc, grown, "struct")
  ok(#gr.before == 1,
    "a docstring that gained a sentence shows one before-image, not the whole atom, got "
      .. #gr.before)
  ok(#gr.before == 1 and gr.before[1]:find("any ancestor entries.", 1, true) ~= nil,
    "and it is the line that actually changed")
end

print("\n[a lost space is still a loss]")
-- The survival test compares tokens, and whitespace is not one -- right
-- for the moves it excuses, where whitespace changing IS the move. But a
-- comment with the space taken off its end is a change difftastic
-- reports, and nothing arrived on the row to be lit: so the row was a
-- dim band with no before-image, changed for a reason the reader could
-- not see, while side by side had the space in red on the left.
do
  local diff = require("uatis.diff")
  local overlay = require("uatis.overlay")

  local function render(old, new, backend, ft)
    local lines = vim.split(new, "\n", { plain = true })
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = ft
    local out, done = { before = {}, lost = {} }, false
    diff.compute(old, new, { backend = backend, path = "x." .. ft, bufnr = buf }, function(r)
      overlay.render(buf, nil, r, vim.split(old, "\n", { plain = true }))
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1, { details = true })) do
        for _, vl in ipairs(m[4].virt_lines or {}) do
          local text = ""
          for _, c in ipairs(chunks_of(vl)) do
            text = text .. c[1]
            if c[2] == "UatisDelete" or c[2] == "UatisDeleteBg" then
              table.insert(out.lost, c[1])
            end
          end
          table.insert(out.before, text)
        end
      end
      done = true
    end)
    vim.wait(8000, function() return done end, 20)
    vim.api.nvim_buf_delete(buf, { force = true })
    return out
  end

  if vim.fn.executable(require("uatis.config").diff.struct.bin) ~= 1 then
    print("  skip lost-space checks (difftastic not installed)")
  else
    local trailing = render("def f():\n    x = 1  # note \n    return x\n",
      "def f():\n    x = 1  # note\n    return x\n", "struct", "python")
    ok(#trailing.before == 1,
      "a comment that lost its trailing space gets a before-image, got "
        .. vim.inspect(trailing.before))
    eq(trailing.lost, { " " }, "with the space, and only the space, drawn as gone")

    local inner = render('def f():\n    """Do  it.\n\n    More.\n    """\n    return 1\n',
      'def f():\n    """Do it.\n\n    More.\n    """\n    return 1\n', "struct", "python")
    ok(#inner.before == 1,
      "and so does a docstring that lost a doubled space, on that row alone, got "
        .. vim.inspect(inner.before))
    eq(inner.lost, { " " }, "with the extra space picked out")

    -- The other way round needs nothing: the space that arrived is on
    -- the row, marked, and the whole of the old row is under it.
    local gained = render("def f():\n    x = 1  # note\n    return x\n",
      "def f():\n    x = 1  # note \n    return x\n", "struct", "python")
    eq(gained.before, {}, "a comment that GAINED a space is still a pure insertion")

    -- ...and a reindent is still a move, not a loss: the code went
    -- nowhere and difftastic reports nothing for it.
    local wrapped = render("def f(x):\n    a = 1  # one\n    b = 2  # two\n",
      "def f(x):\n    if x:\n        a = 1  # one\n        b = 2  # two\n", "struct", "python")
    eq(wrapped.before, {}, "while a block wrapped in a guard shows no before-image")
  end
end

print("\n[a line break is a token, not a line]")
-- The tokenizer emits a line break as a token whose text IS a newline,
-- and the intra-line diff joins tokens with newlines to hand them to
-- `vim.diff`. Left alone, joining three tokens makes four lines: every
-- index after a break points at the wrong token, and a block long enough
-- for the drift to run past the end of the array crashes on the token
-- that is not there. It took a multi-line hunk whose two sides pair up --
-- rare enough to reach, certain to crash when it did.
do
  local diff = require("uatis.diff")

  local function compare(old, new)
    local fine, r = pcall(diff.block_diff, old, new)
    ok(fine, "comparing a " .. #old .. "-line block does not throw")
    return fine and r or { adds = {}, dels = {} }
  end

  local r = compare({ "def one(a):", "    return a" }, { "def two(b, c):", "    return b + c" })
  local adds = {}
  for _, a in ipairs(r.adds or {}) do
    table.insert(adds, ({ "def two(b, c):", "    return b + c" })[a.line]:sub(a.col_start + 1, a.col_end))
  end
  ok(contains(adds, "two"), "and it finds what changed on the first line, got " .. vim.inspect(adds))
  ok(contains(adds, "c"), "and on the second")

  -- The marks have to land on the right LINE as well: a break counted as
  -- two would put the second line's marks a line out.
  for _, a in ipairs(r.adds or {}) do
    ok(a.line == 1 or a.line == 2, "every mark lands on a line of the block, got " .. a.line)
  end

  compare({ "x = 1", "y = 2", "z = 3" }, { "alpha = 10", "beta = 20", "gamma = 30" })
  compare({ "if a:", "    b()", "else:", "    c()" }, { "while q:", "    r()", "finally:", "    s()" })
end

print("\n[removed code keeps its colours]")
-- A before-image is virtual text, and nothing highlights virtual text:
-- both of Neovim's highlighters run over real buffer lines. So a removed
-- line used to arrive in one flat colour -- exactly the flattening the
-- new side goes out of its way to avoid -- and the old side is now parsed
-- on its own so the capture groups can be put on the chunks by hand.
do
  local diff = require("uatis.diff")
  local overlay = require("uatis.overlay")

  --- Every chunk of every before-image, as { text, hl } with `hl` left
  --- exactly as the extmark carries it.
  local function before_chunks(old, new, filetype, backend, path)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(new, "\n", { plain = true }))
    vim.bo[buf].filetype = filetype
    local out, done = {}, false
    diff.compute(old, new, { backend = backend or "line", path = path or "x.lua", bufnr = buf }, function(r)
      overlay.render(buf, nil, r, vim.split(old, "\n", { plain = true }))
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1, { details = true })) do
        for _, vl in ipairs(m[4].virt_lines or {}) do
          for _, c in ipairs(vl) do
            table.insert(out, { text = c[1], hl = c[2] })
          end
        end
      end
      done = true
    end)
    vim.wait(8000, function() return done end, 20)
    vim.api.nvim_buf_delete(buf, { force = true })
    return out
  end

  local old = "local M = {}\nfunction M.run(a)\n  return a + 1\nend"
  local new = "local M = {}\nfunction M.run(a)\nend"

  if not pcall(vim.treesitter.language.add, "lua") then
    print("  skip syntax colouring checks (no lua parser)")
  else
    local got = before_chunks(old, new, "lua")

    local keyword
    for _, c in ipairs(got) do
      if c.text == "return" then
        keyword = c.hl
      end
    end
    ok(type(keyword) == "table" and contains(keyword, "@keyword.return.lua"),
      "a removed keyword carries the group the real highlighter would have used")
    ok(type(keyword) == "table" and keyword[#keyword] == "UatisDeleteBg",
      "with the removal background on top of it, so the colour survives")

    -- The background has to be on EVERY chunk: a gap between two captures
    -- would leave the line striped.
    local text, striped = "", false
    for _, c in ipairs(got) do
      local last = type(c.hl) == "table" and c.hl[#c.hl] or c.hl
      if last ~= "UatisSign" then
        text = text .. c.text
        striped = striped or last ~= "UatisDeleteBg"
      end
    end
    ok(not striped, "every chunk of the line is drawn on the removal background")
    eq(text, "  return a + 1", "and the chunks still spell out the line that went away")
  end

  -- No parser, no groups to put on: the line keeps the flat foreground,
  -- which is better than no colour at all.
  local plainly = before_chunks(old, new, "")
  local flat = {}
  for _, c in ipairs(plainly) do
    if c.hl ~= "UatisSign" then
      table.insert(flat, c.hl .. "=" .. c.text)
    end
  end
  eq(flat, { "UatisDelete=  return a + 1" },
    "a filetype with no parser falls back to one flat removal colour")

  -- ...and a before-image that picks its removals out of the line keeps
  -- them too. Both bands are backgrounds for the same reason the bands
  -- over real code are: a foreground replaces the syntax colouring
  -- instead of tinting it, and the row stops reading as code. The dim
  -- half used to be `Comment`'s grey, which flattened everything the
  -- edit did not touch.
  if not pcall(vim.treesitter.language.add, "python") then
    print("  skip the picked-out half (no python parser)")
  else
    -- Long enough that the removals are not readable inside the line
    -- that replaced them, so the old line keeps a row of its own --
    -- which is the row this is about.
    local split = before_chunks(
      "class D:\n    def go(self, sql, binds):\n"
        .. "        cur = self._conn.execute(sql, binds)\n        return cur",
      "class D:\n    def go(self, sql, binds):\n"
        .. "        cur = self._sql(sql, binds, private=True)\n        return cur",
      "python", "struct", "x.py")
    local band, coloured = {}, {}
    for _, c in ipairs(split) do
      if c.hl ~= "UatisSign" then
        local groups = type(c.hl) == "table" and c.hl or { c.hl }
        band[c.text] = groups[#groups]
        if #groups > 1 then
          coloured[c.text] = groups[1]
        end
      end
    end
    eq(band["_conn"], "UatisDeleteBg", "the word that went carries the removal background")
    eq(band["execute"], "UatisDeleteBg", "and so does the other one")
    eq(band["cur"], "UatisDeleteDim", "while the code that stayed steps back behind it")
    eq(band["sql"], "UatisDeleteDim", "all of it, not just the part beside the edit")
    ok(coloured["_conn"] and coloured["cur"],
      "and every chunk keeps a syntax group of its own under the band, got "
        .. vim.inspect(coloured))
  end

  -- Which is only worth anything if the bands are backgrounds. Asserted
  -- against a `DiffDelete` that HAS one, because the suite runs under a
  -- default scheme whose diff groups are foreground-only -- and there the
  -- grey fallback is right, so the definition under test never appears.
  local was = vim.api.nvim_get_hl(0, { name = "DiffDelete", link = false })
  vim.api.nvim_set_hl(0, "DiffDelete", { bg = 0x4a1f1f, fg = 0xffffff })
  overlay.setup_highlights()
  for _, group in ipairs({ "UatisDeleteDim", "UatisDeleteBg" }) do
    local hl = vim.api.nvim_get_hl(0, { name = group, link = false })
    ok(hl.bg ~= nil and hl.fg == nil,
      group .. " tints the removed line's background and leaves its colours alone, got "
        .. vim.inspect(hl))
  end
  vim.api.nvim_set_hl(0, "DiffDelete", was)
  overlay.setup_highlights()
end

print("\n[a removed line is drawn as a whole line]")
-- `line_hl_group` paints a real line to the window's edge; a virtual line
-- stops at its last character, so a removed line used to end in a ragged
-- red edge that traced the length of the old code instead of marking the
-- row. So a before-image is padded out to the window width -- in
-- whichever colour its own end is already in, which is the removal
-- colour on a line that went whole and the dim band on one that had its
-- removals picked out of it. Running the REMOVAL colour to the edge of a
-- line that mostly survived would claim the rest of it went too; running
-- the band that means "this row is the old line" there claims nothing,
-- and is what the old window does with a real line highlight.
do
  local diff = require("uatis.diff")
  local overlay = require("uatis.overlay")

  local WIDTH = 60

  --- Renders into a real window -- the width has to come from somewhere
  --- -- and reports each before-image row as { text, last chunk, width }.
  local function rows(old, new, backend, filetype, path)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(new, "\n", { plain = true }))
    vim.bo[buf].filetype = filetype or "lua"
    local win = vim.api.nvim_open_win(buf, false, {
      relative = "editor", row = 0, col = 0, width = WIDTH, height = 10, style = "minimal",
    })
    local out, done = {}, false
    diff.compute(old, new, { backend = backend or "line", path = path or "x.lua", bufnr = buf }, function(r)
      overlay.render(buf, win, r, vim.split(old, "\n", { plain = true }))
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1, { details = true })) do
        for _, vl in ipairs(m[4].virt_lines or {}) do
          local cs = chunks_of(vl)
          local text, width = "", 0
          for _, c in ipairs(cs) do
            text = text .. c[1]
            width = width + vim.fn.strdisplaywidth(c[1], width)
          end
          -- The raw last chunk, not the merged one: the fill shares its
          -- overlay group with the syntax chunk before it, so merging
          -- would hide the padding inside the code it pads.
          table.insert(out, { text = text, last = vl[#vl], width = width })
        end
      end
      done = true
    end)
    vim.wait(8000, function() return done end, 20)
    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(buf, { force = true })
    return out
  end

  local gone = rows("local M = {}\nfunction M.run(a)\n  return a + 1\nend",
    "local M = {}\nfunction M.run(a)\nend")
  ok(#gone == 1, "one line was removed, so one before-image is drawn")
  local row = gone[1] or { last = {} }
  eq(row.width, WIDTH, "which is filled out to the window's width")
  ok(row.last[1]:match("^ +$") ~= nil, "the fill is blank")
  eq(row.last[2], "UatisDeleteBg", "and carries the removal colour to the edge")
  ok(row.text:find("  return a + 1", 1, true) ~= nil,
    "and the removed code is still all there in front of it")

  -- An empty removed line has nothing to colour at all, and is exactly
  -- the row where a band that stops at the text is invisible.
  local blank = rows("local a = 1\n\nlocal b = 2", "local a = 1\nlocal b = 2")
  ok(#blank == 1 and (blank[1] or {}).width == WIDTH,
    "a removed blank line is a full-width band too")

  -- ...including one whose removals were picked out of it, where the
  -- padding is the dim band rather than the removal colour: without it
  -- the row ends where the old code happens to end, and the one line on
  -- screen that is not part of the file is the one with no edge.
  if not pcall(vim.treesitter.language.add, "python") then
    print("  skip the picked-out row (no python parser)")
  else
    local picked = rows(
      "class D:\n    def go(self, sql, binds):\n"
        .. "        cur = self._conn.execute(sql, binds)\n        return cur",
      "class D:\n    def go(self, sql, binds):\n"
        .. "        cur = self._sql(sql, binds, private=True)\n        return cur",
      "struct", "python", "x.py")
    ok(#picked == 1, "the renamed call keeps a row of its own, got " .. #picked)
    local r = picked[1] or { last = {} }
    eq(r.width, WIDTH, "filled out to the window's width like any other")
    local last = type(r.last[2]) == "table" and r.last[2][#r.last[2]] or r.last[2]
    eq(last, "UatisDeleteDim",
      "in the band that means \"this row is the old line\", not the one that means \"this went\"")
  end
end

print("\n[a rewritten line is one change, not twenty]")
-- `var = func(foo, bar)` rewritten to a different call with different
-- arguments keeps its brackets, its comma and its `=`. Marking around
-- them left green wrapped round islands of punctuation, and punctuation
-- reading as "unchanged" is true of the character and false of the line:
-- nothing a reader could name came through. Lines like that are drawn as
-- one band on each side instead.
do
  local diff = require("uatis.diff")
  local overlay = require("uatis.overlay")

  --- Renders one changed line and reports what was drawn on it: the band,
  --- the green marks, and the before-image split into its coloured parts.
  local function render(old_line, new_line)
    local old = "local M = {}\n" .. old_line
    local new = "local M = {}\n" .. new_line
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(new, "\n", { plain = true }))
    vim.bo[buf].filetype = "lua"
    local out, done = { marks = {}, before = {}, inline = {} }, false
    diff.compute(old, new, { backend = "line", path = "x.lua", bufnr = buf }, function(r)
      overlay.render(buf, nil, r, vim.split(old, "\n", { plain = true }))
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1, { details = true })) do
        local d = m[4]
        if d.line_hl_group then
          out.band = d.line_hl_group
        end
        if d.virt_text_pos == "inline" then
          for _, c in ipairs(d.virt_text or {}) do
            table.insert(out.inline, c[1])
          end
        end
        if d.end_col then
          table.insert(out.marks, new_line:sub(m[3] + 1, d.end_col))
        end
        for _, vl in ipairs(d.virt_lines or {}) do
          for _, c in ipairs(chunks_of(vl)) do
            if c[2] ~= "UatisSign" then
              table.insert(out.before, c[2] .. "=" .. c[1])
            end
          end
        end
      end
      done = true
    end)
    vim.wait(8000, function() return done end, 20)
    vim.api.nvim_buf_delete(buf, { force = true })
    return out
  end

  local gone = render("x = handle(a, b)", "y = manage(c, d)")
  eq(gone.band, "UatisAdd", "a line where only punctuation survived is added whole")
  eq(gone.marks, {}, "with no marks picking out the brackets it kept")
  eq(gone.before, { "UatisDeleteBg=x = handle(a, b)" },
    "and the line it replaced is removed whole, not dimmed around its commas")

  -- The test is what survived, not how much of it: one name coming
  -- through is something the reader recognises and navigates by, and
  -- taking the marks away to call the line new would throw that away.
  local kept = render("x = handle(a, b)", "x = manage(a, b)")
  ok(kept.band == nil, "a line that kept a name is still marked in parts")
  eq(kept.marks, { "manage" }, "and only the part that changed is green")
  eq(kept.inline, {}, "with nothing of the old line drawn inside it")
  eq(kept.before, { "UatisDeleteDim=x = ", "UatisDeleteBg=handle", "UatisDeleteDim=(a, b)" },
    "and the line it replaced above it, dimmed around the word that went")

  -- Nearly all of a line changing is not the same thing: `return` and the
  -- brackets are still worth navigating by.
  local mostly = render("  return compute_everything(x)", "  return recalculate_all_of_it(x)")
  ok(mostly.band == nil, "a line that changed nearly end to end still keeps its marks")
  eq(mostly.marks, { "recalculate_all_of_it" }, "on the part that changed")
end

print("\n[every removal gets a row of its own]")
-- The old line above, the line that replaced it below, whatever the size
-- of the edit.
--
-- Small removals used to be folded into the line that replaced them --
-- `_closed` drawn beside the `_shutdown` that took its place, no screen
-- line spent -- on the grounds that a before-image is a lot of ceremony
-- for one word. The cost is that "removed" then has two shapes on one
-- screen: a red row above for the big edits, red text inside the code
-- for the small ones, and which one you get depends on a byte count the
-- reader cannot see. One shape always is what lets the red mean one
-- thing, and it puts every comparison in the same place: the row above.
do
  local diff = require("uatis.diff")
  local overlay = require("uatis.overlay")

  --- Renders one changed line and reports anything drawn inside it, and
  --- the before-image rows above it.
  local function render(old_line, new_line)
    local old = "local M = {}\n" .. old_line
    local new = "local M = {}\n" .. new_line
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(new, "\n", { plain = true }))
    vim.bo[buf].filetype = "lua"
    local out, done = { inline = {}, before = {} }, false
    diff.compute(old, new, { backend = "line", path = "x.lua", bufnr = buf }, function(r)
      overlay.render(buf, nil, r, vim.split(old, "\n", { plain = true }))
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1, { details = true })) do
        local d = m[4]
        if d.virt_text_pos == "inline" then
          for _, c in ipairs(d.virt_text or {}) do
            table.insert(out.inline, c[1])
          end
        end
        for _, vl in ipairs(d.virt_lines or {}) do
          local text = ""
          for _, c in ipairs(vl) do
            text = text .. c[1]
          end
          table.insert(out.before, text)
        end
      end
      done = true
    end)
    vim.wait(8000, function() return done end, 20)
    vim.api.nvim_buf_delete(buf, { force = true })
    return out
  end

  -- One word swapped: the smallest edit there is, and it still reads the
  -- same way as the largest.
  local swap = render("  self._closed = True", "  self._shutdown = True")
  eq(swap.inline, {}, "a one-word edit is not folded into the line that replaced it")
  eq(swap.before, { "-  self._closed = True" }, "the old line goes above it, whole")

  -- Two removals from one line, a removal with nothing replacing it, a
  -- digit inside a number, two whole words: every one of them used to be
  -- drawn in place, and every one of them is a row now.
  for _, case in ipairs({
    { "  return a - b", "  return b - a", "-  return a - b" },
    { "  call(a, b)", "  call(a)", "-  call(a, b)" },
    { "  local n = f(50_000)", "  local n = f(20_000)", "-  local n = f(50_000)" },
    { "  send(alpha, bravo, buffer)", "  send(delta, gamma, buffer)",
      "-  send(alpha, bravo, buffer)" },
  }) do
    local r = render(case[1], case[2])
    eq(r.inline, {}, "nothing is drawn inside `" .. case[2] .. "`")
    eq(r.before, { case[3] }, "and the line it replaced is the row above it")
  end

  -- The edits that always had a row keep exactly the one they had.
  local big = render("  return alpha - bravo", "  return omega - kilo")
  eq(big.inline, {}, "a line that mostly went is not folded into its replacement")
  eq(big.before, { "-  return alpha - bravo" }, "it keeps a row of its own")

  -- And never both: one removal, drawn once.
  local long = render("  x = 1", "  x = " .. string.rep("y", 40))
  eq(long.inline, {}, "a removal is never drawn twice, in place and above")
  ok(#long.before == 1, "just the once, above")
end

print("\n[one comparison, two sides, one answer]")
-- The old line and the new one are two halves of the same reading, and
-- they have to agree about which characters are the edit. A sub-token
-- swap drawn in place is what licenses narrowing difftastic's atom down
-- to the characters that are genuinely new -- and when the line takes
-- its old text back to a row of its own, that licence does not go with
-- it: the row marked the `5` and the `6` while the line under it marked
-- the whole of `20_000` and `30_000`.
do
  local diff = require("uatis.diff")
  local overlay = require("uatis.overlay")

  if vim.fn.executable(require("uatis.config").diff.struct.bin) ~= 1 then
    print("  skip both-sides checks (difftastic not installed)")
  else
    --- The new side's token marks, and the before-image split into what
    --- went (either removal group) and what stayed.
    local function sides(old, new)
      local lines = vim.split(new, "\n", { plain = true })
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].filetype = "python"
      local out, done = { marks = {}, gone = {}, stayed = {} }, false
      diff.compute(old, new, { backend = "struct", path = "x.py", bufnr = buf }, function(r)
        overlay.render(buf, nil, r, vim.split(old, "\n", { plain = true }))
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1, { details = true })) do
          local d = m[4]
          if d.end_col and d.hl_group == "UatisAdd" then
            table.insert(out.marks, (lines[m[2] + 1] or ""):sub(m[3] + 1, d.end_col))
          end
          for _, vl in ipairs(d.virt_lines or {}) do
            for _, c in ipairs(vl) do
              local groups = type(c[2]) == "table" and c[2] or { c[2] }
              local band = groups[#groups]
              if band == "UatisDelete" or band == "UatisDeleteBg" then
                table.insert(out.gone, c[1])
              elseif band == "UatisDeleteDim" and c[1]:match("%S") then
                table.insert(out.stayed, c[1])
              end
            end
          end
        end
        done = true
      end)
      vim.wait(8000, function() return done end, 20)
      vim.api.nvim_buf_delete(buf, { force = true })
      return out
    end

    local both = sides(
      "def f():\n    n = g(50_000, 60_000)\n    return n",
      "def f():\n    n = g(20_000, 30_000)\n    return n")
    eq(both.marks, { "2", "3" },
      "the new side marks the digits that are new, not the numbers they are in")
    eq(both.gone, { "5", "6" }, "and the row above marks the digits that went")
    ok(contains(both.stayed, "0_000"),
      "with the rest of each number stepped back, got " .. vim.inspect(both.stayed))
  end
end

print("\n[a signature pulled back onto one line]")
-- Lines folded into one reach the renderer as a pure deletion of the rows
-- that did not survive, anchored -- like every rowless deletion -- after
-- the last new row there was. Inline that put the removed parameters
-- BELOW the one-line signature, which reads as though they had been taken
-- out from between it and its body, and left the one line that changed
-- with nothing on it at all.
do
  local diff = require("uatis.diff")
  local overlay = require("uatis.overlay")

  if vim.fn.executable(require("uatis.config").diff.struct.bin) ~= 1 then
    print("  skip the folded-signature checks (difftastic not installed)")
  else
    --- Every before-image, as { row, above, lines = { { text, band } } }.
    local function images(old, new)
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(new, "\n", { plain = true }))
      vim.bo[buf].filetype = "python"
      local out, done = {}, false
      diff.compute(old, new, { backend = "struct", path = "x.py", bufnr = buf }, function(r)
        overlay.render(buf, nil, r, vim.split(old, "\n", { plain = true }))
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1, { details = true })) do
          local d = m[4]
          if d.virt_lines then
            local img = { row = m[2] + 1, above = d.virt_lines_above or false, lines = {} }
            for _, vl in ipairs(d.virt_lines) do
              local text, band = "", nil
              for _, c in ipairs(vl) do
                local groups = type(c[2]) == "table" and c[2] or { c[2] }
                if groups[#groups] ~= "UatisSign" then
                  text = text .. c[1]
                  band = band or groups[#groups]
                end
              end
              table.insert(img.lines, { (text:gsub("%s+$", "")), band })
            end
            table.insert(out, img)
          end
        end
        done = true
      end)
      vim.wait(8000, function() return done end, 20)
      vim.api.nvim_buf_delete(buf, { force = true })
      return out
    end

    local folded = images(
      "def place(\n    nodes: list[GraphNode],\n    edges: list[GraphEdge],\n"
        .. "    layout: Layout,\n) -> PlaceResult:\n    return None\n",
      "def place(nodes: list[GraphNode]) -> PlaceResult:\n    return None\n")
    ok(#folded == 1, "the fold is one before-image, got " .. #folded)
    local img = folded[1] or { lines = {} }
    ok(img.row == 1 and img.above, "drawn above the line the signature was folded into")
    eq(vim.tbl_map(function(l) return l[1] end, img.lines), {
      "def place(",
      "    nodes: list[GraphNode],",
      "    edges: list[GraphEdge],",
      "    layout: Layout,",
      ") -> PlaceResult:",
    }, "and it is the whole signature -- an opening bracket nobody closes is not the code that was there")
    eq(img.lines[1] and img.lines[1][2], "UatisDeleteDim",
      "the rows that came through the fold step back")
    eq(img.lines[5] and img.lines[5][2], "UatisDeleteDim", "both of them")
    eq(img.lines[4] and img.lines[4][2], "UatisDeleteBg",
      "while the parameter that went keeps the colour for code that went")

    -- An ordinary deletion is still a deletion: the removed rows sit
    -- after the line they were removed from, and nothing that survived
    -- is dragged into the image with them.
    local plain = images(
      "def f():\n    a = 1\n    b = 2\n    c = 3\n    return a\n",
      "def f():\n    a = 1\n    return a\n")
    local pimg = plain[1] or { lines = {} }
    ok(not pimg.above and pimg.row == 2,
      "a plain deletion still hangs below the row it was removed after")
    eq(vim.tbl_map(function(l) return l[1] end, pimg.lines),
      { "    b = 2", "    c = 3" }, "and draws only what went")
  end
end

print("\n[removed and added back are not both true]")
-- A docstring that gains two lines in the middle is one changed atom to
-- difftastic, so it lays the old sentences alongside the new ones in
-- order -- and the last of them comes out paired against text it has
-- nothing to do with. The row was then drawn in red above the line it
-- had been paired with, while the very same sentence sat four rows
-- below, drawn as new. Removed and added back at once, and the reader
-- left to work out which of the two the file actually did.
--
-- Suppressing the red half of that left the green half saying a line
-- had been added which the reader can see was already there. The
-- alignment is what is wrong, so the alignment is what is repaired: the
-- rows the two files hold identically pair up, and what is left is the
-- insertion, drawn where it happened.
do
  local diff = require("uatis.diff")
  local overlay = require("uatis.overlay")

  if vim.fn.executable(require("uatis.config").diff.struct.bin) ~= 1 then
    print("  skip the moved-sentence checks (difftastic not installed)")
  else
    local kept = "    The diagram is a structural overview: a length says nothing about it."
    local old = table.concat({
      "def f(t: str) -> str:",
      '    """Drop a modifier.',
      "",
      kept,
      "    It widens every box that carries one.",
      '    """',
      "    return t",
    }, "\n") .. "\n"
    local new = table.concat({
      "def f(t: str) -> str:",
      '    """Drop a modifier.',
      "",
      "    This is a fuuul",
      "    change that spaaans multiple liiines",
      "",
      "",
      kept,
      "    It widens every box that carries one.",
      '    """',
      "    return t",
    }, "\n") .. "\n"

    local lines = vim.split(new, "\n", { plain = true })
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = "python"
    local before, marked, done = {}, {}, false
    diff.compute(old, new, { backend = "struct", path = "x.py", bufnr = buf }, function(r)
      overlay.render(buf, nil, r, vim.split(old, "\n", { plain = true }))
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1, { details = true })) do
        local d = m[4]
        if d.line_hl_group or d.end_col then
          marked[m[2] + 1] = true
        end
        for _, vl in ipairs(d.virt_lines or {}) do
          local text = ""
          for _, c in ipairs(vl) do
            local groups = type(c[2]) == "table" and c[2] or { c[2] }
            if groups[#groups] ~= "UatisSign" then
              text = text .. c[1]
            end
          end
          table.insert(before, (text:gsub("%s+$", "")))
        end
      end
      done = true
    end)
    vim.wait(8000, function() return done end, 20)
    vim.api.nvim_buf_delete(buf, { force = true })

    ok(not contains(before, kept),
      "a sentence the render is drawing as new is not also drawn as removed, got "
        .. vim.inspect(before))
    eq(before, {}, "and nothing was taken out of the docstring at all")
    ok(not marked[8],
      "and the sentence is not drawn as arriving either -- it never moved")
    ok(marked[4] and marked[5],
      "what is marked is the text that is new, got " .. vim.inspect(vim.tbl_keys(marked)))

    -- ...and the same edit read the other way round. difftastic pairs
    -- the rows of the shortened docstring one off from the row each of
    -- them actually is, so every sentence below the cut was reported as
    -- a changed pair and the closing `\"\"\"` as a removal.
    local back, gone, seen = {}, {}, false
    local rbuf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(rbuf, 0, -1, false, vim.split(old, "\n", { plain = true }))
    vim.bo[rbuf].filetype = "python"
    diff.compute(new, old, { backend = "struct", path = "x.py", bufnr = rbuf }, function(r)
      overlay.render(rbuf, nil, r, vim.split(new, "\n", { plain = true }))
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(rbuf, overlay.ns, 0, -1, { details = true })) do
        local d = m[4]
        if d.line_hl_group or d.end_col then
          back[m[2] + 1] = true
        end
        for _, vl in ipairs(d.virt_lines or {}) do
          local text = ""
          for _, c in ipairs(vl) do
            local groups = type(c[2]) == "table" and c[2] or { c[2] }
            if groups[#groups] ~= "UatisSign" then
              text = text .. c[1]
            end
          end
          table.insert(gone, (text:gsub("%s+$", "")))
        end
      end
      seen = true
    end)
    vim.wait(8000, function() return seen end, 20)
    vim.api.nvim_buf_delete(rbuf, { force = true })

    ok(contains(gone, "This is a fuuul") and contains(gone, "change that spaaans"),
      "taking those lines back out shows them removed, got " .. vim.inspect(gone))
    eq(vim.tbl_keys(back), {},
      "and marks nothing as arriving -- the rows below the cut are the rows they were")

    -- ...and the same thing one layer further down. The alignment is
    -- repaired -- the untouched row pairs with itself -- and the hunk
    -- builder then swallowed it anyway, because a lone unchanged row
    -- between two changed ones belongs to the run they are both part of.
    -- Between a DELETION and an INSERTION it does not: the row goes into
    -- the hunk's old range, and the before-image draws it in red
    -- directly above the identical green row it never left.
    local opts_line = [[    \s*(?P<options>.*?)\s*;?\s*$]]
    local before_src = table.concat({
      "import re",
      "",
      "_LOAD_RE = re.compile(",
      [[    r"""]],
      [[    ^\s*load\s+(?:table\s+)?]],
      [[    \s+(?:from\s+)?]],
      [[    '(?P<path>(?:[^']|'')*)']],
      opts_line,
      [[    """,]],
      "    re.IGNORECASE,",
      ")",
    }, "\n") .. "\n"
    local after_src = table.concat({
      "import re",
      "",
      "_LOAD_RE = re.compile(",
      [[    r"""]],
      [[    ^\s*load\s+(?:table\s+)?]],
      [[    \s+(?:from\s+)?]],
      opts_line,
      "    asdfoo",
      [[    """,]],
      "    re.IGNORECASE,",
      ")",
    }, "\n") .. "\n"

    local shed, lit, ready = {}, {}, false
    local pbuf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(pbuf, 0, -1, false,
      vim.split(after_src, "\n", { plain = true }))
    vim.bo[pbuf].filetype = "python"
    diff.compute(before_src, after_src, { backend = "struct", path = "x.py", bufnr = pbuf },
      function(r)
        overlay.render(pbuf, nil, r, vim.split(before_src, "\n", { plain = true }))
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(pbuf, overlay.ns, 0, -1,
          { details = true })) do
          local d = m[4]
          if d.line_hl_group or d.end_col then
            lit[m[2] + 1] = true
          end
          for _, vl in ipairs(d.virt_lines or {}) do
            local text = ""
            for _, c in ipairs(vl) do
              local groups = type(c[2]) == "table" and c[2] or { c[2] }
              if groups[#groups] ~= "UatisSign" then
                text = text .. c[1]
              end
            end
            table.insert(shed, (text:gsub("%s+$", "")))
          end
        end
        ready = true
      end)
    vim.wait(8000, function() return ready end, 20)
    vim.api.nvim_buf_delete(pbuf, { force = true })

    ok(contains(shed, "(?P<path>"),
      "the line the regex lost is drawn as removed, got " .. vim.inspect(shed))
    ok(not contains(shed, "(?P<options>"),
      "and the line below it is not: it is still there, on screen, unchanged")
    ok(not lit[7],
      "nor is it drawn as arriving, got " .. vim.inspect(vim.tbl_keys(lit)))
    ok(lit[8], "what is new is the line that is new")
  end
end

print("\n[a moved function is drawn as a move]")
-- A function moved to the top of the file and given a new body is a
-- removal in one place and an addition in another to both backends. It
-- is drawn as one line where it was -- not its body in red, since
-- nothing of it went -- and at its new place as an edit of its old
-- self, with `]c` stopping at both ends. A function rewritten where it
-- stands is not a move, and neither is one too short to tell apart.
do
  local diff = require("uatis.diff")
  local overlay = require("uatis.overlay")

  --- Renders `new` against `old` and reads back what was drawn: the
  --- virtual lines (minus the removal marker), the rows carrying the
  --- move's bar, and the `]c` stops.
  local function drawn(old, new, backend, path, ft)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, new)
    vim.bo[buf].filetype = ft
    local out, done = { virt = {}, bars = {} }, false
    diff.compute(table.concat(old, "\n"), table.concat(new, "\n"),
      { backend = backend, path = path, bufnr = buf }, function(r)
        out.stops = overlay.render(buf, nil, r, old)
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1, { details = true })) do
          if m[4].sign_hl_group == "UatisMove" then
            table.insert(out.bars, m[2] + 1)
          end
          for _, vl in ipairs(m[4].virt_lines or {}) do
            local text = ""
            for _, c in ipairs(vl) do
              local groups = type(c[2]) == "table" and c[2] or { c[2] }
              if groups[#groups] ~= "UatisSign" then
                text = text .. c[1]
              end
            end
            table.insert(out.virt, (text:gsub("%s+$", "")))
          end
        end
        done = true
      end)
    vim.wait(8000, function() return done end, 20)
    vim.api.nvim_buf_delete(buf, { force = true })
    return out
  end

  local has_py = require("uatis.syntax").lang_of("python") ~= nil
  if vim.fn.executable(require("uatis.config").diff.struct.bin) ~= 1 or not has_py then
    print("  skip the moved-function checks (difftastic or the python parser missing)")
  else
    local old = {
      "import os",
      "",
      "",
      "def alpha(x):",
      "    return x + 1",
      "",
      "",
      'def gamma(path, mode="r"):',
      "    with open(path, mode) as fh:",
      "        data = fh.read()",
      "    lines = data.splitlines()",
      "    return [l.strip() for l in lines if l]",
    }
    local new = {
      "import os",
      "",
      "",
      'def gamma(path, mode="r"):',
      "    with open(path, mode) as fh:",
      "        data = fh.read()",
      "    return data.split()",
      "",
      "",
      "def alpha(x):",
      "    return x + 1",
    }
    local got = drawn(old, new, "struct", "x.py", "python")
    eq(got.virt, {
      "⇣gamma moved from line 8 · 1 change",
      "    lines = data.splitlines()",
      "    return [l.strip() for l in lines if l]",
      "⇡gamma moved to line 4 · 1 change",
    }, "one line at each end, and only what changed inside the function drawn as removed")
    eq(got.bars, { 4, 5, 6, 7 }, "the moved function carries the bar, row for row")
    eq(got.stops, { 4, 7, 11 }, "]c stops at the new place, the edit inside it, and the old place")

    -- Where no move is read -- no parser, or switched off -- the old
    -- copy is still removed whole: the new copy's rows read exactly like
    -- the old copy's, and once excused them out of its before-image,
    -- leaving the body without its signature hanging under `alpha`.
    local move = require("uatis.config").diff.move
    move.enabled = false
    got = drawn(old, new, "struct", "y.py", "python")
    move.enabled = true
    eq(got.virt, {
      'def gamma(path, mode="r"):',
      "    with open(path, mode) as fh:",
      "        data = fh.read()",
      "    lines = data.splitlines()",
      "    return [l.strip() for l in lines if l]",
    }, "without the move, the old copy is drawn whole, signature and all")

    -- The line backend matches `gamma` in place and moves `alpha`
    -- instead; given three rows, it is a move unchanged.
    local old2 = { "import os", "", "", "def alpha(x):", "    y = x * 2", "    return y + 1",
      "", "", "def gamma(p):", "    a = 1", "    return a" }
    local new2 = { "import os", "", "", "def gamma(p):", "    a = 1", "    return a",
      "", "", "def alpha(x):", "    y = x * 2", "    return y + 1" }
    got = drawn(old2, new2, "line", "x.py", "python")
    eq(got.virt, {
      "⇣alpha moved to line 9 · unchanged",
      "⇡alpha moved from line 4 · unchanged",
    }, "a move with nothing changed says so, and draws nothing red or green")
    eq(got.stops, { 4, 9 }, "...and stops at both ends")

    got = drawn({ "x = 1", "", "def f(a):", "    b = a", "    return b", "", "y = 2" },
      { "x = 1", "", "def f(a, c):", "    d = a + c", "    return d", "", "y = 2" },
      "struct", "x.py", "python")
    eq(got.bars, {}, "a function rewritten where it stands is not a move")

    -- Two classes whose `desc` docstrings each grew a paragraph. Each
    -- docstring is one atom, so each lies wholly inside its hunk on both
    -- sides, and with the copy in place left out of the scoring each was
    -- paired by name with the OTHER class's: drawn as swapped, the old
    -- text of one in red above the other.
    local function setting(name, body)
      local out = { "class " .. name .. "(Setting):", '    desc = """\\' }
      vim.list_extend(out, body)
      vim.list_extend(out, { '        """', "", "" })
      return out
    end
    local t_body = { "        Workers silent for more than this many seconds are killed.", "",
      "        Value is a positive number or 0." }
    local k_body = { "        The number of seconds to wait on a Keep-Alive connection.", "",
      "        Generally set in the 1-5 seconds range." }
    local docs_old = setting("Timeout", t_body)
    vim.list_extend(docs_old, setting("Keepalive", k_body))
    local docs_new = setting("Timeout", vim.list_extend(vim.deepcopy(t_body),
      { "", "        On HTTP/2 it also bounds a single stream." }))
    vim.list_extend(docs_new, setting("Keepalive", vim.list_extend(vim.deepcopy(k_body),
      { "", "        An idle HTTP/2 connection is closed with GOAWAY." })))
    got = drawn(docs_old, docs_new, "struct", "x.py", "python")
    eq(got.bars, {}, "two docstrings that each grew in place are not swapped")
    eq(got.virt, {}, "and neither is drawn as the other's old text")

    -- A class header taken out, so the methods under it now continue
    -- the class above, and the method just above it replaced. To
    -- difftastic the methods are new in one class and gone from the
    -- other, and it paired the replaced method with one that stayed;
    -- the agreed rows it did find -- blank lines, a `c = Config()` --
    -- each cut the damage into a region of its own, too small for the
    -- line diff to see a method in one as the same method in another.
    -- An unchanged method came out as an edit of the removed one, as
    -- removed again lower down, and as moved.
    local function class(name, doc, methods)
      local out = { "class " .. name .. ":", '    """' .. doc .. '"""', "" }
      for k, m in ipairs(methods) do
        vim.list_extend(out, m)
        if k < #methods then
          table.insert(out, "")
        end
      end
      return out
    end
    local negative = { "    def test_negative_value_raises(self):", "        c = Config()",
      "        with pytest.raises(ValueError):",
      '            c.set("http2_max_concurrent_streams", -1)' }
    local window = {
      { "    def test_default_value(self):", "        c = Config()",
        "        # Default per RFC 7540 is 65535",
        "        assert c.http2_initial_window_size == 65535" },
      { "    def test_set_custom_value(self):", "        c = Config()",
        '        c.set("http2_initial_window_size", 131072)',
        "        assert c.http2_initial_window_size == 131072" },
      { "    def test_set_from_string(self):", "        c = Config()",
        '        c.set("http2_initial_window_size", "32768")',
        "        assert c.http2_initial_window_size == 32768" },
    }
    local header_old = class("TestHttp2MaxConcurrentStreams",
      "Test http2_max_concurrent_streams configuration setting.", { negative,
        { "    def test_zero_value(self):",
          "        # Zero is technically valid for positive int validator",
          "        # It may have special meaning (use h2 default)",
          "        c = Config()",
          '        c.set("http2_max_concurrent_streams", 0)',
          "        assert c.http2_max_concurrent_streams == 0" } })
    vim.list_extend(header_old, { "", "" })
    vim.list_extend(header_old, class("TestHttp2InitialWindowSize",
      "Test http2_initial_window_size configuration setting.", window))
    local header_new = class("TestHttp2MaxConcurrentStreams",
      "Test http2_max_concurrent_streams configuration setting.", { negative,
        { "    def test_zero_value_is_rejected(self):",
          '        """0 would advertise a connection that can open no streams."""',
          "        c = Config()",
          "        with pytest.raises(ValueError):",
          '            c.set("http2_max_concurrent_streams", 0)' },
        window[1], window[2], window[3] })
    got = drawn(header_old, header_new, "struct", "x.py", "python")
    eq(got.bars, {}, "methods a removed class header handed up are not moved")
    -- Each removal once, above or below what it answers to: the
    -- replaced method's head and tail above theirs, the header under
    -- the last line of the class it used to follow. The tail is drawn
    -- once -- read as folded into the row under it, it came back a
    -- second time with the header.
    eq(got.virt, {
      "    def test_zero_value(self):",
      "        # Zero is technically valid for positive int validator",
      "        # It may have special meaning (use h2 default)",
      '        c.set("http2_max_concurrent_streams", 0)',
      "        assert c.http2_max_concurrent_streams == 0",
      "class TestHttp2InitialWindowSize:",
      '    """Test http2_initial_window_size configuration setting."""',
    }, "and only what went is drawn as gone, once")
  end
end

print("\n[<C-]> goes to the other end of a move, and only off a symbol]")
-- The two lines naming a move's ends are virtual, so the key works from
-- the rows they stand for. On an identifier it is go-to-definition's, as
-- it was: a moved function is made of symbols. A keyword is not one.
do
  local k = require("uatis.config").keys.view.move_jump
  local symbol = 0
  vim.keymap.set("n", k, function() symbol = symbol + 1 end)
  local buf, view = open_view("calc.lua", "main")
  act(view, function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "local M = {}", "", "function M.sub(a, b)", "  return a - b", "end", "",
      "function M.add(a, b)", "  return a + b", "end", "", "return M",
    })
  end, "a render of the moved function")
  wait_for(function() return view.moves ~= nil end, "the move to be read")
  local mv = view.moves and view.moves[1]
  if ok(mv ~= nil and #view.moves == 1, "one function read as moved") then
    local function press(row, col)
      vim.api.nvim_win_set_cursor(0, { row, col })
      vim.api.nvim_feedkeys(vim.keycode(k), "mx", false)
    end
    local at = math.min(mv.at, vim.api.nvim_buf_line_count(buf))
    -- The indentation of the body's second row.
    press(mv.new.first + 1, 0)
    wait_for(function() return vim.api.nvim_win_get_cursor(0)[1] == at end, "the jump to the old end")
    eq(vim.api.nvim_win_get_cursor(0)[1], at, "from inside the moved function to where it was")
    local line = vim.api.nvim_buf_get_lines(buf, at - 1, at, false)[1]
    press(at, math.max((line:find("[^%w_]") or 1) - 1, 0))
    if line:match("^[%w_]") and not line:find("[^%w_]") then
      print("  skip the jump back (the old end hangs above a row of one word)")
    else
      wait_for(function() return vim.api.nvim_win_get_cursor(0)[1] == mv.new.first end,
        "the jump back")
      eq(vim.api.nvim_win_get_cursor(0)[1], mv.new.first, "...and back again")
    end
    -- A keyword cannot be a definition's name.
    press(at, 0)
    wait_for(function() return vim.api.nvim_win_get_cursor(0)[1] ~= at end, "a jump")
    press(mv.new.first, 0)
    wait_for(function() return vim.api.nvim_win_get_cursor(0)[1] == at end,
      "the jump from the keyword the signature opens with")
    eq(vim.api.nvim_win_get_cursor(0)[1], at, "on `function`, the key is still the move's")
    eq(symbol, 0, "none of those went through the mapping it shadows")
    press(mv.new.first, ("function M."):len())
    eq(symbol, 1, "on a symbol, the mapping that was there before runs")
  end
  view_mod.close(buf)
  vim.keymap.del("n", k)
  vim.cmd("edit!")
end

print("\n[a before-image follows the gutter it is drawn beside]")
-- The indent of a before-image is spaces as wide as the gutter was when it
-- was drawn. A gutter that changes after -- 'number' turned on, a sign
-- column opening -- is found on the next redraw and drawn for; and a view
-- whose own window has closed while its buffer stays in another is drawn
-- for THAT one, not for a window with no gutter at all.
do
  local function indent(buf)
    for _, m in ipairs(marks(buf)) do
      for _, vl in ipairs(m[4].virt_lines or {}) do
        if vl[1] and vl[1][2] == "UatisSign" then
          return vim.fn.strdisplaywidth(vl[1][1])
        end
      end
    end
  end
  local function textoff()
    return vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].textoff
  end
  vim.wo.number, vim.wo.signcolumn = false, "no"
  local buf, view = open_view("calc.lua", "main")
  act(view, function()
    vim.api.nvim_buf_set_lines(buf, 3, 4, false, {})
  end, "a render with a line removed")
  eq(indent(buf), math.max(textoff(), 1), "drawn for a window with no gutter")
  act(view, function()
    vim.wo.number, vim.wo.signcolumn = true, "yes"
    vim.cmd("redraw")
  end, "a render once the gutter has opened")
  vim.cmd("redraw")
  eq(indent(buf), textoff(), "the gutter opening is drawn for")
  local first = vim.api.nvim_get_current_win()
  vim.cmd("vsplit")
  vim.wo.number, vim.wo.signcolumn = true, "yes:2"
  vim.api.nvim_win_close(first, true)
  act(view, function()
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "-- edited" })
  end, "a render after the view's own window closed")
  vim.cmd("redraw")
  eq(indent(buf), textoff(), "measured on the window the buffer is still in")
  view_mod.close(buf)
  vim.cmd("edit!")
  vim.wo.number, vim.wo.signcolumn = false, "auto"
end

print("\n[side by side, a move is read across from its old copy]")
-- The alignment keeps one order and a move breaks it, so the two copies
-- stand opposite blank rows. The old copy is not red -- only what was
-- removed inside it is -- and while the cursor is in the new copy the
-- old window shows the old one, row for row. `<CR>` and `<C-]>` from
-- the old copy land on the row it became.
do
  local oldside = require("uatis.oldside")
  local buf, view = open_view("calc.lua", "main")
  act(view, function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "local M = {}", "", "function M.sub(a, b)", "  return b - a", "end", "",
      "function M.add(a, b)", "  return a + b", "end", "", "return M",
    })
  end, "a render of the moved function")
  wait_for(function() return view.moves ~= nil end, "the move to be read")
  local mv = view.moves and view.moves[1]
  act(view, function() view_mod.choose_layout(view, "side") end, "the side-by-side render")
  wait_for(function() return oldside.is_open(view) and view.old_at_line ~= nil end,
    "the old window")
  if ok(mv ~= nil and mv.name == "M.sub" and mv.changes == 1, "M.sub read as moved and edited") then
    local ob = view.old.buf
    local function marks(line)
      local row = view.old_at_line[line] - 1
      return vim.api.nvim_buf_get_extmarks(ob, oldside.ns, { row, 0 }, { row, -1 }, { details = true })
    end
    local function red(line)
      for _, m in ipairs(marks(line)) do
        if (m[4].line_hl_group or m[4].hl_group) == "UatisDeleteBand" then
          return true
        end
      end
      return false
    end
    eq({ red(mv.old.first), red(mv.old.first + 1), red(mv.old.last) }, { false, true, false },
      "only the line the moved function lost is red in the old window")
    local note
    for _, m in ipairs(marks(mv.old.first)) do
      note = note or (m[4].virt_text and m[4].virt_text[1][1])
    end
    ok(note and note:find("M.sub moved to line 3", 1, true),
      "and its first row says where it went, got: " .. tostring(note))
    local lines = 0
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1, { details = true })) do
      lines = lines + #(m[4].virt_lines or {})
    end
    eq(lines, 0, "nothing in your buffer takes a row the old window does not have")
    local bar = vim.api.nvim_eval_statusline("%{v:lua.require'uatis.oldside'.number()}",
      { winid = view.old.win, use_statuscol_lnum = view.old_at_line[mv.old.first] }).str
    ok(bar:find("UatisMove", 1, true), "the old copy carries the bar, got: " .. bar)

    vim.api.nvim_set_current_win(view.win)
    vim.api.nvim_win_set_cursor(view.win, { mv.new.first + 1, 0 })
    oldside.sync(view, mv.new.first + 1)
    eq(view.old_of_row[vim.api.nvim_win_get_cursor(view.old.win)[1]], mv.old.first + 1,
      "inside the new copy, the old window stands on the old one")

    for _, key in ipairs({ require("uatis.config").keys.old.jump,
      require("uatis.config").keys.view.move_jump }) do
      vim.api.nvim_set_current_win(view.old.win)
      vim.api.nvim_win_set_cursor(view.old.win, { view.old_at_line[mv.old.last], 0 })
      vim.api.nvim_feedkeys(vim.keycode(key), "mx", false)
      eq({ vim.api.nvim_get_current_win() == view.win, vim.api.nvim_win_get_cursor(view.win)[1] },
        { true, mv.new.last }, key .. " from the old copy lands on the row it became")
    end
  end
  view_mod.choose_layout(view, "inline")
  view_mod.close(buf)
  vim.cmd("edit!")
end

print("\n[a move is read at both ends]")
-- git does not see a move: it reports whatever its own diff made of the
-- rows, and its chunk where the definition used to be has no row on the
-- new side for the old end to stand on. That end stands on git's chunks
-- by their OLD rows, and each end is left on its own -- the move is read
-- once both are, and not before.
do
  local cfg = require("uatis.config")
  local read = require("uatis.read")
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local function sh(...)
    vim.system({ "git", "-C", dir, ... }, { text = true }):wait()
  end
  local calc = { "local M = {}", "", "function M.add(a, b)", "  return a + b", "end", "",
    "function M.sub(a, b)", "  return a - b", "end", "", "return M" }
  sh("init", "-q", "-b", "main")
  sh("config", "user.email", "t@example.com")
  sh("config", "user.name", "T")
  sh("config", "commit.gpgsign", "false")
  vim.fn.writefile(calc, dir .. "/calc.lua")
  sh("add", "calc.lua")
  sh("commit", "-qm", "initial")
  vim.fn.writefile({ "local M = {}", "", "function M.sub(a, b)", "  return b - a", "end", "",
    "function M.add(a, b)", "  return a + b", "end", "", "return M" }, dir .. "/calc.lua")

  local spill = cfg.pane.chunk_spill
  cfg.pane.chunk_spill = false
  vim.cmd("tabnew")
  vim.cmd("tcd " .. vim.fn.fnameescape(dir))
  vim.cmd("edit calc.lua")
  local buf = vim.api.nvim_get_current_buf()
  uatis.run({ fargs = { "main" } })
  wait_for(function()
    local v = view_mod.get(buf)
    return v ~= nil and (v.renders or 0) > 0 and v.moves ~= nil
  end, "the move to be read")
  local list
  wait_for(function()
    list = pane_mod.get()
    return list ~= nil and (list.renders or 0) > 0
  end, "the list")
  local v = view_mod.get(buf)
  local f = require("uatis.patch").find(list.files, "calc.lua")
  if ok(v and v.moves and f and #f.chunks == 2, "one move, and git's two chunks for it") then
    local function state()
      local s = ""
      for _, c in ipairs(f.chunks) do
        s = s .. (read.chunk_read(list, f, c) and "R" or ".")
      end
      return s, read.stops_read(list, f, view_mod.stops(v))
    end
    eq(#view_mod.stops(v), #v.anchors, "the read stops are the stops `]c` makes")
    local _, before = state()
    eq(before, { done = 0, total = #v.anchors }, "nothing is read before the reader has moved")
    local km = vim.fn.maparg(cfg.keys.view.hunk_next, "n", false, true)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local seen = {}
    for _ = 1, #v.anchors + 1 do
      km.callback()
      table.insert(seen, (state()))
    end
    local last = seen[#seen]
    eq({ seen[#seen - 1], last }, { "R.", "RR" },
      "the new copy read leaves the old end's chunk unread, until the old end is left too")
    local _, after = state()
    eq(after, { done = #v.anchors, total = #v.anchors }, "and every stop is read")
    ok(read.is_read(list, f), "which is the file read")

    -- `<C-]>` off an end leaves it, as `]c` does: what was stood on is
    -- read, and the end jumped to is not, until it too is left.
    list.read, list.left = {}, {}
    local mv = v.moves[1]
    local count = vim.api.nvim_buf_line_count(buf)
    local at = math.max(math.min(mv.at, count), 1)
    local jump = vim.keycode(cfg.keys.view.move_jump)
    vim.api.nvim_win_set_cursor(0, { mv.new.first + 1, 0 })
    vim.api.nvim_feedkeys(jump, "mx", false)
    wait_for(function() return vim.api.nvim_win_get_cursor(0)[1] == at end, "<C-]> to the old end")
    local s1, h1 = state()
    eq({ s1, h1.done }, { "R.", 2 },
      "<C-]> off the new copy leaves it and the edit in it: their chunk is read")
    vim.api.nvim_feedkeys(jump, "mx", false)
    wait_for(function() return vim.api.nvim_win_get_cursor(0)[1] == mv.new.first end, "<C-]> back")
    local s2, h2 = state()
    eq({ s2, h2.done }, { "RR", 3 }, "and back off the old end leaves that too")
  end
  view_mod.stop(view_mod.get(buf))
  vim.cmd("tabclose")
  cfg.pane.chunk_spill = spill
  vim.fn.delete(dir, "rf")
end

print("\n[a definition moved to another file is drawn as a move at both ends]")
-- Taken out of one file and put into another, a function is in two
-- comparisons that cannot see each other: removed whole in one, added
-- whole in the other. The review pairs them, and each file draws its own
-- end -- one line where it went, an edit of its old self where it came.
do
  local cfg = require("uatis.config")
  local read = require("uatis.read")
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local function sh(...)
    vim.system({ "git", "-C", dir, ... }, { text = true }):wait()
  end
  sh("init", "-q", "-b", "main")
  sh("config", "user.email", "t@example.com")
  sh("config", "user.name", "T")
  sh("config", "commit.gpgsign", "false")
  vim.fn.writefile({ "local M = {}", "", "function M.add(a, b)", "  return a + b", "end", "",
    "function M.sub(a, b)", "  local d = a - b", "  return d", "end", "", "return M" }, dir .. "/calc.lua")
  vim.fn.writefile({ "local U = {}", "", "function U.id(x)", "  return x", "end", "", "return U" },
    dir .. "/util.lua")
  sh("add", ".")
  sh("commit", "-qm", "initial")
  vim.fn.writefile({ "local M = {}", "", "function M.add(a, b)", "  return a + b", "end", "",
    "return M" }, dir .. "/calc.lua")
  vim.fn.writefile({ "local U = {}", "", "function U.id(x)", "  return x", "end", "",
    "function M.sub(a, b)", "  local d = b - a", "  return d", "end", "", "return U" }, dir .. "/util.lua")

  local spill = cfg.pane.chunk_spill
  cfg.pane.chunk_spill = false
  vim.cmd("tabnew")
  vim.cmd("tcd " .. vim.fn.fnameescape(dir))
  vim.cmd("edit calc.lua")
  local calc = vim.api.nvim_get_current_buf()
  uatis.run({ fargs = { "main" } })
  local list
  wait_for(function()
    list = pane_mod.get()
    return list ~= nil and list.moves_across ~= nil and #list.moves_across > 0
  end, "the review's index of moves between files")
  local index = list and list.moves_across or {}
  eq(vim.tbl_map(function(e) return { e.name, e.from.path, e.to.path } end, index),
    { { "M.sub", "calc.lua", "util.lua" } }, "the review pairs the function across the two files")

  local function virt(buf)
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1, { details = true })) do
      for _, vl in ipairs(m[4].virt_lines or {}) do
        local t = ""
        for _, c in ipairs(vl) do
          t = t .. c[1]
        end
        table.insert(out, (t:gsub("%s+$", "")))
      end
    end
    return out
  end

  wait_for(function()
    local v = view_mod.get(calc)
    return v ~= nil and v.moves ~= nil
  end, "calc.lua to draw its end")
  local vc = view_mod.get(calc)
  eq(vc and vim.tbl_map(function(m) return m.kind end, vc.moves), { "out" }, "calc.lua has the move's old end")
  eq(virt(calc), { "↦M.sub moved to util.lua:7 · 1 change" },
    "drawn as one line, not the function in red, counting what changed on the way")

  vim.cmd("edit util.lua")
  local util = vim.api.nvim_get_current_buf()
  wait_for(function()
    local v = view_mod.get(util)
    return v ~= nil and v.moves ~= nil
  end, "util.lua to draw its end")
  local vu = view_mod.get(util)
  local mv = vu and vu.moves[1]
  eq(mv and { mv.kind, mv.new.first, mv.new.last, mv.changes }, { "in", 7, 10, 1 },
    "util.lua has the new copy, compared against its old self")
  eq(virt(util), { "↤M.sub moved from calc.lua:7 · 1 change", "-  local d = a - b" },
    "only what was edited on the way is drawn as removed")

  local stops = view_mod.stops(vu)
  ok(#stops >= 1 and stops[1].lo == 7, "the new copy is a stop")
  local f = require("uatis.patch").find(list.files, "calc.lua")
  local cstops = view_mod.stops(vc)
  local at_old = {}
  for _, s in ipairs(cstops) do
    if s.old then
      vim.list_extend(at_old, read.covering(f, s))
    end
  end
  ok(#at_old > 0, "and the old end stands on git's chunk where the function was")

  local k = vim.keycode(cfg.keys.view.move_jump)
  vim.api.nvim_win_set_cursor(0, { 7, 0 })
  vim.api.nvim_feedkeys(k, "mx", false)
  wait_for(function() return vim.api.nvim_get_current_buf() == calc end, "<C-]> into calc.lua")
  local at = math.max(math.min(vc.moves[1].at, vim.api.nvim_buf_line_count(calc)), 1)
  eq(vim.api.nvim_win_get_cursor(0)[1], at, "<C-]> on the new copy lands on the old end, in the other file")
  vim.api.nvim_feedkeys(k, "mx", false)
  wait_for(function() return vim.api.nvim_get_current_buf() == util end, "<C-]> back into util.lua")
  eq(vim.api.nvim_win_get_cursor(0)[1], 7, "...and back onto the new copy")

  -- Which files are looked at is a question of language: prose and data
  -- have trees too. Moves inside one file are not affected.
  local skip = cfg.diff.move.across_skip
  cfg.diff.move.across_only = { "python" }
  require("uatis.xmoves").build(list)
  eq(list.moves_across, {}, "a language left out is not looked at between files")
  cfg.diff.move.across_only = false
  cfg.diff.move.across_skip = { "lua" }
  require("uatis.xmoves").build(list)
  eq(list.moves_across, {}, "...and neither is one skipped")
  cfg.diff.move.across_skip = nil
  require("uatis.xmoves").build(list)
  wait_for(function() return #(list.moves_across or {}) == 1 end, "the index back")
  cfg.diff.move.across_skip = skip

  view_mod.stop(view_mod.get(util))
  vim.cmd("tabclose")
  cfg.pane.chunk_spill = spill
  vim.fn.delete(dir, "rf")
end

print("\n[a move between files, in a commit]")
-- With a commit on show both sides come out of git -- the commit and
-- its parent -- and the index is the answer for that one commit, never
-- handed to a view measuring another. `:UatisShow` and stepping a branch
-- commit by commit read the move the way the working tree does.
do
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local function sh(...)
    return vim.trim(vim.system({ "git", "-C", dir, ... }, { text = true }):wait().stdout or "")
  end
  sh("init", "-q", "-b", "main")
  sh("config", "user.email", "t@example.com")
  sh("config", "user.name", "T")
  sh("config", "commit.gpgsign", "false")
  vim.fn.writefile({ "local M = {}", "", "function M.add(a, b)", "  return a + b", "end", "",
    "function M.sub(a, b)", "  local d = a - b", "  return d", "end", "", "return M" }, dir .. "/calc.lua")
  vim.fn.writefile({ "local U = {}", "", "function U.id(x)", "  return x", "end", "", "return U" },
    dir .. "/util.lua")
  sh("add", ".")
  sh("commit", "-qm", "initial")
  sh("switch", "-qc", "feat")
  vim.fn.writefile({ "local M = {}", "", "function M.add(a, b)", "  return a + b", "end", "",
    "return M" }, dir .. "/calc.lua")
  vim.fn.writefile({ "local U = {}", "", "function U.id(x)", "  return x", "end", "",
    "function M.sub(a, b)", "  local d = b - a", "  return d", "end", "", "return U" }, dir .. "/util.lua")
  sh("commit", "-qam", "move sub")
  local sha = sh("rev-parse", "HEAD")

  vim.cmd("tabnew")
  local home = vim.api.nvim_get_current_tabpage()
  vim.cmd("tcd " .. vim.fn.fnameescape(dir))
  uatis.show_commit(sha)
  local p
  wait_for(function()
    p = pane_mod.get()
    return p ~= nil and p.standalone and p.moves_across ~= nil and #p.moves_across == 1
  end, "the commit's index of moves between files")
  eq(p and p.moves_across and { p.moves_across[1].from.path, p.moves_across[1].to.path },
    { "calc.lua", "util.lua" }, ":UatisShow pairs the move out of the commit and its parent")

  local idx
  for i, f in ipairs(p and p.files or {}) do
    if f.path == "calc.lua" then idx = i end
  end
  pane_mod.goto_file(p, idx)
  local v
  wait_for(function()
    v = view_mod.get(vim.api.nvim_get_current_buf())
    return v ~= nil and v.relpath == "calc.lua" and v.moves ~= nil
  end, "calc.lua at the commit to draw its end")
  eq(v and vim.tbl_map(function(m) return m.kind end, v.moves), { "out" },
    "the commit's calc.lua has the old end")
  local at = v and math.max(math.min(v.moves[1].at, vim.api.nvim_buf_line_count(v.bufnr)), 1)
  if v then
    vim.api.nvim_win_set_cursor(0, { at, 0 })
    vim.api.nvim_feedkeys(vim.keycode(require("uatis.config").keys.view.move_jump), "mx", false)
  end
  wait_for(function()
    local u = view_mod.get(vim.api.nvim_get_current_buf())
    return u ~= nil and u.relpath == "util.lua" and u.moves ~= nil
      and vim.api.nvim_win_get_cursor(0)[1] == 7
  end, "<C-]> into the commit's util.lua, on the new copy")
  local u = view_mod.get(vim.api.nvim_get_current_buf())
  eq(u and u.moves[1] and { u.moves[1].kind, u.moves[1].changes }, { "in", 1 },
    "where the copy is an edit of its old self")
  if u then
    view_mod.stop(u)
  end
  wait_for(function() return pane_mod.get() == nil or not pane_mod.get().standalone end,
    "the commit's review to end")

  -- Commit by commit: the branch's one commit is the move, and entering it
  -- builds that commit's index.
  if vim.api.nvim_tabpage_is_valid(home) then
    vim.api.nvim_set_current_tabpage(home)
  end
  vim.cmd("edit calc.lua")
  uatis.run({ fargs = { "main" } })
  wait_for(function()
    p = pane_mod.get()
    return p ~= nil and (p.renders or 0) > 0
  end, "the branch review")
  local turns = p.renders
  pane_mod.toggle_commits(p)
  wait_for(function()
    return p.commit ~= nil and (p.renders or 0) > turns and p.moves_across ~= nil
      and p.across_key == p.rev .. ":" .. p.commit.sha
  end, "the commit on show to have its own index")
  eq(#(p.moves_across or {}), 1, "stepping onto the commit finds the move in it")
  local cur = view_mod.get(vim.api.nvim_get_current_buf())
  if cur then
    view_mod.stop(cur)
  end
  vim.cmd("tabclose")
  vim.fn.delete(dir, "rf")
end

print("\n[moves between files: into a new file, out of a deleted or renamed one, several at once]")
-- A module split up is several moves at once, and their sources and
-- destinations are every kind of file a review lists: a file nobody has
-- told git about yet, a file the branch deleted, a file it renamed.
do
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local function sh(...)
    return vim.trim(vim.system({ "git", "-C", dir, ... }, { text = true }):wait().stdout or "")
  end
  local function put(path, lines)
    vim.fn.writefile(lines, dir .. "/" .. path)
  end
  sh("init", "-q", "-b", "main")
  sh("config", "user.email", "t@example.com")
  sh("config", "user.name", "T")
  sh("config", "commit.gpgsign", "false")
  put("a.lua", { "local A = {}", "", "function A.one(x)", "  local y = x * 2", "  return y", "end", "",
    "function A.two(s)", "  local t = s:upper()", "  local u = t:reverse()", "  return u", "end", "",
    "return A" })
  put("gone.lua", { "local G = {}", "", "function G.three(list)", "  local n = 0",
    "  for _ in ipairs(list) do n = n + 1 end", "  return n", "end", "", "return G" })
  local keep = { "local O = {}", "", "function O.keep(a, b, c)", "  local first = a or 1",
    "  local second = b or 2", "  local third = c or 3", "  local total = first + second + third",
    "  if total > 10 then", "    return total - 10", "  end", "  return total", "end", "" }
  put("old_name.lua", vim.list_extend(vim.deepcopy(keep), { "function O.four(t)", "  local k = {}",
    "  for key in pairs(t) do k[#k + 1] = key end", "  return k", "end", "", "return O" }))
  put("dest.lua", { "local D = {}", "", "function D.base()", "  return 0", "end", "", "return D" })
  sh("add", ".")
  sh("commit", "-qm", "initial")

  put("a.lua", { "local A = {}", "", "return A" })
  vim.fn.delete(dir .. "/gone.lua")
  sh("mv", "old_name.lua", "new_name.lua")
  put("new_name.lua", vim.list_extend(vim.deepcopy(keep), { "return O" }))
  put("new.lua", { "local N = {}", "", "function A.one(x)", "  local y = x * 3", "  return y", "end", "",
    "return N" })
  put("dest.lua", { "local D = {}", "", "function D.base()", "  return 0", "end", "",
    "function A.two(s)", "  local t = s:upper()", "  local u = t:reverse()", "  return u", "end", "",
    "function G.three(list)", "  local n = 0", "  for _ in ipairs(list) do n = n + 1 end", "  return n",
    "end", "", "function O.four(t)", "  local k = {}", "  for key in pairs(t) do k[#k + 1] = key end",
    "  return k", "end", "", "return D" })

  vim.cmd("tabnew")
  vim.cmd("tcd " .. vim.fn.fnameescape(dir))
  vim.cmd("edit dest.lua")
  uatis.run({ fargs = { "main" } })
  local list
  wait_for(function()
    list = pane_mod.get()
    return list ~= nil and list.moves_across ~= nil and #list.moves_across == 4
  end, "four moves between files")
  eq(list and vim.tbl_map(function(e)
    return { e.name, e.from.path, e.from.file, e.to.path }
  end, list.moves_across or {}), {
    { "A.two", "a.lua", "a.lua", "dest.lua" },
    { "G.three", "gone.lua", "gone.lua", "dest.lua" },
    { "O.four", "old_name.lua", "new_name.lua", "dest.lua" },
    { "A.one", "a.lua", "a.lua", "new.lua" },
  }, "each paired with its own source: untracked, deleted, renamed and plain alike")

  --- The moves the view on `path` draws, as `{ kind, name, changes }`.
  local function drawn(path)
    local idx
    for i, f in ipairs(list.files) do
      if f.path == path then
        idx = i
      end
    end
    if not idx then
      return "not listed"
    end
    pane_mod.goto_file(list, idx)
    local v
    wait_for(function()
      v = view_mod.get(vim.api.nvim_get_current_buf())
      return v ~= nil and v.relpath == path and v.moves ~= nil
    end, path .. " to draw its moves")
    local out = vim.tbl_map(function(m) return { m.kind, m.name, m.changes } end, v and v.moves or {})
    table.sort(out, function(x, y) return x[2] < y[2] end)
    return out
  end
  eq(drawn("dest.lua"), { { "in", "A.two", 0 }, { "in", "G.three", 0 }, { "in", "O.four", 0 } },
    "three moves into one file, each compared against its own old self")
  eq(drawn("new.lua"), { { "in", "A.one", 1 } }, "into a file git has not been told about")
  eq(drawn("a.lua"), { { "out", "A.one", 1 }, { "out", "A.two", 0 } },
    "two out of one file, each counting what changed on the way")
  eq(drawn("gone.lua"), { { "out", "G.three", 0 } }, "out of a file the branch deleted")
  eq(drawn("new_name.lua"), { { "out", "O.four", 0 } }, "out of a file the branch renamed")

  view_mod.stop(view_mod.get(vim.api.nvim_get_current_buf()))
  vim.cmd("tabclose")
  vim.fn.delete(dir, "rf")
end

print("\n[a stop left in one review is marked in that review, from any tab]")
-- A leave can run a tick after the key that caused it -- `<C-]>`'s does
-- -- by which time another tab, with another review, may be current. Two
-- reviews can list a file of the same name, and the mark belongs to the
-- one whose view was left, never to the one that happens to be in front.
do
  local function repo(after)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local function sh(...)
      vim.system({ "git", "-C", dir, ... }, { text = true }):wait()
    end
    sh("init", "-q", "-b", "main")
    sh("config", "user.email", "t@example.com")
    sh("config", "user.name", "T")
    sh("config", "commit.gpgsign", "false")
    vim.fn.writefile({ "local M = {}", "", "function M.add(a, b)", "  return a + b", "end", "",
      "function M.sub(a, b)", "  return a - b", "end", "", "return M" }, dir .. "/calc.lua")
    sh("add", ".")
    sh("commit", "-qm", "initial")
    vim.fn.writefile(after, dir .. "/calc.lua")
    return dir
  end
  local function review(dir)
    vim.cmd("tabnew")
    vim.cmd("tcd " .. vim.fn.fnameescape(dir))
    vim.cmd("edit calc.lua")
    local buf = vim.api.nvim_get_current_buf()
    uatis.run({ fargs = { "main" } })
    local list
    wait_for(function()
      local v = view_mod.get(buf)
      list = pane_mod.get()
      return list ~= nil and (list.renders or 0) > 0 and v ~= nil and (v.renders or 0) > 0
        and #(v.anchors or {}) > 0
    end, "a review of " .. dir)
    return vim.api.nvim_get_current_tabpage(), list, view_mod.get(buf)
  end

  -- Every line changed in the second, so any row of the first stands on
  -- a chunk of it.
  local x = repo({ "local M = {}", "", "function M.add(a, b)", "  return (a or 0) + b", "end", "",
    "function M.sub(a, b)", "  return a - b", "end", "", "return M" })
  local y = repo({ "local N = {}", "-- one", "-- two", "-- three", "-- four", "-- five", "-- six",
    "-- seven", "-- eight", "-- nine", "return N" })
  local tab_x, list_x, view_x = review(x)
  local tab_y, list_y = review(y)
  eq(vim.api.nvim_get_current_tabpage(), tab_y, "the second review's tab is in front")

  list_x.read, list_x.left, list_y.read, list_y.left = {}, {}, {}, {}
  view_mod.leave_move(view_x, view_x.anchors[1], nil)
  ok(next(list_x.left or {}) ~= nil, "the stop is left in its own review")
  eq({ list_y.read, list_y.left }, { {}, {} }, "and nothing is marked in the review in front")

  for _, tab in ipairs({ tab_y, tab_x }) do
    vim.api.nvim_set_current_tabpage(tab)
    view_mod.stop(view_mod.get(vim.api.nvim_get_current_buf()))
    vim.cmd("tabclose")
  end
  vim.fn.delete(x, "rf")
  vim.fn.delete(y, "rf")
end

print("\n[a rebuilt node keeps the rows it opens with]")
-- A table that gains fields around one it already had is, to
-- difftastic, a node rebuilt: `follow = {` and the field under it come
-- back novel on both sides, and paired with rows they have nothing to
-- do with. `realign` refuses the line diff's pairing there -- two rows
-- out of seven is what a coincidence in a rewrite looks like -- and the
-- two were drawn in red above the same two rows drawn in green. Rows
-- identical at the EDGE of the region, next to rows both sides agree
-- on, are not a coincidence: the rewrite has not started yet.
do
  local diff = require("uatis.diff")
  local overlay = require("uatis.overlay")

  if vim.fn.executable(require("uatis.config").diff.struct.bin) ~= 1 then
    print("  skip the rebuilt-node checks (difftastic not installed)")
  else
    local old = table.concat({
      'require("nemeton").setup({',
      "    comments = {",
      "        follow = {",
      "            commit = uatis.show_commit,",
      "            link = function(_, href)",
      "                vim.fn.setreg('+', href)",
      '                vim.notify("Link content copied", vim.log.levels.INFO)',
      "            end,",
      "        }",
      "    }",
      "})",
    }, "\n") .. "\n"
    local new = table.concat({
      'require("nemeton").setup({',
      "    comments = {",
      "        follow = {",
      "            commit = uatis.show_commit,",
      "            url = copy_link,",
      "            path = copy_link,",
      "        },",
      "        old_side = function(bufnr)",
      "            local at = uatis.showing(bufnr)",
      "            if at and at.side == \"old\" then",
      "                return { path = at.path, sha = at.rev }",
      "            end",
      "        end,",
      "    }",
      "})",
    }, "\n") .. "\n"

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(new, "\n", { plain = true }))
    vim.bo[buf].filetype = "lua"
    local before, marked, done = {}, {}, false
    diff.compute(old, new, { backend = "struct", path = "x.lua", bufnr = buf }, function(r)
      overlay.render(buf, nil, r, vim.split(old, "\n", { plain = true }))
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1, { details = true })) do
        local d = m[4]
        if d.line_hl_group == "UatisAdd" or d.end_col then
          marked[m[2] + 1] = true
        end
        for _, vl in ipairs(d.virt_lines or {}) do
          local text = ""
          for _, c in ipairs(vl) do
            local groups = type(c[2]) == "table" and c[2] or { c[2] }
            if groups[#groups] ~= "UatisSign" then
              text = text .. c[1]
            end
          end
          table.insert(before, (text:gsub("%s+$", "")))
        end
      end
      done = true
    end)
    vim.wait(8000, function() return done end, 20)
    vim.api.nvim_buf_delete(buf, { force = true })

    ok(not contains(before, "follow = {") and not contains(before, "commit = uatis"),
      "the rows the table opens with are not drawn as removed, got " .. vim.inspect(before))
    ok(not marked[3] and not marked[4],
      "nor as arriving, got " .. vim.inspect(vim.tbl_keys(marked)))
    ok(contains(before, "link = function"), "what went is still drawn as gone")
  end
end

print("\n[a word that only lost a letter]")
-- Dropping a character out of a short word shares too little at either
-- end for the affix test that decides whether a replaced word is worth
-- taking apart -- so `and` -> `ad` was marked as one word becoming
-- another: the whole old word in red, drawn in place, and the whole new
-- word in green behind it. Which reads as though `and` had been replaced
-- by `ad`, when every character of `ad` is the old word's own.
--
-- One side having no marks at all is what makes the character diff
-- honest here: there are no fragments of two different words to be
-- misled by when the only marks are characters that genuinely went.
do
  local diff = require("uatis.diff")
  local overlay = require("uatis.overlay")

  local function render(old_line, new_line, backend)
    -- The trailing newline is not decoration: without it the last line
    -- differs from the revision's in a way difftastic reports, and the
    -- band that puts on the file's own last row is not what this is
    -- asking about.
    local old = "local M = {}\n" .. old_line .. "\nreturn M\n"
    local new = "local M = {}\n" .. new_line .. "\nreturn M\n"
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(new, "\n", { plain = true }))
    vim.bo[buf].filetype = "lua"
    local out, done = { marks = {}, went = {}, quiet = {}, stayed = {} }, false
    diff.compute(old, new, { backend = backend, path = "x.lua", bufnr = buf }, function(r)
      overlay.render(buf, nil, r, vim.split(old, "\n", { plain = true }))
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1, { details = true })) do
        local d = m[4]
        for _, vl in ipairs(d.virt_lines or {}) do
          for _, c in ipairs(chunks_of(vl)) do
            -- What the before-image says GOES, as against the context it
            -- is drawn in: the same two-level statement the new side
            -- makes, read from the row above it.
            if c[2] == "UatisDelete" or c[2] == "UatisDeleteBg" then
              table.insert(out.went, c[1])
            elseif c[2] == "UatisDeleteDim" then
              table.insert(out.stayed, (c[1]:gsub("%s+$", "")))
            end
          end
        end
        if d.end_col then
          -- Empty ranges are not marks: they highlight no character.
          local marked = new_line:sub(m[3] + 1, d.end_col)
          if marked ~= "" then
            table.insert(out.marks, marked)
          end
        elseif d.line_hl_group == "UatisAdd" then
          table.insert(out.marks, "the whole line")
        elseif d.line_hl_group == "UatisAddDim" then
          -- Not a mark saying "new": the quiet tint on the line that
          -- replaced the row drawn above it.
          table.insert(out.quiet, "the whole line")
        end
      end
      done = true
    end)
    vim.wait(8000, function() return done end, 20)
    vim.api.nvim_buf_delete(buf, { force = true })
    return out
  end

  local backends = { "line" }
  if vim.fn.executable(require("uatis.config").diff.struct.bin) == 1 then
    table.insert(backends, "struct")
  else
    print("  skip the structural half (difftastic not installed)")
  end

  for _, backend in ipairs(backends) do
    local lost = render("  if enabled and ready then", "  if enabled ad ready then", backend)
    eq(lost.went, { "n" }, backend .. ": the letter that went is picked out of the row above")
    eq(lost.marks, {}, backend .. ": and nothing is marked as new, because nothing is")
    if backend == "struct" then
      -- ...though the row is still tinted quietly, as the answer to the
      -- red row above it. Line mode has its own marks on that row and
      -- needs no such statement.
      eq(lost.quiet, { "the whole line" },
        backend .. ": the line that replaced it is tinted quietly instead")
    end

    -- The same the other way round: a word that only GAINED a letter
    -- marks the letter, not the word it landed in.
    local gained = render("  if enabled and ready then", "  if enabled land ready then", backend)
    eq(gained.marks, { "l" }, backend .. ": a letter added to a short word marks the letter")
    -- Nothing was taken out of the old line, so there is nothing inside
    -- the row above to pick out -- and nothing inside it to draw as
    -- gone either. The block comparison ANSWERED about this row and
    -- answered nothing, which is not the same as having no answer for
    -- it: every character being dimmed is genuinely the line the reader
    -- knows, and what is new is the letter marked on the row below.
    --
    -- Drawn red, the row said the whole line went while the row under
    -- it said one letter arrived -- and the old WINDOW, reading that
    -- same empty answer through `prose_marks`, stepped it back. One
    -- edit cannot read two ways in two layouts.
    eq(gained.went, {}, backend .. ": nothing of the row above is drawn as removed")
    ok(#gained.stayed == 1
      and gained.stayed[1]:find("if enabled and ready then", 1, true) ~= nil,
      backend .. ": it is the line the reader knows, stepped back whole")

    -- ...and the rule the affix test exists for still holds: two words
    -- that merely share letters are marked whole, because character
    -- marks between them would land on whichever letters they happen to
    -- have in common and point at nothing.
    local other = render("  local closer = 1", "  local whose = 1", backend)
    eq(other.marks, { "whose" }, backend .. ": an unrelated word is still marked whole")
    eq(other.went, { "closer" }, backend .. ": with the word it replaced, whole, above it")

    -- ...and the same rule one level down. A shared suffix long enough to
    -- anchor on says the character diff is worth drawing; it says nothing
    -- about the part in FRONT of the stem, which here is one word for
    -- another. Taken apart character by character it came out as `a` and
    -- `sed` marked inside `parsed`, with the `p` and the `r` between them
    -- left bare as though they were the old word's -- two fragments where
    -- the edit is the whole of `report` becoming the whole of `parsed`.
    local stem = render("  local report_flags = 1", "  local parsed_flags = 1", backend)
    eq(stem.marks, { "parsed" }, backend .. ": a word replaced in front of a shared stem is one mark")
    eq(stem.went, { "report" }, backend .. ": and the word it replaced is one too")
  end
end

print("\n[the blank line inside an added block]")
-- A blank line has no atoms, so a token-precise backend reports nothing
-- for it -- and a row the backend did not mention is code that only
-- moved, which is the rule that keeps reindented bodies unpainted.
-- Between two rows that ARE new it is the wrong rule: an added function
-- with a blank line in the middle came out as two green blocks with a
-- gap through it, where line mode has always drawn one.
do
  local diff = require("uatis.diff")
  local overlay = require("uatis.overlay")

  --- Which rows carry a full-line band, and which carry token marks.
  local function bands(old, new, backend)
    local lines = vim.split(new, "\n", { plain = true })
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = "lua"
    local out, done = { band = {}, token = {} }, false
    diff.compute(old, new, { backend = backend, path = "x.lua", bufnr = buf }, function(r)
      overlay.render(buf, nil, r, vim.split(old, "\n", { plain = true }))
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1, { details = true })) do
        local d = m[4]
        if d.line_hl_group then
          table.insert(out.band, m[2])
        elseif d.end_col then
          table.insert(out.token, m[2])
        end
      end
      done = true
    end)
    vim.wait(8000, function() return done end, 20)
    vim.api.nvim_buf_delete(buf, { force = true })
    table.sort(out.band)
    return out
  end

  local function has(list, row)
    return contains(vim.tbl_map(tostring, list), tostring(row))
  end

  local backends = { "line" }
  if vim.fn.executable(require("uatis.config").diff.struct.bin) == 1 then
    table.insert(backends, "struct")
  else
    print("  skip the structural half (difftastic not installed)")
  end

  -- A whole function added, with a blank line inside it.
  local old = "local M = {}\n\nfunction M.one()\n  return 1\nend\n\nreturn M\n"
  local new = "local M = {}\n\nfunction M.one()\n  return 1\nend\n\n"
    .. "function M.two()\n  local a = 1\n\n  return a\nend\n\nreturn M\n"

  for _, backend in ipairs(backends) do
    local added = bands(old, new, backend)
    ok(has(added.band, 6) and has(added.band, 7),
      backend .. ": the added lines are painted whole")
    ok(has(added.band, 8),
      backend .. ": and so is the blank line between them, which was added with them")
    ok(has(added.band, 9) and has(added.band, 10),
      backend .. ": through to the end of the block")
    ok(not has(added.band, 4) and not has(added.band, 5),
      backend .. ": while the function above it, and the blank over it, are left alone")
  end

  if #backends > 1 then
    -- A blank line between two lines that were merely EDITED was always
    -- there, and painting it would claim it is new.
    local eold = "local M = {}\n\nfunction M.one()\n  local a = 1\n\n  return a\nend\n"
    local enew = "local M = {}\n\nfunction M.one()\n  local a = 2\n\n  return a * 2\nend\n"
    local edited = bands(eold, enew, "struct")
    ok(not has(edited.band, 4), "a blank between two edited lines is not painted")
    ok(#edited.token > 0, "though the edits themselves are marked")

    -- ...and the rule it is an exception to still holds: a body wrapped
    -- in an `if` only moved, blank line and all.
    local wold = "local M = {}\nfunction M.run(a)\n  local t = a * 2\n\n  return t\nend\n"
    local wnew = "local M = {}\nfunction M.run(a)\n  if a then\n    local t = a * 2\n\n"
      .. "    return t\n  end\nend\n"
    local wrapped = bands(wold, wnew, "struct")
    ok(has(wrapped.band, 2), "the genuinely new `if a then` is painted")
    ok(not has(wrapped.band, 4),
      "and the blank line inside the body it wrapped is not: that code only moved")
  end
end

print("\n[one digit of a number is not the whole number]")
-- difftastic reports ATOMS, and a number is one atom however many
-- digits changed inside it: `50_000` -> `20_000` came back as the whole
-- `20_000` added, with the removed `5` drawn in red inside it. Five of
-- those six characters were already there, and the row read as though
-- `5` had been replaced by `20_000`.
do
  local diff = require("uatis.diff")
  local overlay = require("uatis.overlay")

  local function render(old_line, new_line, backend)
    local old = "def f():\n" .. old_line .. "\n    return 1\n"
    local new = "def f():\n" .. new_line .. "\n    return 1\n"
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(new, "\n", { plain = true }))
    vim.bo[buf].filetype = "python"
    local out, done = { marks = {}, went = {}, dim = {} }, false
    diff.compute(old, new, { backend = backend, path = "x.py", bufnr = buf }, function(r)
      overlay.render(buf, nil, r, vim.split(old, "\n", { plain = true }))
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1, { details = true })) do
        local d = m[4]
        for _, vl in ipairs(d.virt_lines or {}) do
          for _, c in ipairs(chunks_of(vl)) do
            -- What the before-image says GOES, as against the context it
            -- is drawn in: the same two-level statement the new side
            -- makes, read from the row above it.
            if c[2] == "UatisDelete" or c[2] == "UatisDeleteBg" then
              table.insert(out.went, c[1])
            end
          end
        end
        if d.end_col then
          local marked = new_line:sub(m[3] + 1, d.end_col)
          if marked ~= "" then
            table.insert(d.hl_group == "UatisAddDim" and out.dim or out.marks, marked)
          end
        elseif d.line_hl_group then
          table.insert(out.marks, "the whole line")
        end
      end
      done = true
    end)
    vim.wait(8000, function() return done end, 20)
    vim.api.nvim_buf_delete(buf, { force = true })
    return out
  end

  local backends = { "line" }
  if vim.fn.executable(require("uatis.config").diff.struct.bin) == 1 then
    table.insert(backends, "struct")
  else
    print("  skip the structural half (difftastic not installed)")
  end

  for _, backend in ipairs(backends) do
    local digit = render("    limit = 50_000", "    limit = 20_000", backend)
    eq(digit.marks, { "2" }, backend .. ": the digit that is new is the only thing green")
    eq(digit.went, { "5" }, backend .. ": with the one it replaced picked out above it")

    -- The rule is about characters that were already there, so a number
    -- that really was replaced is still marked whole.
    local other = render("    limit = 50_000", "    limit = 71", backend)
    eq(other.marks, { "71" }, backend .. ": an unrelated number is marked whole")
    eq(other.went, { "50_000" }, backend .. ": with the one it replaced above it")
  end

  -- ...and a string keeps the prose treatment it is meant to have: the
  -- whole atom tinted, with what did not change stepped back rather than
  -- narrowed away.
  if #backends > 1 then
    local text = render("    name = 'alpha'", "    name = 'alpha2'", "struct")
    ok(contains(text.marks, "'alpha2'"),
      "a changed string is still tinted whole, got " .. table.concat(text.marks, ", "))
    ok(#text.dim > 0, "with the part that did not change stepped back instead")
  end
end

print("\n[a changed line the backend reports nothing added on]")
-- Hoisting `"|".join(col.types)` into a variable leaves difftastic with
-- nothing to mark on the new side: the `types` that survived matches the
-- one inside `col.types`, so it calls the right-hand row unchanged and
-- reports the whole edit as removals from the left.
--
-- Nothing is invented to put on that row. The old line goes above the
-- row difftastic paired it with, which is where every removal goes, and
-- the reader compares the two rows -- not a mark the backend never
-- made.
do
  local overlay = require("uatis.overlay")

  local old_lines = {
    "def render(cols):",                                    -- 1
    "    for col in cols:",                                 -- 2
    '        rows.append((col.name, "|".join(col.types)))', -- 3
    "    return rows",                                      -- 4
  }
  local new_lines = {
    "def render(cols):",                        -- 1
    "    for col in cols:",                     -- 2
    '        types = "|".join(col.types)',      -- 3
    "        rows.append((col.name, types))",   -- 4
    "    return rows",                          -- 5
  }

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
  vim.bo[buf].filetype = "python"
  overlay.render(buf, nil, {
    -- One old row replaced by two, and difftastic paired it with the
    -- SECOND of them -- which is the shape the counts alone cannot give.
    hunks = { { start_a = 3, count_a = 1, start_b = 3, count_b = 2 } },
    -- Both sides as difftastic really reports them for this pair: the
    -- hoisted line added whole, and the tokens it took out of the line
    -- below reported against the OLD row -- with nothing at all against
    -- the new row they came out of.
    spans = {
      { line = 3, col_start = 8, col_end = #new_lines[3], kind = "add" },
      { line = 3, col_start = 31, col_end = 44, kind = "delete" },
      { line = 3, col_start = 49, col_end = 50, kind = "delete" },
    },
    dropped = 0,
    pairs = { [4] = 3 },
    anchor = { [3] = 4 },
    engine = "difftastic",
    precise = true,
  }, old_lines)

  local inline, band, before = {}, {}, {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1, { details = true })) do
    local row, d = m[2] + 1, m[4]
    if d.virt_text_pos == "inline" then
      for _, c in ipairs(d.virt_text or {}) do
        table.insert(inline, { row = row, col = m[3], text = c[1], hl = c[2] })
      end
    end
    if d.line_hl_group or d.hl_eol then
      band[row] = d.line_hl_group or d.hl_group
    end
    for _, _vl in ipairs(d.virt_lines or {}) do
      table.insert(before, row)
    end
  end
  vim.api.nvim_buf_delete(buf, { force = true })

  eq(inline, {}, "nothing is drawn inside the line that replaced it")
  eq(before, { 4 }, "the old line is a row of its own, above the row it was paired with")
  -- ...and the row under it is tinted quietly. Nothing on it is new --
  -- the backend reported no additions there, and green would say
  -- otherwise -- but a red row above a line with no mark at all reads as
  -- a deletion, with the line below merely the next line of the file.
  -- The quiet tint says the one thing that is true of it: this is what
  -- the row above became.
  eq(band[4], "UatisAddDim", "and the row under it is tinted quietly, as its answer")
  ok(band[3] == "UatisAdd", "while the line that really is new keeps the full tint")
end

print("\n[code has only moved if you can see it]")
-- Structural mode does not draw a before-image for code that merely
-- moved: a full red copy of a line still on screen below reads as a much
-- bigger change than happened. But "still on screen" has to mean the
-- reader can SEE it unchanged. Moving a test into a class makes
-- difftastic report the old body as removed and the reindented copy as
-- added a few rows down -- so the copy is painted green, and counting it
-- as survival left the old body drawn nowhere at all while its
-- replacement claimed to be new.
do
  local overlay = require("uatis.overlay")

  local old_lines = {
    "import pytest",                    -- 1
    "",                                 -- 2
    "def test_area():",                 -- 3
    "    widget = Widget()",            -- 4
    "    assert widget.area() == 6.0",  -- 5
    "",                                 -- 6
    "def test_normalise():",            -- 7
    "    assert normalise(1.0) == 1.0", -- 8
  }
  local new_lines = {
    "import pytest",                        -- 1
    "",                                     -- 2
    "class TestWidget:",                    -- 3
    "    def test_area(self):",             -- 4
    "        widget = Widget()",            -- 5
    "        assert widget.area() == 6.0",  -- 6
  }

  --- Spans covering every token of `rows`, which is what difftastic
  --- reports for a line it considers wholly new.
  local function cover(rows)
    local spans = {}
    for _, row in ipairs(rows) do
      table.insert(spans, {
        line = row, col_start = 0, col_end = #(new_lines[row] or ""), kind = "add",
      })
    end
    return spans
  end

  local function before_at(hunks, spans)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
    vim.bo[buf].filetype = "python"
    overlay.render(buf, nil, {
      hunks = hunks, spans = vim.list_extend(vim.deepcopy(spans), removed(hunks, old_lines)),
      dropped = 0, engine = "difftastic", precise = true,
    }, old_lines)
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1, { details = true })) do
      for _, vl in ipairs(m[4].virt_lines or {}) do
        local text = ""
        for _, c in ipairs(vl) do
          text = text .. c[1]
        end
        table.insert(out, text)
      end
    end
    vim.api.nvim_buf_delete(buf, { force = true })
    return out
  end

  -- difftastic's own pairing on this shape: the old body against the
  -- class line, and the old test it deleted against the moved body.
  local moved = before_at({
    { start_a = 3, count_a = 3, start_b = 3, count_b = 1 },
    { start_a = 7, count_a = 2, start_b = 4, count_b = 3 },
  }, cover({ 3, 4, 5, 6 }))
  ok(contains(moved, "def test_area():"),
    "the old body is drawn, because the rows it moved into are painted as added")
  ok(contains(moved, "def test_normalise():"),
    "and so is the test that really was deleted")

  -- The same old block, but nothing claims the rows below: they read as
  -- unchanged code, which is what moving into looks like, so the copy
  -- above would only restate what is already on screen.
  local quiet = before_at({
    { start_a = 3, count_a = 3, start_b = 3, count_b = 1 },
  }, cover({ 3 }))
  ok(not contains(quiet, "def test_area():"),
    "with the rows below left alone, the same block reads as moved, not removed")
end

print("\n[a line is not excused by the lines that look like it]")
-- "Still on screen" asks whether the old content is still there, and asked
-- of CHARACTERS it says yes to near-misses: `importos` is a character
-- subsequence of `import json` + `import sys` twice over, and a helptags
-- line is one of the longer tag one row below it. Both were read as moves,
-- so both removals were drawn nowhere at all -- while the side-by-side
-- window beside them went on showing the line. Asked of TOKENS, a word
-- that grew is a different word.
do
  local diff = require("uatis.diff")
  local overlay = require("uatis.overlay")

  ok(not diff.content_survives({ "import os" }, { "import json", "import sys" }),
    "a short line scattered across its neighbours has not survived")
  ok(not diff.content_survives(
      { ":DbConnect\tgrannos.txt\t/*:DbConnect*" },
      { ":DbCancelQuery\tgrannos.txt\t/*:DbCancelQuery*",
        ":DbConnections\tgrannos.txt\t/*:DbConnections*" }),
    "nor has one whose name is a prefix of the tag below it")
  ok(diff.content_survives({ "def test_area():" }, { "    def test_area(self):" }),
    "while a line that gained a token, and kept the rest, has")
  ok(diff.content_survives({ "    x = compute(a)" }, { "        x = compute(a)" }),
    "the same line one indent further in has")
  ok(diff.content_survives(
      { "region = self.client.get_bucket_location(Bucket=b)" },
      { "region = (", "    self.client.get_bucket_location(Bucket=b)", ")" }),
    "and so has a line wrapped in brackets, which inserts around and inside it")

  local old_lines = { "import json", "import os", "import sys", "", "", "def run(a):", "    return a" }
  local new_lines = { "import json", "import sys", "", "", "def run(a):", "    return a" }
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
  vim.bo[buf].filetype = "python"
  -- The shape difftastic reports for it: one line gone, nothing in its
  -- place, and precise spans -- which is where a before-image is drawn
  -- only for what genuinely went away.
  local hunks = { { start_a = 2, count_a = 1, start_b = 2, count_b = 0 } }
  overlay.render(buf, nil, {
    hunks = hunks, spans = removed(hunks, old_lines),
    dropped = 0, engine = "difftastic", precise = true,
  }, old_lines)
  local drawn = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1, { details = true })) do
    for _, vl in ipairs(m[4].virt_lines or {}) do
      local text = ""
      for _, c in ipairs(vl) do
        text = text .. c[1]
      end
      table.insert(drawn, vim.trim(text))
    end
  end
  vim.api.nvim_buf_delete(buf, { force = true })
  ok(contains(drawn, "import os"),
    "so the line is drawn where it was, got " .. vim.inspect(drawn))
end

print("\n[before-images stay in old-file order]")
-- Two deletions with nothing between them on the new side anchor on the
-- same row. Drawn as one extmark each, the order Neovim stacks them in is
-- not the order they were created -- a row that also carries a
-- virt_lines_above mark renders its below marks in reverse -- so the two
-- removed blocks appeared swapped, which reads as code having moved.
-- A structural backend produces this shape routinely: it splits a
-- contiguous removed region into one hunk per top-level form.
do
  local overlay = require("uatis.overlay")

  local old_lines = {
    "def total(xs):",              -- 1
    "    return sum(xs)",          -- 2
    "",                            -- 3
    "def first_removed():",        -- 4
    "    return 1",                -- 5
    "",                            -- 6
    "def second_removed():",       -- 7
    "    return 2",                -- 8
  }
  -- The replacement is a rewrite rather than a small edit, so it keeps a
  -- row of its own: a one-word swap is drawn inside the new line, and
  -- this test is about the order of the rows.
  local new_lines = { "def total(xs):", "    raise ValueError(message)" }

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
  -- Hand-built rather than computed, so the test states the hunk shape it
  -- is about instead of depending on a backend to keep producing it.
  local hunks = {
    { start_a = 2, count_a = 1, start_b = 2, count_b = 1 },
    { start_a = 4, count_a = 2, start_b = 2, count_b = 0 },
    { start_a = 7, count_a = 2, start_b = 2, count_b = 0 },
  }
  overlay.render(buf, nil, {
    hunks = hunks,
    spans = removed(hunks, old_lines),
    dropped = 0,
    engine = "difftastic",
    precise = true,
  }, old_lines)

  -- One string per before-image row, in the order the rows are DRAWN. A
  -- row is several chunks when part of it is dimmed context, so they are
  -- joined back into the line they represent.
  --
  -- Sorted rather than read off the API, which promises no order for two
  -- marks at the same position and does not give a stable one: a third
  -- mark on that row is enough to swap them. What the screen shows is
  -- the row with its `virt_lines_above` marks before it and its others
  -- after, and marks at the same row and side keep the order their own
  -- chunks were built in.
  local anchors = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1, { details = true })) do
    if m[4].virt_lines then
      table.insert(anchors,
        { row = m[2], above = m[4].virt_lines_above == true, virt = m[4].virt_lines })
    end
  end
  table.sort(anchors, function(a, b)
    if a.row ~= b.row then
      return a.row < b.row
    end
    return a.above and not b.above
  end)

  local texts = {}
  for _, anchor in ipairs(anchors) do
    for _, vl in ipairs(anchor.virt) do
      local parts = {}
      for _, c in ipairs(chunks_of(vl)) do
        if c[2] ~= "UatisSign" then
          table.insert(parts, c[1])
        end
      end
      table.insert(texts, table.concat(parts))
    end
  end
  vim.api.nvim_buf_delete(buf, { force = true })

  local function index_of(needle)
    for i, t in ipairs(texts) do
      if t == needle then
        return i
      end
    end
  end
  local replaced = index_of("    return sum(xs)")
  local first = index_of("def first_removed():")
  local second = index_of("def second_removed():")
  ok(replaced and first and second, "all three removed blocks are drawn")
  ok(replaced and first and replaced < first,
    "the replaced line comes before the blocks deleted after it")
  ok(first and second and first < second,
    "and the two deleted blocks keep the order they had in the old file")
end

print("\n[a before-image goes above the line it became]")
-- difftastic pairs the two files by walking their token streams, and a
-- line INSERTED above a changed one takes the changed line's partner: an
-- `assert` added above a `return` whose subscript became an attribute
-- came back as the old return line's opposite number, with the return
-- that actually replaced it reported as an addition answering to nothing.
-- Drawn on that pairing the before-image sits above a line it has nothing
-- to do with, one row above the line it really became -- so the two rows
-- the reader is asked to compare were never the same code.
--
-- The alignment is still difftastic's answer about WHAT changed. This is
-- only about which row the removed line is drawn above, which is the one
-- thing that answer is used for here.
do
  local overlay = require("uatis.overlay")

  local old_lines = {
    "async def connected(dispatcher, mock_driver):",              -- 1
    "    result = await dispatcher.dispatch(Method.CONNECT)",     -- 2
    '    return dispatcher, result["connection_id"], mock_driver', -- 3
  }
  local new_lines = {
    "async def connected(dispatcher, mock_driver):",              -- 1
    "    result = await dispatcher.dispatch(Method.CONNECT)",     -- 2
    "    assert isinstance(result, ConnectResult)",               -- 3
    "    return dispatcher, result.connection_id, mock_driver",   -- 4
  }

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
  -- Hand-built, and the pairing is the point: old row 3 aligned with the
  -- line that was inserted above it, which is what difftastic reported
  -- for this shape.
  local hunks = { { start_a = 3, count_a = 1, start_b = 3, count_b = 2 } }
  overlay.render(buf, nil, {
    hunks = hunks,
    spans = removed(hunks, old_lines),
    anchor = { 1, 2, 3 },
    pairs = { 1, 2, 3 },
    dropped = 0,
    engine = "difftastic",
    precise = true,
  }, old_lines)

  local at, went, kept = nil, {}, {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1, { details = true })) do
    if m[4].virt_lines then
      at = { row = m[2], above = m[4].virt_lines_above == true }
      for _, vl in ipairs(m[4].virt_lines) do
        for _, c in ipairs(chunks_of(vl)) do
          if c[2] == "UatisDelete" or c[2] == "UatisDeleteBg" then
            table.insert(went, c[1])
          elseif c[2] == "UatisDeleteDim" then
            table.insert(kept, c[1])
          end
        end
      end
    end
  end
  vim.api.nvim_buf_delete(buf, { force = true })

  ok(at ~= nil, "the removed line is drawn")
  ok(at and at.above, "above a row rather than below one")
  -- Zero-based, so row 3 is the `return` on line 4: the line the old one
  -- became, not the `assert` that arrived above it.
  eq(at and at.row, 3, "and above the line it resembles, not the one it was paired with")

  -- ...and it says WHICH part went. The backend's report about this row
  -- is a comparison against the line above -- everything changed, every
  -- time -- so re-pairing the row without re-measuring it draws a solid
  -- red copy of a line the reader can see is still there one row below.
  eq(went, { '["', '"]' },
    "the emphasis is on the characters that actually went")
  ok(contains(kept, "connection_id"),
    "and the rest of the line is drawn as the context it is, got "
      .. vim.inspect(kept))
end

-- ...but a line broken over several is anchored on the piece it kept, and
-- that piece -- `fake_url(` -- is too short to resemble the line it came
-- from. Re-paired with the argument row, which does resemble it, the
-- before-image was measured against that row and called `fake_url(` lost.
do
  local overlay = require("uatis.overlay")

  local old_lines = {
    "res = await resolve(",
    "    fake_url(protocol=redir.source_protocol, target=fake_target(redis.source))",
    ")",
  }
  local new_lines = {
    "res = await resolve(",
    "    fake_url(",
    "        protocol=redir.source_protocol, target=fake_target(redis.source_hostname)",
    "    )",
    ")",
  }
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
  -- What difftastic reports for this shape: `source` went, `source_hostname`
  -- arrived, and nothing at all on the `fake_url(` row it kept.
  overlay.render(buf, nil, {
    hunks = { { start_a = 2, count_a = 1, start_b = 2, count_b = 2 } },
    spans = {
      { line = 2, col_start = 70, col_end = 76, kind = "delete" },
      { line = 3, col_start = 65, col_end = 80, kind = "add" },
    },
    anchor = { 1, 2, 5 },
    pairs = { 1, 2, [5] = 3 },
    dropped = 0,
    engine = "difftastic",
    precise = true,
  }, old_lines)

  local at, went = nil, {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1, { details = true })) do
    if m[4].virt_lines then
      at = m[2]
      for _, vl in ipairs(m[4].virt_lines) do
        for _, c in ipairs(chunks_of(vl)) do
          if c[2] == "UatisDelete" or c[2] == "UatisDeleteBg" then
            table.insert(went, c[1])
          end
        end
      end
    end
  end
  vim.api.nvim_buf_delete(buf, { force = true })

  eq(at, 1, "a split line's before-image goes above the piece it kept")
  eq(went, { "source" }, "and only what was taken out of it is red")
end

-- A last parameter dropped with the comma before it. All `port,` lost is
-- the comma, and the row it became is directly below it -- the one case a
-- lone punctuation mark IS worth pointing at, where the reflow rule
-- (`names`) would draw the whole parameter as gone.
do
  local diff = require("uatis.diff")
  local overlay = require("uatis.overlay")

  if vim.fn.executable(require("uatis.config").diff.struct.bin) ~= 1 then
    print("  skip the dropped-comma check (difftastic not installed)")
  else
    local function went(old, new)
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(new, "\n", { plain = true }))
      vim.bo[buf].filetype = "python"
      local rows, done = {}, false
      diff.compute(old, new, { backend = "struct", path = "x.py", bufnr = buf }, function(r)
        overlay.render(buf, nil, r, vim.split(old, "\n", { plain = true }))
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1, { details = true })) do
          for _, vl in ipairs(m[4].virt_lines or {}) do
            local red = {}
            for _, c in ipairs(chunks_of(vl)) do
              if c[2] == "UatisDelete" or c[2] == "UatisDeleteBg" then
                table.insert(red, vim.trim(c[1]))
              end
            end
            table.insert(rows, table.concat(red))
          end
        end
        done = true
      end)
      vim.wait(8000, function() return done end, 20)
      vim.api.nvim_buf_delete(buf, { force = true })
      return rows
    end
    eq(went("def connect(\n    host,\n    port,\n    timeout\n):\n    pass\n",
      "def connect(\n    host,\n    port\n):\n    pass\n"), { ",", "timeout" },
      "a dropped trailing comma is red on its own, the parameter it ended is not")
    -- ...and where the closing bracket moved up off the removed row, so
    -- that `port,` became `port):` and no row is the other minus a comma.
    eq(went("def connect(\n    host,\n    port,\n    timeout):\n    pass\n",
      "def connect(\n    host,\n    port):\n    pass\n")[1], ",",
      "nor when the closing bracket moved up onto it")
    -- ...nor when a formatter joined what was left onto one line, which
    -- leaves the hunk with no new rows at all: what survived of
    -- `fields_columns,` is on the row the parameters were folded into.
    eq(went("def f(\n    df: pd.DataFrame,\n    fields_columns: Cols,\n    config_adv: Adv,\n) -> M:\n    pass\n",
      "def f(\n    df: pd.DataFrame, fields_columns: Cols\n) -> M:\n    pass\n"),
      { "", ",", "config_adv: Adv," },
      "nor when the parameters left were joined onto one line")
  end
end

print("\n[nothing removed means the old half is all there]")
-- The step-back claims the dimmed part is the line the reader already
-- knows. `emphasis_ratio` guards that claim by measuring how much of
-- the NEW atom is new -- which is the wrong side of the comparison, and
-- it gets short strings wrong: `"diagram"` becoming `"structural
-- diagram"` is eleven of twenty characters new, so the ratio called it
-- a rewrite and lit `diagram`, a word that plainly did not change,
-- while the whole old atom sat there in one piece.
--
-- Where NOTHING was removed from a row that HAS an old half, the claim
-- cannot be false: every character about to be dimmed is genuinely the
-- old atom, and there is no coincidental remainder to be misled by --
-- nothing went missing for the matcher to find debris in place of.
do
  local diff = require("uatis.diff")
  local overlay = require("uatis.overlay")

  if vim.fn.executable(require("uatis.config").diff.struct.bin) ~= 1 then
    print("  skip the pure-insertion checks (difftastic not installed)")
  else
    local function drawn(one, two)
      local old = "X = 1\n" .. one .. "\nY = 2\n"
      local new = "X = 1\n" .. two .. "\nY = 2\n"
      local lines = vim.split(new, "\n", { plain = true })
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].filetype = "python"
      local out, done = { lit = {}, dim = {} }, false
      diff.compute(old, new, { backend = "struct", path = "x.py", bufnr = buf },
        function(r)
          overlay.render(buf, nil, r, vim.split(old, "\n", { plain = true }))
          for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1,
            { details = true })) do
            local d = m[4]
            if d.hl_group and d.end_col and m[2] + 1 == 2 then
              local text = lines[2]:sub(m[3] + 1, d.end_col)
              table.insert(d.hl_group == "UatisAddDim" and out.dim or out.lit, text)
            end
          end
          done = true
        end)
      vim.wait(8000, function() return done end, 20)
      vim.api.nvim_buf_delete(buf, { force = true })
      return out
    end

    local short = drawn('HEADER = "diagram"', 'HEADER = "structural diagram"')
    ok(contains(short.dim, 'diagram"'),
      "a word the string kept steps back however short the string is, got "
        .. vim.inspect(short))

    -- ...and the ratio still governs where something DID go, which is
    -- the case it was written for: a paragraph rewritten leaves
    -- fragments matched by coincidence, and dimming those sends the
    -- reader looking for a line they do not answer to.
    local rewritten = drawn('H = "pip install grannos-py"',
      'H = "grannos is a server, so install it as a tool"')
    eq(rewritten.dim, {},
      "a string mostly rewritten is still tinted whole, got " .. vim.inspect(rewritten))
  end
end

print("\n[several lines becoming one is a replacement, not a rewording]")
-- The step-back compares a row with the row it USED to be. A hunk that
-- folds several old rows into fewer new ones has no such pairing to
-- offer: the new row is not a version of any one of them, it is what
-- replaced all of them -- and the emphasis there is computed over the
-- whole block, so the pale text can be lifted out of a line that is not
-- the one being drawn.
--
-- Six `parts.append("title: " + plan.title)` lines becoming one f-string
-- came back with `plan.title` and `plan.author` stepped back inside it,
-- taken from two different old rows and neither of them the row this one
-- answers to. The structure changed completely; the whole line is new.
do
  local diff = require("uatis.diff")
  local overlay = require("uatis.overlay")

  if vim.fn.executable(require("uatis.config").diff.struct.bin) ~= 1 then
    print("  skip the collapse checks (difftastic not installed)")
  else
    local old = table.concat({
      "def describe(plan):",
      "    parts = []",
      '    parts.append("title: " + plan.title)',
      '    parts.append("author: " + plan.author)',
      '    parts.append("scale: " + str(plan.scale))',
      '    return "\\n".join(parts)',
    }, "\n") .. "\n"
    local new = table.concat({
      "def describe(plan):",
      '    return f"{plan.title} by {plan.author}"',
    }, "\n") .. "\n"

    local lines = vim.split(new, "\n", { plain = true })
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = "python"
    local lit, dim, above, done = {}, {}, 0, false
    diff.compute(old, new, { backend = "struct", path = "x.py", bufnr = buf },
      function(r)
        overlay.render(buf, nil, r, vim.split(old, "\n", { plain = true }))
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1,
          { details = true })) do
          local d = m[4]
          above = above + #(d.virt_lines or {})
          if d.hl_group and d.end_col and m[2] + 1 == 2 then
            local text = lines[2]:sub(m[3] + 1, d.end_col)
            table.insert(d.hl_group == "UatisAddDim" and dim or lit, text)
          end
        end
        done = true
      end)
    vim.wait(8000, function() return done end, 20)
    vim.api.nvim_buf_delete(buf, { force = true })

    eq(dim, {}, "nothing on the replacement steps back, got " .. vim.inspect(dim))
    ok(#lit > 0, "the line is drawn as what it is -- new, got " .. vim.inspect(lit))
    -- ...and the block it replaced is above it, which is where the
    -- reader compares, rather than inside the new line in pale grey.
    ok(above >= 5, "with the block it replaced drawn above it, got " .. above)
  end
end

print("\n[one edit does not read two ways in two layouts]")
-- The old side of a reworded sentence steps back with the word that
-- went left at full strength. The side-by-side window did that; the
-- INLINE before-image did not -- there the backend\'s own spans cover
-- the whole atom, `rewritten` throws them out, and it fell through to
-- drawing the sentence solid red. Two windows describing one edit two
-- different ways, and the reader has no way to tell which is the lie.
--
-- Both now read the same table, `del_fine` -- the comparison the
-- emphasis itself came from -- and it is consulted LAST, because it is
-- the coarsest of the four sources: difftastic reports the old side
-- token by token and knows `self.measure(box)` survived a line whose
-- `total +=` went, where this says the row went entire.
do
  local diff = require("uatis.diff")
  local overlay = require("uatis.overlay")
  local oldside = require("uatis.oldside")

  if vim.fn.executable(require("uatis.config").diff.struct.bin) ~= 1 then
    print("  skip the two-layout checks (difftastic not installed)")
  else
    local old = table.concat({
      "def f(t):",
      [[    """Drop a modifier.]],
      "",
      "    It widens every box that carries a modifier.",
      [[    """]],
      "    return t",
    }, "\n") .. "\n"
    local new = old:gsub("carries a modifier%.", "carries two modifiers.")
    local old_lines = vim.split(old, "\n", { plain = true })

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(new, "\n", { plain = true }))
    vim.bo[buf].filetype = "python"
    local oldbuf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(oldbuf, 0, -1, false, old_lines)

    local inline, side, done = {}, {}, false
    diff.compute(old, new, { backend = "struct", path = "x.py", bufnr = buf },
      function(r)
        -- Inline: the before-image, chunk by chunk.
        overlay.render(buf, nil, r, old_lines)
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1,
          { details = true })) do
          for _, vl in ipairs(m[4].virt_lines or {}) do
            for _, c in ipairs(vl) do
              local gs = type(c[2]) == "table" and c[2] or { c[2] }
              if gs[#gs] ~= "UatisSign" then
                table.insert(inline, { text = c[1], band = gs[#gs] })
              end
            end
          end
        end

        -- ...and the same edit in the other window.
        local _, del_fine = overlay.render(buf, nil, r, old_lines, { before = false })
        local dels = {}
        for _, sp in ipairs(r.spans or {}) do
          if sp.kind == "delete" then
            dels[sp.line] = dels[sp.line] or {}
            table.insert(dels[sp.line], sp)
          end
        end
        oldside.refresh({
          bufnr = buf, ref = "main", relpath = "x.py", layout = "inline",
          old_text = old, old = { buf = oldbuf }, renders = 1, hunks = r.hunks,
          del_spans = r.precise and dels or nil, del_fine = del_fine,
          prose = r.prose,
        })
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(oldbuf, oldside.ns, 0, -1,
          { details = true })) do
          if m[2] + 1 == 4 then
            local d = m[4]
            table.insert(side, {
              band = d.line_hl_group or d.hl_group,
              from = m[3], to = d.end_col, eol = d.hl_eol == true,
            })
          end
        end
        done = true
      end)
    vim.wait(8000, function() return done end, 20)
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.api.nvim_buf_delete(oldbuf, { force = true })

    -- Inline: the word that went at full strength, the sentence around
    -- it stepped back.
    local went, kept = {}, {}
    for _, c in ipairs(inline) do
      table.insert(c.band == "UatisDeleteDim" and kept or went, c.text)
    end
    eq(went, { "a" }, "the inline before-image reds only the word that went, got "
      .. vim.inspect(inline))
    ok(#kept > 0 and table.concat(kept, ""):find("It widens every box", 1, true) ~= nil,
      "with the sentence around it stepped back, got " .. vim.inspect(kept))

    -- Side by side: the same statement, in that window\'s colours.
    local banded, picked = nil, {}
    for _, m in ipairs(side) do
      if m.eol or m.band == "UatisDeleteBandDim" and m.to == 0 then
        banded = m.band
      elseif m.band == "UatisDeleteBand" then
        table.insert(picked, old_lines[4]:sub(m.from + 1, m.to))
      end
    end
    eq(banded, "UatisDeleteBandDim", "the other window steps the row back too")
    eq(picked, { "a" }, "and picks out the same word, got " .. vim.inspect(picked))
  end
end

print("\n[a file of bytes says what it weighs]")
-- Both backends will answer about a PNG. difftastic falls back to
-- comparing words where it has no parser, and `vim.diff` will happily
-- split one on whatever newline bytes it contains. Both answers are true
-- of the bytes and useless: marks over noise, a before-image of noise
-- above them, counts that mean nothing. What can honestly be said is
-- what the file weighs.
do
  local ui = require("uatis.ui")

  eq(ui.size(0), "0 B", "a size reads as a person reads one")
  eq(ui.size(900), "900 B", "bytes up to a kilobyte")
  eq(ui.size(1231), "1.2 KB", "and one decimal past it")
  eq(ui.size(nil), "nothing", "a file that did not exist weighed nothing")

  local dir = fixture .. "/binblob"
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/logo.png"
  -- A NUL near the front is how git decides this too, and it is asked of
  -- the CONTENT: the question is whether the file can be read as lines,
  -- and an extension does not answer it.
  local bytes = "\137PNG\r\n\26\n" .. string.rep("\0\1\2\3", 40)
  -- `writefile` refuses a string with a NUL in it -- it becomes a Blob
  -- on the way through Vimscript. Written from Lua, which does not care.
  local fd = io.open(path, "wb")
  fd:write(bytes)
  fd:close()
  vim.fn.system({ "git", "-C", fixture, "add", "binblob/logo.png" })
  vim.fn.system({ "git", "-C", fixture, "commit", "-m", "a binary file" })

  vim.cmd("edit! " .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  view_mod.open("main", { resolve = require("uatis.base").resolve })
  wait_for(function()
    local v = view_mod.get(buf)
    return v ~= nil and (v.renders or 0) > 0
  end, "the binary view to settle")

  local v = view_mod.get(buf)
  ok(v.binary ~= nil, "the view knows it is looking at bytes")
  eq(v.added, 0, "and counts nothing added")
  eq(v.removed, 0, "nor removed")
  eq(#vim.api.nvim_buf_get_extmarks(buf, require("uatis.overlay").ns, 0, -1, {}), 0,
    "nothing is drawn on it at all")

  -- The size is the FILE's, not the buffer's. Neovim stores a NUL as a
  -- newline and splits on the rest, so a PNG round-tripped through
  -- buffer lines comes back a different length than the file is.
  eq(v.binary.new, vim.uv.fs_stat(path).size,
    "the size it reports is the size the file is")

  local bar = ui.view_winbar_text(v, 100):gsub("%%#%w+#", ""):gsub("%%%*", "")
  ok(bar:find("binary", 1, true) ~= nil, "the bar says so, got " .. bar)
  ok(bar:find("→", 1, true) ~= nil, "with what it weighed and weighs, got " .. bar)
  -- None of the slots that describe a comparison of TEXT: no counts, no
  -- backend, no parser note. None of them is a fact about a PNG.
  ok(bar:find("+0", 1, true) == nil and bar:find("structural", 1, true) == nil
    and bar:find("line", 1, true) == nil,
    "and none of what it would say about text, got " .. bar)

  view_mod.stop(v)
  vim.fn.system({ "git", "-C", fixture, "rm", "-r", "-f", "binblob" })
  vim.fn.system({ "git", "-C", fixture, "commit", "-m", "and out again" })
end

print("\n[a file emptied is not a file folded]")
-- A construct pulled back onto one line -- a signature taken off its
-- continuation rows -- reaches the renderer as a pure deletion, and the
-- before-image for it belongs ABOVE the row it collapsed onto, because
-- that is where the old rows were.
--
-- A file whose body was simply deleted looks the same to the alignment
-- and is not the same thing at all: nothing was folded, the rows went,
-- and they went AFTER the line that survived. Read as a fold, every row
-- of the removed body was drawn above the one line the file had left --
-- which is above the FIRST line of the buffer, where there is nothing
-- to scroll to.
--
-- What tells them apart is the surviving row itself. A fold rewrites
-- the line it collapses onto; a deletion leaves it byte for byte as it
-- was.
do
  local diff = require("uatis.diff")
  local overlay = require("uatis.overlay")

  if vim.fn.executable(require("uatis.config").diff.struct.bin) ~= 1 then
    print("  skip the emptied-file checks (difftastic not installed)")
  else
    local function before(old, new)
      local lines = vim.split(new, "\n", { plain = true })
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].filetype = "python"
      local out, done = {}, false
      diff.compute(old, new, { backend = "struct", path = "x.py", bufnr = buf },
        function(r)
          overlay.render(buf, nil, r, vim.split(old, "\n", { plain = true }))
          for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1,
            { details = true })) do
            local d = m[4]
            if d.virt_lines and #d.virt_lines > 0 then
              local said = {}
              for _, vl in ipairs(d.virt_lines) do
                local t = ""
                for _, c in ipairs(vl) do
                  local gs = type(c[2]) == "table" and c[2] or { c[2] }
                  if gs[#gs] ~= "UatisSign" then t = t .. c[1] end
                end
                table.insert(said, vim.trim(t))
              end
              table.insert(out, { row = m[2] + 1, above = d.virt_lines_above == true,
                rows = said })
            end
          end
          done = true
        end)
      vim.wait(8000, function() return done end, 20)
      vim.api.nvim_buf_delete(buf, { force = true })
      return out
    end

    local kept = '"""The docstring stays."""\n'
    local gone = kept .. "\nWIDTH = 40\nHEIGHT = 12\n\n\ndef f(box):\n    return WIDTH\n"
    local emptied = before(gone, kept)
    ok(#emptied > 0, "the removal is drawn at all")
    for _, b in ipairs(emptied) do
      ok(not b.above,
        "a body deleted after the line that survived hangs BELOW it, not above the "
          .. "first line of the buffer, got row " .. b.row .. " above=" .. tostring(b.above))
    end

    -- The genuine fold -- where the before-image DOES belong above the
    -- line it collapsed onto -- is `[a signature pulled back onto one
    -- line]` above, which still passes: what tells the two apart is
    -- that a fold rewrites its line and this leaves it alone.

    -- ...and a deletion at the very START of a file belongs above the
    -- first line, because that is where it was.
    local top = before("import os\nimport sys\n\ndef f():\n    return 1\n",
      "def f():\n    return 1\n")
    ok(#top > 0 and top[1].above and top[1].row == 1,
      "and one at the top of a file is above the first line, got " .. vim.inspect(top))
  end
end

print("\n[`]c` stops where there is something to look at]")
-- difftastic reports a multi-line atom -- a docstring, a regex literal
-- -- as ONE changed node, so the hunk covers every row of it while the
-- marks sit on the rows that actually differ. Anchored at the hunk,
-- `]c` put the cursor on the opening `"""` of a docstring with nothing
-- on that row and the edit three rows below, which is a key whose whole
-- job is to take the reader to the change telling them to go and find
-- it.
do
  local diff = require("uatis.diff")
  local overlay = require("uatis.overlay")

  if vim.fn.executable(require("uatis.config").diff.struct.bin) ~= 1 then
    print("  skip the stop checks (difftastic not installed)")
  else
    local old = table.concat({
      "def f(t):",
      [[    """Drop a modifier.]],
      "",
      "    The diagram is a structural overview.",
      "    It widens every box that carries one.",
      [[    """]],
      "    return t",
    }, "\n") .. "\n"
    local new = old:gsub("carries one", "carries two")

    local lines = vim.split(new, "\n", { plain = true })
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = "python"
    local stops, marked, done = nil, {}, false
    diff.compute(old, new, { backend = "struct", path = "x.py", bufnr = buf },
      function(r)
        stops = overlay.render(buf, nil, r, vim.split(old, "\n", { plain = true }))
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1,
          { details = true })) do
          marked[m[2] + 1] = true
        end
        done = true
      end)
    vim.wait(8000, function() return done end, 20)
    vim.api.nvim_buf_delete(buf, { force = true })

    eq(stops, { 5 }, "the stop is the row that changed, not the node it is in")
    for _, at in ipairs(stops or {}) do
      ok(marked[at], "and every stop is a row carrying a mark, got "
        .. vim.inspect(stops) .. " against " .. vim.inspect(vim.tbl_keys(marked)))
    end

    -- A hunk with nothing drawn on it anywhere keeps its own row: a
    -- pure deletion is anchored where the before-image hangs, and that
    -- is the answer even though the change is not ON that row.
    local cut = "def f(t):\n    a = 1\n    b = 2\n    return t\n"
    local shorter = "def f(t):\n    a = 1\n    return t\n"
    local cbuf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(cbuf, 0, -1, false, vim.split(shorter, "\n", { plain = true }))
    vim.bo[cbuf].filetype = "python"
    local cut_stops, seen = nil, false
    diff.compute(cut, shorter, { backend = "struct", path = "x.py", bufnr = cbuf },
      function(r)
        cut_stops = overlay.render(cbuf, nil, r, vim.split(cut, "\n", { plain = true }))
        seen = true
      end)
    vim.wait(8000, function() return seen end, 20)
    vim.api.nvim_buf_delete(cbuf, { force = true })
    ok(cut_stops ~= nil and #cut_stops == 1,
      "a pure deletion still stops somewhere, got " .. vim.inspect(cut_stops))
  end
end

print("\n[the indentation a wrapping pushed a block by]")
-- Wrapping a body in a guard reindents it, and difftastic is right to
-- report nothing for those rows: not a token of them changed. But the
-- indentation did, and in Python that is the whole of what the wrapping
-- did to them -- drawn as nothing, the reader has to check the column of
-- every line under the new `if` by eye.
--
-- Marked, but only there. A file reindented throughout reports no hunks
-- at all, and one reindented throughout AND edited in one place must not
-- light up every row in it.
do
  local diff = require("uatis.diff")
  local overlay = require("uatis.overlay")

  if vim.fn.executable(require("uatis.config").diff.struct.bin) ~= 1 then
    print("  skip the indentation checks (difftastic not installed)")
  else
    --- Every mark that lands on a row\'s leading whitespace.
    local function shifted(old, new)
      local lines = vim.split(new, "\n", { plain = true })
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].filetype = "python"
      local out, done = {}, false
      diff.compute(old, new, { backend = "struct", path = "x.py", bufnr = buf },
        function(r)
          overlay.render(buf, nil, r, vim.split(old, "\n", { plain = true }))
          for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1,
            { details = true })) do
            local d = m[4]
            local text = lines[m[2] + 1] or ""
            if d.hl_group == "UatisAdd" and d.end_col and not d.hl_eol
              and text:sub(1, d.end_col):match("^%s*$") then
              out[m[2] + 1] = text:sub(m[3] + 1, d.end_col)
            end
          end
          done = true
        end)
      vim.wait(8000, function() return done end, 20)
      vim.api.nvim_buf_delete(buf, { force = true })
      return out
    end

    local wrapped = shifted(
      "def f(a):\n    x = a * 2\n    y = x + 1\n    return y\n",
      "def f(a):\n    if a:\n        x = a * 2\n        y = x + 1\n"
        .. "        return y\n    return 0\n")
    eq(wrapped[3], "    ", "the block a guard was put around is marked where it moved")
    eq(wrapped[4], "    ", "on every row of it")
    eq(wrapped[5], "    ", "through to the last")
    eq(wrapped[2], nil, "and not on the guard itself, which is banded whole")

    -- Cosmetic on its own is still cosmetic: difftastic reports no hunks
    -- for a file that was only reindented, so there is nothing to draw
    -- and this must not invent something.
    eq(shifted("def f(a):\n  x = a * 2\n  y = x + 1\n  return y\n",
      "def f(a):\n    x = a * 2\n    y = x + 1\n    return y\n"), {},
      "a file that was only reindented is not marked at all")

    -- ...and a reformat that happens to share a commit with a real edit
    -- is still a reformat. The run ends next to the hunk rather than
    -- starting under it, and a block nothing was put around is not a
    -- wrapping however close the edit is.
    local wide_old, wide_new = { "def f(a):" }, { "def f(a):" }
    for i = 1, 12 do
      table.insert(wide_old, ("  step%d = a + %d"):format(i, i))
      table.insert(wide_new, ("    step%d = a + %d"):format(i, i))
    end
    table.insert(wide_old, "  return step1")
    table.insert(wide_new, "    return step12")
    local reformat = shifted(table.concat(wide_old, "\n") .. "\n",
      table.concat(wide_new, "\n") .. "\n")
    eq(reformat, {},
      "a reformat beside one edit does not light up every row it moved, got "
        .. vim.inspect(reformat))

    -- A block UNwrapped moved the other way. There is nothing on the new
    -- side that was not there before, so there is nothing to mark.
    eq(shifted("def f(a):\n    if a:\n        x = a * 2\n        return x\n"
      .. "    return 0\n", "def f(a):\n    x = a * 2\n    return x\n"), {},
      "and a block that moved LEFT gained no columns to mark")
  end
end

print("\n[a reworded sentence reads the same parsed or not]")
-- The step-back is a statement about a SENTENCE: these words are new,
-- the rest is the line you already know. difftastic reports a parsed
-- file's docstring as one span for the whole string node, and a file it
-- has no parser for as one span PER WORD -- so narrowing to the spans
-- something was inserted into kept the new word and threw the sentence
-- away. The same edit came out as a pale sentence with a word lit in a
-- .py and as one lit word on a bare row in a .md.
do
  local diff = require("uatis.diff")
  local overlay = require("uatis.overlay")

  if vim.fn.executable(require("uatis.config").diff.struct.bin) ~= 1 then
    print("  skip the prose-mode checks (difftastic not installed)")
  else
    local function marks(old, new, path, ft)
      local lines = vim.split(new, "\n", { plain = true })
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].filetype = ft
      local out, done = { band = {}, lit = {} }, false
      diff.compute(old, new, { backend = "struct", path = path, bufnr = buf },
        function(r)
          overlay.render(buf, nil, r, vim.split(old, "\n", { plain = true }))
          for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1,
            { details = true })) do
            local row, col, d = m[2] + 1, m[3], m[4]
            local band = d.line_hl_group or (d.hl_eol and d.hl_group)
            if band then
              out.band[row] = band
            elseif d.end_col and d.hl_group == "UatisAdd" then
              table.insert(out.lit, (lines[row] or ""):sub(col + 1, d.end_col))
            end
          end
          done = true
        end)
      vim.wait(8000, function() return done end, 20)
      vim.api.nvim_buf_delete(buf, { force = true })
      return out
    end

    local sentence = "A diagram is a structural overview. It says what talks to "
    local md_old = "# Guide\n\n" .. sentence .. "what, and a\nlength says nothing "
      .. "at all about how long anything takes.\n"
    local md_new = md_old:gsub("nothing at all about", "nothing whatsoever about")
    local md = marks(md_old, md_new, "guide.md", "markdown")
    eq(md.band[4], "UatisAddDim",
      "a reworded line of an unparsed file steps back as a sentence")
    eq(md.lit, { "whatsoever" }, "with the word that is new lit inside it")

    -- ...and the same edit in a file difftastic DOES parse, which is the
    -- reading the other one has to match.
    local py_old = 'def f():\n    """A diagram says nothing at all about how long."""\n'
      .. "    return 1\n"
    local py_new = py_old:gsub("nothing at all about", "nothing whatsoever about")
    local py = marks(py_old, py_new, "x.py", "python")
    eq(py.band[2], "UatisAddDim", "which is what the parsed file already did")
    eq(py.lit, { "whatsoever" }, "down to the word it picks out")
  end
end

print("\n[a space between two words that went, went with them]")
-- The marks in a before-image are BACKGROUNDS, so an untinted gap
-- between two tinted words is the most deliberate thing on the row.
-- `total += self.measure(box)` becoming `sum(self.measure(box) for ...)`
-- loses its `total` and its `+=` and keeps the call, so the backend
-- reports two removals with a space between them -- and the space came
-- back at the step-back, reading as a space that survived a deletion on
-- either side of it. `joined` already said this for the marks drawn on a
-- real row; the before-image was walking its ranges raw.
do
  local diff = require("uatis.diff")
  local overlay = require("uatis.overlay")

  if vim.fn.executable(require("uatis.config").diff.struct.bin) ~= 1 then
    print("  skip the before-image join (difftastic not installed)")
  else
    local old = table.concat({
      "def layout(self, boxes):",
      "    total = 0",
      "    for box in boxes:",
      "        total += self.measure(box)",
      "    return total",
    }, "\n") .. "\n"
    local new = table.concat({
      "def layout(self, boxes):",
      "    return sum(self.measure(box) for box in boxes)",
    }, "\n") .. "\n"

    local lines = vim.split(new, "\n", { plain = true })
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = "python"
    local rows, done = {}, false
    diff.compute(old, new, { backend = "struct", path = "x.py", bufnr = buf }, function(r)
      overlay.render(buf, nil, r, vim.split(old, "\n", { plain = true }))
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1,
        { details = true })) do
        for _, vl in ipairs(m[4].virt_lines or {}) do
          -- Text and the background it is drawn on, in order. The
          -- syntax group rides in front of the band, so the band is
          -- whichever group is last.
          local out = {}
          for _, c in ipairs(vl) do
            local gs = type(c[2]) == "table" and c[2] or { c[2] }
            table.insert(out, { text = c[1], band = gs[#gs] })
          end
          table.insert(rows, out)
        end
      end
      done = true
    end)
    vim.wait(8000, function() return done end, 20)
    vim.api.nvim_buf_delete(buf, { force = true })

    -- The row that kept half of itself. The other three went whole and
    -- have no gap to get this wrong on.
    local row
    for _, r in ipairs(rows) do
      for _, c in ipairs(r) do
        if c.text:find("+=", 1, true) then
          row = r
        end
      end
    end
    ok(row ~= nil, "the removed row is drawn, got " .. #rows .. " before-image rows")

    local band_of = {}
    for _, c in ipairs(row or {}) do
      band_of[c.text] = c.band
    end
    eq(band_of["total"], "UatisDeleteBg", "the word that went is at full strength")
    eq(band_of["+="], "UatisDeleteBg", "and so is the operator beside it")

    -- The gap BETWEEN them, which is the whole point: found by walking
    -- the row, since a bare " " appears more than once on it.
    local between, seen_total = nil, false
    for _, c in ipairs(row or {}) do
      if seen_total and between == nil and c.text:match("^%s+$") then
        between = c.band
      end
      if c.text == "total" then
        seen_total = true
      end
    end
    eq(between, "UatisDeleteBg",
      "and the space between two words that both went goes with them")

    -- ...but not the space before the code that SURVIVED. Joining is
    -- about gaps inside one removal, not about reaching across a word
    -- the reader can still see on the line below.
    local after = nil
    for i, c in ipairs(row or {}) do
      if c.text == "self" and i > 1 then
        after = row[i - 1].band
      end
    end
    eq(after, "UatisDeleteDim",
      "while the space before the call that stayed is still stepped back")
  end
end

print("\n[a passage of removed rows is not spread over the new side]")
-- Drawing a removed row directly above the row it became gives the reader
-- one comparison they can check without looking anywhere else. Drawing a
-- whole passage that way gives them stripes: red, green, red, green all
-- the way down, with every line of the old code separated from the next
-- by a line of the new. The block that was there is then nowhere on
-- screen as CODE, which is the one thing a before-image is for.
--
-- So the spreading is for a row or two. Past that the rows go back where
-- a patch has always put them -- one block above the hunk, old together
-- and new together -- with the same lines in the same order.
do
  local overlay = require("uatis.overlay")

  --- Renders `n` rows each replaced by a line it resembles, and answers
  --- with the rows the before-images were anchored to.
  local function anchors_for(n)
    local old_lines, new_lines = { "def check(user, registry, audit):" }, { "def check(user, registry, audit):" }
    for i = 1, n do
      table.insert(old_lines,
        ("    v%d = registry.lookup_by_identifier(user.identifier, audit.window)"):format(i))
      table.insert(new_lines,
        ("    v%d = registry.resolve_from_registry_cache(user.canonical_id, trail.window)"):format(i))
    end
    table.insert(old_lines, "    return v1")
    table.insert(new_lines, "    return v1")

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
    -- Hand-built, so the test states the shape it is about: the sides
    -- pair up row for row, which is when the spreading applies at all.
    local hunks = { { start_a = 2, count_a = n, start_b = 2, count_b = n } }
    local anchor, pairs_of = {}, {}
    for i = 1, #old_lines do
      anchor[i], pairs_of[i] = i, i
    end
    overlay.render(buf, nil, {
      hunks = hunks,
      spans = removed(hunks, old_lines),
      anchor = anchor,
      pairs = pairs_of,
      dropped = 0,
      engine = "difftastic",
      precise = true,
    }, old_lines)

    local rows, drawn = {}, 0
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1, { details = true })) do
      if m[4].virt_lines then
        table.insert(rows, m[2])
        drawn = drawn + #m[4].virt_lines
      end
    end
    vim.api.nvim_buf_delete(buf, { force = true })
    table.sort(rows)
    return rows, drawn
  end

  -- Three rows: each above its own, which is the whole point of the
  -- pairing -- the line a mark was measured against is the line above it.
  local few, few_drawn = anchors_for(3)
  eq(few_drawn, 3, "three removed rows are all drawn")
  eq(few, { 1, 2, 3 }, "each above the row it became")

  -- Six: the same six lines, in the same order, in one block at the top
  -- of the hunk.
  local many, many_drawn = anchors_for(6)
  eq(many_drawn, 6, "six removed rows are all drawn too")
  eq(many, { 1 }, "but together, above the hunk, rather than one per row")
end

print("\n[the diff view]")
do
    
  local function open(ref)
    vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
    local buf = vim.api.nvim_get_current_buf()
    uatis.run({ fargs = { ref } })
    wait_for(function()
      local v = view_mod.get(buf)
      return v ~= nil and #(v.anchors or {}) > 0
    end, "the in-place view on calc.lua vs " .. ref)
    return buf, view_mod.get(buf)
  end

  -- The fixture leaves main checked out, so the buffer is main's calc.lua
  -- and the branch is what it is measured against.
  local buf, view = open("feature/math")
  ok(view ~= nil, "a view is registered for the buffer")
  ok(view.relpath == "calc.lua", "it knows its path inside the repo, got "
    .. tostring(view and view.relpath))
  ok(vim.wo.winbar ~= "", "the window gets a winbar")
  ok(#vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1, {}) > 0,
    "and the buffer is annotated")
  ok(vim.bo[buf].buftype == "" and vim.bo[buf].modifiable,
    "the buffer stays a normal, writable file buffer")

  local ui = require("uatis.ui")
  local function plain(s)
    return (s:gsub("%%#[%w]*#", ""):gsub("%%%*", ""):gsub("%%<", ""))
  end
  local bar = plain(ui.view_winbar_text(view, 200))
  ok(bar:find("calc.lua", 1, true) and bar:find("vs feature/math", 1, true),
    "the winbar names the file and the revision, got: " .. bar)
  -- ...and no keys. The identity is read on every glance and the keys
  -- once, and `g?` in the list teaches them on demand.
  local keys = require("uatis.config").keys
  ok(bar:find(keys.global.toggle_diff .. " close", 1, true) == nil
    and bar:find(keys.view.hunk_next .. "/", 1, true) == nil,
    "and names no key, got: " .. bar)

  -- difftastic answering without a parser is not difftastic being
  -- missing, and the two read differently: one is a line diff, the other
  -- is a structural diff of words. Both are worth a word in the header,
  -- because both look like less than the reader asked for.
  local prose_bar = plain(ui.view_winbar_text(
    vim.tbl_extend("force", {}, view, { prose = true }), 200))
  ok(prose_bar:find("structural · no parser", 1, true) ~= nil,
    "and says so when difftastic answered without a parser, got: " .. prose_bar)
  -- ...and WHY, where it had a parser and put it down. `no parser` on
  -- a `.py` file reads as "difftastic cannot do Python"; the truth was
  -- a diff too large for its graph limit, or a file that would not
  -- parse just now, and either is something the reader can act on.
  local why_bar = plain(ui.view_winbar_text(
    vim.tbl_extend("force", {}, view, { prose = true, fallback = "graph limit" }), 200))
  ok(why_bar:find("structural · text fallback (graph limit)", 1, true) ~= nil,
    "and names the limit difftastic gave up at, got: " .. why_bar)
  eq(require("uatis.diff").fallback_of("Text (exceeded DFT_GRAPH_LIMIT)"), "graph limit",
    "read off difftastic's own language string")
  eq(require("uatis.diff").fallback_of("Text (3 Python parse errors, exceeded DFT_PARSE_ERROR_LIMIT)"),
    "parse errors", "whichever limit it was")
  eq(require("uatis.diff").fallback_of("Text"), nil, "and nothing where there was no parser to put down")
  eq(require("uatis.diff").fallback_of("Python"), nil, "or no fallback at all")
  local pieces_bar = plain(ui.view_winbar_text(
    vim.tbl_extend("force", {}, view, { pieces = 3, prose = false }), 200))
  ok(pieces_bar:find("structural · in 3 pieces", 1, true) ~= nil,
    "and says when the file was read in pieces, got: " .. pieces_bar)

  -- Re-running replaces the comparison rather than stacking a second view
  -- on the same buffer.
  local before_renders = view.renders
  uatis.run({ fargs = { "main" } })
  wait_for(function()
    local v = view_mod.get(buf)
    return v ~= nil and v.ref == "main" and (v.renders or 0) > before_renders
  end, "the ref to be replaced in place")
  ok(view_mod.get(buf) == view, "re-running reuses the same view")
  ok(#(view_mod.get(buf).anchors or {}) == 0,
    "and against the checked-out revision there is nothing to show")

  -- Editing moves the new side, so the diff has to follow it. Debounced,
  -- so this waits rather than asserting immediately.
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "-- a line that is not in main" })
  wait_for(function()
    return #(view_mod.get(buf).anchors or {}) > 0
  end, "the diff to follow an edit to the buffer")
  ok(view_mod.get(buf).added > 0, "an unsaved edit shows up as an addition")

  -- What it has to put back.
  view_mod.close(buf)
  ok(view_mod.get(buf) == nil, "closing unregisters the view")
  ok(#vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1, {}) == 0,
    "and clears every mark")
  ok(vim.wo.winbar == "", "and puts the winbar back")
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
end

print("\n[side by side, or in place]")
-- The same comparison drawn two ways. In place, the old side is virtual
-- lines around your buffer; side by side, it is the window next door and
-- drawing it twice would say everything twice. What does not change is
-- the marks on your own buffer: what was added is a property of the
-- buffer, not of the layout.
do
    local oldside = require("uatis.oldside")
  local ui = require("uatis.ui")
  local k = require("uatis.config").keys.view

  vim.cmd("silent! only")
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
  local buf = vim.api.nvim_get_current_buf()
  require("uatis").run({ fargs = { "feature/math" } })
  wait_for(function()
    return view_mod.get(buf) ~= nil and #(view_mod.get(buf).anchors or {}) > 0
  end, "the in-place view to open on calc.lua")
  local view = view_mod.get(buf)

  local function press(lhs)
    local m = vim.fn.maparg(lhs, "n", false, true)
    ok(m and m.callback ~= nil, "the view binds " .. lhs)
    local before = view.renders or 0
    if m and m.callback then
      m.callback()
    end
    wait_for(function()
      return (view.renders or 0) > before
    end, "a redraw after " .. lhs)
  end

  local function counts()
    local out = { marks = 0, before = 0 }
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1, { details = true })) do
      local d = m[4]
      if d.line_hl_group or d.end_col or d.virt_text_pos == "inline" then
        out.marks = out.marks + 1
      end
      out.before = out.before + #(d.virt_lines or {})
    end
    return out
  end

  local placed = counts()
  ok(placed.before > 0, "in place, the old side is drawn around your buffer")
  eq(view.layout, "inline", "which is where a view starts")

  press(k.layout)
  eq(view.layout, "side", k.layout .. " switches to side by side")
  ok(oldside.is_open(view), "which opens the old revision in its own window")
  ok(vim.api.nvim_get_current_win() == view.win,
    "leaving you in your own buffer, which is the one you can edit")

  local beside = counts()
  eq(beside.before, 0, "and stops drawing the old side twice")
  ok(beside.marks > 0, "while your buffer keeps its own marks")

  -- The two windows are one view of one comparison, so the old one
  -- follows the cursor rather than being scrolled by hand.
  vim.api.nvim_win_set_cursor(view.win, { 4, 0 })
  vim.cmd("doautocmd CursorMoved")
  eq(vim.api.nvim_win_get_cursor(view.old.win)[1], oldside.old_row(view, 4),
    "the old window follows the cursor")

  -- Both sides are padded with blank rows where the other has lines it
  -- does not, so a line and the line it replaced sit on the same screen
  -- row. Equal display heights is that property, stated once.
  local function filler_rows(bufnr)
    local n = 0
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, oldside.ns, 0, -1, { details = true })) do
      n = n + #(m[4].virt_lines or {})
    end
    return n
  end
  -- The branch this is measured against only ADDED, so the padding all
  -- lands on your side: there is nothing here to sit opposite `M.mul`.
  -- One view change per movement, and none at all when the answer has
  -- not changed. Moving the cursor and then correcting the scroll drew
  -- the old window twice per keypress, with a jump to another part of the
  -- file in between -- which is what flickering is.
  local function old_view()
    return vim.api.nvim_win_call(view.old.win, function()
      return vim.fn.winsaveview()
    end)
  end
  local settled = old_view()
  eq(settled.lnum, oldside.old_row(view, 4), "the old window's cursor is where the mapping says")
  oldside.sync(view, 4)
  eq(old_view(), settled, "and syncing again for the same row changes nothing at all")

  ok(filler_rows(buf) > 0, "your side is padded where the old one has lines you do not")

  -- The old side is padded with REAL lines instead. Virtual ones cannot
  -- be scrolled into -- a block below the last line not at all, and one
  -- taller than the window not without a real line to put the cursor on
  -- -- so a shorter old file pinned its last line to the top and sat
  -- there while your side scrolled past it.
  local old_lines = vim.api.nvim_buf_get_lines(view.old.buf, 0, -1, false)
  eq(#old_lines, #oldside.alignment(view),
    "the old buffer has one line per row of the alignment")
  local blanks, revision = 0, 0
  for row = 1, #old_lines do
    if view.old_of_row[row] then
      revision = revision + 1
    else
      blanks = blanks + 1
      eq(old_lines[row], "", "a row standing for a line you have and it does not is blank")
    end
  end
  eq(revision, #vim.split(view.old_text, "\n", { plain = true }),
    "every line of the revision is there, and nothing else")
  -- This branch only added, so nothing had to be padded on the old side:
  -- the blanks are all on yours. The alignment's own tests cover the
  -- other direction line by line.
  eq(blanks, 0, "with blanks only where the alignment calls for them")
  ok(vim.api.nvim_win_get_cursor(view.old.win)[1] <= #old_lines,
    "and the cursor can sit anywhere in it")
  eq(vim.api.nvim_win_text_height(view.win, {}).all,
    vim.api.nvim_win_text_height(view.old.win, {}).all,
    "which leaves the two sides exactly as tall as each other")

  -- Each window says which revision it is showing, which is the question
  -- a two-window layout invents.
  local function plain(text)
    return (text:gsub("%%#[%w]*#", ""):gsub("%%%*", ""):gsub("%%<", ""))
  end
  local mine = plain(ui.view_winbar_text(view, 200))
  ok(mine:find("working tree", 1, true) ~= nil,
    "your window says it is the working tree, got: " .. mine)
  local theirs = plain(ui.old_winbar_text(view, 200))
  ok(theirs:find("feature/math", 1, true) ~= nil, "the other names the revision")
  ok(theirs:find(view.rev:sub(1, 7), 1, true) ~= nil,
    "and the sha it resolved to, got: " .. theirs)

  press(k.layout)
  eq(view.layout, "inline", "pressing it again goes back")
  ok(not oldside.is_open(view), "closing the window it opened")
  ok(counts().before > 0, "and drawing the old side around your buffer again")
  eq(filler_rows(buf), 0, "and taking the padding back out of your buffer")

  view_mod.close(buf)
  vim.cmd("silent! only")
end

print("\n[a tab closed on a side-by-side view takes its padding with it]")
-- The fillers that line your buffer up with the old window are extmarks
-- in YOUR buffer, and `:tabclose` takes both windows away at once. The
-- old window's `WinClosed` dropped `view.old` so the next sync would not
-- reach for a window that was gone -- and the view's own close, coming
-- a tick later, found no old side to clean up after. The buffer stayed
-- loaded, and the file came back with blank rows between its lines.
do
  local oldside = require("uatis.oldside")
  local k = require("uatis.config").keys.view

  -- The file is shown in the new tab and nowhere else: a view is one
  -- per buffer, and a buffer on screen in two tabs is a different
  -- question. Nothing has to be left behind for the point to be made.
  vim.cmd("silent! only")
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/stable.lua"))
  vim.cmd("tabnew")
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
  local buf = vim.api.nvim_get_current_buf()
  local tab = vim.api.nvim_get_current_tabpage()
  require("uatis").run({ fargs = { "feature/math" } })
  wait_for(function()
    return view_mod.get(buf) ~= nil and #(view_mod.get(buf).anchors or {}) > 0
  end, "the in-place view to open on calc.lua")
  local view = view_mod.get(buf)
  local wrapped = vim.wo[view.win].wrap

  -- Pressed from the file, as it would be: the old revision opens
  -- beside the window the key was pressed in.
  vim.api.nvim_set_current_win(view.win)
  local m = vim.fn.maparg(k.layout, "n", false, true)
  local before = view.renders or 0
  m.callback()
  wait_for(function()
    return (view.renders or 0) > before
  end, "the side-by-side layout")
  ok(oldside.is_open(view), "the old revision is open beside the buffer")

  local function filler_rows()
    local n = 0
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, oldside.ns, 0, -1, { details = true })) do
      n = n + #(m[4].virt_lines or {})
    end
    return n
  end
  ok(filler_rows() > 0, "and your side is padded to line up with it")

  vim.cmd("tabclose")
  wait_for(function()
    return view_mod.get(buf) == nil
  end, "the view to close with its tab")
  ok(not vim.api.nvim_tabpage_is_valid(tab), "the tab is gone")
  ok(vim.api.nvim_buf_is_loaded(buf), "and the buffer is still loaded, as any hidden buffer is")
  eq(filler_rows(), 0, "with no padding left in it for the next window to draw")

  vim.cmd("silent! only")
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
  eq(vim.api.nvim_get_current_buf(), buf, "reopening the file lands in that same buffer")
  eq(filler_rows(), 0, "and shows it without blank rows between its lines")
  eq(vim.wo.wrap, wrapped, "with wrapping as it was before the layout turned it off")
end

print("\n[a window that moves on takes its view with it]")
-- `BufWinLeave` is what closes a view when its window moves to the next
-- file -- and it does not fire while the buffer is still on screen
-- somewhere else: the same file open in another tab. `]f` then left the
-- view standing, `view.win` showing a file that was not its own and the
-- old revision still split beside it, and the next file's old window
-- opened alongside -- two old sides on screen.
do
  local oldside = require("uatis.oldside")
  local kv = require("uatis.config").keys.view

  vim.fn.system({ "git", "-C", fixture, "switch", "-qf", "feature/math" })
  vim.cmd("silent! only")
  -- The file on screen in another tab as well, which is what keeps
  -- `BufWinLeave` from firing when the review's window moves on.
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
  local buf = vim.api.nvim_get_current_buf()
  vim.cmd("tabnew")
  vim.api.nvim_win_set_buf(0, buf)
  local tab = vim.api.nvim_get_current_tabpage()

  uatis.run({ fargs = { "main" } })
  wait_for(function()
    local v = view_mod.get(buf)
    return v ~= nil and (v.renders or 0) > 0 and pane_mod.get() ~= nil
      and (pane_mod.get().renders or 0) > 0
  end, "the review to open on calc.lua")
  local view = view_mod.get(buf)
  local win = view.win

  local function press(lhs)
    local m = vim.fn.maparg(lhs, "n", false, true)
    ok(m and m.callback ~= nil, "the buffer binds " .. lhs)
    if m and m.callback then
      m.callback()
    end
  end
  local function olds()
    local n = 0
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      if oldside.view_for(vim.api.nvim_win_get_buf(w)) then
        n = n + 1
      end
    end
    return n
  end

  press(kv.layout)
  wait_for(function() return oldside.is_open(view) end, "the old window")
  eq(olds(), 1, "one old side on screen")

  press(kv.file_next)
  wait_for(function()
    local v = view_mod.get(vim.api.nvim_get_current_buf())
    return v ~= nil and v ~= view and (v.renders or 0) > 0 and oldside.is_open(v)
  end, "the next file, side by side")
  wait_for(function() return view_mod.get(buf) == nil end,
    "the view on the file left behind to close")
  ok(view_mod.get(buf) == nil, "the file the window moved off has no view, though it is still on screen elsewhere")
  eq(olds(), 1, "and one old side on screen, not two")
  eq(vim.api.nvim_win_get_buf(win) ~= buf, true, "the window itself moved on")

  view_mod.stop(view_mod.get(vim.api.nvim_get_current_buf()))
  wait_for(function() return pane_mod.get() == nil end, "the review to end")
  vim.cmd("silent! tabclose")
  vim.cmd("silent! only")
  vim.fn.system({ "git", "-C", fixture, "switch", "-qf", "main" })
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
end

print("\n[which line is opposite which]")
-- What a side-by-side layout needs and an overlay does not: for every
-- display row, the old line, the new line, or both. Padding each side
-- where the other has lines it does not is what puts a line and the line
-- it replaced on the same screen row.
do
  local oldside = require("uatis.oldside")

  local old_lines = { "one", "two", "three", "four" }
  local new_lines = { "one", "TWO", "two and a half", "three", "four" }

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)

  --- The alignment as a printable table: "old|new" per display row.
  local function rows(view, olds, news)
    olds, news = olds or old_lines, news or new_lines
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, news)
    view.bufnr = buf
    view.old_text = table.concat(olds, "\n")
    local out = {}
    for _, e in ipairs(oldside.alignment(view)) do
      table.insert(out, (e.old and olds[e.old] or "-")
        .. "|" .. (e.new and news[e.new] or "-"))
    end
    return out
  end

  -- One line replaced by two, by the hunk shapes alone: the two blocks
  -- start opposite each other and the shorter side runs out first, which
  -- is what every side-by-side diff has always drawn.
  eq(rows({ hunks = { { start_a = 2, count_a = 1, start_b = 2, count_b = 2 } } }), {
    "one|one",
    "two|TWO",
    "-|two and a half",
    "three|three",
    "four|four",
  }, "unchanged lines advance in step and a replacement pads to the longer side")

  -- The backend's own alignment wins where it has one: here it says the
  -- old `two` answers to `two and a half`, not to `TWO`.
  eq(rows({
    hunks = { { start_a = 2, count_a = 1, start_b = 2, count_b = 2 } },
    pairs = { [1] = 1, [3] = 2, [4] = 3, [5] = 4 },
  }), {
    "one|one",
    "-|TWO",
    "two|two and a half",
    "three|three",
    "four|four",
  }, "and a stated pairing is followed instead of guessed at")

  -- A pure deletion has nothing on the new side to sit opposite, and
  -- anchors after the row it follows: `start_b` is "the line after which
  -- content was removed", so the padding goes under new line 2, not over
  -- it.
  eq(rows({ hunks = { { start_a = 3, count_a = 2, start_b = 2, count_b = 0 } } },
    { "one", "two", "three", "four" }, { "one", "two" }), {
    "one|one",
    "two|two",
    "three|-",
    "four|-",
  }, "a deletion pads the new side under the row it follows")

  vim.api.nvim_buf_delete(buf, { force = true })
end

print("\n[the view leaves your mappings alone]")
-- The review's panes are scratch buffers, so a mapping left behind there
-- dies with them. Here it would sit on a file buffer for the rest of the
-- session. A global mapping is the case that bites: maparg reports it as
-- the mapping in effect, and "restoring" it re-creates it globally while
-- the buffer-local one still shadows it.
do
    local k = require("uatis.config").keys.view

  -- Nothing following the cursor: what is under test is a view opening
  -- over a buffer that already had a mapping of its own, and a review
  -- running would have annotated the file on arrival -- before the mapping
  -- this section is about existed.
  pane_mod.close(pane_mod.get())

  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
  local buf = vim.api.nvim_get_current_buf()
  view_mod.close(buf)
  vim.keymap.set("n", k.hunk_next, "<Cmd>echo 'mine'<CR>", { desc = "user's own" })
  local mine = vim.fn.maparg(k.hunk_next, "n")

  require("uatis").run({ fargs = { "feature/math" } })
  wait_for(function()
    return view_mod.get(buf) ~= nil and #(view_mod.get(buf).anchors or {}) > 0
  end, "the view to open over a buffer with its own mappings")
  ok(vim.fn.maparg(k.hunk_next, "n") ~= mine, "the view takes " .. k.hunk_next .. " while it is open")

  view_mod.close(buf)
  eq(vim.fn.maparg(k.hunk_next, "n"), mine,
    "and hands " .. k.hunk_next .. " straight back on exit")
  eq(vim.fn.maparg(k.layout, "n"), "", "leaving nothing of its own behind")
  vim.keymap.del("n", k.hunk_next)
end

print("\n[finding the line that answers to this one]")
-- Counting added and removed lines is exact outside a hunk and inside one
-- that pairs its two sides. It is useless inside one that does not: a file
-- whose functions were moved into a class comes back from the line
-- backend as ONE hunk covering all of it, and counting alone puts every
-- row in it on the same line. The text has to break the tie.
do
  local oldside = require("uatis.oldside")

  local old_lines = {
    "import pytest",                                  -- 1
    "",                                               -- 2
    "from widgetry.core import Widget, normalise",    -- 3
    "",                                               -- 4
    "",                                               -- 5
    "def test_area():",                               -- 6
    "    widget = Widget(name=\"a\")",                 -- 7
    "    assert widget.area() == 6.0",                -- 8
  }
  local new_lines = {
    "import pytest",                                  -- 1
    "",                                               -- 2
    "from widgetry.core import Widget, clamp",        -- 3
    "",                                               -- 4
    "",                                               -- 5
    "class TestWidget:",                              -- 6
    "    def test_area(self):",                       -- 7
    "        widget = Widget(name=\"a\")",             -- 8
    "        assert widget.area() == 6.0",            -- 9
  }
  -- One hunk over everything from line 3, six old lines against seven new.
  local hunks = { { start_a = 3, count_a = 6, start_b = 3, count_b = 7 } }
  local function old_row(row)
    return oldside.map_row(hunks, row, true, new_lines, old_lines)
  end

  eq(old_row(7), 6, "an indented, re-signatured line finds the line it came from")
  eq(old_row(8), 7, "and so does the body under it, which only moved")
  eq(old_row(1), 1, "a line above every hunk is where it always was")

  -- Nothing to go on: a blank line matches everything, so position
  -- decides rather than a coincidence of text.
  eq(old_row(4), 4, "a line with no text to match falls back to counting")

  -- A hunk that pairs up is answered by position alone, text or no text.
  eq(oldside.map_row({ { start_a = 4, count_a = 1, start_b = 4, count_b = 1 } },
    4, true, new_lines, old_lines), 4, "a paired hunk is exact")

  -- A pure insertion has no line on the other side at all; the row it
  -- follows is the closest true answer.
  eq(oldside.map_row({ { start_a = 3, count_a = 0, start_b = 4, count_b = 2 } },
    5, true, new_lines, old_lines), 3, "an inserted block answers with the line it follows")
end

print("\n[the view says why it cannot open]")
do
    local notes = {}
  local real_notify = vim.notify
  vim.notify = function(msg, level) -- luacheck: ignore
    table.insert(notes, msg)
    real_notify(msg, level)
  end

  local function last_note(what)
    notes = {}
    require("uatis").run({ fargs = { what } })
    vim.wait(2000, function() return #notes > 0 end, 20)
    return notes[1] or ""
  end

  -- A buffer with no file in it has nothing to annotate -- but "what has
  -- this branch changed" is still a good question, and it is about the
  -- repository rather than about whichever buffer is on screen. So the
  -- list opens instead of a refusal.
  vim.cmd("enew!")
  notes = {}
  require("uatis").run({ fargs = { "main" } })
  wait_for(function()
    local p = pane_mod.get()
    return p ~= nil and (p.renders or 0) > 0
  end, "the file list from a buffer with no file in it")
  ok(pane_mod.get() ~= nil, "a buffer with no file gets the file list")
  eq(pane_mod.get().ref, "main", "against the ref that was asked for")
  eq(notes, {}, "and says nothing, because nothing went wrong")
  pane_mod.close(pane_mod.get())

  -- ...including one whose name is not a path. A terminal is called
  -- `term://<cwd>//<pid>:<shell>`, and handing that to `git -C` asks about
  -- a directory that does not exist -- which used to answer "not inside a
  -- git repository" from inside one.
  vim.cmd("enew!")
  vim.bo.buftype = "nofile"
  vim.api.nvim_buf_set_name(0, "term://" .. fixture .. "//4242:/bin/bash")
  notes = {}
  require("uatis").run({ fargs = { "main" } })
  wait_for(function()
    local p = pane_mod.get()
    return p ~= nil and (p.renders or 0) > 0
  end, "the file list from a buffer whose name is not a path")
  ok(pane_mod.get() ~= nil, "a buffer named like a terminal gets it too")
  eq(notes, {}, "without claiming the repository is not one")
  pane_mod.close(pane_mod.get())

  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
  local buf = vim.api.nvim_get_current_buf()
  -- Re-reading the file does not end a review on it, so any one an
  -- earlier section left here is stopped by hand: what is being asked is
  -- whether a ref that does not resolve leaves a view, not whether one
  -- was already there.
  if view_mod.get(buf) then
    view_mod.stop(view_mod.get(buf))
  end
  ok(last_note("no-such-ref"):find("unknown revision", 1, true) ~= nil,
    "an unknown revision is named as one")
  ok(view_mod.get(buf) == nil, "and leaves no view behind")

  -- A file the branch added does not exist in the ref being compared
  -- against, which is a different failure from a bad ref.
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
  notes = {}
  require("uatis").run({ fargs = { "feature/math" } })
  wait_for(function()
    return view_mod.get(vim.api.nvim_get_current_buf()) ~= nil
  end, "a view over calc.lua")
  view_mod.close(vim.api.nvim_get_current_buf())

  vim.notify = real_notify
end

-- ------------------------------------------------------------------
-- The everyday flow: choose a base branch, toggle a diff view on the
-- buffer you are in, open the pane listing the rest of the branch.
--
-- Driven through the public API rather than through the modules, because
-- that is what a keymap calls and the point of these three functions is
-- that they are what a keymap calls.
--
-- Runs on the branch, not on main: everything here is about what the
-- branch changed, and from main there is nothing to see.
-- ------------------------------------------------------------------

print("\n[a repository that stores CRLF]")
-- The old side comes from `git show` and the new side from the buffer.
-- A repo that commits its line endings the Windows way hands back a
-- blob whose every line ends in `\r`, while nvim has stripped them into
-- `fileformat=dos` -- and every line would then differ from itself.
-- `vim.system(..., { text = true })` normalises that away; this is here
-- so nobody takes it for a type annotation and turns it off.
do
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo, "p")
  local function git_run(...)
    return vim.fn.system(vim.list_extend({ "git", "-C", repo }, { ... }))
  end
  git_run("init", "-q", ".")
  git_run("config", "user.email", "t@example.com")
  git_run("config", "user.name", "t")
  git_run("config", "core.autocrlf", "false")
  -- Written as bytes, so the CRLF survives into the blob.
  vim.fn.writefile({ "local a = 1\r", "local b = 2\r", "local c = 3\r" },
    repo .. "/dos.lua", "b")
  git_run("add", "dos.lua")
  git_run("commit", "-qm", "one")

  vim.cmd("silent! only")
  vim.cmd("edit! " .. vim.fn.fnameescape(repo .. "/dos.lua"))
  local buf = vim.api.nvim_get_current_buf()
  eq(vim.bo[buf].fileformat, "dos", "nvim reads it as a dos file")
  vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "local b = 22" })

  view_mod.open("HEAD")
  wait_for(function()
    local v = view_mod.get(buf)
    return v ~= nil and (v.renders or 0) > 0
  end, "a view over a file with CRLF behind it")
  local v = view_mod.get(buf) or {}
  eq(v.added, 1, "the one changed line is the only addition")
  eq(v.removed, 1, "and the only removal")

  local rows = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1, {})) do
    rows[m[2]] = true
  end
  eq(vim.tbl_count(rows), 1, "and one row of the file carries anything at all")

  view_mod.stop(view_mod.get(buf))
  vim.cmd("silent! bwipeout! " .. buf)
  vim.fn.delete(repo, "rf")
end

print("\n[outside a repository]")
-- Every way in has to say so, and say WHERE: a file is asked about by
-- its own path and a buffer with no file by the working directory, so
-- "not inside a git repository" on its own leaves the reader guessing
-- which of the two the answer is about.
do
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local file = dir .. "/loose.lua"
  vim.fn.writefile({ "local M = {}", "return M" }, file)

  -- In a tab of its own: a review running in this one would answer the
  -- key before any of this got asked, and the `lcd` below would follow
  -- the reader back out.
  vim.cmd("tabnew")

  local said = {}
  local real_notify = vim.notify
  vim.notify = function(msg)
    table.insert(said, msg)
  end

  local function complained_about(what, run)
    said = {}
    run()
    wait_for(function() return #said > 0 end, "uatis to say why it cannot " .. what)
    return said[1] or ""
  end

  -- A file that is in no repository, opened and asked about by name.
  vim.cmd("silent! only")
  vim.cmd("edit! " .. vim.fn.fnameescape(file))
  local buf = vim.api.nvim_get_current_buf()
  local msg = complained_about("open a loose file", function()
    view_mod.open("main")
  end)
  eq(msg, "uatis: " .. file .. " is not inside a git repository",
    "a file outside a repository is refused, by name")
  ok(view_mod.get(buf) == nil, "and no view is left on it")

  -- The same file through the key, which resolves a base branch first.
  msg = complained_about("start a review", function()
    uatis.toggle_diff()
  end)
  ok(msg:find("is not inside a git repository", 1, true) ~= nil,
    "and the key says the same, got " .. msg)
  ok(view_mod.get(buf) == nil and pane_mod.get() == nil,
    "with neither a view nor a list put up")

  -- A buffer with no file at all: the question is about the working
  -- directory, so that is what the answer names.
  vim.cmd("enew")
  vim.cmd("lcd " .. vim.fn.fnameescape(dir))
  msg = complained_about("list anything", function()
    uatis.toggle_diff()
  end)
  eq(msg, "uatis: " .. dir .. " is not inside a git repository",
    "a buffer with no file is answered about the directory it is in")
  ok(pane_mod.get() == nil, "and no list is put up")

  msg = complained_about("choose a base", function()
    uatis.set_base_branch()
  end)
  eq(msg, "uatis: " .. dir .. " is not inside a git repository",
    "and so is choosing a base branch")

  vim.notify = real_notify
  vim.cmd("silent! tabclose")
  vim.cmd("silent! bwipeout! " .. buf)
  vim.fn.delete(dir, "rf")
end

print("\n[base branch]")

local base = require("uatis.base")


vim.fn.system({ "git", "-C", fixture, "switch", "-q", "feature/math" })

local root
base.root(function(r) root = r end)
wait_for(function() return root ~= nil end, "the repo root")

local function git_out(...)
  return vim.trim(vim.fn.system({ "git", "-C", root, ... }))
end

do
  base.forget(root)
  local detected
  base.get(root, function(name) detected = name end)
  wait_for(function() return detected ~= nil end, "a detected base branch")
  -- The fixture was `git init`ed, so there is no `origin/HEAD` to read and
  -- the conventional-name fallback is the whole answer. That is the case
  -- on every repository that was never cloned, which is most of them.
  eq(detected, "main", "the default branch is detected without being told")

  local picked
  base.select("feature/math", function(name) picked = name end)
  wait_for(function() return picked ~= nil end, "the branch to be set")
  eq(base.current(root), "feature/math", "setting one by name sticks")

  local refused = "unset"
  base.select("no-such-branch", function(name) refused = name end)
  wait_for(function() return refused ~= "unset" end, "the branch to be refused")
  ok(refused == nil, "an unknown branch is refused")
  eq(base.current(root), "feature/math", "and the previous choice survives it")

  base.set(root, "main")
  local label, sha
  base.resolve(root, function(l, s) label, sha = l, s end)
  wait_for(function() return sha ~= nil end, "the base branch to resolve")
  eq(label, "main", "the label is the branch, which is what was chosen")
  -- The fixture lands a commit on main AFTER the fork. Comparing against
  -- main's TIP would drag that commit into every diff view as a change to
  -- account for, reversed -- the same failure three-dot diffing exists to
  -- avoid in the review.
  eq(sha, git_out("merge-base", "main", "HEAD"), "and the revision is the fork point")
  ok(sha ~= git_out("rev-parse", "main"), "which is not main's tip")
end

-- What the picker offers: the base in force, then the conventional
-- default names that this repository actually has. Not every tag and
-- every branch -- in a repo with a hundred of either that is a list
-- nobody reads, and `vim.ui.select` may be a plain cursor list with
-- nothing to filter it by. Anything else is `:Uatis <ref>`.
do
  base.forget(root)
  local shown, items, chosen_cb
  local real_select, real_input = vim.ui.select, vim.ui.input
  vim.ui.select = function(list, opts, on_choice)
    items = list
    shown = vim.tbl_map(function(item)
      return opts.format_item(item)
    end, list)
    chosen_cb = on_choice
  end
  vim.ui.input = function()
    ok(false, "the picker asks nothing by hand")
  end

  base.select(nil, function() end)
  wait_for(function() return chosen_cb ~= nil end, "the picker to be offered a list")
  eq(shown, { "main  (current)", "type a revision..." },
    "only the default branch this repository has, marked as the one in force, "
      .. "and a row for everything else")

  -- The fixture has no `develop` and no `master`, and neither is offered:
  -- a short list that names branches which are not there is wrong rather
  -- than merely short. `feature/math` and both tags exist and are left
  -- out, which is the point.
  local names = {}
  for _, item in ipairs(items) do
    if item.name then
      table.insert(names, item.name)
    end
  end
  ok(not contains(names, "develop") and not contains(names, "master"),
    "with the conventional names this repo does not have left out, got "
      .. table.concat(names, ", "))
  ok(not contains(names, "v0.1") and not contains(names, "feature/math"),
    "and its tags and other branches left out too, got " .. table.concat(names, ", "))

  -- The base still need not be a branch -- a tag is the answer to "what
  -- has changed since the release". It is set by name rather than picked
  -- out of a list, and resolves like any other base.
  local picked = "unset"
  base.select("v0.1", function(name) picked = name end)
  wait_for(function() return picked ~= "unset" end, "the tag to be checked")
  eq(base.current(root), "v0.1", "a tag named by hand becomes the base")

  local label, sha = nil, nil
  base.resolve(root, function(l, s) label, sha = l, s end)
  wait_for(function() return sha ~= nil end, "it to resolve like any other base")
  eq(sha, git_out("merge-base", "v0.1", "HEAD"),
    "to the fork point between it and HEAD, the same as a branch")

  -- ...and it comes back into the picker as the one in force, since a
  -- base you cannot see is a base you cannot get back off.
  chosen_cb = nil
  base.select(nil, function() end)
  wait_for(function() return chosen_cb ~= nil end, "the picker again")
  eq(shown[1], "v0.1  (current)", "whatever is in force is offered first")
  ok(contains(shown, "main"), "with the default branch still there to go back to")

  vim.ui.select, vim.ui.input = real_select, real_input
  base.forget(root)
  base.set(root, "main")
end

print("\n[a base branch outlives the session]")
-- Choosing a base is a fact about the project, not about this hour: a
-- repository reviewed against `develop`, or against the last release
-- tag, is that way tomorrow too. Being asked again every morning is the
-- plugin forgetting something it has already been told.
do
  local config = require("uatis.config")
  local was = config.base.remember
  local file = vim.fn.tempname()
  config.base.remember = file

  base.forget(root)
  local picked = "unset"
  base.select("feature/math", function(name) picked = name end)
  wait_for(function() return picked ~= "unset" end, "the base to be chosen")
  eq(base.current(root), "feature/math", "the choice is in force")
  eq(base.source(root), "chosen", "and it is a choice, not a detection")

  local kept = vim.json.decode(table.concat(vim.fn.readfile(file), "\n"))
  eq(kept[root], { base = "feature/math" },
    "written down under the repository it is about")

  -- The subtree rides in the same entry, and the two are set apart: a
  -- base chosen after a scope must not throw the scope away.
  base.set_dir(root, "util/")
  eq(base.dir(root), "util", "a subtree is kept with the slashes taken off")
  local both = vim.json.decode(table.concat(vim.fn.readfile(file), "\n"))
  eq(both[root], { base = "feature/math", dir = "util" },
    "beside the base, not instead of it")
  base.forget(root)
  eq(base.dir(root), "util", "which a later session reads back too")
  eq(base.current(root), "feature/math", "with the base still under it")

  -- ...and taking it off writes nothing rather than an empty string:
  -- the whole repository is what no subtree means.
  base.set_dir(root, "")
  eq(base.dir(root), "", "an empty answer is the whole repository")
  eq(vim.json.decode(table.concat(vim.fn.readfile(file), "\n"))[root],
    { base = "feature/math" }, "and leaves nothing behind in the file")

  -- A file written before there was a subtree holds a bare string. It is
  -- read as the base rather than discarded: adding a field is no reason
  -- to make everyone choose their base branch again.
  vim.fn.writefile({ vim.json.encode({ [root] = "v0.1" }) }, file)
  base.forget(root)
  eq(base.current(root), "v0.1", "an entry from before the subtree still reads")
  eq(base.dir(root), "", "as the whole repository")
  vim.fn.writefile({ vim.json.encode({ [root] = { base = "feature/math" } }) }, file)
  base.forget(root)

  -- A new session: nothing in memory, the file still on disk.
  base.forget(root)
  eq(base.current(root), "feature/math", "which a later session reads back")
  eq(base.source(root), "remembered", "knowing where it came from")
  local got
  base.get(root, function(name) got = name end)
  wait_for(function() return got ~= nil end, "the remembered base to resolve")
  eq(got, "feature/math", "and reviews against it without being asked again")

  -- ...but only while it still exists. A branch that was the base last
  -- week can have been merged and deleted since, and a base that is not
  -- there fails at the fork point, two steps from the cause.
  vim.fn.system({ "git", "-C", fixture, "branch", "gone-tomorrow", "main" })
  base.forget(root)
  base.select("gone-tomorrow", function() end)
  wait_for(function() return base.current(root) == "gone-tomorrow" end, "a doomed base")
  vim.fn.system({ "git", "-C", fixture, "branch", "-D", "gone-tomorrow" })
  base.forget(root)
  got = nil
  base.get(root, function(name) got = name end)
  wait_for(function() return got ~= nil end, "the base to be worked out again")
  eq(got, "main", "a base that no longer exists is dropped and the repo asked again")
  local after = vim.json.decode(table.concat(vim.fn.readfile(file), "\n"))
  ok(after[root] == nil, "and forgotten, rather than failing again tomorrow")

  -- Detection is not a choice: what was worked out from origin/HEAD or
  -- the conventional names is worked out again, since that answer can
  -- change without anyone deciding anything.
  base.forget(root)
  got = nil
  base.get(root, function(name) got = name end)
  wait_for(function() return got ~= nil end, "a detected base")
  eq(base.source(root), "detected", "a detected base says so")
  local still = vim.fn.filereadable(file) == 1
    and vim.json.decode(table.concat(vim.fn.readfile(file), "\n")) or {}
  ok(still[root] == nil, "and is not written down")

  -- Off means off.
  config.base.remember = false
  base.forget(root)
  base.select("v0.1", function() end)
  wait_for(function() return base.current(root) == "v0.1" end, "a base chosen with memory off")
  local unchanged = vim.fn.filereadable(file) == 1
    and vim.json.decode(table.concat(vim.fn.readfile(file), "\n")) or {}
  ok(unchanged[root] == nil, "nothing is written down when remembering is off")

  vim.fn.delete(file)
  config.base.remember = was
  base.forget(root)
  base.set(root, "main")
end

print("\n[typing a revision the picker does not offer]")
-- The short list is the answer you almost always want; the row under it
-- is everything else -- a tag, another branch, a hash, `HEAD~3`. It goes
-- through the plugin's own prompt rather than `vim.ui.input`, because
-- what makes that input usable is completion and `completion` is the
-- field a `vim.ui.input` replacement is free to ignore.
do
  base.forget(root)
  base.set(root, "main")

  local prompt = require("uatis.prompt")
  local real_open, real_select = prompt.open, vim.ui.select
  local asked, answer
  prompt.open = function(opts, cb)
    asked = opts
    cb(answer)
  end
  -- The picker always picks the last row, which is the one that asks.
  vim.ui.select = function(list, _, on_choice)
    on_choice(list[#list])
  end

  answer = "feature/math"
  local picked = "unset"
  base.select(nil, function(name) picked = name end)
  wait_for(function() return picked ~= "unset" end, "the typed revision to be taken")
  eq(base.current(root), "feature/math", "what was typed becomes the base")

  local offered, kinds = {}, {}
  for _, item in ipairs(asked.items) do
    table.insert(offered, item.word)
    kinds[item.kind] = (kinds[item.kind] or 0) + 1
  end
  ok(contains(offered, "feature/math"), "with every branch offered as completion")
  ok(contains(offered, "v0.1"), "and the tags, which are not branches and not last")
  -- A base is not always a name. The commit before a refactor landed has
  -- no ref pointing at it and no sha anyone has memorised, so it is
  -- offered with the subject line it is remembered by.
  ok((kinds.commit or 0) > 0, "and the recent commits, got " .. tostring(kinds.commit))
  -- What the menu says beside each: the date it was made, and for a
  -- commit the subject line after it -- a sha says nothing on its own,
  -- and neither does a tag nobody remembers cutting.
  local said = {}
  for _, item in ipairs(asked.items) do
    said[item.kind] = said[item.kind] or item.menu
  end
  ok(said.commit and said.commit:match("^%d%d%d%d%-%d%d%-%d%d  %S"),
    "each carrying its date and what it did, got " .. tostring(said.commit))
  ok(said.tag and said.tag:match("^%d%d%d%d%-%d%d%-%d%d$"),
    "and a tag the date it was cut, got " .. tostring(said.tag))
  ok(said.branch and said.branch:match("^%d%d%d%d%-%d%d%-%d%d$"),
    "and a branch its last commit's, got " .. tostring(said.branch))

  -- A revision git cannot resolve is refused the same way `:Uatis` and a
  -- named branch are: the typed row is another way to say a name, not
  -- another set of rules about what a name is.
  answer = "no-such-thing"
  local refused = "unset"
  base.select(nil, function(name) refused = name end)
  wait_for(function() return refused ~= "unset" end, "the typed revision to be checked")
  ok(refused == nil, "one git cannot resolve is refused")
  eq(base.current(root), "feature/math", "and the previous choice survives it")

  -- Nothing typed is nothing chosen, and nothing said about it.
  answer = nil
  local cancelled = "unset"
  base.select(nil, function(name) cancelled = name end)
  wait_for(function() return cancelled ~= "unset" end, "the prompt to be dismissed")
  ok(cancelled == nil, "backing out of the prompt chooses nothing")
  eq(base.current(root), "feature/math", "and changes nothing")

  prompt.open, vim.ui.select = real_open, real_select
  base.forget(root)
  base.set(root, "main")
end

print("\n[both halves of one statement, on one panel]")
-- What a review IS has two parts -- the revision it measures against,
-- and how much of the tree it is about -- and they are one statement.
-- "main, under util" is a sentence; "main", and then, later, "util", is
-- two decisions that happen to have been taken in a row. Asked in
-- sequence the first is already in force by the time the second is put,
-- so changing the base and thinking better of the subtree has
-- re-pointed every view in the repository on the way past, and there is
-- never a moment where both answers are on the screen to be read
-- together.
do
  local scope = require("uatis.scope")
  local prompt = require("uatis.prompt")
  local real_open, real_select = prompt.open, vim.ui.select
  local answer
  prompt.open = function(_, cb) cb(answer) end
  -- The picker always picks the last row, which is the one that asks.
  vim.ui.select = function(list, _, on_choice) on_choice(list[#list]) end

  base.forget(root)
  base.set(root, "main")
  base.set_dir(root, "")

  local saved
  scope.open({ on_save = function(r) saved = r end })
  wait_for(function() return scope.get() ~= nil end, "the panel to open")
  local p = scope.get()

  local lines = vim.tbl_map(function(l)
    return (vim.trim(l):gsub("%s+", " "))
  end, vim.api.nvim_buf_get_lines(p.buf, 0, -1, false))
  ok(contains(lines, "base main"), "the panel opens on what is in force, got "
    .. vim.inspect(lines))
  ok(contains(lines, "subtree (the whole repository)"),
    "with no subtree spelled out rather than left blank -- all of it is an answer")

  -- `q` puts every other float here away without doing anything, so it
  -- must not be the key that commits this one.
  local bound = {}
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(p.buf, "n")) do
    bound[m.lhs] = m.callback
  end
  eq(bound["q"], scope.close, "q discards")
  eq(bound["<C-S>"] or bound["<C-s>"], scope.save, "and <C-s> is what saves")

  -- Each entry answered on its own, through the picker and the prompt
  -- that entry's question already had.
  scope.move(0)
  answer = "feature/math"
  scope.edit()
  wait_for(function() return scope.get().pending.base == "feature/math" end,
    "the base to be taken")
  scope.move(1)
  answer = "util"
  scope.edit()
  wait_for(function() return scope.get().pending.dir == "util" end,
    "the subtree to be taken")

  -- ...and neither of them applied. This is the whole reason it is a
  -- panel: two answers are held together until the reader has looked at
  -- the pair, and a mind changed about the second must not have to undo
  -- the first.
  eq(base.current(root), "main", "nothing is in force while the panel is open")
  eq(base.dir(root), "", "on either row")

  local shown = vim.tbl_map(function(l)
    return (vim.trim(l):gsub("%s+", " "))
  end, vim.api.nvim_buf_get_lines(p.buf, 0, -1, false))
  ok(contains(shown, "base feature/math") and contains(shown, "subtree util/"),
    "though the panel says what it is holding, got " .. vim.inspect(shown))

  scope.save()
  ok(scope.get() == nil, "closing puts the panel away")
  eq(base.current(root), "feature/math", "and both answers land at once")
  eq(base.dir(root), "util", "the subtree with the base")
  eq(saved, root, "with whatever is on screen told to follow")

  -- Backing out takes nothing with it.
  saved = nil
  scope.open({ on_save = function(r) saved = r end })
  wait_for(function() return scope.get() ~= nil end, "the panel to open again")
  scope.move(1)
  answer = ""
  scope.edit()
  wait_for(function() return scope.get().pending.dir == "" end, "the subtree to be cleared")
  scope.close()
  eq(base.dir(root), "util", "discarding leaves what was in force alone")
  ok(saved == nil, "and asks nothing to follow it")

  prompt.open, vim.ui.select = real_open, real_select
  base.forget(root)
  base.set(root, "main")
  base.set_dir(root, "")
end

print("\n[the prompt that completes]")
-- The window itself: one line, in a float, completing the list it was
-- handed. Asserted through the mappings it binds rather than by feeding
-- keys -- headless has no insert mode to press them in.
do
  local prompt = require("uatis.prompt")
  local items = {
    { word = "main", kind = "branch" },
    { word = "feature/math", kind = "branch" },
    { word = "origin/feature/math", kind = "remote" },
    { word = "v0.1", kind = "tag" },
    { word = "a1b2c3d", kind = "commit", menu = "widen the pane on a narrow window" },
  }

  local function words(list)
    return vim.tbl_map(function(item) return item.word end, list)
  end

  local answer = "unset"
  local win = prompt.open({ prompt = "uatis: base revision", items = items },
    function(text) answer = text end)
  local buf = vim.api.nvim_win_get_buf(win)
  eq(vim.api.nvim_win_get_config(win).relative, "editor", "the prompt is a float")
  eq(vim.api.nvim_buf_line_count(buf), 1, "one line to type on")

  -- Completion is `omnifunc`, so it answers the two questions the
  -- completion machinery asks: where the word starts, and what matches.
  eq(vim.bo[buf].omnifunc, "v:lua.require'uatis.prompt'.omnifunc",
    "with completion bound to the buffer")
  eq(prompt.omnifunc(1, ""), 0,
    "the word being completed is the whole line -- a revision holds slashes")
  eq(words(prompt.omnifunc(0, "math")), { "feature/math", "origin/feature/math" },
    "a name is matched anywhere in a ref, not only at its start")
  eq(words(prompt.omnifunc(0, "v0")), { "v0.1" }, "tags complete too")
  eq(words(prompt.omnifunc(0, "nothing-like-this")), {}, "and nothing matches nothing")
  -- Prefix matches first: when what is typed does start a name, that is
  -- the name being typed towards.
  eq(prompt.omnifunc(0, "feature")[1].word, "feature/math",
    "a ref the text starts is offered before one that merely contains it")
  -- A commit is a sha nobody has memorised, so it is found by what it
  -- did -- and it says so in the menu beside it.
  eq(words(prompt.omnifunc(0, "narrow window")), { "a1b2c3d" },
    "a commit is matched on its subject line")
  eq(prompt.omnifunc(0, "narrow window")[1].kind, "commit",
    "and the menu says which kind of thing it is")
  -- Nothing typed yet: every kind gets a look in. A flat list of the
  -- first N in a repository with three hundred branches is three hundred
  -- branches, and the tags may as well not be offered.
  local empty = {}
  for _, item in ipairs(prompt.omnifunc(0, "")) do
    empty[item.kind] = true
  end
  ok(empty.branch and empty.tag and empty.remote and empty.commit,
    "with nothing typed, each kind is represented")

  -- The menu comes up as the line changes rather than on a key: `<Tab>`
  -- in insert mode belongs to whichever completion engine the reader
  -- installed, and a prompt that completes only when it wins that race
  -- is a prompt that silently does not complete.
  ok(#vim.api.nvim_get_autocmds({ event = "TextChangedI", buffer = buf }) > 0,
    "the menu is driven by the line changing")
  eq(vim.bo[buf].completeopt, "menuone,noselect",
    "and it is shown without taking a word nobody chose")
  eq(vim.b[buf].completion, false,
    "with the engines that watch every buffer told to stay out of this one")

  local cr = vim.fn.maparg("<CR>", "n", false, true)
  ok(cr and cr.callback ~= nil and cr.buffer == 1, "<CR> is bound in the prompt")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "  v0.1  " })
  cr.callback()
  wait_for(function() return answer ~= "unset" end, "the prompt to answer")
  eq(answer, "v0.1", "what was typed comes back, trimmed")
  ok(not vim.api.nvim_win_is_valid(win), "and the window is gone with it")

  answer = "unset"
  win = prompt.open({ prompt = "uatis: base revision", items = items },
    function(text) answer = text end)
  local esc = vim.fn.maparg("<Esc>", "n", false, true)
  ok(esc and esc.callback ~= nil, "<Esc> is bound in the prompt")
  esc.callback()
  wait_for(function() return answer ~= "unset" end, "the prompt to be dismissed")
  ok(answer == nil, "which answers nothing at all")
  ok(not vim.api.nvim_win_is_valid(win), "and takes its window away")
end

print("\n[what checkhealth can say about this repository]")
-- The three binaries were never the whole story: "the pane says nothing
-- changed" has as many causes in the repository as in the plugin -- no
-- base branch to be found, a fork point that IS HEAD, a `git diff` the
-- reader's own config rewrites. Gathered as data so this can check the
-- questions being asked; `vim.health` has nowhere to put an answer a
-- test can read.
do
  local health = require("uatis.health")
  local f = health.facts(fixture)

  eq(f.root, fixture, "the repository is found from a directory inside it")
  ok(f.head ~= nil and f.head ~= "", "and which branch it has out, got " .. tostring(f.head))
  eq(f.base, require("uatis.base").current(fixture) or "main", "the base a review here would take")
  ok(f.fork_point ~= nil and #f.fork_point == 40,
    "resolved to the fork point it would measure against, got " .. tostring(f.fork_point))
  ok(f.fork_point ~= f.head_sha,
    "which on a branch with work on it is not HEAD")

  -- What the reader's own git config does to `git diff`, reported
  -- because it is the first thing to look at when a list is empty --
  -- and reported honestly, without the overrides this plugin passes on
  -- every call being read back as if the repository had asked for them.
  vim.fn.system({ "git", "-C", fixture, "config", "diff.noprefix", "true" })
  local hostile = health.facts(fixture)
  eq(hostile.diff_config["diff.noprefix"], "true",
    "a setting that rewrites the diff is named")
  ok(hostile.diff_config["core.quotepath"] == nil,
    "while the overrides uatis passes itself are not reported as the repo's, got "
      .. tostring(hostile.diff_config["core.quotepath"]))
  vim.fn.system({ "git", "-C", fixture, "config", "--unset", "diff.noprefix" })

  local nowhere = health.facts(vim.fn.tempname())
  ok(nowhere.root == nil, "and outside a repository there is nothing to report")
end

print("\n[setup(opts)]")
-- The options a user actually writes. The merge goes INTO the live config
-- table -- every module took its reference at require time -- so this
-- section deep-copies it first and puts it back at the end: everything
-- below reads the same table.
do
  local cfg = require("uatis.config")
  local defaults = vim.deepcopy(cfg)

  -- mapleader is unset under `-u NONE`, so <leader> is a backslash.
  local function mapping(lhs)
    return vim.fn.maparg((lhs:gsub("<leader>", "\\")), "n", false, true) or {}
  end

  uatis.setup({
    pane = { auto_open = false },
    base = { fallbacks = { "trunk" } },
    keys = { global = { toggle_diff = "<leader>zz", base_branch = false } },
  })

  eq(cfg.pane.auto_open, false, "an option that is named is taken")
  eq(cfg.list.width, defaults.list.width, "one that is not keeps its default")
  eq(cfg.keys.view.hunk_next, defaults.keys.view.hunk_next,
    "including the neighbours of one that is, at every depth")
  eq(cfg.diff.line.algorithm, defaults.diff.line.algorithm, "and three deep")
  eq(cfg.base.fallbacks, { "trunk" },
    "a list replaces the one underneath rather than merging into it by index")

  -- Merge or replace is decided by the default, not by what was written:
  -- an empty table against a list means an empty list, and against a
  -- table of settings it means none of them.
  uatis.setup({ base = { fallbacks = {} }, keys = { view = {} } })
  eq(cfg.base.fallbacks, {}, "so a list can be emptied")
  eq(cfg.keys.view.hunk_next, defaults.keys.view.hunk_next,
    "while an empty table of settings changes none of them")

  ok(mapping("<leader>zz").callback ~= nil, "a global key moves to where it was put")
  ok(next(mapping(defaults.keys.global.toggle_diff)) == nil,
    "and does not stay bound where it was")
  ok(next(mapping(defaults.keys.global.base_branch)) == nil,
    "false unbinds one, for anyone who would rather bind the function")

  -- A key the defaults do not have is a typo. Accepted in silence it looks
  -- like a setting that had no effect.
  local warned, real = {}, vim.notify
  vim.notify = function(msg) table.insert(warned, msg) end
  uatis.setup({ pane = { auto_opne = true }, nonsens = 1 })
  vim.notify = real
  ok(contains(warned, "'pane.auto_opne'"), "a misspelt option says so, with its path")
  ok(contains(warned, "'nonsens'"), "and so does a misspelt table")
  ok(rawget(cfg, "nonsens") == nil and rawget(cfg.pane, "auto_opne") == nil,
    "neither of which is written into the config")

  for k in pairs(cfg) do
    cfg[k] = nil
  end
  for k, v in pairs(defaults) do
    cfg[k] = v
  end
  uatis.setup()
  ok(mapping(defaults.keys.global.toggle_diff).callback ~= nil
    and next(mapping("<leader>zz")) == nil,
    "and the defaults come back, with what the last call bound taken down")
end

print("\n[completing :Uatis]")
-- The command line asks the same question the base prompt does, so it
-- offers the same candidates -- and, unlike the prompt, it has to answer
-- now: a completion that arrives after the reader has stopped pressing
-- <Tab> is not an answer, it is a command that does not complete.
do
  local first = uatis.complete("")
  ok(contains(first, "main"), "the very first press already knows the branches")
  ok(contains(first, "v0.1"), "and the tags, got " .. table.concat(first, ", "))
  local bare_shas = 0
  for _, word in ipairs(first) do
    if word:match("^%x%x%x%x%x%x%x+$") then
      bare_shas = bare_shas + 1
    end
  end
  eq(bare_shas, 0, "and no bare hashes, which would bury them")

  local narrowed = uatis.complete("feature/m")
  eq(narrowed[1], "feature/math", "a lead narrows to what it starts")

  -- Commits are candidates here for the reason they are in the prompt --
  -- a base is often a commit nobody has memorised -- but only for a lead
  -- that looks like a sha: the command line has no menu column to put a
  -- subject line in, and a thousand bare hashes would bury the branches.
  local sha = vim.trim(vim.fn.system({ "git", "-C", fixture, "rev-parse", "--short", "HEAD" }))
  local hex = uatis.complete(sha:sub(1, 4))
  ok(contains(hex, sha), "a lead that looks like a sha completes commits, got "
    .. table.concat(hex, ", "))
  local plain = uatis.complete("m")
  for _, word in ipairs(plain) do
    ok(not word:match("^%x%x%x%x%x%x%x$") or word == "main",
      "while an ordinary lead offers refs alone, got " .. word)
  end
  ok(contains(plain, "main"), "and finds the branch it was typed towards")
end

print("\n[what a statusline can ask for]")
-- The winbar belongs to the window a review is in. A reader who wants
-- the same numbers in lualine had no way to them that did not mean
-- reaching into `view.lua`, whose field names are nobody else's to
-- depend on. These two answer in plain data.
do
  vim.cmd("silent! only")
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
  local buf = vim.api.nvim_get_current_buf()
  if view_mod.get(buf) then
    view_mod.stop(view_mod.get(buf))
  end
  uatis.toggle_diff()
  wait_for(function()
    local v = view_mod.get(buf)
    local p = pane_mod.get()
    return v ~= nil and (v.renders or 0) > 0 and p ~= nil and (p.renders or 0) > 0
  end, "a review to ask about")

  local st = uatis.status(buf)
  ok(st ~= nil, "a buffer being compared answers")
  eq(st and st.path, "calc.lua", "with where it is in the repository")
  ok(st and st.added > 0 and st.removed > 0,
    "and what changed in it, got +" .. tostring(st and st.added)
      .. " -" .. tostring(st and st.removed))
  eq(st and st.base, "main", "named for what it is measured against")
  eq(st and st.rev, (view_mod.get(buf) or {}).rev, "and the revision that resolved to")
  ok(st and st.tracks_base == true, "which follows the base branch, having not been pinned")
  ok(st and (st.backend == "struct" or st.backend == "line"),
    "the backend is one of the two, got " .. tostring(st and st.backend))
  eq(st and st.layout, "inline", "and the layout is where a view starts")

  local rv = uatis.review()
  ok(rv ~= nil, "and the review itself answers separately")
  eq(rv and rv.base, "main", "against the same base")
  ok(rv and rv.files > 1, "over every file of the branch, got " .. tostring(rv and rv.files))
  ok(rv and rv.added >= (st and st.added or 0),
    "whose totals cover this file's own")
  ok(rv and rv.window == true, "and it says the list has a window up")

  eq(st and st.pending, false, "and nothing is still being waited for")

  -- ...and which side of the comparison a buffer is, which is what an
  -- outside tool has to know before it can say anything about the line
  -- under the cursor. A line this branch deleted is in no buffer but
  -- the one `<leader>go` opens.
  local sh = uatis.showing(buf)
  eq(sh and sh.side, "new", "the buffer being annotated is the new side")
  eq(sh and sh.path, "calc.lua", "named as the repository names it")
  eq(sh and sh.rev, (view_mod.get(buf) or {}).rev, "at the revision being compared against")
  eq(sh and sh.root, (view_mod.get(buf) or {}).root, "in the repository it belongs to")

  require("uatis.oldside").open(view_mod.get(buf))
  wait_for(function()
    local v2 = view_mod.get(buf)
    return v2 and v2.old and v2.old.buf ~= nil and vim.api.nvim_buf_is_valid(v2.old.buf)
  end, "the old side to open")
  local old_buf = view_mod.get(buf).old.buf
  local os_ = uatis.showing(old_buf)
  eq(os_ and os_.side, "old", "and the window beside it is the old one")
  eq(os_ and os_.path, "calc.lua", "showing the same file")
  eq(os_ and os_.rev, (view_mod.get(buf) or {}).rev, "at the revision it is being compared with")
  require("uatis.oldside").close(view_mod.get(buf))

  -- A structural diff is a subprocess, and a file it has not answered
  -- about yet looks exactly like a file with nothing in it: no marks, no
  -- counts, a header naming a backend as though it had spoken. Both
  -- answers say which of the two it is.
  local v = view_mod.get(buf)
  v.pending = true
  local bar = require("uatis.ui").view_winbar_text(v, 200)
    :gsub("%%#[%w]*#", ""):gsub("%%%*", ""):gsub("%%<", "")
  ok(bar:find("comparing", 1, true) ~= nil,
    "the header says a comparison is running, got:" .. bar)
  ok(bar:find("structural", 1, true) == nil,
    "rather than naming a backend that has not answered, got:" .. bar)
  eq(uatis.status(buf).pending, true, "and a statusline can ask the same thing")
  v.pending = false

  -- A buffer nothing is being compared in says so by saying nothing.
  vim.cmd("enew")
  ok(uatis.status(vim.api.nvim_get_current_buf()) == nil,
    "a buffer with no comparison answers nil")

  uatis.toggle_diff()
  wait_for(function() return pane_mod.get() == nil end, "the review to end")
  ok(uatis.review() == nil, "and with the review over, so does the review")
end

print("\n[the global keys]")
do
  uatis.setup()
  -- Brackets and case taken out: a description marks its key letter,
  -- `[G]it - [L]og of ...`, and the words are what is asserted on.
  local function plain(d)
    return (d or ""):gsub("[%[%]]", ""):lower()
  end
  local function desc(lhs)
    return plain((vim.fn.maparg(lhs, "n", false, true) or {}).desc)
  end
  -- Read from the config rather than written out here: these are the
  -- user's to change, and a test that hardcodes them fails for the one
  -- reason that is not a bug. mapleader is unset under `-u NONE`, so
  -- <leader> is a backslash.
  local k = require("uatis.config").keys.global
  local function lhs(name)
    return (k[name]:gsub("<leader>", "\\"))
  end
  ok(desc(lhs("base_branch")):find("base branch", 1, true) ~= nil,
    k.base_branch .. " sets the base branch")
  ok(desc(lhs("toggle_diff")):find("diff view", 1, true) ~= nil,
    k.toggle_diff .. " toggles the diff view")
  -- The two questions about history, one key apart: what a commit did,
  -- and what has happened since one. Both global, since neither is
  -- asked from inside a review.
  ok(desc(lhs("show_commit")):find("one commit", 1, true) ~= nil,
    k.show_commit .. " shows one commit on its own")
  ok(desc(lhs("since_commit")):find("since", 1, true) ~= nil,
    k.since_commit .. " reviews everything changed since a revision")
  -- ...and the third: everything that ever happened to one file, or
  -- from Visual mode to the lines selected in it.
  ok(desc(lhs("history")):find("this file", 1, true) ~= nil,
    k.history .. " reads the history of this file")
  ok(desc(lhs("at")):find("project as it was", 1, true) ~= nil,
    k.at .. " opens the project as it was at a revision")
  ok(plain((vim.fn.maparg(lhs("history"), "x", false, true) or {}).desc)
    :find("these lines", 1, true) ~= nil,
    "and in Visual mode, of the lines selected")
end

print("\n[diff view against the base branch]")
local view_buf, view
do
  vim.cmd("tabnew")
  -- On its own tab, and the only tab. Earlier sections leave calc.lua on
  -- screen elsewhere, and a buffer that is still visible in another window
  -- keeps its view when you edit past it -- which is right, and would make
  -- everything below depend on what happened to run before it.
  vim.cmd("silent! tabonly!")
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
  view_buf = vim.api.nvim_get_current_buf()
  -- Re-reading a file no longer ends the review on it -- which is the
  -- point of that, and not what this section is about. Any review an
  -- earlier one left here is stopped by hand, so what follows is about
  -- the one opened below.
  local stale = view_mod.get(view_buf)
  if stale then
    view_mod.stop(stale)
  end

  uatis.toggle_diff()
  wait_for(function()
    local v = view_mod.get(view_buf)
    return v ~= nil and (v.renders or 0) > 0
  end, "a diff view against the base branch")
  view = view_mod.get(view_buf)

  eq(view.ref, "main", "the view names the base branch")
  eq(view.rev, git_out("merge-base", "main", "HEAD"), "and measures against the fork point")
  ok(view.added > 0 and view.removed > 0, "and finds the branch's changes")
  ok(vim.bo[view_buf].buftype == "" and vim.bo[view_buf].modifiable,
    "the buffer stays your own file")

  -- The list comes up with it: "what have I changed" is a question about
  -- the branch and not about one file, and the answer to "which file
  -- next" should be on screen before you ask for it.
  wait_for(function()
    local p = pane_mod.get()
    return p ~= nil and (p.renders or 0) > 0
  end, "the changed-file list to come up with the view")
  ok(pane_mod.get() ~= nil, "turning the view on puts the file list up")
  eq(vim.api.nvim_get_current_win(), vim.fn.win_getid(),
    "without taking the cursor into it")
  ok(view_mod.get(vim.api.nvim_get_current_buf()) ~= nil,
    "the cursor is still in the file you were reading")

  -- ...and off, for the sections below, which test the explicit paths.
  require("uatis.config").pane.auto_open = false
  pane_mod.close(pane_mod.get())
  ok(pane_mod.get() == nil, "closed again for the checks below")
end

print("\n[changing the base branch moves what is open]")
-- Choosing a base branch is choosing what you are comparing against, so
-- the views and the list already on screen follow it. One left measuring
-- against the branch you stopped comparing to would be answering the
-- question you stopped asking -- and a list beside a view measuring
-- something else is the disagreement this plugin exists not to have.
do
  -- The view from the section above is still on calc.lua, against main.
  -- Its list back, so both halves are on screen to be moved.
  pane_mod.open({ focus = false })
  wait_for(function()
    local p = pane_mod.get()
    return p ~= nil and (p.renders or 0) > 0
  end, "the list back beside the view")
  local list = pane_mod.get()
  eq(list.ref, "main", "the list is against the base branch too")
  ok(#list.files > 0, "and has the branch's files in it")

  -- Side by side as well, because the old window's buffer is NAMED for
  -- the revision it holds -- and a name is a claim that has to keep up.
  local code_win = vim.api.nvim_get_current_win()
  local k = require("uatis.config").keys.view
  local function layout()
    local m = vim.fn.maparg(k.layout, "n", false, true)
    ok(m and m.callback ~= nil, "the view binds " .. k.layout)
    if m and m.callback then
      m.callback()
    end
  end
  layout()
  wait_for(function() return require("uatis.oldside").is_open(view) end,
    "the old revision in a window of its own")
  local function old_name()
    return vim.api.nvim_buf_get_name(view.old.buf)
  end
  eq(old_name(), "uatis://main/calc.lua", "which is named for the revision it holds")

  -- A view pointed at a revision BY NAME, in a window of its own. It was
  -- not following the base branch and must not start now.
  vim.cmd("vsplit " .. vim.fn.fnameescape(fixture .. "/helper.lua"))
  local named_buf = vim.api.nvim_get_current_buf()
  uatis.run({ fargs = { "main" } })
  wait_for(function()
    local v = view_mod.get(named_buf)
    return v ~= nil and (v.renders or 0) > 0
  end, "a view named at a ref by hand")
  local named = view_mod.get(named_buf)
  local named_rev = named.rev

  local renders = view.renders
  uatis.set_base_branch("feature/math")
  wait_for(function()
    return view.ref == "feature/math" and (view.renders or 0) > renders
  end, "the open view to follow the new base branch")
  eq(view.ref, "feature/math", "the view names the branch just chosen")
  -- HEAD is feature/math, so its fork point with itself is HEAD: nothing
  -- has changed since it, which is the point -- the numbers move because
  -- the comparison did.
  eq(view.rev, git_out("merge-base", "feature/math", "HEAD"),
    "and measures against the new fork point")
  ok((view.renders or 0) > renders, "and redraws rather than waiting to be asked")

  wait_for(function() return list.ref == "feature/math" end,
    "the list to follow it as well")
  eq(list.rev, view.rev, "the list moves with it, to the same revision")
  wait_for(function() return #list.files == 0 end, "the list to be re-read")
  eq(#list.files, 0, "and lists nothing changed since it")

  eq(old_name(), "uatis://feature/math/calc.lua",
    "and the old window is renamed for the revision it now holds")

  eq(named.ref, "main", "a view named at a ref by hand stays where it was put")
  eq(named.rev, named_rev, "against the revision that was named")

  -- ...and back, which is the same move in the other direction: the
  -- sections below are about the branch against main.
  uatis.set_base_branch("main")
  wait_for(function() return view.ref == "main" and list.ref == "main" end,
    "the base branch to be put back")
  eq(view.rev, git_out("merge-base", "main", "HEAD"),
    "choosing the old one back restores the old fork point")
  wait_for(function() return #list.files > 0 end, "the list to fill again")
  ok(#list.files > 0, "and the list fills again")

  view_mod.close(named_buf)
  vim.api.nvim_set_current_win(code_win)
  layout()
  pane_mod.close(list)
  vim.cmd("silent! only")
  vim.cmd("buffer " .. view_buf)
  ok(pane_mod.get() == nil and view_mod.get(view_buf) ~= nil,
    "closed again for the checks below")
end

print("\n[:Uatis]")
-- The command and the Lua API are not two ways to one thing -- a command
-- is what you type when you already know the ref -- but they do have to
-- end in the same place.
do
  require("uatis.config").pane.auto_open = true
  vim.cmd("silent! only")
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
  local buf = vim.api.nvim_get_current_buf()

  uatis.run({ fargs = { "main" } })
  wait_for(function()
    local v = view_mod.get(buf)
    return v ~= nil and (v.renders or 0) > 0
  end, "a view from :Uatis main")
  eq((view_mod.get(buf) or {}).ref, "main", ":Uatis <ref> compares against that ref")

  -- The list comes up here too. It is the same `on_open` the base-branch
  -- path uses, and it has to be reached by a local defined ABOVE the
  -- function that passes it -- one defined below is not a local at all,
  -- it is a nil global, and the pane silently never opens.
  wait_for(function()
    local p = pane_mod.get()
    return p ~= nil and (p.renders or 0) > 0
  end, "the file list to come up with it")
  ok(pane_mod.get() ~= nil, ":Uatis puts the file list up as well")

  local listed = pane_mod.get()
  eq(listed.ref, "main", "against the ref that was named")
  local against_main = #listed.files
  ok(against_main > 0, "listing what that ref changed, got " .. against_main)

  -- Naming another revision annotates the buffer and leaves the review
  -- alone: a view pointed by hand is meant to sit beside a list
  -- measuring something else, which is what the base-branch section
  -- above relies on.
  uatis.run({ fargs = { "feature/math" } })
  wait_for(function()
    local v = view_mod.get(buf)
    return v ~= nil and v.ref == "feature/math" and (v.renders or 0) > 0
  end, "the view to go to the ref that was named")
  eq(pane_mod.get().ref, "main", "while the list stays where it was")

  -- ...but asking for the list FROM that buffer re-reads it there. The
  -- list and the view under the cursor have to agree -- that is what
  -- `with_list` is for -- and taking the window away and putting it back
  -- is exactly what a reader does when the pane looks stale beside a
  -- buffer full of marks.
  pane_mod.hide(pane_mod.get())
  pane_mod.open({ focus = false })
  wait_for(function()
    local p = pane_mod.get()
    return p ~= nil and p.ref == "feature/math" and (p.renders or 0) > 0
  end, "the list to be re-read where the cursor is")
  eq(pane_mod.get().ref, "feature/math", "the list goes where the view went")
  eq(#pane_mod.get().files, 0,
    "and says what THAT revision changed -- here, nothing")
  -- `feature/math ← feature/math` and not `← working tree`: the fixture
  -- is checked out on that branch with nothing edited, so the new side
  -- of the comparison IS the branch and the header names it.
  eq(vim.trim(vim.api.nvim_buf_get_lines(pane_mod.get().list_buf, 0, 1, false)[1]),
    "feature/math ← feature/math", "with the header saying so")

  -- Put back, so what follows is a view and a list against main.
  uatis.run({ fargs = { "main" } })
  wait_for(function()
    local v = view_mod.get(buf)
    return v ~= nil and v.ref == "main"
  end, "the view back against main")

  -- The view stays: what follows is about a pane opened over one. Only
  -- the automatic opening goes, since those sections test the key.
  require("uatis.config").pane.auto_open = false
  pane_mod.close(pane_mod.get())
end

print("\n[the commits of a review]")
-- What a review is made of, one commit at a time: the list a reader
-- steps through, and what each of those commits did on its own.
do
  local git = require("uatis.git")
  local patch = require("uatis.patch")
  local fork = vim.trim(vim.fn.system({ "git", "-C", fixture, "merge-base", "main", "HEAD" }))

  local commits
  git.commits_between(fixture, fork, "HEAD", function(list) commits = list end)
  wait_for(function() return commits ~= nil end, "the commits of the branch")
  ok(#commits >= 3, "the branch's own commits are listed, got " .. #commits)

  -- Oldest first: that is the order the work happened in, and the order
  -- `12/17` has to count in for the number to mean anything.
  local subjects = vim.tbl_map(function(c) return c.subject end, commits)
  eq(subjects[1], "fix sub argument order and add mul", "oldest first")
  eq(subjects[#subjects], "document clamp", "newest last")

  local newest = commits[#commits]
  ok(newest.short ~= nil and #newest.short >= 7, "each carries a short sha, got "
    .. tostring(newest.short))
  ok(newest.date:match("^%d%d%d%d%-%d%d%-%d%d$") ~= nil,
    "the date it was made, got " .. tostring(newest.date))
  ok(newest.author ~= nil and newest.author ~= "", "and who made it, got "
    .. tostring(newest.author))

  -- ...and what one commit did, which is a range and not a comparison
  -- against the working tree: a commit is finished, and what it changed
  -- cannot depend on what is unsaved now.
  local text
  git.diff_range(fixture, newest.sha .. "^", newest.sha, function(out) text = out end)
  wait_for(function() return text ~= nil end, "the newest commit's own diff")
  local touched = vim.tbl_map(function(f) return f.path end, patch.parse(text))
  eq(touched, { "helper.lua" }, "one commit's diff names only the files it touched")

  -- An unsaved edit is invisible to it, unlike the review's own list.
  local scratch_path = fixture .. "/helper.lua"
  local disk = vim.fn.readfile(scratch_path)
  vim.fn.writefile(vim.list_extend({ "-- not part of any commit" }, vim.deepcopy(disk)),
    scratch_path)
  local again
  git.diff_range(fixture, newest.sha .. "^", newest.sha, function(out) again = out end)
  wait_for(function() return again ~= nil end, "the same commit read again")
  eq(again, text, "and says the same thing while the tree moves under it")
  vim.fn.writefile(disk, scratch_path)
end

print("\n[the side pane]")
local pane
do
  -- ]f with no list reads one, and puts no window up for it: the key
  -- asked which file comes next, not for somewhere to stand and look at a
  -- list. The list and the window onto it are separate things.
  local k = require("uatis.config").keys.view
  do
    local was_win = vim.api.nvim_get_current_win()
    local was_wins = #vim.api.nvim_tabpage_list_wins(0)
    local step = vim.fn.maparg(k.file_next, "n", false, true)
    ok(step and step.callback ~= nil and pane_mod.get() == nil,
      "]f is bound, and there is no list yet")
    if step and step.callback then
      step.callback()
    end
    wait_for(function()
      local p = pane_mod.get()
      return p ~= nil and (p.renders or 0) > 0
    end, "the list to be read")
    ok(pane_mod.get() ~= nil, "which reads one rather than refusing")
    eq(#vim.api.nvim_tabpage_list_wins(0), was_wins, "with no window put up for it")
    ok(pane_mod.get().list_win == nil, "the list has no window of its own")
    eq(vim.api.nvim_get_current_win(), was_win, "and the cursor stays where it was")
    pane_mod.close(pane_mod.get())
    ok(pane_mod.get() == nil, "closed again for the checks below")

    -- That press moved the list AND opened what it landed on, so put the
    -- file back: everything below is about a pane opened while reading
    -- calc.lua.
    vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
    -- Re-reading the file leaves a review on it running, so a view from
    -- an earlier section is stopped rather than waited past: `renders`
    -- is already above zero on that one, and waiting on it would go
    -- through before the revision below had been resolved.
    if view_mod.get(vim.api.nvim_get_current_buf()) then
      view_mod.stop(view_mod.get(vim.api.nvim_get_current_buf()))
    end
    view_mod.open("main", { resolve = require("uatis.base").resolve })
    wait_for(function()
      local v = view_mod.get(vim.api.nvim_get_current_buf())
      return v ~= nil and (v.renders or 0) > 0
    end, "the view back on calc.lua")
  end

  -- Opened from the view's own key, since that is where a reader reaches
  -- for it: the pane lists what changed since the revision the view is
  -- measured against, so it means nothing until one is open.
  local mapped = vim.fn.maparg(k.files, "n", false, true)
  ok(mapped and mapped.callback ~= nil, "the view binds " .. k.files)

  local before_wins = #vim.api.nvim_tabpage_list_wins(0)
  if mapped and mapped.callback then
    mapped.callback()
  end
  pane = pane_mod.get()
  ok(pane ~= nil, "and one in this buffer, a pane")
  wait_for(function() return (pane.renders or 0) > 0 end, "the pane to fill")

  eq(#vim.api.nvim_tabpage_list_wins(0), before_wins + 1, "which is one new window")
  pane_mod.open()
  eq(#vim.api.nvim_tabpage_list_wins(0), before_wins + 1, "and opening it again does not stack")

  local listed = vim.tbl_map(function(f) return f.status .. " " .. f.path end, pane.files)
  eq(listed, {
    "M calc.lua",
    "D doomed.lua",
    "A helper.lua",
    "R renamed_to.lua",
    "A util/strings.lua",
  }, "every file the branch touched, in path order")

  local lines = vim.api.nvim_buf_get_lines(pane.list_buf, 0, -1, false)
  ok(vim.trim(lines[1]) == "main ← feature/math",
    "the header names what is being compared, got: " .. vim.trim(lines[1] or ""))
  ok(vim.trim(lines[#lines - 1] or ""):find(require("uatis.config").keys.pane.help, 1, true)
    ~= nil or contains(vim.tbl_map(vim.trim, lines), "g? keys"),
    "the header offers one key for the rest, got " .. table.concat(lines, " | "))
  ok(offered(pane):find("<CR> open the file on this row", 1, true) ~= nil,
    "and that key lists the ones this pane actually has, got " .. offered(pane))

  -- ...and what it names on the right depends on whether the tree is
  -- still the branch. One unwritten character and it is not: the new
  -- side is the live buffer, git reads the disk, and a header that went
  -- on saying `feature/math` would be naming a revision that does not
  -- contain what is on screen.
  do
    -- The list's own window has the cursor by now, and its buffer is
    -- not modifiable. What has to be dirtied is the file.
    local buf = vim.fn.bufnr(fixture .. "/calc.lua")
    local was = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "-- typed, not written" })
    local seen = pane.renders or 0
    pane_mod.refresh(pane)
    wait_for(function() return (pane.renders or 0) > seen end, "the list to re-read")
    eq(vim.trim(vim.api.nvim_buf_get_lines(pane.list_buf, 0, 1, false)[1]),
      "main ← working tree", "an unsaved edit puts the working tree back in the header")

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, was)
    vim.bo[buf].modified = false
    seen = pane.renders or 0
    pane_mod.refresh(pane)
    wait_for(function() return (pane.renders or 0) > seen end, "the list to re-read again")
    eq(vim.trim(vim.api.nvim_buf_get_lines(pane.list_buf, 0, 1, false)[1]),
      "main ← feature/math", "and taking it back out names the branch again")
  end

  eq(pane.file_idx, 1, "the pane opens on the file you were reading")

  -- A review can be about part of the tree rather than all of it. The
  -- list then counts only what is under there, says so in the header,
  -- and draws every path relative to it -- a column of rows all
  -- beginning `util/` spends the pane's width saying nothing.
  do
    local base_mod = require("uatis.base")
    local ui = require("uatis.ui")
    local root = pane.root
    local was = base_mod.dir(root)

    base_mod.set_dir(root, "util")
    pane_mod.rescope(root, "util")
    eq(vim.tbl_map(function(f) return f.path end, pane_mod.get().files),
      { "util/strings.lua" }, "the list is only what is under the subtree")
    eq(vim.tbl_map(function(f) return ui.shown(f) end, pane_mod.get().files),
      { "strings.lua" }, "drawn relative to it")

    local scoped_lines = vim.api.nvim_buf_get_lines(pane.list_buf, 0, -1, false)
    eq(vim.trim(scoped_lines[2] or ""), "util/",
      "with the header saying how much of the tree this is")
    local squashed = vim.tbl_map(function(l)
      return (vim.trim(l):gsub("%s+", " "))
    end, scoped_lines)
    ok(contains(squashed, "A strings.lua +7 -0"),
      "and the row itself carrying the short path, got " .. vim.inspect(squashed))

    -- No git call is needed to take it off again: which files the branch
    -- touched has not changed, only how much of the answer is being read.
    base_mod.set_dir(root, was)
    pane_mod.rescope(root, was)
    eq(#pane_mod.get().files, 5, "and taking the scope off brings the rest back")
    eq(vim.trim(vim.api.nvim_buf_get_lines(pane.list_buf, 0, 2, false)[2] or ""),
      "5 files · +21 -4", "with no subtree row left in the header, got "
        .. vim.trim(vim.api.nvim_buf_get_lines(pane.list_buf, 0, 2, false)[2] or ""))
  end

  -- ]f/[f work from the file you are READING, not only from the pane
  -- listing them: moving between changed files is one activity, and which
  -- window you happen to be in is not part of it.
  vim.api.nvim_set_current_win(pane.code_win)
  local step = vim.fn.maparg(k.file_next, "n", false, true)
  ok(step and step.callback ~= nil, "the view binds " .. k.file_next)
  local was = vim.api.nvim_buf_get_name(0)
  local function press()
    if step and step.callback then
      step.callback()
    end
  end

  -- Next along is `doomed.lua`, which the branch deleted. It opens too --
  -- as the revision that had it, with nothing opposite -- so the window
  -- changes even though there is no file on disk to edit.
  press()
  eq(pane.file_idx, 2, "the list moves on")
  ok(vim.api.nvim_buf_get_name(0) ~= was
    and vim.api.nvim_buf_get_name(0):find("doomed.lua", 1, true) ~= nil,
    "and a file the branch deleted opens as what it was, got "
      .. vim.api.nvim_buf_get_name(0))

  press()
  eq(pane.file_idx, 3, "and again")
  ok(vim.api.nvim_buf_get_name(0):find("helper.lua", 1, true) ~= nil,
    "which opens the next changed file, got " .. vim.api.nvim_buf_get_name(0))
  ok(vim.api.nvim_get_current_win() == pane.code_win,
    "in the window you were reading in, not in the pane")
  wait_for(function()
    local v = view_mod.get(vim.api.nvim_get_current_buf())
    return v ~= nil and (v.renders or 0) > 0
  end, "the file opened from your own buffer to be annotated too")
end

print("\n[a file opened from the list]")
-- Pressing `<CR>` moves the row AND re-reads the list -- the file is read
-- off disk, and that is git's answer going stale for all the pane knows.
-- Which file to keep the row on used to be settled when the read was
-- REQUESTED, and the request goes out mid-way through opening the file,
-- at a moment when the row is still on the buffer the code window is
-- being entered with. Two subprocesses later it landed and put the row
-- back there -- so `]f` off a file just opened by hand stepped from the
-- file before it, and `[f` and `]c`'s spill into the next file, which
-- step from the same row, were out by one with it.
do
  local function index_of(path)
    for i, f in ipairs(pane.files) do
      if f.path == path then
        return i
      end
    end
  end
  local target = index_of("renamed_to.lua")
  ok(target ~= nil and pane.file_idx ~= target,
    "a row to open that is not the file already being read")

  local line
  for l, idx in pairs(pane.list_rows or {}) do
    if idx == target then
      line = l
    end
  end
  vim.api.nvim_set_current_win(pane.list_win)
  vim.api.nvim_win_set_cursor(pane.list_win, { line, 0 })
  local select = vim.fn.maparg(require("uatis.config").keys.pane.select,
    "n", false, true)
  ok(select and select.callback ~= nil, "the list binds <CR>")
  local seen = pane.renders or 0
  select.callback()
  ok(vim.api.nvim_buf_get_name(0):find("renamed_to.lua", 1, true) ~= nil,
    "which opens the file on that row, got " .. vim.api.nvim_buf_get_name(0))
  wait_for(function() return (pane.renders or 0) > seen end,
    "the re-read that opening it set off")
  eq(pane.file_idx, target, "and the row it landed on is the file just opened")

  local step = vim.fn.maparg(require("uatis.config").keys.view.file_next,
    "n", false, true)
  if step and step.callback then
    step.callback()
  end
  eq(pane.file_idx, target + 1, "so `]f` steps from there")
  ok(vim.api.nvim_buf_get_name(0):find("util/strings.lua", 1, true) ~= nil,
    "into the file after it, got " .. vim.api.nvim_buf_get_name(0))
end

print("\n[the pane resized]")
-- The rows are drawn to a width, and the width a reader gives the window
-- is the one they mean. Drawn to `config.list.width` whatever the window
-- had, a pane dragged wider went on cutting the same paths off at the
-- same column with empty space beside them -- and one dragged narrower
-- drew its rows past its own edge, where nvim simply stops showing them.
do
  local function rows()
    return vim.tbl_map(vim.trim,
      vim.api.nvim_buf_get_lines(pane.list_buf, 0, -1, false))
  end
  local full = rows()
  ok(contains(full, "A strings.lua"), "a path drawn in full at the width it opened at")

  vim.api.nvim_win_call(pane.list_win, function() vim.cmd("vertical resize 16") end)
  -- Fired by hand: `WinResized` comes from nvim's main loop, which a
  -- headless `-l` script never reaches. What is under test is that the
  -- pane listens for it and redraws to the window it actually has.
  vim.api.nvim_exec_autocmds("WinResized", { group = pane.augroup })
  eq(pane.list_width, 16, "a narrowed pane redraws to the width it now has")
  local cut = rows()
  ok(not contains(cut, "A strings.lua")
    and #(cut[1] or "") <= 16 and #(cut[#cut] or "") <= 16,
    "with every row inside it, got " .. vim.inspect(cut))

  vim.api.nvim_win_call(pane.list_win, function()
    vim.cmd("vertical resize " .. require("uatis.config").list.width)
  end)
  vim.api.nvim_exec_autocmds("WinResized", { group = pane.augroup })
  eq(pane.list_width, require("uatis.config").list.width,
    "and widening it again redraws too")
  eq(rows(), full, "with the paths it had been cutting off back in full")
end

print("\n[marking a chunk read]")
-- A review is finished a chunk at a time, and which chunks are behind
-- you is not something the plugin can work out from where the cursor
-- is: arriving at a change is not having read it. So `]c` marks the
-- chunk it moves AWAY from, and a file is read when every chunk of it
-- is -- the whole row going green then, status letter and churn with
-- it, those being how you decide what to open next and there being
-- nothing left to decide.
do
  local ui = require("uatis.ui")
  local read = require("uatis.read")
  local filelist = require("uatis.filelist")
  local cfg = require("uatis.config")
  local list_ns = vim.api.nvim_create_namespace("uatis_list")

  local function index_of(path)
    for i, f in ipairs(pane.files) do
      if f.path == path then
        return i
      end
    end
  end
  local function file(path)
    return pane.files[index_of(path)]
  end
  --- The highlight groups drawn on the row for `path`.
  local function groups(path)
    local line
    for l, idx in pairs(pane.list_rows or {}) do
      if pane.files[idx].path == path then
        line = l - 1
      end
    end
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(pane.list_buf, list_ns,
      { line, 0 }, { line, -1 }, { details = true })) do
      table.insert(out, m[4].hl_group)
    end
    return out
  end
  --- How many of `path`'s chunks are read, and how many it has.
  local function chunks_read(path)
    local f, n, of = file(path), 0, 0
    for _, c in ipairs(f.chunks) do
      of = of + 1
      if read.chunk_read(pane, f, c) then
        n = n + 1
      end
    end
    return n, of
  end

  -- The chunks are git's: one per hunk of the diff, with its own delta.
  -- calc.lua was changed in two places far enough apart to be two.
  local calc = file("calc.lua")
  eq(#calc.chunks, 2, "calc.lua's change is two chunks")
  eq(calc.chunks[1].added + calc.chunks[2].added, calc.added,
    "which between them are the file's delta")
  ok(calc.chunks[1].fp ~= calc.chunks[2].fp and #calc.chunks[1].fp == 64,
    "each with a fingerprint of its own content")
  eq(#file("doomed.lua").chunks, 1, "a deleted file is one chunk")
  eq(#file("renamed_to.lua").chunks, 1,
    "and a file git reported no hunks for is one chunk covering all of it")

  -- Bound in the list, so it is read from inside it: a bare `x` in
  -- somebody else's file is a real key, and this one is never lent there.
  vim.api.nvim_set_current_win(pane.list_win)
  local key = cfg.keys.pane.mark_read
  local m = vim.fn.maparg(key, "n", false, true)
  ok(m and m.callback ~= nil and m.buffer == 1,
    "the list binds " .. key .. ", and to its own buffer")
  --- Presses it on the row for `path`.
  local function press(path)
    local line
    for l, idx in pairs(pane.list_rows or {}) do
      if pane.files[idx].path == path then
        line = l
      end
    end
    vim.api.nvim_set_current_win(pane.list_win)
    vim.api.nvim_win_set_cursor(pane.list_win, { line, 0 })
    m.callback()
  end

  ok(not contains(groups("calc.lua"), "UatisRead"),
    "a file nobody has said anything about is drawn as any other")
  -- The cursor stays on the row that was pressed, which is not the
  -- current file's: the reader is about to press `j` to the next one.
  ok(index_of("calc.lua") ~= pane.file_idx, "calc.lua is not the file being read")
  press("calc.lua")
  eq((pane.list_rows or {})[vim.api.nvim_win_get_cursor(pane.list_win)[1]], index_of("calc.lua"),
    "and the list's cursor stays on the row pressed, not the current file's")
  eq({ chunks_read("calc.lua") }, { 2, 2 }, "`x` marks every chunk of the file read")
  ok(read.is_read(pane, calc), "which is what a read file is")
  eq(groups("calc.lua"), { "UatisRead", "UatisStatAdd", "UatisStatDel" },
    "letter and name in the read colour, the churn in its own -- a column of counts "
      .. "that went green whenever a row did could not be read down")

  press("calc.lua")
  eq({ chunks_read("calc.lua") }, { 0, 2 }, "and again takes them all back off")
  ok(contains(groups("calc.lua"), "UatisStatusM"),
    "with the row drawn as it was, got " .. vim.inspect(groups("calc.lua")))

  -- Half read is not read, and `x` on it completes rather than inverts:
  -- one press finishes a file with a chunk to go, the next takes the
  -- whole of it back.
  read.mark(pane, calc, { calc.chunks[1] }, true)
  filelist.render(pane)
  ok(not read.is_read(pane, calc) and not contains(groups("calc.lua"), "UatisRead"),
    "one chunk of two read is a file not yet read, and drawn so")
  press("calc.lua")
  eq({ chunks_read("calc.lua") }, { 2, 2 }, "`x` on it finishes it")
  press("calc.lua")
  eq({ chunks_read("calc.lua") }, { 0, 2 }, "and only then takes it back")

  -- A mark is on the chunk's CONTENT. A commit that rewrites one chunk
  -- of a file -- which is what a changed fingerprint is -- resets that
  -- chunk and leaves the other read; and a chunk edited back to what it
  -- was is the chunk that was read.
  press("calc.lua")
  local was_fp = calc.chunks[2].fp
  calc.chunks[2].fp = "0000"
  ok(read.chunk_read(pane, calc, calc.chunks[1]) and not read.chunk_read(pane, calc, calc.chunks[2]),
    "a chunk whose content moved stops being read, and the one beside it does not")
  ok(not read.is_read(pane, calc), "so the file is not read")
  calc.chunks[2].fp = was_fp
  ok(read.is_read(pane, calc), "and is again when the chunk is back")
  press("calc.lua")

  -- Over a selection, the rows are one set and one decision: a
  -- directory and a file inside it both selected is that file once, not
  -- that file twice and flipped back to where it began.
  do
    local function line_of(path, dir)
      for l, v in pairs(dir and pane.list_dirs or pane.list_rows) do
        if (dir and v == path) or (not dir and pane.files[v].path == path) then
          return l
        end
      end
    end
    vim.api.nvim_set_current_win(pane.list_win)
    local vm = vim.fn.maparg(key, "x", false, true)
    ok(vm and vm.callback ~= nil and vm.buffer == 1, "and binds it in Visual mode too")
    -- From the `util/` row down over the file inside it: both name
    -- strings.lua.
    vim.api.nvim_win_set_cursor(pane.list_win, { line_of("util", true), 0 })
    vim.cmd("normal! V")
    vim.api.nvim_win_set_cursor(pane.list_win, { line_of("util/strings.lua"), 0 })
    eq(vim.fn.mode(), "V", "a selection is on")
    vm.callback()
    eq(vim.fn.mode(), "n", "which the key leaves, as a key acting on one does")
    ok(read.is_read(pane, file("util/strings.lua")),
      "a directory and the file under it, both selected, is that file read once")
    vm = vim.fn.maparg(key, "x", false, true)
    -- ...and across files: everything in the range, decided as one.
    vim.api.nvim_win_set_cursor(pane.list_win, { line_of("calc.lua"), 0 })
    vim.cmd("normal! V")
    vim.api.nvim_win_set_cursor(pane.list_win, { line_of("util/strings.lua"), 0 })
    vm.callback()
    local all = true
    for _, f in ipairs(pane.files) do
      all = all and read.is_read(pane, f)
    end
    ok(all, "every row of a selection with something unread in it is read afterwards")
    vim.api.nvim_win_set_cursor(pane.list_win, { line_of("calc.lua"), 0 })
    vim.cmd("normal! V")
    vim.api.nvim_win_set_cursor(pane.list_win, { line_of("util/strings.lua"), 0 })
    vm.callback()
    local none = true
    for _, f in ipairs(pane.files) do
      none = none and not read.is_read(pane, f)
    end
    ok(none, "and a selection entirely read comes off as one")
  end

  -- A directory row stands for everything under it here as everywhere
  -- else in this list, so marking one completes the lot.
  do
    local flat = {
      root = "/nowhere", read = {},
      files = {
        { path = "lua/a.lua", status = "M", added = 3, removed = 1, hunks = {} },
        { path = "lua/deep/b.lua", status = "A", added = 40, removed = 0, hunks = {} },
        { path = "other.lua", status = "M", added = 2, removed = 7, hunks = {} },
      },
    }
    local function state()
      return vim.tbl_map(function(g) return read.is_read(flat, g) end, flat.files)
    end
    pane_mod.toggle_read_dir(flat, "lua")
    eq(state(), { true, true, false },
      "a directory takes everything under it, nested included, and nothing beside it")
    flat.read["lua/a.lua"] = nil
    pane_mod.toggle_read_dir(flat, "lua")
    eq(state(), { true, true, false }, "one half-read completes rather than inverting")
    pane_mod.toggle_read_dir(flat, "lua")
    eq(state(), { false, false, false }, "and entirely read, it comes off")
  end

  -- ...and the directory row says so itself, which is what makes folding
  -- a finished directory away worth doing.
  do
    local one = { path = "lua/a.lua", status = "M", added = 3, removed = 1, hunks = {} }
    local built = ui.build_list({
      target = "main", src = "working tree", hint = "", file_idx = 0,
      stat_added = 0, stat_removed = 0, collapsed = {},
      read = { ["lua/a.lua"] = { [read.fingerprint(read.chunks(one)[1])] = true } },
      files = { one },
    }, 38)
    local dir_line
    for line in pairs(built.dirs) do
      dir_line = line
    end
    local on_dir = {}
    for _, h in ipairs(built.hls) do
      if h.line == dir_line - 1 then
        table.insert(on_dir, h.hl)
      end
    end
    eq(on_dir, { "UatisRead" }, "a directory whose every file is read is drawn read too")
  end

  -- Read rows step back from the `+N` green rather than borrowing it: a
  -- finished row is the one thing on the list the eye should be able to
  -- pass over, and it cannot if it is as loud as a count still asking
  -- to be read.
  do
    local function fg(name)
      return vim.api.nvim_get_hl(0, { name = name, link = false }).fg
    end
    local function lum(c)
      return bit.rshift(c, 16) + bit.band(bit.rshift(c, 8), 0xff) + bit.band(c, 0xff)
    end
    local bg = vim.api.nvim_get_hl(0, { name = "Normal", link = false }).bg
    if fg("UatisStatAdd") and bg then
      ok(fg("UatisRead") ~= fg("UatisStatAdd"), "a read row is not the `+N` green")
      local towards = lum(bg) < lum(fg("UatisStatAdd")) and -1 or 1
      ok((lum(fg("UatisRead")) - lum(fg("UatisStatAdd"))) * towards > 0,
        "but that green stepped back towards the background")
    else
      print("  skip the read colour: the scheme has no ground to step back to")
    end
  end

  -- Then without a key at all: a chunk motion marks the chunk it moves
  -- away from, in either direction. Arriving at a change is not having
  -- read it.
  do
    local k = cfg.keys.view
    local calc_buf
    local function open_calc()
      vim.api.nvim_set_current_win(pane.code_win)
      -- A spill has just left calc.lua behind, and the view on it ends
      -- on the NEXT tick. Opened again inside this one, the arrival
      -- finds the old view still registered and attaches nothing, and
      -- the close then lands on a buffer that is back on screen. A
      -- reader cannot press two keys in one tick; a script can.
      if calc_buf and vim.api.nvim_win_get_buf(pane.code_win) ~= calc_buf then
        wait_for(function() return view_mod.get(calc_buf) == nil end,
          "the view left behind by the spill to end")
      end
      pane_mod.goto_file(pane, index_of("calc.lua"))
      local buf = vim.api.nvim_get_current_buf()
      calc_buf = buf
      wait_for(function()
        local v = view_mod.get(buf)
        return v ~= nil and (v.renders or 0) > 0 and #(v.anchors or {}) > 0
      end, "calc.lua to be annotated")
      return view_mod.get(buf)
    end
    local function press_key(lhs)
      local km = vim.fn.maparg(lhs, "n", false, true)
      if km and km.callback then
        km.callback()
      end
    end

    pane.read = {}
    local v = open_calc()
    eq(#v.anchors, 2, "the view stops twice in calc.lua, once per chunk")
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    press_key(k.hunk_next)
    eq({ chunks_read("calc.lua") }, { 0, 2 },
      "`]c` from the top of the file onto the first change marks nothing")
    press_key(k.hunk_next)
    eq({ chunks_read("calc.lua") }, { 1, 2 }, "`]c` off it onto the second marks the first")
    ok(read.chunk_read(pane, calc, calc.chunks[1]) and not read.is_read(pane, calc),
      "the first, and the file is not read on the strength of it")
    -- The file's own header says so.
    local bar = require("uatis.ui").view_winbar_text(v, 200)
      :gsub("%%#[%w]*#", ""):gsub("%%%*", ""):gsub("%%<", "")
    ok(bar:find("1/2 read", 1, true) ~= nil, "and the header counts it, got: " .. bar)
    -- In STOPS, not in git's chunks, though the marks are on the
    -- chunks. A lone unchanged row between two changes is one node to
    -- difftastic and two chunks to git: one stop, and the header read
    -- `0/2` until a single press took it to `2/2`. The stop is read
    -- when every chunk it stands on is.
    do
      local f = { path = "x.py", chunks = {
        { fp = "a", added = 1, removed = 1, start = 27, count = 1 },
        { fp = "b", added = 2, removed = 1, start = 29, count = 2 },
      } }
      local one = { { lo = 27, hi = 30, key = "s1" } }
      local marks = { read = {} }
      eq(read.stops_read(marks, f, one), { done = 0, total = 1 },
        "one stop over two chunks is one stop")
      read.mark(marks, f, { f.chunks[1] }, true)
      eq(read.stops_read(marks, f, one), { done = 0, total = 1 },
        "half its chunks read is not the stop read")
      read.mark(marks, f, { f.chunks[2] }, true)
      eq(read.stops_read(marks, f, one), { done = 1, total = 1 },
        "all of them is")
      eq(read.stops_read(marks, f, {}), nil, "and nothing to step is nothing to count")

      -- ...and the other way round: a hundred added lines is one chunk
      -- to git and, to a backend that found blank rows inside it, five
      -- stops. Marked when the first was left, the chunk took the other
      -- four with it -- the header jumped by five on one press and
      -- stood still on the next four. A chunk is marked once every stop
      -- on it has been left; until then the stops left count on their
      -- own.
      local big = { path = "y.py", chunks = {
        { fp = "c", added = 108, removed = 0, start = 609, count = 108 },
      } }
      local five = {
        { lo = 611, hi = 640, key = "k1" }, { lo = 643, hi = 646, key = "k2" },
        { lo = 649, hi = 653, key = "k3" }, { lo = 656, hi = 699, key = "k4" },
        { lo = 702, hi = 716, key = "k5" },
      }
      local m = { read = {}, left = { ["y.py"] = {} } }
      local left = m.left["y.py"]
      eq(read.leave(left, five, 1, big, 643), {}, "leaving the first of five marks no chunk")
      eq(read.stops_read(m, big, five), { done = 1, total = 5 }, "but counts as one stop left")
      read.leave(left, five, 2, big, 649)
      read.leave(left, five, 3, big, 656)
      read.leave(left, five, 4, big, 702)
      eq(read.stops_read(m, big, five), { done = 4, total = 5 }, "four, one press each")
      -- `[c` from below onto the last stop is an arrival, not a leaving.
      eq(read.leave(left, five, 5, big, 702), {}, "arriving at the fifth from below leaves nothing")
      eq(read.stops_read(m, big, five), { done = 4, total = 5 }, "and counts nothing")
      local marked = read.leave(left, five, 5, big, nil)
      eq(#marked, 1, "leaving the fifth, with nowhere to go, marks the chunk at last")
      read.mark(m, big, marked, true)
      eq(read.stops_read(m, big, five), { done = 5, total = 5 }, "and every stop is read")
      ok(read.is_read(m, big), "which is the file read")
      -- Marked from the list instead, every stop on the chunk is read at
      -- once: the mark is the chunk's, whichever way it was made.
      local fresh = { read = {} }
      read.mark(fresh, big, big.chunks, true)
      eq(read.stops_read(fresh, big, five), { done = 5, total = 5 },
        "a chunk marked from the list reads every stop on it")
    end
    press_key(k.hunk_prev)
    eq({ chunks_read("calc.lua") }, { 2, 2 }, "`[c` back off the second marks it too")
    press_key(k.hunk_next)
    press_key(k.hunk_next)
    eq({ chunks_read("calc.lua") }, { 2, 2 },
      "and `]c` off the last change, with nowhere left to go, leaves it read")
    ok(read.is_read(pane, calc), "and the file is read")
    ok(vim.api.nvim_buf_get_name(0):find("doomed.lua", 1, true) ~= nil,
      "on the way into the next file, got " .. vim.api.nvim_buf_get_name(0))

    -- Coming in at the last chunk and leaving marks that one alone: the
    -- rest of the file was never seen.
    pane.read = {}
    v = open_calc()
    vim.api.nvim_win_set_cursor(0, { v.anchors[#v.anchors], 0 })
    press_key(k.hunk_next)
    eq({ chunks_read("calc.lua") }, { 1, 2 }, "`]c` off the last chunk alone marks that chunk")
    ok(not read.is_read(pane, calc), "and not the file")

    -- Scrolled on past a change and pressed: the change being left is
    -- the last one above the cursor.
    pane.read = {}
    v = open_calc()
    vim.api.nvim_win_set_cursor(0, { math.min(v.anchors[1] + 1, v.anchors[2] - 1), 0 })
    press_key(k.hunk_next)
    ok(read.chunk_read(pane, calc, calc.chunks[1]),
      "`]c` from below a change, before the next, marks the one above")

    -- `[c` from the same place goes back ONTO that change: arriving,
    -- not leaving, and nothing is marked.
    pane.read = {}
    v = open_calc()
    vim.api.nvim_win_set_cursor(0, { math.min(v.anchors[1] + 1, v.anchors[2] - 1), 0 })
    press_key(k.hunk_prev)
    eq({ chunks_read("calc.lua") }, { 0, 2 }, "`[c` from below a change onto it marks nothing")
    eq(vim.api.nvim_win_get_cursor(0)[1], v.anchors[1], "having landed on it")
    -- ...and `[c` off the first change, with nothing before it, marks
    -- it: leaving is leaving whichever way.
    press_key(k.hunk_prev)
    ok(read.chunk_read(pane, calc, calc.chunks[1]),
      "`[c` off the first change, with nowhere to go, marks it")

    pane.read = {}
    cfg.pane.auto_read = false
    v = open_calc()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    for _ = 1, #v.anchors + 1 do
      press_key(k.hunk_next)
    end
    eq({ chunks_read("calc.lua") }, { 0, 2 },
      "`pane.auto_read = false` leaves the marking to the reader")
    cfg.pane.auto_read = true
  end

  -- What was read is read next time: the marks go to disk as they are
  -- made, per repository, and a list built later on the same one starts
  -- with them. Only the chunks the file still has are kept -- a chunk
  -- edited out from under its mark is not coming back in that shape.
  do
    pane.read = {}
    press("calc.lua")
    read.mark(pane, file("helper.lua"), file("helper.lua").chunks, true)
    pane.read["helper.lua"]["stale:0:0"] = true
    read.save(pane.root, pane.read, { file("helper.lua") })
    local again = read.load(pane.root)
    ok(again["calc.lua"] and again["calc.lua"][read.fingerprint(calc.chunks[1])]
      and again["calc.lua"][read.fingerprint(calc.chunks[2])],
      "a file marked from the list comes back from disk")
    ok(again["helper.lua"] and again["helper.lua"][read.fingerprint(file("helper.lua").chunks[1])]
      and not again["helper.lua"]["stale:0:0"],
      "with the fingerprints its chunks have and none they no longer do")
    ok(again["doomed.lua"] == nil, "and nothing for a file never marked")

    -- `remember_read = false` keeps nothing.
    local where = cfg.pane.remember_read
    cfg.pane.remember_read = false
    eq(read.load(pane.root), {}, "and off, a new list starts with nothing")
    cfg.pane.remember_read = where
  end

  pane.read = {}
  filelist.render(pane)
end

print("\n[how much of the review is behind you]")
-- `3/20` is not an answer to "how much is left" on a branch whose third
-- file is a nine-hundred-line generated blob. The foot of the pane
-- measures the review in delta LOC -- added AND removed, a line taken out
-- being as much to read as one put in -- over the chunks that are read,
-- and carries beside it how many files are read entirely.
do
  local ui = require("uatis.ui")
  local read = require("uatis.read")
  local filelist = require("uatis.filelist")

  local function file(path)
    for _, f in ipairs(pane.files) do
      if f.path == path then
        return f
      end
    end
  end
  --- What the pane's status line says with these chunks read:
  --- `{ path = { chunk indices } }`, or a path alone for all of it.
  local function foot(spec)
    pane.read = {}
    for path, which in pairs(spec) do
      if type(path) == "number" then
        path, which = which, nil
      end
      local f = file(path)
      local chunks = {}
      for i, c in ipairs(f.chunks) do
        if which == nil or vim.tbl_contains(which, i) then
          table.insert(chunks, c)
        end
      end
      read.mark(pane, f, chunks, true)
    end
    filelist.render(pane)
    return (vim.wo[pane.list_win].statusline:gsub("%%#%w+#", ""):gsub("%%%%", "%%"))
  end

  -- calc 8, doomed 2, helper 8, renamed_to 0, strings 7 -- 25 in all.
  local none = foot({})
  ok(none:find("0/5 · 0%", 1, true) ~= nil and none:find("█", 1, true) == nil,
    "nothing read is an empty bar, and says so, got " .. none)
  ok(foot({ "calc.lua" }):find("1/5 · 32%", 1, true) ~= nil,
    "one of five files is 32% of the delta and not a fifth of it, got "
      .. foot({ "calc.lua" }))
  ok(foot({ "calc.lua", "helper.lua" }):find("2/5 · 64%", 1, true) ~= nil,
    "and two of them 64%, got " .. foot({ "calc.lua", "helper.lua" }))

  -- A chunk counts on its own: one of calc.lua's two read is that
  -- chunk's share of the delta behind the reader, with no file finished.
  local calc = file("calc.lua")
  local share = calc.chunks[1].added + calc.chunks[1].removed
  local one = foot({ ["calc.lua"] = { 1 } })
  ok(one:find(("0/5 · %d%%"):format(math.floor(share / 25 * 100 + 0.5)), 1, true) ~= nil,
    "one chunk of a file read moves the bar and not the file count, got " .. one)

  -- The cursor is not progress: arriving at the last file of a branch is
  -- not having read the branch.
  local was_idx = pane.file_idx
  pane.file_idx = #pane.files
  ok(foot({}):find("0/5 · 0%", 1, true) ~= nil,
    "standing on the last file with nothing marked is still nothing read")
  pane.file_idx = was_idx

  local all = {}
  for _, f in ipairs(pane.files) do
    table.insert(all, f.path)
  end
  local full = foot(all)
  ok(full:find("5/5 · 100%", 1, true) ~= nil and full:find("░", 1, true) == nil,
    "and the whole review read fills it, got " .. full)

  local part = foot({ "calc.lua" })
  eq(vim.fn.strdisplaywidth(part), pane.list_width,
    "the row is drawn to the width the window has")
  ok(select(2, part:gsub("█", "")) > 0 and select(2, part:gsub("░", "")) > 0,
    "a review part read is drawn as neither nothing nor done, got " .. part)

  -- Too narrow for a bar the reader could read a proportion off, so the
  -- numbers say it alone rather than four blocks pretending to.
  local narrow = (ui.progress(pane, 14):gsub("%%#%w+#", ""):gsub("%%%%", "%%"))
  ok(narrow:find("1/5 · 32%", 1, true) ~= nil and narrow:find("█", 1, true) == nil,
    "a pane too narrow for a bar keeps the numbers, got " .. narrow)

  -- Nothing to measure but the files, which is what it then measures.
  local a = { path = "a", added = 0, removed = 0, hunks = {} }
  local flat = (ui.progress({
    files = { a, { path = "b", added = 0, removed = 0, hunks = {} } },
    read = { a = { [read.fingerprint(read.chunks(a)[1])] = true } },
    stat_added = 0, stat_removed = 0,
  }, 38):gsub("%%#%w+#", ""):gsub("%%%%", "%%"))
  ok(flat:find("1/2 · 50%", 1, true) ~= nil,
    "a review with no delta at all is measured on its files, got " .. flat)

  local cfg = require("uatis.config")
  cfg.list.progress = false
  foot({})
  -- Read window-locally: an empty one is what hands the window back to
  -- whatever the reader set globally, and asking for the effective value
  -- would come back with theirs.
  eq(vim.api.nvim_get_option_value("statusline", { win = pane.list_win, scope = "local" }),
    "", "and off, the window is handed back to the reader's own status line")
  cfg.list.progress = true
  foot({})
end

print("\n[a chunk the backend hides is set aside]")
-- Structural mode draws nothing for a chunk that is only formatting,
-- and `]c` never stops there -- so a file read stop by stop still had
-- a chunk nobody could mark, and its row stayed unread beside a header
-- that said every stop was. The view tells the list which chunks it
-- drew nothing for, and the list stops waiting for them for as long as
-- that is how the file is drawn.
do
  local read = require("uatis.read")
  local ui = require("uatis.ui")
  local patch = require("uatis.patch")
  local path = fixture .. "/stable.lua"
  local was = vim.fn.readfile(path)

  -- The hiding itself, as data: a chunk under no hunk.
  local f = { path = "x.py", chunks = {
    { fp = "a", added = 1, removed = 1, start = 27, count = 1 },
    { fp = "b", added = 2, removed = 1, start = 29, count = 2 },
  } }
  eq(read.hidden(f, { { start_b = 27, count_b = 4 } }), {},
    "a hunk standing on both chunks hides neither")
  eq(read.hidden(f, { { start_b = 27, count_b = 1 } }),
    { [read.fingerprint(f.chunks[2])] = true }, "and one standing on the first hides the second")
  local marks = { read = { ["x.py"] = { [read.fingerprint(f.chunks[1])] = true } } }
  ok(not read.is_read(marks, f), "one chunk of two read is not the file read")
  marks.hidden = { ["x.py"] = read.hidden(f, { { start_b = 27, count_b = 1 } }) }
  ok(read.is_read(marks, f), "unless the other is set aside")

  -- ...and live. stable.lua, which the branch never touched, gains
  -- spaces between its tokens: one chunk to git, nothing to difftastic.
  vim.fn.writefile({ "return {   untouched = true   }" }, path)
  local before = pane.renders or 0
  pane_mod.refresh(pane)
  wait_for(function()
    return (pane.renders or 0) > before and patch.find(pane.files, "stable.lua") ~= nil
  end, "the list to pick the reformat up")
  local row = patch.find(pane.files, "stable.lua")
  eq(#(row.chunks or read.chunks(row)), 1, "git reports it as one chunk")
  ok(not read.is_read(pane, row), "unread, since nothing has set it aside yet")

  vim.api.nvim_set_current_win(pane.code_win)
  vim.cmd("edit! " .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  wait_for(function()
    local v = view_mod.get(buf)
    return v ~= nil and (v.renders or 0) > 0 and not v.pending
  end, "the review to follow into stable.lua")
  local v = view_mod.get(buf)
  if use_backend(v, "struct") then
    wait_for(function()
      return pane.hidden and pane.hidden["stable.lua"] ~= nil
    end, "the view to set the chunk aside")
    eq(#v.hunks, 0, "difftastic finds nothing in it")
    ok(read.is_read(pane, row), "so the file is read, with no mark on it at all")
    ok(ui.read_chunks(v) == nil, "and the header counts nothing rather than 0/0")

    -- Drawn as lines, the chunk is a change again, and unread.
    use_backend(v, "line")
    wait_for(function()
      return not (pane.hidden and pane.hidden["stable.lua"])
    end, "line mode to give the chunk back")
    ok(not read.is_read(pane, row), "in line mode the same file is unread")
    use_backend(v, "struct")
  end

  view_mod.close(buf)
  vim.fn.writefile(was, path)
  before = pane.renders or 0
  pane_mod.refresh(pane)
  wait_for(function()
    return (pane.renders or 0) > before and patch.find(pane.files, "stable.lua") == nil
  end, "the list to let stable.lua go again")
  pane.hidden = nil
end

print("\n[folding a directory away]")
-- A branch that touched forty files in six directories is a list you
-- scroll rather than read. Folding a directory shut is how the pane
-- gets back to the size of the question you are asking of it -- and the
-- row stays, because a fold that vanished would be a list that silently
-- lost files.
do
  local ui = require("uatis.ui")

  -- The flattening on its own: nested directories go with their parent,
  -- and a directory that is merely deeper is not swept up by a fold
  -- above it that is open.
  local files = {
    { path = "README.md" },
    { path = "lua/a.lua" },
    { path = "lua/deep/b.lua" },
    { path = "tests/run.lua" },
  }
  local function shape(collapsed)
    local out = {}
    for _, r in ipairs(ui.tree_rows(files, collapsed)) do
      table.insert(out, (r.kind == "dir" and (r.collapsed and "▸" or "▾") or "·") .. r.name)
    end
    return out
  end
  eq(shape(nil), { "·README.md", "▾lua", "·a.lua", "▾deep", "·b.lua", "▾tests", "·run.lua" },
    "every directory is a row of its own, with its files under it")
  eq(shape({ lua = true }),
    { "·README.md", "▸lua", "▾tests", "·run.lua" },
    "a shut directory keeps its row and takes everything below it with it")
  eq(shape({ ["lua/deep"] = true }),
    { "·README.md", "▾lua", "·a.lua", "▸deep", "▾tests", "·run.lua" },
    "shutting a nested one leaves its parent's own files on screen")
  eq(ui.dirs_of("lua/uatis/x.lua"), { "lua", "lua/uatis" },
    "and a file names every directory it is under, outermost first")

  -- Shut, a directory row stands in for every row underneath it, so it
  -- carries what they were worth: the reason you would open it.
  do
    local counted = {
      target = "main", src = "working tree", hint = "", file_idx = 0,
      stat_added = 0, stat_removed = 0, collapsed = { ["lua/deep"] = true },
      files = {
        { path = "lua/a.lua", status = "M", added = 3, removed = 1 },
        { path = "lua/deep/b.lua", status = "A", added = 40, removed = 0 },
        { path = "lua/deep/c.lua", status = "M", added = 2, removed = 7 },
      },
    }
    local built = ui.build_list(counted, 38)
    local by_dir = {}
    for line, path in pairs(built.dirs) do
      by_dir[path] = vim.trim(built.lines[line])
    end
    ok(by_dir["lua/deep"] and by_dir["lua/deep"]:match("^▸") ~= nil
      and by_dir["lua/deep"]:match("%+42 %-7$") ~= nil,
      "a shut directory says what it is hiding, everything nested under it "
        .. "included, got " .. tostring(by_dir["lua/deep"]))
    eq(by_dir["lua"], "▾ lua/",
      "and an open one says nothing: its files are on screen with their own")

    counted.collapsed = {}
    local open_all = ui.build_list(counted, 38)
    for line, path in pairs(open_all.dirs) do
      ok(vim.trim(open_all.lines[line]):match("[+-]%d") == nil,
        path .. " carries no count once it is open, got "
          .. vim.trim(open_all.lines[line]))
    end
  end

  -- ...and in the pane, on the key that folds anything else.
  local was_win = vim.api.nvim_get_current_win()
  local idx
  for i, f in ipairs(pane.files) do
    if f.path == "util/strings.lua" then
      idx = i
    end
  end
  local function line_of(index)
    for line, i in pairs(pane.list_rows or {}) do
      if i == index then
        return line
      end
    end
  end
  local function dir_line(path)
    for line, p in pairs(pane.list_dirs or {}) do
      if p == path then
        return line
      end
    end
  end

  ok(idx ~= nil and dir_line("util") ~= nil, "the pane draws a row for util/")
  vim.api.nvim_set_current_win(pane.list_win)
  vim.api.nvim_win_set_cursor(pane.list_win, { dir_line("util"), 0 })
  local fold = vim.fn.maparg(require("uatis.config").keys.pane.fold, "n", false, true)
  ok(fold and fold.callback ~= nil, "the list binds " .. require("uatis.config").keys.pane.fold)
  fold.callback()
  ok(pane.collapsed["util"] == true, "which shuts the directory under the cursor")
  ok(line_of(idx) == nil, "so the file inside it has no row")
  ok(dir_line("util") ~= nil, "while the directory itself still does")
  eq(vim.api.nvim_win_get_cursor(pane.list_win)[1], dir_line("util"),
    "with the cursor left on the row that was acted on")

  -- Over a file, the same key shuts the directory the file is IN.
  fold.callback()
  ok(line_of(idx) ~= nil, "pressing it again opens the directory back up")
  vim.api.nvim_win_set_cursor(pane.list_win, { line_of(idx), 0 })
  fold.callback()
  ok(pane.collapsed["util"] == true and line_of(idx) == nil,
    "and over a file it shuts the directory that file is in")

  -- Arriving at a file opens the way to it: a list that could hide the
  -- row it is pointing at would be a list that disagrees with the code
  -- pane, which is the one thing redrawing it on every move prevents.
  pane_mod.goto_file(pane, idx)
  ok(pane.collapsed["util"] == nil, "walking into a folded directory opens it")
  ok(line_of(idx) ~= nil, "so the file you are reading always has a row")

  -- ...but only on arrival. Re-opening it on every RENDER instead made
  -- the fold that matters most into the one fold that did nothing: in a
  -- repo whose files all sit under one top-level directory, the
  -- directory you are standing in is the directory you want shut.
  vim.api.nvim_set_current_win(pane.list_win)
  vim.api.nvim_win_set_cursor(pane.list_win, { dir_line("util"), 0 })
  fold.callback()
  ok(pane.collapsed["util"] == true and line_of(idx) == nil,
    "the directory the current file is in folds like any other")
  ok(dir_line("util") ~= nil, "leaving its own row to open it again by")

  -- zc/zo say which way, so neither has to be pressed twice to find out
  -- which way it went.
  local pk = require("uatis.config").keys.pane
  local shut = vim.fn.maparg(pk.fold_close, "n", false, true)
  local open = vim.fn.maparg(pk.fold_open, "n", false, true)
  ok(shut and shut.callback ~= nil and open and open.callback ~= nil,
    "the list binds " .. pk.fold_close .. " and " .. pk.fold_open)
  vim.api.nvim_win_set_cursor(pane.list_win, { dir_line("util"), 0 })
  open.callback()
  ok(pane.collapsed["util"] == nil and line_of(idx) ~= nil, "zo opens it")
  open.callback()
  ok(pane.collapsed["util"] == nil, "and opening an open one leaves it open")
  shut.callback()
  ok(pane.collapsed["util"] == true, "zc shuts it")
  shut.callback()
  ok(pane.collapsed["util"] == true,
    "and pressing it on a shut one does not open it back up")
  open.callback()

  -- The whole tree at once, which on a branch that touched forty files
  -- is the first thing you reach for.
  local shut_all = vim.fn.maparg(pk.fold_close_all, "n", false, true)
  local open_all = vim.fn.maparg(pk.fold_open_all, "n", false, true)
  ok(shut_all and shut_all.callback ~= nil and open_all and open_all.callback ~= nil,
    "the list binds " .. pk.fold_close_all .. " and " .. pk.fold_open_all)
  -- Set outright rather than walked to: which file the pane is on after
  -- an open settles is the subject of other sections, and this one is
  -- about where the cursor goes when that file's row folds away.
  local was_idx = pane.file_idx
  pane.file_idx = idx
  shut_all.callback()
  local shut_dirs, file_lines = {}, 0
  for _, path in pairs(pane.list_dirs or {}) do
    table.insert(shut_dirs, path)
  end
  for _ in pairs(pane.list_rows or {}) do
    file_lines = file_lines + 1
  end
  eq(shut_dirs, { "util" }, "zM leaves the outermost directories and nothing under them")
  eq(file_lines, 4, "so only the files that are in no directory keep a row")
  ok(pane.collapsed["util"] == true, "with every directory marked shut, not just the top")
  eq(vim.api.nvim_win_get_cursor(pane.list_win)[1], dir_line("util"),
    "and the cursor on the row standing in for where you were")
  open_all.callback()
  eq(next(pane.collapsed), nil, "zR opens every one of them again")
  ok(line_of(idx) ~= nil, "and every file has its row back")
  pane.file_idx = was_idx

  vim.api.nvim_set_current_win(was_win)
end

print("\n[opening files from the pane]")
do
  local function index_of(path)
    for i, f in ipairs(pane.files) do
      if f.path == path then
        return i
      end
    end
  end

  -- A file the branch ADDED has no blob at the fork point. Treating that
  -- as a failure made a third of a merge request unreachable from the
  -- pane; the honest answer is that all of it is new.
  pane_mod.goto_file(pane, index_of("helper.lua"))
  local added_buf = vim.api.nvim_get_current_buf()
  wait_for(function()
    local v = view_mod.get(added_buf)
    return v ~= nil and (v.renders or 0) > 0
  end, "a view over the added file")
  -- `or {}` so a broken open reports as failed assertions rather than
  -- taking the whole run down with a nil index.
  local added_view = view_mod.get(added_buf) or {}

  ok(vim.api.nvim_buf_get_name(added_buf):find("helper.lua", 1, true) ~= nil,
    "the file opens in the window beside the pane")
  ok(added_buf ~= pane.list_buf, "and never into the pane itself")
  -- Asked of the PANE and not of some other view that happens to hold the
  -- same sha: what is being claimed is that a file opened from the list
  -- is measured against the list's own revision.
  eq(added_view.rev, pane.rev, "pinned to the same revision as the pane")
  eq(added_view.removed, 0, "an added file removes nothing")
  eq(added_view.added, #vim.api.nvim_buf_get_lines(added_buf, 0, -1, false),
    "and every one of its lines is an addition")
  -- On the tick after the window let go of it, which a render served
  -- from cache does not wait through on its own.
  ok(wait_for(function() return view_mod.get(view_buf) == nil end,
    "the view on the file left behind to end"),
    "the file you left behind gives its buffer back")
  eq(vim.wo.winbar, require("uatis.ui").VIEW_WINBAR,
    "and the window it landed in describes the file that is now in it")

  -- A path is not an identity. A file the branch renamed has no blob under
  -- its NEW name at the fork point, so a view that looked only at where the
  -- file is now would report a pure `git mv` as a brand new file. The pane
  -- has the old name, because rename detection is a property of the patch
  -- it parsed.
  pane_mod.goto_file(pane, index_of("renamed_to.lua"))
  local renamed_buf = vim.api.nvim_get_current_buf()
  wait_for(function()
    local v = view_mod.get(renamed_buf)
    return v ~= nil and (v.renders or 0) > 0
  end, "a view over the renamed file")
  local renamed_view = view_mod.get(renamed_buf) or {}
  eq(renamed_view.old_path, "renamed_from.lua", "the view is told where the file came from")
  eq({ renamed_view.added, renamed_view.removed }, { 0, 0 }, "so a pure rename changes nothing")
  local bar = require("uatis.ui").view_winbar_text(renamed_view, 200)
    :gsub("%%#[%w]*#", ""):gsub("%%%*", ""):gsub("%%<", "")
  ok(bar:find("← renamed_from.lua", 1, true) ~= nil,
    "and the header says where it came from, got:" .. bar)

  -- A file the branch DELETED has nothing in your tree to annotate, and
  -- it is the one file where "what was there" is the whole question. So
  -- the window gets an empty buffer standing for the file that is gone,
  -- and the comparison says every line of it went.
  pane_mod.goto_file(pane, index_of("doomed.lua"))
  local gone_buf = vim.api.nvim_get_current_buf()
  wait_for(function()
    local v = view_mod.get(gone_buf)
    return v ~= nil and (v.renders or 0) > 0
  end, "a view over the file the branch deleted")
  local gone = view_mod.get(gone_buf) or {}
  ok(gone_buf ~= renamed_buf, "a deleted file opens rather than refusing")
  eq(vim.api.nvim_buf_get_lines(gone_buf, 0, -1, false), { "" },
    "with nothing in it, because there is nothing in your tree")
  eq(gone.added, 0, "nothing was added to it")
  ok(gone.removed > 0, "and every line it had is gone, got " .. tostring(gone.removed))
  eq(gone.relpath, "doomed.lua", "the view knows which file it stands for")
  ok(not vim.bo[gone_buf].modifiable, "and the buffer is not one to type in")
end

print("\n[the next change is in the next file]")
-- The unit being read is a branch, not a buffer. `]c` off the last chunk
-- of a file carries on into the next file the list names and lands on the
-- first change in it -- the reader was asking for the next change, and
-- there is one. Off the end of the review it says so and stays, the way
-- stepping the list does.
do
  local k = require("uatis.config").keys.view
  local cfg = require("uatis.config")

  local function index_of(path)
    for i, f in ipairs(pane.files) do
      if f.path == path then
        return i
      end
    end
  end

  local function press(lhs)
    local m = vim.fn.maparg(lhs, "n", false, true)
    if m and m.callback then
      m.callback()
      return true
    end
    return false
  end

  local function opened(path)
    pane_mod.goto_file(pane, index_of(path))
    local buf = vim.api.nvim_get_current_buf()
    wait_for(function()
      local v = view_mod.get(buf)
      return v ~= nil and v.relpath == path and (v.renders or 0) > 0
    end, "a view over " .. path)
    return buf, view_mod.get(buf) or {}
  end

  -- Backwards first, because it is the direction with something to
  -- assert: the last chunk of the file before is a line partway down it,
  -- and landing at the top would be indistinguishable from having gone
  -- nowhere.
  local gone_buf = opened("doomed.lua")
  local calc_idx = index_of("calc.lua")
  ok(calc_idx == index_of("doomed.lua") - 1,
    "the file before the deleted one is the modified one")
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  ok(press(k.hunk_prev), "[c is bound in the file it is pressed in")
  wait_for(function()
    local b = vim.api.nvim_get_current_buf()
    local v = view_mod.get(b)
    return b ~= gone_buf and v ~= nil and v.relpath == "calc.lua"
      and (v.renders or 0) > 0
  end, "[c off the top of a file to open the one before it")
  local calc_buf = vim.api.nvim_get_current_buf()
  local calc = view_mod.get(calc_buf) or {}
  local last = (calc.anchors or {})[#(calc.anchors or {})]
  ok(last ~= nil and last > 1, "which has more than one chunk in it, got "
    .. vim.inspect(calc.anchors))
  wait_for(function()
    return vim.api.nvim_win_get_cursor(0)[1] == last
  end, "the cursor to reach the chunk it was aimed at")
  eq(vim.api.nvim_win_get_cursor(0)[1], last,
    "and `[c` lands on the LAST change in it, not on the top of the file")

  -- ...and forwards, from that same chunk, which is the last one there is
  -- here.
  ok(press(k.hunk_next), "]c off the last chunk of a file")
  wait_for(function()
    local b = vim.api.nvim_get_current_buf()
    local v = view_mod.get(b)
    return b ~= calc_buf and v ~= nil and v.relpath == "doomed.lua"
  end, "]c to carry on into the next file the list names")
  eq((view_mod.get(vim.api.nvim_get_current_buf()) or {}).relpath, "doomed.lua",
    "which is the next file, and not the next window or the list")

  -- The end of the review is the end. It says so rather than wrapping:
  -- running out is the answer to "what is next", and a review that came
  -- back round to the top would hide it.
  local said = {}
  local real_notify = vim.notify
  vim.notify = function(msg) table.insert(said, msg) end
  local last_idx = #pane.files
  local tail_buf, tail = opened(pane.files[last_idx].path)
  local tail_last = (tail.anchors or {})[#(tail.anchors or {})]
  vim.api.nvim_win_set_cursor(0, { tail_last or 1, 0 })
  press(k.hunk_next)
  vim.wait(200, function() return #said > 0 end, 10)
  vim.notify = real_notify
  eq(vim.api.nvim_get_current_buf(), tail_buf, "the last change in the last file stays put")
  ok(contains(said, "last change"), "and says there is nothing after it, got "
    .. vim.inspect(said))

  -- Off, `]c` is a motion again: it stops at the ends of the buffer it is
  -- in and the file list is stepped by `]f` alone.
  said = {}
  vim.notify = function(msg) table.insert(said, msg) end
  cfg.pane.chunk_spill = false
  local held_buf = opened("doomed.lua")
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  press(k.hunk_prev)
  vim.wait(100, function() return false end, 10)
  vim.notify = real_notify
  cfg.pane.chunk_spill = true
  eq(vim.api.nvim_get_current_buf(), held_buf,
    "with chunk_spill off it goes nowhere")
  eq(said, {}, "and says nothing about it")

  -- Handed back: a later section opens calc.lua in a tab of its own and
  -- toggles a review on from it, and a view left here by a `[c` that
  -- stepped into the file is the one that toggle would turn off. Views
  -- are per buffer, and a buffer is the same buffer in every tab.
  view_mod.close(calc_buf)
end

print("\n[the pane counts the working tree]")
do
  -- `git diff <fork point>` with no second revision, so an unsaved-then-
  -- saved edit is counted. A range would have called the file unchanged.
  -- On the file the branch ADDED, whose count is a plain line count. A
  -- renamed file would have been the wrong subject: edit one enough and
  -- git stops calling it a rename at all, so the number moves for a
  -- reason that has nothing to do with what this is testing.
  local path = "helper.lua"
  for i, f in ipairs(pane.files) do
    if f.path == path then
      pane_mod.goto_file(pane, i)
    end
  end
  local buf = vim.api.nvim_get_current_buf()
  wait_for(function()
    local v = view_mod.get(buf)
    return v ~= nil and v.relpath == path and (v.renders or 0) > 0
  end, "a view over the file about to be written")
  local before = pane.renders
  local function counted()
    for _, f in ipairs(pane.files) do
      if f.path == path then
        return f.added
      end
    end
  end
  local counted_before = counted()
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "-- a line added while reviewing" })
  vim.cmd("silent write")
  wait_for(function() return (pane.renders or 0) > before end, "the pane to re-read after a write")
  local counted_after = counted()
  eq(counted_after, counted_before + 1, "a saved edit lands in the pane's counts")
end

print("\n[a file git has never heard of]")
-- `git diff <fork point>` cannot mention an untracked file: there is no
-- revision it existed in to be measured against. It is still part of
-- what the branch did, and a list that leaves it out answers "what have
-- I changed" with everything except the file you just wrote -- which is
-- also the one `]f` then cannot reach.
do
  local path = "brand_new.lua"
  local full = fixture .. "/" .. path
  vim.fn.writefile({ "local M = {}", "", "function M.hello()", "end", "return M" }, full)

  local before = pane.renders
  pane_mod.refresh(pane)
  wait_for(function() return (pane.renders or 0) > before end, "the list to be re-read")

  local row
  for _, f in ipairs(pane.files) do
    if f.path == path then
      row = f
    end
  end
  ok(row ~= nil, "a file git has never been told about is in the list")
  eq(row and row.status, "A", "as an addition, which is what it is")
  eq(row and row.added, 5, "with every line of it counted, since none of them was there")
  eq(row and row.removed, 0, "and nothing removed")

  -- ...and it is reachable, which is the half that matters: a row nobody
  -- can step to is a row that only says the file exists.
  local idx
  for i, f in ipairs(pane.files) do
    if f.path == path then
      idx = i
    end
  end
  pane_mod.goto_file(pane, idx)
  local opened = vim.api.nvim_get_current_buf()
  eq(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(opened), ":t"), path,
    "stepping the list opens it")
  wait_for(function()
    local v = view_mod.get(opened)
    return v ~= nil and (v.renders or 0) > 0
  end, "a view on the new file")
  ok((view_mod.get(opened) or {}).new_file == true,
    "annotated as a file with no old side at all")

  -- Ignored files are git's own answer to "not mine", and the list takes
  -- it: `--exclude-standard` is what keeps a build directory out of a
  -- review.
  vim.fn.writefile({ "*.log" }, fixture .. "/.gitignore")
  vim.fn.writefile({ "ignored" }, fixture .. "/ignored.log")
  before = pane.renders
  pane_mod.refresh(pane)
  wait_for(function() return (pane.renders or 0) > before end, "the list once more")
  local listed = vim.tbl_map(function(f) return f.path end, pane.files)
  ok(not contains(listed, "ignored.log"),
    "a file .gitignore covers stays out of it, got " .. table.concat(listed, ", "))
  ok(contains(listed, ".gitignore"),
    "while the .gitignore that says so is itself a new file of the branch")

  -- Gone from the disk AND from the editor. A buffer still holding the
  -- text is a change the list is right to keep reporting -- that is the
  -- same reason an unsaved edit is counted -- so the buffer goes first,
  -- put away by reading another file into its window rather than by
  -- wiping it out from under one: the pane remembers the window it
  -- splits off, and a window closed here is one the next section cannot
  -- step back into.
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/helper.lua"))
  vim.cmd("silent! bwipeout! " .. opened)
  vim.fn.delete(full)
  vim.fn.delete(fixture .. "/ignored.log")
  vim.fn.delete(fixture .. "/.gitignore")
  before = pane.renders
  pane_mod.refresh(pane)
  wait_for(function() return (pane.renders or 0) > before end, "the list after deleting it")
  listed = vim.tbl_map(function(f) return f.path end, pane.files)
  ok(not contains(listed, path), "and it leaves the list when it leaves the disk")
end

print("\n[reading a review one commit at a time]")
-- A branch is a sequence of commits, and reviewing it is often reading
-- them in order rather than all at once. `<leader>gh` turns that on:
-- the review becomes one commit, its own files measured against the one
-- before it. `]C`/`[C` move within it. Off again, the review is what it
-- is the rest of the time -- the whole branch against the working tree.
do
  -- A clean tree, because half of what this section is about is the
  -- case where the reader's own file IS the commit's content, and an
  -- earlier section here has been writing to one of these files. Put
  -- back rather than worked around: "nothing has touched it since" is
  -- the precondition, and a test that cannot state its own
  -- preconditions is testing something else.
  vim.fn.system({ "git", "-C", fixture, "checkout", "--", "." })
  -- ...and the buffers that were holding what git just put back. A
  -- buffer is what the file IS, unsaved edits and all -- that is the
  -- rule the whole plugin rests on -- so a stale one here would make
  -- the reader's own file differ from the commit for a reason that has
  -- nothing to do with the commit.
  vim.cmd("silent! checktime")

  vim.cmd("tabnew")
  base.set(root, "main")
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
  uatis.toggle_diff()
  wait_for(function()
    local p = pane_mod.get()
    return p ~= nil and (p.renders or 0) > 0
  end, "a review to read commit by commit")
  local p = pane_mod.get()
  local whole = #p.files
  local tree_rev = p.rev
  ok(whole > 1, "the review is the whole branch to start with, got " .. whole .. " files")
  ok(p.commit == nil, "with no single commit on show")
  local keys = require("uatis.config").keys.pane
  ok(offered(p):find(keys.commit_view .. " read the branch one commit at a time",
    1, true) ~= nil,
    "and the keys say how to read it one at a time, got " .. offered(p))

  -- The navigation keys do not turn the mode on. A key that means "next"
  -- has no business meaning "enter" as well.
  local said = {}
  local real_notify = vim.notify
  vim.notify = function(msg) table.insert(said, msg) end
  pane_mod.step_commit(p, -1)
  wait_for(function() return #said > 0 end, "uatis to say the mode is off")
  ok(p.commit == nil, "stepping does not enter the mode")
  -- The view's key, since this is pressed in a file as often as in the
  -- list -- and the list's own toggle is a bare `C`, which in a file is
  -- `c$` and could never be bound there.
  ok(said[1]:find(require("uatis.config").keys.view.commit_view, 1, true) ~= nil,
    "and says which key does, got " .. said[1])
  vim.notify = real_notify

  -- The list has a bare letter for it, which only a list can afford:
  -- `C` there has nothing to change, and in the file beside it that
  -- keystroke is `c$`.
  local pane_key = require("uatis.config").keys.pane.commit_view
  if not p.list_buf then
    pane_mod.open({ focus = false })
  end
  ok(p.list_buf ~= nil, "the list has a window to bind keys in")
  local in_list = vim.api.nvim_buf_call(p.list_buf, function()
    return vim.fn.maparg(pane_key, "n", false, true)
  end)
  ok(in_list and in_list.callback ~= nil, "the list binds " .. pane_key)
  eq(vim.fn.maparg(pane_key, "n"), "",
    "and nothing binds it in the file beside it, where it is a change command")

  -- Entering shows the first commit: where the branch starts, so `]C`
  -- reads it in the order it was written.
  local turns = p.renders
  pane_mod.toggle_commits(p)
  wait_for(function() return p.commit ~= nil and (p.renders or 0) > turns end,
    "the first commit to be put on show")
  eq(p.commit_idx, 1, "the toggle enters at the first commit")
  eq(p.rev, p.tree_rev, "measured against the fork point, which is its parent")

  -- The date on the commit's row says the day; rested on, it says the
  -- moment, to the second and with its offset.
  do
    require("uatis.filelist").render(p)
    local row, span
    for r, sp in pairs(p.list_dates or {}) do
      if sp.sha == p.commit.sha then
        row, span = r, sp
      end
    end
    if ok(span ~= nil, "the commit's date is a place in the list") then
      -- After the commit's file has opened, which takes the cursor to it.
      wait_for(function()
        local v = vim.api.nvim_win_is_valid(p.code_win)
          and view_mod.get(vim.api.nvim_win_get_buf(p.code_win))
        return v and (v.renders or 0) > 0
      end, "the commit's file to open")
      vim.api.nvim_set_current_win(p.list_win)
      vim.api.nvim_win_set_cursor(p.list_win, { row, span.col_start })
      pane_mod.peek_date(p)
      wait_for(function() return p.date_float and vim.api.nvim_win_is_valid(p.date_float) end,
        "the date's float")
      local said = p.date_float and vim.api.nvim_win_is_valid(p.date_float)
        and vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(p.date_float), 0, -1, false)[1] or ""
      ok(said:match("^" .. vim.pesc(p.commit.date) .. " %d%d:%d%d:%d%d [+-]%d%d%d%d") ~= nil,
        "rested on, it says the time to the second, got " .. said)
      vim.api.nvim_win_set_cursor(p.list_win, { row, 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = p.list_buf })
      ok(not (p.date_float and vim.api.nvim_win_is_valid(p.date_float)), "and moving on closes it")
      pane_mod.peek_date(p)
      vim.wait(300)
      ok(not (p.date_float and vim.api.nvim_win_is_valid(p.date_float)),
        "off the date, nothing is said")
      vim.api.nvim_set_current_win(p.code_win)
    end
  end

  -- ...and `]C` walks it to the newest, where the rest of this is read.
  for _ = 2, #p.commits do
    local at = p.commit_idx
    pane_mod.step_commit(p, 1)
    wait_for(function() return p.commit_idx == at + 1 end, "the next commit")
  end

  -- The walk's header: where you are in it, which commit, when and by
  -- whom -- all on one greyed row -- and the message under it in the
  -- buffer's own colour. Everything above the message is how you FIND a
  -- commit; the message is the thing being read.
  do
    local walk = require("uatis.ui").build_list(p, 38)
    local said = vim.trim(walk.lines[2] or "")
    ok(said:find(("%d/%d"):format(p.commit_idx, #p.commits), 1, true) == 1,
      "the count leads the row, got " .. said)
    ok(said:find(p.commit.short, 1, true) ~= nil, "with the sha on it, got " .. said)
    eq(vim.trim(walk.lines[3] or ""), p.commit.subject,
      "and the message under it, got " .. table.concat(walk.lines, " | "))
  end
  eq(p.commit.subject, "document clamp", "which is the last thing the branch did")
  eq(p.rev, p.commits[#p.commits - 1].sha,
    "measured against the commit before it, not against the base")
  eq(#p.files, 1, "and the list is that commit's own files")

  -- The newest commit on a clean tree is the one case where the file on
  -- disk IS the commit's content, so the reader keeps their own buffer.
  wait_for(function()
    return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t") == "helper.lua"
  end, "the commit's file to be opened")
  local buf = vim.api.nvim_get_current_buf()
  ok(vim.bo[buf].buftype == "", "as the reader's own buffer, since nothing has moved since")
  ok(vim.bo[buf].modifiable, "which is still a buffer they could type in")
  eq((view_mod.get(buf) or {}).at_commit, nil, "so nothing says it is a copy")

  -- `]C` at the newest stays there and says so: walking off the end of a
  -- list is a thing to be told about, not a way out of the mode.
  said = {}
  vim.notify = function(msg) table.insert(said, msg) end
  pane_mod.step_commit(p, 1)
  wait_for(function() return #said > 0 end, "uatis to say there is no next commit")
  ok(said[1]:find("last commit", 1, true) ~= nil, "the last commit says so, got " .. said[1])
  ok(p.commit ~= nil, "and the mode is still on")
  vim.notify = real_notify

  -- Back through the branch, one commit at a time.
  pane_mod.step_commit(p, -1)
  wait_for(function() return p.commit_idx == #p.commits - 1 end, "the commit before it")
  vim.wait(400)
  eq(p.commit.subject, "drop doomed, rename module", "the one before is on show")
  eq(#p.files, 2, "with its own two files")

  pane_mod.step_commit(p, -1)
  wait_for(function() return p.commit_idx == #p.commits - 2 end, "and the one before that")
  vim.wait(400)
  eq(p.commit.subject, "add clamp helper", "which added the helper")
  local at = vim.api.nvim_get_current_buf()
  local v = view_mod.get(at)
  -- ...out of the review's own checkout of that commit: a real file,
  -- which a language server attaches to, holding the commit's text.
  local checkout = require("uatis.checkout")
  local at_name = vim.api.nvim_buf_get_name(at)
  local co = checkout.owner_of(at_name)
  ok(co ~= nil, "a file later commits touched is shown as it was, out of a checkout, got "
    .. at_name)
  eq(vim.bo[at].buftype, "", "as a file on disk, for a language server to attach to")
  eq(table.concat(vim.api.nvim_buf_get_lines(at, 0, -1, false), "\n"),
    vim.fn.system({ "git", "-C", fixture, "show", p.commit.sha .. ":helper.lua" }):gsub("\n$", ""),
    "holding the commit's text")
  ok(not vim.bo[at].modifiable, "read-only, because it is not the reader's file")
  eq(v and v.at_commit, p.commit.short, "and the view says which commit it holds")
  eq(v and v.rev, p.commits[p.commit_idx - 1].sha, "measured against the commit before it")

  -- ...and the other end of the sequence.
  said = {}
  vim.notify = function(msg) table.insert(said, msg) end
  pane_mod.step_commit(p, -1)
  vim.wait(400)
  pane_mod.step_commit(p, -1)
  wait_for(function() return #said > 0 end, "uatis to say there is nothing further back")
  ok(said[1]:find("first commit", 1, true) ~= nil, "the first commit says so, got " .. said[1])
  vim.notify = real_notify
  eq(p.commit_idx, 1, "and it stays there")
  eq(p.target, "main", "whose parent is what the review measures from, named as such")

  -- The two keys that only mean anything in this mode are only offered
  -- in it -- and `C`, which does not go away, says what it does now.
  ok(offered(p):find(keys.commit_prev .. " " .. keys.commit_next, 1, true) ~= nil,
    "the keys offer the step pair while a commit is on show, got " .. offered(p))
  ok(offered(p):find(keys.commit_view .. " back to the whole branch", 1, true) ~= nil,
    "and say where the toggle goes from here, got " .. offered(p))

  -- `FocusGained` while a commit is on show. `recheck` drops the walk --
  -- something may have landed on the branch while nvim was not looking
  -- -- and the header counts the commit against that walk, so dropping
  -- it and rendering threw: `attempt to get length of field 'commits'`.
  -- The reader stays on the commit they were reading; only the count it
  -- is one of can have moved.
  local on = p.commit
  turns = p.renders
  pane_mod.recheck(p)
  wait_for(function() return (p.renders or 0) > turns end,
    "the list to be re-read after git may have moved")
  ok(p.commit ~= nil and p.commits ~= nil,
    "a commit on show survives a recheck, with the walk it is counted against")
  eq(p.commit and p.commit.sha, on.sha, "and it is the same commit")
  eq(p.commit_idx, 1, "at its place in the walk")

  -- The same key turns it off, wherever in the sequence you had got to.
  turns = p.renders
  pane_mod.toggle_commits(p)
  wait_for(function()
    return p.commit == nil and (p.renders or 0) > turns and #p.files == whole
  end, "the review to be the whole branch again")
  ok(p.commit == nil, "the toggle turns it off from any commit")
  eq(#p.files, whole, "and the review is the whole branch again")
  eq(p.rev, tree_rev, "against what it always measured against")
  wait_for(function() return vim.bo[vim.api.nvim_get_current_buf()].buftype == "" end,
    "a file of the reader's own again")
  ok(vim.bo[vim.api.nvim_get_current_buf()].buftype == "",
    "with the reader in a file of their own")
  ok(checkout.owner_of(vim.api.nvim_buf_get_name(0)) == nil,
    "and not one out of the walk's checkout")
  ok(not checkout.has(p), "which the walk's end takes away")
  wait_for(function() return co and vim.fn.isdirectory(co.dir) == 0 end,
    "the walk's checkout to be removed from the disk")

  -- Taken down by hand rather than with the key: a review is one root
  -- and one revision wherever it is reached from, so ending this one
  -- would end the one the sections below are standing in.
  view_mod.close_all(root, p.rev)
  pane_mod.close(p)
  vim.cmd("silent! tabclose")
end

print("\n[the review notices git moving underneath it]")
-- Nothing here was written or re-read, so neither of the pane's other
-- watchers fires: the reader switched to another window, ran git there,
-- and came back. A commit would need no answer -- the list counts the
-- working tree against the fork point, and committing moves neither --
-- but a branch switched, a rebase, or the base branch pulled moves the
-- FORK POINT, and a review measuring against the old one is not stale,
-- it is wrong.
--
-- In a tab of its own, against the BASE BRANCH: only a base-tracking
-- review follows the fork point. One named by hand -- `:Uatis <ref>` --
-- was pointed at a revision by someone who meant that revision, and the
-- pane beside this section's own is one of those.
do
  local function git_run(...)
    return vim.trim(vim.fn.system({ "git", "-C", fixture, ... }))
  end

  vim.cmd("tabnew")
  base.set(root, "main")
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
  uatis.toggle_diff()
  wait_for(function()
    local p = pane_mod.get()
    return p ~= nil and (p.renders or 0) > 0
  end, "a review against the base branch")
  local watched = pane_mod.get()

  -- A change to the tree that no buffer here made.
  local path = "helper.lua"
  local before = watched.renders
  local disk = vim.fn.readfile(fixture .. "/" .. path)
  vim.fn.writefile(vim.list_extend({ "-- written by something else" }, vim.deepcopy(disk)),
    fixture .. "/" .. path)
  vim.cmd("doautocmd FocusGained")
  wait_for(function() return (watched.renders or 0) > before end,
    "the list to be re-read on coming back")
  local counted
  for _, f in ipairs(watched.files) do
    if f.path == path then
      counted = f.added
    end
  end
  ok(counted ~= nil and counted > 0,
    "a change made outside nvim reaches the list, got " .. tostring(counted))
  vim.fn.writefile(disk, fixture .. "/" .. path)

  -- ...and the fork point itself moving, which is what a branch switch
  -- or a pull on the base branch does. `main` is pointed at a commit of
  -- this branch's own, so `merge-base(main, HEAD)` is somewhere else
  -- than it was.
  local was_rev = watched.rev
  local was_main = git_run("rev-parse", "main")
  local moved_to = git_run("rev-parse", "HEAD~1")
  git_run("branch", "-f", "main", moved_to)
  vim.cmd("doautocmd FocusGained")
  wait_for(function() return watched.rev ~= was_rev end,
    "the list to be re-pointed at the new fork point")
  eq(watched.rev, moved_to, "the list follows the fork point to where it moved")

  -- The views measuring against it move with it, or the two disagree.
  local v = view_mod.get(vim.api.nvim_get_current_buf())
  ok(v ~= nil and v.rev == watched.rev,
    "and the view beside it is measuring against the same one, got "
      .. tostring(v and v.rev))

  git_run("branch", "-f", "main", was_main)
  vim.cmd("doautocmd FocusGained")
  wait_for(function() return watched.rev == was_rev end, "the fork point to be put back")
  eq(watched.rev, was_rev, "and back again when git moves back")

  -- The list of THIS tab put away, and the tab with it. Not
  -- `toggle_diff`: a review is one root and one revision wherever it is
  -- reached from, so ending it here would end the one the sections
  -- below are standing in, which is measuring against the same fork
  -- point in the tab underneath.
  pane_mod.close(watched)
  vim.cmd("silent! tabclose")
end

print("\n[the reader's git config cannot empty the list]")
-- The list is the one thing built by parsing git's own diff output, and
-- a reader's config is allowed to change what that output looks like:
-- an external differ (difftastic, on the sort of machine that has it)
-- replaces it wholesale, `color.ui = always` wraps it in escapes, the
-- prefix settings rename the `a/`/`b/` the header is found by. Every one
-- of those used to show up as an empty pane beside a buffer full of
-- highlighted changes.
do
  local function cfg(...)
    vim.system({ "git", "-C", fixture, "config", ... }):wait()
  end
  local hostile = {
    ["diff.external"] = "echo not-a-diff",
    ["diff.noprefix"] = "true",
    ["diff.mnemonicPrefix"] = "true",
    ["color.ui"] = "always",
  }
  local want = #pane.files
  ok(want > 0, "the list has files in it to begin with, got " .. want)
  for k, v in pairs(hostile) do
    cfg(k, v)
  end
  local before = pane.renders
  pane_mod.refresh(pane)
  wait_for(function() return (pane.renders or 0) > before end, "the pane to re-read")
  eq(#pane.files, want, "the same files are listed with git configured against us")
  for k in pairs(hostile) do
    cfg("--unset", k)
  end
end

print("\n[stepping the list from anywhere]")
-- The view binds ]f/[f, but a reader is not always in a file with a
-- comparison on it: a scratch buffer, a file the branch did not touch,
-- the empty buffer nvim started in. Stepping the list is about the LIST,
-- and the list is open -- so the keys are lent to whatever buffer you are
-- in, and handed back when the pane closes.
local scratch
do
  local k = require("uatis.config").keys.pane

  vim.api.nvim_set_current_win(pane.code_win)
  vim.cmd("enew")
  scratch = vim.api.nvim_get_current_buf()
  vim.bo[scratch].bufhidden = "hide"
  ok(view_mod.get(scratch) == nil, "a buffer with no diff view on it")

  local step = vim.fn.maparg(k.file_prev, "n", false, true)
  ok(step and step.callback ~= nil,
    "still answers to " .. k.file_prev .. " while the list is open")

  -- Placed deliberately: the file before this one in the list is one the
  -- branch ADDED, so stepping back has something to open. (The one before
  -- that is a file it deleted, which has nothing -- covered above.)
  pane.file_idx = 4
  if step and step.callback then
    step.callback()
  end
  eq(pane.file_idx, 3, "which steps the list")
  ok(vim.api.nvim_get_current_buf() ~= scratch
    and vim.api.nvim_buf_get_name(0):find("helper.lua", 1, true) ~= nil,
    "and opens the file it landed on, got "
      .. vim.api.nvim_buf_get_name(0):match("[^/]*$"))
  local landed = vim.api.nvim_get_current_buf()

  -- A buffer of someone else's -- a terminal, a help page, another
  -- plugin's pane -- is somewhere you went for its own sake.
  -- Created as a scratch buffer BEFORE it is entered: made into one
  -- afterwards it would already have been lent the keys, which is a fact
  -- about this test rather than about the rule.
  local borrowed = vim.api.nvim_create_buf(false, true)
  vim.cmd("buffer " .. borrowed)
  eq(vim.api.nvim_buf_call(borrowed, function()
    return vim.fn.maparg(k.file_prev, "n")
  end), "", "and a buffer that is not a file keeps its own keys")
  vim.cmd("buffer " .. landed)
end

print("\n[the review follows you]")
-- Reviewing a branch is a mode, not a decoration on one buffer. A file the
-- list names is annotated however you arrive at it -- `:e`, a jump to
-- definition, a picker -- and one it does not name is left alone.
do
  local rev = pane.rev

  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/util/strings.lua"))
  local arrived = vim.api.nvim_get_current_buf()
  wait_for(function()
    local v = view_mod.get(arrived)
    return v ~= nil and (v.renders or 0) > 0
  end, "a file opened by hand to be annotated by the review")
  local v = view_mod.get(arrived) or {}
  ok(v.renders ~= nil, "a changed file opened by hand is annotated on arrival")
  eq(v.rev, rev, "against the revision the review is pinned to, not one of its own")
  eq(v.tracks_base, pane.tracks_base, "and following the base branch with it")

  -- The file the branch never touched. A view here would put a winbar over
  -- every file in the repository you happened to open.
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/stable.lua"))
  local bystander = vim.api.nvim_get_current_buf()
  ok(view_mod.get(bystander) == nil, "a file the branch did not touch is left alone")
  ok(vim.fn.maparg(require("uatis.config").keys.pane.file_next, "n") ~= "",
    "and is lent " .. require("uatis.config").keys.pane.file_next .. " instead, as any buffer is")

  -- ...unless it is asked for directly, which is what the key means in a
  -- file the list does not have. Answered by the review that is running,
  -- at its revision.
  uatis.toggle_diff()
  wait_for(function()
    local w = view_mod.get(bystander)
    return w ~= nil and (w.renders or 0) > 0
  end, "the unlisted file to be taken in by hand")
  eq((view_mod.get(bystander) or {}).rev, rev,
    "asking for one by hand joins the review rather than starting a second")

  -- `q` is about the window. The list is what the review IS, so it stays:
  -- `]f` still steps it and the next file still arrives annotated.
  local list_win = pane.list_win
  local wins = #vim.api.nvim_tabpage_list_wins(0)
  local quit = vim.api.nvim_buf_call(pane.list_buf, function()
    return vim.fn.maparg(require("uatis.config").keys.pane.quit, "n", false, true)
  end)
  ok(quit and quit.callback ~= nil, "the list binds " .. require("uatis.config").keys.pane.quit)
  if quit and quit.callback then
    quit.callback()
  end
  ok(not vim.api.nvim_win_is_valid(list_win), "which closes its window")
  eq(#vim.api.nvim_tabpage_list_wins(0), wins - 1, "and only its window")
  ok(pane_mod.get() == pane and pane.list_win == nil,
    "while the list itself goes on, with no window of its own")
  eq(#pane.files, 5, "still listing what the branch changed")

  -- ...and the key that put it there is a toggle, so it can take it away
  -- again. Driven through the real mappings rather than through the
  -- module, because the second press of a toggle is answered by whatever
  -- buffer the first press left the cursor in -- which is the list.
  local files_key = require("uatis.config").keys.view.files
  local function press(bufnr, lhs)
    local m = vim.api.nvim_buf_call(bufnr, function()
      return vim.fn.maparg(lhs, "n", false, true)
    end)
    if not (m and m.callback) then
      return false
    end
    m.callback()
    return true
  end

  ok(press(bystander, files_key), "the view binds " .. files_key)
  ok(pane_mod.get() == pane and pane.list_win ~= nil,
    "which puts a window back on the same list rather than reading a new one")
  eq(#vim.api.nvim_tabpage_list_wins(0), wins, "one window again")
  eq(vim.api.nvim_get_current_win(), pane.list_win, "with the cursor in it")

  -- Pressed while the list is up but the cursor is somewhere else, it is
  -- not asking for the window to go away -- it is asking to get to it.
  -- Closing a window the reader is not even standing in would be a
  -- strange answer to a key pressed to see something.
  local code_win
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(w) == bystander then
      code_win = w
    end
  end
  ok(code_win ~= nil and code_win ~= pane.list_win, "the file is in a window of its own")
  vim.api.nvim_set_current_win(code_win)
  ok(press(bystander, files_key), "and the view still answers to it from there")
  eq(vim.api.nvim_get_current_win(), pane.list_win, "which moves the cursor into the list")
  eq(#vim.api.nvim_tabpage_list_wins(0), wins, "and leaves the window where it was")

  ok(press(pane.list_buf, files_key), "the list binds the same key")
  eq(#vim.api.nvim_tabpage_list_wins(0), wins - 1,
    "so pressing it again takes the window away")
  ok(pane_mod.get() == pane and pane.list_win == nil,
    "the window, not the review -- the list goes on with no window of its own")
  eq(#pane.files, 5, "still listing what the branch changed")

  press(bystander, files_key)
  ok(pane.list_win ~= nil and vim.api.nvim_win_is_valid(pane.list_win),
    "and once more puts it back")
  eq(#vim.api.nvim_tabpage_list_wins(0), wins, "one window again")
end

print("\n[the list points at the file you are in]")
-- The cursor is how the list says where you are: the row it sits on is
-- the one drawn as current. So arriving at a file puts it there -- every
-- arrival, not only the ones that change which file is current, since a
-- list left on the row of the file you came back FROM points at the wrong
-- file for as long as you stay in this one.
do
  local function row_of(path)
    for i, f in ipairs(pane.files or {}) do
      if f.path == path then
        for line, idx in pairs(pane.list_rows or {}) do
          if idx == i then
            return line
          end
        end
      end
    end
  end
  local function cursor()
    return vim.api.nvim_win_get_cursor(pane.list_win)[1]
  end

  local back_win = vim.api.nvim_get_current_win()
  local back_buf = vim.api.nvim_get_current_buf()

  local code_win
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if w ~= pane.list_win then
      code_win = w
    end
  end
  ok(code_win ~= nil, "there is a window to read files in")
  local code_buf = vim.api.nvim_win_get_buf(code_win)
  vim.api.nvim_set_current_win(code_win)

  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
  eq(cursor(), row_of("calc.lua"), "arriving at a file moves the list onto its row")

  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/util/strings.lua"))
  eq(cursor(), row_of("util/strings.lua"), "and onto the next one's when you move on")

  -- Read the list, then go back to the file you were already in. The
  -- index has not changed, so nothing is redrawn -- and the cursor was
  -- still put back, because that is the whole of the mark.
  local strings_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_current_win(pane.list_win)
  pcall(vim.api.nvim_win_set_cursor, pane.list_win, { row_of("helper.lua"), 0 })
  ok(cursor() ~= row_of("util/strings.lua"), "the list can be read somewhere else by hand")
  vim.api.nvim_set_current_win(code_win)
  vim.api.nvim_set_current_buf(strings_buf)
  eq(cursor(), row_of("util/strings.lua"),
    "and coming back to the file puts the cursor back on its row")

  -- A buffer the list has no row for is not a reason to move the mark off
  -- the file you were reading.
  local was = cursor()
  vim.api.nvim_set_current_buf(scratch)
  eq(cursor(), was, "an unlisted buffer leaves the list pointing where it was")

  -- Put the reader back where the section before this one left them: the
  -- suite is one session, and the next section reads the buffer it is
  -- standing in.
  vim.api.nvim_win_set_buf(code_win, code_buf)
  vim.api.nvim_set_current_win(back_win)
  vim.api.nvim_set_current_buf(back_buf)
end

print("\n[closing]")
do
  local list_win = pane.list_win
  local wins = #vim.api.nvim_tabpage_list_wins(0)
  pane_mod.close(pane)
  ok(not vim.api.nvim_win_is_valid(list_win), "closing the pane closes its window")
  eq(#vim.api.nvim_tabpage_list_wins(0), wins - 1, "and only its window")
  ok(pane_mod.get() == nil, "and unregisters it")
  eq(vim.api.nvim_buf_call(scratch, function()
    return vim.fn.maparg(require("uatis.config").keys.pane.file_prev, "n")
  end), "", "and hands back the keys it lent")

  local buf = vim.api.nvim_get_current_buf()
  ok(view_mod.get(buf) ~= nil, "the diff view is not the pane's to close")

  -- Every buffer the review annotated as it followed the reader around,
  -- not merely the one they happen to be standing in: a mode that had to
  -- be turned off once per file would never be all the way off.
  local elsewhere = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if b ~= buf and view_mod.get(b) then
      table.insert(elsewhere, b)
    end
  end
  ok(#elsewhere > 0, "the review is on more than one buffer, got " .. #elsewhere)

  uatis.toggle_diff()
  ok(view_mod.get(buf) == nil, "toggling again ends it")
  local left = vim.tbl_filter(function(b) return view_mod.get(b) ~= nil end, elsewhere)
  eq(#left, 0, "and every other file it had annotated with it")
  eq(#vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1, {}), 0, "and clears every mark")
  eq(vim.wo.winbar, "", "leaving no winbar line above the file")

  -- ...and the list goes with it, whatever revision the list had got to.
  -- The two can drift apart -- a view pinned by `:Uatis <ref>` beside a
  -- list that followed a base change -- and a list left up goes on
  -- annotating the next file opened, which is what the key just said to
  -- stop.
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
  uatis.toggle_diff()
  wait_for(function()
    local p = pane_mod.get()
    return p ~= nil and (p.renders or 0) > 0
  end, "a review to end again")
  local drifted = pane_mod.get()
  ok(drifted ~= nil, "a review is running, with a list")
  drifted.rev = "0000000000000000000000000000000000000000"
  uatis.toggle_diff()
  ok(pane_mod.get() == nil, "ending the review takes the list with it")
  ok(not (drifted.list_win and vim.api.nvim_win_is_valid(drifted.list_win)),
    "and the window it was in")

  -- A review reached from two tabs is one review: the views are, since
  -- they are closed by root and revision wherever they are, and the
  -- lists have to be too. The second one used to be left running --
  -- annotating every file opened in that tab, for a review that was
  -- over.
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
  uatis.toggle_diff()
  wait_for(function()
    local p = pane_mod.get()
    return p ~= nil and (p.renders or 0) > 0
  end, "a review to reach from two tabs")
  vim.cmd("tab split")
  pane_mod.open({ focus = false })
  wait_for(function()
    local p = pane_mod.get()
    return p ~= nil and (p.renders or 0) > 0
  end, "the same review listed in the second tab")
  eq(#pane_mod.all(), 2, "the same review, listed in two tabs")
  vim.cmd("tabprevious")
  uatis.toggle_diff()
  eq(#pane_mod.all(), 0, "ending it in one ends it in both")
  vim.cmd("silent! tabnext")
  if vim.fn.tabpagenr("$") > 1 then
    vim.cmd("silent! tabclose")
  end

  -- The same from a buffer with nothing to compare: a scratch buffer, a
  -- terminal, the empty one nvim started in. The key means the review,
  -- not the window -- closing the window alone would leave every file it
  -- had annotated annotated, with nothing left on screen to end it by.
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
  local annotated = vim.api.nvim_get_current_buf()
  uatis.toggle_diff()
  wait_for(function()
    local p = pane_mod.get()
    return p ~= nil and (p.renders or 0) > 0 and view_mod.get(annotated) ~= nil
  end, "a review to end from somewhere else")
  vim.cmd("enew")
  ok(view_mod.can_open(vim.api.nvim_get_current_buf()) == false,
    "standing in a buffer with no file")
  uatis.toggle_diff()
  ok(pane_mod.get() == nil, "which ends the review from there too")
  ok(view_mod.get(annotated) == nil, "annotations and all")

  vim.cmd("silent! tabclose")
  vim.fn.system({ "git", "-C", fixture, "switch", "-qf", "main" })
end

print("\n[a review begun from the empty buffer lands on its first file]")
-- Starting nvim in a repository and pressing the key: nothing here to
-- annotate, and nobody is here for this buffer either. The list is
-- read and the first file it names opens where the empty buffer was,
-- with the list beside it -- the same landing as a review begun from a
-- file, one `]f` earlier.
do
  vim.fn.system({ "git", "-C", fixture, "switch", "-qf", "feature/math" })
  vim.cmd("tabnew")
  local here, empty = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  ok(vim.api.nvim_buf_get_name(empty) == "" and not vim.bo[empty].modified,
    "standing in the empty buffer")
  -- The fixture's root is not the cwd, so the question is asked of it.
  vim.cmd("lcd " .. vim.fn.fnameescape(fixture))

  uatis.toggle_diff()
  wait_for(function()
    local p = pane_mod.get()
    return p ~= nil and (p.renders or 0) > 0
      and vim.api.nvim_win_get_buf(here) ~= empty
      and view_mod.get(vim.api.nvim_win_get_buf(here)) ~= nil
  end, "the first file to open in the window the empty buffer was in")
  local p = pane_mod.get()
  local landed = vim.api.nvim_win_get_buf(here)
  eq(vim.api.nvim_buf_get_name(landed), fixture .. "/" .. p.files[1].path,
    "and it is the first file the list names")
  eq(p.file_idx, 1, "which the list points at")
  eq(vim.api.nvim_get_current_win(), here,
    "with the cursor in the file rather than in the list")
  ok(p.list_win and vim.api.nvim_win_is_valid(p.list_win), "and the list up beside it")

  -- A buffer someone is using is left alone: the list goes up and
  -- takes the cursor, and which file to open is the reader's call.
  view_mod.stop(view_mod.get(landed))
  wait_for(function() return pane_mod.get() == nil end, "the review to end")
  vim.cmd("enew")
  local typed = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(typed, 0, -1, false, { "notes" })
  local typed_win = vim.api.nvim_get_current_win()
  uatis.toggle_diff()
  wait_for(function()
    local q = pane_mod.get()
    return q ~= nil and (q.renders or 0) > 0
  end, "the list to be read from a buffer being typed into")
  eq(vim.api.nvim_win_get_buf(typed_win), typed, "the buffer typed into is still there")
  eq(vim.api.nvim_get_current_win(), pane_mod.get().list_win, "and the list has the cursor")
  pane_mod.close(pane_mod.get())
  vim.bo[typed].modified = false

  vim.cmd("silent! tabclose")
  vim.fn.system({ "git", "-C", fixture, "switch", "-qf", "main" })
end

print("\n[the layout is the review's, and ends with it]")
-- `]f` closes one view and opens the next as a new one, and a reader who
-- put the old revision beside the first file wants it beside the second
-- too -- not the default back every time the list moves on. The choice
-- is kept on the list, which is what outlives the view, and goes when
-- the review does: the next review starts at the default like anything
-- else.
do
  local oldside = require("uatis.oldside")
  local kv = require("uatis.config").keys.view
  local ko = require("uatis.config").keys.old

  vim.fn.system({ "git", "-C", fixture, "switch", "-qf", "feature/math" })
  vim.cmd("tabnew " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
  local first = vim.api.nvim_get_current_buf()

  local function press(lhs)
    local m = vim.fn.maparg(lhs, "n", false, true)
    ok(m and m.callback ~= nil, "the buffer binds " .. lhs)
    if m and m.callback then
      m.callback()
    end
  end
  -- The view on the buffer under the cursor, once it is drawn in the
  -- layout the review has chosen: side by side, the old window opens
  -- off a blob fetch of its own, and a view whose marks have landed can
  -- still be waiting on it.
  local function settled(path)
    local buf = vim.api.nvim_get_current_buf()
    wait_for(function()
      local v = view_mod.get(buf)
      return v ~= nil and v.relpath == path and (v.renders or 0) > 0
        and (v.layout ~= "side" or oldside.is_open(v))
    end, "a view over " .. path .. " in the review's layout")
    return view_mod.get(buf) or {}
  end

  uatis.run({ fargs = { "main" } })
  local view = settled("calc.lua")
  wait_for(function()
    local p = pane_mod.get()
    return p ~= nil and (p.renders or 0) > 0
  end, "the list to be read")
  local p = pane_mod.get()
  eq(view.layout, "inline", "a view starts in place")
  eq(p.layout, nil, "and the review has no layout chosen yet")

  press(kv.layout)
  eq(view.layout, "side", kv.layout .. " puts the old side in a window")
  eq(p.layout, "side", "which is the review's choice, not the file's")

  press(kv.file_next)
  local second = settled("doomed.lua")
  ok(vim.api.nvim_get_current_buf() ~= first, "]f moves on to the next file")
  eq(second.layout, "side", "which comes up side by side too")
  ok(oldside.is_open(second), "with the old revision in a window beside it")
  -- ...holding the revision. Opened before the first render, the old
  -- window was filled while `old_text` was still nil, and the render
  -- that then landed laid it out from a cache of that: every row blank,
  -- with the removal marks drawn on the blanks. Content that appeared
  -- only on the next render -- a switch of backend and back.
  local shown = {}
  for _, l in ipairs(vim.api.nvim_buf_get_lines(second.old.buf, 0, -1, false)) do
    if l ~= "" then
      table.insert(shown, l)
    end
  end
  local revision = {}
  for _, l in ipairs(vim.split(second.old_text or "", "\n", { plain = true })) do
    if l ~= "" then
      table.insert(revision, l)
    end
  end
  eq(shown, revision, "and the old window holds the revision's lines, not blanks")
  ok(view_mod.get(first) == nil, "and the file left behind is closed")
  local olds = 0
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if oldside.view_for(vim.api.nvim_win_get_buf(w)) then
      olds = olds + 1
    end
  end
  eq(olds, 1, "its old window with it: one old side on screen, not two")

  press(kv.file_prev)
  local back = settled("calc.lua")
  eq(back.layout, "side", "and back again the same way")
  eq(p.layout, "side", "the review still says so")

  -- The same key from the other window: the layout is two windows, and
  -- a toggle that answered from only one of them was half a toggle.
  -- `q` in there is the same choice under another name -- a close that
  -- left the review saying "side" had the next file come up beside a
  -- revision the reader had just dismissed.
  vim.api.nvim_set_current_win(back.old.win)
  press(kv.layout)
  eq(back.layout, "inline", kv.layout .. " in the old window goes back in place")
  ok(not oldside.is_open(back), "closing that window")
  eq(vim.api.nvim_get_current_win(), back.win, "and leaves the cursor in your file")
  eq(p.layout, "inline", "as the review's choice")
  press(kv.layout)
  wait_for(function() return oldside.is_open(back) end, "the old window to open again")
  vim.api.nvim_set_current_win(back.old.win)
  press(ko.quit)
  eq(back.layout, "inline", ko.quit .. " in the old window is the same choice")
  eq(p.layout, "inline", "for the review")
  eq(vim.api.nvim_get_current_win(), back.win, "with the cursor back in your file")
  press(kv.layout)
  wait_for(function() return oldside.is_open(back) end, "the old window to open once more")

  -- Switched back in one file, it is switched back for the rest.
  press(kv.layout)
  eq(back.layout, "inline", "pressing the key again goes back in place")
  eq(p.layout, "inline", "for the review")
  press(kv.file_next)
  local third = settled("doomed.lua")
  eq(third.layout, "inline", "and the next file comes up in place")
  ok(not oldside.is_open(third), "with no old window")

  -- Ending the review ends the choice: the next one starts at the
  -- default, however the last one was left.
  press(kv.layout)
  eq(p.layout, "side", "left side by side")
  view_mod.stop(view_mod.get(vim.api.nvim_get_current_buf()))
  wait_for(function() return pane_mod.get() == nil end, "the review to end")
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    ok(oldside.view_for(vim.api.nvim_win_get_buf(w)) == nil,
      "ending the review takes the old window with it")
  end

  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
  uatis.run({ fargs = { "main" } })
  local again = settled("calc.lua")
  wait_for(function()
    local q = pane_mod.get()
    return q ~= nil and (q.renders or 0) > 0
  end, "the list to be read again")
  eq(again.layout, "inline", "a new review starts in place")
  eq(pane_mod.get().layout, nil, "with no layout chosen")
  view_mod.stop(again)
  wait_for(function() return pane_mod.get() == nil end, "the review to end")

  vim.cmd("silent! tabclose")
  vim.fn.system({ "git", "-C", fixture, "switch", "-qf", "main" })
end

print("\n[re-reading a file is not leaving it]")
-- `:e` is what a reader does when something else has written the file
-- they are reviewing. Neovim reads it back into the SAME buffer and the
-- same window, and drops every `nvim_buf_attach` doing it -- so the
-- review used to end on the one gesture most likely to be aimed at it.
--
-- Last, and on a tab and a review of its own: this section edits past a
-- file on purpose, and every section above it is about a layout.
do
  vim.fn.system({ "git", "-C", fixture, "switch", "-qf", "feature/math" })
  vim.cmd("tabnew " .. vim.fn.fnameescape(fixture .. "/util/strings.lua"))
  local buf = vim.api.nvim_get_current_buf()

  require("uatis").run({ fargs = { "main" } })
  wait_for(function()
    local v = view_mod.get(buf)
    return v ~= nil and (v.renders or 0) > 0
  end, "a view to re-read under")
  local v = view_mod.get(buf)
  local rev, renders = v.rev, v.renders
  local ns = require("uatis.overlay").ns
  ok(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) > 0, "with marks on it")

  local list = pane_mod.get()
  wait_for(function() return list ~= nil and (list.renders or 0) > 0 end,
    "a list beside it")
  local list_renders = list and list.renders or 0

  vim.cmd("edit!")
  wait_for(function()
    local now = view_mod.get(buf)
    return now ~= nil and (now.renders or 0) > renders
  end, "the view to draw itself again after the re-read")

  eq(view_mod.get(buf), v, "the review survives `:e`, as the same view")
  eq(view_mod.get(buf).rev, rev, "still measured against the same revision")
  ok(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) > 0,
    "and its marks are back -- re-reading takes the buffer's extmarks with it")

  -- The list goes with it. `:e` says the disk moved under us, and the
  -- list is `git diff` against that disk -- redrawing the buffer and
  -- leaving the counts beside it as they were says the write never
  -- happened.
  wait_for(function() return (list.renders or 0) > list_renders end,
    "the list to be re-read after the file was")
  ok((list.renders or 0) > list_renders,
    "re-reading a file re-reads the list beside it")

  -- The attachment has to come back with the marks, or the next edit
  -- goes unnoticed and they describe text that is no longer there.
  local again = view_mod.get(buf).renders
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "-- touched" })
  wait_for(function()
    local now = view_mod.get(buf)
    return now ~= nil and (now.renders or 0) > again
  end, "an edit after the re-read to redraw")
  ok(view_mod.get(buf) ~= nil, "and the edit is still being watched for")

  -- Leaving the buffer behind in the window still ends the review. That
  -- is what `BufWinLeave` is for, and it does not fire for a re-read.
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/stable.lua"))
  wait_for(function() return view_mod.get(buf) == nil end,
    "editing past the file to end the review on it")
  ok(view_mod.get(buf) == nil, "editing another file into the window still ends it")

  vim.fn.system({ "git", "-C", fixture, "switch", "-qf", "main" })
end

print("\n[one commit, on its own]")
-- The other question about history. Reading YOUR branch a commit at a
-- time is a mode inside a review of it; this is a commit that has
-- nothing to do with what you are working on, on a branch this checkout
-- is nowhere near -- and it opens in a tab of its own, because a review
-- is a mode over a tabpage and taking the one the reader is standing in
-- would end the review they already had.
do
  local function sha_of(subject)
    return vim.trim(vim.fn.system({ "git", "-C", fixture, "log", "--all",
      "--format=%H", "-1", "--grep=" .. subject }))
  end

  -- The branch checked out, because half of this is about a review of
  -- it running beside a review of one of its commits. The section above
  -- left `main`.
  vim.fn.system({ "git", "-C", fixture, "switch", "-qf", "feature/math" })
  vim.cmd("silent! tabonly")
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/stable.lua"))
  -- Whatever the sections above left running. This one is about two
  -- reviews being open at once, so it has to know which two.
  local stale = pane_mod.get()
  if stale then
    view_mod.close_all(stale.root, stale.rev)
    pane_mod.close(stale)
    vim.wait(200)
  end
  local home = vim.api.nvim_get_current_tabpage()
  local tabs = #vim.api.nvim_list_tabpages()

  local rename = sha_of("drop doomed, rename module")
  uatis.show_commit(rename)
  wait_for(function()
    local p = pane_mod.get()
    return p ~= nil and p.standalone and (p.renders or 0) > 0 and #p.files > 0
  end, "a review of one commit")
  local p = pane_mod.get()
  eq(#vim.api.nvim_list_tabpages(), tabs + 1, "it opens in a tab of its own")
  ok(p.owns_tab, "which it knows is its own")
  -- ...named after the commit, for a tabline that shows names. The tab
  -- holds one commit and nothing else, and its number says nothing
  -- about which.
  eq(vim.fn.gettabvar(vim.api.nvim_tabpage_get_number(p.tab), "tabname", ""),
    p.commit.short, "and the tab is named after the commit")
  eq(p.rev, vim.trim(vim.fn.system({ "git", "-C", fixture, "rev-parse", rename .. "^" })),
    "measured against the commit's parent")
  eq(p.target, p.commit.short .. "^", "named as the commit before this one")
  eq(p.src, p.commit.short, "with the commit itself as the new side")
  eq(#p.files, 2, "and the list is that commit's own files")

  -- `q` from anywhere in the tab, and not only from the list. Nothing
  -- else is ever in a tab `:UatisShow` opened: every window in it is
  -- this review, and a reader three files deep into it should not have
  -- to find the list again to press the key that means "done".
  do
    local quit = require("uatis.config").keys.pane.quit
    wait_for(function()
      return view_mod.get(vim.api.nvim_get_current_buf()) ~= nil
    end, "the commit's first file, annotated")
    local mapped = vim.fn.maparg(quit, "n", false, true)
    eq(mapped.buffer, 1, "`q` is lent to the file being read in a tab of the review's own")
    ok((mapped.desc or ""):find("commit", 1, true) ~= nil,
      "and it closes the commit rather than the list, got " .. tostring(mapped.desc))
  end

  -- The header counts a commit against the walk it is one of, and there
  -- is no walk here: `1/1` would be a number answering nothing.
  --
  -- Nor is there a second side to name. `<sha>^ ← <sha>` is the same
  -- sha twice with a caret on one of them, and "against its parent" is
  -- the only thing `:UatisShow` ever means -- so the sha alone, with
  -- the subject under it, which is what names a commit to a person.
  local keys_of_pane = require("uatis.config").keys.pane
  local head = require("uatis.ui").build_list(p, 38).lines
  ok(vim.trim(head[1]):find(p.commit.short, 1, true) == 1,
    "the header names the commit, got " .. vim.trim(head[1]))
  ok(not contains(vim.tbl_map(vim.trim, head), p.commit.short .. "^ ← " .. p.commit.short),
    "and not the same sha twice")
  ok(not contains(head, "1/1"), "and counts it against no walk")
  -- Sha, when, who on one row: that is one fact about a commit, and
  -- reading it off three rows is the reader assembling it.
  ok(vim.trim(head[1]):find(p.commit.date, 1, true) ~= nil,
    "with when it was made on the same row, got " .. vim.trim(head[1]))
  eq(vim.trim(head[2] or ""), "drop doomed, rename module",
    "and the message under it, on its own, got " .. table.concat(head, " | "))

  -- ...and that row never wraps. The fixture's author does not fit
  -- beside the rest, and half a name on a row of its own -- or, in a
  -- walk, half a SHA -- is worse than a field that is simply not there.
  local narrow = require("uatis.ui").build_list(p, 30).lines
  ok(vim.trim(narrow[1]):find(p.commit.short, 1, true) == 1
    and vim.trim(narrow[2] or "") == "drop doomed, rename module",
    "a narrow pane drops fields off the row rather than wrapping it, got "
      .. vim.inspect({ narrow[1], narrow[2] }))

  -- The body is the half of a message that says WHY, and a review is
  -- exactly the activity that wants it -- so it is a keypress away
  -- rather than absent.
  ok(offered(p):find(keys_of_pane.commit_message .. " its whole message", 1, true) ~= nil,
    "and the whole message a keypress away, got " .. offered(p))

  -- `g?` puts all of that on screen. One key in the header, and the key
  -- answers completely -- which is the trade: the hint used to name a
  -- third of them, taught the reader only that third, and did it on
  -- every render forever.
  do
    local wins = #vim.api.nvim_tabpage_list_wins(0)
    local win = pane_mod.peek_keys(p)
    ok(win ~= nil and #vim.api.nvim_tabpage_list_wins(0) > wins,
      "the key float opens")
    local said = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
    local flat = table.concat(vim.tbl_map(function(l)
      return (vim.trim(l):gsub("%s+", " "))
    end, said), " | ")
    ok(flat:find("<CR> open the file on this row", 1, true) ~= nil,
      "carrying this list's own keys, got " .. flat)
    ok(flat:find(require("uatis.config").keys.global.toggle_diff .. " start or end",
      1, true) ~= nil, "and the global ones, which are not bound here, got " .. flat)
    -- Searched by what the row SAYS, not by the bare letter: `C` is
    -- inside `<CR>` on the row above it.
    ok(flat:find("read the branch one commit at a time", 1, true) == nil
      and flat:find("back to the whole branch", 1, true) == nil,
      "and still nothing that has nowhere to go, got " .. flat)
    vim.api.nvim_win_close(win, true)
    eq(#vim.api.nvim_tabpage_list_wins(0), wins, "and closing it puts the window back")
  end

  do
    local wins = #vim.api.nvim_tabpage_list_wins(0)
    pane_mod.peek_commit(p)
    wait_for(function()
      return #vim.api.nvim_tabpage_list_wins(0) > wins
    end, "the message float to open")
    local float = vim.api.nvim_get_current_win()
    local said = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(float), 0, -1, false)
    ok(contains(said, "drop doomed, rename module"),
      "the float carries the subject, got " .. vim.inspect(said))
    ok(vim.trim(said[1] or ""):find(p.commit.short, 1, true) == 1,
      "under the sha it belongs to, got " .. tostring(said[1]))
    -- `q` closes it, and the reader is back where they were.
    vim.api.nvim_win_close(float, true)
    eq(#vim.api.nvim_tabpage_list_wins(0), wins, "and closing it puts the window back")
  end

  -- Neither of the keys that move within a walk has anywhere to go, so
  -- they are not offered. A key that answers "there is only this one"
  -- is a key the reader spends a press to disbelieve.
  local keys = keys_of_pane
  ok(offered(p):find(keys.commit_view .. " ", 1, true) == nil,
    "no way out is offered to a branch there is none of, got " .. offered(p))
  ok(offered(p):find(keys.commit_prev .. " " .. keys.commit_next, 1, true) == nil,
    "nor a walk to step, got " .. offered(p))

  -- The file is shown as it was, always: a finished commit is not the
  -- reader's buffer, whatever today's copy of the file happens to say.
  wait_for(function()
    return vim.api.nvim_buf_get_name(0):match("^uatis://") ~= nil
  end, "the commit's first file to be opened")
  local buf = vim.api.nvim_get_current_buf()
  ok(not vim.bo[buf].modifiable, "read-only, because it is not the reader's file")
  local v = view_mod.get(buf)
  eq(v and v.rev, p.rev, "and it is measured against the same revision as the list")

  -- Neither of the two keys does anything, and both say so rather than
  -- doing something else: `C` would otherwise mean the commit's PARENT
  -- against the working tree, which is nobody's question.
  local said = {}
  local real_notify = vim.notify
  vim.notify = function(msg) table.insert(said, msg) end
  pane_mod.toggle_commits(p)
  pane_mod.step_commit(p, 1)
  wait_for(function() return #said > 1 end, "uatis to say there is only this commit")
  vim.notify = real_notify
  ok(said[1]:find("one commit", 1, true) ~= nil, "the toggle says so, got " .. said[1])
  ok(said[2]:find("one commit", 1, true) ~= nil, "and so does stepping, got " .. said[2])
  ok(p.standalone and p.commit ~= nil, "and the review is still that one commit")

  -- Nothing the working tree does can move it. `git diff <parent>
  -- <commit>` is a fact about two revisions, and neither of them is the
  -- tree -- so the watchers that keep a branch review honest are not
  -- even set up here.
  local turns = p.renders
  vim.cmd("tabnew " .. vim.fn.fnameescape(fixture .. "/stable.lua"))
  vim.cmd("silent write")
  vim.cmd("doautocmd FocusGained")
  vim.wait(300)
  eq(p.renders, turns, "a write and a FocusGained re-read nothing")
  vim.cmd("silent! tabclose")

  -- A commit whose parent is the fork point of a review running
  -- elsewhere -- the first commit of the branch -- is the case where
  -- one root and one revision describe two different readings. Ending
  -- the branch review must not take this one with it.
  local first = sha_of("fix sub argument order and add mul")
  vim.api.nvim_set_current_tabpage(p.tab)
  uatis.show_commit(first)
  wait_for(function()
    local q = pane_mod.get()
    return q ~= nil and q ~= p and q.standalone and (q.renders or 0) > 0 and #q.files > 0
  end, "a review of the branch's first commit")
  local one = pane_mod.get()
  -- ...opened on what it did rather than at the top of the file: the
  -- change is what a commit is read for.
  wait_for(function()
    local v = view_mod.get(vim.api.nvim_get_current_buf())
    return v ~= nil and (v.renders or 0) > 0
  end, "the first commit's file to draw")
  local drawn = view_mod.get(vim.api.nvim_get_current_buf())
  ok(drawn.anchors[1] ~= nil and drawn.anchors[1] > 1,
    "its first change is below the top of the file")
  eq(vim.api.nvim_win_get_cursor(0)[1], drawn.anchors[1],
    "and the commit opens with the cursor on it")
  pane_mod.close(p)
  vim.wait(200)

  vim.api.nvim_set_current_tabpage(home)
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
  base.set(root, "main")
  uatis.toggle_diff()
  wait_for(function()
    local q = pane_mod.get()
    return q ~= nil and q ~= one and (q.renders or 0) > 0
  end, "a review of the branch beside it")
  local branch = pane_mod.get()
  eq(branch.rev, one.rev, "the two reviews are one root and one revision")

  -- ...and not lent in a tab the reader was already working in. There
  -- `q` is theirs -- it records a macro -- and the list's own `q` puts
  -- the list down without ending anything.
  eq(vim.fn.maparg(require("uatis.config").keys.pane.quit, "n", false, true).buffer or 0, 0,
    "`q` stays the reader's own in a tab this review did not open")

  -- Ending the one you are standing in ends that one. From the commit's
  -- own tab it takes the tab with it, and the branch review beside it
  -- goes on running.
  vim.api.nvim_set_current_tabpage(one.tab)
  local at = view_mod.get(vim.api.nvim_get_current_buf())
  ok(at ~= nil and at.standalone,
    "the commit's file carries a view of the commit's own review")
  local was = #vim.api.nvim_list_tabpages()
  uatis.toggle_diff()
  wait_for(function() return pane_mod.get(one.tab) == nil end, "the commit review to end")
  eq(#vim.api.nvim_list_tabpages(), was - 1, "ending it takes the tab it opened")
  ok(pane_mod.get(branch.tab) ~= nil, "and leaves the branch review running")

  -- ...and the other way round, which is the one that would take a tab
  -- the reader is not even looking at.
  vim.api.nvim_set_current_tabpage(branch.tab)
  uatis.show_commit(first)
  wait_for(function()
    local q = pane_mod.get()
    return q ~= nil and q.standalone and (q.renders or 0) > 0 and #q.files > 0
  end, "that commit read on its own again")
  local two = pane_mod.get()
  vim.api.nvim_set_current_tabpage(branch.tab)
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
  wait_for(function() return view_mod.get(vim.api.nvim_get_current_buf()) ~= nil end,
    "a file of the branch review to stand in")
  uatis.toggle_diff()
  wait_for(function() return pane_mod.get(branch.tab) == nil end, "the branch review to end")
  ok(pane_mod.get(two.tab) ~= nil,
    "which leaves the commit read in another tab alone")
  ok(vim.api.nvim_tabpage_is_valid(two.tab), "and the tab it is in")

  -- ...and `q` from the file rather than from the list ends it and
  -- takes that tab with it. Nothing else was ever in the tab, so
  -- "close this window" and "close this commit" are the same thing
  -- wherever in it the key is pressed.
  vim.api.nvim_set_current_tabpage(two.tab)
  wait_for(function()
    return view_mod.get(vim.api.nvim_get_current_buf()) ~= nil
  end, "to be standing in the commit's own file")
  local tabs_before_q = #vim.api.nvim_list_tabpages()
  vim.api.nvim_feedkeys(
    vim.keycode(require("uatis.config").keys.pane.quit), "x", false)
  wait_for(function() return pane_mod.get(two.tab) == nil end,
    "`q` in the file to end the commit review")
  eq(#vim.api.nvim_list_tabpages(), tabs_before_q - 1,
    "and to take the tab it opened with it")
  vim.wait(200)

  -- A commit with no parent at all. Every line of it arrived, so it is
  -- measured against the empty tree -- and there is no `<sha>^` to name.
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/stable.lua"))
  uatis.show_commit(sha_of("initial"))
  wait_for(function()
    local q = pane_mod.get()
    return q ~= nil and q.standalone and (q.renders or 0) > 0 and #q.files > 0
  end, "a review of the first commit in the repository")
  local root_commit = pane_mod.get()
  eq(root_commit.target, "nothing", "which is measured against nothing, and says so")
  eq(root_commit.stat_removed, 0, "nothing was taken away by it")
  ok(root_commit.stat_added > 0, "and every line of it arrived, got "
    .. root_commit.stat_added)
  pane_mod.close(root_commit)
  vim.wait(200)

  -- A rev that names nothing opens no tab: the answer is git's, said
  -- once, in a line the reader can read.
  said = {}
  vim.notify = function(msg) table.insert(said, msg) end
  local before = #vim.api.nvim_list_tabpages()
  uatis.show_commit("no-such-revision")
  wait_for(function() return #said > 0 end, "uatis to say there is no such commit")
  vim.notify = real_notify
  ok(said[1]:find("no commit at no-such-revision", 1, true) ~= nil,
    "a rev that names nothing says so, got " .. said[1])
  eq(#said[1]:gsub("[^\n]", ""), 0, "in one line, not in git's four")
  eq(#vim.api.nvim_list_tabpages(), before, "and opens no tab for it")

  -- The command completes commits for any lead, where `:Uatis` takes
  -- them only for a hex-shaped one: here a commit is not the unusual
  -- answer, it is the whole question -- and `prompt.rank` matches a
  -- commit on its subject, which is how anyone remembers one.
  -- A commit this checkout is nowhere near: `unrelated work on main`
  -- is not on the branch HEAD is sitting on, and none of the above
  -- needed it to be. That is the usual case for the question this
  -- command answers -- somebody else's commit, somewhere else.
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/stable.lua"))
  uatis.show_commit(sha_of("unrelated work on main"))
  wait_for(function()
    local q = pane_mod.get()
    return q ~= nil and q.standalone and (q.renders or 0) > 0 and #q.files > 0
  end, "a review of a commit on another branch")
  local elsewhere = pane_mod.get()
  eq(#elsewhere.files, 1, "a commit off this branch is read the same way")
  eq(elsewhere.files[1].path, "unrelated.lua", "with its own file")
  pane_mod.close(elsewhere)
  vim.wait(200)

  local by_subject = uatis.complete_show("clamp")
  ok(contains(by_subject, sha_of("add clamp helper"):sub(1, 7)),
    "a commit is found by what it did, got " .. table.concat(by_subject, ", "))
  local bare = uatis.complete_show("")
  for _, word in ipairs(bare) do
    ok(not word:match("^%x%x%x%x%x%x%x$") or word == "main",
      "while nothing typed is still no list of hashes, got " .. word)
  end

  vim.fn.system({ "git", "-C", fixture, "switch", "-qf", "main" })
end

print("\n[everything since a revision]")
-- The other half of the pair above, and the difference is what is being
-- measured: that one reads what a commit DID, against its parent, in a
-- tab of its own; this one is the ordinary review -- your buffers, where
-- you are standing -- pointed at a revision you picked instead of at the
-- fork point. `:Uatis <rev>` without typing the rev.
do
  local function sha_of(subject)
    return vim.trim(vim.fn.system({ "git", "-C", fixture, "log", "--all",
      "--format=%H", "-1", "--grep=" .. subject }))
  end

  vim.fn.system({ "git", "-C", fixture, "switch", "-qf", "feature/math" })
  vim.cmd("silent! tabonly")
  vim.cmd("silent! only")
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
  local buf = vim.api.nvim_get_current_buf()
  local stale = view_mod.get(buf)
  if stale then
    view_mod.stop(stale)
    vim.wait(200)
  end

  -- The reader's own tab, which they may already have named.
  vim.t.tabname = "mine"
  local initial = sha_of("initial")
  uatis.since_commit(initial)
  wait_for(function()
    local v = view_mod.get(buf)
    local q = pane_mod.get()
    return v ~= nil and (v.renders or 0) > 0 and q ~= nil and (q.renders or 0) > 0
  end, "a review since the first commit")

  -- In a tab of the reader's own, with their own work in it, whatever
  -- name it has is theirs: a review that runs here names nothing.
  eq(vim.t.tabname, "mine", "the reader's tab keeps its own name")

  local v = view_mod.get(buf)
  eq(v.ref, initial, "the view names the revision it was handed")
  eq(v.rev, initial, "and measures against that revision itself")
  ok(v.tracks_base ~= true,
    "pinned, not following the base branch: a revision named by hand was meant")
  -- The reader's own buffer, which is the whole premise. `<leader>gA`
  -- draws a finished commit in a buffer of its own; this is a review of
  -- where the tree has got to, so the new side is the file being edited.
  eq(vim.api.nvim_get_current_buf(), buf, "in the buffer the reader was in")
  ok(vim.bo[buf].modifiable, "still writable")

  local p = pane_mod.get()
  ok(p ~= nil, "with the changed-file list beside it")
  ok(p and not p.standalone, "as an ordinary review, not one commit on show")
  eq(p and p.rev, initial, "listing what has changed since the same revision")
  ok(p and #p.files > 1,
    "over every file that has moved since, got " .. tostring(p and #p.files))

  uatis.toggle_diff()
  wait_for(function() return pane_mod.get() == nil end, "the review to end")
  eq(vim.t.tabname, "mine", "and still has it after")
  vim.t.tabname = nil

  vim.fn.system({ "git", "-C", fixture, "switch", "-qf", "main" })
end

print("\n[the colour dial]")
-- Colour is the one thing here that cannot be settled by reading the
-- code: every number in `config.highlight` is a statement about a
-- colourscheme this repository has never seen. The dial is how a reader
-- looks at theirs -- so what is asserted is that it turns the numbers,
-- that the screen follows, and that it offers every number there is.
do
  local colors = require("uatis.colors")
  local hl = require("uatis.config").highlight
  local function press(key)
    local m = vim.fn.maparg(key, "n", false, true)
    if not (m and m.callback) then
      return false
    end
    m.callback()
    return true
  end
  local function bg(name)
    return vim.api.nvim_get_hl(0, { name = name, link = false }).bg
  end

  vim.cmd("silent! only")
  local wins = #vim.api.nvim_list_wins()
  colors.open()
  ok(colors.get() ~= nil, "the dial opens")
  local lines = vim.api.nvim_buf_get_lines(colors.get().buf, 0, -1, false)
  local text = table.concat(lines, "\n")

  -- Every number in the table, not the ones somebody remembered. A
  -- setting added to `config.highlight` and left out of here is a
  -- colour with no way to look at it, which is the one thing this is
  -- for.
  local missing = {}
  for key, v in pairs(hl) do
    if type(v) == "number" and not text:find(key, 1, true) then
      table.insert(missing, key)
    end
  end
  eq(missing, {}, "and offers every number config.highlight has")

  -- The live half. `setup_highlights` writes each group by name and
  -- every mark on screen carries the name rather than the colour, so
  -- re-deriving is a repaint of a review that was never re-rendered.
  ok(press("j"), "j steps to the next setting")
  eq(vim.api.nvim_get_current_line():match("^%s+([%w_]+)"), "add_lightness",
    "which is the one below the first")
  local was, before = hl.add_lightness, bg("UatisAdd")
  ok(press("L"), "L turns it up")
  ok(hl.add_lightness > was, "the number moves, got " .. hl.add_lightness)
  ok(bg("UatisAdd") ~= before,
    "and the tint is re-derived with it, without a view being rendered")
  ok(press("r"), "r puts the row back as it was")
  eq(hl.add_lightness, was, "the number with it")
  eq(bg("UatisAdd"), before, "and the colour")

  -- A colour named outright switches off the derivation above it, and
  -- the dial says so rather than going on offering a number that now
  -- decides nothing.
  hl.delete_bg = 0x402020
  press("j")
  press("l")
  press("h")
  local named = table.concat(vim.api.nvim_buf_get_lines(colors.get().buf, 0, -1, false), "\n")
  ok(named:find("named outright", 1, true) ~= nil, "a colour set by hand is listed")
  ok(named:match("delete_lightness%s+[%d.]+%s+[^\n]*overridden") ~= nil,
    "and the derivation it replaces is marked as replaced")
  hl.delete_bg = nil

  ok(press("q"), "q closes it")
  ok(colors.get() == nil, "and the dial is gone")
  eq(#vim.api.nvim_list_wins(), wins, "leaving the windows it found")

  -- The block is what a reader keeps: every number, so that a default
  -- moving here cannot quietly move a palette somebody tuned by hand.
  local saturation = hl.saturation
  colors.open()
  press("l")
  ok(load(table.concat(colors.snippet(), "\n")) ~= nil, "the printed block is Lua")
  ok(colors.snippet()[3]:find("saturation = " .. ("%.2f"):format(hl.saturation), 1, true) ~= nil,
    "carrying the numbers as they now are, got " .. colors.snippet()[3])
  ok(press("p"), "p yanks it")
  ok(vim.fn.getreg('"'):find("highlight = {", 1, true) ~= nil,
    "into the unnamed register")
  ok(colors.get() == nil, "and closes the dial, the answer being in hand")
  hl.saturation = saturation
end

print("\n[a block rewrite is not a comparison]")
-- The last of the four sources a before-image can draw its red from is
-- `del_fine`, a character comparison over the whole BLOCK -- and it is
-- the only one whose pale text can come out of a row that is not the
-- one being drawn. Five rows of comment rewritten as six came back with
-- the `th` of `the` stepped back and its `e` lit, matched against a
-- `th` two sentences away.
--
-- `rewritten` passes that: two thirds of the row is marked, under
-- `major_ratio`, and `is`, `group` and `this` survived whole. The old
-- WINDOW, reading the same table, bands the row -- so the same edit
-- read as three words inline and as a whole line side by side.
do
  local old_lines = {
    "  -- ...and the third of them: a page it says to go and read. Underlined",
    "  -- rather than only coloured, because that is what a link has looked",
    "  -- like since before any of this: the words are the author's own",
    "  -- sentence, and the line under them is what says they are also a",
    "  -- door. `Underlined` is the group Neovim ships for exactly this.",
    '  link("NemetonLink", "Underlined")',
  }
  local new_lines = {
    "  -- ...and the third of them: a page it says to go and read. The same",
    "  -- colour as the other two, because all three are one kind of thing --",
    "  -- a reference out of the comment -- and underlined as well, because",
    "  -- that is what a link has looked like since before any of this: the",
    "  -- words are the author's own sentence, and the line under them is",
    "  -- what says they are also a door.",
    "  --",
    "  -- Copied from `DiagnosticInfo` rather than linked to it, because a",
    "  -- link is all or nothing: a group that links somewhere takes that",
    "  -- group's attributes entire, and there is nowhere to hang the",
    "  -- underline. `Underlined` on its own was the other half of this and",
    "  -- carried no colour at all.",
    '  local info = vim.api.nvim_get_hl(0, { name = "DiagnosticInfo", link = false })',
    '  vim.api.nvim_set_hl(0, "NemetonLink", {',
    "    fg = info.fg,",
    "    ctermfg = info.ctermfg,",
    "    underline = true,",
    "    cterm = { underline = true },",
    "    default = true,",
    "  })",
  }
  local hunks = { { start_a = 1, count_a = 6, start_b = 1, count_b = 20 } }
  local spans = removed(hunks, old_lines)
  for i, text in ipairs(new_lines) do
    table.insert(spans, { line = i, col_start = 0, col_end = #text, kind = "add" })
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
  vim.bo[buf].filetype = "lua"
  overlay.render(buf, nil, {
    hunks = hunks, spans = spans, dropped = 0,
    engine = "difftastic", precise = true,
  }, old_lines)

  -- The before-image, row by row, as the groups drawn over its text.
  local before = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, overlay.ns, 0, -1, { details = true })) do
    for _, vl in ipairs(m[4].virt_lines or {}) do
      local text, groups = "", {}
      for _, c in ipairs(vl) do
        local hl = c[2]
        if type(hl) == "table" then hl = table.concat(hl, "+") end
        if hl ~= "UatisSign" and c[1]:match("%S") then
          text = text .. c[1]
          groups[hl:match("UatisDelete%w*") or hl] = true
        end
      end
      table.insert(before, { text = text, groups = groups })
    end
  end
  vim.api.nvim_buf_delete(buf, { force = true })

  local scavenged, narrowed
  for _, row in ipairs(before) do
    if row.text:find("group Neovim ships", 1, true) then
      scavenged = row
    elseif row.text:find("rather than only coloured", 1, true) then
      narrowed = row
    end
  end

  if ok(scavenged ~= nil, "the rewritten block is drawn as a before-image") then
    ok(not scavenged.groups["UatisDeleteDim"],
      "a row the block comparison only scavenged is banded whole, not picked apart")
  end
  if ok(narrowed ~= nil, "and the rows beside it are still drawn") then
    ok(narrowed.groups["UatisDeleteDim"] and narrowed.groups["UatisDeleteBg"],
      "a row the emphasis genuinely narrows keeps its step-back")
  end
end

print("\n[a conflict block is read]")
-- What git leaves in a file: markers around ours and theirs, and with
-- `merge.conflictStyle` diff3 or zdiff3 the base between them. Read
-- from lines alone -- no buffer, no git -- so the list can count a
-- file's blocks off disk and the annotator off the buffer with one
-- reader.
do
  local merge = require("uatis.merge")
  local blocks = merge.blocks({
    "keep",
    "<<<<<<< HEAD",
    "ours 1",
    "ours 2",
    "=======",
    "theirs",
    ">>>>>>> feature/x",
    "between",
    "<<<<<<< HEAD",
    "o",
    "||||||| merged common ancestors",
    "b",
    "=======",
    "t",
    ">>>>>>> feature/x",
    "<<<<<<< HEAD",
    "never closed",
  })
  eq(#blocks, 2, "two blocks, and a run of markers that never closes is not one")
  eq({ blocks[1].top, blocks[1].sep, blocks[1].bottom }, { 2, 5, 7 },
    "the first block's marker rows")
  eq(blocks[1].ours, { "ours 1", "ours 2" }, "its ours side")
  eq(blocks[1].theirs, { "theirs" }, "its theirs side")
  eq(blocks[1].base, nil, "and no base: the markers carry none")
  eq({ blocks[1].label_ours, blocks[1].label_theirs }, { "HEAD", "feature/x" },
    "the labels git wrote on the markers")
  eq({ blocks[2].mid, blocks[2].base }, { 11, { "b" } },
    "the second carries a base, and says where the `|||||||` row is")
end

print("\n[three ways merged by the word]")
-- git merges by the line, and a conflict is two branches touching the
-- same line. Inside the block the question is asked again by the word:
-- base against ours, base against theirs, both applied where the two
-- sets of changes touch no common token. Touching is by closed ranges
-- -- adjacent words, or two insertions at one point -- and that is a
-- conflict here as it is a conflict for git one level up.
do
  local merge = require("uatis.merge")
  local function merged(b, o, t)
    return (merge.merge3(b, o, t))
  end
  eq(merged("function add(a, b)\n  return a + b",
    "function add(a, b)\n  return (a or 0) + (b or 0)",
    "function add(a, b)  -- sum\n  return a + b"),
    "function add(a, b)  -- sum\n  return (a or 0) + (b or 0)",
    "different words of adjacent lines: both changes applied")
  eq(merged("return a + b", "return (a or 0) + b", "return a + b -- sum"),
    "return (a or 0) + b -- sum", "different words of one line, likewise")
  eq(merged("x = 1", "x = 2", "x = 3"), nil, "the same word changed both ways is a conflict")
  eq(merged("x = 1", "x = 2", "x = 2"), "x = 2", "the same change on both sides is applied once")
  eq(merged("x = 1", "x = 1", "y = 1"), "y = 1", "a side that changed nothing takes the other")
  eq(merged("a b c", "a X b c", "a b Y c"), "a X b Y c", "two insertions at different points")
  eq(merged("a b c", "a X b c", "a Y b c"), nil, "two insertions at the same point are a conflict")
  eq(merged("f(x)", "g(x)", "f[x]"), nil, "so are edits to adjacent tokens")
  eq(merged("a b", "A b", "a B"), "A B", "while the blank between two words is a token, and is context")
  eq(merged("a b", "A  b", "a b"), "A  b", "kept byte for byte")
  eq(merged("", "a", "b"), nil, "two sides filling an empty base disagree")
  eq(merged("", "a", "a"), "a", "unless they say the same")
  eq(merged("d = 'é'\nx = 1", "d = 'è'\nx = 1", "d = 'é'\nx = 2"),
    "d = 'è'\nx = 2", "a multi-byte character is one word")
  local _, why = merge.merge3("x = 1", "x = 2", "x = 3")
  ok(type(why) == "string" and why:find("same words") ~= nil,
    "and a refusal says why, got " .. tostring(why))
end

print("\n[a conflicted file, annotated in place]")
-- The annotator on its own, with no list: the buffer git left the
-- markers in, banded and dimmed, a motion between the blocks, and a
-- key for each way of settling one -- every one of them an ordinary
-- edit in the reader's own buffer.
do
  local conflict = require("uatis.conflict")
  local merge = require("uatis.merge")
  local k = require("uatis.config").keys.conflict

  local notes = {}
  local notify = vim.notify
  vim.notify = function(msg) table.insert(notes, msg) end

  vim.cmd("silent! only")
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/stable.lua"))
  vim.fn.system({ "git", "-C", fixture, "switch", "-qf", "feature/math" })
  local out = vim.fn.system({ "git", "-C", fixture, "merge", "feature/clash" })
  ok(vim.v.shell_error ~= 0, "the fixture's clashing branch does not merge, got " .. out)

  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
  local buf = vim.api.nvim_get_current_buf()
  local blocks = merge.blocks(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  eq(#blocks, 1, "calc.lua came out of the merge with one block")

  local announced
  vim.api.nvim_create_autocmd("User", {
    pattern = "UatisConflictAttach",
    once = true,
    callback = function(ev) announced = ev.data end,
  })
  eq(vim.diagnostic.is_enabled({ bufnr = buf }), true, "diagnostics are on, as they are anywhere")
  local c = conflict.attach(buf, vim.api.nvim_get_current_win(), fixture, "calc.lua")
  ok(conflict.get(buf) == c, "the buffer is annotated")
  eq(vim.diagnostic.is_enabled({ bufnr = buf }), false,
    "and its diagnostics are off: a file with markers in it does not parse")
  eq(announced, { buf = buf, root = fixture, path = "calc.lua" },
    "and `User UatisConflictAttach` says so, with the buffer, for a config that wants to know")
  ok(vim.fn.maparg(k.next, "n") ~= "", "after the keys are bound")
  eq(vim.wo.winbar, require("uatis.ui").CONFLICT_WINBAR, "and carries the conflict winbar")

  local function marks()
    local out = { band = {}, mark = {}, text = {} }
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, conflict.ns, 0, -1, { details = true })) do
      local d = m[4]
      if d.line_hl_group then
        out.band[m[2] + 1] = d.line_hl_group
      elseif d.hl_group then
        table.insert(out.mark, { row = m[2] + 1, hl = d.hl_group,
          text = vim.api.nvim_buf_get_text(buf, m[2], m[3], m[2], d.end_col, {})[1] })
      elseif d.virt_text and d.virt_text_pos == "eol" then
        out.text[m[2] + 1] = d.virt_text[1][1]
      end
    end
    return out
  end
  local b = blocks[1]
  local drawn = marks()
  eq(drawn.band[b.top], "UatisMarker", "the opening marker row is dimmed")
  eq(drawn.band[b.sep], "UatisMarker", "so is the separator")
  eq(drawn.band[b.bottom], "UatisMarker", "and the closing one")
  eq(drawn.band[b.top + 1], "UatisOurs", "our side is banded as ours")
  eq(drawn.band[b.sep - 1], "UatisOurs", "down to the separator")
  eq(drawn.band[b.sep + 1], "UatisTheirs", "and theirs as theirs")
  eq(drawn.band[b.bottom + 1], nil, "nothing past the block")
  ok(drawn.text[b.top] and drawn.text[b.top]:find("conflict 1 of 1", 1, true) ~= nil,
    "the marker row says which block this is, got " .. tostring(drawn.text[b.top]))
  -- ...and which branch `HEAD` is, drawn in after the word: the one
  -- label git writes that names nothing.
  wait_for(function() return c.head ~= nil end, "the branch HEAD is on")
  local named
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, conflict.ns, 0, -1, { details = true })) do
    local d = m[4]
    if m[2] + 1 == b.top and d.virt_text_pos == "inline" then
      named = d.virt_text[1][1]
    end
  end
  eq(named, " (feature/math)", "the HEAD marker names the branch HEAD is")

  -- The base is not in the markers, so it comes out of the index: the
  -- three stages merged again in diff3 style and matched by content.
  wait_for(function() return c.base_lines ~= nil end, "the base to come out of the index")
  drawn = marks()
  ok(drawn.text[b.top]:find("resolvable by the word", 1, true) ~= nil,
    "and, once the base is known, that the wand can take it, got " .. drawn.text[b.top])
  local ours_marks, theirs_marks = {}, {}
  for _, m in ipairs(drawn.mark) do
    if m.hl == "UatisOursMark" then table.insert(ours_marks, m.text) end
    if m.hl == "UatisTheirsMark" then table.insert(theirs_marks, m.text) end
  end
  ok(vim.tbl_contains(theirs_marks, "-- sum"), "the words theirs added are marked on their rows, got "
    .. vim.inspect(theirs_marks))
  ok(vim.tbl_contains(ours_marks, "(") and vim.tbl_contains(ours_marks, "or 0)"),
    "and the words ours changed on ours, joined across the blanks inside a change, got "
    .. vim.inspect(ours_marks))

  local function press(lhs)
    local m = vim.fn.maparg(lhs, "n", false, true)
    ok(m and m.callback ~= nil, "the buffer binds " .. lhs)
    if m and m.callback then
      m.callback()
    end
  end
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  press(k.next)
  eq(vim.api.nvim_win_get_cursor(0)[1], b.top + 1, k.next .. " lands on the first row of the block")
  press(k.next)
  eq(vim.api.nvim_win_get_cursor(0)[1], b.top + 1, "and with nowhere to go, stays")
  ok(notes[#notes] and notes[#notes]:find("last conflict", 1, true) ~= nil, "saying so, got " .. tostring(notes[#notes]))
  local wb = require("uatis.ui").conflict_winbar_text(c, 120)
  ok(wb:find("conflict 1/1", 1, true) ~= nil, "the winbar says where the cursor is, got " .. wb)

  -- Settled by the word: both sides' changes on the base, since they
  -- touch no common word.
  press(k.resolve)
  eq(#c.blocks, 0, "the wand settles the block")
  eq(vim.api.nvim_buf_get_lines(buf, 2, 12, false), {
    "function M.add(a, b)  -- sum",
    "  return (a or 0) + (b or 0)",
    "end",
    "",
    "function M.sub(a, b)  -- difference",
    "  return b - a",
    "end",
    "",
    "function M.mul(a, b)",
    "  return a * b",
  }, "with both sides' changes applied to the base and nothing else")
  eq(vim.api.nvim_win_get_cursor(0)[1], b.top, "cursor on the first row of what replaced it")
  eq(#vim.api.nvim_buf_get_extmarks(buf, conflict.ns, 0, -1, {}), 0, "and nothing left to draw")
  ok(notes[#notes]:find("calc.lua resolved", 1, true) ~= nil, "the file is announced done, got " .. notes[#notes])
  wb = require("uatis.ui").conflict_winbar_text(c, 120)
  ok(wb:find("no conflicts left", 1, true) ~= nil, "and the winbar agrees, got " .. wb)
  eq(conflict.state(c), { conflicts = 0, resolved = 1 }, "state(): none left, one resolved")
  eq(vim.diagnostic.is_enabled({ bufnr = buf }), true, "and with no block left, diagnostics are back")

  vim.cmd("silent undo")
  wait_for(function() return #c.blocks == 1 end, "the block to come back on undo")
  eq(#c.blocks, 1, "u puts the block back, marks and all: a pick is an edit")
  press(k.theirs)
  eq(vim.api.nvim_buf_get_lines(buf, 2, 8, false), {
    "function M.add(a, b)  -- sum",
    "  return a + b",
    "end",
    "",
    "function M.sub(a, b)  -- difference",
    "  return a - b",
  }, k.theirs .. " takes their side whole")
  vim.cmd("silent undo")
  wait_for(function() return #c.blocks == 1 end, "the block to come back again")
  press(k.both)
  local both = vim.api.nvim_buf_get_lines(buf, b.top - 1, b.top - 1 + #b.ours + #b.theirs, false)
  eq(both, vim.list_extend(vim.list_extend({}, b.ours), b.theirs), k.both .. " takes ours then theirs")
  vim.cmd("silent undo")
  wait_for(function() return #c.blocks == 1 end, "and once more")
  press(k.base)
  eq(vim.api.nvim_buf_get_lines(buf, 2, 8, false), {
    "function M.add(a, b)",
    "  return a + b",
    "end",
    "",
    "function M.sub(a, b)",
    "  return a - b",
  }, k.base .. " takes the base, which the index supplied")
  vim.cmd("silent undo")
  wait_for(function() return #c.blocks == 1 end, "and back")

  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  press(k.ours)
  ok(notes[#notes]:find("not inside a conflict", 1, true) ~= nil,
    "a pick outside any block says so, got " .. notes[#notes])

  -- `K` on a marker row: the commit it names, beside the cursor, gone
  -- when the cursor moves. On any other row, the reader's own `K` --
  -- an LSP's hover is buffer-local, and three rows of a file are no
  -- reason to take it off the rest.
  conflict.close(buf)
  local hovered = 0
  vim.keymap.set("n", k.peek, function() hovered = hovered + 1 end, { buffer = buf })
  c = conflict.attach(buf, vim.api.nvim_get_current_win(), fixture, "calc.lua")
  wait_for(function() return c.head ~= nil end, "the branch HEAD is on")
  local function floats()
    local out = {}
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local cfg = vim.api.nvim_win_get_config(w)
      if cfg.relative ~= "" then
        table.insert(out, { title = cfg.title and cfg.title[1][1], win = w,
          lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false) })
      end
    end
    return out
  end
  b = c.blocks[1]
  vim.api.nvim_win_set_cursor(0, { b.top, 0 })
  press(k.peek)
  wait_for(function() return #floats() > 0 end, "the commit HEAD names")
  local f = floats()[1] or { lines = {} }
  eq(f.title, " HEAD (feature/math) ", k.peek .. " on the opening marker names HEAD, and the branch it is")
  ok(f.lines[1] and f.lines[1]:find("Fixture Author", 1, true) ~= nil,
    "with sha, date and author on the first row, got " .. tostring(f.lines[1]))
  -- The commit that last touched the block's lines on that side, not
  -- the tip: feature/math's tip is "document clamp", which never went
  -- near calc.lua.
  ok(vim.tbl_contains(f.lines, "fix sub argument order and add mul"),
    "and under it the message of the commit that last touched these lines on that side, got "
    .. vim.inspect(f.lines))
  eq(vim.api.nvim_get_current_win(), c.win, "without taking the cursor")
  vim.cmd("doautocmd CursorMoved")
  eq(#floats(), 0, "and the float goes when the cursor moves")
  vim.api.nvim_win_set_cursor(0, { b.bottom, 0 })
  press(k.peek)
  wait_for(function() return #floats() > 0 end, "the commit theirs names")
  f = floats()[1] or { lines = {} }
  eq(f.title, " feature/clash ", "on the closing marker, the branch being merged")
  ok(vim.tbl_contains(f.lines, "document calc, add clamp the other way round"),
    "and its message, got " .. vim.inspect(f.lines))
  vim.cmd("doautocmd CursorMoved")
  eq(hovered, 0, "none of which was the reader's own K")
  vim.api.nvim_win_set_cursor(0, { b.top + 1, 0 })
  press(k.peek)
  eq(hovered, 1, "which a row inside the block still gets")
  eq(#floats(), 0, "and no float")
  conflict.close(buf)
  press(k.peek)
  eq(hovered, 2, "and which is all that is left of K once the review ends")
  vim.keymap.del("n", k.peek, { buffer = buf })
  c = conflict.attach(buf, vim.api.nvim_get_current_win(), fixture, "calc.lua")

  -- The other file: added by both sides, so there is no base and no
  -- word to merge against. The wand says so rather than guessing.
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/helper.lua"))
  local hbuf = vim.api.nvim_get_current_buf()
  wait_for(function() return conflict.get(buf) == nil end, "the first annotator to close")
  ok(conflict.get(buf) == nil, "leaving the window closed the first annotator")
  local h = conflict.attach(hbuf, vim.api.nvim_get_current_win(), fixture, "helper.lua")
  eq(#h.blocks, 1, "helper.lua has one block")
  wait_for(function() return h.base_lines ~= nil end, "the index to be asked")
  vim.api.nvim_win_set_cursor(0, { h.blocks[1].top + 1, 0 })
  press(k.resolve_all)
  eq(#h.blocks, 1, "the wand leaves a block with no base alone")
  ok(notes[#notes]:find("resolved 0 of 1", 1, true) ~= nil, "and reports it, got " .. notes[#notes])
  drawn = (function()
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(hbuf, conflict.ns, 0, -1, { details = true })) do
      if m[4].virt_text and m[4].virt_text_pos == "eol" then return m[4].virt_text[1][1] end
    end
  end)()
  eq(drawn, "conflict 1 of 1", "the marker row claims nothing it cannot do, got " .. tostring(drawn))

  eq(vim.diagnostic.is_enabled({ bufnr = hbuf }), false, "diagnostics off while the block stands")
  conflict.close(hbuf)
  eq(conflict.get(hbuf), nil, "close forgets the buffer")
  eq(vim.diagnostic.is_enabled({ bufnr = hbuf }), true, "and diagnostics back when the review ends, block or no block")
  eq(vim.wo.winbar, "", "gives the winbar back")
  eq(vim.fn.maparg(k.next, "n"), "", "and every key")
  eq(#vim.api.nvim_buf_get_extmarks(hbuf, conflict.ns, 0, -1, {}), 0, "and every mark")

  vim.notify = notify
  vim.cmd("silent! only")
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/stable.lua"))
  vim.fn.system({ "git", "-C", fixture, "merge", "--abort" })
  vim.fn.system({ "git", "-C", fixture, "switch", "-qf", "main" })
  vim.cmd("silent! checktime")
  eq(vim.trim(vim.fn.system({ "git", "-C", fixture, "status", "--porcelain" })), "",
    "the fixture is clean again")
end

print("\n[conflicts, in the buffer]")
-- The whole review: `<leader>gx` lists the files a merge stopped on,
-- annotates the one under the cursor -- or opens the first -- and the
-- list counts blocks settled rather than lines read. Ended by the same
-- key, with nothing of it left behind.
do
  local conflict = require("uatis.conflict")
  local kc = require("uatis.config").keys.conflict
  local kg = require("uatis.config").keys.global
  local kv = require("uatis.config").keys.view

  local notes = {}
  local notify = vim.notify
  vim.notify = function(msg) table.insert(notes, msg) end
  local auto_open = require("uatis.config").pane.auto_open
  require("uatis.config").pane.auto_open = true

  vim.cmd("silent! only")
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/stable.lua"))
  local function press(lhs)
    local m = vim.fn.maparg(lhs, "n", false, true)
    ok(m and m.callback ~= nil, "the buffer binds " .. lhs)
    if m and m.callback then
      m.callback()
    end
  end

  -- Nothing unmerged: the key says so and opens nothing.
  press(kg.conflicts)
  wait_for(function() return #notes > 0 end, "an answer")
  ok(notes[#notes]:find("no conflicts", 1, true) ~= nil, "with nothing unmerged the key says so, got " .. notes[#notes])
  eq(pane_mod.get(), nil, "and opens nothing")

  vim.fn.system({ "git", "-C", fixture, "switch", "-qf", "feature/math" })
  vim.fn.system({ "git", "-C", fixture, "merge", "feature/clash" })

  -- From a file that is not one of them: the list comes up and the
  -- first conflicted file with it.
  press(kg.conflicts)
  wait_for(function()
    local p = pane_mod.get()
    return p ~= nil and (p.renders or 0) > 0 and conflict.get(vim.api.nvim_get_current_buf()) ~= nil
  end, "the conflict review to open on its first file")
  local p = pane_mod.get()
  eq(p.conflicts, true, "the list is a conflict review")
  eq(p.mode, "conflicts", "and says so")
  eq(#p.files, 2, "over the two files the merge stopped on")
  eq({ p.files[1].path, p.files[1].status, p.files[1].conflicts },
    { "calc.lua", "U", 1 }, "each a U with its blocks counted")
  eq(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"), "calc.lua",
    "pressed from a file that is not one of them, the first one is opened")
  local buf = vim.api.nvim_get_current_buf()
  local c = conflict.get(buf)
  ok(c ~= nil, "and annotated")
  ok(p.list_win and vim.api.nvim_win_is_valid(p.list_win), "with the list beside it")
  local lines = vim.api.nvim_buf_get_lines(p.list_buf, 0, -1, false)
  ok(lines[1]:find("conflicts on feature/math", 1, true) ~= nil,
    "the header names the branch taking the merge, got " .. lines[1])
  ok(lines[2]:find("2 files · 2 left · 0 resolved", 1, true) ~= nil,
    "and the count line counts blocks, got " .. lines[2])
  local function row_of(name)
    for _, l in ipairs(vim.api.nvim_buf_get_lines(p.list_buf, 0, -1, false)) do
      if l:find(name, 1, true) then
        return l
      end
    end
  end
  ok(row_of("calc.lua"):find("1 left", 1, true) ~= nil, "a row says how many are left in it, got " .. row_of("calc.lua"))
  ok(vim.wo[p.list_win].statusline:find("0/2", 1, true) ~= nil,
    "the bar counts files done, got " .. vim.wo[p.list_win].statusline)
  local st = uatis.review()
  eq({ st.mode, st.conflicts, st.resolved, st.files }, { "conflicts", 2, 0, 2 }, "review() answers in blocks")
  local bs = uatis.status()
  eq({ bs.mode, bs.conflicts, bs.resolved, bs.path }, { "conflicts", 1, 0, "calc.lua" }, "and so does status()")

  local keys = offered(p)
  ok(keys:find(kc.resolve, 1, true) ~= nil, "g? offers the conflict keys")
  ok(keys:find("one commit at a time", 1, true) == nil and keys:find("back / forward", 1, true) == nil,
    "and no commit walk, got " .. keys)
  ok(keys:find("mark this row", 1, true) == nil, "nor a mark: a conflict is settled, not read")

  -- Settle the one block; the row, the count line and the bar follow
  -- before the file is written.
  wait_for(function() return c.base_lines ~= nil end, "the base")
  -- From the top of the file: the buffer remembers where the cursor
  -- last was, and from inside the block `]x` would step into the next
  -- file.
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  press(kc.next)
  press(kc.resolve)
  eq(#c.blocks, 0, "the wand settles calc.lua")
  ok(row_of("calc.lua"):find("done", 1, true) ~= nil, "its row says done, got " .. row_of("calc.lua"))
  lines = vim.api.nvim_buf_get_lines(p.list_buf, 0, -1, false)
  ok(lines[2]:find("1 left · 1 resolved", 1, true) ~= nil, "the count line moved, got " .. lines[2])
  ok(vim.wo[p.list_win].statusline:find("1/2", 1, true) ~= nil,
    "and the bar, got " .. vim.wo[p.list_win].statusline)
  ok(vim.bo[buf].modified, "with the file still unwritten")
  ok(notes[#notes]:find("calc.lua resolved, 1 more in helper.lua", 1, true) ~= nil,
    "and the notice says what is left, got " .. notes[#notes])

  -- Off the end of this file into the next.
  press(kc.next)
  wait_for(function()
    local h = conflict.get(vim.api.nvim_get_current_buf())
    return h ~= nil and h ~= c and (h.renders or 0) > 0
  end, "the next conflicted file")
  eq(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"), "helper.lua",
    kc.next .. " with nothing left here steps into the next file")
  local h = conflict.get(vim.api.nvim_get_current_buf())
  eq(vim.api.nvim_win_get_cursor(0)[1], h.blocks[1].top + 1, "and lands on its first block")
  press(kc.next)
  ok(notes[#notes]:find("last conflict", 1, true) ~= nil, "and at the very end says so, got " .. notes[#notes])
  press(kv.file_prev)
  wait_for(function()
    return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t") == "calc.lua"
  end, "the previous file")
  ok(conflict.get(vim.api.nvim_get_current_buf()) ~= nil, kv.file_prev .. " walks the list, and the file is annotated on arrival")

  -- `x` in the list has nothing to mark here.
  vim.api.nvim_set_current_win(p.list_win)
  pane_mod.toggle_read(p, 2)
  ok(notes[#notes]:find("not when it is marked", 1, true) ~= nil, "marking a row read is refused, got " .. notes[#notes])
  vim.api.nvim_set_current_win(p.code_win)

  -- The key again ends it: list, annotators, keys, winbar, marks.
  local cur = vim.api.nvim_get_current_buf()
  press(kg.conflicts)
  eq(pane_mod.get(), nil, kg.conflicts .. " again closes the list")
  eq(#conflict.all(), 0, "and every annotator")
  eq(vim.fn.maparg(kc.next, "n"), "", "with the keys given back")
  eq(vim.wo.winbar, "", "and the winbar")
  eq(#vim.api.nvim_buf_get_extmarks(cur, conflict.ns, 0, -1, {}), 0, "and the marks")

  -- ...and `<leader>gu` ends it too, being the key that ends the review
  -- in this tab.
  press(kg.conflicts)
  wait_for(function() local q = pane_mod.get(); return q ~= nil and (q.renders or 0) > 0 end, "the review again")
  press(kg.toggle_diff)
  eq(pane_mod.get(), nil, kg.toggle_diff .. " ends a conflict review as it ends any other")
  eq(#conflict.all(), 0, "annotators and all")

  vim.notify = notify
  require("uatis.config").pane.auto_open = auto_open
  vim.cmd("silent! only")
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].modified then
      vim.api.nvim_buf_call(b, function() vim.cmd("silent! edit!") end)
    end
  end
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/stable.lua"))
  vim.fn.system({ "git", "-C", fixture, "merge", "--abort" })
  vim.fn.system({ "git", "-C", fixture, "switch", "-qf", "main" })
  vim.cmd("silent! checktime")
  eq(vim.trim(vim.fn.system({ "git", "-C", fixture, "status", "--porcelain" })), "",
    "the fixture is clean again")
end

print("\n[the base, from the markers or from the index]")
-- Where `merge.conflictStyle` is diff3 or zdiff3 the block carries its
-- own base, and the index is never asked. A real overlap -- both sides
-- changed the same word -- is left as it is, whichever way the base
-- arrived, and the marker row says which kind of block it is.
do
  local conflict = require("uatis.conflict")
  local kc = require("uatis.config").keys.conflict
  local notes = {}
  local notify = vim.notify
  vim.notify = function(msg) table.insert(notes, msg) end

  vim.cmd("silent! only")
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/stable.lua"))
  vim.fn.system({ "git", "-C", fixture, "switch", "-qf", "feature/math" })
  vim.fn.system({ "git", "-C", fixture, "-c", "merge.conflictStyle=diff3", "merge", "feature/clash" })
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
  local buf = vim.api.nvim_get_current_buf()
  local c = conflict.attach(buf, vim.api.nvim_get_current_win(), fixture, "calc.lua")
  -- Two blocks, not one: diff3 style forgoes the coalescing the
  -- default style does, so the two are what git found.
  eq(#c.blocks, 2, "diff3 style leaves the two blocks git found")
  local b = c.blocks[1]
  ok(b and b.mid ~= nil and b.base ~= nil, "a diff3 block carries its base")
  eq(c.base_lines, nil, "so the index is not asked")
  local bands = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, conflict.ns, 0, -1, { details = true })) do
    if m[4].line_hl_group then
      bands[m[2] + 1] = m[4].line_hl_group
    end
  end
  eq(bands[b.mid], "UatisMarker", "the `|||||||` row is dimmed like the others")
  eq(bands[b.mid + 1], "UatisBase", "and the base under it banded as the base")
  eq(bands[b.sep - 1], "UatisBase", "down to the separator")
  vim.api.nvim_win_set_cursor(0, { b.top + 1, 0 })
  local m = vim.fn.maparg(kc.resolve, "n", false, true)
  m.callback()
  eq(#c.blocks, 1, "and the wand takes it from there")
  eq(vim.api.nvim_buf_get_lines(buf, 2, 4, false),
    { "function M.add(a, b)  -- sum", "  return (a or 0) + (b or 0)" }, "to the same answer")
  eq(c.base_lines, nil, "still without asking the index")

  -- A block whose two sides changed the same word, written by hand
  -- with its base: the wand refuses, the marker row says why, and
  -- every other key still works on it.
  vim.cmd("silent undo")
  wait_for(function() return #c.blocks == 2 end, "the block back")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "local M = {}",
    "<<<<<<< HEAD",
    "x = 2",
    "||||||| base",
    "x = 1",
    "=======",
    "x = 3",
    ">>>>>>> feature/clash",
    "return M",
  })
  wait_for(function() return c.blocks[1] ~= nil and c.blocks[1].ours[1] == "x = 2" end, "the hand-made block")
  local text
  for _, e in ipairs(vim.api.nvim_buf_get_extmarks(buf, conflict.ns, 0, -1, { details = true })) do
    if e[4].virt_text and e[4].virt_text_pos == "eol" then
      text = e[4].virt_text[1][1]
    end
  end
  ok(text and text:find("both sides changed the same words", 1, true) ~= nil,
    "the marker row says the block is a real overlap, got " .. tostring(text))
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  m.callback()
  eq(#c.blocks, 1, "the wand leaves it")
  ok(notes[#notes]:find("real overlap", 1, true) ~= nil, "and says why, got " .. notes[#notes])
  vim.fn.maparg(kc.resolve_all, "n", false, true).callback()
  ok(notes[#notes]:find("resolved 0 of 1", 1, true) ~= nil, "over the whole file likewise, got " .. notes[#notes])
  vim.fn.maparg(kc.base, "n", false, true).callback()
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "local M = {}", "x = 1", "return M" },
    kc.base .. " takes the base the markers carry")

  conflict.close(buf)
  vim.notify = notify
  vim.cmd("silent! edit!")
  vim.cmd("silent! only")
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/stable.lua"))
  vim.fn.system({ "git", "-C", fixture, "merge", "--abort" })
  vim.fn.system({ "git", "-C", fixture, "switch", "-qf", "main" })
  vim.cmd("silent! checktime")
  eq(vim.trim(vim.fn.system({ "git", "-C", fixture, "status", "--porcelain" })), "",
    "the fixture is clean again")
end

print("\n[history]")
-- Every commit that touched a file, a directory or a run of lines, back
-- to the one that made it: a list of commits rather than of files, each
-- read the way `:UatisShow` reads one -- against its own parent, in its
-- own buffers, in a tab of its own.
do
  local config = require("uatis.config")
  local keys = config.keys.pane
  local function short_of(subject)
    return vim.trim(vim.fn.system({ "git", "-C", fixture, "log", "--all",
      "--format=%h", "-1", "--grep=" .. subject }))
  end
  --- The pane a history just opened, once its first file has drawn.
  local function opened(before, what)
    wait_for(function()
      local q = pane_mod.get()
      if not (q and q ~= before and q.history and (q.renders or 0) > 0) then
        return false
      end
      local v = view_mod.get(vim.api.nvim_get_current_buf())
      return v ~= nil and (v.renders or 0) > 0
    end, what)
    return pane_mod.get()
  end
  --- ...and once the commit at `idx` is the one drawn.
  local function on_show(p, idx, what)
    wait_for(function()
      local v = view_mod.get(vim.api.nvim_get_current_buf())
      return p.commit_idx == idx and v ~= nil and (v.renders or 0) > 0
        and v.at_commit == p.commits[idx].short
    end, what)
  end
  local function list_text(p)
    return table.concat(vim.api.nvim_buf_get_lines(p.list_buf, 0, -1, false), "\n")
  end

  vim.fn.system({ "git", "-C", fixture, "switch", "-qf", "feature/math" })
  vim.cmd("silent! tabonly!")
  vim.cmd("silent! only")
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
  local home = vim.api.nvim_get_current_tabpage()
  local tabs = #vim.api.nvim_list_tabpages()

  uatis.history()
  local p = opened(nil, "the history of calc.lua")
  ok(p.tab ~= home, "in a tab of its own")
  eq(#vim.api.nvim_list_tabpages(), tabs + 1, "one more tab")
  eq(#p.commits, 2, "the two commits that touched it, creation included")
  eq(p.commit_idx, 2, "with the newest on show")
  eq(p.commits[2].short, short_of("fix sub argument order"), "which is the newest")
  eq(p.rev, p.commits[2].parent, "measured against its own parent")
  eq(uatis.review().mode, "history", "and a statusline is told what kind of review it is")
  local text = list_text(p)
  ok(text:find("history of calc.lua", 1, true) ~= nil, "the list says what it is the history of")
  ok(text:find("2 commits", 1, true) ~= nil, "and how long it is")
  -- Newest at the top, the way every log is read.
  local newest_at = text:find(p.commits[2].subject:sub(1, 7), 1, true)
  local oldest_at = text:find(p.commits[1].subject:sub(1, 7), 1, true)
  ok(newest_at and oldest_at and newest_at < oldest_at, "newest first, got:\n" .. text)
  -- Each row dated; the sha only under the one on show.
  ok(text:find(" " .. p.commits[2].date .. " ", 1, true) ~= nil, "a row carries its date, got:\n" .. text)
  ok(text:find(p.commits[2].short, 1, true) ~= nil, "the commit on show names its sha")
  ok(text:find(p.commits[1].short, 1, true) == nil, "a folded one does not")
  -- The file, as it was: never the reader's own buffer, which holds the
  -- present.
  local buf = vim.api.nvim_get_current_buf()
  ok(require("uatis.checkout").owner_of(vim.api.nvim_buf_get_name(buf)) ~= nil,
    "the file is shown as it was, out of the history's checkout, got "
      .. vim.api.nvim_buf_get_name(buf))
  local v = view_mod.get(buf)
  eq(vim.api.nvim_win_get_cursor(0)[1], v.anchors[1], "the cursor on the change it made")

  -- Pinned under the winbar, the commit it is shown at: datetime to
  -- the second, then its message.
  local code_win = vim.api.nvim_get_current_win()
  local card_win, card_lines
  local function read_card()
    card_win, card_lines = nil, {}
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local c = vim.api.nvim_win_get_config(w)
      if c.relative ~= "" and not c.focusable then
        card_win = w
        card_lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)
      end
    end
    return card_lines[1] or ""
  end
  wait_for(function()
    return read_card():find(":%d%d ") ~= nil
  end, "the commit's message pinned over the file")
  ok(card_lines[1]:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d · fix sub argument order") ~= nil,
    "datetime and subject on the top row -- the sha is the winbar's -- got " .. card_lines[1])
  local info = vim.fn.getwininfo(code_win)[1]
  local cc = vim.api.nvim_win_get_config(card_win)
  eq({ cc.row, cc.col, cc.width }, { info.winrow - 1 + info.winbar, info.wincol - 1, info.width },
    "on the window's first row of text, its full width")
  -- It covers nothing of the file: blank filler above line 1 is what it
  -- sits over at the top, and 'scrolloff' keeps the cursor out from under
  -- it everywhere else.
  local sight = vim.fn.winsaveview()
  eq(sight.topline, 1, "the change is near the top, so the window is too")
  ok(sight.topfill >= #card_lines, "line 1 is below it, topfill " .. sight.topfill)
  ok(vim.wo[code_win].scrolloff >= #card_lines, "and the cursor never goes under it")
  -- Two rows by default: a body of one line fits under the subject, a
  -- longer one is `...`.
  local two = require("uatis.config").show.message_lines
  eq(#require("uatis.ui").commit_card("d", "subject\n\none", two), 2, "one body line fits")
  local cut = require("uatis.ui").commit_card("d", "subject\n\none\ntwo", two)
  eq({ #cut, cut[2][1][1] }, { 2, "..." }, "more than that is the subject and ...")

  -- The cap is a setting: at five, the last of five says there is more.
  local ui_mod = require("uatis.ui")
  local long = ui_mod.commit_card("2026-01-02 03:04:05",
    "subject\n\none\ntwo\nthree\nfour\nfive", 5)
  eq(#long, 5, "a long message is cut to five rows")
  eq(long[2][1][1], "one", "the blank row under the subject is dropped")
  eq(long[5][1][1], "...", "and the last says there is more")
  eq(#ui_mod.commit_card("d", "subject\n\none\ntwo\nthree\nfour", 5), 5,
    "one that fits is not cut")
  ok(offered(p):find("this history", 1, true) ~= nil
    and offered(p):find(keys.commit_prev .. " " .. keys.commit_next, 1, true) ~= nil,
    "the keys offer the walk, got " .. offered(p))
  ok(offered(p):find("| " .. keys.commit_view .. " ", 1, true) == nil,
    "and no whole to go back out to, got " .. offered(p))

  -- `K` is the commit's whole message, and under it what the commit did
  -- to each file it touched -- the churn, then the path.
  pane_mod.peek_commit(p)
  local float_lines
  wait_for(function()
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local c = vim.api.nvim_win_get_config(w)
      if c.relative ~= "" and c.focusable then
        float_lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)
        pcall(vim.api.nvim_win_close, w, true)
        return true
      end
    end
  end, "the commit's message in a float")
  local stat_row
  for _, l in ipairs(float_lines or {}) do
    if l:find("calc.lua", 1, true) then
      stat_row = l
    end
  end
  ok(stat_row ~= nil and stat_row:match("^%s*%+%d+%s+%-%d+%s+calc%.lua$") ~= nil,
    "the float says what the commit did to each file, got "
      .. vim.inspect(float_lines))

  -- The commit a step would reach is already being compared: difftastic
  -- takes seconds over a large file, and the next commit is the one
  -- question a history knows is coming.
  ok(p.prefetched and p.prefetched[p.commits[1].sha],
    "the older neighbour is compared ahead of the step")

  -- Older, and older still: the first commit made the file, and has no
  -- parent to be measured against but nothing.
  pane_mod.step_commit(p, -1)
  on_show(p, 1, "the commit that made calc.lua")
  -- The card goes with the step. The file of the commit left behind is
  -- wiped a tick later, and that must not take the new card with it.
  wait_for(function()
    return read_card():find(p.commits[1].subject, 1, true) ~= nil
  end, "the older commit's card")
  vim.wait(50)
  ok(read_card():find(p.commits[1].subject, 1, true) ~= nil,
    "and it is still there once the old file is gone, got " .. vim.inspect(card_lines))
  eq(p.target, "nothing", "the first is measured against nothing")
  eq(p.stat_removed, 0, "nothing was taken away by it")
  local said = {}
  local real_notify = vim.notify
  vim.notify = function(msg) table.insert(said, msg) end
  pane_mod.step_commit(p, -1)
  pane_mod.toggle_commits(p)
  vim.notify = real_notify
  ok(contains(said, "oldest commit"), "off the old end it says so, got " .. vim.inspect(said))
  ok(contains(said, "one commit at a time"), "and C says a history is walked already")
  eq(p.commit_idx, 1, "and stays where it was")

  -- A commit row of the list, picked: that one on show.
  vim.api.nvim_set_current_win(p.list_win)
  for line, idx in pairs(p.list_commits) do
    if idx == 2 then
      vim.api.nvim_win_set_cursor(p.list_win, { line, 0 })
    end
  end
  vim.api.nvim_feedkeys(vim.keycode(keys.select), "x", false)
  on_show(p, 2, "the row picked back on show")
  ok(true, "<CR> on a commit row puts it on show")

  -- The branch review's subtree is not this history's.
  pane_mod.rescope(p.root, "util")
  eq(p.scope, "", "choosing what the branch review is about leaves a history alone")
  pane_mod.close(p)
  wait_for(function() return not vim.api.nvim_tabpage_is_valid(p.tab) end, "the history's tab to go")

  -- A file that was renamed is followed back past the rename, each
  -- commit read under the name it had then.
  vim.api.nvim_set_current_tabpage(home)
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/renamed_to.lua"))
  uatis.history()
  p = opened(nil, "the history of a renamed file")
  eq(#p.commits, 2, "the rename, and the commit that made it under its old name")
  pane_mod.step_commit(p, -1)
  on_show(p, 1, "the file under its old name")
  ok(vim.api.nvim_buf_get_name(0):find("renamed_from.lua", 1, true) ~= nil,
    "read under the name it had, got " .. vim.api.nvim_buf_get_name(0))
  pane_mod.close(p)

  -- A run of lines: `M.sub`'s three rows, followed by `git log -L`.
  vim.api.nvim_set_current_tabpage(home)
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
  uatis.history({ range = 2, line1 = 7, line2 = 9 })
  p = opened(nil, "the history of calc.lua:7-9")
  eq({ p.history.from, p.history.to }, { 7, 9 }, "of the lines asked about")
  eq(#p.commits, 2, "every commit that touched them")
  ok(list_text(p):find("lines 7-9", 1, true) ~= nil, "and the list says which lines")
  eq(vim.api.nvim_win_get_cursor(0)[1], 7, "the cursor on them, where git says they stood")
  pane_mod.close(p)

  -- ...asked through an edit not yet committed. Three lines typed at
  -- the top move `M.sub` to 10-12 in the buffer, and it is still 7-9 in
  -- every commit git can be asked about.
  vim.api.nvim_set_current_tabpage(home)
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
  vim.api.nvim_buf_set_lines(0, 0, 0, false, { "-- one", "-- two", "-- three" })
  uatis.history({ range = 2, line1 = 10, line2 = 12 })
  p = opened(nil, "the history of lines an edit moved")
  eq({ p.history.from, p.history.to }, { 7, 9 }, "the rows as HEAD has them")
  pane_mod.close(p)

  -- Lines that exist nowhere but the buffer have no history, and asking
  -- opens nothing.
  vim.api.nvim_set_current_tabpage(home)
  said = {}
  vim.notify = function(msg) table.insert(said, msg) end
  local before = #vim.api.nvim_list_tabpages()
  uatis.history({ range = 2, line1 = 1, line2 = 3 })
  wait_for(function() return #said > 0 end, "uatis to say those lines are new")
  vim.notify = real_notify
  ok(contains(said, "not been committed"), "uncommitted lines say so, got " .. vim.inspect(said))
  eq(#vim.api.nvim_list_tabpages(), before, "and open no tab")
  vim.cmd("silent! edit!")

  -- A directory, named: its commits, and under the one on show the files
  -- it touched in there, drawn relative to it. (`:UatisHistory util`,
  -- which `plugin/` defines and `-l` does not source.)
  uatis.history({ path = "util" })
  p = opened(nil, "the history of util/")
  eq(p.history.dir, true, "a directory")
  eq(p.scope, "util", "read as the list's subtree")
  eq(#p.commits, 1, "one commit ever touched it")
  eq(#p.files, 1, "and one file under it")
  ok(list_text(p):find("A strings.lua", 1, true) ~= nil,
    "drawn relative to it, got:\n" .. list_text(p))

  -- `L` on that file's row: its own history.
  vim.api.nvim_set_current_win(p.list_win)
  local file_line = next(p.list_rows)
  vim.api.nvim_win_set_cursor(p.list_win, { file_line, 0 })
  vim.api.nvim_feedkeys(keys.history, "x", false)
  local q = opened(p, "the history of the row under the cursor")
  eq(q.history.path, "util/strings.lua", "L on a file row is that file's history")
  pane_mod.close(q)
  pane_mod.close(p)

  -- A path that nothing ever touched says so and opens nothing.
  said = {}
  vim.notify = function(msg) table.insert(said, msg) end
  before = #vim.api.nvim_list_tabpages()
  uatis.history({ path = "no-such-file.lua" })
  wait_for(function() return #said > 0 end, "uatis to say nothing touched it")
  vim.notify = real_notify
  ok(contains(said, "no commit has touched"), "got " .. vim.inspect(said))
  eq(#vim.api.nvim_list_tabpages(), before, "and opens no tab")

  vim.cmd("silent! tabonly!")
  vim.fn.system({ "git", "-C", fixture, "switch", "-qf", "main" })
end

print("\n[the project at a revision]")
-- Not a comparison: the project as it was, checked out, in a tab of its
-- own -- real files, so a language server and an explorer find a
-- project there -- and read-only, and gone when the tab is.
do
  local at = require("uatis.at")
  vim.fn.system({ "git", "-C", fixture, "switch", "-qf", "feature/math" })
  vim.cmd("silent! tabonly!")
  vim.cmd("silent! only")
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
  local home = vim.api.nvim_get_current_tabpage()
  local short = vim.trim(vim.fn.system({ "git", "-C", fixture, "rev-parse", "--short", "HEAD~2" }))

  uatis.at("HEAD~2")
  wait_for(function() return at.get() ~= nil end, "the project checked out at HEAD~2")
  local a = at.get()
  ok(vim.api.nvim_get_current_tabpage() ~= home, "in a tab of its own")
  eq(a.short, short, "at the revision asked for")
  eq(vim.api.nvim_buf_get_name(0), a.dir .. "/calc.lua", "on the file the reader was in, as a real file")
  eq(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"),
    vim.trim(vim.fn.system({ "git", "-C", fixture, "show", "HEAD~2:calc.lua" })),
    "holding what it held then")
  ok(vim.bo.readonly and not vim.bo.modifiable, "read-only")
  eq(vim.fn.getcwd(-1, 0), a.dir, "the tab's own directory is the checkout")
  ok(vim.fn.getcwd(-1, vim.api.nvim_tabpage_get_number(home)) ~= a.dir,
    "and the reader's tab keeps its own")
  ok(vim.api.nvim_eval_statusline(vim.wo.winbar, {}).str:find("at " .. short, 1, true) ~= nil,
    "the winbar says which revision this is")
  eq(vim.trim(vim.fn.system({ "git", "-C", a.dir, "rev-parse", "--short", "HEAD" })), short,
    "a real checkout, which is what a language server needs")

  -- Anything opened from there is the past too.
  vim.cmd("edit helper.lua")
  eq(vim.api.nvim_buf_get_name(0), a.dir .. "/helper.lua", "a relative :edit lands in the checkout")
  ok(vim.bo.readonly and not vim.bo.modifiable, "read-only as well")

  -- Closed, the checkout goes with it.
  vim.cmd("tabclose")
  wait_for(function() return vim.uv.fs_stat(a.dir) == nil end, "the checkout to be removed")
  ok(not vim.fn.system({ "git", "-C", fixture, "worktree", "list" }):find(a.dir, 1, true),
    "and git no longer lists it")
  eq(at.get(), nil, "nothing left registered")
  wait_for(function() return vim.uv.fs_stat(vim.fs.dirname(a.dir)) == nil end,
    "the repository's empty folder in the cache to go too")

  -- A file that did not exist then: the checkout opens on its directory.
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/helper.lua"))
  local said = {}
  local real_notify = vim.notify
  vim.notify = function(msg) table.insert(said, msg) end
  uatis.at("HEAD~3")
  wait_for(function() return at.get() ~= nil end, "the project at HEAD~3")
  vim.notify = real_notify
  a = at.get()
  ok(contains(said, "did not exist"), "a file that did not exist then says so, got " .. vim.inspect(said))

  -- ...and on the way out of the editor, from inside it. The tab is one
  -- window, and `:qa` refuses to quit if that window is closed.
  local quitting = vim.api.nvim_get_current_win()
  vim.api.nvim_exec_autocmds("ExitPre", {})
  eq(#vim.api.nvim_list_tabpages(), 1, "ExitPre closes the checkout's tab")
  ok(vim.api.nvim_win_is_valid(quitting), "keeping the window the quit came from")
  ok(vim.uv.fs_stat(a.dir) == nil, "and the checkout is removed before the editor goes")
  vim.cmd("silent! only")
  vim.fn.system({ "git", "-C", fixture, "switch", "-qf", "main" })
end

print("\n[leaving the editor]")
-- The tabs uatis opened for itself go before the editor does, so a
-- session saved on the way out does not bring back a tab of `uatis://`
-- buffers that no longer exist.
do
  vim.fn.system({ "git", "-C", fixture, "switch", "-qf", "feature/math" })
  vim.cmd("silent! tabonly!")
  vim.cmd("silent! only")
  vim.cmd("edit! " .. vim.fn.fnameescape(fixture .. "/calc.lua"))
  local home = vim.api.nvim_get_current_tabpage()
  uatis.history()
  wait_for(function()
    local q = pane_mod.get()
    return q ~= nil and q.history and (q.renders or 0) > 0
  end, "a history in its own tab")
  local hist = pane_mod.get()
  vim.api.nvim_set_current_tabpage(home)
  uatis.show_commit("HEAD")
  wait_for(function()
    local q = pane_mod.get()
    return q ~= nil and q ~= hist and q.standalone and (q.renders or 0) > 0
  end, "a commit in its own tab")
  local shown = pane_mod.get()
  eq(#vim.api.nvim_list_tabpages(), 3, "three tabs, two of them uatis's")

  -- Quit from inside one of them. `:qa` refuses to go on when `ExitPre`
  -- closed the window it was asked from -- nvim simply stays up -- so
  -- that window has to outlive the tabs.
  local quitting = vim.api.nvim_get_current_win()
  vim.api.nvim_exec_autocmds("ExitPre", {})
  eq(#vim.api.nvim_list_tabpages(), 1, "ExitPre closes the tabs uatis opened")
  eq(vim.api.nvim_get_current_tabpage(), home, "and leaves the reader's own")
  ok(pane_mod.get(hist.tab) == nil and pane_mod.get(shown.tab) == nil,
    "with the reviews in them ended")
  ok(vim.api.nvim_win_is_valid(quitting),
    "and the window the quit came from still there, or the quit is refused")
  vim.cmd("silent! only")

  -- ...and from the list, which is a window the review would otherwise
  -- close itself.
  uatis.history()
  wait_for(function()
    local q = pane_mod.get()
    return q ~= nil and q.history and (q.renders or 0) > 0 and q.list_win ~= nil
  end, "a history with its list up")
  vim.api.nvim_set_current_win(pane_mod.get().list_win)
  quitting = vim.api.nvim_get_current_win()
  vim.api.nvim_exec_autocmds("ExitPre", {})
  eq(#vim.api.nvim_list_tabpages(), 1, "quit from the list, its tab goes too")
  ok(vim.api.nvim_win_is_valid(quitting), "and the list's window outlives it")
  vim.cmd("silent! only")

  -- ...and where a review's tab is the only one left, a blank one takes
  -- its place: nvim will not close its last tab.
  uatis.history()
  wait_for(function()
    local q = pane_mod.get()
    return q ~= nil and q.history and (q.renders or 0) > 0
  end, "a history in its own tab again")
  vim.cmd("silent! tabonly!")
  eq(#vim.api.nvim_list_tabpages(), 1, "the history's tab is the only one")
  vim.api.nvim_exec_autocmds("ExitPre", {})
  eq(pane_mod.get(), nil, "the history is ended")
  eq(#vim.api.nvim_list_tabpages(), 1, "and one tab is left")
  eq(vim.api.nvim_buf_get_name(0), "", "a blank one")

  vim.fn.system({ "git", "-C", fixture, "switch", "-qf", "main" })
end

print("\n[the command-line window]")
-- `q:` is a normal-mode window, so the global keys fire in it -- and
-- every one of them ends in opening a window or leaving the buffer,
-- which is `E11` there. The window is two git calls past the key, so
-- unguarded the refusal arrived as a traceback out of a `vim.schedule`
-- callback with nothing on screen to connect it to.
do
  local notes = {}
  local notify = vim.notify
  vim.notify = function(msg) table.insert(notes, msg) end

  local errs = {}
  local keys = require("uatis.config").keys.global
  vim.api.nvim_create_autocmd("CmdwinEnter", {
    once = true,
    callback = function()
      for _, lhs in pairs(keys) do
        if lhs and lhs ~= "" then
          local m = vim.fn.maparg(vim.keycode(lhs), "n", false, true)
          if m and m.callback then
            local good, err = pcall(m.callback)
            if not good then
              table.insert(errs, lhs .. ": " .. tostring(err))
            end
          end
        end
      end
      vim.api.nvim_feedkeys(vim.keycode("<C-c>"), "n", false)
    end,
  })
  vim.api.nvim_feedkeys("q:", "x", false)

  vim.notify = notify
  eq(errs, {}, "every global key is refused rather than raising in the cmdwin")
  ok(#notes > 0 and notes[1]:find("command%-line window") ~= nil,
    "and says why, got " .. tostring(notes[1]))
  eq(pane_mod.get(), nil, "nothing was opened")
end

-- `os.exit` fires no `ExitPre`: what a quit would take down is taken
-- down here, so no checkout outlives the run in git's worktree list.
require("uatis.checkout").release_all()
require("uatis.at").release_all()

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
