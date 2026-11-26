-- Which rows answer to which. difftastic's alignment is not taken at face
-- value (`realign`, `prefer_lines`, the slides in diff.lua; rules.md
-- section 1): where its positional walk inside a changed node, or a tie
-- between equally good readings, draws code removed and added back at
-- once, the line diff's reading is taken instead. Each case is a real
-- edit that once drew wrong.
local h = require("helpers")

local function drawn(old, new, expected)
  h.drawn({ lang = "python", old = old, new = new }, expected)
end

describe("alignment", function()
  if not h.difft then
    pending("difftastic is not installed")
    return
  end

  -- A lone untouched row between two changes is swallowed into the hunk
  -- so a wrap reads as one edit; where the hunk then fails to pair up,
  -- it came out red above itself with a dim band on itself.
  it("draws nothing for an untouched row swallowed between two changes", function()
    drawn([[
      def clamp(value, lower, upper):
          if value < lower:
              return lower
          if value > upper:
              return upper
          return value
    ]], [[
      def clamp(value, lower, upper):
          if value < lower:
              return float(lo)
          if value > upper:
              return float(hi)
          assert value is not None
          return value
    ]], [[
      | def clamp(value, lower, upper):
      |     if value < lower:
      - ⟨        return ⟩lower
      |         return ⟦float(lo)⟧
      |     if value > upper:
      - ⟨        return ⟩upper
      |         return ⟦float(hi)⟧
      +     assert value is not None
      |     return value
    ]])
  end)

  -- Swallowed, the hunk was 4-into-4 with half its rows resembling their
  -- partners and went up as one block: the `if` red above itself, the old
  -- comment above the wrong line.
  it("draws apart two changes either side of an untouched row", function()
    drawn([[
      def handle(resp):
          try:
              work()
          except Exception:
              if resp and resp.headers_sent:
                  # If the requests have already been sent, we should close the
                  # connection to indicate the error.
                  raise
    ]], [[
      def handle(resp):
          try:
              work()
          except BaseException:
              if resp and resp.headers_sent:
                  # Timeout abort is SystemExit. If we already started the
                  # response, writing a 500 on the same socket corrupts it.
                  raise
    ]], [[
      | def handle(resp):
      |     try:
      |         work()
      - ⟨    except ⟩Exception⟨:⟩
      |     except ⟦BaseException⟧:
      |         if resp and resp.headers_sent:
      -             # If the requests have already been sent, we should close the
      -             # connection to indicate the error.
      +             # Timeout abort is SystemExit. If we already started the
      +             # response, writing a 500 on the same socket corrupts it.
      |             raise
    ]])
  end)

  -- difftastic calls the comment removed where it was and added where it
  -- is; the line diff matches only that row, too few to overrule a
  -- pairing -- except it overrules nothing: difftastic had already said
  -- the line went and came back.
  it("keeps a comment rows were put in above, the block it headed collapsed", function()
    drawn([[
      class Worker:
          def handle(self, conn):
              try:
                  req = next(conn.parser)
                  if not req:
                      return False

                  # Handle the request
                  keepalive = self.handle_request(req, conn)
                  if keepalive:
                      # Discard any unread request body before keepalive to prevent
                      # the socket from appearing readable due to leftover bytes.
                      drain_deadline = time.monotonic() + DEFAULT_WORKER_DATA_TIMEOUT
                      if not conn.parser.finish_body(deadline=drain_deadline):
                          # Abandon keepalive when the body could not be fully drained.
                          return False
                      return True
              except http.errors.NoMoreData as e:
                  self.log.debug("Ignored premature client disconnection. %s", e)
              return False
    ]], [[
      class Worker:
          def handle(self, conn):
              try:
                  req = next(conn.parser)
                  if not req:
                      return False

                  settings = None
                  if negotiation.upgrade_allowed(self.cfg, conn.client):
                      settings = negotiation.upgrade_settings(req)
                  if settings is not None:
                      return self.handle_h2c_upgrade(conn, req, settings)

                  # Handle the request
                  return self._keepalive_after(conn, self.handle_request(req, conn))
              except http.errors.NoMoreData as e:
                  self.log.debug("Ignored premature client disconnection. %s", e)
              return False
    ]], [[
      | class Worker:
      |     def handle(self, conn):
      |         try:
      |             req = next(conn.parser)
      |             if not req:
      |                 return False
      |
      |             ⟦settings = None⟧
      |             ⟦if negotiation.upgrade_allowed(⟧self.⟦cfg⟧, conn⟦.client)⟧:
      |                 ⟦settings = negotiation.upgrade_settings(req)⟧
      |             if ⟦settings is⟧ not ⟦None⟧:
      |                 return ⟦self.handle_h2c_upgrade(conn, req, settings)⟧
      |
      |             # Handle the request
      - ⟨            ⟩keepalive⟨ = self.⟩handle_request(req⟨, conn⟩)
      -             if keepalive:
      -                 # Discard any unread request body before keepalive to prevent
      -                 # the socket from appearing readable due to leftover bytes.
      -                 drain_deadline = time.monotonic() + DEFAULT_WORKER_DATA_TIMEOUT
      -                 if not conn.parser.finish_body(deadline=drain_deadline):
      -                     # Abandon keepalive when the body could not be fully drained.
      - ⟨                    return ⟩False
      - ⟨                return ⟩True
      |             return ⟦self._keepalive_after(conn, self.handle_request(req, conn))⟧
      |         except http.errors.NoMoreData as e:
      |             self.log.debug("Ignored premature client disconnection. %s", e)
      |         return False
    ]])
  end)

  -- Four rewritten rows are a passage, drawn as one block, and the
  -- opening line, the blank and the closing quotes were drawn in it, red
  -- above their own twins. Unchanged at both ends, they come off it.
  it("draws a reworded paragraph without the docstring's unchanged ends", function()
    drawn([[
      class C:
          async def _send(self, queue_frames):
              """Queue frames on h2 and put them on the wire.

              Streams are served by concurrent tasks, so both steps happen
              under one lock with no await between them: the receive loop
              cannot parse a GOAWAY (which clears h2's outbound buffer) in
              between, and HEADERS leave in the order they were encoded.
              """
              async with self._lock():
                  queue_frames()
    ]], [[
      class C:
          async def _send(self, queue_frames):
              """Queue frames on h2 and put them on the wire.

              Streams are served by concurrent tasks, so encoding and writing
              happen under one lock with no await between them: the receive
              loop cannot parse a GOAWAY (which clears h2's outbound buffer)
              in between, and HEADERS leave in the order they were encoded.
              Waiting for the transport happens after the lock is released.
              """
              async with self._lock():
                  queue_frames()
    ]], [[
      | class C:
      |     async def _send(self, queue_frames):
      |         """Queue frames on h2 and put them on the wire.
      |
      - ⟨        Streams are served by concurrent tasks, so ⟩both steps happen
      - ⟨        under one lock with no await between them: the receive⟩ loop
      - ⟨        cannot parse a GOAWAY (which clears h2's outbound buffer)⟩ in
      -         between, and HEADERS leave in the order they were encoded.
      ~         Streams are served by concurrent tasks, so ⟦encoding and writing⟧
      ~         ⟦happen ⟧under one lock with no await between them: the receive
      ~         ⟦loop ⟧cannot parse a GOAWAY (which clears h2's outbound buffer)
      ~         ⟦in ⟧between, and HEADERS leave in the order they were encoded.
      +         Waiting for the transport happens after the lock is released.
      |         """
      |         async with self._lock():
      |             queue_frames()
    ]])
  end)

  -- Inside one atom difftastic pairs rows by position, so the rows under
  -- a paragraph that lost a line were each paired with the row above its
  -- twin. A run matched in order, each a row difftastic marked, is its
  -- positional walk gone wrong, not a coincidence.
  it("leaves the rows under a paragraph that lost a line alone", function()
    drawn([[
      class C:
          def _handle_connection_terminated(self, event):
              """Handle ConnectionTerminated event (GOAWAY frame).

              A graceful GOAWAY (NO_ERROR) only forbids new streams; the ones
              already established finish (RFC 9113 section 6.8). h2 closes its
              connection state on receipt and would refuse to send anything,
              so its state is put back to open while those streams drain, and
              the connection closes once they are done. Any other error code
              closes at once.

              Args:
                  event: ConnectionTerminated event
              """
              if event.error_code == HTTP2ErrorCode.NO_ERROR and self.streams:
                  self.draining = True
                  return
              self._closed = True
    ]], [[
      class C:
          def _handle_connection_terminated(self, event):
              """Handle ConnectionTerminated event (GOAWAY frame).

              A graceful GOAWAY (NO_ERROR) with streams in flight puts the
              connection into draining: the established streams finish, later
              ones are refused, and the connection closes once they are done
              (RFC 9113 section 6.8). The h2 subclass has already kept its own
              state open for that case. Any other GOAWAY closes at once.

              Args:
                  event: ConnectionTerminated event
              """
              if (event.error_code == HTTP2ErrorCode.NO_ERROR
                      and self.h2_conn.peer_goaway_last_stream_id is not None):
                  self.draining = True
                  return
              self._closed = True
    ]], [[
      | class C:
      |     def _handle_connection_terminated(self, event):
      |         """Handle ConnectionTerminated event (GOAWAY frame).
      |
      -         A graceful GOAWAY (NO_ERROR) only forbids new streams; the ones
      -         already established finish (RFC 9113 section 6.8). h2 closes its
      -         connection state on receipt and would refuse to send anything,
      -         so its state is put back to open while those streams drain, and
      -         the connection closes once they are done. Any other error code
      -         closes at once.
      +         A graceful GOAWAY (NO_ERROR) with streams in flight puts the
      +         connection into draining: the established streams finish, later
      +         ones are refused, and the connection closes once they are done
      +         (RFC 9113 section 6.8). The h2 subclass has already kept its own
      +         state open for that case. Any other GOAWAY closes at once.
      |
      |         Args:
      |             event: ConnectionTerminated event
      |         """
      - ⟨        if event.error_code == HTTP2ErrorCode.NO_ERROR and self.⟩streams⟨:⟩
      |         if ⟦(⟧event.error_code == HTTP2ErrorCode.NO_ERROR
      |                 and self⟦.h2_conn.peer_goaway_last_stream_id is not None)⟧:
      |             self.draining = True
      |             return
      |         self._closed = True
    ]])
  end)

  -- difftastic follows the body and calls the new function the old one
  -- renamed, leaving the unchanged `def` and docstring red where they
  -- were and green where they are. The line diff's reading draws fewer
  -- lines as both, and is taken.
  it("keeps the def and docstring of a function whose body was split out", function()
    drawn([[
      class C:
          def send_response(self, stream_id, status, headers, body=None):
              """Send a response on a stream.

              Args:
                  stream_id: The stream ID to respond on
                  status: HTTP status code (int)
                  headers: List of (name, value) header tuples
                  body: Optional response body bytes

              Raises:
                  HTTP2Error: If stream not found or in invalid state

              Returns:
                  bool: True if response sent, False if stream was already closed
              """
              stream = self.streams.get(stream_id)
              if stream is None:
                  # Stream was already cleaned up (reset/closed) - return gracefully
                  return False

              # Build response headers with :status pseudo-header
              response_headers = [(':status', str(status))]
              for name, value in headers:
                  # HTTP/2 headers must be lowercase
                  response_headers.append((name.lower(), str(value)))

              end_stream = body is None or len(body) == 0

              try:
                  # Send headers
                  self.h2_conn.send_headers(stream_id, response_headers, end_stream=end_stream)
                  stream.send_headers(response_headers, end_stream=end_stream)
                  self._send_pending_data()

                  # Send body if present
                  if body and len(body) > 0:
                      self.send_data(stream_id, body, end_stream=True)
                  return True
              except _h2_exceptions.StreamClosedError:
                  # Stream was reset by client - clean up gracefully
                  stream.close()
                  self.cleanup_stream(stream_id)
                  return False
    ]], [[
      class C:
          def send_response_headers(self, stream_id, status, headers,
                                    end_stream=False):
              """Send response headers on a stream without ending it.

              Returns False if the stream is already gone. Split out of
              send_response() so a response can be streamed: headers first, then
              any number of data frames, then end_stream().
              """
              stream = self.streams.get(stream_id)
              if stream is None:
                  # Stream was already cleaned up (reset/closed)
                  return False

              # Build response headers with :status pseudo-header
              response_headers = [(':status', str(status))]
              for name, value in headers:
                  # HTTP/2 headers must be lowercase
                  response_headers.append((name.lower(), str(value)))

              self.h2_conn.send_headers(stream_id, response_headers,
                                        end_stream=end_stream)
              stream.send_headers(response_headers, end_stream=end_stream)
              self._send_pending_data()
              return True

          def send_response(self, stream_id, status, headers, body=None):
              """Send a response on a stream.

              Args:
                  stream_id: The stream ID to respond on
                  status: HTTP status code (int)
                  headers: List of (name, value) header tuples
                  body: Optional response body bytes

              Raises:
                  HTTP2Error: If stream not found or in invalid state

              Returns:
                  bool: True if response sent, False if stream was already closed
              """
              end_stream = body is None or len(body) == 0
              try:
                  if not self.send_response_headers(stream_id, status, headers,
                                                    end_stream=end_stream):
                      return False
                  # Send body if present
                  if body and len(body) > 0:
                      self.send_data(stream_id, body, end_stream=True)
                  return True
              except _h2_exceptions.StreamClosedError:
                  # Stream was reset by client - clean up gracefully
                  stream = self.streams.get(stream_id)
                  if stream is not None:
                      stream.close()
                  self.cleanup_stream(stream_id)
                  return False
    ]], [[
      | class C:
      +     def send_response_headers(self, stream_id, status, headers,
      +                               end_stream=False):
      +         """Send response headers on a stream without ending it.
      +
      +         Returns False if the stream is already gone. Split out of
      +         send_response() so a response can be streamed: headers first, then
      +         any number of data frames, then end_stream().
      +         """
      +         stream = self.streams.get(stream_id)
      +         if stream is None:
      +             # Stream was already cleaned up (reset/closed)
      +             return False
      +
      +         # Build response headers with :status pseudo-header
      +         response_headers = [(':status', str(status))]
      +         for name, value in headers:
      +             # HTTP/2 headers must be lowercase
      +             response_headers.append((name.lower(), str(value)))
      +
      +         self.h2_conn.send_headers(stream_id, response_headers,
      |                                   end_stream=end_stream)
      +         stream.send_headers(response_headers, end_stream=end_stream)
      +         self._send_pending_data()
      |         return True
      |
      |     def send_response(self, stream_id, status, headers, body=None):
      |         """Send a response on a stream.
      |
      |         Args:
      |             stream_id: The stream ID to respond on
      |             status: HTTP status code (int)
      |             headers: List of (name, value) header tuples
      |             body: Optional response body bytes
      |
      |         Raises:
      |             HTTP2Error: If stream not found or in invalid state
      |
      |         Returns:
      |             bool: True if response sent, False if stream was already closed
      |         """
      -         stream = self.streams.get(stream_id)
      -         if stream is None:
      -             # Stream was already cleaned up (reset/closed) - return gracefully
      -             return False
      -
      -         # Build response headers with :status pseudo-header
      -         response_headers = [(':status', str(status))]
      -         for name, value in headers:
      -             # HTTP/2 headers must be lowercase
      -             response_headers.append((name.lower(), str(value)))
      |         end_stream = body is None or len(body) == 0
      |         try:
      -             # Send headers
      -             self.h2_conn.send_headers(stream_id, response_headers, end_stream=end_stream)
      - ⟨            ⟩stream.send_⟨headers⟩(response_headers, ⟨end_stream=end_stream)⟩
      -             self._send_pending_data()
      -
      +             if not self.send_response_headers(stream_id, status, headers,
      +                                               end_stream=end_stream):
      +                 return False
      |             # Send body if present
      |             if body and len(body) > 0:
      |                 self.send_data(stream_id, body, end_stream=True)
      |             return True
      |         except _h2_exceptions.StreamClosedError:
      |             # Stream was reset by client - clean up gracefully
      +             stream = self.streams.get(stream_id)
      +             if stream is not None:
      +                 stream.close()
      |             self.cleanup_stream(stream_id)
      |             return False
    ]])
  end)

  -- The setup is byte for byte in both tests and difftastic handed it to
  -- the sibling. Neither reading contradicts itself, so the tie goes to
  -- the one that keeps the line in step with the agreed row above it.
  it("does not hand a test's setup to a sibling below that repeats it", function()
    drawn([[
      class TestDefaults:
          def test_default_scheme(self):
              conn = MockConnection()
              stream = HTTP2Stream(stream_id=1, connection=conn)
              stream.receive_headers([
                  (':method', 'GET'),
                  (':path', '/'),
                  (':authority', 'example.com'),
              ], end_stream=True)

              cfg = MockConfig()
              req = HTTP2Request(stream, cfg, ('127.0.0.1', 12345))

              assert req.scheme == 'https'

          def test_default_path(self):
              conn = MockConnection()
              stream = HTTP2Stream(stream_id=1, connection=conn)
              stream.receive_headers([
                  (':method', 'GET'),
                  (':scheme', 'https'),
                  (':authority', 'example.com'),
              ], end_stream=True)

              cfg = MockConfig()
              req = HTTP2Request(stream, cfg, ('127.0.0.1', 12345))

              assert req.uri == '/'
              assert req.path == '/'
    ]], [[
      class TestDefaults:
          def test_default_scheme(self):
              conn = MockConnection()
              stream = HTTP2Stream(stream_id=1, connection=conn)
              stream.receive_headers([
                  (':method', 'GET'),
                  (':path', '/'),
                  (':authority', 'example.com'),
              ], end_stream=True)

              cfg = MockConfig()
              req = HTTP2Request(stream, cfg, ('127.0.0.1', 12345))

              # Derived from the transport, not assumed to be https.
              assert req.scheme == 'http'

          def test_default_scheme_over_tls(self):
              conn = MockConnection()
              stream = HTTP2Stream(stream_id=1, connection=conn)
              stream.receive_headers([
                  (':method', 'GET'),
                  (':path', '/'),
                  (':authority', 'example.com'),
              ], end_stream=True)

              cfg = MockConfig()
              cfg.set('certfile', __file__)
              cfg.set('keyfile', __file__)
              req = HTTP2Request(stream, cfg, ('127.0.0.1', 12345))

              assert req.scheme == 'https'

          def test_default_path(self):
              conn = MockConnection()
              stream = HTTP2Stream(stream_id=1, connection=conn)
              stream.receive_headers([
                  (':method', 'GET'),
                  (':scheme', 'https'),
                  (':authority', 'example.com'),
              ], end_stream=True)

              cfg = MockConfig()
              req = HTTP2Request(stream, cfg, ('127.0.0.1', 12345))

              assert req.uri == '/'
              assert req.path == '/'
    ]], [[
      | class TestDefaults:
      |     def test_default_scheme(self):
      |         conn = MockConnection()
      |         stream = HTTP2Stream(stream_id=1, connection=conn)
      |         stream.receive_headers([
      |             (':method', 'GET'),
      |             (':path', '/'),
      |             (':authority', 'example.com'),
      |         ], end_stream=True)
      |
      |         cfg = MockConfig()
      |         req = HTTP2Request(stream, cfg, ('127.0.0.1', 12345))
      |
      +         # Derived from the transport, not assumed to be https.
      +         assert req.scheme == 'http'
      +
      +     def test_default_scheme_over_tls(self):
      +         conn = MockConnection()
      +         stream = HTTP2Stream(stream_id=1, connection=conn)
      +         stream.receive_headers([
      +             (':method', 'GET'),
      +             (':path', '/'),
      +             (':authority', 'example.com'),
      +         ], end_stream=True)
      +
      +         cfg = MockConfig()
      +         cfg.set('certfile', __file__)
      +         cfg.set('keyfile', __file__)
      +         req = HTTP2Request(stream, cfg, ('127.0.0.1', 12345))
      |
      |         assert req.scheme == 'https'
      |
      |     def test_default_path(self):
      |         conn = MockConnection()
      |         stream = HTTP2Stream(stream_id=1, connection=conn)
      |         stream.receive_headers([
      |             (':method', 'GET'),
      |             (':scheme', 'https'),
      |             (':authority', 'example.com'),
      |         ], end_stream=True)
      |
      |         cfg = MockConfig()
      |         req = HTTP2Request(stream, cfg, ('127.0.0.1', 12345))
      |
      |         assert req.uri == '/'
      |         assert req.path == '/'
    ]])
  end)

  -- ...and the tie the other way round: the line diff hands the old body
  -- to the sibling, difftastic keeps it under its own `def`, and stands.
  it("keeps a body under its own def when a sibling below takes its job", function()
    drawn([[
      class C:
          async def _send(self, queue_frames):
              """Queue frames on h2 and put them on the wire.

              Streams are served by concurrent tasks, so encoding and writing
              happen under one lock with no await between them: the receive
              loop cannot parse a GOAWAY (which clears h2's outbound buffer)
              in between, and HEADERS leave in the order they were encoded.
              Waiting for the transport happens after the lock is released.
              """
              async with self._lock():
                  queue_frames()
                  self._write_locked()
              await self._drain()

          async def _send_pending_data(self):
              """Send whatever h2 already has queued."""
              async with self._lock():
                  self._write_locked()
              await self._drain()

          def _write_locked(self):
              """Hand h2's pending bytes to the transport. Never waits."""
              data = self.h2_conn.data_to_send()
              if data:
                  try:
                      self.writer.write(data)
                  except (OSError, IOError) as e:
                      self._closed = True
                      raise HTTP2ConnectionError(f"Socket write error: {e}")

          async def _drain(self):
    ]], [[
      class C:
          async def _send(self, queue_frames):
              """Queue frames on h2 and put them on the wire.

              Streams are served by concurrent tasks, so encoding and writing
              happen under one lock with no await between them: the receive
              loop cannot parse a GOAWAY (which clears h2's outbound buffer)
              in between, and HEADERS leave in the order they were encoded.
              Waiting for the transport happens after the lock is released.
              """
              async with self._lock():
                  queue_frames()
                  wrote = self._write_locked()
              if wrote:
                  await self._drain()

          async def _send_pending_data(self):
              """Send whatever h2 already has queued and wait for the transport."""
              async with self._lock():
                  wrote = self._write_locked()
              if wrote:
                  await self._drain()

          async def _write_pending(self):
              """Send whatever h2 already has queued, without waiting.

              Used by the receive loop: what it has to send are control frames
              (SETTINGS and PING acknowledgements, WINDOW_UPDATE, RST_STREAM,
              GOAWAY), and waiting for the transport there would stop the
              connection from reading. Backpressure belongs on the response
              path, where the volume is.
              """
              async with self._lock():
                  self._write_locked()

          def _write_locked(self):
              """Hand h2's pending bytes to the transport. Never waits.

              Returns:
                  bool: True if there was anything to write
              """
              data = self.h2_conn.data_to_send()
              if not data:
                  return False
              try:
                  self.writer.write(data)
              except (OSError, IOError) as e:
    ]], [[
      | class C:
      |     async def _send(self, queue_frames):
      |         """Queue frames on h2 and put them on the wire.
      |
      |         Streams are served by concurrent tasks, so encoding and writing
      |         happen under one lock with no await between them: the receive
      |         loop cannot parse a GOAWAY (which clears h2's outbound buffer)
      |         in between, and HEADERS leave in the order they were encoded.
      |         Waiting for the transport happens after the lock is released.
      |         """
      |         async with self._lock():
      |             queue_frames()
      |             ⟦wrote =⟧ self._write_locked()
      +         if wrote:
      |         ⟦    ⟧await self._drain()
      |
      |     async def _send_pending_data(self):
      - ⟨        """Send whatever h2 already has queued."""⟩
      ~         """Send whatever h2 already has queued⟦ and wait for the transport⟧."""
      |         async with self._lock():
      |             ⟦wrote =⟧ self._write_locked()
      +         if wrote:
      |         ⟦    ⟧await self._drain()
      |
      +     async def _write_pending(self):
      +         """Send whatever h2 already has queued, without waiting.
      +
      +         Used by the receive loop: what it has to send are control frames
      +         (SETTINGS and PING acknowledgements, WINDOW_UPDATE, RST_STREAM,
      +         GOAWAY), and waiting for the transport there would stop the
      +         connection from reading. Backpressure belongs on the response
      +         path, where the volume is.
      +         """
      +         async with self._lock():
      +             self._write_locked()
      |
      |     def _write_locked(self):
      - ⟨        """Hand h2's pending bytes to the transport. Never waits."""⟩
      ~         """Hand h2's pending bytes to the transport. Never waits.
      +
      +         Returns:
      +             bool: True if there was anything to write
      ~         """
      |         data = self.h2_conn.data_to_send()
      |         if ⟦not⟧ data:
      +             return False
      |         try:
      |             self.writer.write(data)
      |         except (OSError, IOError) as e:
      -                 self._closed = True
      -                 raise HTTP2ConnectionError(f"Socket write error: {e}")
      -
      -     async def _drain(self):
    ]])
  end)

  -- difftastic held more identical lines than the line diff, every one
  -- the shared `try:`/`finally:` trailer. Counted over lines the old side
  -- has once, the line diff's reading wins.
  it("does not draw an untouched test added for sharing a trailer", function()
    drawn([[
      class TestH2CFallback:
          def test_http1_request_falls_back_and_parses(self):
              """A plain HTTP/1.1 request must be served untouched, including
              the bytes consumed while sniffing the preface."""
              request = b"GET /ping HTTP/1.1\r\nHost: example.com\r\n\r\n"
              conn, client = make_conn(h2c_config(), request)
              try:
                  conn.init()
                  assert conn.is_http2 is False
                  req = next(conn.parser)
                  assert req.method == "GET"
                  assert req.path == "/ping"
              finally:
                  conn.sock.close()
                  client.close()
          def test_uwsgi_protocol_not_sniffed(self):
              """The uwsgi protocol has its own parser; h2c must not touch it."""
              cfg = h2c_config()
              cfg.set("protocol", "uwsgi")
              conn, client = make_conn(cfg, gthread.H2C_PREFACE)
              try:
                  conn.init()
                  assert conn.is_http2 is False
              finally:
                  conn.sock.close()
                  client.close()
    ]], [[
      class TestH2CTrustedPeerRejection:
          """A trusted peer on a prior-knowledge port must speak HTTP/2.

          Anything else is rejected with InvalidH2CPreface (mapped to a 400 by
          the worker) instead of being silently downgraded to HTTP/1.x.
          """

          def test_http1_request_rejected(self):
              request = b"GET /ping HTTP/1.1\r\nHost: example.com\r\n\r\n"
              conn, client = make_conn(h2c_config(), request)
              try:
                  with pytest.raises(InvalidH2CPreface):
                      conn.init()
              finally:
                  conn.sock.close()
                  client.close()
          def test_http1_from_untrusted_peer_parses(self):
              """Untrusted h1 traffic is byte-for-byte unaffected by the flag."""
              request = b"GET /ping HTTP/1.1\r\nHost: example.com\r\n\r\n"
              conn, client = make_conn(h2c_config(), request, addr=UNTRUSTED_ADDR)
              try:
                  conn.init()
                  assert conn.is_http2 is False
                  req = next(conn.parser)
                  assert req.method == "GET"
                  assert req.path == "/ping"
              finally:
                  conn.sock.close()
                  client.close()


      class TestH2CProtocolGuard:
          def test_uwsgi_protocol_not_sniffed(self):
              """The uwsgi protocol has its own parser; h2c must not touch it."""
              cfg = h2c_config()
              cfg.set("protocol", "uwsgi")
              conn, client = make_conn(cfg, gthread.H2C_PREFACE)
              try:
                  conn.init()
                  assert conn.is_http2 is False
              finally:
                  conn.sock.close()
                  client.close()
    ]], [[
      - ⟨class ⟩TestH2CFallback⟨:⟩
      - ⟨    def ⟩test_http1_request_falls_back_and_parses⟨(self):⟩
      -         """A plain HTTP/1.1 request must be served untouched, including
      -         the bytes consumed while sniffing the preface."""
      | class ⟦TestH2CTrustedPeerRejection⟧:
      +     """A trusted peer on a prior-knowledge port must speak HTTP/2.
      +
      +     Anything else is rejected with InvalidH2CPreface (mapped to a 400 by
      +     the worker) instead of being silently downgraded to HTTP/1.x.
      ~     """
      |
      |     def ⟦test_http1_request_rejected⟧(self):
      |         request = b"GET /ping HTTP/1.1\r\nHost: example.com\r\n\r\n"
      |         conn, client = make_conn(h2c_config(), request)
      |         try:
      +             with pytest.raises(InvalidH2CPreface):
      +                 conn.init()
      +         finally:
      +             conn.sock.close()
      +             client.close()
      +     def test_http1_from_untrusted_peer_parses(self):
      +         """Untrusted h1 traffic is byte-for-byte unaffected by the flag."""
      +         request = b"GET /ping HTTP/1.1\r\nHost: example.com\r\n\r\n"
      +         conn, client = make_conn(h2c_config(), request, addr=UNTRUSTED_ADDR)
      +         try:
      |             conn.init()
      |             assert conn.is_http2 is False
      |             req = next(conn.parser)
      |             assert req.method == "GET"
      |             assert req.path == "/ping"
      |         finally:
      |             conn.sock.close()
      |             client.close()
      |
      |
      + class TestH2CProtocolGuard:
      |     def test_uwsgi_protocol_not_sniffed(self):
      |         """The uwsgi protocol has its own parser; h2c must not touch it."""
      |         cfg = h2c_config()
      |         cfg.set("protocol", "uwsgi")
      |         conn, client = make_conn(cfg, gthread.H2C_PREFACE)
      |         try:
      |             conn.init()
      |             assert conn.is_http2 is False
      |         finally:
      |             conn.sock.close()
      |             client.close()
    ]])
  end)

  -- difftastic handed each test to the one before it, so the kept test's
  -- `def`, docstring and last assert -- each the only copy in its file --
  -- were misattributed twice, which counts for the line diff's reading.
  it("keeps a test that had a new one put in above it unmarked", function()
    drawn([[
      class TestAsync:
          @pytest.mark.asyncio
          async def test_async_read_message_too_large(self):
              """Test async read rejects too-large messages."""
              reader = asyncio.StreamReader()
              # Create a header claiming an absurdly large message
              header = struct.pack(
                  DirtyProtocol.HEADER_FORMAT,
                  DirtyProtocol.MAX_MESSAGE_SIZE + 1000
              )
              reader.feed_data(header)
              reader.feed_eof()

              with pytest.raises(DirtyProtocolError) as exc_info:
                  await DirtyProtocol.read_message_async(reader)
              assert "too large" in str(exc_info.value)

          @pytest.mark.asyncio
          async def test_async_read_empty_message(self):
              """Test async read rejects empty messages."""
              reader = asyncio.StreamReader()
              header = struct.pack(DirtyProtocol.HEADER_FORMAT, 0)
              reader.feed_data(header)
              reader.feed_eof()

              with pytest.raises(DirtyProtocolError) as exc_info:
                  await DirtyProtocol.read_message_async(reader)
              assert "Empty message" in str(exc_info.value)
    ]], [[
      class TestAsync:
          @pytest.mark.asyncio
          async def test_async_read_invalid_magic(self):
              """Test async read rejects invalid magic."""
              reader = asyncio.StreamReader()
              header = b"XX" + bytes([VERSION, MSG_TYPE_REQUEST]) + b"\x00" * 12
              reader.feed_data(header)
              reader.feed_eof()

              with pytest.raises(DirtyProtocolError) as exc_info:
                  await BinaryProtocol.read_message_async(reader)
              assert "magic" in str(exc_info.value).lower()

          @pytest.mark.asyncio
          async def test_async_read_message_too_large(self):
              """Test async read rejects too-large messages."""
              reader = asyncio.StreamReader()
              header = struct.pack(HEADER_FORMAT, MAGIC, VERSION, MSG_TYPE_REQUEST,
                                   MAX_MESSAGE_SIZE + 1000, 0)
              reader.feed_data(header)
              reader.feed_eof()

              with pytest.raises(DirtyProtocolError) as exc_info:
                  await BinaryProtocol.read_message_async(reader)
              assert "too large" in str(exc_info.value)
    ]], [[
      | class TestAsync:
      |     @pytest.mark.asyncio
      +     async def test_async_read_invalid_magic(self):
      +         """Test async read rejects invalid magic."""
      +         reader = asyncio.StreamReader()
      +         header = b"XX" + bytes([VERSION, MSG_TYPE_REQUEST]) + b"\x00" * 12
      +         reader.feed_data(header)
      +         reader.feed_eof()
      +
      +         with pytest.raises(DirtyProtocolError) as exc_info:
      +             await BinaryProtocol.read_message_async(reader)
      +         assert "magic" in str(exc_info.value).lower()
      +
      +     @pytest.mark.asyncio
      |     async def test_async_read_message_too_large(self):
      |         """Test async read rejects too-large messages."""
      |         reader = asyncio.StreamReader()
      -         # Create a header claiming an absurdly large message
      -         header = struct.pack(
      -             DirtyProtocol.HEADER_FORMAT,
      - ⟨            ⟩DirtyProtocol.⟨MAX_MESSAGE_SIZE + 1000⟩
      -         )
      +         header = struct.pack(HEADER_FORMAT, MAGIC, VERSION, MSG_TYPE_REQUEST,
      |                              ⟦MAX_MESSAGE_SIZE + 1000,⟧ 0)
      |         reader.feed_data(header)
      |         reader.feed_eof()
      |
      |         with pytest.raises(DirtyProtocolError) as exc_info:
      - ⟨            await ⟩Dirt⟨yProtocol.read_message_async(reader)⟩
      |             await ⟦Binar⟧yProtocol.read_message_async(reader)
      |         assert "too large" in str(exc_info.value)
      -     @pytest.mark.asyncio
      -     async def test_async_read_empty_message(self):
      -         """Test async read rejects empty messages."""
      -         reader = asyncio.StreamReader()
      -         header = struct.pack(DirtyProtocol.HEADER_FORMAT, 0)
      -         reader.feed_data(header)
      -         reader.feed_eof()
      -
      -         with pytest.raises(DirtyProtocolError) as exc_info:
      -             await DirtyProtocol.read_message_async(reader)
      -         assert "Empty message" in str(exc_info.value)
    ]])
  end)

  -- One line is enough where the file says it once...
  it("does not draw a comment line moved below a new block as moved", function()
    drawn([[
      class P:
                          exc_to_raise = RuntimeError("Response already started")
                          return
                      response_started = True
                      response_status = message["status"]
                      response_headers = message.get("headers", [])

                      # Check if Content-Length or Transfer-Encoding is present
                      has_content_length = False
                      has_transfer_encoding = False
                      for name, _ in response_headers:
                          name_lower = name.lower() if isinstance(name, str) else name.lower()
                          if name_lower in (b"content-length", "content-length"):
                              has_content_length = True
                          elif name_lower in (b"transfer-encoding", "transfer-encoding"):
                              has_transfer_encoding = True
                              use_chunked = True  # Framework already set chunked encoding

                      # Use chunked encoding for HTTP/1.1 streaming responses without Content-Length.
                      # Skip when the response cannot carry a body (HEAD/1xx/204/304) or when
                      # Transfer-Encoding was already set by the framework.
                      is_no_body = self._response_omits_body(request.method, response_status)
                      needs_chunked = (
                          not has_content_length
                          and not has_transfer_encoding
                          and request.version >= (1, 1)
                          and not is_no_body
                      )
    ]], [[
      class P:
                      if response_started:
                          exc_to_raise = RuntimeError("Response already started")
                          return
                      response_started = True
                      response_status = message["status"]
                      response_headers = message.get("headers", [])

                      # Check if Content-Length or Transfer-Encoding is present
                      has_content_length = False
                      has_transfer_encoding = False
                      for name, _ in response_headers:
                          name_lower = name.lower() if isinstance(name, str) else name.lower()
                          if name_lower in (b"content-length", "content-length"):
                              has_content_length = True
                          elif name_lower in (b"transfer-encoding", "transfer-encoding"):
                              has_transfer_encoding = True
                              use_chunked = True  # Framework already set chunked encoding

                      # RFC 9110 forbids a body for HEAD requests and for 1xx/204/304
                      # status codes.  When the framework supplied Content-Length or
                      # Transfer-Encoding for such a response, drop them and force
                      # plain framing so we never emit a chunked terminator or a
                      # framework-supplied body.
                      omits_body = self._response_omits_body(request.method, response_status)
                      if omits_body and (has_content_length or has_transfer_encoding):
                          response_headers = self._strip_body_framing_headers(response_headers)
                          has_content_length = False
                          has_transfer_encoding = False
                          use_chunked = False

                      # Use chunked encoding for HTTP/1.1 streaming responses without Content-Length.
                      # Skip when the response cannot carry a body or when Transfer-Encoding was
                      # already set by the framework.
                      needs_chunked = (
                          not has_content_length
                          and not has_transfer_encoding
                          and request.version >= (1, 1)
                          and not omits_body
                      )
                      if needs_chunked:
                          use_chunked = True
                          response_headers = list(response_headers) + [(b"transfer-encoding", b"chunked")]
    ]], [[
      | class P:
      +                 if response_started:
      |                     exc_to_raise = RuntimeError("Response already started")
      |                     return
      |                 response_started = True
      |                 response_status = message["status"]
      |                 response_headers = message.get("headers", [])
      |
      |                 # Check if Content-Length or Transfer-Encoding is present
      |                 has_content_length = False
      |                 has_transfer_encoding = False
      |                 for name, _ in response_headers:
      |                     name_lower = name.lower() if isinstance(name, str) else name.lower()
      |                     if name_lower in (b"content-length", "content-length"):
      |                         has_content_length = True
      |                     elif name_lower in (b"transfer-encoding", "transfer-encoding"):
      |                         has_transfer_encoding = True
      |                         use_chunked = True  # Framework already set chunked encoding
      |
      +                 # RFC 9110 forbids a body for HEAD requests and for 1xx/204/304
      +                 # status codes.  When the framework supplied Content-Length or
      +                 # Transfer-Encoding for such a response, drop them and force
      +                 # plain framing so we never emit a chunked terminator or a
      +                 # framework-supplied body.
      +                 omits_body = self._response_omits_body(request.method, response_status)
      +                 if omits_body and (has_content_length or has_transfer_encoding):
      +                     response_headers = self._strip_body_framing_headers(response_headers)
      +                     has_content_length = False
      +                     has_transfer_encoding = False
      +                     use_chunked = False
      |
      |                 # Use chunked encoding for HTTP/1.1 streaming responses without Content-Length.
      - ⟨                # Skip when the response cannot carry a body ⟩(HEAD/1xx/204/304) ⟨or when⟩
      -                 # Transfer-Encoding was already set by the framework.
      -                 is_no_body = self._response_omits_body(request.method, response_status)
      ~                 # Skip when the response cannot carry a body or when Transfer-Encoding was
      +                 # already set by the framework.
      |                 needs_chunked = (
      |                     not has_content_length
      |                     and not has_transfer_encoding
      |                     and request.version >= (1, 1)
      - ⟨                    and not ⟩is_no⟨_body⟩
      |                     and not ⟦omits⟧_body
      |                 )
      +                 if needs_chunked:
      +                     use_chunked = True
      +                     response_headers = list(response_headers) + [(b"transfer-encoding", b"chunked")]
    ]])
  end)

  -- ...but not where the reading it carries splits a line from its
  -- reindented self.
  it("keeps a block wrapped in a new try: reindented as one line moves out", function()
    drawn({
      "    async def test_flow(self):",
      "",
      "            # Create arbiter",
      "            arbiter = DirtyArbiter(cfg=cfg, log=log, socket_path=arbiter_socket_path)",
      "            arbiter.pid = os.getpid()",
      "",
      "            # Register worker",
      "            fake_pid = 12345",
      "            arbiter.workers[fake_pid] = worker",
      "            arbiter.worker_sockets[fake_pid] = worker_socket_path",
      "",
      "            # Route a request",
      "            request = make_request(",
      '                request_id="full-flow-test",',
      '                app_path="tests.support_dirty_app:TestDirtyApp",',
      '                action="compute",',
      "                args=(7, 3),",
      '                kwargs={"operation": "multiply"}',
      "            )",
      "",
      "            response = await arbiter.route_request(request)",
      "",
      '            assert response["type"] == DirtyProtocol.MSG_TYPE_RESPONSE',
      '            assert response["result"] == 21',
      "",
      "            # Cleanup - close arbiter's connection first",
      "            arbiter._close_worker_connection(fake_pid)",
      "            worker_server.close()",
      "            await worker_server.wait_closed()",
      "            worker._cleanup()",
      "            arbiter._cleanup_sync()",
    }, {
      "    async def test_flow(self):",
      '            arbiter_socket_path = os.path.join(tmpdir, "arbiter.sock")',
      '            worker_socket_path = os.path.join(tmpdir, "worker.sock")',
      "",
      "            worker = None",
      "            arbiter = None",
      "            worker_server = None",
      "            fake_pid = 12345",
      "",
      "            try:",
      "                # Create worker",
      "                worker = DirtyWorker(",
      "                    age=1,",
      "                    ppid=os.getpid(),",
      '                    app_paths=["tests.support_dirty_app:TestDirtyApp"],',
      "                    cfg=cfg,",
      "                    log=log,",
      "                    socket_path=worker_socket_path",
      "                )",
      "                worker.pid = os.getpid()",
      "                worker.load_apps()",
      "",
      "                # Start worker server",
      "                worker_server = await asyncio.start_unix_server(",
      "                    worker.handle_connection,",
      "                    path=worker_socket_path",
      "                )",
      "",
      "                # Create arbiter",
      "                arbiter = DirtyArbiter(cfg=cfg, log=log, socket_path=arbiter_socket_path)",
      "                arbiter.pid = os.getpid()",
      "                arbiter.alive = True",
      "",
      "                # Register worker",
      "                arbiter.workers[fake_pid] = worker",
      "                arbiter.worker_sockets[fake_pid] = worker_socket_path",
      "",
      "                # Route a request using MockStreamWriter",
      "                request = make_request(",
      '                    request_id="full-flow-test",',
      '                    app_path="tests.support_dirty_app:TestDirtyApp",',
      '                    action="compute",',
      "                    args=(7, 3),",
      '                    kwargs={"operation": "multiply"}',
      "                )",
      "",
      "                mock_writer = MockStreamWriter()",
      "                await arbiter.route_request(request, mock_writer)",
      "",
      "                assert len(mock_writer.messages) == 1",
      "                response = mock_writer.messages[0]",
      '                assert response["type"] == DirtyProtocol.MSG_TYPE_RESPONSE',
      '                assert response["result"] == 21',
      "            finally:",
    }, [[
      |     async def test_flow(self):
      +             arbiter_socket_path = os.path.join(tmpdir, "arbiter.sock")
      +             worker_socket_path = os.path.join(tmpdir, "worker.sock")
      +
      +             worker = None
      +             arbiter = None
      +             worker_server = None
      +             fake_pid = 12345
      +
      +             try:
      +                 # Create worker
      +                 worker = DirtyWorker(
      +                     age=1,
      +                     ppid=os.getpid(),
      +                     app_paths=["tests.support_dirty_app:TestDirtyApp"],
      +                     cfg=cfg,
      +                     log=log,
      +                     socket_path=worker_socket_path
      +                 )
      +                 worker.pid = os.getpid()
      +                 worker.load_apps()
      +
      +                 # Start worker server
      +                 worker_server = await asyncio.start_unix_server(
      +                     worker.handle_connection,
      +                     path=worker_socket_path
      +                 )
      +
      ~             ⟦    ⟧# Create arbiter
      |             ⟦    ⟧arbiter = DirtyArbiter(cfg=cfg, log=log, socket_path=arbiter_socket_path)
      |             ⟦    ⟧arbiter.pid = os.getpid()
      -             # Register worker
      -             fake_pid = 12345
      |                 ⟦arbiter.alive = True⟧
      |
      +                 # Register worker
      |             ⟦    ⟧arbiter.workers[fake_pid] = worker
      |             ⟦    ⟧arbiter.worker_sockets[fake_pid] = worker_socket_path
      |
      ~                 # Route a request⟦ using MockStreamWriter⟧
      |             ⟦    ⟧request = make_request(
      |                 ⟦    ⟧request_id="full-flow-test",
      |                 ⟦    ⟧app_path="tests.support_dirty_app:TestDirtyApp",
      |                 ⟦    ⟧action="compute",
      |                 ⟦    ⟧args=(7, 3),
      |                 ⟦    ⟧kwargs={"operation": "multiply"}
      |             ⟦    ⟧)
      |
      +                 mock_writer = MockStreamWriter()
      - ⟨            ⟩response =⟨ await arbiter.route_request(request)⟩
      |                 await arbiter.route_request(request⟦, mock_writer⟧)
      |
      +                 assert len(mock_writer.messages) == 1
      +                 response = mock_writer.messages[0]
      |             ⟦    ⟧assert response["type"] == DirtyProtocol.MSG_TYPE_RESPONSE
      |             ⟦    ⟧assert response["result"] == 21
      -
      -             # Cleanup - close arbiter's connection first
      -             arbiter._close_worker_connection(fake_pid)
      -             worker_server.close()
      -             await worker_server.wait_closed()
      -             worker._cleanup()
      -             arbiter._cleanup_sync()
      +             finally:
    ]])
  end)

  -- The untouched import was paired with the new one and drawn removed
  -- above itself. The line diff matches one row of three -- but it is a
  -- statement, not a row of an atom difftastic pairs by position.
  it("keeps an import that stayed while the list around it changed", function()
    drawn([[
      class TestHTTP2WindowOverflowHandling:
          """Test window overflow handling."""

          def test_window_overflow_sends_goaway(self):
              """Test that window overflow results in GOAWAY with FLOW_CONTROL_ERROR."""
              from gunicorn.http2.connection import HTTP2ServerConnection
              from gunicorn.http2.errors import HTTP2ErrorCode

              cfg = MockConfig()
    ]], [[
      class TestHTTP2WindowOverflowHandling:
          """A peer sending past the receive window gets GOAWAY(FLOW_CONTROL_ERROR)."""

          def test_window_overflow_sends_goaway(self):
              from hyperframe.frame import DataFrame
              from gunicorn.http2.connection import HTTP2ServerConnection

              cfg = MockConfig()
    ]], [[
      | class TestHTTP2WindowOverflowHandling:
      -     """Test window overflow handling."""
      +     """A peer sending past the receive window gets GOAWAY(FLOW_CONTROL_ERROR)."""
      |
      |     def test_window_overflow_sends_goaway(self):
      -         """Test that window overflow results in GOAWAY with FLOW_CONTROL_ERROR."""
      |         from ⟦hyperframe.frame⟧ import ⟦DataFrame⟧
      |         from gunicorn.http2.connection import HTTP2ServerConnection
      - ⟨        from gunicorn.http2.⟩errors⟨ import ⟩HTTP2ErrorCode
      |
      |         cfg = MockConfig()
    ]])
  end)

  -- As a fold onto the dedented row above, the outer `finally:`'s
  -- removal came back with the row's own old self drawn above it.
  it("does not draw a row only dedented as removed above itself", function()
    drawn([[
      def f(resp):
          try:
              try:
                  resp.write()
                  resp.close()
              finally:
                  t = now()
                  log(resp, t)
          finally:
              if resp:
                  resp.done()
    ]], [[
      def f(resp):
          try:
              resp.write()
              resp.close()
          finally:
              t = now()
              log(resp, t)
              if resp:
                  resp.done()
    ]], [[
      | def f(resp):
      |     try:
      -         try:
      |         resp.write()
      |         resp.close()
      |     finally:
      |         t = now()
      |         log(resp, t)
      -     finally:
      |         if resp:
      |             resp.done()
    ]])
  end)

  -- The line diff matched the blanks, which count for nothing, and so
  -- nothing; the comment was drawn removed above the rows put in and
  -- added under them.
  it("keeps a comment a blank line crossed", function()
    drawn([[
      class AsyncRequest:
          async def _parse(self):
              """Parse the request from the unreader."""
              buf = io.BytesIO()
              await self._get_data(buf, stop=True)

              # Get request line
              line, rbuf = await self._read_line(buf, self.limit_request_line)

              # Proxy protocol
              if self._proxy_protocol(bytes_to_str(line)):
                  # Get next request line
                  buf = io.BytesIO()
                  buf.write(rbuf)
                  line, rbuf = await self._read_line(buf, self.limit_request_line)

              self._parse_request_line(line)
              buf = io.BytesIO()
              buf.write(rbuf)

              # Headers
              data = buf.getvalue()

              while True:
                  idx = data.find(b"\r\n\r\n")
                  done = data[:2] == b"\r\n"
    ]], [[
      class AsyncRequest:
          async def _parse(self):
              """Parse the request from the unreader."""
              buf = bytearray()
              await self._read_into(buf, stop=True)

              # Handle proxy protocol if enabled and this is the first request
              mode = self.cfg.proxy_protocol
              if mode != "off" and self.req_number == 1:
                  buf = await self._handle_proxy_protocol(buf, mode)

              # Get request line
              line, buf = await self._read_line(buf, self.limit_request_line)

              self._parse_request_line(line)

              # Headers
              data = bytes(buf)

              while True:
                  idx = data.find(b"\r\n\r\n")
    ]], [[
      | class AsyncRequest:
      |     async def _parse(self):
      |         """Parse the request from the unreader."""
      - ⟨        buf = ⟩io.BytesIO⟨()⟩
      |         buf = ⟦bytearray⟧()
      - ⟨        await self.⟩_get_data⟨(buf, stop=True)⟩
      |         await self.⟦_read_into⟧(buf, stop=True)
      |
      +         # Handle proxy protocol if enabled and this is the first request
      |         ⟦mode⟧ = self.⟦cfg.proxy_protocol⟧
      |         if ⟦mode != "off" and self.req_number == 1⟧:
      +             buf = await self._handle_proxy_protocol(buf, mode)
      |
      |         # Get request line
      - ⟨        line, ⟩r⟨buf = await self._read_line(buf, self.limit_request_line)⟩
      ~         line, buf = await self._read_line(buf, self.limit_request_line)
      |
      -         # Proxy protocol
      -         if self._proxy_protocol(bytes_to_str(line)):
      -             # Get next request line
      -             buf = io.BytesIO()
      -             buf.write(rbuf)
      - ⟨            line, ⟩rbuf⟨ = await self._read_line(buf, self.limit_request_line)⟩
      |         self._parse_request_line(line)
      -         buf = io.BytesIO()
      -         buf.write(rbuf)
      |
      |         # Headers
      - ⟨        data = ⟩buf.getvalue⟨()⟩
      |         data = ⟦bytes⟧(buf)
      |
      |         while True:
      |             idx = data.find(b"\r\n\r\n")
      -             done = data[:2] == b"\r\n"
    ]])
  end)

  -- The block slides across the identical decorators to where it starts
  -- after a blank line, as git draws it.
  it("draws a test put in under the same decorators added with its own", function()
    drawn([[
      @mock.patch('os.getpid')
      @mock.patch('os.unlink')
      def test_close_delete(unlink, getpid):
          gsock.close(False)
          unlink.assert_called_with('test.sock')


      @mock.patch('os.getpid')
      @mock.patch('os.unlink')
      def test_not_deleted_by_worker(unlink, getpid):
          getpid.return_value = 'fake'
          gsock.close(False)
          unlink.assert_not_called()
    ]], [[
      @mock.patch('os.getpid')
      @mock.patch('os.unlink')
      def test_close_delete(unlink, getpid):
          gsock.close(False)
          unlink.assert_called_with('test.sock')


      @mock.patch('os.getpid')
      @mock.patch('os.unlink')
      def test_close_keep(unlink, getpid):
          gsock.close(True)
          unlink.assert_not_called()


      @mock.patch('os.getpid')
      @mock.patch('os.unlink')
      def test_not_deleted_by_worker(unlink, getpid):
          getpid.return_value = 'fake'
          gsock.close(False)
          unlink.assert_not_called()
    ]], [[
      | @mock.patch('os.getpid')
      | @mock.patch('os.unlink')
      | def test_close_delete(unlink, getpid):
      |     gsock.close(False)
      |     unlink.assert_called_with('test.sock')
      |
      |
      + @mock.patch('os.getpid')
      + @mock.patch('os.unlink')
      + def test_close_keep(unlink, getpid):
      +     gsock.close(True)
      +     unlink.assert_not_called()
      |
      |
      | @mock.patch('os.getpid')
      | @mock.patch('os.unlink')
      | def test_not_deleted_by_worker(unlink, getpid):
      |     getpid.return_value = 'fake'
      |     gsock.close(False)
      |     unlink.assert_not_called()
    ]])
  end)

  it("and taken out again, removed with its own decorators", function()
    drawn([[
      @mock.patch('os.getpid')
      @mock.patch('os.unlink')
      def test_close_delete(unlink, getpid):
          gsock.close(False)
          unlink.assert_called_with('test.sock')


      @mock.patch('os.getpid')
      @mock.patch('os.unlink')
      def test_close_keep(unlink, getpid):
          gsock.close(True)
          unlink.assert_not_called()


      @mock.patch('os.getpid')
      @mock.patch('os.unlink')
      def test_not_deleted_by_worker(unlink, getpid):
          getpid.return_value = 'fake'
          gsock.close(False)
          unlink.assert_not_called()
    ]], [[
      @mock.patch('os.getpid')
      @mock.patch('os.unlink')
      def test_close_delete(unlink, getpid):
          gsock.close(False)
          unlink.assert_called_with('test.sock')


      @mock.patch('os.getpid')
      @mock.patch('os.unlink')
      def test_not_deleted_by_worker(unlink, getpid):
          getpid.return_value = 'fake'
          gsock.close(False)
          unlink.assert_not_called()
    ]], [[
      | @mock.patch('os.getpid')
      | @mock.patch('os.unlink')
      | def test_close_delete(unlink, getpid):
      |     gsock.close(False)
      |     unlink.assert_called_with('test.sock')
      |
      |
      - @mock.patch('os.getpid')
      - @mock.patch('os.unlink')
      - def test_close_keep(unlink, getpid):
      -     gsock.close(True)
      -     unlink.assert_not_called()
      | @mock.patch('os.getpid')
      | @mock.patch('os.unlink')
      | def test_not_deleted_by_worker(unlink, getpid):
      |     getpid.return_value = 'fake'
      |     gsock.close(False)
      |     unlink.assert_not_called()
    ]])
  end)

  -- A blank row of a string is a row of its atom; taken as one it was
  -- banded dim, the one stripe in a green block reading as what stayed.
  it("draws a blank line in an added docstring added with it", function()
    drawn([[
      def load_py(fname):
          module_name = '__config__'
          mod = types.ModuleType(module_name)
          setattr(mod, 'uri', uri)
          setattr(mod, 'cfg', Config())
          loader = importlib.machinery.SourceFileLoader(module_name, fname)
          loader.exec_module(mod)
          # Use Python parser for tests to ensure consistent validation behavior
          # (set after loading so test-specific configs don't override)
          mod.cfg.set('http_parser', 'python')
          return vars(mod)
    ]], [[
      def load_py(fname, http_parser='python'):
          """Load test configuration from Python file.

          Args:
              fname: Path to the .py configuration file
              http_parser: Parser to use - 'python' or 'fast'
          """
          module_name = '__config__'
          mod = types.ModuleType(module_name)
          setattr(mod, 'uri', uri)
          setattr(mod, 'cfg', Config())
          loader = importlib.machinery.SourceFileLoader(module_name, fname)
          loader.exec_module(mod)
          # Set parser after loading so test-specific configs don't override
          mod.cfg.set('http_parser', http_parser)
          return vars(mod)
    ]], [[
      | def load_py(fname⟦, http_parser='python'⟧):
      +     """Load test configuration from Python file.
      +
      +     Args:
      +         fname: Path to the .py configuration file
      +         http_parser: Parser to use - 'python' or 'fast'
      +     """
      |     module_name = '__config__'
      |     mod = types.ModuleType(module_name)
      |     setattr(mod, 'uri', uri)
      |     setattr(mod, 'cfg', Config())
      |     loader = importlib.machinery.SourceFileLoader(module_name, fname)
      |     loader.exec_module(mod)
      -     # Use Python parser for tests to ensure consistent validation behavior
      - ⟨    ⟩# (set ⟨after loading so test-specific configs don't override⟩)
      +     # Set parser after loading so test-specific configs don't override
      - ⟨    mod.cfg.set('http_parser', ⟩'python'⟨)⟩
      |     mod.cfg.set('http_parser', ⟦http_parser⟧)
      |     return vars(mod)
    ]])
  end)

  -- Joined into one node across the blank row -- right for a docstring's
  -- paragraph break, wrong for comments, which a blank line ends -- the
  -- new comment took the edited one's comparison and was drawn dim.
  it("draws a comment added above an edited one added, not stepped back", function()
    drawn({
      "# -*- coding: utf-8 -",
      "#",
      "# This file is part of gunicorn released under the MIT license.",
      "# See the NOTICE for more information.",
      "",
      "",
      "# we inherit from BaseException here to make sure to not be caucght ",
      "# at application level",
      "class HaltServer(BaseException):",
      "    def __init__(self, reason, exit_status=1):",
    }, [[
      # -*- coding: utf-8 -
      #
      # This file is part of gunicorn released under the MIT license.
      # See the NOTICE for more information.

      # We don't need to call super() in __init__ methods of our
      # BaseException and Exception classes because we also define
      # our own __str__ methods so there is no need to pass 'message'
      # to the base class to get a meaningful output from 'str(exc)'.
      # pylint: disable=super-init-not-called


      # we inherit from BaseException here to make sure to not be caught
      # at application level
      class HaltServer(BaseException):
          def __init__(self, reason, exit_status=1):
    ]], [[
      | # -*- coding: utf-8 -
      | #
      | # This file is part of gunicorn released under the MIT license.
      | # See the NOTICE for more information.
      |
      + # We don't need to call super() in __init__ methods of our
      + # BaseException and Exception classes because we also define
      + # our own __str__ methods so there is no need to pass 'message'
      + # to the base class to get a meaningful output from 'str(exc)'.
      + # pylint: disable=super-init-not-called
      |
      |
      - ⟨# we inherit from BaseException here to make sure to not be cau⟩c⟨ght⟩␣
      ~ # we inherit from BaseException here to make sure to not be caught
      | # at application level
      | class HaltServer(BaseException):
      |     def __init__(self, reason, exit_status=1):
    ]])
  end)

  -- difftastic kept the reindented block, which whitespace cannot hide
  -- from it, and drew the other -- five lines byte for byte the same --
  -- deleted and inserted. The reindented rows did change, so the line
  -- diff's reading undoes nothing true.
  it("keeps a block that stayed while another moved past it", function()
    drawn([[
      class C:
          async def send_data(self, stream_id, data, end_stream=False):
              """Send data on a stream.

              Args:
                  stream_id: The stream ID
                  data: Body data bytes
                  end_stream: Whether this ends the stream

              Returns:
                  bool: True if data sent, False if stream was already closed
              """
              stream = self.streams.get(stream_id)
              if stream is None:
                  return False

              data_to_send = data
              try:
                  while data_to_send:
                      available = self.h2_conn.local_flow_control_window(stream_id)
                      chunk_size = min(available, self.max_frame_size, len(data_to_send))

                      if chunk_size <= 0:
                          # Wait for WINDOW_UPDATE per RFC 7540 Section 6.9.2
                          await self._send_pending_data()
                          available = await self._wait_for_flow_control_window(stream_id)
                          if available <= 0:
                              return False
                          chunk_size = min(available, self.max_frame_size, len(data_to_send))

                      chunk = data_to_send[:chunk_size]
                      data_to_send = data_to_send[chunk_size:]
                      is_final = end_stream and len(data_to_send) == 0

                      self.h2_conn.send_data(stream_id, chunk, end_stream=is_final)
                      await self._send_pending_data()

                  stream.send_data(data, end_stream=end_stream)
                  return True
              except (_h2_exceptions.StreamClosedError, _h2_exceptions.FlowControlError):
                  stream.close()
                  self.cleanup_stream(stream_id)
                  return False
    ]], [[
      class C:
          async def send_data(self, stream_id, data, end_stream=False):
              """Send data on a stream.

              Args:
                  stream_id: The stream ID
                  data: Body data bytes
                  end_stream: Whether this ends the stream

              Returns:
                  bool: True if data sent, False if stream was already closed
              """
              stream = self.streams.get(stream_id)
              if stream is None:
                  return False

              data_to_send = data
              try:
                  while data_to_send:
                      # The window is read and the frame queued under the lock,
                      # so another stream cannot spend the credit in between.
                      async with self._lock():
                          available = self.h2_conn.local_flow_control_window(stream_id)
                          chunk_size = min(available, self.max_frame_size, len(data_to_send))
                          if chunk_size > 0:
                              chunk = data_to_send[:chunk_size]
                              data_to_send = data_to_send[chunk_size:]
                              is_final = end_stream and len(data_to_send) == 0
                              self.h2_conn.send_data(stream_id, chunk, end_stream=is_final)
                              # Bookkeeping goes with the frame, before the
                              # drain: a reset processed meanwhile closes the
                              # stream and must not turn into a send error.
                              stream.send_data(chunk, end_stream=is_final)
                              await self._flush_locked()
                      if chunk_size <= 0:
                          # Wait for WINDOW_UPDATE per RFC 7540 Section 6.9.2
                          available = await self._wait_for_flow_control_window(stream_id)
                          if available <= 0:
                              return False

                  return True
              except (_h2_exceptions.StreamClosedError, _h2_exceptions.FlowControlError):
                  stream.close()
                  self.cleanup_stream(stream_id)
                  return False
    ]], [[
      | class C:
      |     async def send_data(self, stream_id, data, end_stream=False):
      |         """Send data on a stream.
      |
      |         Args:
      |             stream_id: The stream ID
      |             data: Body data bytes
      |             end_stream: Whether this ends the stream
      |
      |         Returns:
      |             bool: True if data sent, False if stream was already closed
      |         """
      |         stream = self.streams.get(stream_id)
      |         if stream is None:
      |             return False
      |
      |         data_to_send = data
      |         try:
      |             while data_to_send:
      +                 # The window is read and the frame queued under the lock,
      +                 # so another stream cannot spend the credit in between.
      +                 async with self._lock():
      |                 ⟦    ⟧available = self.h2_conn.local_flow_control_window(stream_id)
      |                 ⟦    ⟧chunk_size = min(available, self.max_frame_size, len(data_to_send))
      +                     if chunk_size > 0:
      +                         chunk = data_to_send[:chunk_size]
      +                         data_to_send = data_to_send[chunk_size:]
      +                         is_final = end_stream and len(data_to_send) == 0
      +                         self.h2_conn.send_data(stream_id, chunk, end_stream=is_final)
      +                         # Bookkeeping goes with the frame, before the
      +                         # drain: a reset processed meanwhile closes the
      +                         # stream and must not turn into a send error.
      +                         stream.send_data(chunk, end_stream=is_final)
      +                         await self._flush_locked()
      |                 if chunk_size <= 0:
      |                     # Wait for WINDOW_UPDATE per RFC 7540 Section 6.9.2
      -                     await self._send_pending_data()
      |                     available = await self._wait_for_flow_control_window(stream_id)
      |                     if available <= 0:
      |                         return False
      -                     chunk_size = min(available, self.max_frame_size, len(data_to_send))
      |
      -                 chunk = data_to_send[:chunk_size]
      -                 data_to_send = data_to_send[chunk_size:]
      -                 is_final = end_stream and len(data_to_send) == 0
      -
      -                 self.h2_conn.send_data(stream_id, chunk, end_stream=is_final)
      -                 await self._send_pending_data()
      -
      -             stream.send_data(data, end_stream=end_stream)
      |             return True
      |         except (_h2_exceptions.StreamClosedError, _h2_exceptions.FlowControlError):
      |             stream.close()
      |             self.cleanup_stream(stream_id)
      |             return False
    ]])
  end)

  -- The walk after the reflow paired the new comment with a row of the
  -- old dict, so nothing was drawn above it and the comment it replaced
  -- hung below.
  it("draws a dict reflowed onto one line whole, and the comment it displaced", function()
    drawn([[
      class C:
          async def receive(self):  # pylint: disable=too-many-return-statements
              """ASGI receive callable - reads body on demand."""
              # Already finished body - return disconnect
              if self.body_complete:
                  return {"type": "http.disconnect"}

              # No body expected - must return body message before disconnect
              if self.request.content_length == 0 and not self.request.chunked:
                  self.body_complete = True
                  return {
                      "type": "http.request",
                      "body": b"",
                      "more_body": False,
                  }

              # Check for disconnect before reading (only when body hasn't been returned)
              if self.protocol._closed:
                  return {"type": "http.disconnect"}
    ]], [[
      class C:
          async def receive(self):
              """ASGI receive callable - returns body chunks or disconnect."""
              # Already disconnected or body finished
              if self._closed or self._body_finished:
                  return {"type": "http.disconnect"}

              # Fast path: chunk already available
              if self._chunks:
                  chunk = self._chunks.pop(0)
                  more = bool(self._chunks) or not self._complete
                  if not more:
                      self._body_finished = True
                  return {"type": "http.request", "body": chunk, "more_body": more}

              # Body complete with no more chunks
              if self._complete:
                  self._body_finished = True
                  return {"type": "http.request", "body": b"", "more_body": False}

              # No body expected
              if self.request.content_length == 0 and not self.request.chunked:
                  self._complete = True
                  self._body_finished = True
                  return {"type": "http.request", "body": b"", "more_body": False}

              # Check protocol closed state
              if self.protocol._closed:
                  self._closed = True
                  return {"type": "http.disconnect"}
    ]], [[
      | class C:
      - ⟨    async def receive(self):  ⟩# pylint: disable=too-many-return-statements
      - ⟨        """ASGI receive callable - ⟩reads⟨ body ⟩on demand⟨."""⟩
      -         # Already finished body - return disconnect
      - ⟨        if self.⟩body_complete⟨:⟩
      ~     async def receive(self):
      ~         """ASGI receive callable - ⟦returns⟧ body ⟦chunks or disconnect⟧."""
      +         # Already disconnected or body finished
      |         if self.⟦_closed or self._body_finished⟧:
      |             return {"type": "http.disconnect"}
      |
      -         # No body expected - must return body message before disconnect
      +         # Fast path: chunk already available
      +         if self._chunks:
      +             chunk = self._chunks.pop(0)
      +             more = bool(self._chunks) or not self._complete
      +             if not more:
      +                 self._body_finished = True
      +             return {"type": "http.request", "⟨body⟩": chunk, "more_body": more}
      +
      +         # Body complete with no more chunks
      +         if self._complete:
      +             self._body_finished = True
      +             return {"type": "http.request", "⟨body⟩": b"", "more_body": False}
      +
      +         # No body expected
      |         if self.request.content_length == 0 and not self.request.chunked:
      - ⟨            self.⟩body_complete⟨ = True⟩
      |             self.⟦_complete⟧ = True
      +             self._body_finished = True
      |             return {"type": "http.request", "body": b"", "more_body": False}
      |
      -         # Check for disconnect before reading (only when body hasn't been returned)
      +         # Check protocol closed state
      |         if self.protocol._closed:
      +             self._closed = True
      |             return {"type": "http.disconnect"}
    ]])
  end)
end)

-- A docstring gaining two lines in the middle is one changed atom, so
-- difftastic lays the old sentences alongside the new ones in order and
-- the last comes out paired against text it has nothing to do with: red
-- above that line, and the same sentence four rows below drawn as new.
-- Suppressing the red half left the green half claiming a line was added
-- that was already there. The alignment is what is wrong, so it is what
-- is repaired (`realign`).
describe("removed and added back", function()
  if not h.difft then
    pending("difftastic is not installed")
    return
  end

  local kept = "    The diagram is a structural overview: a length says nothing about it."
  local short = {
    "def f(t: str) -> str:",
    '    """Drop a modifier.',
    "",
    kept,
    "    It widens every box that carries one.",
    '    """',
    "    return t",
    "",
  }
  local long = {
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
    "",
  }

  it("is neither for a sentence below lines put into a docstring", function()
    drawn(short, long, [[
      | def f(t: str) -> str:
      |     """Drop a modifier.
      |
      +     This is a fuuul
      +     change that spaaans multiple liiines
      |
      |
      |     The diagram is a structural overview: a length says nothing about it.
      |     It widens every box that carries one.
      |     """
      |     return t
      |
    ]])
  end)

  -- Read the other way round, difftastic pairs each row below the cut
  -- one off, and reported every sentence there as changed and the
  -- closing quotes as removed.
  it("is neither for the sentences below lines taken out of one", function()
    drawn(long, short, [[
      | def f(t: str) -> str:
      |     """Drop a modifier.
      |
      -     This is a fuuul
      -     change that spaaans multiple liiines
      |     The diagram is a structural overview: a length says nothing about it.
      |     It widens every box that carries one.
      |     """
      |     return t
      |
    ]])
  end)

  -- One layer down: the alignment is repaired and the hunk builder then
  -- swallowed the untouched row anyway, as a lone unchanged row between
  -- two changed ones. Between a DELETION and an INSERTION it belongs to
  -- neither, and went red above the identical green row it never left.
  it("is neither for a row between a deletion and an insertion", function()
    local opts_line = [[    \s*(?P<options>.*?)\s*;?\s*$]]
    drawn({
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
      "",
    }, {
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
      "",
    }, [[
      | import re
      |
      | _LOAD_RE = re.compile(
      |     r"""
      |     ^\s*load\s+(?:table\s+)?
      |     \s+(?:from\s+)?
      -     '(?P<path>(?:[^']|'')*)'
      |     \s*(?P<options>.*?)\s*;?\s*$
      +     asdfoo
      |     """,
      |     re.IGNORECASE,
      | )
      |
    ]])
  end)
end)

-- A table gaining fields around one it had is, to difftastic, a node
-- rebuilt: `follow = {` and the field under it come back novel and
-- paired with rows they have nothing to do with. Two rows of seven is
-- what a coincidence in a rewrite looks like, so `realign` refused the
-- line diff there -- but rows identical at the EDGE of the region, next
-- to rows both sides agree on, are not a coincidence.
describe("a rebuilt node", function()
  it("keeps the rows it opens with", function()
    if not h.difft then
      return pending("difftastic is not installed")
    end
    h.drawn({ old = [[
      require("nemeton").setup({
          comments = {
              follow = {
                  commit = uatis.show_commit,
                  link = function(_, href)
                      vim.fn.setreg('+', href)
                      vim.notify("Link content copied", vim.log.levels.INFO)
                  end,
              }
          }
      })

    ]], new = [[
      require("nemeton").setup({
          comments = {
              follow = {
                  commit = uatis.show_commit,
                  url = copy_link,
                  path = copy_link,
              },
              old_side = function(bufnr)
                  local at = uatis.showing(bufnr)
                  if at and at.side == "old" then
                      return { path = at.path, sha = at.rev }
                  end
              end,
          }
      })

    ]] }, [[
      | require("nemeton").setup({
      |     comments = {
      |         follow = {
      |             commit = uatis.show_commit,
      - ⟨            ⟩link⟨ = function(⟩_, href⟨)⟩
      -                 vim.fn.setreg('+', href)
      -                 vim.notify("Link content copied", vim.log.levels.INFO)
      +             url = copy_link,
      +             path = copy_link,
      |         ⟦}⟧,
      |         ⟦old_side⟧ = function(⟦bufnr⟧)
      |             ⟦local at = uatis.showing(bufnr)⟧
      |             ⟦if at and at.side == "old" then⟧
      |                 ⟦return { path = at.path, sha = at.rev }⟧
      +             end
      |         end,
      -         }
      |     }
      | })
      |
    ]])
  end)
end)
