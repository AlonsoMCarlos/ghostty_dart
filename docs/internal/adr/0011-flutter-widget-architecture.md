# 0011. `ghostty_dart_flutter` widget architecture

**Status:** Proposed (2026-11-09). Research: `docs/internal/research/2026-11-09-flutter-rendering.md` and `2026-11-09-flutter-input.md` (2026-11-09). Some points are inferred and marked "to measure"; the plan validates them first.

## Context
- No existing Flutter terminal tracks dirty rows. xterm 4.0.0 paints one paragraph per cell and repaints everything on every write. xterm2 also paints per cell. flterm uses a `drawRawAtlas` glyph atlas but publishes no numbers.
- In Flutter 3.47.9, Impeller is the default on every native platform and web uses Skia (CanvasKit or skwasm). Impeller has no raster cache: per-row `RepaintBoundary`s save UI-thread recording only, not raster work.
- libghostty-vt already provides what a renderer and an input layer need:
  - a batched `RenderState` with dirty rows, style runs and a stable `RenderRowId`;
  - a key encoder (legacy and Kitty, including release events), a mouse encoder, and selection gestures;
  - a viewport whose scroll position stays anchored while output arrives.
- Every local pty package (`flutter_pty`, `pty2`, `portable_pty`) compiles native code on the user's machine.
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

**Accessibility (v1).** A `Semantics` node with the visible text, computed only while accessibility is on, plus an opt-in announcement of new output (`sendAnnouncement`). Full screen-reader navigation is deferred.

**Demo app** (`apps/demo`, `publish_to: none`):
- native platforms use `flutter_pty`, with a committed lockfile and its native build reviewed;
- web uses a fake shell in pure Dart, deployed as the live demo.

**Deferred:**
- Kitty images: `setVtPngDecoder` must decode synchronously, while `dart:ui` decodes asynchronously and has no web sync path. The layer order reserves a slot for them.
- the `drawRawAtlas` glyph atlas (v2, only with benchmark evidence);
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
