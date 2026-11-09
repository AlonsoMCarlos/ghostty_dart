# Research: libghostty-vt 1.0.0 behaviour that differs from the headers

Date: 2026-11-09. Library: libghostty-vt 1.0.0 (tag `vt-1.0.0`), built locally with `tool/native/build.sh`. Sources read: the headers in `.native-cache/out/x86_64-linux-gnu/include/ghostty/vt/` and the Zig sources in `.native-cache/src/libghostty-vt-1.0.0/src/terminal/`. **[V]** = reproduced by a test in this repo, **[I]** = inferred from the source.

Each finding lists a repro, what the header leads us to expect, what 1.0.0 does, and how `ghostty_vt` deals with it. Findings 1 and 2 are candidates for upstream issues; the others are documentation gaps or ordinary parser behaviour, recorded so nobody rediscovers them.

## 1. Search keeps matches on evicted scrollback pages (upstream issue candidate)

- **[V] Repro** (`test/search/search_review_test.dart`, group "evicted scrollback"):
  1. A 40x5 terminal with unlimited scrollback receives 30 000 lines that all contain `hit`.
  2. `ghostty_search_new` with needle `hit`, then a few `ghostty_search_feed` / `ghostty_search_tick` calls, so the search is still running (not `COMPLETE`).
  3. Lower the scrollback limit (`GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES` = 1200), which frees the oldest pages.
  4. One more `feed` (or `feed` + `tick`), then read `GHOSTTY_SEARCH_DATA_MATCHES`.
- **Expected:** every returned `GhosttySelection` names cells that still exist; `search.h` says results track the terminal and pruned data is cleaned up on feed.
- **Actual:** the result list still holds matches whose `GhosttyGridRef.node` points at pages the terminal has already freed. A later `tick` can even append more of them. **[I]** Formatting or resolving such a match would read freed memory (we never do it: see the workaround).
- **Environment for the report:** libghostty-vt 1.0.0 (`vt-1.0.0`), Linux x86_64, `ReleaseFast`, Zig 0.17.1. The test drives the C API through the Dart bindings; the C call sequence above is the whole repro.
- **[I] Cause:** `ScreenSearch.feed` (`src/terminal/search/screen.zig`) calls `pruneHistory()` only on the branch where the history searcher has no more data (`state = .complete`). While the search is still running, nothing drops `history_results` entries whose pages were pruned. A completed search (or selecting a match, which validates the selected result) does clean them up.
- **Workaround in `ghostty_vt`:** `TerminalSearch._match` checks both ends of every match against the live page list (`isLiveGridRef` in `lib/src/selection/selection_native.dart`: `ghostty_terminal_point_from_grid_ref` on the active screen, then a round trip through `ghostty_terminal_grid_ref`; neither dereferences the page). A match that fails the check is returned already stale (`VtSelection.isValid == false`). Cost: two page-list walks per end, documented on `TerminalSearch.matches`.
- **Upstream report** (suggested title: "search: `GHOSTTY_SEARCH_DATA_MATCHES` returns matches on evicted pages while the search is running"): run `pruneHistory()` on every `feed`, not only on completion, or validate history results before returning them from `GHOSTTY_SEARCH_DATA_MATCHES`.

## 2. Viewport coordinates past the bottom (upstream issue candidate)

- **[V] Repro** (`test/grid/grid_review_test.dart`, "viewport" group): a 10x3 terminal with scrollback, scrolled to the top (`GHOSTTY_TERMINAL_SCROLL_VIEWPORT_TOP`). Take a grid ref of active cell (0, 0), which is now below the visible area, and call `ghostty_terminal_point_from_grid_ref(..., GHOSTTY_POINT_TAG_VIEWPORT, ...)`.
- **Expected:** `GHOSTTY_NO_VALUE`; the header says a cell outside the visible area has no viewport position.
- **Actual:** `GHOSTTY_SUCCESS` with a row past the viewport's bottom (row 18 for a 3-row viewport in the test). Only cells *above* the viewport are rejected.
- **Workaround:** `readPointCoordinate` (`lib/src/grid/grid_ref.dart`) maps a viewport row `>= rows` to `null`. Used by `GridRef.pointIn` and `TrackedGridRef.pointIn`.
- **Upstream report** (suggested title: "`ghostty_terminal_point_from_grid_ref` returns a viewport row below the viewport instead of `GHOSTTY_NO_VALUE`"): reject rows at or past the viewport's bottom as well as rows above it. **[I]** Both this function and the tracked equivalent (`ghostty_tracked_grid_ref_point`, `src/terminal/c/grid_ref_tracked.zig`) go through `PageList.pointFromPin`, which only rejects pins above the viewport's top, so the fix belongs there.

## 3. `PointSpace.history` counts rows like `screen`

- **[V] Repro** (`test/grid/grid_review_test.dart`, "history points count from the oldest row like screen points"; also `grid_ref_test.dart`): with scrollback, `ghostty_terminal_grid_ref` of `GHOSTTY_POINT_TAG_HISTORY` (0, y) and of `GHOSTTY_POINT_TAG_SCREEN` (0, y) name the same cell for every y, and history rows past the scrollback resolve into the active area instead of failing.
- **Expected:** from the header's wording, history row 0 being the oldest scrollback row is right, but a history point past the scrollback should be out of range.
- **[I] Cause:** `getTopLeft(.history) == getTopLeft(.screen)` in the page list, and the history bottom is not enforced.
- **Handling:** documented on `VtTerminalGrid.gridRef` and pinned by tests, so an upstream change is noticed. Not reported yet: it may be intended.

## 4. Long OSC 8 hyperlinks are dropped silently

- **[V] Repro** (`test/grid/grid_review_test.dart`, "an OSC 8 URI over 2046 bytes is dropped silently"): write `ESC ] 8 ; ; <uri> ESC \ x ESC ] 8 ; ; ESC \` to a terminal.
- **Expected:** either the link, or some signal that it was rejected; nothing in the headers mentions a URI limit.
- **Actual:** a URI of up to 2046 bytes (with empty parameters) is kept; from 2047 bytes the whole OSC 8 is ignored: `x` is printed without a link, there is no unknown-sequence callback and the parser returns to ground. Parameters count towards the limit (with `id=abc` the cut-off is lower), so the limit is on the OSC payload, about 2 KiB.
- **Handling:** none needed; pinned by the test. Worth a line in the upstream docs.

## 5. ESC inside an APC string

- **[V] Repro:** with `ghostty_terminal_set(..., UNKNOWN_SEQUENCE_MAX_BYTES, 1000)` and an unknown-sequence callback, write `ESC _ z a ESC 0xFF b ESC \ A`.
- **Actual:** the APC is reported with content `za` (it ends at the `ESC`). `0xFF` is ignored in the escape state, so `b` becomes the escape's final byte (`ESC b`, ignored); the trailing `ESC \` is a lone ST; only `A` is printed. `ESC _ z a 0xFF b ESC \` (no ESC before `0xFF`) reports `za\xffb`.
- **Assessment:** consistent with the DEC/VT500 parser state machine (any `ESC` leaves the control string). Not a bug; recorded because the `ESC`-handling inside control strings surprises people writing tests for `writeUntil` / APC limits.

## 6. Smaller observations

- **`SelectionOrder` mirrored targets:** `ghostty_selection_order` with a mirrored desired order returns the selection unchanged when it already has that order, and otherwise behaves like `FORWARD`. Documented on `VtSelection.ordered`.
- **Two "no limit" conventions:** `CLIPBOARD_WRITE_MAX_BYTES` uses `SIZE_MAX` for "no limit", while the scrollback limits use `GHOSTTY_NO_VALUE` on read. The header documents each; `VtTerminal` maps both to `null`.
- **Tracked grid ref free writes to its terminal:** `ghostty_tracked_grid_ref_free`, `ghostty_search_free` and `ghostty_selection_gesture_free` unregister from (or release cells in) their live terminal, and `ghostty_terminal_free` writes to every still-registered tracked ref and search. The headers say what must outlive what but not that these frees touch another object, which matters for finalizers that run on another thread. Audit of every `_free` in `src/terminal/c/` (2026-11-09) and the finalizer `ghostty_vt` uses for it:

  | Object | `_free` touches | Finalizer |
  |---|---|---|
  | terminal | itself, plus every registered tracked ref and search (clears their back pointer) | `NativeFinalizer` (dependents' tokens keep it alive, see below) |
  | search | its terminal (unregisters, releases tracked pins) | Dart `Finalizer`, token holds the terminal handle |
  | tracked grid ref | its terminal (unregisters, untracks its pin) | Dart `Finalizer`, token holds the terminal handle |
  | selection gesture | its terminal (`gesture.deinit(t)`); two-argument free | Dart `Finalizer`, token holds the terminal handle |
  | formatter, render state and its row/cell/image iterators, key/mouse encoders and events, OSC/SGR parsers, snapshot decoder, kitty placement iterator | only their own memory | `NativeFinalizer` (the kitty iterator is freed in `finally`) |

  A Dart `Finalizer` runs as an event on the owning isolate, never in the middle of a native call; holding the terminal's handle in its token stops the terminal's `NativeFinalizer` from running first. Whether these frees are safe from another thread is worth one sentence in the upstream headers.
