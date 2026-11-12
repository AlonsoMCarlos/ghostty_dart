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
