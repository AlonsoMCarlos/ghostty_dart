# 0011. `ghostty_dart_flutter` widget architecture

**Status:** Accepted (2026-11-10), with the amendments below. Proposed 2026-11-09. Research: `docs/internal/research/2026-11-09-flutter-rendering.md` and `2026-11-09-flutter-input.md` (2026-11-09). Points marked "to measure" are measured by the benchmark (`benchmarks/widget`) and the grid pixel tests; the frame-time targets below are still unmeasured.

## Context
- No existing Flutter terminal tracks dirty rows. xterm 4.0.0 paints one paragraph per cell and repaints everything on every write. xterm2 also paints per cell. flterm uses a `drawRawAtlas` glyph atlas but publishes no numbers.
- In Flutter 3.47.9, Impeller is the default on every native platform and web uses Skia (CanvasKit or skwasm). Impeller has no raster cache: per-row `RepaintBoundary`s save UI-thread recording only, not raster work.
- libghostty-vt already provides what a renderer and an input layer need:
  - a batched `RenderState` with dirty rows, style runs and a stable `RenderRowId`;
  - a key encoder (legacy and Kitty, including release events), a mouse encoder, and selection gestures;
  - a viewport whose scroll position stays anchored while output arrives.
- Every local pty package (`flutter_pty`, `flutter_pty2`, `pty2`, `portable_pty`) runs native build code on the user's machine. `portable_pty` 0.0.5 is ruled out: its own build hook downloads a prebuilt binary and otherwise builds Rust crates with `native_toolchain_rust` (not `native_prebuilt`, as first noted).
- xterm 4.0.0 binds Ctrl+V and Ctrl+A on Linux, Windows and Android, so the shell never receives them. AGENTS.md forbids that.

## Decision
**Package and API.**
- `packages/ghostty_dart_flutter` depends only on `ghostty_dart` and Flutter.
- It is **pty-agnostic**: bytes come in through `write`, and the user's input goes out through `onOutput`, plus `onResize`.
- Public names carry the `Vt` prefix (conventions §11), because the xterm adapter will export xterm's names:
  - `VtTerminalController`, a `ChangeNotifier` owning the `VtTerminal`, the `RenderState`, the encoders and the selection gesture. It exposes `write`, `sendKey`, `sendText`, `paste`, selection, search highlights and scrolling, which is everything the adapter needs;
  - `VtTerminalView`, the widget;
  - `VtTerminalTheme`, shaped like xterm's `TerminalTheme`. The theme is pushed into the terminal's default colours and palette, so OSC colour queries answer correctly and the painter only reads `RenderColors`.
  - Every other public type of the package carries `Vt` too (`VtCellMetrics`, `VtTerminalKeyToolbar`), although its bare name clashes with nothing: this is broader than conventions §11 on purpose, so the package reads as one uniform surface next to the xterm adapter's unprefixed names.

**Rendering (v1).**
- One repaint-isolated `RenderBox`.
- A cached `Picture` per row, keyed by `RenderRowId`. Only dirty rows are re-recorded, and scrolling reuses pictures because row ids are stable.
- Output only calls `markNeedsPaint`, so the render state updates once per frame. While output is synchronized (`onRenderHold`), the cached pictures are kept.
- Text is drawn as one paragraph per style run, from an LRU cache that disposes what it evicts.
- Wide characters, grapheme clusters, emoji and likely fallback glyphs break the run and are placed at `col * cellWidth`, so they never drift.
- Underline (all five styles), strikethrough and overline are drawn by hand. The cursor and blink are an overlay layer, so they never re-record rows.
- Cell metrics are aligned to device pixels and use a forced strut. Ligatures are off (`liga`, `calt`). The cell size is passed to `terminal.resize`. Whether `letterSpacing = cellWidth - advance` keeps the grid on Impeller, CanvasKit and skwasm is **to measure** first.
- Fonts: JetBrains Mono (OFL-1.1) is bundled in tests for goldens, which run on Linux CI only. The package bundles no font by default; users choose one. The README explains how, and warns about web's default fallback fetch from `fonts.gstatic.com`.

*Amendment (2026-11-10, row reuse and run placement).* Row ids are stable, but dirty flags cannot tell "moved" from "changed": libghostty-vt 1.0.0 rebuilds every row and flags it dirty whenever the viewport pin changes (`src/terminal/render.zig:1022-1024` sets `redraw`; `RowBuilder.row` sets `dirties[vy] = true` unconditionally, `:2684`), so every scroll, including each newline while following output, reports every row dirty; ED 2 also keeps the ids with new content. The renderer therefore keys each cached picture by `RenderRowId` **and** a content key: the draw operations it derives anyway while scanning a dirty row (background spans, selection span and colour, run and cluster texts with their colours, faces and columns, decorations). A dirty row whose scan equals the cached content keeps its picture; colour, theme and column changes rescan every row instead of dropping pictures; only text style, text scaler and cell-metric changes drop everything. Scrolling a 60-row screen by one line now records one row (60 scans). No `ghostty_dart` API was added. Runs are also verified once when laid out: a letter-spaced run whose width is not its cell count times the cell width (within half a device pixel: a fallback font, another face advance, a zero-advance format character) is drawn cell by cell, and U+00AD and combining marks never enter runs. A differential test (warm caches against a cold repaint, after scroll, ED 2, resize, alternate screen, render hold, OSC 4/10/11/12, reverse video, selection and random output) guards both.

**Input.**
- Hardware keys go to `VtKeyEvent`: the physical key through a static USB-HID table, the text, the unshifted codepoint, and the modifiers.
  - Both key-down and key-up events reach the encoder, for Kitty.
  - When AltGr is active, Ctrl and Alt are dropped from the modifiers.
  - Every key the encoder handles returns `handled`, so Tab, Esc and the arrows never reach Flutter's default shortcuts.
- Default shortcuts are never taken from the shell:
  - copy and paste are Ctrl+Shift+C/V and Ctrl+Insert/Shift+Insert on Linux and Windows, and Cmd+C/V on Apple;
  - Ctrl+V and Ctrl+A go to the shell;
  - the xterm adapter keeps xterm's map and documents the difference.
- Text input uses a `DeltaTextInputClient` with a hidden sentinel text:
  - the IME candidate window is placed at the cursor (`getTransformTo`, `setComposingRect`, `setCaretRect`, `viewId`);
  - autocorrect, suggestions and smart punctuation are off;
  - on mobile, deleting the sentinel is detected as Backspace, one per deleted character, and a soft-keyboard `\n` becomes `\r`.
- An optional `VtTerminalKeyToolbar` widget provides Esc, Ctrl, Alt, Tab and the arrows on mobile.
- Mouse input arrives through a `Listener` and goes to the `MouseEncoder` when the program tracks the mouse, and to selection otherwise.
  - Shift bypasses mouse tracking.
  - Double and triple click, block selection and autoscroll come from `SelectionGesture`; Shift+click extends the selection.
  - The wheel scrolls the viewport, or sends arrows on the alternate screen when mode 1007 is set.
- Scrolling is owned by libghostty: there is no `ScrollPosition`. A custom scrollbar is drawn from `ViewportScrollbar`.

*Amendment (2026-11-10, key routing).* While a text input connection is open and nothing is composing, a plain printable key (a writing-system key or Space, without Ctrl, Alt or Super after the AltGr and Option rules) is left to the platform text input, as `EditableText` does: desktop embedders offer a key to the IME only after the framework leaves it unhandled (Flutter 3.47.9 `shell/platform/linux/fl_view.cc`, `handle_key_event`), so encoding it would break IMEs, dead keys and compose sequences. Its text arrives as committed text. The exception is a program that set Kitty flag 2 (report event types) or 8 (report all keys as escape codes): those need key events that committed text cannot carry, so printable keys are then encoded directly, presses, repeats and releases included, and only an active composition still goes to the IME. Encoded keys and pastes wait until the text of earlier keys left to the platform has arrived (bounded by a 100 ms timeout), so the order is kept on embedders that do not serialize key events. A key is `handled` only when the encoder produced bytes, or for Tab, Esc, Enter, Space and the arrows; other keys, such as Cmd shortcuts and media keys, reach the platform.

**Accessibility (v1).** A `Semantics` node with the visible text, computed only while accessibility is on, plus an opt-in announcement of new output (`sendAnnouncement`). Full screen-reader navigation is deferred.

**Demo app** (`apps/demo`, `publish_to: none`):
- native platforms use `flutter_pty2` 3.0.0, pinned exactly, with a committed lockfile and its build hook and C sources reviewed;
- *amendment (2026-11-10):* it replaced `flutter_pty` 0.4.2, which is unmaintained since 2025-01 and leaks descriptors and a thread per shell, blocks the UI thread on writes, has no close call and lets a failed `exec` return into the app. `flutter_pty2` fixes all of these, adds no lockfile entry besides itself, and needs a C compiler wherever the demo's dependencies are built (`demo:test` included). Research: `docs/internal/research/2026-11-10-pty-packages.md`;
- web uses a fake shell in pure Dart, deployed as the live demo.
- the web demo waits for `ghostty_dart`'s wasm backend; until it exists, `mise run demo:build-web` stops with that message.

**Deferred:**
- Kitty images: `setVtPngDecoder` must decode synchronously, while `dart:ui` decodes asynchronously and has no web sync path. The layer order reserves a slot for them.
- the `drawRawAtlas` glyph atlas (v2, only with benchmark evidence): built and made the default by ADR 0012 (2026-11-10);
- ligatures;
- mobile selection handles;
- full screen-reader navigation.

**Performance targets** (200×60 at DPR 2; to measure with `integration_test` `traceAction` under `flutter drive --profile`):

| Frame | UI thread | Raster thread |
|---|---|---|
| Idle | ≤ 0.5 ms | ≤ 1 ms |
| 3 dirty rows | ≤ 1 ms | ≤ 2 ms |
| Full screen, warm cache | ≤ 4 ms | ≤ 4 ms |

We compare against xterm 4.0.0 and xterm2 with the same byte streams.

## Consequences
- The widget is simple and fast enough for v1 without an atlas. The measurements decide whether v2 needs one.
- Users bring their own pty, but the demo shows how to connect one.
- The adapter stays thin: a key table plus name mapping. xterm's `Buffer` and `scrollController` map only partially, and `COMPATIBILITY.md` lists them as differences (⚠️).

## Amendment (2026-11-10, contracts of the first implementation)
- The `SelectionGesture` belongs to the view's pointer layer, not to `VtTerminalController`. It is per-view input state whose repeat interval and distance depend on the platform; the pointer layer creates it from the controller's terminal and disposes it. The selection itself stays in the terminal and is read and set through the controller.
- Search highlights are not part of v0.1's controller API; they will be added without breaking it.

## Amendment (2026-11-10, integration of the view)
- **Accessibility as built.** The view exposes one semantics node (label `semanticsLabel`, value the visible rows as plain text, multiline, read-only only when the view is `readOnly`, tap = focus and show the keyboard). The `Semantics` widget is always in the tree, so toggling accessibility never remounts the view; its properties are filled only while `SemanticsBinding.semanticsEnabled` is true (any accessibility service, not only a screen reader, which is what `MediaQuery.accessibleNavigation` reports), and the view does not even listen to the controller otherwise. The text is read with a `TerminalFormatter` over a viewport `selectRange`, at most every 500 ms. `announceOutput` (off by default) sends the rows that are new since the last read with `SemanticsService.sendAnnouncement` (`announce` is deprecated since 3.35), at the same rate and at most 1000 characters, newest kept.
- **Theme lives on the controller.** The view has no `theme` parameter: `VtTerminalController.theme` is the one source (it is pushed into the terminal's defaults so OSC queries answer correctly). The setter notifies synchronously, except while a frame of a widget over the controller is being built, laid out or painted (`SchedulerPhase.persistentCallbacks`): then the notification is delivered once after the frame. The xterm adapter maps `TerminalView.theme` to the controller from `initState` and from `didUpdateWidget` only when it changed, never from `build`.
- **Discrete wheel on macOS.** Flutter's macOS embedder sends scrolls with gesture phases (trackpad, Magic Mouse) as pan-zoom events of kind `trackpad`, and phase-less wheel events as mouse-kind scroll signals: `lines × 40` px without precise deltas, raw pixels with them (`FlutterViewController.mm`). Flutter exposes no precise-deltas flag, so the time stamp is the other signal: a mouse-kind event with no other within 100 ms is a discrete notch. macOS reports a slow notch as about 0.1 line, less than a row; like Ghostty's `scrollCallback` (`src/Surface.zig` at `vt-1.0.0`: at least one line on Darwin, then `mouse-scroll-multiplier.discrete` = 3 rows per line), such a notch scrolls `max(lines, 1) × 3` rows. Events inside a stream (fast spins, smooth-scrolling mice without phases) accumulate their pixels unchanged; only a stream's first event may count as a notch. Other platforms pass deltas through: Linux sends 53 px per discrete notch and fractions for high-resolution wheels, Windows the system's lines × 20 px, so with rows taller than 53 px a Linux notch can scroll no row until the next one (accepted for v0.1).
- **Unsafe paste.** The package has no built-in confirmation dialog (it depends only on the widgets layer): without `onUnsafePaste`, text the terminal rejects is not pasted, as Ghostty's paste protection does. Apps pass a callback that asks the user.
- **Keyboard on tap.** A mouse press focuses the view and opens the text input connection; a touch or stylus press shows the soft keyboard only when it ends as a tap (within `kTouchSlop`, before `kLongPressTimeout`), so scrolling and long-press selection never pop it up. `closeKeyboard()` keeps the connection closed across rebuilds until `requestKeyboard()` or the next focus gain.
- **IME composing hides the cursor without a rebuild.** The view feeds a `ValueNotifier<bool>` that the render box listens to (`TerminalRenderWidget.cursorHidden`): the input layer can close its connection, and so end a composition, from `didUpdateWidget` (readOnly, hardwareKeyboardOnly or deleteDetection changes, a disposed controller), and a `setState` there would be a rebuild of an ancestor during build. The preedit background is read when the preedit is drawn and on every notification while composing, so it follows theme and OSC 11 changes.
- **Focus across swaps.** Replacing the focus node moves the focus to the new node (the request waits until it is attached), disposes only a node the view created, and only after the frame; the input layer judges the new node's focus once it has settled, so the program sees no focus-out/focus-in blip. Replacing the controller while focused sends focus-out to the old program and focus-in to the new one (DEC 1004).
- **Tap callbacks** carry xterm's details: `onTapUp(TapUpDetails, GridPoint)`, `onSecondaryTapDown(TapDownDetails, GridPoint)`, `onSecondaryTapUp(TapUpDetails, GridPoint)` (global and local position, device kind), so the adapter only converts the viewport `GridPoint` to xterm's `CellOffset`.
- **Defaults that differ from xterm 4.0.0** (`keyboardType` null = platform pick instead of `emailAddress`, `deleteDetection` on, `cursorStyle` null = follow DECSCUSR instead of block, `padding` without the `MediaQuery` padding) are chosen for a native terminal and documented on each parameter; `keyboardAppearance` is dark, as in xterm. The adapter passes xterm's defaults explicitly.
- **Box drawing** (U+2500–259F) is stretched to its cell's width and clipped to the cell: a vertical stroke taller than the line overlapped the next row's stroke and the antialiased overlap drew a brighter dot at every row boundary.
- **Read-only views** send nothing to the program, mouse included: the pointer layer sees a terminal that does not track the mouse and has no alternate scroll, so presses select and the wheel scrolls the scrollback (xterm's `readOnly`: "no input should send to the terminal").
- **Goldens.** The `golden` tag (package `dart_test.yaml`) skips goldens and exact raster checks off Linux; `mise run test:goldens:update` regenerates them and the pub.dev screenshot `doc/screenshot.png`, which is a golden of the real view.

## Amendment (2026-11-10, render performance)
Measured first (temporary `Stopwatch` probes in the view's paint, profile mode, the benchmark's machine and streams): the repeated full-screen frame spent 70 ms in paint, 63 ms of it creating paragraphs. One paragraph per style run from a 4,096-entry LRU hit 1.5 % of lookups on the 8-screen stream (~11,500 distinct runs), so every frame built, laid out and disposed ~1,400 paragraphs (~44 µs each). These changes replace "one paragraph per style run" above:
- **One paragraph per row.** A row with two or more text runs is laid out as one paragraph with a style span per run (blank gaps are spaces with the same letter spacing). It is used only if it measures its cells × cell width and every run starts at its cell (both within half a device pixel; checking the total alone let a wider face and a narrower one cancel out); otherwise the row is drawn run by run as before, each run checked again and drawn per cell if needed. A differential test shows both paths paint identical pixels on mixed screens. Single-run rows, clusters and the cursor glyph keep the run cache. Row paragraphs are not cached (~70 KiB of RSS each for 200 columns).
- **Row pictures are also cached by content.** `RowContent` (the scan already used as the content key) keys an LRU of pictures; a changed row reuses a picture with equal content before recording one, rows with equal content share it, rows that stay on screen stay most recent, and eviction never disposes a picture shown in the current frame.
- **Memory.** Pictures and paragraphs are bounded by an estimated byte budget per view, 16 MiB by default (`TerminalRenderWidget.cacheBudget`; ¾ pictures, ¼ paragraphs; estimates from RSS measurements of 2026-11-10). Everything is released when the render box is detached, when its tickers are muted (a hidden tab or a covered route), and when the system fonts change; memory pressure keeps only the visible rows' pictures.

Result (`mise run bench:widget`, same VM, DPR 2, write + UI average in ms, ours / xterm 4.0.0 / xterm2 5.4.0): idle 0.14 / 0.15 / 0.15; 3 dirty rows 2.49 / 19.11 / 25.49; scroll (`cat`) 1.76 / 5.87 / 6.43; full screen of new text 32.30 / 21.58 / 25.51; htop-like (20 % of cells, every row) 33.32 / 19.63 / 24.02; full screen of 8 repeated screens (cache replay) 3.05 / 20.42 / 25.83. Before these changes the replay scenario measured 63.91 for us. Targets on this VM: UI met for idle and for the replay; missed for 3 dirty rows and for a full screen of new text, where we are also 1.5× slower than xterm 4.0.0 (1.7× on the htop-like screen); raster missed everywhere (software). Those misses are what the `drawRawAtlas` v2 would address; it is proposed, not built (numbers in `benchmarks/README.md`).

## Amendment (2026-11-10, glyph atlas)

ADR 0012 (Accepted 2026-11-10) amends "Rendering (v1)" and the render-performance amendment above: grid text is drawn from a `drawRawAtlas` glyph atlas by default (`VtTextRendering.atlas`), one call per row and atlas page inside the row's cached picture. Row paragraphs stay as `VtTextRendering.paragraphs` (public opt-out), as the fallback for glyphs the atlas does not hold, and as the reference of the differential tests. The cache budget now counts atlas images too (pictures and atlas share ¾, paragraphs ¼). Design, numbers and the open raster question are in ADR 0012.

## Amendment (2026-11-11, hooks and highlights for the xterm adapter)

ADR 0013 needs the view to let an app (first of all `ghostty_dart_xterm`) change what reaches the program, so `VtTerminalView` gained additive, xterm-agnostic hooks; with every hook `null` the view behaves and paints exactly as before (the existing tests and goldens are unchanged). `onTerminalKey` sits in the key routing after `onKeyEvent`, the shortcut map, `readOnly`, releases, modifiers, repeats of encoded or platform presses and the IME composition, and before the step that leaves printable keys to the platform; a string it returns is sent through the same ordered input queue as committed text. Soft-keyboard Backspace and IME Enter-like actions reach it as synthesised `KeyDownEvent`s. `onTerminalText` sees committed text (never pastes) just before it is sent. `mouseReportFilter` is consulted where the view would report (tracking on, Shift not held) for presses, wheel steps and motion, never for the release of a reported press; a refused press handles its whole gesture as untracked, a refused wheel step scrolls as untracked. `onTerminalMouse` replaces the encoding of each report that passed. `wordBoundaryCodepoints`, `rectangleSelection` and a `SelectAllTextIntent` action (no default shortcut) complete the selection options, and `VtTerminalViewState` exposes `cursorRect`, `globalCursorRect` and `hasInputConnection`.

`VtTerminalController.addHighlight` adds coloured ranges tracked by two `TrackedGridRef`s. They are an **overlay of the render box, like the cursor**: the renderer reads their viewport positions through the frame source once per paint (not while the render is held) and fills whole cells after the text and the cursor, in creation order. They are not part of any row's content key, so adding, moving or removing one records no row picture. The selection is part of the row pictures (under the text), so highlights paint over it, where xterm paints the selection over highlights; with the translucent colours both use, the difference is the blend order only. A highlight is painted only while the screen it was made on is active.

## Amendment (2026-11-12, frame rate under an output flood)

**Context.** The maintainer measured `tree -C` over 570,000 files in vtterm (release build, CachyOS, Wayland): about the wall time of Kitty (6.2 s against 5.65 s; `tree` itself is the bottleneck), but ~190 % CPU and 225 MB RSS against Kitty's ~66 % and 165 MB. The firehose benchmark (`mise run bench:firehose`; `benchmarks/README.md`) reproduces it headless: the parser costs ~5 ms of CPU per MB (212 MB/s in 4 KiB writes) and the controller without a view ~16 ms per MB of process CPU in total, so nearly all the cost is frames. Once output scrolls a screen or more per frame, every frame draws a whole new screen, and every listener that schedules a frame (the renderer, and also the scrollbar, which follows the growing scrollback, and the pointer and IME layers, which follow the cursor) kept the view painting at the display's refresh rate: 60 to 144 full-screen frames a second of text nobody can read. Kitty bounds its repaint rate for the same reason: `repaint_delay` 10 ms by default, "~100 FPS", with `sync_to_monitor` also limiting it to the refresh rate (https://sw.kovidgoyal.net/kitty/conf/, Performance tuning, read 2026-11-12).

**Decision.** The view's seams (`ControllerSeams`) now listen to the controller once and notify the view's listeners themselves. After each paint the renderer reports whether output floods the view: every visible row was a row the previous frame did not show (by `RenderRowId`), in each of the last two frames (`RenderTerminal.floodFrames`; two, so one `clear` never delays the prompt after it). While it floods, a controller change is delivered no earlier than 25 ms after the last paint (`ControllerSeams.floodInterval`), to every listener at once; the frame it schedules starts at the next vsync, so a flood paints about 30 times a second at 60 and 120 Hz and 36 at 144 Hz. A paint cancels a pending notification, and removing the last listener or releasing the seams cancels it too. Output that redraws rows in place (full-screen programs, the alternate screen), scrolling slower than a screen per frame, and the first change after a pause are delivered synchronously as before. The controller's own contract is unchanged: its listeners are still notified synchronously after every call; only the view's internal listeners are coalesced. Errors in one view listener are reported and do not skip the others, as with `ChangeNotifier`.

**Result** (40 MB of `tree -C`-like output at 7 MB/s, 4 KiB chunks, 200 × 60, Xvfb + llvmpipe, Ryzen 5 3600, together with the box-drawing amendment of ADR 0012): process CPU 464 → 155–217 ms per MB, frames 179 → 56–88, UI thread 1.87 → 0.76–0.97 s, raster thread 1.76 → 0.22–0.34 s; excluding llvmpipe (software GPU, absent on real hardware) 103 → 32–41 ms per MB. Unthrottled input, throughput with the view went from 25 to 49 MB/s. On this machine the flood paints every 50–80 ms rather than every 33 ms: GTK presents each llvmpipe frame on the UI thread (the Linux embedder runs UI and platform on one thread), which delays the 25 ms timer by 15–25 ms; on a real GPU that present is short. The numbers on a real GPU, and at 120/144 Hz, are still to be measured (`mise run bench:firehose` on a desktop).

## Amendment (2026-11-12, frame cost and sustained floods)

**Context.** On the maintainer's machine (CachyOS, AMD GPU, Impeller OpenGL ES, DPR 2, `mise run bench:firehose`, 40 MB at 7 MB/s) the view cost 2.83–2.87 s of CPU against 1.12–1.32 s without it, for 140–143 frames: the UI thread took ~1.3 s more (≈ 9 ms per frame, while `FrameTiming` build was 2.0–2.1 ms), the raster thread 0.1 s. In vtterm (flutter_pty2 → `writeBytes`, the same wiring as `apps/demo`) the real `tree -C ~` (65.5 MB in 6.4 s) cost 8.73 s against Kitty's 3.47 s.

Measured here (Ryzen 5 3600, Xvfb + llvmpipe, Dart CPU profiles of the UI isolate through the VM service, profile builds, 2026-11-12):

- **Per frame, the view is not the cost.** The UI isolate's Dart work per flood frame (frame callback, `RenderTerminal._pullFrame`, row scans, recording) is 0.7–1.9 ms. Since Flutter 3.x the Linux embedder runs the UI isolate on the platform (GTK) thread by default (`fl_engine.cc`, `FL_UI_THREAD_POLICY_DEFAULT`), and that thread also presents every frame: `fl_compositor_opengl_render` draws the frame into the window with `gdk_cairo_draw_from_gl`, and on X11 first uploads the pixels the raster thread read back with `glReadPixels` (frames are shareable between contexts only on Wayland, `fl_view_renderer.cc`); engine `89c39edfdfae2949f6806e4a315c0c08522238b7`, Flutter 3.47.9. The new `blank` configuration of the benchmark (a widget of the view's size that only fills a rectangle, at the same cadence) pays 15.7–17.1 ms of UI thread per frame here (3600 × 2200 px window), against 17.0–18.3 ms for the view: the embedder's present is the cost, and it scales with frames and window pixels, not with what the view draws. GC is small (concurrent marking ~30 ms per 40 MB run).
- **Per write, the view's listeners were.** With a focused view and frames slower than the 25 ms flood interval (a large window, a software GPU), `ControllerSeams` delivered a notification on *every* write between the timer's notification and the paint it scheduled, because the interval counted only from the last paint; and `VtTerminalViewState` listened to the controller directly, reading `cols` and `rows` (two native calls) on every write. In the demo app (64 MB at 10.2 MB/s, line-buffered writer, ~15,700 reads) that was 126 ms + 38 ms of the UI isolate's ~1.1 s.
- **Per write, the rest is the parser and the pty package.** `ghostty_terminal_vt_write` costs ~4 ms per MB. flutter_pty2 3.0.0's `pty_session_ack_output` (`src/unix/pty_unix_session.c:1019`) writes to the reactor's wake pipe on every acknowledgement (`wake_reactor`, `:107`), another ~4 ms per MB, and `read_output` (`:322`) posts every read of at most 4 KiB as its own message, so the UI thread dispatches a platform task per 4 KiB. Both are upstream's to change (wake only when the credit was exhausted; keep reading into the 16 KiB buffer before posting); we do not patch dependencies.

**Decision.**

1. While flooded, `ControllerSeams` waits the flood interval from the last paint **or the last notification**, whichever came later, so a slow frame no longer turns every write into a round of listener calls. Not flooded, delivery is unchanged (synchronous).
2. `VtTerminalViewState` listens through its seams instead of the controller, so its size check is coalesced with the other view listeners in a flood and never costs native calls per write.
3. A flood that has lasted `ControllerSeams.sustainedFloodAfter` (1 s) is delivered at most every `ControllerSeams.sustainedFloodInterval` (60 ms): about 15 frames a second at 60, 120 and 144 Hz, instead of ~30. The first second of a flood, and every change after a pause or that does not replace every row, behave as before (25 ms, or at once). The reason is the cost structure above: the view's own work per frame is already 1–2 ms, while each frame costs the UI thread several times that in the embedder, which no change to the view can reduce, and text that scrolls a screen per frame for seconds is unreadable at any rate. This trades smoothness of an unreadable scroll for CPU; Kitty, which renders on the GPU with little per-frame CPU, caps at ~100 fps (`repaint_delay`), so this is a deliberate difference, not Kitty's behaviour.

The benchmark gained the `blank` configuration, `ui thread ms`, `ui ms/frame over no view`, and `window px` and `display` in `FIREHOSE_ENV` (existing keys unchanged), so the split between the embedder's and the view's cost per frame can be re-measured on a real GPU and on Wayland.

**Result** (Xvfb + llvmpipe; llvmpipe caps this machine at 8–20 frames a second, so decision 3 cannot show here and must be measured on a real GPU): in the demo app the UI isolate's listener and size-check time per 64 MB went from 164 ms to 10–16 ms and `writeBytes` beyond the parser from 154 ms to 33–46 ms; in the benchmark, where the view has no focus and no input connection, the view's Dart time is unchanged (~1.7 ms per frame). Expected on the maintainer's machine from decision 3: ~140 → ~90 frames per 40 MB run, about 0.4–0.5 s less UI thread CPU (≈ 15 % of the view's 2.85 s), proportionally more for the 6.4 s `tree -C ~`.

## Amendment (2026-11-12, vsync-aligned flood pacing)

**Context.** On the maintainer's machine (CachyOS, Wayland, AMD GPU) a long `tree` flood "goes in jumps" in vtterm while Kitty scrolls smoothly; CPU is no longer the problem (6.58 s against Kitty's 3.67 s for the same `tree`, 1.8×). The firehose benchmark there showed frame gaps p10/p50/p90 ≈ 33/67/130 ms: a low rate **and** an irregular cadence. Two causes, both of the wall-clock timer of the previous amendments:

- A `Timer` of 25 or 60 ms is not aligned with vsync. The frame it requests starts at the next vsync, so a late timer (the UI thread also dispatches pty reads, and on Linux presents frames) slips a whole vsync, and gaps alternate between two or three different multiples of the refresh period.
- When no frame is scheduled for 51 ms, the engine notifies the Dart VM that the UI thread is idle for 100 ms (`Animator`, `kNotifyIdleTaskWaitTime`, `shell/common/animator.cc`, engine of Flutter 3.47.9). The sustained flood's 60 ms interval waited exactly into that window; in the benchmark (Xvfb + llvmpipe), a cadence of every fourth vsync gave gaps of 90–160 ms (p50) instead of 67, every third vsync steady 66 ms.

Read in the pinned engine (2026-11-12): the Linux embedder gives the engine no vsync callback (`shell/platform/linux/fl_engine.cc`), so Flutter on Linux uses `VsyncWaiterFallback`, a fixed 60 Hz tick whatever the monitor (`shell/common/vsync_waiter_fallback.cc`); it does report the monitor's rate in `FlutterView.display.refreshRate` (`fl_display_monitor.cc`, `gdk_monitor_get_refresh_rate`). Vsync timestamps (`SchedulerBinding.currentSystemFrameTimeStamp`) are on Dart's timeline clock, because the engine sets `fml::TimePoint`'s clock to it (`runtime/dart_vm_initializer.cc`); `Timeline.now` reads the same clock.

**Decision.**

1. While output floods the view, `ControllerSeams` delivers the view's notifications at the **start of a frame** (a transient frame callback, before build, layout and paint) that is a whole number of vsyncs after the last flooded paint. It does not request frames it does not paint: a `Timer` wakes up during the vsync period before the due vsync (an eighth of a period after the previous one, at least 1 ms, rounded up to whole ms) and only then schedules the frame callback, so the timer may run late by most of a period and still land on the right vsync. The last frame's vsync time comes from the scheduler (falling back to now outside a frame, or if it is not within a second before now). A notification that waits for a slow frame counts from that frame, so writes in between never notify again. The rest of the first flood amendment holds (flood detection, two frames, synchronous delivery otherwise, cancellation on paint, on removing the last listener and on release). The 1 s "sustained" mode is dropped: a constant rate is what reads as smooth, and its 60 ms interval fell into the engine's idle window.
2. The rate is public, additive API: `VtTerminalView.floodPacing`, `VtFloodPacing { smooth (≤ 60 fps), balanced (≤ 30 fps, the default), efficient (≤ 20 fps) }`. Vsyncs per flood frame = refresh rate (`View.of(context).display.refreshRate`; 60 when unknown or below 24 Hz) ÷ the policy's rate, rounded, at least 1: 1/2/3 at 60 Hz, 2/4/6 at 120 Hz, 2/5/7 at 144 Hz. `efficient` stops at 20 fps (every third vsync at 60 Hz) to stay under the engine's 51 ms idle notification. On Linux, where the engine ticks at 60 Hz whatever the monitor, these intervals land on the same 60 Hz ticks (16.7/33.3/50 ms).
3. **Default `balanced`.** The maintainer's measurements give each flood frame ~9–12 ms of CPU on his machine, nearly all the embedder's present (previous amendment). His `tree` (6.4 s) at the old cadence painted ~110 frames; `balanced` paints ~190 (≈ +0.8–1 s, about 2× Kitty), `smooth` ~380 (≈ +3 s, about 2.6× Kitty). Within the "at most 2× Kitty" budget only `balanced` keeps an even cadence, so it is the default and `smooth` is one parameter away. Revisit once `mise run bench:firehose` has run on a real GPU at 60 and 120/144 Hz.

The firehose benchmark runs `blank` and `view` once per policy (`--pacing`, all three by default; `blank` follows the same vsync pacing), and reports `pacing`, `frame gap jitter ms` (standard deviation), `frame gap irregular %` (gaps that are not the median's whole number of vsyncs), `present gap ms p10/p50/p90` (from `rasterFinish`), and `refresh Hz` in `FIREHOSE_ENV`; existing keys are unchanged.

**Result** (Ryzen 5 3600, Xvfb + llvmpipe, 1800 × 1100 px, DPR 1, `refresh Hz` 0 so 60 Hz, 40 MB at 7 MB/s, 3 runs each; `before` is the previous amendment's timer). With llvmpipe a view frame takes longer than a 33 ms period here (GTK presents it on the UI thread after a software raster), so the view cannot hold 30 fps on this machine and the three policies converge near 15 fps; the `blank` frames, which fit in a period, show the cadence itself.

| | frames | gap p10/p50/p90, ms | jitter, ms | irregular % | CPU ms/MB without llvmpipe | UI thread, s |
|---|---:|---|---:|---:|---:|---:|
| view, before | 38–49 | 66–120 / 127–161 / 189–196 | 32–53 | 65–96 | 27–32 | 0.62–0.69 |
| view, smooth | 88–154 | 14–29 / 33–53 / 51–114 | 15–35 | 31–74 | 42–60 | 0.96–1.40 |
| view, balanced | 86–104 | 33–47 / 56–66 / 67–89 | 10–28 | 29–78 | 41–47 | 0.95–1.07 |
| view, efficient | 62–90 | 31–53 / 66–87 / 67–156 | 13–48 | 19–79 | 34–42 | 0.78–0.97 |
| blank, balanced | 92–167 | 33 / 33–61 / 34–112 | 4–33 | 1–89 (4 of 6 runs ≤ 15) | 34–49 | 0.82–1.18 |

The deterministic tests (`test/render/terminal_render_test.dart`, `test/view/flood_pacing_test.dart`, on the test's fake clock and frames) hold every policy at 60, 120 and 144 Hz to frames exactly *n* vsyncs apart once the flood is detected. On a real GPU, where a frame fits in a vsync, the cadence should be that of `blank`; the maintainer's run (`mise run bench:firehose`) decides whether `balanced` stays the default.

## Amendment (2026-11-12, real-GPU pacing: `smooth` by default, `efficient` removed)

**Context.** The previous amendment left the default to a run on a real GPU. The maintainer ran `mise run bench:firehose` (2026-11-12) on CachyOS, Wayland, AMD GPU, a 60 Hz monitor, window 3600 × 2200 px, with the benchmark's view configuration (200 × 60, JetBrains Mono 12 px, atlas path, 40 MB at 7 MB/s):

| policy | frame rate | frame gaps, ms | irregular gaps | CPU, ms/MB |
|---|---:|---|---:|---:|
| smooth | 60 fps | 16 / 16.8 / 17.2 (p10/p50/p90) | 1–3 % | 118 |
| balanced | 30 fps | 33 | 12–16 % | 74–80 |
| efficient | 20 fps | 35 / 50 / 67, alternating | 44–50 % | 57–61 |

Where a frame fits in a vsync the pacing does what decision 1 intended for `smooth` and `balanced`. `efficient` does not: about every third due vsync is missed and the gaps alternate between 50 and 67 ms, which reads as jumps. The cause is not established. The engine's idle notification (`kNotifyIdleTaskWaitTime`, 51 ms) is the likely suspect, but under `efficient` the seams already ask for the frame about 35 ms after the previous one (the timer wakes in the vsync period before the due vsync), under that deadline, so asking one vsync earlier or adding a heartbeat frame would be a guess. A heartbeat would also cost frames, which is the opposite of what the policy is for. Xvfb + llvmpipe cannot reproduce it, because there a view frame does not fit in a period at all.

**Decision.**

1. **`VtFloodPacing.smooth` is the default** of `VtTerminalView.floodPacing` (and of `ControllerSeams.floodPacing`): steady 60 fps with 1–3 % irregular gaps, the scroll the maintainer wanted from Kitty, for about 1.5× the CPU per MB of `balanced`. This supersedes decision 3 of the previous amendment. `balanced` stays as the opt-in for less CPU at a still-even cadence.
2. **`efficient` is removed** from `VtFloodPacing`, which is unpublished, so the removal breaks nobody. A policy that promises to save CPU but stutters on real hardware is worse than none. The enum is now `{ smooth (≤ 60 fps, default), balanced (≤ 30 fps) }`, with 1/2 vsyncs at 60 Hz, 2/4 at 120 Hz and 2/5 at 144 Hz. A slower policy can come back only with a cause, a fix and a real-GPU run that shows regular gaps.
3. `bench:firehose` runs `smooth,balanced` by default.

Still to measure: the same run at 120/144 Hz on a platform whose embedder gives the engine real vsync (Linux ticks at 60 Hz whatever the monitor, see the previous amendment).
