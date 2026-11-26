-- Blocks, as the lines they are drawn as.
--
-- `render.markdown` says what each part of a text is; this says what it
-- looks like: prose wrapped to the width there is, a heading without its
-- hashes, a table ruled and padded, a list item hanging under its
-- bullet, a citation behind a bar. What comes out is lines of chunks --
-- `{ text, hl }`, with `ref` on the ones that point somewhere and
-- `style` on the ones written with a weight -- which is the shape
-- virtual text takes as it is, and which `M.flatten` turns into lines
-- and extmarks for a real buffer.
--
-- Everything a caller might draw differently is an option, so that the
-- same drawing serves a page of its own and a comment set inside
-- something else:
--
--   width        the most a line of prose may reach, `lead` included;
--                nil for no wrapping at all
--   code         the same for what means what it means by its columns
--                -- a fence, a table -- and `false` for never; `width`
--                when it is left out
--   lead         what stands in front of every line (a rail, a margin),
--                in `lead_hl`
--   hl           the colour of the words; nil for the window's own
--   groups       `{ meta, citation, heading, head, ok, math, rule,
--                band, ruler }` -- `heading` and `ruler` are prefixes,
--                and the level goes on the end; `band` is a heading's
--   headings     how each level of heading stands out, beyond its
--                colour: a list, by level, of `{ above, band, rule }`
--                -- `above` blank lines before it at the least, `band`
--                a ground across the whole width under it (`true` for
--                `groups.band`, or a group), `rule` a character ruled
--                across the width under it, in `groups.ruler`. nil, or
--                `false` for a level, is the colour alone
--   glyphs       `{ bullets, tasks, citation }`
--   inline(text) a line as `drawn, runs` (`render.markdown.inline`)
--   paint(lines, lang)  code, coloured, as `render.syntax.paint` gives
--                it; nil for code in one colour
--   custom(block, ctx, lead, hl)  draws a block this module does not
--                know, and says so by returning true; `ctx` is `{ body,
--                front, emit, code, width }`, the pieces it is drawn
--                with, where `body(lead, text, hl, sign, runs, cap, band)`
--                is one line wrapped and put down
--
-- Each line carries `row`, the line of the source its block began on,
-- and a heading's first line `heading`, its words -- which is what a
-- reader needs to put the cursor back and to follow `#a-heading`.

local M = {}

M.GROUPS = {
  meta = "RenderMeta",
  citation = "RenderCitation",
  heading = "RenderHeading",
  head = "RenderTableHead",
  ok = "RenderOk",
  math = "RenderMath",
  rule = "RenderMeta",
  band = "RenderHeadingBand",
  ruler = "RenderHeadingRule",
}

M.GLYPHS = {
  bullets = { "•", "◦", "▪" },
  tasks = { "☐", "✓" },
  citation = "▎ ",
}

--- The longest prefix of `s` that fits in `width` columns, whole
--- characters only.
function M.fit(s, width)
  local out, w = "", 0
  for i = 0, vim.fn.strchars(s) - 1 do
    local ch = vim.fn.strcharpart(s, i, 1)
    local cw = vim.fn.strdisplaywidth(ch)
    if w + cw > width then
      -- A first character wider than the room it is given goes in
      -- anyway; otherwise nothing ever fits and the cut never ends.
      if out == "" then
        out = ch
      end
      break
    end
    out, w = out .. ch, w + cw
  end
  return out
end

--- `text`, cut into lines no wider than `width` columns.
---
--- Broken at spaces, and inside a word only when the word is wider than
--- a whole line on its own -- a URL in a narrow split. Cutting one is
--- ugly; the alternative is a line that stops in the middle and does
--- not say so.
---
--- The line's own leading whitespace survives on the first piece, so an
--- indented line keeps the shape it was written in.
function M.wrap(text, width)
  if not width or width < 1 or vim.fn.strdisplaywidth(text) <= width then
    return { text }
  end
  local out = {}
  local line, empty = text:match("^%s*"), true
  for space, word in text:gmatch("(%s*)(%S+)") do
    local candidate = empty and (line .. word) or (line .. space .. word)
    if vim.fn.strdisplaywidth(candidate) <= width then
      line, empty = candidate, false
    else
      if not empty then
        table.insert(out, line)
      end
      while vim.fn.strdisplaywidth(word) > width do
        local head = M.fit(word, width)
        table.insert(out, head)
        word = word:sub(#head + 1)
      end
      line, empty = word, false
    end
  end
  if not empty then
    table.insert(out, line)
  end
  return #out > 0 and out or { text }
end

--- The chunks of `runs` covering bytes [from, to) of the line they were
--- made for, cut to fit -- which is what a wrapped line needs, since
--- the colours were worked out against the line whole.
function M.slice(runs, from, to)
  local out, at = {}, 1
  for _, run in ipairs(runs) do
    local first, last = at, at + #run[1]
    at = last
    local a, b = math.max(first, from), math.min(last, to)
    if b > a then
      -- What the run points at goes with every piece of it: a link
      -- wrapped across two lines is one link, and the key that follows
      -- it is pressed on whichever half the cursor is on.
      table.insert(
        out,
        { run[1]:sub(a - first + 1, b - first), run[2], ref = run.ref, style = run.style }
      )
    end
  end
  return out
end

--- `text` wrapped to `room`, as the pieces it comes to and the colours
--- of each (`{ text, runs }`): the cut a wrapped line makes, for what is
--- drawn inside something -- a cell, a box -- rather than on a line.
function M.pieces(text, runs, room)
  local cut, cursor = {}, 1
  for _, piece in ipairs(M.wrap(text, room)) do
    local at = text:find(piece, cursor, true) or cursor
    cursor = at + #piece
    table.insert(cut, { text = piece, runs = runs and M.slice(runs, at, at + #piece) or nil })
  end
  return cut
end

--- How wide `chunks` is drawn.
function M.measure(chunks)
  local w = 0
  for _, chunk in ipairs(chunks) do
    w = w + vim.fn.strdisplaywidth(chunk[1])
  end
  return w
end

-- The rules of a table: the corners, the tees and the cross.
local RULE = {
  top = { "┌", "┬", "┐" },
  head = { "├", "┼", "┤" },
  bottom = { "└", "┴", "┘" },
}

--- `blocks` (`render.markdown.blocks`) as lines of chunks. See the top
--- of this file for `opts`.
function M.blocks(blocks, opts)
  opts = opts or {}
  local groups = vim.tbl_extend("force", M.GROUPS, opts.groups or {})
  local glyphs = vim.tbl_extend("force", M.GLYPHS, opts.glyphs or {})
  local inline = opts.inline
    or function(text)
      return require("render.markdown").inline(text)
    end
  local limit = opts.width
  -- The width a line of *code* may reach, which is not the same
  -- question. A sentence broken at a space is the same sentence; a
  -- fence and a ruled table mean what they mean by their columns, and
  -- folding one at the edge of a narrow window destroys the thing being
  -- shown. A caller with somewhere for a long line to go -- a real
  -- window, which can be scrolled sideways -- says `code = false`.
  local code = opts.code
  if code == nil then
    code = limit
  end
  local out = {}
  local heading
  local bar = glyphs.citation or ""
  local cited = 0
  -- The source line the block being drawn began on.
  local row

  local function emit(line)
    line.row = row
    table.insert(out, line)
  end

  --- What stands at the front of a line: `lead` as chunks, the margin's
  --- part in the lead's colour and each citation bar in its own.
  local function front(lead)
    local chunks = {}
    local own = lead:sub(1, #lead - #bar * cited)
    if own ~= "" then
      table.insert(chunks, { own, opts.lead_hl })
    end
    for _ = 1, cited do
      table.insert(chunks, { bar, groups.citation })
    end
    return chunks
  end

  -- One line of text, wrapped and put down behind `lead`. `sign` is
  -- what stands in front of the first piece only -- a bullet, a number
  -- -- and the pieces after it are indented past where it would be, so
  -- a wrapped item stays inside its column. `{ text, hl }` for a sign
  -- in a colour of its own. `cap` is the width to break at: absent is
  -- the prose limit, and `false` is no breaking at all. `band` is a
  -- ground under the words -- the half of a diff a line is in -- with
  -- the words' own colours laid over it.
  local function body(lead, text, hl, sign, runs, cap, band)
    local sign_hl
    if type(sign) == "table" then
      sign, sign_hl = sign[1], sign[2]
    end
    sign = sign or ""
    local pad = (" "):rep(vim.fn.strdisplaywidth(sign))
    if cap == nil then
      cap = limit
    end
    local room = cap and (cap - vim.fn.strdisplaywidth(lead) - #pad)
    local cursor = 1
    for j, piece in ipairs(M.wrap(text, room)) do
      local marker = j > 1 and pad or sign
      local line = front(lead)
      if not runs and not sign_hl then
        table.insert(line, { marker .. piece, band or hl })
      elseif not runs then
        table.insert(line, { marker, sign_hl })
        table.insert(line, { piece, band or hl })
      else
        local at = text:find(piece, cursor, true) or cursor
        cursor = at + #piece
        if marker ~= "" then
          table.insert(line, { marker, j == 1 and sign_hl or band or hl })
        end
        for _, run in ipairs(M.slice(runs, at, at + #piece)) do
          local colour = run[2] or hl
          table.insert(line, {
            run[1],
            band and { band, colour } or colour,
            ref = run.ref,
            style = run.style,
          })
        end
      end
      emit(line)
    end
  end

  --- A pipe table, drawn as a table.
  ---
  --- Markdown's own is a table only in the sense that the columns are
  --- named: the cells line up in the source when its author lined them
  --- up by hand and not otherwise. Ruled and padded, the columns line up
  --- because they are columns, which is the whole reason the author
  --- reached for a table instead of a list.
  ---
  --- Too wide for the room, the columns give up room from the widest
  --- first -- a table of ids and sentences is nearly all sentence -- and
  --- a cell that then does not fit is cut with an ellipsis. A ruled
  --- table cannot wrap: a rule that wraps is two rules.
  local function tabled(lead, block, hl)
    local grid, widths, columns = {}, {}, 0
    for r, cells in ipairs(block.rows) do
      grid[r] = {}
      for c, cell in ipairs(cells) do
        local text, runs = inline(cell)
        grid[r][c] = { text = text, runs = runs }
        widths[c] = math.max(widths[c] or 0, vim.fn.strdisplaywidth(text))
        columns = math.max(columns, c)
      end
    end
    if columns == 0 then
      return
    end
    for c = 1, columns do
      widths[c] = widths[c] or 0
    end

    -- Three columns per cell that are not the cell: a rule and the
    -- space on either side of the words, plus the rule that closes the
    -- last one.
    local room = code and (code - vim.fn.strdisplaywidth(lead))
    if room then
      local total = 1
      for c = 1, columns do
        total = total + widths[c] + 3
      end
      while total > room do
        local widest, at = 0, nil
        for c = 1, columns do
          if widths[c] > widest then
            widest, at = widths[c], c
          end
        end
        -- Nothing left to give: a window this narrow gets a table that
        -- runs past its edge, which is at least a table.
        if not at or widest <= 3 then
          break
        end
        widths[at], total = widths[at] - 1, total - 1
      end
    end

    local function rule(kind)
      local parts = { RULE[kind][1] }
      for c = 1, columns do
        table.insert(parts, ("─"):rep(widths[c] + 2))
        table.insert(parts, c < columns and RULE[kind][2] or RULE[kind][3])
      end
      local line = front(lead)
      table.insert(line, { table.concat(parts), groups.meta })
      return line
    end

    local first = row
    emit(rule("top"))
    for r, cells in ipairs(grid) do
      -- The source has a delimiter row under the head, so the second
      -- row of the table is the third line of it.
      row = first + (r == 1 and 0 or r)
      -- The head in a colour of its own: it is what the columns are
      -- called and not one of the values in them.
      local colour = r == 1 and groups.head or hl
      local line = front(lead)
      for c = 1, columns do
        local cell = cells[c] or { text = "" }
        local text, runs = cell.text, cell.runs
        if vim.fn.strdisplaywidth(text) > widths[c] then
          local kept = M.fit(text, math.max(widths[c] - 1, 0))
          runs = runs and M.slice(runs, 1, #kept + 1) or nil
          text = kept .. "…"
          if runs then
            table.insert(runs, { "…" })
          end
        end
        local slack = widths[c] - vim.fn.strdisplaywidth(text)
        local left = (block.align[c] == "right" and slack)
          or (block.align[c] == "center" and math.floor(slack / 2))
          or 0
        table.insert(line, { "│", groups.meta })
        table.insert(line, { (" "):rep(left + 1), colour })
        for _, run in ipairs(runs or { { text } }) do
          table.insert(line, { run[1], run[2] or colour, ref = run.ref, style = run.style })
        end
        table.insert(line, { (" "):rep(slack - left + 1), colour })
      end
      table.insert(line, { "│", groups.meta })
      emit(line)
      if r == 1 then
        emit(rule("head"))
      end
    end
    emit(rule("bottom"))
  end

  --- Whether `line` is blank: nothing on it past what stands in front
  --- of every line.
  local function blank(line, lead)
    local text = ""
    for _, chunk in ipairs(line) do
      text = text .. chunk[1]
    end
    return vim.trim(text) == vim.trim(lead)
  end

  --- A heading without its hashes. There is no bigger type in a
  --- terminal, so rank is told by what a page has besides size: a
  --- colour and a weight per level (`groups.heading`), and for the
  --- levels `opts.headings` styles, space above, a band under the words
  --- and a rule under the line -- which read from across the room,
  --- whatever the colourscheme makes of the colours.
  function heading(left, block, prose, runs)
    local level = math.min(block.level or 1, 6)
    local colour = groups.heading .. level
    local style = opts.headings and opts.headings[level] or {}
    local across = math.max((limit or 72) - vim.fn.strdisplaywidth(left), 3)

    -- Space above, made up to `above` from the blank lines the source
    -- already has -- and none at the top, where there is nothing to be
    -- apart from. Each one is the line before's, so that a heading is
    -- still found at its words.
    if style.above and #out > 0 then
      local have = 0
      while have < #out and blank(out[#out - have], left) do
        have = have + 1
      end
      for _ = have + 1, style.above do
        local line = front(left)
        line.row = out[#out].row
        table.insert(out, line)
      end
    end

    local band = style.band == true and groups.band or style.band or nil
    local before = #out
    if band then
      -- A space inside either end, as a label has, and the band carried
      -- on to the width of the page.
      body(left, prose, colour, { " ", band }, runs or { { prose } }, limit and limit - 1, band)
      for i = before + 1, #out do
        local line = out[i]
        local slack = across - (M.measure(line) - vim.fn.strdisplaywidth(left))
        if slack > 0 then
          table.insert(line, { (" "):rep(slack), band })
        end
      end
    else
      body(left, prose, colour, nil, runs)
    end
    if out[before + 1] then
      out[before + 1].heading = prose
    end
    if style.rule then
      local line = front(left)
      table.insert(line, { style.rule:rep(across), groups.ruler .. level })
      emit(line)
    end
  end

  local ctx = { body = body, front = front, emit = emit }

  local function draw(left, list, hl)
    for _, block in ipairs(list) do
      row = block.row
      ctx.code, ctx.width = code, limit
      local custom = opts.custom and opts.custom(block, ctx, left, hl)
      if custom then
        row = block.row
      elseif block.kind == "code" then
        -- Somebody else's fence, drawn as they typed it -- the fence
        -- lines included, because they are the only thing saying where
        -- their code starts and stops. Nothing rendered inside it: code
        -- that says `:tada:` says `:tada:`, and code that says `[a](b)`
        -- says `[a](b)`. In the colours of its language where there is
        -- a painter for it.
        local first = row
        body(left, block.fence, groups.meta, nil, nil, code)
        local colours = opts.paint and block.lang and opts.paint(block.lines, block.lang) or {}
        for k, l in ipairs(block.lines) do
          row = first + k
          body(left, l, hl, nil, colours[k], code)
        end
        if block.close then
          row = first + #block.lines + 1
          body(left, block.close, groups.meta, nil, nil, code)
        end
      elseif block.kind == "definition" then
        -- Where a name goes, said for the links that use it: nothing to
        -- read on its own.
        row = block.row
      elseif block.kind == "table" then
        -- Under an item, hanging where the item's words do.
        local under = block.of and ("  "):rep(block.depth or 0) .. (" "):rep(block.of.width or 2)
          or ""
        tabled(left .. under, block, hl)
      elseif block.kind == "math" then
        -- A displayed formula on lines of its own, one per row of it,
        -- set in from the prose as a page centres one. Measured like
        -- code: a formula broken at a space is not the formula.
        local tex = require("render.tex")
        for _, l in ipairs(tex.lines(table.concat(block.lines, " "))) do
          body(left, l, groups.math, "  ", nil, code)
        end
      elseif block.kind == "rule" then
        local across = (limit or 72) - vim.fn.strdisplaywidth(left)
        local line = front(left)
        table.insert(line, { ("─"):rep(math.max(across, 3)), groups.rule })
        emit(line)
      elseif block.kind == "item" then
        -- A list item, as a page draws one: a bullet for the level it is
        -- at, or its number, then its box if it is a task -- and every
        -- line it wraps to, and every line that carries it on, hanging
        -- under the words rather than under the bullet.
        local prose, runs = inline(block.text)
        local inset = ("  "):rep(block.depth)
        local sign
        if block.of then
          sign = inset .. (" "):rep(block.of.width or 2)
        else
          local glyph = block.marker
          if glyph == "-" then
            glyph = glyphs.bullets[block.depth % #glyphs.bullets + 1]
          end
          glyph = glyph .. " "
          -- A task is its box and not a bullet as well, as on a page:
          -- the box already says "this is an item".
          local tick = ""
          if block.task ~= nil then
            tick = (block.task and glyphs.tasks[2] or glyphs.tasks[1]) .. " "
            if block.marker == "-" then
              glyph = ""
            end
          end
          block.width = vim.fn.strdisplaywidth(glyph .. tick)
          sign = {
            inset .. glyph .. tick,
            block.task and groups.ok or block.task == false and groups.meta or hl,
          }
        end
        body(left, prose, hl, sign, runs)
      elseif block.kind == "citation" then
        -- What somebody quoted, behind a bar and in the quiet colour:
        -- the one part of a text that is somebody else speaking. The
        -- bar goes on the left, so that a wrapped line keeps it and a
        -- table inside the citation is measured against what is left.
        cited = cited + 1
        draw(left .. bar, block.blocks, groups.citation)
        cited = cited - 1
      else
        local prose, runs = inline(block.text)
        if block.kind == "heading" then
          heading(left, block, prose, runs)
        else
          body(left, prose, hl, nil, runs)
        end
      end
    end
  end

  draw(opts.lead or "", blocks, opts.hl)
  return out
end

--- The same lines as plain strings, plus the highlights to paint over
--- them -- for a real buffer rather than virtual text. Rows are 0-based
--- and offset by `first_row`; columns are byte offsets, which is what
--- extmarks want.
---
--- ...and third, where each of the things the text points at ended up:
--- `{ row, col, end_col, ref }`, which is what a key that follows a
--- link looks the cursor up in.
function M.flatten(rendered, first_row)
  first_row = first_row or 0
  local lines, hls, refs = {}, {}, {}
  for i, chunks in ipairs(rendered) do
    local text = ""
    for _, chunk in ipairs(chunks) do
      if chunk.ref then
        table.insert(refs, {
          row = first_row + i - 1,
          col = #text,
          end_col = #text + #chunk[1],
          ref = chunk.ref,
        })
      end
      if chunk[2] or chunk.style then
        -- A chunk asking for a band behind a colour comes out as two
        -- highlights over the same bytes, the band first: extmarks are
        -- composed rather than replaced, so what is drawn is the band's
        -- background with the colour's foreground on it.
        local function over(group)
          table.insert(hls, {
            row = first_row + i - 1,
            col = #text,
            end_col = #text + #chunk[1],
            hl = group,
          })
        end
        for _, group in ipairs(type(chunk[2]) == "table" and chunk[2] or { chunk[2] }) do
          over(group)
        end
        -- ...and the weight last of all: a group that says a word is
        -- bold says nothing about what colour it is, and going on top
        -- of the colour is what leaves the colour alone.
        for _, group in ipairs(chunk.style or {}) do
          over(group)
        end
      end
      text = text .. chunk[1]
    end
    table.insert(lines, text)
  end
  return lines, hls, refs
end

return M
