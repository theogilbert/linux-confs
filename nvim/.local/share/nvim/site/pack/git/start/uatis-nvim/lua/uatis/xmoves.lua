-- A definition that moved from one file to another.
--
-- `moves.lua` reads a move inside one file, from the one comparison a
-- view has. A function taken out of `a.lua` and put into `b.lua` is in
-- two comparisons, two views, and neither can see the other: `a.lua`
-- draws it removed whole, `b.lua` draws it added whole, and what changed
-- in it on the way is left for the reader to find by holding one file in
-- their head while reading the other.
--
-- So the review is asked, once, after the list has read git's diff: the
-- list already holds every file's chunks, which say which rows each side
-- removed and added. Each file with enough of either is parsed -- its
-- old text at the review's revision, its new text off the disk, since
-- git's rows are the disk's -- and the definitions lying wholly inside
-- those rows are paired across files by the rules a move inside one file
-- is paired by: same kind, and the same name or enough alike.
--
-- A definition that only moved inside its own file is paired here too,
-- and then dropped: it is the view's to draw, and pairing it keeps it
-- from being claimed by a lookalike in another file.
--
-- The index is in git's rows, the disk's. A view draws from the buffer,
-- which may be ahead of the disk, so it finds its end of each move again
-- in what it is drawing (`apply`), by name or by content, rather than
-- trusting a row number the reader may have typed past.
--
-- In a branch review the new side is the disk. With a commit on show --
-- stepping a branch, `:UatisShow`, a history -- it is that commit, and
-- both sides are read out of git: the commit's text and its parent's.
-- An index is the answer for one revision and one commit, and is never
-- handed to a view measuring anything else (`key`): stepping `]C` re-reads
-- the list, and the commit just left must not draw on the one arrived at.

local config = require("uatis.config")
local moves = require("uatis.moves")

local M = {}

--- Definitions found in a text, by the text and the rows asked about.
--- Never evicted, like git's blobs: what a text holds does not change.
local found = {}

local function cands(text, lang, rows)
  local keys = vim.tbl_keys(rows)
  table.sort(keys)
  local k = lang .. "\0" .. vim.fn.sha256(text) .. "\0" .. table.concat(keys, ",")
  if not found[k] then
    local lines = vim.split(text, "\n", { plain = true })
    local out = moves.candidates(text, lines, lang, rows)
    for _, c in ipairs(out) do
      c.lines = vim.list_slice(lines, c.first, c.last)
    end
    found[k] = out
  end
  return found[k]
end

local function lang_for(path)
  return require("uatis.syntax").lang_of(vim.filetype.match({ filename = path }))
end

--- The new row where old row `r` of `f` would hang: the top of the git
--- chunk that removed it, or below the row a pure removal follows.
local function at_of(f, r)
  for _, h in ipairs(f.hunks or {}) do
    if h.old_count > 0 and r >= h.old_start and r < h.old_start + h.old_count then
      return h.new_count == 0 and h.new_start + 1 or h.new_start
    end
  end
  return 1
end

--- Whether files in `lang` are looked at between files. Prose and data
--- have trees too, and a section of one README that reads like a section
--- of another is not a function that moved; the language is what says
--- which a file is.
local function counted(lang)
  local opts = config.diff.move
  if opts.across_only then
    return vim.tbl_contains(opts.across_only, lang)
  end
  return not vim.tbl_contains(opts.across_skip or {}, lang)
end

--- Which reviews this is asked of: every one with a revision to measure
--- against. A conflict review has none.
local function eligible(pane)
  local opts = config.diff.move
  return opts.enabled and opts.across and not pane.conflicts
end

--- What an index is the answer for.
local function key(pane)
  return (pane.rev or "") .. ":" .. (pane.commit and pane.commit.sha or "")
end

--- A key for an index, so a re-read that found the same moves redraws
--- nothing.
local function signature(list)
  local parts = {}
  for _, e in ipairs(list) do
    table.insert(parts, table.concat({ e.from.path, e.from.first, e.from.last,
      e.to.path, e.to.first, e.to.last }, ":"))
  end
  return table.concat(parts, "|")
end

--- Builds `pane.moves_across` from the list's files, then redraws the
--- views on files whose moves changed. Asynchronous; a newer build
--- supersedes an older one still out.
function M.build(pane)
  pane.across_gen = (pane.across_gen or 0) + 1
  local gen = pane.across_gen
  if not eligible(pane) then
    pane.moves_across = nil
    return
  end
  -- Another revision or another commit: what was known is not about it.
  if pane.across_key ~= key(pane) then
    pane.moves_across, pane.across_sig, pane.across_key = nil, nil, key(pane)
  end
  local opts = config.diff.move
  local min = opts.min_lines

  -- The files with enough removed or added to hold a definition.
  local files = {}
  for _, f in ipairs(pane.files or {}) do
    if not f.binary then
      local gone, came, ng, nc = {}, {}, 0, 0
      if f.untracked then
        nc = f.added or 0
      else
        for _, h in ipairs(f.hunks or {}) do
          for r = h.old_start, h.old_start + h.old_count - 1 do
            gone[r], ng = true, ng + 1
          end
          for r = h.new_start, h.new_start + h.new_count - 1 do
            came[r], nc = true, nc + 1
          end
        end
      end
      local lang = (ng >= min or nc >= min) and lang_for(f.path)
      if lang and counted(lang) then
        table.insert(files, { f = f, gone = gone, came = came, ng = ng, nc = nc, lang = lang })
      end
    end
  end
  -- Past the cap, the files that changed most are the ones kept: a
  -- function is a run of lines, and a file that moved three of them
  -- holds no definition worth pairing.
  table.sort(files, function(a, b)
    return a.ng + a.nc > b.ng + b.nc
  end)
  for i = #files, opts.across_files + 1, -1 do
    files[i] = nil
  end

  local pending = 1
  local function settle()
    pending = pending - 1
    if pending > 0 or pane.across_gen ~= gen or pane.across_key ~= key(pane) then
      return
    end
    local list = M.pair(files)
    local sig = signature(list)
    if sig == pane.across_sig then
      return
    end
    local before = pane.moves_across or {}
    pane.moves_across, pane.across_sig = list, sig
    -- Redrawn: every view on a file either index names.
    local touched = {}
    for _, e in ipairs(vim.list_extend(vim.list_extend({}, before), list)) do
      touched[e.from.file] = true
      touched[e.to.path] = true
    end
    local view_mod = require("uatis.view")
    for _, v in ipairs(view_mod.matching(pane.root, pane.rev, pane.standalone)) do
      if touched[v.relpath] then
        view_mod.redraw(v)
      end
    end
  end

  local commit = pane.commit
  for _, x in ipairs(files) do
    local f = x.f
    if x.nc >= min and f.status ~= "D" and commit then
      pending = pending + 1
      require("uatis.git").blob(pane.root, commit.sha, f.path, function(text)
        x.new_text = text
        settle()
      end)
    elseif x.nc >= min and f.status ~= "D" then
      local ok, lines = pcall(vim.fn.readfile, pane.root .. "/" .. f.path)
      if ok and type(lines) == "table" then
        x.new_text = table.concat(lines, "\n")
        if f.untracked then
          for r = 1, #lines do
            x.came[r] = true
          end
        end
      end
    end
    if x.ng >= min and f.status ~= "A" then
      pending = pending + 1
      require("uatis.git").blob(pane.root, pane.rev, f.old_path or f.path, function(text)
        x.old_text = text
        settle()
      end)
    end
  end
  settle()
end

--- The cross-file moves among `files` (as `build` gathers them, texts
--- read): `{ name, from = { path, file, first, last, at, lines },
--- to = { path, first, last, lines } }`. `from.path` is the name the file had
--- at the revision, `from.file` the name it has now -- a renamed file is
--- opened by the second and read at the revision by the first.
function M.pair(files)
  local opts = config.diff.move
  local olds, news = {}, {}
  for i, x in ipairs(files) do
    if x.old_text then
      for _, c in ipairs(cands(x.old_text, x.lang, x.gone)) do
        table.insert(olds, { fi = i, c = c })
      end
    end
    if x.new_text then
      for _, c in ipairs(cands(x.new_text, x.lang, x.came)) do
        table.insert(news, { fi = i, c = c })
      end
    end
  end
  if #olds == 0 or #news == 0 then
    return {}
  end

  local scored, budget = {}, opts.across_pairs
  for i, o in ipairs(olds) do
    for j, n in ipairs(news) do
      local a, b = o.c, n.c
      local named = a.name ~= nil and a.name == b.name
      -- Lines are compared only where they could pass: a name in common,
      -- or two blocks of a size. A review that split one module into
      -- six would otherwise compare every pair of its functions.
      local sized = math.max(#a.lines, #b.lines) <= 2 * math.min(#a.lines, #b.lines)
      if a.kind == b.kind and (named or sized) and budget > 0 then
        budget = budget - 1
        local sim = moves.likeness(a.lines, b.lines)
        if (named and sim >= opts.named_similarity) or sim >= opts.similarity then
          table.insert(scored, { i = i, j = j, score = (named and 1 or 0) + sim })
        end
      end
    end
  end
  table.sort(scored, function(x, y) return x.score > y.score end)

  local out, taken_i, taken_j = {}, {}, {}
  for _, s in ipairs(scored) do
    if not taken_i[s.i] and not taken_j[s.j] then
      taken_i[s.i], taken_j[s.j] = true, true
      local o, n = olds[s.i], news[s.j]
      if o.fi ~= n.fi then
        local fo, fn = files[o.fi].f, files[n.fi].f
        table.insert(out, {
          name = n.c.name or o.c.name,
          kind = n.c.kind,
          from = { path = fo.old_path or fo.path, file = fo.path, first = o.c.first,
            last = o.c.last, at = at_of(fo, o.c.first), lines = o.c.lines },
          to = { path = fn.path, first = n.c.first, last = n.c.last, lines = n.c.lines },
        })
      end
    end
  end
  table.sort(out, function(x, y)
    return x.to.path < y.to.path or (x.to.path == y.to.path and x.to.first < y.to.first)
  end)
  return out
end

--- The index of the review `view` belongs to, or nil.
local function index_for(view)
  for _, p in ipairs(require("uatis.pane").all()) do
    if p.root == view.root and p.rev == view.rev and p.moves_across
      and (p.standalone == true) == (view.standalone == true)
      and p.across_key == key(p) then
      return p.moves_across
    end
  end
  return nil
end

--- `result` with the moves into and out of this view's file drawn,
--- handed to `cb` -- or `result` itself where there are none. A copy:
--- the result is cached and shared, and these moves are this review's.
---
--- A move IN is drawn the way a move inside the file is, as an edit of
--- the definition's old self, which comes from the other file: its old
--- lines are appended past the end of this file's own (`old_lines` on
--- the drawn answer), so the hunks spliced in can point at them. A move
--- OUT is the old copy taken out and one line where it was.
function M.apply(view, result, old_text, new_text, cb)
  local index = index_for(view)
  if not index or #index == 0 or not result.hunks then
    return cb(result)
  end
  local old_path = view.old_path or view.relpath
  local ins, outs = {}, {}
  for _, e in ipairs(index) do
    if e.to.path == view.relpath then
      table.insert(ins, e)
    end
    if e.from.path == old_path and e.from.file == view.relpath then
      table.insert(outs, e)
    end
  end
  if #ins == 0 and #outs == 0 then
    return cb(result)
  end

  local lang = lang_for(view.relpath)
  if not lang then
    return cb(result)
  end
  local base = result.drawn or result
  local old_lines = vim.split(old_text, "\n", { plain = true })
  local new_lines = vim.split(new_text, "\n", { plain = true })
  local gone, came = {}, {}
  for _, h in ipairs(result.hunks) do
    for r = h.start_a, h.start_a + h.count_a - 1 do gone[r] = true end
    for r = h.start_b, h.start_b + h.count_b - 1 do came[r] = true end
  end
  -- Rows a move inside the file already answers for.
  for _, mv in ipairs(base.moves or {}) do
    if mv.old then
      for r = mv.old.first, mv.old.last do gone[r] = nil end
    end
    if mv.new then
      for r = mv.new.first, mv.new.last do came[r] = nil end
    end
  end

  local found_moves, inner_of, counted_of = {}, {}, {}

  -- Out: the old copy is at the revision, which is the index's own, so
  -- its rows hold -- provided this render removed them too.
  for _, e in ipairs(outs) do
    local whole = true
    for r = e.from.first, e.from.last do
      if not gone[r] and not moves.blank(old_lines[r]) then
        whole = false
        break
      end
    end
    if whole then
      for r = e.from.first, e.from.last do gone[r] = nil end
      local mv = {
        kind = "out", name = e.name,
        old = { first = e.from.first, last = e.from.last },
        at = moves.hangs_at(result, e.from.first),
        to = { path = e.to.path, first = e.to.first },
      }
      table.insert(found_moves, mv)
      -- How much it changed on the way, which is the comparison the
      -- other file's view draws: made here too, against the copy as the
      -- review read it, for the count and nothing else.
      counted_of[mv] = {
        old = table.concat(vim.list_slice(old_lines, e.from.first, e.from.last), "\n"),
        new = table.concat(e.to.lines or {}, "\n"),
      }
    end
  end

  -- In: found again in the buffer, which may be ahead of the disk.
  local news = #ins > 0 and moves.candidates(new_text, new_lines, lang, came) or {}
  local taken = {}
  local extra = {}
  for _, e in ipairs(ins) do
    local best, best_score
    for j, n in ipairs(news) do
      if not taken[j] and n.kind == e.kind then
        local named = e.name ~= nil and n.name == e.name
        local sim = moves.likeness(e.from.lines, vim.list_slice(new_lines, n.first, n.last))
        local opts = config.diff.move
        if (named and sim >= opts.named_similarity) or sim >= opts.similarity then
          local score = (named and 1 or 0) + sim
          if not best_score or score > best_score then
            best, best_score = j, score
          end
        end
      end
    end
    if best then
      taken[best] = true
      local n = news[best]
      local first = #old_lines + #extra + 1
      vim.list_extend(extra, e.from.lines)
      local mv = {
        kind = "in", name = e.name,
        old = { first = first, last = first + #e.from.lines - 1 },
        new = { first = n.first, last = n.last },
        from = { path = e.from.path, file = e.from.file, first = e.from.first, at = e.from.at },
      }
      table.insert(found_moves, mv)
      inner_of[mv] = {
        old = table.concat(e.from.lines, "\n"),
        new = table.concat(vim.list_slice(new_lines, n.first, n.last), "\n"),
      }
    end
  end
  if #found_moves == 0 then
    return cb(result)
  end

  local all_old = old_text
  if #extra > 0 then
    all_old = old_text .. "\n" .. table.concat(extra, "\n")
  end
  local inners, counts, pending = {}, {}, 1
  local function done()
    pending = pending - 1
    if pending > 0 then
      return
    end
    for mv, n in pairs(counts) do
      mv.changes = n
    end
    local drawn = moves.rewrite(base, found_moves, inners, all_old, new_text)
    drawn.old_lines = vim.split(all_old, "\n", { plain = true })
    cb(vim.tbl_extend("force", result, { drawn = drawn }))
  end
  for _, mv in ipairs(found_moves) do
    local texts = counted_of[mv]
    if texts then
      pending = pending + 1
      require("uatis.diff").compute(texts.old, texts.new,
        { backend = view.backend, path = view.relpath }, function(inner)
          counts[mv] = #(inner.hunks or {})
          done()
        end)
    end
  end
  for k, mv in ipairs(found_moves) do
    local texts = inner_of[mv]
    if texts then
      pending = pending + 1
      require("uatis.diff").compute(texts.old, texts.new,
        { backend = view.backend, path = view.relpath }, function(inner)
          inners[k] = inner
          done()
        end)
    end
  end
  done()
end

return M
