-- `diff.lua`'s pure helpers, stated as data. What a whole pair of files is
-- drawn as lives in tests/uatis/overlay/.
local h = require("helpers")
local diff = require("uatis.diff")
local config = require("uatis.config")

local function cols(list)
  local out = vim.tbl_map(function(a) return { a.col_start, a.col_end } end, list)
  table.sort(out, function(a, b) return a[1] < b[1] end)
  return out
end

describe("block_diff / inline_diff and indentation", function()
  -- Matched by content across rows, an eight-space indent on old row one
  -- found the eight spaces on new row one -- a row that had never been
  -- there. Nothing about leading whitespace comes from the block
  -- comparison; a row with a known partner gets the columns it gained.
  it("marks nothing inside any row's indentation", function()
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
    local at_front = vim.tbl_filter(function(a) return a.col_start < 8 end, r.adds)
    assert.are.same({}, at_front)
  end)

  it("gives a row the columns it gained against its own old row, and the edit", function()
    local one = diff.inline_diff("        x = 1", "            x = 2")
    assert.are.same({ { 8, 12 }, { 16, 17 } }, cols(one.adds))
    assert.are.same({ { 12, 13 } }, cols(one.dels))
  end)

  it("shows the columns that went on a row pulled left", function()
    local back = diff.inline_diff("            x = 1", "        x = 1")
    assert.are.same({ { 8, 12 } }, cols(back.dels))
  end)
end)

describe("word_span", function()
  local function span_of(a, b)
    local s, e = diff.word_span(a, b)
    return s and b:sub(s + 1, e) or nil
  end

  -- A raw character trim would stop at the shared `s`.
  it("does not truncate a word at a shared trailing letter", function()
    assert.are.equal("semaphores", span_of("a semaphore here", "a semaphores here"))
  end)

  it("marks only an inserted argument, not the whole call", function()
    assert.are.equal(", b", span_of("call(a)", "call(a, b)"))
  end)

  it("has no span for identical lines", function()
    assert.is_nil(diff.word_span("same", "same"))
  end)
end)

describe("the line backend's algorithm", function()
  -- Myers and histogram are both minimal and differ in WHICH script they
  -- return. Test functions moved into a class come back from Myers as one
  -- hunk over the whole body, which swallows a one-word change to an
  -- import above it -- drawn here as red above green, a wholesale
  -- replacement, since this renderer draws the whole old block above the
  -- whole new one.
  local old = h.source([[
    import pytest

    from widgetry.core import Widget, normalise, scale_widget, total_area


    def test_area():
        widget = Widget(name="a", width=2.0, height=3.0)
        assert widget.area() == 6.0


    def test_normalise_clamps_low():
        assert normalise(-1.0, 0.0, 10.0) == 0.0


    def test_normalise_clamps_high():
        assert normalise(11.0, 0.0, 10.0) == 10.0


    def test_normalise_passes_through():
        assert normalise(5.0, 0.0, 10.0) == 5.0


    def test_scale_widget():
        widget = Widget(name="a", width=2.0, height=3.0)
        scaled = scale_widget(widget, 2.0)
        assert scaled.width == 4.0
        assert scaled.height == 6.0


    def test_total_area():
        widgets = [
            Widget(name="a", width=1.0, height=1.0),
            Widget(name="b", width=2.0, height=2.0),
        ]
        assert total_area(widgets) == 5.0
  ]])
  local new = h.source([[
    import pytest

    from widgetry.core import Widget, clamp, scale_widget, total_area


    class TestWidget:
        def test_area(self):
            widget = Widget(name="a", width=2.0, height=3.0)
            assert widget.area() == 6.0

        def test_scale_widget(self):
            widget = Widget(name="a", width=2.0, height=3.0)
            scaled = scale_widget(widget, 2.0)
            assert scaled.width == 4.0
            assert scaled.height == 6.0

        def test_total_area(self):
            widgets = [
                Widget(name="a", width=1.0, height=1.0),
                Widget(name="b", width=2.0, height=2.0),
            ]
            assert total_area(widgets) == 5.0

        def test_is_square(self):
            assert Widget(name="a", width=2.0, height=2.0).is_square()


    class TestClamp:
        @pytest.mark.parametrize(
            "value,expected",
            [(-1.0, 0.0), (11.0, 10.0), (5.0, 5.0)],
        )
        def test_clamp(self, value, expected):
            assert clamp(value, 0.0, 10.0) == expected
  ]])

  local function hunks(algorithm)
    local was = config.diff.line.algorithm
    config.diff.line.algorithm = algorithm
    local r = h.compute({ old = old, new = new, backend = "line", lang = "python" })
    config.diff.line.algorithm = was
    return r.hunks
  end

  it("is not myers, which lumps the body into one hunk", function()
    assert.are.equal(1, #hunks("myers"))
  end)

  it("keeps the import line a 1:1 hunk of its own", function()
    local split = hunks(config.diff.line.algorithm)
    assert.is_true(#split > 1)
    assert.are.equal(1, split[1].count_a)
    assert.are.equal(1, split[1].count_b)
  end)

  it("so the import renders as the one word that changed", function()
    local pic = h.draw({ old = old, new = new, backend = "line", lang = "python" })
    h.expect(h.rows(pic, 1, 4), [[
      | import pytest
      |
      - ⟨from widgetry.core import Widget, ⟩normalise⟨, scale_widget, total_area⟩
      | from widgetry.core import Widget, ⟦clamp⟧, scale_widget, total_area
    ]])
  end)
end)

describe("content_survives", function()
  -- The decision cannot come from the token diff: aligning these pairs
  -- the old opening quote against `self` and calls it deleted.
  it("sees a wrapped call is all still there", function()
    assert.is_true(diff.content_survives(
      { '        region = self._client.get_bucket_location(Bucket=bucket).get(',
        '            "LocationConstraint"', "        )" },
      { "        region = (",
        '            self._client.get_bucket_location(Bucket=bucket).get("LocationConstraint")',
        "        )" }))
  end)

  it("sees a real replacement as a removal", function()
    assert.is_false(diff.content_survives({ "    self._closed = True" }, { "    self._shutdown = True" }))
  end)

  it("sees a dropped comma as a removal", function()
    assert.is_false(diff.content_survives({ 'x.get("k", "v")' }, { 'x.get("k") or "v"' }))
  end)

  -- The same edit gets the same answer whatever line it is on: at a
  -- floor of two, a quarter of sixteen tokens covers three and a quarter
  -- of eleven covers two, and one file drew one edit two ways.
  it("keeps a short line that gained a type parameter the line it was", function()
    assert.is_true(diff.content_survives({ '        assert desc.types == ["VARCHAR2"]' },
      { '        assert desc.types == ["VARCHAR2(50)"]' }))
  end)

  it("and the longer one beside it", function()
    assert.is_true(diff.content_survives({ '        assert by_name["VAL"].types == ["VARCHAR2"]' },
      { '        assert by_name["VAL"].types == ["VARCHAR2(50)"]' }))
  end)
end)

describe("block_diff and line breaks", function()
  -- The tokenizer emits a line break as a token whose text IS a newline,
  -- and the intra-line diff joins tokens with newlines for `vim.diff`:
  -- left alone every index after a break drifts, and past the end of the
  -- array it crashed on the token that is not there.
  local function compare(old, new)
    local fine, r = pcall(diff.block_diff, old, new)
    assert.is_true(fine, "comparing a " .. #old .. "-line block does not throw")
    return r
  end

  it("finds what changed on each line, and lands each mark on its line", function()
    local new = { "def two(b, c):", "    return b + c" }
    local r = compare({ "def one(a):", "    return a" }, new)
    local adds = {}
    for _, a in ipairs(r.adds) do
      assert.is_true(a.line == 1 or a.line == 2)
      table.insert(adds, new[a.line]:sub(a.col_start + 1, a.col_end))
    end
    assert.is_true(h.contains(adds, "two"))
    assert.is_true(h.contains(adds, "c"))
  end)

  it("does not throw on longer blocks", function()
    compare({ "x = 1", "y = 2", "z = 3" }, { "alpha = 10", "beta = 20", "gamma = 30" })
    compare({ "if a:", "    b()", "else:", "    c()" }, { "while q:", "    r()", "finally:", "    s()" })
  end)
end)

describe("content_survives, by the token", function()
  it("says a short line scattered across its neighbours has not survived", function()
    assert.is_false(diff.content_survives({ "import os" }, { "import json", "import sys" }))
  end)

  it("says a name that is a prefix of the tag below it has not", function()
    assert.is_false(diff.content_survives(
      { ":DbConnect\tgrannos.txt\t/*:DbConnect*" },
      { ":DbCancelQuery\tgrannos.txt\t/*:DbCancelQuery*",
        ":DbConnections\tgrannos.txt\t/*:DbConnections*" }))
  end)

  it("says a line that gained a token and kept the rest has", function()
    assert.is_true(diff.content_survives({ "def test_area():" }, { "    def test_area(self):" }))
  end)

  it("says the same line one indent further in has", function()
    assert.is_true(diff.content_survives({ "    x = compute(a)" }, { "        x = compute(a)" }))
  end)

  it("says a line wrapped in brackets has", function()
    assert.is_true(diff.content_survives(
      { "region = self.client.get_bucket_location(Bucket=b)" },
      { "region = (", "    self.client.get_bucket_location(Bucket=b)", ")" }))
  end)
end)
