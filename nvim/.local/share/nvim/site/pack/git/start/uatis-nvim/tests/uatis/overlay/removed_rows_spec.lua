-- How a before-image row itself is drawn: what in it is marked lost, the
-- syntax colours it keeps, and the width it fills.
local h = require("helpers")
local overlay = require("uatis.overlay")

local function drawn(old, new, expected)
  h.drawn({ lang = "python", old = old, new = new }, expected)
end

describe("a lost space", function()
  if not h.difft then
    pending("difftastic is not installed")
    return
  end

  -- Whitespace is not a token to the survival test -- right for moves,
  -- where whitespace changing IS the move. But a comment with the space
  -- taken off its end is a change difftastic reports, and nothing
  -- arrived on the row to be lit: a dim band with no before-image.
  it("is drawn gone from a comment that lost its trailing space", function()
    drawn("def f():\n    x = 1  # note \n    return x\n",
      "def f():\n    x = 1  # note\n    return x\n", [[
        | def f():
        - ⟨    x = 1  # note⟩␣
        |     x = 1  ⟨# note⟩
        |     return x
      ]])
  end)

  it("is picked out of a docstring that lost a doubled space, on that row alone", function()
    drawn('def f():\n    """Do  it.\n\n    More.\n    """\n    return 1\n',
      'def f():\n    """Do it.\n\n    More.\n    """\n    return 1\n', [[
        | def f():
        - ⟨    """Do ⟩ ⟨it.⟩
        ~     """Do it.
        |
        |     More.
        |     """
        |     return 1
      ]])
  end)

  -- The space that arrived is on the row, marked, with the old row under it.
  it("leaves a comment that GAINED a space a pure insertion", function()
    drawn("def f():\n    x = 1  # note\n    return x\n",
      "def f():\n    x = 1  # note \n    return x\n", [[
        | def f():
        |     x = 1  ⟨# note⟩⟦ ⟧
        |     return x
      ]])
  end)

  it("is not what a reindent is: a wrapped block shows no before-image", function()
    drawn("def f(x):\n    a = 1  # one\n    b = 2  # two\n",
      "def f(x):\n    if x:\n        a = 1  # one\n        b = 2  # two\n", [[
        | def f(x):
        +     if x:
        |     ⟦    ⟧a = 1  # one
        |     ⟦    ⟧b = 2  # two
      ]])
  end)

  -- One atom, so difftastic made all its rows a single hunk for three
  -- trailing spaces: too long to compare row for row, every word still
  -- there, so it read as a reflow -- rows dim with nothing to say why.
  it("is drawn on each row of a long docstring cleared of trailing spaces", function()
    drawn({
      "class WorkerClass(Setting):",
      '    name = "worker_class"',
      '    section = "Worker Processes"',
      '    cli = ["-k", "--worker-class"]',
      '    meta = "STRING"',
      "    validator = validate_class",
      '    default = "sync"',
      '    desc = """\\',
      "        The type of workers to use.",
      "",
      '        The default class (``sync``) should handle most "normal" types of',
      "        workloads. You'll want to read :doc:`design` for information on when",
      "        you might want to choose one of the other worker classes. Required",
      "        libraries may be installed using setuptools' ``extra_require`` feature.",
      "",
      "        A string referring to one of the following bundled classes:",
      "",
      "        * ``sync``",
      "        * ``eventlet`` - Requires eventlet >= 0.9.7 (or install it via ",
      "          ``pip install gunicorn[eventlet]``)",
      "        * ``gevent``   - Requires gevent >= 0.13 (or install it via ",
      "          ``pip install gunicorn[gevent]``)",
      "        * ``tornado``  - Requires tornado >= 0.2 (or install it via ",
      "          ``pip install gunicorn[tornado]``)",
      "        * ``gthread``  - Python 2 requires the futures package to be installed",
      "          (or install it via ``pip install gunicorn[gthread]``)",
      "        * ``gaiohttp`` - Deprecated.",
      "",
      "        Optionally, you can provide your own worker by giving Gunicorn a",
      "        Python path to a subclass of ``gunicorn.workers.base.Worker``.",
      "        This alternative syntax will load the gevent class:",
      "        ``gunicorn.workers.ggevent.GeventWorker``.",
      "",
      "        .. deprecated:: 19.8",
      "           The ``gaiohttp`` worker is deprecated. Please use",
      "           ``aiohttp.worker.GunicornWebWorker`` instead. See",
      "           :ref:`asyncio-workers` for more information on how to use it.",
      '        """',
    }, [[
      class WorkerClass(Setting):
          name = "worker_class"
          section = "Worker Processes"
          cli = ["-k", "--worker-class"]
          meta = "STRING"
          validator = validate_class
          default = "sync"
          desc = """\
              The type of workers to use.

              The default class (``sync``) should handle most "normal" types of
              workloads. You'll want to read :doc:`design` for information on when
              you might want to choose one of the other worker classes. Required
              libraries may be installed using setuptools' ``extra_require`` feature.

              A string referring to one of the following bundled classes:

              * ``sync``
              * ``eventlet`` - Requires eventlet >= 0.9.7 (or install it via
                ``pip install gunicorn[eventlet]``)
              * ``gevent``   - Requires gevent >= 0.13 (or install it via
                ``pip install gunicorn[gevent]``)
              * ``tornado``  - Requires tornado >= 0.2 (or install it via
                ``pip install gunicorn[tornado]``)
              * ``gthread``  - Python 2 requires the futures package to be installed
                (or install it via ``pip install gunicorn[gthread]``)
              * ``gaiohttp`` - Deprecated.

              Optionally, you can provide your own worker by giving Gunicorn a
              Python path to a subclass of ``gunicorn.workers.base.Worker``.
              This alternative syntax will load the gevent class:
              ``gunicorn.workers.ggevent.GeventWorker``.

              .. deprecated:: 19.8
                 The ``gaiohttp`` worker is deprecated. Please use
                 ``aiohttp.worker.GunicornWebWorker`` instead. See
                 :ref:`asyncio-workers` for more information on how to use it.
              """
    ]], [[
      | class WorkerClass(Setting):
      |     name = "worker_class"
      |     section = "Worker Processes"
      |     cli = ["-k", "--worker-class"]
      |     meta = "STRING"
      |     validator = validate_class
      |     default = "sync"
      |     desc = """\
      |         The type of workers to use.
      |
      |         The default class (``sync``) should handle most "normal" types of
      |         workloads. You'll want to read :doc:`design` for information on when
      |         you might want to choose one of the other worker classes. Required
      |         libraries may be installed using setuptools' ``extra_require`` feature.
      |
      |         A string referring to one of the following bundled classes:
      |
      |         * ``sync``
      - ⟨        * ``eventlet`` - Requires eventlet >= 0.9.7 (or install it via⟩␣
      ~         * ``eventlet`` - Requires eventlet >= 0.9.7 (or install it via
      |           ``pip install gunicorn[eventlet]``)
      - ⟨        * ``gevent``   - Requires gevent >= 0.13 (or install it via⟩␣
      ~         * ``gevent``   - Requires gevent >= 0.13 (or install it via
      |           ``pip install gunicorn[gevent]``)
      - ⟨        * ``tornado``  - Requires tornado >= 0.2 (or install it via⟩␣
      ~         * ``tornado``  - Requires tornado >= 0.2 (or install it via
      |           ``pip install gunicorn[tornado]``)
      |         * ``gthread``  - Python 2 requires the futures package to be installed
      |           (or install it via ``pip install gunicorn[gthread]``)
      |         * ``gaiohttp`` - Deprecated.
      |
      |         Optionally, you can provide your own worker by giving Gunicorn a
      |         Python path to a subclass of ``gunicorn.workers.base.Worker``.
      |         This alternative syntax will load the gevent class:
      |         ``gunicorn.workers.ggevent.GeventWorker``.
      |
      |         .. deprecated:: 19.8
      |            The ``gaiohttp`` worker is deprecated. Please use
      |            ``aiohttp.worker.GunicornWebWorker`` instead. See
      |            :ref:`asyncio-workers` for more information on how to use it.
      |         """
    ]])
  end)
end)

describe("a removed line's colours", function()
  local old = "local M = {}\nfunction M.run(a)\n  return a + 1\nend"
  local new = "local M = {}\nfunction M.run(a)\nend"

  --- Every chunk of every before-image, `hl` as the extmark carries it.
  local function chunks(o)
    local _, _, buf = h.draw(vim.tbl_extend("keep", o, { keep = true, backend = "line" }))
    local out = {}
    for _, m in ipairs(h.marks(buf)) do
      for _, vl in ipairs(m[4].virt_lines or {}) do
        for _, c in ipairs(vl) do
          table.insert(out, { text = c[1], hl = c[2] })
        end
      end
    end
    vim.api.nvim_buf_delete(buf, { force = true })
    return out
  end

  local function top(hl)
    return type(hl) == "table" and hl[#hl] or hl
  end

  -- Nothing highlights virtual text, so the old side is parsed on its
  -- own and the capture groups put on the chunks by hand.
  it("keeps the group the real highlighter would have used, under the band", function()
    if not pcall(vim.treesitter.language.add, "lua") then
      return pending("no lua parser")
    end
    local got = chunks({ old = old, new = new })
    local keyword
    for _, c in ipairs(got) do
      if c.text == "return" then
        keyword = c.hl
      end
    end
    assert.is_true(h.contains(keyword, "@keyword.return.lua"))
    assert.are.equal("UatisDeleteBg", top(keyword))
    -- On EVERY chunk: a gap between two captures would stripe the line.
    local text = ""
    for _, c in ipairs(got) do
      if top(c.hl) ~= "UatisSign" then
        assert.are.equal("UatisDeleteBg", top(c.hl))
        text = text .. c.text
      end
    end
    assert.are.equal("  return a + 1", text)
  end)

  it("falls back to one flat removal colour with no parser", function()
    local flat = {}
    for _, c in ipairs(chunks({ old = old, new = new, lang = "" })) do
      if c.hl ~= "UatisSign" then
        table.insert(flat, c.hl .. "=" .. c.text)
      end
    end
    assert.are.same({ "UatisDelete=  return a + 1" }, flat)
  end)

  -- Both bands are backgrounds for the reason the bands over real code
  -- are: a foreground replaces the syntax colouring. The dim half was
  -- once `Comment`'s grey, which flattened everything the edit missed.
  it("keeps syntax under both halves of a row with its removals picked out", function()
    if not h.difft or not pcall(vim.treesitter.language.add, "python") then
      return pending("needs difftastic and a python parser")
    end
    local band, coloured = {}, {}
    for _, c in ipairs(chunks({ backend = "struct", lang = "python",
      old = "class D:\n    def go(self, sql, binds):\n        cur = self._conn.execute(sql, binds)\n        return cur",
      new = "class D:\n    def go(self, sql, binds):\n        cur = self._sql(sql, binds, private=True)\n        return cur",
    })) do
      if c.hl ~= "UatisSign" then
        local groups = type(c.hl) == "table" and c.hl or { c.hl }
        band[c.text] = groups[#groups]
        coloured[c.text] = #groups > 1 and groups[1] or nil
      end
    end
    assert.are.same({ "UatisDeleteBg", "UatisDeleteBg", "UatisDeleteDim", "UatisDeleteDim" },
      { band._conn, band.execute, band.cur, band.sql })
    assert.is_truthy(coloured._conn and coloured.cur)
  end)

  -- Asserted against a `DiffDelete` that HAS a background: the default
  -- scheme's is foreground-only, where the definition under test never
  -- appears.
  it("tints the background and leaves the colours alone", function()
    local was = vim.api.nvim_get_hl(0, { name = "DiffDelete", link = false })
    vim.api.nvim_set_hl(0, "DiffDelete", { bg = 0x4a1f1f, fg = 0xffffff })
    overlay.setup_highlights()
    for _, group in ipairs({ "UatisDeleteDim", "UatisDeleteBg" }) do
      local hl = vim.api.nvim_get_hl(0, { name = group, link = false })
      assert.is_true(hl.bg ~= nil and hl.fg == nil, group)
    end
    vim.api.nvim_set_hl(0, "DiffDelete", was)
    overlay.setup_highlights()
  end)
end)

describe("a removed line's width", function()
  -- `line_hl_group` paints a real line to the window's edge; a virtual
  -- line stops at its last character, a ragged edge tracing the old code.
  -- So it is padded out, in whichever colour its own end is in: running
  -- the REMOVAL colour to the edge of a line that mostly survived would
  -- claim the rest of it went too.
  local WIDTH = 60

  --- Each before-image row as { text, last = raw last chunk, width }.
  local function rows(o)
    local buf = h.scratch(o.new, o.lang or "lua")
    local win = vim.api.nvim_open_win(buf, false, {
      relative = "editor", row = 0, col = 0, width = WIDTH, height = 10, style = "minimal",
    })
    local r = h.compute(vim.tbl_extend("keep", o, { backend = "line", bufnr = buf }))
    overlay.render(buf, win, r, h.source(o.old))
    local out = {}
    for _, m in ipairs(h.marks(buf)) do
      for _, vl in ipairs(m[4].virt_lines or {}) do
        local text, width = "", 0
        for _, c in ipairs(h.chunks_of(vl)) do
          text = text .. c[1]
          width = width + vim.fn.strdisplaywidth(c[1], width)
        end
        -- The raw last chunk: merged, the fill would hide in the code it pads.
        table.insert(out, { text = text, last = vl[#vl], width = width })
      end
    end
    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(buf, { force = true })
    return out
  end

  it("is the window's, filled blank in the removal colour", function()
    local gone = rows({ old = "local M = {}\nfunction M.run(a)\n  return a + 1\nend",
      new = "local M = {}\nfunction M.run(a)\nend" })
    assert.are.equal(1, #gone)
    assert.are.equal(WIDTH, gone[1].width)
    assert.is_truthy(gone[1].last[1]:match("^ +$"))
    assert.are.equal("UatisDeleteBg", gone[1].last[2])
    assert.is_truthy(gone[1].text:find("  return a + 1", 1, true))
  end)

  -- The row where a band that stops at the text is invisible.
  it("is the window's for a removed blank line too", function()
    local blank = rows({ old = "local a = 1\n\nlocal b = 2", new = "local a = 1\nlocal b = 2" })
    assert.are.equal(1, #blank)
    assert.are.equal(WIDTH, blank[1].width)
  end)

  it("is filled in the dim band where the removals were picked out", function()
    if not h.difft or not pcall(vim.treesitter.language.add, "python") then
      return pending("needs difftastic and a python parser")
    end
    local picked = rows({ backend = "struct", lang = "python",
      old = "class D:\n    def go(self, sql, binds):\n        cur = self._conn.execute(sql, binds)\n        return cur",
      new = "class D:\n    def go(self, sql, binds):\n        cur = self._sql(sql, binds, private=True)\n        return cur",
    })
    assert.are.equal(1, #picked)
    assert.are.equal(WIDTH, picked[1].width)
    local last = picked[1].last[2]
    assert.are.equal("UatisDeleteDim", type(last) == "table" and last[#last] or last)
  end)
end)

-- The gap between two removed words is not the buffer showing through
-- but the other half of the comparison: a removed `total +=` came back
-- with the space between its halves stepped back as though it survived
-- (`joined`).
describe("a space between two words that went", function()
  it("went with them, the space before what stayed stepped back", function()
    if not h.difft then
      return pending("difftastic is not installed")
    end
    drawn({
      "def layout(self, boxes):",
      "    total = 0",
      "    for box in boxes:",
      "        total += self.measure(box)",
      "    return total",
      "",
    }, {
      "def layout(self, boxes):",
      "    return sum(self.measure(box) for box in boxes)",
      "",
    }, [[
      | def layout(self, boxes):
      -     total = 0
      -     for box in boxes:
      - ⟨        ⟩total +=⟨ self.measure(box)⟩
      -     return total
      |     ⟦return sum(⟧self.measure(box) ⟦for box in boxes)⟧
      |
    ]])
  end)
end)

-- One row above the row it became is a comparison the reader can check;
-- a whole passage drawn that way is stripes, and the old block cannot be
-- read back as code. Past `diff.line.spread_max` removed rows they go in
-- one block above the hunk.
describe("a passage of removed rows", function()
  local function draw(n)
    local old, new = { "def check(user, registry, audit):" }, { "def check(user, registry, audit):" }
    for i = 1, n do
      table.insert(old, ("    v%d = registry.lookup_by_identifier(user.identifier, audit.window)"):format(i))
      table.insert(new, ("    v%d = registry.resolve_from_registry_cache(user.canonical_id, trail.window)"):format(i))
    end
    table.insert(old, "    return v1")
    table.insert(new, "    return v1")
    local anchor = {}
    for i = 1, #old do
      anchor[i] = i
    end
    return h.draw({ lang = "", old = old, new = new, result = {
      hunks = { { start_a = 2, count_a = n, start_b = 2, count_b = n } },
      anchor = anchor, pairs = anchor,
    } })
  end

  it("of three is spread, each above the row it became", function()
    h.expect(draw(3), [[
      | def check(user, registry, audit):
      - ⟨    v1 = registry.⟩lookup_by_identifier⟨(user.⟩identifier, audit⟨.window)⟩
      ~     v1 = registry.resolve_from_registry_cache(user.canonical_id, trail.window)
      - ⟨    v2 = registry.⟩lookup_by_identifier⟨(user.⟩identifier, audit⟨.window)⟩
      ~     v2 = registry.resolve_from_registry_cache(user.canonical_id, trail.window)
      - ⟨    v3 = registry.⟩lookup_by_identifier⟨(user.⟩identifier, audit⟨.window)⟩
      ~     v3 = registry.resolve_from_registry_cache(user.canonical_id, trail.window)
      |     return v1
    ]])
  end)

  it("of six is one block above the hunk", function()
    h.expect(draw(6), [[
      | def check(user, registry, audit):
      - ⟨    v1 = registry.⟩lookup_by_identifier⟨(user.⟩identifier, audit⟨.window)⟩
      - ⟨    v2 = registry.⟩lookup_by_identifier⟨(user.⟩identifier, audit⟨.window)⟩
      - ⟨    v3 = registry.⟩lookup_by_identifier⟨(user.⟩identifier, audit⟨.window)⟩
      - ⟨    v4 = registry.⟩lookup_by_identifier⟨(user.⟩identifier, audit⟨.window)⟩
      - ⟨    v5 = registry.⟩lookup_by_identifier⟨(user.⟩identifier, audit⟨.window)⟩
      - ⟨    v6 = registry.⟩lookup_by_identifier⟨(user.⟩identifier, audit⟨.window)⟩
      ~     v1 = registry.resolve_from_registry_cache(user.canonical_id, trail.window)
      |     v2 = registry.resolve_from_registry_cache(user.canonical_id, trail.window)
      |     v3 = registry.resolve_from_registry_cache(user.canonical_id, trail.window)
      |     v4 = registry.resolve_from_registry_cache(user.canonical_id, trail.window)
      |     v5 = registry.resolve_from_registry_cache(user.canonical_id, trail.window)
      |     v6 = registry.resolve_from_registry_cache(user.canonical_id, trail.window)
      |     return v1
    ]])
  end)
end)

-- The last source a before-image draws its red from is `del_fine`, a
-- character comparison over the whole BLOCK -- the only one whose pale
-- text can come out of a row that is not the one being drawn. Five rows
-- of comment rewritten as six came back with the `th` of `the` stepped
-- back and its `e` lit, matched against a `th` two sentences away. A row
-- the block comparison only scavenged is banded whole; one it genuinely
-- narrows keeps its step-back.
describe("a block rewrite", function()
  it("is not a comparison", function()
    local new = {
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
    local spans = {}
    for i, text in ipairs(new) do
      table.insert(spans, { line = i, col_start = 0, col_end = #text, kind = "add" })
    end
    h.expect(h.draw({ new = new, old = {
      "  -- ...and the third of them: a page it says to go and read. Underlined",
      "  -- rather than only coloured, because that is what a link has looked",
      "  -- like since before any of this: the words are the author's own",
      "  -- sentence, and the line under them is what says they are also a",
      "  -- door. `Underlined` is the group Neovim ships for exactly this.",
      '  link("NemetonLink", "Underlined")',
    }, result = {
      hunks = { { start_a = 1, count_a = 6, start_b = 1, count_b = 20 } },
      spans = spans,
    } }), [[
      - ⟨  -- ...and the third of them: a page it says to go and read. ⟩Underlined
      - ⟨  -- ⟩rather than only coloured⟨, because that is what a link has looked⟩
      -   -- like since before any of this: the words are the author's own
      -   -- sentence, and the line under them is what says they are also a
      -   -- door. `Underlined` is the group Neovim ships for exactly this.
      -   link("NemetonLink", "Underlined")
      +   -- ...and the third of them: a page it says to go and read. The same
      +   -- colour as the other two, because all three are one kind of thing --
      +   -- a reference out of the comment -- and underlined as well, because
      +   -- that is what a link has looked like since before any of this: the
      +   -- words are the author's own sentence, and the line under them is
      +   -- what says they are also a door.
      +   --
      +   -- Copied from `DiagnosticInfo` rather than linked to it, because a
      +   -- link is all or nothing: a group that links somewhere takes that
      +   -- group's attributes entire, and there is nowhere to hang the
      +   -- underline. `Underlined` on its own was the other half of this and
      +   -- carried no colour at all.
      +   local info = vim.api.nvim_get_hl(0, { name = "DiagnosticInfo", link = false })
      +   vim.api.nvim_set_hl(0, "NemetonLink", {
      +     fg = info.fg,
      +     ctermfg = info.ctermfg,
      +     underline = true,
      +     cterm = { underline = true },
      +     default = true,
      +   })
    ]])
  end)
end)
