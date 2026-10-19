# uatis inline-diff anomalies

Found by rendering uatis's inline view (structural backend, difftastic 0.69.0,
nvim 0.12.5) headlessly over commits of the gunicorn repository
(`~/projects/gunicorn`), each commit `C` checked out and every changed `.py`
file annotated against `C^`, then cross-checking the extmarks against
`git show C^:path` and `git diff -w C^ C`.

Each entry: commit, file, rows (1-based, new side), what uatis drew, what was
expected. Logged as found, not fixed.

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

---

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
- Scripts and per-file text renders were in
  `/tmp/claude-1000/-home-tgilbert-projects-gunicorn/c6f76e48-91eb-4bef-bfbe-cd49686b47ba/scratchpad/`
  (`bin/dump.lua`, `bin/check.py`, `render/`); that is session scratch space and may be gone.

## Recurring themes

1. **Same row drawn both removed and added** (#1, #4, #5, #6, #8, #9): an untouched
   row ends up in the before-image *and* is painted or left as its new self. Usually
   difft pairs a node with a different node (an inserted sibling, an extracted helper),
   and `realign`/`intact`/`moved_to` don't recover it.
2. **Move detection keyed on names** (#2, #3, #11): identically named attributes
   (`desc`) or locals (`chunk`) in different scopes are paired as moves, and the false
   move hides the real in-place edit. Meanwhile real reorders of methods (#8) get no
   marker at all.
3. **Exact twin ignored in favour of a resemblance match** (#7, #10): a row with a
   byte-identical old counterpart gets re-paired with a different old row.
