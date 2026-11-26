-- A definition moved within the file. Both backends align in order, so
-- it arrives as a removal in one place and an addition in another; it is
-- drawn as one line where it was -- not its body in red, since nothing of
-- it went -- and at the new place as an edit of its old self, `]c`
-- stopping at both ends. A move line is `>` in a picture, and the bar
-- beside the moved rows `◂`.
local h = require("helpers")
local config = require("uatis.config")

local function draw(old, new, o)
  return h.draw(vim.tbl_extend("keep", o or {}, { lang = "python", old = old, new = new }))
end

describe("a moved function", function()
  if not h.difft or not require("uatis.syntax").lang_of("python") then
    pending("needs difftastic and the python parser")
    return
  end

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

  it("is a line at each end, with only what changed inside it drawn", function()
    local pic, stops = draw(old, new)
    h.expect(pic, [[
      | import os
      |
      |
      > ⇣gamma moved from line 8 · 1 change
      | def gamma(path, mode="r"):  ◂▎
      |     with open(path, mode) as fh:  ◂▎
      |         data = fh.read()  ◂▎
      - ⟨    ⟩lines =⟨ data.⟩splitlines⟨()⟩
      -     return [l.strip() for l in lines if l]
      |     ⟦return⟧ data.⟦split⟧()  ◂▎
      |
      |
      | def alpha(x):
      |     return x + 1
      > ⇡gamma moved to line 4 · 1 change
    ]])
    -- The new place, the edit inside it, and the old place.
    assert.are.same({ 4, 7, 11 }, stops)
  end)

  -- The new copy's rows read exactly like the old copy's, and once
  -- excused them out of its before-image, leaving the body without its
  -- signature hanging under `alpha`.
  it("is the old copy removed whole where no move is read", function()
    config.diff.move.enabled = false
    local pic = draw(old, new, { path = "y.py" })
    config.diff.move.enabled = true
    h.expect(pic, [[
      | import os
      |
      |
      + def gamma(path, mode="r"):
      +     with open(path, mode) as fh:
      +         data = fh.read()
      +     return data.split()
      |
      |
      | def alpha(x):
      |     return x + 1
      - def gamma(path, mode="r"):
      -     with open(path, mode) as fh:
      -         data = fh.read()
      -     lines = data.splitlines()
      -     return [l.strip() for l in lines if l]
    ]])
  end)

  -- The line backend matches `gamma` in place and moves `alpha`.
  it("says so when nothing in it changed, and stops at both ends", function()
    local pic, stops = draw(
      { "import os", "", "", "def alpha(x):", "    y = x * 2", "    return y + 1",
        "", "", "def gamma(p):", "    a = 1", "    return a" },
      { "import os", "", "", "def gamma(p):", "    a = 1", "    return a",
        "", "", "def alpha(x):", "    y = x * 2", "    return y + 1" },
      { backend = "line" })
    h.expect(pic, [[
      | import os
      |
      |
      > ⇣alpha moved to line 9 · unchanged
      | def gamma(p):
      |     a = 1
      |     return a
      |
      |
      > ⇡alpha moved from line 4 · unchanged
      | def alpha(x):  ◂▎
      |     y = x * 2  ◂▎
      |     return y + 1  ◂▎
    ]])
    assert.are.same({ 4, 9 }, stops)
  end)
end)

describe("not a move", function()
  if not h.difft or not require("uatis.syntax").lang_of("python") then
    pending("needs difftastic and the python parser")
    return
  end

  it("is a function rewritten where it stands", function()
    h.expect(draw({ "x = 1", "", "def f(a):", "    b = a", "    return b", "", "y = 2" },
      { "x = 1", "", "def f(a, c):", "    d = a + c", "    return d", "", "y = 2" }), [[
        | x = 1
        |
        | def f(a⟦, c⟧):
        - ⟨    ⟩b⟨ = a⟩
        |     ⟦d⟧ = a ⟦+ c⟧
        - ⟨    return ⟩b
        |     return ⟦d⟧
        |
        | y = 2
      ]])
  end)

  -- Each docstring is one atom wholly inside its hunk on both sides, and
  -- with the copy in place left out of the scoring each was paired by
  -- name with the OTHER class's: drawn swapped.
  it("is two docstrings that each grew in place", function()
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
    h.expect(draw(docs_old, docs_new), [[
      | class Timeout(Setting):
      |     desc = """\
      |         Workers silent for more than this many seconds are killed.
      |
      |         Value is a positive number or 0.
      |
      +         On HTTP/2 it also bounds a single stream.
      |         """
      |
      |
      | class Keepalive(Setting):
      |     desc = """\
      |         The number of seconds to wait on a Keep-Alive connection.
      |
      |         Generally set in the 1-5 seconds range.
      |
      +         An idle HTTP/2 connection is closed with GOAWAY.
      |         """
      |
      |
    ]])
  end)

  -- To difftastic the methods are new in one class and gone from the
  -- other, and the agreed rows it found -- blanks, a `c = Config()` --
  -- cut the damage into regions too small for the line diff to see a
  -- method in one as the same method in another. Each removal is drawn
  -- once, above or below what it answers to.
  it("is the methods a removed class header handed up to the class above", function()
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
    h.expect(draw(header_old, header_new), [[
      | class TestHttp2MaxConcurrentStreams:
      |     """Test http2_max_concurrent_streams configuration setting."""
      |
      |     def test_negative_value_raises(self):
      |         c = Config()
      |         with pytest.raises(ValueError):
      |             c.set("http2_max_concurrent_streams", -1)
      |
      - ⟨    def ⟩test_zero_value⟨(self):⟩
      -         # Zero is technically valid for positive int validator
      -         # It may have special meaning (use h2 default)
      +     def test_zero_value_is_rejected(self):
      +         """0 would advertise a connection that can open no streams."""
      |         c = Config()
      - ⟨        c.set(⟩"http2_max_concurrent_streams", 0⟨)⟩
      - ⟨        assert c.⟩http2_max_concurrent_streams⟨ == ⟩0
      +         with pytest.raises(ValueError):
      +             c.set("http2_max_concurrent_streams", 0)
      |
      - class TestHttp2InitialWindowSize:
      -     """Test http2_initial_window_size configuration setting."""
      |     def test_default_value(self):
      |         c = Config()
      |         # Default per RFC 7540 is 65535
      |         assert c.http2_initial_window_size == 65535
      |
      |     def test_set_custom_value(self):
      |         c = Config()
      |         c.set("http2_initial_window_size", 131072)
      |         assert c.http2_initial_window_size == 131072
      |
      |     def test_set_from_string(self):
      |         c = Config()
      |         c.set("http2_initial_window_size", "32768")
      |         assert c.http2_initial_window_size == 32768
    ]])
  end)

  -- An assignment names a definition at the top of a file or in a class
  -- body; inside a function it is a local, and two locals sharing a name
  -- are not one thing. Paired as a move, the edit where it stood drew
  -- nothing.
  it("is a local of the same name in another function", function()
    h.expect(draw([[
      class Receiver:
          async def _read_with_disconnect_check(self):
              """Read body with periodic disconnect checks (avoids task creation)."""
              # Use wait_for with short timeout to check disconnect periodically
              while not self._closed and not self.protocol._closed:
                  try:
                      chunk = await asyncio.wait_for(
                          self.request.read_body(65536),
                          timeout=0.1
                      )
                      return chunk
                  except asyncio.TimeoutError:
                      # Check disconnect and retry
                      continue
              return None

          async def _handle_http2_request(self, request, h2_conn, sockname, peername):
              """Handle a single HTTP/2 request with streaming support.

              Streams response body chunks immediately instead of buffering,
              enabling SSE, streaming downloads, and other real-time use cases.
              """
              stream_id = request.stream.stream_id
              scope = self._build_http2_scope(request, sockname, peername)

              response_started = False
              response_complete = False
              headers_sent = False
              exc_to_raise = None
              response_status = 500
              response_headers = []
              response_sent = 0

              async def receive():
                  # For HTTP/2, the body is already buffered in the stream
                  body = request.body.read()
                  return {
                      "type": "http.request",
                      "body": body,
                      "more_body": False,
                  }
    ]], [[
      class Receiver:
          async def _read_with_disconnect_check(self):
              """Read body using event-based waiting (no polling).

              Uses the protocol's data event to wait for incoming data,
              avoiding the latency and CPU overhead of periodic polling.
              """
              while not self._closed and not self.protocol._closed:
                  # Try to read available data
                  try:
                      chunk = await self.request.read_body(65536)
                      return chunk
                  except Exception:
                      # If read fails, check if we should continue
                      if self._closed or self.protocol._closed:
                          return None
                      # Wait for more data using the protocol's data event
                      if self.protocol._data_event:
                          self.protocol._data_event.clear()
                          # Use wait_for with longer timeout for disconnect detection
                          try:
                              await asyncio.wait_for(
                                  self.protocol._data_event.wait(),
                                  timeout=30.0  # 30s timeout for disconnect detection
                              )
                          except asyncio.TimeoutError:
                              # Check connection state and continue
                              continue
                      else:
                          # No event available, brief sleep as fallback
                          await asyncio.sleep(0.001)
              return None

          async def _handle_http2_request(self, request, h2_conn, sockname, peername):
              """Handle a single HTTP/2 request with streaming support.

              Streams both request and response body chunks immediately,
              avoiding buffering entire uploads and enabling SSE, streaming
              downloads, and other real-time use cases.
              """
              stream_id = request.stream.stream_id
              stream = h2_conn.streams.get(stream_id)
              scope = self._build_http2_scope(request, sockname, peername)

              response_started = False
              response_complete = False
              headers_sent = False
              exc_to_raise = None
              response_status = 500
              response_headers = []
              response_sent = 0

              # Track if we've finished receiving body
              body_received = False

              async def receive():
                  nonlocal body_received

                  # Check if stream is closed or missing
                  if stream is None or stream.state.name == "CLOSED":
                      return {"type": "http.disconnect"}

                  # First call: if body already complete (small requests), return it
                  if not body_received and stream.request_complete and not stream._body_chunks:
                      body_received = True
                      body = stream.get_request_body()
                      return {
                          "type": "http.request",
                          "body": body,
                          "more_body": False,
                      }

                  # Streaming: read next chunk
                  try:
                      chunk = await asyncio.wait_for(
                          stream.read_body_chunk(),
                          timeout=30.0
                      )
                  except asyncio.TimeoutError:
                      return {"type": "http.disconnect"}

                  if chunk is None:
                      body_received = True
                      return {
                          "type": "http.request",
                          "body": b"",
                          "more_body": False,
                      }

                  return {
                      "type": "http.request",
                      "body": chunk,
                      "more_body": not stream._body_complete,
                  }
    ]]), [[
      | class Receiver:
      |     async def _read_with_disconnect_check(self):
      -         """Read body with periodic disconnect checks (avoids task creation)."""
      -         # Use wait_for with short timeout to check disconnect periodically
      +         """Read body using event-based waiting (no polling).
      +
      +         Uses the protocol's data event to wait for incoming data,
      +         avoiding the latency and CPU overhead of periodic polling.
      +         """
      |         while not self._closed and not self.protocol._closed:
      +             # Try to read available data
      |             try:
      - ⟨                chunk = await ⟩asyncio.wait_for(
      - ⟨                    self.request.read_body(65536)⟩,
      -                     timeout=0.1
      -                 )
      ~                 chunk = await self.request.read_body(65536)
      |                 return chunk
      - ⟨            except asyncio.TimeoutError:⟩
      |             except ⟦Exception:⟧
      +                 # If read fails, check if we should continue
      +                 if self._closed or self.protocol._closed:
      +                     return None
      +                 # Wait for more data using the protocol's data event
      +                 if self.protocol._data_event:
      +                     self.protocol._data_event.clear()
      +                     # Use wait_for with longer timeout for disconnect detection
      +                     try:
      +                         await asyncio.wait_for(
      +                             self.protocol._data_event.wait(),
      +                             timeout=30.0  # 30s timeout for disconnect detection
      +                         )
      |                     ⟦except⟧ asyncio.TimeoutError:
      -                 # Check disconnect and retry
      ~                         # Check ⟦connection state⟧ and ⟦continue⟧
      |                 ⟦        ⟧continue
      +                 else:
      +                     # No event available, brief sleep as fallback
      +                     await asyncio.sleep(0.001)
      |         return None
      |
      |     async def _handle_http2_request(self, request, h2_conn, sockname, peername):
      |         """Handle a single HTTP/2 request with streaming support.
      |
      - ⟨        Streams response body chunks immediately⟩ instead of buffering⟨,⟩
      ~         Streams ⟦both request and ⟧response body chunks immediately,
      -         enabling SSE, streaming downloads, and other real-time use cases.
      +         avoiding buffering entire uploads and enabling SSE, streaming
      ~         downloads, and other real-time use cases.
      |         """
      |         stream_id = request.stream.stream_id
      +         stream = h2_conn.streams.get(stream_id)
      |         scope = self._build_http2_scope(request, sockname, peername)
      |
      |         response_started = False
      |         response_complete = False
      |         headers_sent = False
      |         exc_to_raise = None
      |         response_status = 500
      |         response_headers = []
      |         response_sent = 0
      |
      +         # Track if we've finished receiving body
      +         body_received = False
      |
      |         async def receive():
      -             # For HTTP/2, the body is already buffered in the stream
      - ⟨            body = ⟩request.body.read⟨()⟩
      +             nonlocal body_received
      +
      +             # Check if stream is closed or missing
      +             if stream is None or stream.state.name == "CLOSED":
      +                 return {"type": "http.disconnect"}
      +
      +             # First call: if body already complete (small requests), return it
      +             if not body_received and stream.request_complete and not stream._body_chunks:
      +                 body_received = True
      |                 body = ⟦stream.get_request_body⟧()
      +                 return {
      +                     "type": "http.request",
      +                     "body": body,
      +                     "more_body": False,
      +                 }
      +
      +             # Streaming: read next chunk
      +             try:
      +                 chunk = await asyncio.wait_for(
      +                     stream.read_body_chunk(),
      +                     timeout=30.0
      +                 )
      +             except asyncio.TimeoutError:
      +                 return {"type": "http.disconnect"}
      +
      +             if chunk is None:
      +                 body_received = True
      +                 return {
      +                     "type": "http.request",
      +                     "body": b"",
      +                     "more_body": False,
      +                 }
      |
      |             return {
      |                 "type": "http.request",
      - ⟨                "body": ⟩body⟨,⟩
      - ⟨                "more_body": ⟩False⟨,⟩
      |                 ⟦"body": chunk⟧,
      |                 ⟦"more_body": not stream._body_complete⟧,
      |             }
    ]])
  end)
end)
