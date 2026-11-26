# uatis inline-diff anomalies

Found by rendering uatis's inline view (structural backend, difftastic 0.69.0,
nvim 0.12.5) headlessly over commits of the gunicorn repository
(`~/projects/gunicorn`), each commit `C` checked out and every changed `.py`
file annotated against `C^`, then cross-checking the extmarks against
`git show C^:path` and `git diff -w C^ C`.

Each entry: commit, file, rows (1-based, new side), what uatis drew, what was
expected. Logged as found, not fixed.


## Status

| # | State | Commit(s) |
|---|---|---|
| 1 | fixed | `7205349` |
| 2 | fixed | `880738d` |
| 3 | fixed | `21fe6de` (and `1edccb3`) |
| 4 | fixed | `4c5cb98` |
| 5 | fixed (`e90b1c2c` `finish_body` by `0176c5e`) | `3c0bef1`, `2cefd21`, `0176c5e` |
| 6 | fixed | `9e8f068` |
| 7 | fixed (cost: a rewrite around a bare `return` is drawn in two pieces, as git does) | `a1e8bce` |
| 8 | `__iter__` fixed by the above; `force_close`/`parse` are 2-line defs, under `diff.move.min_lines` | — |
| 9 | fixed | `398d67b` |
| 10 | fixed | `86ecb9b` |
| 11 | fixed | `7c9edbc` |
| 12 | fixed (`56087c3b` by recounting over lines the old side has once) | `aa0f9c2`, `ed0fc50` |
| 13 | fixed | `4a5024d` |
| 14 | fixed | `6027076` |
| 15 | fixed | `4ff8e59` |
| 16 | fixed | `5abe03d` |
| 17 | fixed | `6e7d079` |
| 18 | fixed | `5c9aa24` |
| 19 | fixed | `0cabf96` |
| 20 | fixed (`3573fd38` `message.py` left as it was: the reading would split a reindented pair) | `0176c5e` |
| 21 | fixed | `02e4d45` |
| 22 | fixed | `0412899` |
| 23 | fixed | `999cedd` |
| 24 | fixed | `be271bc` |

---

## 1. Unchanged row drawn red above itself (between two edited rows)

- **Commit** `049bbf7a` ("Don't append a 500 after the response has already started")
- **Files** `gunicorn/workers/sync.py` row 201, `gunicorn/workers/gthread.py` row 734,
  `gunicorn/workers/base_async.py` row 310 — same shape in all three.
- **Change** (git):
  ```
  -        except Exception:
  +        except BaseException:
               if resp and resp.headers_sent:          <- untouched
  -                # If the requests have already been sent, we should close the
  -                # connection to indicate the error.
  +                # Timeout abort is SystemExit. If we already started the
  +                # response, writing a 500 on the same socket corrupts it.
  ```
- **Drawn** (inline, structural):
  ```
        -|         except Exception:                                   <Delete/DeleteDim>
        -|             if resp and resp.headers_sent:                  <UatisDelete, whole row>
        -|                 # If the requests have already been sent, ...  <UatisDelete>
        -|                 # connection to indicate the error.        <UatisDelete>
    200+|         except BaseException:        (Add on "BaseException")
    201 |             if resp and resp.headers_sent:                  (no mark)
    202+|                 # Timeout abort is SystemExit. ...           (line Add)
    203+|                 # response, writing a 500 ...                (line Add)
  ```
- **Expected**: `if resp and resp.headers_sent:` is not drawn in the before-image at
  all — it is shown removed (full red) directly above the identical row it never left,
  "removed and added back" by yet another route. rules.md §1 ("A lone unchanged row
  between a deletion and an insertion") covers deletion/insertion neighbours and the
  `intact` case; here the neighbours are a *modified* row above and a *replaced comment
  block* below, and the row is still swallowed.
- **Also seen**: `a81c7d66` `gunicorn/http2/async_connection.py` row 602 — the untouched
  `except asyncio.TimeoutError:` is drawn red in the before-image block above row 601,
  directly over its own unchanged twin at 602 (neighbours: modified `wait_for(...)` row
  above, `continue` → `return 0` below).
- **Secondary**: the replaced comment's before-image is hoisted above row 200 (the
  `except` line) instead of sitting above rows 202–203 it was replaced by.

## 2. Two docstrings that each grew are drawn as swapped with each other

- **Commit** `4d2f53cb` ("docs: describe the HTTP/2 review fixes ...")
- **File** `gunicorn/config.py`, `Timeout.desc` (rows 860–879) and `Keepalive.desc` (rows 907–~926).
- **Change** (git): two pure insertions, one paragraph appended at the end of each
  docstring (+8 / +6 lines). Not a byte of either existing docstring changed.
- **Drawn**:
  ```
         | ⇣desc moved to line 907 · 1 change      <UatisMove>
         | ⇣desc moved from line 899 · 1 change    <UatisMove>
    860 |     desc = """\
        -|         The number of seconds to wait for requests on a Keep-Alive connection.   <UatisDelete>
        -|         ... (whole Keepalive docstring, red)
    861 |         Workers silent for more than ... killed and restarted.   (line UatisAdd)
        ... every pre-existing Timeout row painted UatisAdd ...
  ```
  and the mirror image at `Keepalive.desc` (row 907): the old Timeout docstring in red,
  the unchanged Keepalive rows painted green, plus "moved from line 860 / moved to line 860".
- **Expected**: two in-place appends — only rows 871–878 and the new Keepalive rows
  marked, no move markers. The move matcher pairs `desc` in class A with `desc` in
  class B (same assignment name, both "changed"), so each docstring is shown replaced by
  the *other* class's old text. Two contradicting markers ("moved to 907" and
  "moved from 899") sit on the same row 860.
- Likely general: any two sibling classes/settings whose identically named attribute
  (`desc`, `name`, …) both change in one commit.

## 3. Removing a class header: an unchanged method drawn as both rewritten and deleted, a stationary one as "moved"

- **Commit** `01fda640` ("http2: stream errors stay on the stream ...")
- **File** `tests/test_http2_config.py`, rows 112–128.
- **Change** (git): `test_zero_value` replaced by `test_zero_value_is_rejected`, and the
  two header lines `class TestHttp2InitialWindowSize:` + its docstring deleted, so the
  methods below now continue the previous class. `test_default_value` and
  `test_set_custom_value` are byte-identical and in the same order.
- **Drawn**:
  ```
         | ⇣test_default_value moved from line 123 · unchanged    <UatisMove>
    118 |     def test_default_value(self):
        ...
        -|     def test_zero_value(self):                               <Delete>
        -|         # Zero is technically valid ...                      <Delete>
    123 |     def test_set_custom_value(self):        (Add on "test_set_custom_value")
        -|         c.set("http2_max_concurrent_streams", 0)             <Delete>
    125 |         c.set("http2_initial_window_size", 131072)   (Add on most of the row)
        -|         assert c.http2_max_concurrent_streams == 0           <Delete>
    126 |         assert c.http2_initial_window_size == 131072 (Add)
        -| class TestHttp2InitialWindowSize:                            <Delete>
        -|     """Test http2_initial_window_size ..."""                 <Delete>
        -|     def test_set_custom_value(self):                         <Delete>   <- again
        -|         c = Config()                                         <Delete>
        -|         c.set("http2_initial_window_size", 131072)           <Delete>
        -|         assert c.http2_initial_window_size == 131072         <Delete>
         | ⇡test_default_value moved to line 118 · unchanged
    128 |     def test_set_from_string(self):
  ```
- **Expected**: `test_set_custom_value` unmarked; the removed `test_zero_value` drawn red
  above `test_zero_value_is_rejected` (which is itself fully green at 112–116, so the old
  method's before-image is drawn far from its replacement); the two class-header lines
  red; no move marker on `test_default_value`.
- **Contradictions in one view**: the same unchanged method is (a) shown as an edit of
  `test_zero_value` at 123–126 and (b) shown as wholly deleted at 127; the "moved"
  marker claims a move for a method that kept its position relative to its neighbours
  (only its parent class header vanished), and the marker pair labels both ends with
  rows of the *new* file (123 vs 118) such that "moved from line 123" points at
  `test_set_custom_value`.

## 4. A kept comment drawn deleted, and re-added green a few rows lower

- **Commit** `1faf6b70` ("http2: serve Upgrade: h2c on the gthread and gevent workers")
- **File** `gunicorn/workers/gthread.py`, rows 508–516.
- **Change** (git): five rows inserted before `# Handle the request` (untouched), and the
  `keepalive = …` block under it collapsed into `return self._keepalive_after(...)`.
- **Drawn**:
  ```
        -|             # Handle the request                           <UatisDelete>
        -|             keepalive = self.handle_request(req, conn)     <Delete/DeleteDim>
        -|             ... (rest of old block, red)
    509+|             settings = None                    (Add)
        ...
    515 |             # Handle the request               (line UatisAdd)
    516+|             return self._keepalive_after(...)  (Add)
  ```
- **Expected**: `# Handle the request` unmarked, before-image of the `keepalive` block
  above row 516. The comment row is shown removed and then shown added verbatim six
  rows lower — the "both cannot be true" case rules.md §1 says `realign` repairs — and
  the whole before-image is hoisted above the inserted `settings` block (row 509)
  rather than above what replaced it.

## 5. Docstring with one paragraph reworded: untouched rows drawn red above themselves, unchanged rows lit green

- **Commits / files**
  - `58b38a06` `gunicorn/http2/async_connection.py` rows 838–846 (`_send` docstring)
  - `2d5f01f0` `gunicorn/http2/connection.py` rows 430–441 and
    `gunicorn/http2/async_connection.py` rows ~402–409 (`_handle_connection_terminated`)
- **Change** (git): inside a multi-line docstring only the middle paragraph changed; the
  opening line, the blank line, `Args:` / `event: ConnectionTerminated event` and the
  closing `"""` are byte-identical.
- **Drawn** (`58b38a06`):
  ```
        -|         """Queue frames on h2 and put them on the wire.   <UatisDelete, full strength>
        -|                                                           <UatisDelete>
        -|         Streams are served ... (4 rows)                   <Delete/DeleteDim>
        -|         """                                               <UatisDelete>
    839 |         """Queue frames on h2 and put them on the wire.   (line UatisAddDim)
    840 |
    841+|  ... reworded rows                                         (Add on changed words)
    846 |         """                                               (no mark)
  ```
  `2d5f01f0` `connection.py`: the whole old docstring is drawn red (12 rows, including
  the identical `Args:`, `event: ConnectionTerminated event`, `"""`), and below it the
  unchanged row 439 `Args:` carries a **full-strength `UatisAdd`** line highlight and row
  440 a `UatisAdd` range over `event:`.
- **Expected**: per rules.md §2 `quiet_unchanged` / `intact`, rows identical on both sides
  are not drawn in the before-image and not lit as added. Here half the before-image is
  rows still on screen (drawn in full red directly above their own twins), and unchanged
  text is painted at full add strength. The same situation is also drawn
  inconsistently: the opening docstring line is `UatisDeleteDim` in `2d5f01f0` but full
  `UatisDelete` in `58b38a06`; the closing `"""` is red in the before-image while its
  twin is unmarked.
- **Also seen**: `e8150e27` `gunicorn/asgi/parser.py` rows 4–10 (module docstring
  reworded): opening `"""` drawn `UatisDeleteDim` above its identical twin (row 5,
  `UatisAddDim`), closing `"""` drawn full `UatisDelete`, blank row 7 painted full
  `UatisAdd`.
- **Also seen**: `20cfaf10` `tests/test_asgi_invalid_requests.py` rows 91–98 (class
  docstring, first line identical: drawn full red above its `UatisAddDim` twin; closing
  `"""` red); `e90b1c2c` `gunicorn/http/parser.py` rows 37–50 (`finish_body`: def
  line gained parameters, docstring partly reworded — the before-image holds the whole
  old def, docstring and the first four body rows, including the identical docstring
  opening line, blank, and `if self.mesg:` / `try:` rows).

## 6. Function split in two: the kept function drawn wholly deleted above the new one and wholly added below it

- **Commit** `ab626467` ("http2: stream WSGI responses instead of buffering them")
- **File** `gunicorn/http2/connection.py`, rows 401–475.
- **Change** (git): `send_response_headers()` and `end_stream()` inserted *above* the
  existing `send_response()`; `send_response()` keeps its `def` line and its whole
  14-row docstring byte-identical, its body now calls `send_response_headers`.
- **Drawn**:
  ```
        -|     def send_response(self, stream_id, status, headers, body=None):   <Delete>
        -|         """Send a response on a stream.                               <Delete>
        -|         ... the full old docstring, red (14 rows)
    401+|     def send_response_headers(self, stream_id, status, headers,  (Add on name)
        ...  rows 409–424 (new send_response_headers body): no mark at all
    450 |     def send_response(self, stream_id, status, headers, body=None):  (line UatisAdd)
    451 |         """Send a response on a stream.                             (line UatisAdd)
        ... every row of the unchanged docstring + `end_stream = ...` + `try:` painted
            full UatisAdd through row 475
  ```
- **Expected**: `send_response`'s `def` and docstring unmarked (git and the
  `content_survives`/`intact`/`moved_to` rules all agree they did not change); the new
  functions marked as added. What is drawn instead is the same 15 rows shown red at 401
  *and* green at 450 with no move marker linking them — the "removed here and added
  back further down" contradiction, at function scale. The new `send_response_headers`
  body (409–424) gets no mark, so the actually-new code reads as old.
- **Also seen**: `3e2167c3` `gunicorn/asgi/protocol.py` rows 499–524 — a helper
  (`_handle_h1c_parse_error`) inserted above `data_received`, and `_feed_callback_parser`
  extracted below it. The unchanged first eleven rows of `data_received` (def, docstring,
  websocket/reader branches, 499–509) are painted full `UatisAdd`, and the same eleven
  rows are drawn red above the new `_feed_callback_parser` at 517, as if
  `data_received` had been renamed into it.

## 7. An unchanged import line shown red above itself and re-lit as an edit of a different import

- **Commit** `da7d2e38` ("http2: stream the request body to the application")
- **File** `tests/test_http2_connection.py`, rows 933–935.
- **Change** (git): the docstring line and `from gunicorn.http2.errors import
  HTTP2ErrorCode` removed, `from hyperframe.frame import DataFrame` added;
  `from gunicorn.http2.connection import HTTP2ServerConnection` is untouched (git keeps
  it as context).
- **Drawn**:
  ```
        -|         """Test that window overflow results in GOAWAY ..."""         <Delete>
        -|         from gunicorn.http2.connection import HTTP2ServerConnection  <Delete/DeleteDim>
        -|         from gunicorn.http2.errors import HTTP2ErrorCode             <Delete/DeleteDim>
    934+|         from hyperframe.frame import DataFrame          (Add on "hyperframe.frame", "DataFrame")
    935 |         from gunicorn.http2.connection import HTTP2ServerConnection
                                                       (Add on "connection" and "HTTP2ServerConnection")
  ```
- **Expected**: row 935 unmarked and not in the before-image. It is drawn removed
  (red, directly above) *and* lit as if `errors`→`connection` and
  `HTTP2ErrorCode`→`HTTP2ServerConnection` had been typed into it — the identical line
  was re-paired with the deleted `errors` import (`fitted`/`refit` picking the wrong
  partner by resemblance when an exact twin exists).

## 8. Methods reordered: not detected as moves, drawn removed above and re-added below

- **Commit** `da7d2e38`, **file** `gunicorn/http2/request.py`, rows 157–166.
- **Change**: `__iter__` (def line + docstring identical) now comes after the new
  `close()` instead of before `__len__`/`close`; its body changed.
- **Drawn**: old `def __iter__(self):` / `"""Iterate over lines in the body."""` red
  above row 157 (the new `close`), and the identical rows 162–163 painted green
  (`UatisAdd` on `__iter__`, line `UatisAdd` on the docstring). No `⇣ moved` marker,
  although moves.lua does mark the swapped `desc` blocks in #2 and an unchanged method
  in #3.
- **Expected**: either a move marker for `__iter__`, or the def/docstring left unmarked
  where git aligns them; not the same two rows drawn both deleted and added in one view.
- **Also seen**: `391dbc78` `gunicorn/http/message.py` — `force_close()` / `parse()` moved
  ~125 rows down: drawn red above the new `_peer_is_trusted_proxy` at row 199 and green
  at 323–327, no move marker. Below that, the unchanged `def parse_headers(...)` and its
  first rows (329–333) are painted full `UatisAdd`, while fragments of the *old*
  `parse_headers` body (`# Consume value continuation lines..`, the obs-fold loop, …)
  are drawn red interleaved between rows of the new class body (above 323, 329, 334),
  i.e. under the wrong method.

## 9. Unchanged block under a new nested block: drawn red above it and painted green below it

- **Commit** `da7d2e38` ("http2: stream the request body to the application")
- **File** `gunicorn/http2/async_connection.py`, rows 599–618 (`send_data` loop).
- **Change** (git): 15 rows inserted above `if chunk_size <= 0:`; inside that `if`, one
  row (`await self._send_pending_data()`) removed and the trailing `chunk_size = min(...)`
  removed. `if chunk_size <= 0:`, its comment, `available = await …`,
  `if available <= 0:`, `return False` are git context (unchanged, same indent).
- **Drawn**:
  ```
    603+|                     chunk_size = min(available, ...)       (Add)
        -|                 if chunk_size <= 0:                        <UatisDelete>
        -|                     # Wait for WINDOW_UPDATE ...           <UatisDelete>
        -|                     await self._send_pending_data()        <UatisDelete>
        -|                     available = await self._wait_for_flow_control_window(stream_id)  <UatisDelete>
        -|                     if available <= 0:                     <UatisDelete>
        -|                         return False                       <UatisDelete>
        -|                     chunk_size = min(...)                  <Delete/DeleteDim>
    604+|                     if chunk_size > 0:
        ...
    614 |                 if chunk_size <= 0:                        (line UatisAdd)
    615 |                     # Wait for WINDOW_UPDATE ...           (line UatisAdd)
    616 |                     available = await ...                  (line UatisAdd)
    617 |                     if available <= 0:                     (line UatisAdd)
    618 |                         return False                       (line UatisAdd)
  ```
- **Expected**: rows 614–618 unmarked, with only `await self._send_pending_data()` (and
  the old `chunk_size = min(...)`) in a before-image at 615/619. As drawn, five
  untouched rows are shown both deleted and added, and the one row that really went is
  buried among them ten rows away from where it was. Same family as #4/#6, at block size;
  difft apparently pairs the old `if` block with the new nested `if chunk_size > 0:` and
  `realign` does not repair it.

## 10. A multi-line dict collapsed to one line: its before-image torn in two, tail orphaned under a blank row

- **Commit** `78184011`, **file** `gunicorn/asgi/protocol.py`, rows 205–213.
- **Change** (git):
  ```
  -            return {
  -                "type": "http.request",
  -                "body": b"",
  -                "more_body": False,
  -            }
  +            return {"type": "http.request", "body": b"", "more_body": False}   (row 211)
  ```
  (an identical new one-liner was also added at row 205, in a new `if self._complete:` block).
- **Drawn**:
  ```
    205+|             return {"type": "http.request", "body": b"", "more_body": False}   (UatisAddDim on cols 45-49 …)
        ...
    211+|             return {"type": "http.request", "body": b"", "more_body": False}   (no mark)
    212 |
        -|                 "body": b"",           <UatisDeleteDim>
        -|                 "more_body": False,    <UatisDeleteDim>
        -|             }                          <UatisDeleteDim>
        -|                                        <UatisDeleteDim>
        -|         # Check for disconnect before reading (...)   <UatisDelete>
    213+|         # Check protocol closed state
  ```
- **Expected**: the reflow of one statement read as one thing — either no before-image
  (`content_survives`, as the three identical reflows at rows 223/227/233 in the same
  file get) or the whole five-row dict above row 211. Instead its first two rows
  (`return {`, `"type": …`) are matched to the *other* one-liner at row 205, and the
  last three are hung under the blank row 212, between two unrelated statements,
  as a fragment that does not parse on its own. The same edit is drawn three ways in
  one file (nothing / torn / dim-band on a different row).

## 11. A local variable assignment treated as a moved definition, 1200 rows away, and its in-place edit left unmarked

- **Commit** `0ca0d0cb`, **file** `gunicorn/asgi/protocol.py`, row 286 ↔ row 1481.
- **Change** (git): inside `_read_with_disconnect_check`, the local
  ```
  -                chunk = await asyncio.wait_for(
  -                    self.request.read_body(65536),
  -                    timeout=0.1
  -                )
  +                chunk = await self.request.read_body(65536)
  ```
  and, in an unrelated new method ~1200 rows lower, a new local
  `chunk = await asyncio.wait_for(stream.read_body_chunk(), timeout=30.0)`.
- **Drawn**:
  ```
         | ⇣chunk moved to line 1481 · 1 change     <UatisMove>
    286+|                 chunk = await self.request.read_body(65536)    (no mark at all)
  ...
         | ⇡chunk moved from line 282 · 1 change    <UatisMove>
   1481+|                 chunk = await asyncio.wait_for(
        -|                     self.request.read_body(65536),   <Delete>
   1482+|                     stream.read_body_chunk(),        (Add)
        -|                     timeout=0.1                      <Delete>
   1483+|                     timeout=30.0                     (Add)
  ```
- **Expected**: no move. `chunk` is a function-local in two different methods; the
  move matcher (moves.lua / xmoves.lua) keys on the assigned name as if it were a
  definition. The consequence is worse than a spurious marker: row 286 — a real edit
  — carries no mark and no before-image, so reading the function in place it looks
  unchanged, while the old 4-row call is shown being edited inside a different
  function.

## 12. Function split in two, again: the kept function's unchanged body painted added, its old copy drawn removed inside the new one

Same family as #6, in cases `prefer_lines` does not take.

- **Commit** `ce2e06ce`, **file** `gunicorn/dirty/arbiter.py`, rows 239–248 and 294–317.
- **Change** (git): `route_request` keeps its def, its docstring (bar two reworded
  lines) and its first ten body rows byte-identical (`request_id = ...`,
  `# Find an available worker`, `worker_pid = await ...`, the `if worker_pid is None:`
  return); below them its lock-and-send tail is replaced by a queue, and the old tail
  reappears, reworked, as the new `_execute_on_worker` 50 rows lower.
- **Drawn**: rows 239–248 painted full `UatisAdd` (unchanged rows, git context); the
  same ten rows drawn red under row 295, inside `_execute_on_worker`, between its
  `request_id = ...` and its `try:`.
- **Expected**: rows 239–248 unmarked; only the replaced tail drawn removed.
- **Also seen**:
  - `391dbc78` `tests/test_http2_request.py` rows 552–580: `test_default_scheme`'s
    def is unmarked, its byte-identical body (553–563) is painted full `UatisAdd`, and
    the new `test_default_scheme_over_tls` inserted below it gets `UatisAdd` on its
    name only. Its body (568–576, all new to git) has no mark at all, so the new test
    reads as old code and the old test reads as new.
  - `56087c3b` `tests/test_http2_h2c.py` rows 205–230: `test_uwsgi_protocol_not_sniffed`
    is unchanged and only gains a new `class TestH2CProtocolGuard:` header above it.
    It is drawn red at 205 (its old rows lent to `test_unix_socket_peer_is_trusted`,
    206–216) and painted full `UatisAdd` at 220–230. The same file's rows 131–133 and
    187–189 are painted added while their old copies are drawn red 30–50 rows away.

## 13. A kept comment drawn removed, then added back a few rows lower (with other matches around it)

Same as #4, in a region where other lines also match, so the fix for #4
(which needs *every* solid match to be deleted-and-inserted) does not apply.

- **Commit** `f3190f84`, **file** `gunicorn/asgi/message.py`, rows 135–149.
- **Change** (git): a proxy-protocol block above `# Get request line` is replaced by
  four new rows; `# Get request line` itself is untouched (git context), and the
  `line, rbuf = ...` under it becomes `line, buf = ...`.
- **Drawn**:
  ```
        -|         # Get request line                              <UatisDelete>
        -|         line, rbuf = await self._read_line(...)          <UatisDelete>
        -|         ... old proxy-protocol block                     <UatisDelete>
    138+|         # Handle proxy protocol if enabled ...          (Add)
        ...
    143 |         # Get request line                              (line UatisAdd)
    144+|         line, buf = await self._read_line(...)          (Add on "buf")
  ```
- **Expected**: row 143 unmarked and absent from the before-image; the old
  `line, rbuf = ...` paired with row 144 (it is drawn as an edit there anyway).

## 14. Indentation marks of a wrapped block stop at its first blank line

- **Commit** `4e3245a0`, **file** `gunicorn/http2/async_connection.py`, rows 376–385.
- **Change** (git): the body of `send_response` from `# Send headers` to the
  `send_data` call is wrapped in a new `try:` (row 376); every row moves right by four,
  otherwise byte-identical. A blank row (381) sits inside the wrapped block.
- **Drawn**: rows 377–380 get the 4-column `UatisAdd` indent mark
  (rules.md, "Indentation a wrapping pushed a block by"); rows 382–384, after the blank
  row, get nothing, so half the wrapped block reads as untouched.
- **Expected**: all of 377–384 marked alike. The gate ("a hunk directly above the
  run") is evidently satisfied only by the first paragraph; a blank row inside the
  block ends the run, which rules.md does not say.
- **Also seen**: same commit, `async_connection.py` rows 464–471 (after the blank row
  463, inside the `try:`-wrapped `while`) and `gunicorn/http2/connection.py` rows
  419–421 and 513–520; `56cc094b` `gunicorn/dirty/arbiter.py` rows 255–278
  (`async with worker_lock:` wraps 23 rows: 255–257 marked, 259–278 after the blank
  row 258 not).

## 15. A deleted top-level block hung under the last line of the previous one, above the blank rows that separated them

- **Commit** `201df19a`, **file** `tests/test_http2_alpn.py`, row 353.
- **Change** (git): the whole `class TestEventletWorkerAlpn` (73 rows) deleted at the
  end of the file. git draws it after the two blank rows that follow
  `TestGeventWorkerAlpn` (`@@ -353,76 +353,3 @@`, the blanks as context).
- **Drawn**: the removed class hangs directly below row 353
  (`mock_super.assert_called_once()`, the last line of the previous class's last
  method), with no gap, and the two blank rows 354–355 come after it. Read top to
  bottom, the deleted class looks like a continuation of the method above.
- **Expected**: the before-image below the blank rows, where the class stood (the
  same slide git's indent heuristic makes).
- **Also seen**: `555d2fa2` `gunicorn/config.py` row 2371 (`class
  TolerateDangerousFraming` hung directly under the previous setting's closing
  `"""`); `e780508f` `tests/docker/asgi_compliance/apps/lifespan_app.py` row 264 (two
  deleted handlers hung under the previous one's `})`) and
  `tests/docker/asgi_compliance/test_lifespan_compliance.py` row 240.

## 16. Blank rows of a wholly removed docstring drawn as surviving, striping the deleted block

- **Commit** `555d2fa2`, **file** `gunicorn/config.py`, row 2371 (the
  `TolerateDangerousFraming` before-image, same block as #15).
- **Drawn** (in a window, where rows are padded to the edge): every row of the deleted
  class is `UatisDeleteBg` to the window edge except the blank rows inside its `desc`
  docstring, which are padded `UatisDeleteDim`. Blank rows *outside* strings in the
  same kind of block (e.g. `e780508f` above) are full `UatisDelete`. The deleted class
  comes out striped, dim bands saying "this row survived" on rows that are gone.
- **Expected**: a row of a block removed whole is drawn removed, blank or not. (The
  blank row is part of a string atom, has no span of its own, and ends up filled in
  the "nothing removed here" colour.)
- **Also seen**: `06aba092` `gunicorn/dirty/app.py` row 78 (the old `Example::`
  section of the class docstring, every blank row in it dim).

## 17. A dedented row drawn in the before-image directly above itself

- **Commit** `858b743d` ("remove double finally") — **files** `gunicorn/workers/sync.py` rows 179–188,
  `gunicorn/workers/gthread.py` rows 335–345, `gunicorn/workers/base_async.py` rows
  111–120 (same edit in all three).
- **Change** (git): an inner `try: ... finally:` is collapsed into the outer one; its
  body moves left by four, and `request_time = ...` / `self.log.access(...)` move from
  the inner `finally:` to the outer one, also left by four.
- **Drawn** (`sync.py`):
  ```
        -|                 try:                                     <UatisDelete>
    180 |                 if isinstance(respiter, ...):             (no mark)
        ...
    186 |             finally:
    187 |                 request_time = datetime.now() - ...      (no mark)
        -|                     self.log.access(resp, req, ...)      <UatisDeleteDim>
        -|             finally:                                     <UatisDelete>
    188 |                 self.log.access(resp, req, ...)          (no mark)
  ```
- **Expected**: `self.log.access(...)` not in the before-image: it is the same
  statement four columns left, and its neighbour `request_time = ...`, which made the
  same move, is drawn without one. As drawn, a removed `finally:` sits between the two
  statements that were moved together, and the access-log line is shown removed and
  kept at once.

---


## 18. A test inserted above another under the same decorators: its decorators drawn as old code, the next test's painted added

- **Commit** `b4dc48dc`, **file** `tests/test_sock.py`, rows 18–29.
- **Change** (git): `test_unix_socket_close_keep_if_no_exlock` (three `@mock.patch`
  decorators, def, body) inserted whole above `test_unix_socket_not_deleted_by_worker`,
  which has the same three decorators.
- **Drawn**: rows 18–20 (the new test's decorators) unmarked; rows 27–29 (the untouched
  test's decorators) painted `UatisAdd`, as though that test had gained them.
- **Expected**: the inserted block slid up across the identical decorators, starting
  after the blank line, as git's slider draws it.

## 19. A test inserted, the one after it removed: every test handed to the one before it

- **Commit** `1665857c`, **file** `tests/test_dirty_protocol.py`, rows 326–350.
- **Change** (git): `test_async_read_invalid_magic` inserted above
  `test_async_read_message_too_large` (def and docstring byte-identical), and
  `test_async_read_empty_message` removed below it.
- **Drawn**: `test_async_read_message_too_large`'s def and docstring red above 327
  (paired with the new test) and edited at 339 (paired with the removed one); the new
  test drawn as a rename of the kept one.
- **Expected**: the new test added whole, the kept test unmarked, the removed test red.
  The kept lines are each the only copy in their file and difftastic pairs them with
  different text at *both* ends, a chain with no unpaired end, which `prefer_lines`
  did not count.

## 20. A comment moved below a new block: its unchanged first line drawn removed and added back

- **Commit** `2191832b`, **file** `gunicorn/asgi/protocol.py`, rows 958–972.
- **Change** (git): a new comment and `if omits_body ...` block inserted above
  `# Use chunked encoding for HTTP/1.1 streaming responses without Content-Length.`,
  which is untouched (git context, row 970); the two comment lines under it reworded.
- **Drawn**: the old three-line comment red above 958 (paired with the new block's
  comment); row 970 dim with `# ` lit.
- **Expected**: row 970 unmarked; only the reworded lines drawn changed. A single
  misattributed line, which `prefer_lines`' two-line minimum ignored.
- **Also**: `e90b1c2c` `finish_body` (#5's exception) and `444b2d82`/`9419d660`/`d530e673`
  `socketfromfd.py` headers resolve the same way.


## 21. A blank row in an added docstring drawn dim, striping the block

- **Commits** `da7d2e38` `gunicorn/http2/stream.py` row 322, `03cc85ef` `tests/treq.py`
  row 38, `ab626467` `gunicorn/http/wsgi.py` row 487, and 115 more rows in 62 files.
- **Drawn**: every row of a new docstring `UatisAdd` except its blank line,
  `UatisAddDim` — the added-side mirror of #16.
- **Expected**: the blank row banded with the block.

## 22. A comment added whole drawn dim, joined across a blank line to an edited one

- **Commit** `76eaa080`, **file** `gunicorn/errors.py`, rows 6–10.
- **Change** (git): a five-line comment added; two rows below, past a blank line, a
  typo fixed in another comment.
- **Drawn**: the five new rows `UatisAddDim` with no before-image ("nothing here is
  new"), having inherited the edited comment's comparison.
- **Expected**: `UatisAdd`. A blank line ends a run of comments; only a string's
  rows carry a node across one. Also `1665857c` `dirty/protocol.py` 531–535, and two
  strings on wholly new lines (`4aaecb8d`, `fa967743`) no longer stepped back.

## 23. Trailing spaces cleared from a long docstring: rows dim with nothing above them

- **Commit** `e98f6a03`, **file** `gunicorn/config.py`, rows 630–634.
- **Change** (git): trailing spaces removed from three rows of a 31-row docstring.
- **Drawn**: the three rows `UatisAddDim`, no before-image. difftastic made the whole
  atom one 31-row hunk, past the 20 rows `lines_correspond` compares row for row, so
  the existing trailing-space rule never saw it and the hunk read as a reflow.
- **Expected**: as for a short one: each row's old line above it with only the
  space red.

## 24. A line split over several rows: its before-image hung between the pieces

- **Commits** `8559854b` `gunicorn/dirty/arbiter.py` rows 575, 648; `f6418d4e`
  `dirty/arbiter.py` row 297; `eda9d456` `config.py` row 2389.
- **Change** (git): `"""Spawn a new dirty worker."""` opened onto several rows; a
  sentence broken in two.
- **Drawn**: the opening `"""` (or the first half) dim and alone, the old line
  below it, above the second piece.
- **Expected**: the old line above where it now begins.

## Coverage and how to reproduce

- Swept the 200 most recent non-merge commits touching `*.py` in gunicorn
  (`git log --no-merges -n 200 -- '*.py'`), modified files only (`--diff-filter=M`).
  All renders completed with the structural backend, no errors on stderr.
- Per commit: `git checkout --detach C` in a scratch worktree, open each file headlessly
  (`nvim --headless -u NONE --cmd 'set packpath=' --cmd 'set rtp+=~/projects/uatis-nvim'`),
  `require("uatis.view").open("C^")`, wait for `view.renders > 0`, dump every extmark in
  `overlay.ns`.
- Automated flags (then each one checked by hand against `git show`): red rows identical
  to an unchanged neighbour; red rows whose identical twin within ±25 rows is painted
  added; rows git calls unchanged that carry `UatisAdd*`; new text with no mark; deleted
  text never drawn. Most "marked added but git says unchanged" flags were git and difft
  picking different alignments inside genuinely rewritten blocks, and are **not** logged.
  Pure insertions with no before-image (`content_survives`) and before-images collected
  above a hunk (`spread_max`) are by design, and are not logged either.
- **Second sweep** (12–17), after 1–11 were fixed: the next 250 commits
  (`git log --no-merges -n 450 -- '*.py' | tail -n +201`, 775 modified files) and the
  first 200 again (447 files), same harness, same flags plus: red rows whose twin
  within ±12 rows is painted `UatisAdd`; runs of ≥3 rows git calls added that carry no
  mark with no before-image beside them. Of ~180 flags, most were genuine statement
  moves (drawn removed and added, honestly), dedents (unmarked by design), or
  alignments where git and difft pick different but equally valid partners; those are
  not logged. No render errored; two files (`glogging.py` at `ed9729a8`, `a7ead983`)
  fell back on parse errors.
- Scripts and per-file text renders were in
  `/tmp/claude-1000/-home-tgilbert-projects-gunicorn/c6f76e48-91eb-4bef-bfbe-cd49686b47ba/scratchpad/`
  (`bin/dump.lua`, `bin/check.py`, `render/`); that is session scratch space and may be gone. The second sweep's harness
  (`dump.lua`, `check.py`, `check2.py`, `show.py <n> <lo> <hi>`) is in
  `/tmp/claude-1000/-home-tgilbert-projects-uatis-nvim/72da2764-1d20-4666-9d9d-37ad600b97df/scratchpad/sw2/` and `sw3/`
  (since wiped; the third sweep's `render.lua`, `check.py`, `redcheck.py`,
  `gitagree.py`, `cmp.sh` are in the same scratchpad, under `all/` and `sw4/`).

- **Third sweep** (18–20): 500 commits further back
  (`git rev-list --no-merges --skip 700 -n 500`, 619 modified files) plus the 1212 of
  the first two, rendered through `overlay.render` and checked against
  `git diff --histogram`: rows git keeps painted added, red lines whose text git never
  removed, and runs of git-added rows with no mark. The older history is clean; what
  remains flagged is statement moves drawn as moves, wholesale rewrites, and
  `desc = """\` in `687b78d2` `config.py`, an unchanged row inside a before-image
  passage (by design: a hole in a passage is worse).

- **Fourth round** (21–24): new checks over the same 1831 files — rows git keeps
  carrying add tokens, reindents drawn as remove-and-add, `UatisAddDim` rows with no
  before-image anywhere above them, a dim row whose old line hangs one row lower —
  and 587 non-Python files (`md`, `yml`, `toml`, `css`, `html`, `ini`), which came
  back clean bar moved HTML sections and generated CSS (moves there are out of scope).
  Move markers (five in 1831 files) were checked against both files; all true.

## Recurring themes

1. **Same row drawn both removed and added** (#1, #4, #5, #6, #8, #9; #12–13, #17 fixed in the second round; #18–20 in the third): an untouched
   row ends up in the before-image *and* is painted or left as its new self. Usually
   difft pairs a node with a different node (an inserted sibling, an extracted helper),
   and `realign`/`intact`/`moved_to` don't recover it.
2. **Move detection keyed on names** (#2, #3, #11): identically named attributes
   (`desc`) or locals (`chunk`) in different scopes are paired as moves, and the false
   move hides the real in-place edit. Meanwhile real reorders of methods (#8) get no
   marker at all.
3. **Exact twin ignored in favour of a resemblance match** (#7, #10): a row with a
   byte-identical old counterpart gets re-paired with a different old row.
4. **Placement and paint of a removal** (#15, #16, fixed): where a before-image hangs
   among blank rows, and what colour a blank row inside it is filled with.
5. **Indentation marks** (#14, fixed): the wrapped-block rule stops at a blank row.
6. **The dim band where nothing explains it** (#21–24, fixed): a row stepped back as
   "not new" with no comparison on screen for it to be the other half of.
