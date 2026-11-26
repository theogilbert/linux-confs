-- Where a before-image hangs: above the row it became, below the rows it
-- went after, as one block or spread row by row (`collapsed_span`,
-- `delete_anchor`, `spread_max`; rules.md section 4).
local h = require("helpers")

local function drawn(old, new, expected)
  h.drawn({ lang = "python", old = old, new = new }, expected)
end

describe("placement", function()
  if not h.difft then
    pending("difftastic is not installed")
    return
  end

  -- difftastic kept the blank lines after the class and left the ones
  -- before it unpaired, so the old class hung under the method above,
  -- reading as more of it. It hangs below the blanks, as git draws it.
  it("hangs a class removed from between two below the blank lines", function()
    drawn("class A:\n    def a(self):\n        return 1\n\n\nclass B:\n    def b(self):\n"
        .. "        return 2\n\n\nclass C:\n    def c(self):\n        return 3\n",
      "class A:\n    def a(self):\n        return 1\n\n\nclass C:\n    def c(self):\n"
        .. "        return 3\n", [[
          | class A:
          |     def a(self):
          |         return 1
          |
          |
          - class B:
          -     def b(self):
          -         return 2
          | class C:
          |     def c(self):
          |         return 3
        ]])
  end)

  -- ...but only a sibling of what follows does.
  it("keeps the removed tail of a method above the blank line, with the method", function()
    drawn("class A:\n    def a(self, x):\n        y = x + 1\n        log(y)\n        return y\n"
        .. "\n    def b(self):\n        return 2\n",
      "class A:\n    def a(self, x):\n        y = x + 1\n\n    def b(self):\n        return 2\n",
      [[
        | class A:
        |     def a(self, x):
        |         y = x + 1
        -         log(y)
        -         return y
        |
        |     def b(self):
        |         return 2
      ]])
  end)

  -- A blank row of a string is a row of its atom with a zero-width span,
  -- and taken as one it was padded in the dim band: a stripe saying
  -- "this row stayed" between rows that all went.
  it("draws the blank line in a removed class's docstring removed with it", function()
    drawn('class A:\n    x = 1\n\n\nclass B:\n    desc = """\\\n        One.\n\n'
      .. '        Two.\n        """\n', "class A:\n    x = 1\n", [[
        | class A:
        |     x = 1
        - class B:
        -     desc = """\
        -         One.
        -
        -         Two.
        -         """
      ]])
  end)

  -- The old line is paired with the opening `"""` and re-fitted onto the
  -- sentence below it, which it resembles more, so it hung between the
  -- two with the `"""` alone above the line it starts.
  it("draws a docstring opened onto several rows above its opening quotes", function()
    drawn('class Arbiter:\n    def spawn_worker(self):\n        """Spawn a new dirty worker."""\n'
        .. "        self.workers += 1\n",
      'class Arbiter:\n    def spawn_worker(self):\n        """\n        Spawn a new dirty worker.\n\n'
        .. '        Pending respawns are served first.\n        """\n        self.workers += 1\n',
      [[
        | class Arbiter:
        |     def spawn_worker(self):
        - ⟨        ⟩"""⟨Spawn a new dirty worker.⟩"""
        ~         """
        ~         Spawn a new dirty worker.
        +
        +         Pending respawns are served first.
        ~         """
        |         self.workers += 1
      ]])
  end)

  -- One hunk of seven removed rows, which as one block put the old code
  -- ABOVE the docstring it followed. The atom's rows go above the row it
  -- became -- the first stepped back, being on that row whole -- and the
  -- rest where they were.
  it("splits a fold's before-image at the atom's edge", function()
    drawn([[
      class T:
          def test_scale(self):
              """A test about scale widget.

              Args:
                  self: own class.
              """
              widget = Widget(2.0)
              scaled = scale_widget(widget, 2.0)
              assert scaled.width == 4.0
              assert scaled.height == 6.0
    ]], [[
      class T:
          def test_scale(self):
              """A test about scale widget."""
              assert scaled.width == 4.0
    ]], [[
      | class T:
      |     def test_scale(self):
      - ⟨        """A test about scale widget.⟩
      -
      -         Args:
      -             self: own class.
      -         """
      ~         """A test about scale widget.⟦"""⟧
      -         widget = Widget(2.0)
      -         scaled = scale_widget(widget, 2.0)
      |         assert scaled.width == 4.0
      -         assert scaled.height == 6.0
    ]])
  end)

  -- The survival window asks whether the old tokens are on screen, and
  -- an untouched identical row can answer yes for them.
  it("keeps the before-image of a row edited beside an identical one", function()
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
    drawn(twins, (twins:gsub("height=3%.0", "height=4.0", 1)), [[
      | class TestWidget:
      |     def test_area(self):
      - ⟨        widget = Widget(name="a", width=2.0, height=⟩3⟨.0)⟩
      |         widget = Widget(name="a", width=2.0, height=⟦4⟧.0)
      |         assert widget.area() == 6.0
      |
      |     def test_scale_widget(self):
      |         widget = Widget(name="a", width=2.0, height=3.0)
      |         scaled = scale_widget(widget, 2.0)
    ]])
  end)

  -- difftastic reports an alignment for every hunk, but between blocks
  -- of different lengths with nothing in common it is the two laid side
  -- by side in order. Spread on that, every old line hangs above a new
  -- one it has nothing to do with.
  it("draws a rewritten docstring in one block", function()
    local pic, _, buf = h.draw({ lang = "python", old = [[
      class C:
          def find(self, name):
              """Resolve a symbol, preferring the cache over any round trip.

              Four passes, cheapest first:

              1. The find cache, answered before and kept on disk.
              2. The generic walk over tree levels already cached.
              3. The inner driver's own catalog lookup, in one query.
              4. The generic walk over the live listing, for the rest.

              Only pass 3 is written back, since it is the only one that
              leaves nothing behind for the others to find.
              """
              return self._find(name)
    ]], new = [[
      class C:
          def find(self, name):
              """Resolve a symbol, preferring the find cache over any round trip.

              Two passes:

              1. The find cache, keyed by the search itself.
              2. The wrapped driver, whichever way it can answer.
              """
              return self._find(name)
    ]], keep = true })
    h.expect(pic, [[
      | class C:
      |     def find(self, name):
      -         """Resolve a symbol, preferring the cache over any round trip.
      -
      -         Four passes, cheapest first:
      -
      -         1. The find cache, answered before and kept on disk.
      -         2. The generic walk over tree levels already cached.
      -         3. The inner driver's own catalog lookup, in one query.
      -         4. The generic walk over the live listing, for the rest.
      -
      -         Only pass 3 is written back, since it is the only one that
      -         leaves nothing behind for the others to find.
      ~         """Resolve a symbol, preferring the ⟦find ⟧cache over any round trip.
      +
      +         Two passes:
      +
      +         1. The find cache, keyed by the search itself.
      +         2. The wrapped driver, whichever way it can answer.
      |         """
      |         return self._find(name)
    ]])
    local anchors = vim.tbl_filter(function(m) return m[4].virt_lines end, h.marks(buf))
    assert.are.equal(1, #anchors)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

-- difftastic walks the token streams, and a line INSERTED above a changed
-- one takes the changed line's partner. Drawn on that pairing the old
-- line sits above a line it has nothing to do with (`fitted`), and,
-- measured against it, comes out solid red (`refit`). The alignment is
-- still the answer about WHAT changed; this is only which row it hangs
-- above. Hand-built results: the pairing is the point.
describe("a before-image", function()
  it("goes above the line it resembles, not the one it was paired with", function()
    h.expect(h.draw({ lang = "python", old = {
      "async def connected(dispatcher, mock_driver):",
      "    result = await dispatcher.dispatch(Method.CONNECT)",
      '    return dispatcher, result["connection_id"], mock_driver',
    }, new = {
      "async def connected(dispatcher, mock_driver):",
      "    result = await dispatcher.dispatch(Method.CONNECT)",
      "    assert isinstance(result, ConnectResult)",
      "    return dispatcher, result.connection_id, mock_driver",
    }, result = {
      hunks = { { start_a = 3, count_a = 1, start_b = 3, count_b = 2 } },
      anchor = { 1, 2, 3 },
      pairs = { 1, 2, 3 },
    } }), [[
      | async def connected(dispatcher, mock_driver):
      |     result = await dispatcher.dispatch(Method.CONNECT)
      |     assert isinstance(result, ConnectResult)
      - ⟨    return dispatcher, result⟩["⟨connection_id⟩"]⟨, mock_driver⟩
      ~     return dispatcher, result.connection_id, mock_driver
    ]])
  end)

  -- The piece a split line kept -- `fake_url(` -- is too short to resemble
  -- the line it came from; re-paired with the argument row, the old line
  -- was measured against that and called `fake_url(` lost.
  it("of a line split over several goes above the piece it kept", function()
    h.expect(h.draw({ lang = "python", exact = true, old = {
      "res = await resolve(",
      "    fake_url(protocol=redir.source_protocol, target=fake_target(redis.source))",
      ")",
    }, new = {
      "res = await resolve(",
      "    fake_url(",
      "        protocol=redir.source_protocol, target=fake_target(redis.source_hostname)",
      "    )",
      ")",
    }, result = {
      hunks = { { start_a = 2, count_a = 1, start_b = 2, count_b = 2 } },
      spans = {
        { line = 2, col_start = 70, col_end = 76, kind = "delete" },
        { line = 3, col_start = 65, col_end = 80, kind = "add" },
      },
      anchor = { 1, 2, 5 },
      pairs = { 1, 2, [5] = 3 },
    } }), [[
      | res = await resolve(
      - ⟨    fake_url(protocol=redir.source_protocol, target=fake_target(redis.⟩source⟨))⟩
      ~     fake_url(
      |         protocol=redir.source_protocol, target=fake_target(redis.⟦source_hostname⟧)
      |     )
      | )
    ]])
  end)
end)

-- A condition broken one clause per row has no single row it became.
-- Nested, the indentation it shares with its longest clause lifted that
-- row over `word_similarity`; re-measured against it alone, every other
-- clause came back as removed, in both layouts, where difftastic had
-- said `is` and nothing else.
describe("a line reflowed over several rows", function()
  if not h.difft then
    pending("difftastic is not installed")
    return
  end

  local o = { lang = "python",
    old = "class A:\n    def f(self, annotation):\n        for x in y:\n"
      .. "            if isinstance(annotation, type) and issubclass(annotation, AsyncSession)"
      .. " and annotation is not AsyncSession:\n                return 1\n",
    new = "class A:\n    def f(self, annotation):\n        for x in y:\n"
      .. "            if (\n                isinstance(annotation, type)\n"
      .. "                and issubclass(annotation, AsyncSession | Session)\n"
      .. "                and annotation not in (AsyncSession, Session)\n"
      .. "            ):\n                return 1\n" }

  it("loses only what difftastic says it lost, inline", function()
    h.drawn(o, [[
      | class A:
      |     def f(self, annotation):
      |         for x in y:
      - ⟨            if isinstance(annotation, type) and issubclass(annotation, AsyncSession) and annotation ⟩is⟨ not AsyncSession:⟩
      |             if ⟦(⟧
      |                 isinstance(annotation, type)
      |                 and issubclass(annotation, AsyncSession ⟦| Session⟧)
      |                 and annotation not ⟦in (⟧AsyncSession⟦, Session)⟧
      |             ⟦)⟧:
      |                 return 1
    ]])
  end)

  it("...and in the old window", function()
    h.expect(h.draw_old(o), [[
      | class A:
      |     def f(self, annotation):
      |         for x in y:
      |             if isinstance(annotation, type) and issubclass(annotation, AsyncSession) and annotation ⟦is⟧ not AsyncSession:
      |                 return 1
    ]])
  end)
end)

-- All `port,` lost is the comma, and the row it became is directly below
-- it: the one case a lone punctuation mark IS worth pointing at, where
-- the reflow rule (`names`) would draw the whole parameter gone.
describe("a dropped trailing comma", function()
  if not h.difft then
    pending("difftastic is not installed")
    return
  end

  it("is red on its own, the parameter it ended is not", function()
    drawn("def connect(\n    host,\n    port,\n    timeout\n):\n    pass\n",
      "def connect(\n    host,\n    port\n):\n    pass\n", [[
        | def connect(
        |     host,
        - ⟨    port⟩,
        -     timeout
        ~     port
        | ):
        |     pass
      ]])
  end)

  it("is red on its own when the closing bracket moved up onto its row", function()
    drawn("def connect(\n    host,\n    port,\n    timeout):\n    pass\n",
      "def connect(\n    host,\n    port):\n    pass\n", [[
        | def connect(
        |     host,
        - ⟨    port⟩,
        -     timeout):
        ~     port):
        |     pass
      ]])
  end)

  -- No new rows at all: what survived of `fields_columns,` is on the row
  -- the parameters were folded into.
  it("is red on its own when what was left was joined onto one line", function()
    drawn("def f(\n    df: pd.DataFrame,\n    fields_columns: Cols,\n    config_adv: Adv,\n) -> M:\n    pass\n",
      "def f(\n    df: pd.DataFrame, fields_columns: Cols\n) -> M:\n    pass\n", [[
        | def f(
        - ⟨    df: pd.DataFrame,⟩
        - ⟨    fields_columns: Cols⟩,
        -     config_adv: Adv,
        |     df: pd.DataFrame, fields_columns: Cols
        | ) -> M:
        |     pass
      ]])
  end)
end)

-- A file whose body was deleted looks like a fold to the alignment and
-- is not: the rows went AFTER the line that survived. Read as a fold,
-- the whole body hung above the buffer's first line, where there is
-- nothing to scroll to. A fold rewrites the line it collapses onto; a
-- deletion leaves it byte for byte (`collapsed_span`).
describe("a file emptied", function()
  if not h.difft then
    pending("difftastic is not installed")
    return
  end

  it("hangs what went below the line that survived", function()
    local kept = '"""The docstring stays."""\n'
    drawn(kept .. "\nWIDTH = 40\nHEIGHT = 12\n\n\ndef f(box):\n    return WIDTH\n", kept, [[
      | """The docstring stays."""
      - WIDTH = 40
      - HEIGHT = 12
      - def f(box):
      -     return WIDTH
    ]])
  end)

  it("but a deletion at its very start goes above the first line", function()
    drawn("import os\nimport sys\n\ndef f():\n    return 1\n", "def f():\n    return 1\n", [[
      - import os
      - import sys
      | def f():
      |     return 1
    ]])
  end)
end)
