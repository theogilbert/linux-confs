-- Draws a diff onto a code buffer as extmarks.
--
-- The buffer holds the NEW side of the diff -- the file as it exists at
-- whichever revision is being reviewed. Content that exists in the new
-- side is highlighted on the real line it occupies; content that only
-- exists in the old side has no line to sit on, so it is drawn as virtual
-- lines above the position it used to occupy.
--
-- That asymmetry is the whole design. It means the reviewer is reading
-- real, navigable, syntax-highlighted code with the removals annotated
-- around it, rather than reading a patch.

local config = require("uatis.config")
local diff = require("uatis.diff")
local syntax = require("uatis.syntax")

local M = {}

M.ns = vim.api.nvim_create_namespace("uatis_overlay")

--- Highlight groups, derived from the built-in diff groups so they follow
--- whatever colourscheme is in use.
---
--- Line highlights over real code take the BACKGROUND ONLY. Most
--- colourschemes give DiffAdd and DiffChange a foreground as well --
--- `#ffffff` in slate, industry, desert and evening -- and a foreground
--- applied over a code buffer replaces the syntax colouring underneath.
--- Every changed line would go flat white, which is the opposite of what
--- this plugin is for: the whole point is reading the branch as code.
--- Taking the background alone tints the line and leaves syntax intact.
---
--- UatisAddText is the same colour again, further from the background:
--- the part of a banded line that is the actual edit, standing out
--- inside the tint rather than beside it. Derived from `DiffAdd` rather
--- than `DiffText` so the two are one hue at two strengths -- `DiffText`
--- is a different colour in most schemes, and pairs its background with a
--- black foreground the buffer's syntax colours are not going to match.
---
--- UatisAddDim is the pair the other way up, for a changed prose atom
--- whose words are not all the edit: there the new words keep the plain
--- tint and the sentence around them steps back towards the background,
--- so the loudest colour on the screen goes on meaning one thing.
---
--- It cannot simply be drawn over a banded line: a character range cannot
--- override the background of a line carrying `line_hl_group` at all
--- (verified empirically, at every priority, in 0.12 as before). The way
--- round it is to band with a multiline range and `hl_eol`, which reaches
--- the window edge the same way and does compose -- see `paint_row`.
---
--- There is no third colour for "changed". Added text is green, removed
--- text is red in the before-image above it, and a replacement is both --
--- which is what a patch has always looked like.
---
--- Groups drawn on VIRTUAL lines are the other way round: there is no
--- syntax highlighting under virtual text, so those need a real
--- foreground and keep the full definition.
function M.setup_highlights()
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false }).bg

  local function channels(c)
    return math.floor(c / 65536) % 256, math.floor(c / 256) % 256, c % 256
  end

  local function pack(r, g, b)
    local function clamp(v)
      return math.min(math.max(math.floor(v + 0.5), 0), 255)
    end
    return clamp(r) * 65536 + clamp(g) * 256 + clamp(b)
  end

  --- RGB <-> HSL, so a tint can be deepened rather than lightened.
  ---
  --- Scaling the distance from the background in RGB was the obvious way
  --- and it makes a colour PALER as it makes it stronger: every channel
  --- moves, so a quiet green becomes a bright grey-green rather than a
  --- deep one. Saturation and lightness are separate axes here, which is
  --- what "more colour, not more light" needs.
  local function to_hsl(c)
    local r, g, b = channels(c)
    r, g, b = r / 255, g / 255, b / 255
    local hi, lo = math.max(r, g, b), math.min(r, g, b)
    local l = (hi + lo) / 2
    if hi == lo then
      return 0, 0, l -- grey: no hue to keep
    end
    local d = hi - lo
    local sat = l > 0.5 and d / (2 - hi - lo) or d / (hi + lo)
    local h
    if hi == r then
      h = (g - b) / d + (g < b and 6 or 0)
    elseif hi == g then
      h = (b - r) / d + 2
    else
      h = (r - g) / d + 4
    end
    return h / 6, sat, l
  end

  local function to_rgb(h, sat, l)
    if sat == 0 then
      return pack(l * 255, l * 255, l * 255)
    end
    local function hue(p, q, t)
      t = t % 1
      if t < 1 / 6 then
        return p + (q - p) * 6 * t
      elseif t < 1 / 2 then
        return q
      elseif t < 2 / 3 then
        return p + (q - p) * (2 / 3 - t) * 6
      end
      return p
    end
    local q = l < 0.5 and l * (1 + sat) or l + sat - l * sat
    local p = 2 * l - q
    return pack(hue(p, q, h + 1 / 3) * 255, hue(p, q, h) * 255, hue(p, q, h - 1 / 3) * 255)
  end

  --- Deepens a tint: the colourscheme's own hue, saturated to at least
  --- `saturation`, sitting `lightness` away from the editor's background
  --- -- in whichever direction the scheme already put it, so a light
  --- theme's tints stay light and a dark theme's stay dark.
  ---
  --- The hue is never touched. What comes back is the scheme's colour,
  --- more of it. See `config.highlight`.
  local function deepen(bg, saturation, lightness)
    if not bg or not normal then
      return bg
    end
    local h, sat, l = to_hsl(bg)
    local _, _, base = to_hsl(normal)
    if sat == 0 then
      return bg -- a grey has no colour to deepen
    end
    local dir = l >= base and 1 or -1
    return to_rgb(h, math.max(sat, saturation),
      math.min(math.max(base + dir * lightness, 0), 1))
  end

  M.deepen = deepen

  --- A colour part of the way from `from` to `to`. Where `deepen` makes
  --- a tint more of itself, this puts one BETWEEN two colours -- which is
  --- what a quieter tint has to be: still the tint, still visibly not the
  --- background it is stepping back towards.
  local function mix(from, to, amount)
    if not (from and to) then
      return to or from
    end
    local fr, fg, fb = channels(from)
    local tr, tg, tb = channels(to)
    return pack(fr + (tr - fr) * amount, fg + (tg - fg) * amount, fb + (tb - fb) * amount)
  end


  -- Falls back to a plain link when the target has no background to take
  -- (some colourschemes express these groups with `reverse` or a
  -- foreground alone), since a highlight with nothing set is invisible.
  local function tint(name, target, lightness)
    local base = vim.api.nvim_get_hl(0, { name = target, link = false })
    if base.bg then
      vim.api.nvim_set_hl(0, name, {
        bg = deepen(base.bg, config.highlight.saturation, lightness),
      })
    else
      vim.api.nvim_set_hl(0, name, { link = target })
    end
  end

  local function derive(name, target, extra)
    local base = vim.api.nvim_get_hl(0, { name = target, link = false })
    vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", base, extra))
  end

  -- Over real code.
  local add_l = config.highlight.add_lightness
  local del_l = config.highlight.delete_lightness

  tint("UatisAdd", "DiffAdd", add_l)
  tint("UatisChange", "DiffChange", add_l)
  -- ...including the old revision opened in a window of its own, where
  -- the band marks which lines this branch removed. Background only, and
  -- no strikethrough: everything in that buffer is the old side, so
  -- striking it through would say nothing while making the code harder
  -- to read -- and reading it is what that window is for.
  tint("UatisDeleteBand", "DiffDelete", del_l)

  -- The emphasis: which part of a banded line is the actual edit, where
  -- the backend only knows lines and the band on its own says no more
  -- than "this line changed". The same hue as the tint it sits in,
  -- pushed further from the background, so the pair reads as one colour
  -- at two strengths.
  --
  -- It was an underline, because a character range cannot override the
  -- background of a line carrying `line_hl_group` -- still true, verified
  -- again at every priority. The way round it is to draw that band as a
  -- multiline range with `hl_eol`, which reaches the window edge the same
  -- way and DOES compose with a range on top of it. See `paint_row`.
  local add = vim.api.nvim_get_hl(0, { name = "DiffAdd", link = false })
  vim.api.nvim_set_hl(0, "UatisAddText", add.bg
    and { bg = deepen(add.bg, config.highlight.emphasis_saturation,
      config.highlight.emphasis_lightness) }
    or { link = "DiffText" })

  -- ...and the same relationship read the other way, for a changed prose
  -- atom. difftastic calls a reworded docstring changed word by word,
  -- and only some of those words are the edit; the rest are the sentence
  -- they were dropped into. Marking the new words louder would make a
  -- comment the brightest thing on a screen full of changed code, so the
  -- new words keep the ordinary tint and the sentence around them steps
  -- back instead. Two levels either way -- this way round the top one
  -- always means the same thing.
  --
  -- Mixed towards the editor's background rather than desaturated, so it
  -- lands between the tint and the buffer whatever the scheme's diff
  -- colours are. What difftastic called changed is never drawn as
  -- unchanged, only as less of the story.
  local add_bg = add.bg and deepen(add.bg, config.highlight.saturation, add_l)
  vim.api.nvim_set_hl(0, "UatisAddDim", (add_bg and normal)
    and { bg = mix(normal, add_bg, config.highlight.dim_contrast) }
    or { link = "DiffAdd" })

  -- Over virtual text. Strikethrough on top of DiffDelete is what makes a
  -- virtual line read as "this is gone" rather than "here is another line
  -- of code".
  derive("UatisDelete", "DiffDelete", { strikethrough = true })

  -- The same, minus the foreground, for a before-image whose own syntax
  -- colours are known (see `syntax.lua`). DiffDelete's foreground would
  -- flatten every removed line to one colour -- which is what the new
  -- side deliberately avoids -- so where there are real groups to put
  -- underneath, only the background and the strikethrough come from here.
  local del = vim.api.nvim_get_hl(0, { name = "DiffDelete", link = false })
  -- The old side's band, stepped back the same way the new side's tint
  -- is: a removed docstring reports every word of it removed, and the
  -- words that actually went are a handful. Same relationship, same
  -- distance, so the two windows read as one statement.
  local del_band = del.bg and deepen(del.bg, config.highlight.saturation, del_l)
  vim.api.nvim_set_hl(0, "UatisDeleteBandDim", (del_band and normal)
    and { bg = mix(normal, del_band, config.highlight.dim_contrast) }
    or { link = "DiffDelete" })
  vim.api.nvim_set_hl(0, "UatisDeleteBg", del.bg
    and { bg = deepen(del.bg, config.highlight.saturation, del_l),
      strikethrough = true }
    or { link = "UatisDelete" })
  vim.api.nvim_set_hl(0, "UatisSign", { link = "DiffDelete" })

  -- The part of a before-image that did NOT go away. Present for context,
  -- so it is dimmed and keeps the strikethrough without the red.
  local comment = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
  vim.api.nvim_set_hl(0, "UatisDeleteDim", {
    fg = comment.fg,
    strikethrough = true,
  })

  -- The blank rows that keep a side-by-side layout lined up. Nothing is
  -- there, and the group says so: this is the same colour Neovim uses for
  -- the parts of the screen that are not the buffer.
  vim.api.nvim_set_hl(0, "UatisFiller", { link = "NonText" })

  vim.api.nvim_set_hl(0, "UatisHeader", { link = "Title" })
  vim.api.nvim_set_hl(0, "UatisMeta", { link = "Comment" })

  -- Hints in a winbar, which is not the buffer: `NonText` is meant for
  -- the parts of the screen that are not text at all, and against a
  -- winbar's own background it can be near-invisible. Mixed from the
  -- bar's background towards the editor's foreground instead, so it is
  -- quieter than the text beside it and still legible.
  local function bar_bg()
    -- `Normal` before `StatusLine`: a winbar with no background of its
    -- own draws on the window's, and mixing from a status line that is
    -- lighter than the window would put the hints brighter than the text
    -- they sit beside.
    for _, name in ipairs({ "WinBar", "Normal", "StatusLine" }) do
      local h = vim.api.nvim_get_hl(0, { name = name, link = false })
      if h.bg then
        return h.bg
      end
    end
  end

  local bar = bar_bg()
  local fg = vim.api.nvim_get_hl(0, { name = "Normal", link = false }).fg
  vim.api.nvim_set_hl(0, "UatisHint", (bar and fg)
    and { fg = mix(bar, fg, config.highlight.hint_contrast) }
    or { link = "NonText" })

  --- A churn count in a winbar: the diff colour as a FOREGROUND, since a
  --- background the width of `+12` in a one-line bar reads as a smudge.
  --- Light enough to be read on the bar rather than deep enough to sit
  --- under code, which is the opposite of what the tints want.
  local function signal(name, target, fallback)
    local base = vim.api.nvim_get_hl(0, { name = target, link = false })
    if not base.bg then
      vim.api.nvim_set_hl(0, name, { link = fallback })
      return
    end
    local h, sat = to_hsl(base.bg)
    local _, _, bl = to_hsl(bar or 0)
    vim.api.nvim_set_hl(0, name, {
      fg = to_rgb(h, math.max(sat, config.highlight.signal_saturation),
        bl > 0.5 and config.highlight.signal_lightness_dark
          or config.highlight.signal_lightness),
      bold = true,
    })
  end

  signal("UatisPlus", "DiffAdd", "UatisMeta")
  signal("UatisMinus", "DiffDelete", "UatisMeta")
  vim.api.nvim_set_hl(0, "UatisStatAdd", { link = "DiffAdd" })
  vim.api.nvim_set_hl(0, "UatisStatDel", { link = "DiffDelete" })
  vim.api.nvim_set_hl(0, "UatisFileCur", { link = "CursorLineNr" })
  vim.api.nvim_set_hl(0, "UatisDir", { link = "Directory" })
  vim.api.nvim_set_hl(0, "UatisStatusA", { link = "DiffAdd" })
  vim.api.nvim_set_hl(0, "UatisStatusD", { link = "DiffDelete" })
  vim.api.nvim_set_hl(0, "UatisStatusM", { link = "DiffChange" })
  vim.api.nvim_set_hl(0, "UatisStatusR", { link = "Special" })
end

function M.clear(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  end
end

--- Column where real buffer text starts, so the deleted-line marker can
--- sit in the gutter (left of the number column) and the deleted code
--- itself can start at exactly the column real code starts at.
local function text_offset(win)
  local info = win and vim.api.nvim_win_is_valid(win) and vim.fn.getwininfo(win)[1]
  return (info and info.textoff) or 0
end

--- Screen columns available to a before-image. Virtual lines here are
--- anchored with `virt_lines_leftcol`, so one starts at the very left of
--- the window and has the whole width to fill.
local function window_width(win)
  if win and vim.api.nvim_win_is_valid(win) then
    return vim.api.nvim_win_get_width(win)
  end
end

--- True when `ranges` account for every non-whitespace character of
--- `text`: nothing on the line came through.
---
--- The strict form of the test below, and the honest one. Where it holds,
--- painting the whole row adds only the spaces BETWEEN the marks, which
--- no backend classifies either way, and says "this line is new" in one
--- stroke instead of leaving the reader to notice that every token
--- happens to be tinted.
local function covers_all(ranges, text)
  if #ranges == 0 then
    return false
  end
  local covered = {}
  for _, r in ipairs(ranges) do
    for col = r.col_start, math.min(r.col_end, #text) - 1 do
      covered[col] = true
    end
  end
  local total = 0
  for col = 0, #text - 1 do
    if text:sub(col + 1, col + 1):match("%S") then
      total = total + 1
      if not covered[col] then
        return false
      end
    end
  end
  return total > 0
end

M.covers_all = covers_all

--- Neighbouring ranges merged into one, across whitespace and across
--- whitespace only -- so two marks with real code between them stay two.
---
--- Wanted in two places for what turns out to be one reason. A changed
--- string arrives from difftastic as one range per word and is a single
--- atom (see `atoms`); and on a line of code, the space between two
--- tokens it BOTH called changed is a hole in the middle of one
--- insertion. `edges` gaining `, spacing.channel_padding` comes back as
--- a range on the comma and a range on the argument, with the space
--- between them belonging to neither.
---
--- That hole is a difference between difftastic's display and this one
--- rather than a disagreement with it. difftastic colours FOREGROUNDS,
--- where an uncoloured space is indistinguishable from a coloured one
--- and leaving it out costs nothing -- its own inline display draws that
--- line as green comma, plain space, green argument, and it reads as one
--- addition. Marks here are BACKGROUNDS, and an untinted space between
--- two tinted tokens is the most deliberate-looking thing on the row.
--- Joining them is what says the same thing in this medium; drawing the
--- gap is what would add something difftastic never said.
---
--- Whitespace only, because whitespace is the one run of characters a
--- reader cannot be asked to recognise. Anything else between two marks
--- is code that came through unchanged, and covering it would claim an
--- edit that did not happen.
local function joined(ranges, text)
  table.sort(ranges, function(a, b)
    return a.col_start < b.col_start
  end)
  local out = {}
  for _, r in ipairs(ranges) do
    local last = out[#out]
    if last and text:sub(last.col_end + 1, r.col_start):match("^%s*$") then
      last.col_end = math.max(last.col_end, r.col_end)
    else
      table.insert(out, { col_start = r.col_start, col_end = r.col_end })
    end
  end
  return out
end

M.joined = joined

--- Where on `row` difftastic's own display would go further than its
--- tint: the PROSE atoms -- a docstring, a comment, a long literal --
--- as whole ranges.
---
--- Whole, because the JSON does not report them that way. A changed
--- string arrives as one `change` per word, each carrying the same
--- `string` highlight, with the spaces between the words unmarked; what
--- the reader sees, and what the emphasis is a statement about, is the
--- sentence they make up. So neighbouring ranges are joined back
--- together across whitespace -- and across whitespace only, so two
--- literals with code between them stay two atoms.
---
--- On a line of code there is nothing to return, and there should not
--- be: every atom there is a token, and a changed token is novel in its
--- entirety, so picking out part of one would be inventing a
--- distinction difftastic did not draw.
---
--- `all` is a file difftastic never parsed -- no parser for the
--- extension, or a source file mid-edit that would not go through the one
--- there is. Then there are no tokens anywhere in it: what it compared
--- were words, every atom is prose, and a changed line comes back with
--- every word on it marked. Reading those as tokens is what made a text
--- file band line by line -- a line diff drawn by the structural engine,
--- and worse than the real one, which at least marks the word.
local function atoms(spans, text, all)
  local ranges = {}
  for _, sp in ipairs(spans or {}) do
    if all or sp.atom == "string" or sp.atom == "comment" then
      table.insert(ranges, { col_start = sp.col_start, col_end = sp.col_end })
    end
  end
  return joined(ranges, text)
end

--- The emphasis, kept to where difftastic's own display would draw it:
--- the ranges of `fine` that fall inside one of those atoms.
---
--- Its JSON reports the tint and not the emphasis, so the words are
--- worked out here -- and `atom`, which is what it called the thing each
--- range belongs to, is what says where that is this plugin's job.
local function prose(fine, regions)
  local out = {}
  for _, r in ipairs(fine or {}) do
    for _, sp in ipairs(regions or {}) do
      if r.col_start < sp.col_end and r.col_end > sp.col_start then
        table.insert(out, r)
        break
      end
    end
  end
  return out
end

--- ...and its complement: the parts of each atom in `regions` that the
--- emphasis did NOT pick out, which is what actually gets drawn.
---
--- The emphasis is expressed by stepping this back rather than by
--- pushing the new words forward, so the strongest colour on screen goes
--- on meaning the same thing everywhere.
---
--- That only works as a comparison, so somewhere there has to be a "the
--- emphasis found nothing here, leave it alone". That question is not
--- asked here and not asked of a row: it is asked of the whole node, in
--- `render`, because a row of a changed docstring that gained no new
--- words is exactly the row that most needs stepping back.
local function unstressed(fine, regions)
  local out = {}
  for _, sp in ipairs(regions or {}) do
    local cuts = {}
    for _, r in ipairs(fine or {}) do
      if r.col_start < sp.col_end and r.col_end > sp.col_start then
        table.insert(cuts, {
          col_start = math.max(r.col_start, sp.col_start),
          col_end = math.min(r.col_end, sp.col_end),
        })
      end
    end
    table.sort(cuts, function(a, b)
      return a.col_start < b.col_start
    end)
    local col = sp.col_start
    for _, c in ipairs(cuts) do
      if c.col_start > col then
        table.insert(out, { col_start = col, col_end = c.col_start })
      end
      col = math.max(col, c.col_end)
    end
    if col < sp.col_end then
      table.insert(out, { col_start = col, col_end = sp.col_end })
    end
  end
  return out
end

--- The ranges of `fine` that sit strictly INSIDE one of `spans`.
---
--- What separates the emphasis from a second opinion. difftastic marks an
--- atom as changed, and where that atom is a whole string -- a docstring,
--- a comment, a long literal -- its own display goes further and picks
--- out the words inside it that are actually new. Its JSON reports only
--- the atom, so the words are worked out here; keeping just the ranges
--- that refine an atom keeps this to the same job. A range that IS the
--- atom restates it, and a range covering several says something
--- difftastic did not.
local function refines(fine, spans)
  local out = {}
  for _, r in ipairs(fine or {}) do
    for _, sp in ipairs(spans or {}) do
      if r.col_start >= sp.col_start and r.col_end <= sp.col_end
        and (sp.col_end - sp.col_start) > (r.col_end - r.col_start) then
        table.insert(out, r)
        break
      end
    end
  end
  return out
end

--- The prose atoms of a change, grouped into NODES and asked -- once for
--- each node -- whether the emphasis narrowed it.
---
--- A node is what the emphasis is a statement about. difftastic reports a
--- changed docstring as changed word by word on every row of it, and the
--- words that are actually new are usually on one; deciding row by row
--- said the opposite of what was meant, because the rows that gained
--- nothing had nothing to compare against and so kept the full tint. The
--- only quiet row was the one that had changed.
---
--- Rows belong to the same node while they are consecutive, and a blank
--- row is passed through rather than ending one: a docstring with a
--- paragraph break in it is one docstring, difftastic reports nothing at
--- all for a row with no words on it, and side by side the old revision
--- is laid out with blank rows between its lines.
---
--- `spans_by_row` is what the backend called changed, per row; `text_of`
--- and `fine_of` read the row's text and the emphasis found in it; `all`
--- is a file difftastic never parsed, where every atom is prose. What
--- comes back, per row that carries prose:
---
---   regions   the atoms, whole, joined across whitespace
---   fine      the emphasis inside them
---   quiet     the complement: what to step back
---   full      the atoms ARE the row, indentation aside
---   narrowed  the node this row belongs to had an emphasis somewhere
function M.prose_marks(spans_by_row, text_of, fine_of, all)
  local rows, marks = {}, {}
  for row in pairs(spans_by_row) do
    table.insert(rows, row)
  end
  table.sort(rows)

  local order, narrowed, node, prev = {}, {}, 0, nil
  for _, row in ipairs(rows) do
    local text = text_of(row)
    local regions = atoms(spans_by_row[row], text, all)
    if #regions > 0 then
      local joined = false
      if prev then
        joined = true
        for gap = prev + 1, row - 1 do
          if not text_of(gap):match("^%s*$") then
            joined = false
            break
          end
        end
      end
      if not joined then
        node = node + 1
      end
      local fine = fine_of(row)
      marks[row] = {
        regions = regions,
        fine = prose(fine, regions),
        -- Whether the atom IS the row, quotes and indentation aside.
        -- Where it is, the row is what steps back; where it shares the
        -- line with code, only its own columns do.
        full = covers_all(regions, text),
        node = node,
      }
      table.insert(order, row)
      -- What makes the rest of a node the part that did not change is
      -- that the node was COMPARED against something -- not that the
      -- comparison found anything. A docstring that only gained a word
      -- lost none, so the old side's answer is empty, and the whole of
      -- the old sentence is what did not change: all of it steps back.
      -- Read the other way, `#fine > 0` said "nothing was removed here,
      -- so this is a removal", and painted the old window solid red.
      --
      -- `nil` is the real absence: no comparison was made, because there
      -- was nothing on the other side to make one against. A docstring
      -- with no counterpart is new, or gone, in its entirety.
      if fine ~= nil then
        narrowed[node] = true
      end
      prev = row
    end
  end

  for _, row in ipairs(order) do
    local m = marks[row]
    m.narrowed = narrowed[m.node] or false
    m.quiet = m.narrowed and unstressed(m.fine, m.regions) or {}
  end
  return marks, order
end

-- There is deliberately no "and nothing but punctuation survived" case
-- here. It is tempting -- `widget = Widget(name="a")` rewritten to a
-- different call keeps its brackets and its `=`, and the row comes out
-- green wrapped round islands of punctuation -- but a token difftastic
-- called unchanged IS unchanged, and painting over it is this plugin
-- disagreeing with the thing it exists to show. The band is for a row
-- where nothing at all came through.

--- True when marking `ranges` one by one inside `text` says nothing a
--- single full-width band would not say better -- at which point the line
--- is a rewritten line and should read as one.
---
--- Two ways to be that. The obvious one is coverage: past
--- `config.diff.line.major_ratio` of the line's non-whitespace, what is left
--- unmarked is a remainder, not a part the reader is meant to recognise.
---
--- The other is what actually survived. `var = func(foo, bar)` rewritten
--- to a different call with different arguments keeps its brackets, its
--- comma and its `=`, and marking around them draws green round islands
--- of punctuation -- the punctuation reads as "unchanged", which is true
--- of the character and false of the line. Nothing a reader can name came
--- through, so the line is new. A single surviving identifier or number
--- is enough to make the marks mean something again, and that is exactly
--- the test.
local function rewritten(ranges, text)
  if #ranges == 0 then
    return false
  end
  local covered = {}
  for _, r in ipairs(ranges) do
    for col = r.col_start, math.min(r.col_end, #text) - 1 do
      covered[col] = true
    end
  end
  local total, hit, kept_word = 0, 0, false
  for col = 0, #text - 1 do
    local c = text:sub(col + 1, col + 1)
    if c:match("%S") then
      total = total + 1
      if covered[col] then
        hit = hit + 1
      elseif c:match("[%w_]") then
        kept_word = true
      end
    end
  end
  if total == 0 then
    return false
  end
  return not kept_word or (hit / total) >= config.diff.line.major_ratio
end

--- Whether a line's removals are small enough to read inside the line
--- that replaced them.
---
--- A before-image costs a screen line and asks the reader to compare two
--- rows character by character. For a word swapped in the middle of a
--- line that is a lot of ceremony for one word, and the comparison is
--- easier when the old text sits where the new text is: `self._closed`
--- with `_shutdown` beside it reads at a glance as one edit, rather than
--- as two rows that have to be lined up first.
---
--- It stops being easier once the old text is long enough to push the
--- real code off to the right, or once enough of the line went for the
--- row to be more removal than line. Past either, the old line is worth a
--- row of its own.
local function readable_inline(dels, text)
  local bytes = 0
  for _, d in ipairs(dels) do
    bytes = bytes + (d.col_end - d.col_start)
  end
  if bytes == 0 or bytes > config.diff.line.minor_bytes then
    return false
  end
  if rewritten(dels, text) then
    return false
  end
  local total = 0
  for col = 1, #text do
    if text:sub(col, col):match("%S") then
      total = total + 1
    end
  end
  return total > 0 and (bytes / total) <= config.diff.line.minor_ratio
end

--- Where to draw a removal that belongs at `col` on the new side.
---
--- Sitting it exactly there puts it after whatever replaced it, since the
--- insertion occupies the same gap: `goodbye hello`, new then old, which
--- is backwards from every diff the reader has ever seen. Where an
--- addition ends exactly at that point, the removal goes in front of it.
local function ahead_of_replacement(adds, col)
  for _, a in ipairs(adds or {}) do
    if a.col_end == col then
      return a.col_start
    end
  end
  return col
end

--- The characters of `text` that no range covers, as (columns, text).
local function untouched(text, ranges)
  local marked = {}
  for _, r in ipairs(ranges or {}) do
    for col = r.col_start, math.min(r.col_end, #text) - 1 do
      marked[col] = true
    end
  end
  local cols, kept = {}, {}
  for col = 0, #text - 1 do
    if not marked[col] then
      table.insert(cols, col)
      table.insert(kept, text:sub(col + 1, col + 1))
    end
  end
  return cols, table.concat(kept)
end

--- Where each removal goes on the new line, as { col, text } in the order
--- they were removed -- or nil when the question has no answer.
---
--- Worked out from what did NOT change. Both sides of a substitution
--- report ranges into their own text, and the leftovers -- the characters
--- neither added nor removed -- are the same sequence on both sides.
--- Counting along it turns a position in the old line into the position
--- in the new line that means the same place, which is exactly where the
--- old text was taken from.
---
--- When the two leftovers are not the same text, they are not describing
--- one line's edit -- the comparison ran over a block and matched
--- something on the row above or below -- and there is no honest place to
--- put the removal. Nil, and the old line keeps its own row.
local function inline_places(old_text, dels, new_text, adds)
  local old_cols, old_kept = untouched(old_text, dels)
  local new_cols, new_kept = untouched(new_text, adds)
  if old_kept ~= new_kept then
    return nil
  end

  -- How many untouched characters lie before each column of the old line.
  local before, seen = {}, 0
  for col = 0, #old_text do
    before[col] = seen
    if old_cols[seen + 1] == col then
      seen = seen + 1
    end
  end

  local places = {}
  for _, d in ipairs(dels) do
    local col = new_cols[(before[d.col_start] or 0) + 1] or #new_text
    table.insert(places, {
      col = ahead_of_replacement(adds, col),
      text = old_text:sub(d.col_start + 1, d.col_end),
    })
  end
  return places
end

--- Paints the whole of `row`, with `over` ranges drawn on top of it in
--- `over_hl` -- the emphasis by default, or the dim where what is being
--- said is that the rest of an atom is the part to skip.
---
--- A range's background cannot override a line carrying `line_hl_group`
--- -- at any priority, still true -- so a row with anything over the
--- band is banded with a multiline range and `hl_eol` instead, which
--- reaches the window edge the same way and does compose with a range on
--- top. A plain row keeps the simpler mark.
---
--- Takes its namespace, because the old revision's window draws the same
--- shape in its own (see `oldside.refresh`) and this is not a trick to
--- have written down twice.
local function paint_row(bufnr, ns, row, hl, over, text, count, over_hl)
  if #over == 0 or row + 1 >= count then
    vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
      line_hl_group = hl,
      priority = 100,
    })
  else
    vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
      end_row = row + 1,
      end_col = 0,
      hl_group = hl,
      hl_eol = true,
      priority = 100,
    })
  end
  for _, r in ipairs(over) do
    local s = math.min(r.col_start, #text)
    local e = math.min(r.col_end, #text)
    if e > s then
      vim.api.nvim_buf_set_extmark(bufnr, ns, row, s, {
        end_col = e,
        hl_group = over_hl or "UatisAddText",
        priority = 110,
      })
    end
  end
end

M.paint_row = paint_row

--- Where a hunk's removed lines belong, as a (row0, above) pair.
---
--- vim.diff's deletion anchor reads backwards at first glance: for a pure
--- deletion, `start_b` is the line AFTER WHICH content was removed, and 0
--- means "before everything". For a replacement, `start_b` is the first
--- changed line, and the removed text belongs directly above it.
local function delete_anchor(hunk, line_count)
  if hunk.count_b > 0 then
    return math.max(hunk.start_b - 1, 0), true
  end
  if hunk.start_b == 0 then
    return 0, true
  end
  return math.min(hunk.start_b - 1, math.max(line_count - 1, 0)), false
end

--- Renders `result` (from diff.compute) onto `bufnr`, which must already
--- hold the new-side text. `old_lines` is the old side, split into lines.
---
--- Returns the sorted list of buffer lines a chunk jump should visit,
--- and -- since it is here that the two blocks are compared -- which
--- words each removed line actually lost, for the old revision's own
--- window to draw.
function M.render(bufnr, win, result, old_lines, opts)
  opts = opts or {}
  -- Side-by-side puts the old revision in a window of its own, so drawing
  -- it here as well would say everything twice -- once as code you can
  -- search and once as a decoration you cannot. The new side keeps its
  -- own marks: what was added is a property of THIS buffer either way.
  local show_old = opts.before ~= false
  M.clear(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return {}
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local offset = text_offset(win)
  local marker = config.marker.delete
  local pad = string.rep(" ", math.max(offset - vim.fn.strdisplaywidth(marker), 0))
  local anchors = {}

  -- Removed lines are drawn as virtual text, and nothing highlights
  -- virtual text: both of Neovim's highlighters run over real buffer
  -- lines. Parsed here instead, so the old side is read in the same
  -- colours as the new one -- see `syntax.lua`. Every removal row is
  -- offered up front, because which of them end up drawn is decided
  -- further down and a second parse would cost more than the few extra
  -- rows do.
  local del_rows = {}
  for _, hunk in ipairs(result.hunks or {}) do
    for i = 0, hunk.count_a - 1 do
      table.insert(del_rows, hunk.start_a + i)
    end
  end
  local syn = #del_rows > 0
    and syntax.spans(table.concat(old_lines, "\n"), vim.bo[bufnr].filetype, del_rows)
    or nil

  -- A removed line is a removed LINE, and a band that stops at its last
  -- character says something weaker: the red ends in a ragged edge that
  -- tracks the length of the old code rather than marking the row. Real
  -- lines get this for free -- `line_hl_group` paints to the window edge
  -- -- and virtual ones have to be padded out by hand. Only whole-line
  -- removals are filled: where the red marks CHARACTERS inside a line
  -- that mostly survived, running it to the edge would claim the rest of
  -- the line went with them.
  local width = window_width(win)
  local function fill(chunks, hl)
    if not width then
      return
    end
    local used = 0
    for _, c in ipairs(chunks) do
      -- Measured from the column it starts at, because a tab's width
      -- depends on where it lands.
      used = used + vim.fn.strdisplaywidth(c[1], used)
    end
    if used < width then
      table.insert(chunks, { string.rep(" ", width - used), hl })
    end
  end

  -- Before-images are collected here and emitted once per anchor rather
  -- than one extmark per hunk. Two hunks whose removed lines land on the
  -- same row -- consecutive deletions with nothing between them on the new
  -- side -- would otherwise be two extmarks at one position, and the order
  -- Neovim stacks those in is not the order they were created: a row that
  -- also carries a virt_lines_above mark renders its below marks in
  -- reverse. Deleted blocks then appear in the wrong order relative to the
  -- old file, which reads as though the code moved. One extmark per anchor
  -- puts the ordering back where it belongs, in the loop below.
  local before, before_order = {}, {}
  local function add_before(row, above, virt)
    local key = row .. (above and "a" or "b")
    if not before[key] then
      before[key] = { row = row, above = above, virt = {} }
      table.insert(before_order, key)
    end
    vim.list_extend(before[key].virt, virt)
  end

  -- Spans on the new side, grouped by the line they land on, with
  -- whether they leave enough of that line unmarked to be worth marking
  -- at all.
  local by_row, rewrote = {}, {}
  for _, span in ipairs(result.spans or {}) do
    if span.kind == "add" then
      local row = span.line - 1
      if row >= 0 and row < line_count then
        by_row[row] = by_row[row] or {}
        table.insert(by_row[row], span)
      end
    end
  end
  for row, spans in pairs(by_row) do
    local text = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
    rewrote[row] = rewritten(spans, text)
  end

  -- Highlight at the granularity the backend actually knows.
  --
  -- `vim.diff` only knows lines, so a changed line gets a full-width
  -- band; that is an honest statement of what it can tell you. The
  -- structural backend knows individual tokens, and painting the whole
  -- line there overstates the change -- a line where one argument gained
  -- a default reads as though all of it were rewritten, and a run of new
  -- lines reads as a solid block of "added" even where most of each line
  -- is unchanged text that merely moved. So when the backend's spans are
  -- token-precise, only the changed tokens get the tint and the rest of
  -- the line is left alone.
  --
  -- A line whose spans cover all of its non-whitespace is the exception:
  -- there the band and the tokens say the same thing, so the band wins
  -- as the cheaper, calmer drawing. So is a line with no line of its own
  -- to be compared against -- see `paired` below.
  local line_marked, token_marked, unpaired = {}, {}, {}

  -- Rows carrying a changed PROSE atom, held back until every hunk has
  -- had its say: what to draw on one of them is a question about the
  -- node, and a node can run past a hunk (the blank row in the middle of
  -- a docstring is a row difftastic calls unchanged). See the pass below
  -- `hunks`, and `prose_marks`.
  local prose_spans, prose_fine, prose_band = {}, {}, {}

  -- ...and the same for the OLD side, which is a window of its own in
  -- side-by-side and needs the same statement made about it: which words
  -- of a changed atom actually went away. Worked out here, where the two
  -- blocks are already sliced and compared, and handed back for
  -- `oldside.refresh` to draw -- so the two windows cannot end up
  -- disagreeing about what changed.
  local del_fine = {}

  local function line_text(row)
    return vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  end

  -- Which hunk each new-side row belongs to. A row inside a hunk is a row
  -- that hunk is making a claim about -- it will be banded, or marked --
  -- and that matters when deciding whether code MOVED rather than went
  -- away: see the survival window below.
  local claimed_by = {}
  for idx, hunk in ipairs(result.hunks or {}) do
    for i = 0, hunk.count_b - 1 do
      claimed_by[hunk.start_b - 1 + i] = idx
    end
  end

  for hidx, hunk in ipairs(result.hunks or {}) do
    -- A hunk that replaces N lines with N lines pairs them up, and a
    -- paired line can be compared against the exact line it replaced.
    -- That is worth doing regardless of backend: it is the only way to
    -- say which CHARACTERS were inserted and which were taken away, which
    -- neither `vim.diff` (lines only) nor difftastic (whole tokens, and a
    -- docstring is one token) reports on its own.
    -- Only where the hunk's two sides correspond line for line. A hunk
    -- that replaces one line with three has no pairing to compare, and
    -- guessing one across the break turns a substitution into a scatter
    -- of whitespace marks -- it stops reading as "this was replaced by
    -- that", which is the one thing a line diff is for. Equal counts are
    -- not enough either: wrapping an expression in parentheses keeps the
    -- count while shifting the content down a line, and pairing by
    -- position then reports the tail of each line as removed, leaving a
    -- before-image of red fragments that cannot be read back as the old
    -- code.
    local olds, news = {}, {}
    for i = 1, hunk.count_a do
      olds[i] = old_lines[hunk.start_a + i - 1] or ""
    end
    for i = 1, hunk.count_b do
      news[i] = line_text(hunk.start_b + i - 2)
    end

    -- Whether the edit took any code away, as opposed to moving it.
    -- Decides whether a before-image is worth drawing at all.
    --
    -- Asked against a WINDOW of the new buffer, not just the hunk's own
    -- new lines. A structural backend is free to report a wrap as a
    -- deletion here and an insertion three rows down -- two hunks, so the
    -- deletion's own new side is empty and the code it supposedly removed
    -- is sitting just outside it. Looking only within the hunk answers
    -- "did this text move out of these exact rows", which is not the
    -- question; looking at the neighbourhood answers "is this code still
    -- on screen", which is.
    local ctx = config.diff.line.survives_context
    local first = math.max(0, hunk.start_b - 1 - ctx)
    local last = math.min(line_count - 1,
      hunk.start_b - 1 + math.max(hunk.count_b, 1) - 1 + ctx)
    --
    -- Rows another hunk speaks for are left OUT of the window, though.
    -- "This code did not go away, it is still on screen" is only true if
    -- the reader can SEE it still there, and a row inside another hunk is
    -- one that hunk is painting as added. Moving a test into a class
    -- makes difftastic report the old body as removed here and the
    -- reindented copy as added three rows down: counting those rows as
    -- survival suppressed the before-image while the copy was painted
    -- green, so the old code appeared nowhere at all and its replacement
    -- claimed to be new. Rows no hunk claims are the ones that read as
    -- unchanged code, and those are what moving into looks like.
    local window = {}
    for row = first, last do
      local owner = claimed_by[row]
      if owner == nil or owner == hidx then
        table.insert(window, line_text(row))
      end
    end
    -- Asked of the block and not of each line in it. A hunk is one
    -- statement -- these lines became those -- and a before-image that
    -- kept some of the old rows and dropped others is not readable as the
    -- code that was there. Where one row of the block really did only move
    -- down, showing it costs a red copy of a line the reader can see is
    -- still below; dropping it costs the shape of what was replaced.
    local content_survives = hunk.count_a > 0 and diff.content_survives(olds, window)

    -- Whether a new row has one old row answering to it. Marks inside a
    -- line say "these characters changed and the rest did not", and that
    -- sentence needs a line for "the rest" to have come from -- one the
    -- reader can see, directly above.
    --
    -- Asked of the backend where the backend knows. difftastic aligns the
    -- two files row by row and says which old row each new row answers
    -- to, and `result.anchor` puts that row directly above its partner,
    -- so the comparison a mark describes is the one on screen. Only where
    -- there is no pairing does the question fall back to the shape of the
    -- hunk: with the two sides the same length the rows line up, and
    -- where they do not there is no such line at all -- drawing marks
    -- then says `def`, the brackets and the colon came through unchanged
    -- from a line that is nowhere on screen, and the row reads as having
    -- replaced `def ():`, which never existed.
    local function paired_row(row)
      if result.pairs then
        return result.pairs[row + 1] ~= nil
      end
      return hunk.count_a == hunk.count_b
    end

    local inline, any_del = nil, false
    if hunk.count_a > 0 and diff.lines_correspond(olds, news) then
      local r = diff.block_diff(olds, news)
      if r then
        inline = { adds = {}, dels = {} }
        for _, a in ipairs(r.adds) do
          inline.adds[a.line] = inline.adds[a.line] or {}
          table.insert(inline.adds[a.line], a)
        end
        for _, d in ipairs(r.dels) do
          inline.dels[d.line] = inline.dels[d.line] or {}
          table.insert(inline.dels[d.line], d)
        end
        any_del = #r.dels > 0
      end
    end

    -- Which words inside what the backend called changed are the actual
    -- edit -- difftastic's emphasis, which its JSON does not report and
    -- which is worked out here the same way it works it out there.
    --
    -- Compared BLOCK against block, without asking the two sides to pair
    -- up line for line. That gate belongs to the before-image, where
    -- pairing a line against the wrong one draws red fragments over
    -- unreadable context; here the answer can only ever narrow a mark
    -- that is already there, so a hunk of fifteen lines against sixteen
    -- -- a docstring gaining a line, which is exactly when a reader wants
    -- to know which words are new -- has an answer too.
    local emphasis
    local pair = inline
    if not pair and result.precise and hunk.count_a > 0 and hunk.count_b > 0 then
      local r = diff.block_diff(olds, news)
      if r then
        local adds, dels = {}, {}
        for _, a in ipairs(r.adds) do
          adds[a.line] = adds[a.line] or {}
          table.insert(adds[a.line], a)
        end
        -- Both sides of the same comparison. What a docstring gained is
        -- the emphasis on the new side; what it lost is the emphasis on
        -- the old one, and dropping it here left the old window with a
        -- solid red block where this window has a sentence with two
        -- words picked out of it.
        for _, d in ipairs(r.dels) do
          dels[d.line] = dels[d.line] or {}
          table.insert(dels[d.line], d)
        end
        pair = { adds = adds, dels = dels }
      end
    end
    emphasis = pair and pair.adds or nil
    -- An empty answer where there WAS a comparison, and nil where there
    -- was none: a line that lost nothing is not the same as a line
    -- nothing was asked about. See `prose_marks`.
    if pair and pair.dels then
      for i = 1, hunk.count_a do
        del_fine[hunk.start_a + i - 1] = pair.dels[i] or {}
      end
    end

    -- Lines whose removals are small enough to draw inside the line that
    -- replaced them, instead of on a row of their own above it. `merged`
    -- is keyed by the removed line's index in the hunk, which is what the
    -- before-image loop asks it; `merged_at` by the new row the removals
    -- get drawn on. The two are the same index only where the sides pair
    -- up position by position, which difftastic's pairing does not.
    local merged, merged_at = {}, {}
    if inline and hunk.count_b > 0 then
      for i = 1, hunk.count_a do
        local dels = inline.dels[i] or {}
        local old_text = old_lines[hunk.start_a + i - 1] or ""
        local new_text = line_text(hunk.start_b + i - 2)
        if #dels == 0 and diff.content_survives({ old_text }, { new_text }) then
          -- Nothing was taken out of this line: every character of it is
          -- still there in the line below, and a row repeating it says
          -- only that the line moved down one. Empty rather than absent
          -- -- there is nothing to draw in place either.
          --
          -- Asked of the text rather than read off the token diff, which
          -- can come back with no removals for a line that did lose
          -- something: alignment inside a block is a guess, and a row is
          -- the only place the old text would have been shown.
          merged[i] = {}
        elseif readable_inline(dels, old_text) then
          merged[i] = inline_places(old_text, dels, new_text, inline.adds[i] or {})
        end
        merged_at[hunk.start_b + i - 2] = merged[i]
      end
    elseif result.precise and result.pairs and hunk.count_b > 0 then
      -- A new row difftastic paired with an old one and reported no
      -- changed tokens for. That is not the same as a row that did not
      -- change: it is what comes back whenever every token the new line
      -- kept was matched somewhere in the old one, so the whole edit
      -- lands on the old side as removals and the new side has nothing
      -- left to mark. `"|".join(col.types)` becoming `types` is the
      -- shape -- the surviving `types` matches the one inside
      -- `col.types`, difftastic reports the RHS as unchanged, and the
      -- line that changed comes out with no mark on it at all while a
      -- full red copy of the old line sits above saying nothing about
      -- which part of it went. Side by side that reads fine, because the
      -- two rows are level with each other; inline it does not, because
      -- the correspondence is exactly what the layout has spent.
      --
      -- So the removals are drawn where they happened, in the line that
      -- replaced them -- the same statement line mode already makes, and
      -- the only one that puts the change back on the changed row
      -- without claiming difftastic found an addition it did not.
      --
      -- Compared as a PAIR rather than block against block. difftastic
      -- already said which old row this one answers to, and a one-line
      -- comparison is the only one whose untouched text is the same
      -- sequence on both sides -- which is what `inline_places` needs to
      -- place anything at all.
      for i = 0, hunk.count_b - 1 do
        local row = hunk.start_b - 1 + i
        local old_row = result.pairs[row + 1]
        if (not by_row[row] or #by_row[row] == 0)
          and old_row and old_row >= hunk.start_a
          and old_row < hunk.start_a + hunk.count_a then
          local old_text = old_lines[old_row] or ""
          local new_text = line_text(row)
          local r = old_text ~= new_text and diff.block_diff({ old_text }, { new_text }) or nil
          local dels = r and r.dels or {}
          if #dels > 0 and readable_inline(dels, old_text) then
            local places = inline_places(old_text, dels, new_text, r.adds)
            if places then
              merged[old_row - hunk.start_a + 1] = places
              merged_at[row] = places
            end
          end
        end
      end
    end

    -- Present in the new side: highlight the real lines.
    if hunk.count_b > 0 then
      -- Green, whether or not the hunk also removes something. Removal
      -- is what the red before-image directly above says; colouring the
      -- new side a third colour for "changed" only asks the reader to
      -- decode which of two greens-that-are-not-green they are looking
      -- at. Added is added.
      local hl = "UatisAdd"
      for i = 0, hunk.count_b - 1 do
        local row = hunk.start_b - 1 + i
        if row < line_count then
          local text = line_text(row)

          -- Which marks to draw, in order of how much the source knows.
          --
          -- A token-precise backend's spans are drawn AS THEY ARE. It
          -- aligned the two files itself, row by row and token by token,
          -- and every rule of ours layered over that -- band the line if
          -- the marks cover most of it, band it if the counts do not pair
          -- up, compare the pair again for finer detail -- is this plugin
          -- disagreeing with the thing it exists to show. Structural mode
          -- is a window onto difftastic, so what difftastic said is what
          -- appears: the tokens it called changed, tinted; everything
          -- else, including the brackets and the spaces between them,
          -- left alone. That is what its own display does.
          --
          -- The exception is a backend that claims precision without an
          -- alignment. Nothing produces that today -- difftastic always
          -- reports `aligned_lines` -- but marks whose counterpart cannot
          -- be put on screen are marks nobody can check, so those still
          -- fall back to the counts.
          local spans, span_hl, ranged, whole = nil, hl, false, false
          if result.precise and by_row[row] and #by_row[row] > 0
            and (result.pairs ~= nil or paired_row(row)) then
            spans, ranged = by_row[row], true
            -- A line every token of which the backend called changed is
            -- a line that is new, whether or not it was aligned with
            -- something. Painting it whole adds only the spaces between
            -- the marks -- which no backend classifies either way -- and
            -- says in one stroke what the reader would otherwise have to
            -- notice token by token.
            --
            -- Nothing is lost by it: there is no unchanged token left on
            -- the row for the paint to bury. Where the emphasis knows
            -- which words inside it are the actual edit -- a docstring
            -- with one word added reports every word as changed -- that
            -- is still said, by drawing the rest of the sentence a shade
            -- quieter, which composes over a banded row where a second
            -- colour on the words themselves would not.
            whole = covers_all(spans, text)
            -- difftastic's own display makes that distinction -- a
            -- changed string is tinted whole and the novel words in it
            -- come out bold -- but its JSON reports only the tint: every
            -- word of the string arrives as a change, with nothing to
            -- say which of them is the new one. So the emphasis is
            -- worked out here the same way difftastic works it out
            -- there, and what is drawn is its inverse: the words that
            -- ARE the edit keep the ordinary tint, and the sentence they
            -- landed in steps back from them. Nothing difftastic called
            -- changed is drawn as unchanged -- only as less of the
            -- story, which is what it is.
            prose_spans[row] = by_row[row]
            prose_fine[row] = emphasis and (emphasis[i + 1] or {}) or nil
          elseif not result.precise and inline then
            spans = inline.adds[i + 1] or {}
            -- Inserted text is inserted text whichever side of a
            -- replacement it sits on, so it is green rather than the
            -- hunk's own colour: the point of marking characters is
            -- that the eye can tell added from removed without reading.
            span_hl = "UatisAdd"
            -- A line the comparison marks end to end is a line that is
            -- genuinely all new; a band draws that more calmly than a
            -- range per token.
            ranged = not rewritten(spans, text)
          end

          -- A line inside a structural hunk that the backend reports no
          -- changes for is unchanged code that moved. Marking it at all
          -- -- banded, or from a comparison of our own -- would claim an
          -- edit the backend explicitly did not report.
          if result.precise and (not by_row[row] or #by_row[row] == 0) then
            token_marked[row] = true
          elseif whole then
            -- Painted below. Whether anything on it steps back depends
            -- on whether it is prose, and if it is, on rows this hunk
            -- may not even contain.
            prose_band[row] = hl
            line_marked[row] = true
            token_marked[row] = true
          elseif ranged then
            for _, span in ipairs(joined(spans, text)) do
              local s = math.min(span.col_start, #text)
              local e = math.min(span.col_end, #text)
              if e > s then
                vim.api.nvim_buf_set_extmark(bufnr, M.ns, row, s, {
                  end_col = e,
                  hl_group = span_hl,
                  priority = 100,
                })
              end
            end
            -- A prose atom among them steps back below, where the
            -- node it belongs to is known.
            token_marked[row] = true
          elseif inline and #spans == 0 then
            -- Nothing was inserted into this line at all: its text came
            -- through the change untouched and only moved. Marking it
            -- would claim a change that did not happen.
            token_marked[row] = true
          else
            vim.api.nvim_buf_set_extmark(bufnr, M.ns, row, 0, {
              line_hl_group = hl,
              priority = 100,
            })
            line_marked[row] = true
            unpaired[row] = not paired_row(row)
          end

          -- The old text, in place. One extmark per position rather than
          -- one per removal, because two removals from the same gap are
          -- drawn in the order Neovim happens to stack marks in, and that
          -- is not the order they were taken out.
          if merged_at[row] and show_old then
            local at, order = {}, {}
            for _, place in ipairs(merged_at[row]) do
              local col = math.max(0, math.min(place.col, #text))
              if not at[col] then
                at[col] = {}
                table.insert(order, col)
              end
              table.insert(at[col], place.text)
            end
            for _, col in ipairs(order) do
              vim.api.nvim_buf_set_extmark(bufnr, M.ns, row, col, {
                virt_text = { { table.concat(at[col]), "UatisDelete" } },
                virt_text_pos = "inline",
                priority = 100,
              })
            end
          end
        end
      end
      table.insert(anchors, math.min(hunk.start_b, line_count))
    end

    -- Nothing was removed from any of these lines, so there is no old
    -- text to recover and the before-image would only repeat what is
    -- already highlighted one line below it.
    -- Line mode always shows what a line was replaced by -- that IS the
    -- statement a line diff makes. Structural mode only shows a
    -- before-image when something was genuinely removed: wrapping an
    -- expression in parentheses moves the code, it does not delete it,
    -- and a full red copy of a line that is still on screen below reads
    -- as a much bigger change than happened.
    -- Line mode still states a substitution -- "this line became those
    -- lines" is what a line diff says -- unless the two sides line up and
    -- the edit was purely additive, where the old text is readable in the
    -- new line already. Structural mode goes further: moving code is not
    -- deleting it, so nothing that survives gets a before-image.
    local pure_insertion = content_survives and (inline ~= nil or result.precise)

    -- Absent from the new side: draw it as virtual lines.
    if hunk.count_a > 0 and not pure_insertion and show_old then
      local virt, drawn = {}, 0
      for i = 0, hunk.count_a - 1 do
        local text = old_lines[hunk.start_a + i]
        -- ...except where it was already drawn inside the line below.
        if text ~= nil and not merged[i + 1] then
          -- Where the removed characters are known, the rest of the old
          -- line is context: it is drawn dimmed so the eye lands on what
          -- actually went away rather than on a solid red band that says
          -- "all of this" when most of it came back.
          -- ...unless what went away amounts to the whole line, in which
          -- case dimming the punctuation that happens to have survived
          -- draws islands of context inside a line nobody kept: the old
          -- line reads as removed, so it is drawn as removed.
          local dels = inline and inline.dels[i + 1]
          if dels and rewritten(dels, text) then
            dels = nil
          end
          local chunks = { { marker .. pad, "UatisSign" } }
          if dels and #dels > 0 then
            local at = 0
            for _, d in ipairs(dels) do
              local s = math.min(d.col_start, #text)
              local e = math.min(d.col_end, #text)
              if s > at then
                table.insert(chunks, { text:sub(at + 1, s), "UatisDeleteDim" })
              end
              if e > s then
                table.insert(chunks, { text:sub(s + 1, e), "UatisDelete" })
              end
              at = math.max(at, e)
            end
            if at < #text then
              table.insert(chunks, { text:sub(at + 1), "UatisDeleteDim" })
            end
          else
            local runs = syn and syn[hunk.start_a + i]
            local hl = "UatisDelete"
            if runs and text ~= "" then
              vim.list_extend(chunks, syntax.chunks(text, runs, "UatisDeleteBg"))
              hl = "UatisDeleteBg"
            else
              table.insert(chunks, { text ~= "" and text or " ", "UatisDelete" })
            end
            fill(chunks, hl)
          end
          -- Where the backend aligned the two files row by row, each
          -- removed line goes directly above the new line it answers to
          -- rather than into one block at the top of the hunk. Same
          -- lines, same order, same statement -- but a mark on a new row
          -- is then something the reader can check, because the row it
          -- was measured against is the one immediately above it.
          -- Without an alignment there is nothing finer to say than
          -- "these lines became those", and the block is that.
          local at = result.anchor and result.anchor[hunk.start_a + i]
          if at then
            add_before(math.min(at - 1, math.max(line_count - 1, 0)), true, { chunks })
          else
            table.insert(virt, chunks)
          end
          drawn = drawn + 1
        end
      end
      local row, above = delete_anchor(hunk, line_count)
      if #virt > 0 then
        add_before(row, above, virt)
      end
      if drawn > 0 and hunk.count_b == 0 then
        table.insert(anchors, math.min(math.max(row + 1, 1), math.max(line_count, 1)))
      end
    elseif hunk.count_a > 0 and hunk.count_b == 0 and not pure_insertion then
      -- Nothing is drawn here, but something WAS removed here, and `]c`
      -- has to stop for it: side by side, the row it stops on is the row
      -- the other window is showing the removal against.
      local row = delete_anchor(hunk, line_count)
      table.insert(anchors, math.min(math.max(row + 1, 1), math.max(line_count, 1)))
    end
  end

  -- The emphasis is a statement about a NODE, so it is drawn once the
  -- whole node is known -- which is here, and not in the loop above.
  local marks, order = M.prose_marks(prose_spans, line_text, function(row)
    return prose_fine[row]
  end, result.prose)

  -- A banded row with no prose on it: nothing here to narrow, and the
  -- band is the whole of what it has to say.
  for row, band in pairs(prose_band) do
    if not marks[row] then
      paint_row(bufnr, M.ns, row, band, {}, line_text(row), line_count)
    end
  end

  for _, row in ipairs(order) do
    local p, text = marks[row], line_text(row)
    local band = prose_band[row]
    if not p.narrowed then
      if band then
        paint_row(bufnr, M.ns, row, band, {}, text, line_count)
      end
    elseif p.full and band then
      -- The atom is the whole row, so the ROW is what steps back --
      -- indentation, quotes and the run out to the window edge with it.
      -- Stepping back only the words would leave those at full strength
      -- around a sentence that is quieter than they are, which reads as
      -- a line striped rather than as a line to skim.
      paint_row(bufnr, M.ns, row, "UatisAddDim", p.fine, text, line_count, band)
    elseif band then
      -- An atom sharing its line with code steps back inside its own
      -- columns: the code beside it is a change of its own and has
      -- nothing to do with what the sentence gained.
      paint_row(bufnr, M.ns, row, band, p.quiet, text, line_count, "UatisAddDim")
    else
      -- ...and where the row was drawn token by token, the tints are
      -- already there and only the stepping back is left to do.
      for _, r in ipairs(p.quiet) do
        local s = math.min(r.col_start, #text)
        local e = math.min(r.col_end, #text)
        if e > s then
          vim.api.nvim_buf_set_extmark(bufnr, M.ns, row, s, {
            end_col = e,
            hl_group = "UatisAddDim",
            priority = 110,
          })
        end
      end
    end
  end

  for _, key in ipairs(before_order) do
    local b = before[key]
    vim.api.nvim_buf_set_extmark(bufnr, M.ns, b.row, 0, {
      virt_lines = b.virt,
      virt_lines_above = b.above,
      -- Anchored at column 0, left of the number column, so the marker
      -- occupies the sign position and the code lines up with real buffer
      -- text.
      virt_lines_leftcol = true,
      priority = 100,
    })
  end

  -- Where the line still carries a full-width band -- the line backend,
  -- whose spans are one coarse range per changed line rather than real
  -- tokens -- the spans are drawn on top of it in the stronger colour,
  -- marking which part of the line differs without claiming the precision
  -- the backend does not have. Skipped where the tokens already ARE the
  -- highlight, and where they cover the whole line and would only restate
  -- the band.
  --
  -- Skipped too on a line banded for want of a line to compare it
  -- against: emphasising the tokens there says the same untrue thing the
  -- tint would have, only quieter.
  for row, spans in pairs(by_row) do
    if line_marked[row] and not unpaired[row]
      and not token_marked[row] and not rewrote[row] then
      local text = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
      -- Re-drawn rather than added to: the band this row already carries
      -- is a `line_hl_group`, which no range can be seen on top of.
      vim.api.nvim_buf_clear_namespace(bufnr, M.ns, row, row + 1)
      paint_row(bufnr, M.ns, row, "UatisAdd", spans, text, line_count)
    end
  end

  table.sort(anchors)
  local uniq = {}
  for _, a in ipairs(anchors) do
    if uniq[#uniq] ~= a then
      table.insert(uniq, a)
    end
  end
  return uniq, del_fine
end

return M
