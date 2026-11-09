# Research: libghostty-vt, existing Dart bindings and the `xterm` API

Date: 2026-11-09 (all sources read that day). **[V]** = verified at the source, **[I]** = inferred.

## 1. libghostty-vt

### Stability
- **[V]** 1.0.0 was released on 2026-11-06. The library and its C ABI are declared stable.
  - Tag `vt-1.0.0`, commit `0fa3d577a561…`.
  - Sources: https://mitchellh.com/writing/libghostty-1-0 and https://lib.ghostty.org/vt/stability.html
- **[V]** Guarantees:
  - Semver. SONAME `libghostty-vt.so.1`, ELF symbol versions `GHOSTTY_VT_1.0`.
  - Minor releases are additive only. Handles are opaque, and getters/setters are keyed by enums.
  - Newer headers against an older library return `GHOSTTY_UNSUPPORTED`.
  - Version checks: `GHOSTTY_VT_VERSION_AT_LEAST()` at compile time, `ghostty_version()` at runtime.
- **[V]** Not covered by the guarantees: the snapshot byte format and the Zig version.
- **[V]** Licence: MIT.

### C API
Include only `<ghostty/vt.h>` (about 15.7k lines).

- **Core**
  - Lifecycle: `ghostty_terminal_new/free/resize/reset`.
  - Byte input: `ghostty_terminal_vt_write`.
  - Options and data: `ghostty_terminal_set/get` (keyed by enum).
- **Callbacks.** They are set as terminal options (`OPT_*`) and run synchronously, on the thread that calls `vt_write`.
  - `WRITE_PTY`, `BELL`, `TITLE_CHANGED`, `PWD_CHANGED`.
  - Clipboard (OSC 52), notifications.
  - `RenderHold` (synchronized output).
- **Rendering:** `ghostty_render_state_*` with row and cell iterators, including `row_iterator_next_dirty`. This is the API meant for renderers.
- **Input encoding**
  - Keyboard: `ghostty_key_event_*` / `ghostty_key_encoder_*`, including the Kitty keyboard protocol.
  - Mouse: `ghostty_mouse_encoder_*` (X10, UTF-8, SGR, URxvt, SGR-Pixels).
  - Paste, focus and reports: `paste_*`, `focus_encode`, `*_report_encode`.
- **Utilities**
  - Selection: `selection_gesture_*`, `select_word/line/all`.
  - Search: `search_*`. Formatting to text, VT or HTML: `formatter_*`.
  - Kitty graphics, snapshots, Unicode width.

### Memory and threads
Source: **[V]** https://lib.ghostty.org/vt/conventions.html

- Every `_new` has a matching `_free`, and `_free` accepts NULL.
- Borrowed handles stay valid only until the next call that mutates the terminal.
- Output buffers follow the "NULL/0 returns the required size" convention.
- The library creates no threads. A single handle is not thread-safe; different handles are.

### Build
All **[V]**:

- Requires **Zig 0.17.x exactly**.
- From the release tarball: `zig build -Doptimize=ReleaseFast`. From a git checkout, add `-Demit-lib-vt`.
- Runtime dependency is libc only. `-Dsimd=false` makes it freestanding, but much slower.
- WebAssembly: `-Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall`.

### Platforms
- **[V]** Tested in CI:

  | OS | Targets |
  |---|---|
  | Linux (glibc, musl) | x64, arm64 |
  | macOS | x64, arm64 |
  | iOS | arm64 |
  | Windows | x64 |
  | Android (16 KB pages) | arm64, x64, arm |
  | WebAssembly | wasm32 |

- Windows arm64 is built but not tested.
- **[V]** Official artefacts at https://release.files.ghostty.org/libghostty-vt/1.0.0/, signed with minisign:
  - the source tarball;
  - `xcframework.zip`;
  - `.wasm` and `-small.wasm`.
- **No prebuilt Linux, Windows or Android binaries.**

### Performance
- **[V]** Ghostty 1.4 notes: ASCII parsing at 725 MB/s.
- No official comparison against other parsers.

## 2. Existing Dart bindings

| Package | State | Notes |
|---|---|---|
| `libghostty` 0.0.13 + `flterm` 0.0.6 (github.com/elias8/libghostty) | Active (Oct–Nov 2026) | Pinned to a **pre-1.0** commit (`e3ac6200…`, Oct 10). Its Dart API changes often. The build hook downloads the author's own binaries (sha256-checked) and has a `source=compile` option. FFI on native, wasm on web. No xterm compatibility. The name `libghostty` is taken on pub.dev. |
| `ghostty_vte` 0.1.3 + `ghostty_vte_flutter` (github.com/kingwill101/dart_terminal) | 0.1.3 from May 2026, 0.2.0 in beta | Useful as a build reference: `-Dsimd=false`, an Android libc link patch, a 16 KB ELF page check and the full target mapping. It delegates to `native_prebuilt`, a single-author package. |

**[V]** The names `ghostty_vt`, `ghostty_vt_flutter` and `ghostty_xterm` were free on pub.dev on 2026-11-09.

## 3. Terminal packages on pub.dev

- **[V] `xterm` 4.0.0 (TerminalStudio) is the de facto standard:**
  - 239 likes, about 253k downloads in 30 days, 140/160 pub points.
  - Last release on 2024-02-27. 78 open issues and 33 open PRs.
- **[V] Forks:**

  | Fork | Notes |
  |---|---|
  | `xterm2` 5.4.0 | Same API |
  | `xterm3` | AGPL |
  | `kterm` | Adds the Kitty protocol |
  | `terminal_view` | Not drop-in |
  | `yoxterm` | Glyph atlas |

  All have very little adoption.

### Public API of `xterm` 4.0.0 (the compatibility target)

**`Terminal`**

```dart
Terminal({
  maxLines, onBell, onTitleChange, onIconChange, onOutput,
  onResize(w, h, pw, ph), platform, inputHandler, mouseHandler,
  onPrivateOSC, reflowEnabled, wordSeparators,
})
```

- Methods: `write(String)`, `keyInput(TerminalKey, {shift, alt, ctrl})` (no meta), `charInput`, `textInput`, `paste`, `mouseInput`, `resize`.
- Getters: `buffer`, `mainBuffer`, `altBuffer`, `viewWidth`, `viewHeight`, and the mode getters.
- It is `Observable`.

**`TerminalView`**

```dart
TerminalView(terminal, {
  controller, theme, textStyle, textScaler, padding,
  scrollController, autoResize, backgroundOpacity, focusNode,
  autofocus, onTapUp, onSecondaryTapDown, onSecondaryTapUp,
  mouseCursor, keyboardType, keyboardAppearance, cursorType,
  alwaysShowCursor, deleteDetection, shortcuts, onKeyEvent,
  readOnly, hardwareKeyboardOnly, simulateScroll,
})
```

**Other public types**
- `TerminalController`: selection (`BufferRange`, `CellAnchor`) and highlights.
- Theming: `TerminalTheme`, `TerminalThemes`, `TerminalStyle`.
- Input: `TerminalKey` (about 270 values, index-order dependent), `TerminalInputHandler`, `TerminalMouseButton`, `MouseMode`.
- Low level:
  - `Buffer` and `BufferLine`. A `BufferLine` is a `Uint32List` with 4 words per cell.
  - `CellData`, `CellAttr`, `CellColor`, `CellContent`.
  - The public `EscapeHandler` / `EscapeParser`.

**Weaknesses (what we improve on):**
- Parser runs at about 15 MiB/s.
- One `drawParagraph` per cell, and a full repaint on every `write`, with no dirty tracking.
- No grapheme clusters.
- Input: no Kitty keyboard protocol, no meta modifier, no mouse motion or drag reports.
- Unsupported sequences: DEC 2026, DECSCUSR, and any OSC except 0–2.
- Bugs:
  - DECCKM is wired to `appKeypadMode`.
  - Keyboard input on Windows with Flutter 3.44+ (`viewId`).
  - Several scrollback bugs.

**Typical integration:** `flutter_pty` or `dartssh2`. Output goes through `Utf8Decoder` into `terminal.write`, and `onOutput` is sent back with `utf8.encode`.

## 4. Packaging native code for Dart

**Build hooks**
- **[V]** Stable since Dart 3.10 / Flutter 3.38 (`hooks` 2.2.0, `code_assets` 2.2.0). Current versions are Flutter 3.47 and Dart 3.13.
  - Sources: https://dart.dev/tools/hooks and https://docs.flutter.dev/platform-integration/bind-native-code
- **[V]** **No static linking** (https://github.com/dart-lang/sdk/issues/49418). Always ship a dynamic library; on iOS, Flutter wraps it in a framework.
- **[V]** No fat Mach-O binaries: ship one per architecture. On Apple platforms the file name must be identical across architectures and SDKs.
- **[V]** Prebuilt binaries: download, verify the hash, then declare them with `DynamicLoadingBundled`.
- Reference implementation: `sqlite3` 3.x. It ships prebuilt binaries with sha256 and SLSA provenance, and offers `user_defines` for source builds.

**Bindings and calls**
- **[V]** ffigen 23.0.0 is configured through a Dart API (YAML is deprecated) and generates `@Native` by default.
- **[V]** Callbacks: use `NativeCallable.isolateLocal`. They are synchronous inside `vt_write`.
- **[V]** Call cost: `@Native` leaf calls take about 28 ns, non-leaf calls about 235 ns.
  - `.address` on TypedData passes memory without copying, but only to leaf calls.
  - `asTypedList` creates zero-copy views.
  - Free resources with `NativeFinalizer` plus an explicit `dispose()`.

**Web**
- **[V]** dart2wasm does not support `dart:ffi`.
  - Load the module through `dart:js_interop` and `WebAssembly.instantiate`.
  - Read memory through a `Uint8List` view of `memory.buffer`, and rebuild the view whenever memory grows.
  - `ghostty_type_json()` gives the struct layouts.

**Zig inside hooks**
- **[V]** `native_toolchain_zig` 0.3.0 has been tested with Zig 0.15 and 0.16, **not 0.17**.
- **[V]** Android needs the API level in the target triple, or a `libc.txt` pointing to the NDK.

**Rendering**
- **[V]** `Canvas.drawRawAtlas` works on Skia, Impeller and the web. Flutter GPU is still in preview and has no web support.
- **[I]** Plan:
  1. A `CustomPainter` that draws style runs and repaints only dirty rows.
  2. Later, a glyph atlas drawn with `drawRawAtlas`.

## 5. Open questions
- Does 1.0.0 build for Android from a Linux host with Zig 0.17?
- Is `-Dsimd=false` still needed on Android? Pre-1.0 builds hit a `getauxval` problem.
- Does the `.so.1` SONAME cause trouble in Android jniLibs?
- How fast is `drawRawAtlas` for a terminal grid in practice?
