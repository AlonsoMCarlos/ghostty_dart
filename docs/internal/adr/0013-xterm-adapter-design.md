# 0013. `ghostty_dart_xterm` design: an xterm 4.0.0 adapter over the widget's controller

**Status:** Accepted (2026-11-11). Refines ADR 0004 (xterm compatibility as a thin adapter); ADR 0004 stays in force. Plan run: `.claude/plan-runs/20261111-xterm-adapter/` (research `investigacion/00-xterm-api.md`, `00-xterm-tests.md`, `00-gap-analysis.md`; cross-task names in `contratos.md`).

## Context
- ADR 0004 decided the adapter's goal (xterm 4.0.0's public API, migration by import change, no "drop-in" claim without evidence) but not its shape.
- xterm 4.0.0 exports 64 symbols and ~1,000 members from `xterm.dart` (`core.dart`, `ui.dart`, `zmodem.dart`), plus `utils.dart` and `suggestion.dart`. Several public signatures expose types xterm never exports (`IndexAwareCircularBuffer`, `Keytab`, `Charset`, `RenderTerminal`, `Event`), and typos are API (`isItalis`, `setTapStop`, `KeyboardVisibilty`).
- A sample of real apps (research §6) uses a small core: `Terminal(maxLines, onOutput, onResize, …)`, `write`, `viewWidth/viewHeight`, `TerminalView` parameters, `TerminalController.selection`, `buffer.getText`, `buffer.lines[i]`, and also the `Buffer` mutators `clear()` and `setCursor(0, 0)` (xterm's own SSH example). Custom `inputHandler`s (virtual keyboards) are common; custom `mouseHandler`s are rare.
- `ghostty_dart_flutter`'s `VtTerminalView` only accepts a concrete `VtTerminalController`, and its seams are internal on purpose (ADR 0011). It has no highlights, no key/text/mouse hooks, no select-all action, no word separators or block-drag option, and no cursor rectangle on its state.
- `VtTerminalController` already handles what the adapter would otherwise re-implement: callback queueing outside `vt_write`, render holds, theme pushing, scroll to bottom on input, resizing during layout.

## Decision

**Composition.** `Terminal` (`with Observable implements TerminalState`, as in xterm) owns a `VtTerminalController`; it does not extend it, so the controller's API never appears as xterm members and xterm's `Observable` (with its public `listeners` set) does not clash with `ChangeNotifier`. `TerminalView` builds a `VtTerminalView` on that controller. The adapter reaches the controller through an internal seam (`lib/src/internal/terminal_internals.dart`, an `Expando` bound by `Terminal`'s constructor), never through public API.

**Libraries.** The adapter mirrors xterm's library files: `xterm.dart` (exports `core.dart` and `ui.dart`), `core.dart`, `ui.dart`, `utils.dart` and `suggestion.dart`, with `lib/src/` laid out like xterm's. `core.dart` does not import `widgets` (foundation, painting and the widget package's controller are acceptable). `zmodem.dart` is ❌ planned: it needs the `zmodem` package as a new dependency, a separate decision. `utils.dart` exists but exports nothing: xterm's `TerminalDebugger` is built on its Dart parser, 🚫. `suggestion.dart` (`SuggestionPortal`) is ported, since it is terminal-independent and only needs the view's `globalCursorRect`.

**Ported code.** Pure Dart parts of xterm are ported verbatim with an MIT header per file, the original licence in `LICENSE.xterm` (kept separate so that `LICENSE` stays a single MIT text for pana's licence detection): the value types (`CellOffset`, ranges, segments, `CellData` and its constants, `CursorStyle`, `TerminalState`, `TerminalTargetPlatform`, mouse modes), `TerminalKey` with its exact value order, the keytab and the input and mouse handler classes, `charInput`, themes, `TerminalStyle`, `defaultTerminalShortcuts`, `KeyboardVisibilty`, `PointerInputs`. Every public member gets dartdoc (our lint), which does not change the API.

**Keys.** `Terminal.keyInput` runs xterm's `inputHandler` chain, so its bytes match xterm. `TerminalView` encodes keys with libghostty's encoder (Kitty protocol, releases, AltGr, the IME rules of ADR 0011) while `terminal.inputHandler` is xterm's `defaultInputHandler` (checked with `identical`), and routes keys and committed text through the custom handler otherwise, through hooks the widget gains (below). xterm's `KeytabInputHandler` reads `appKeypadMode` where it means `cursorKeysMode`; the port fixes it (⚠️, documented).

**Mouse.** The view's mouse reports come from libghostty's encoder: correct rows, all formats. xterm's off-by-one row is not copied (⚠️). `TerminalController.pointerInputs` gates reports the way xterm 4.0.0 does in practice: taps per `PointerInput.tap`, the wheel always, drag and motion only when `drag` / `move` are enabled (xterm never reports them, ⚠️ as an addition). A custom `mouseHandler` replaces the native report.

**Shortcuts.** `TerminalView` defaults to xterm's `defaultTerminalShortcuts` (Ctrl+Shift+C copy, Ctrl+V paste, Ctrl+A select all; Cmd on Apple platforms), because the adapter promises xterm's behaviour. `ghostty_dart_flutter`'s own default keeps leaving Ctrl+V and Ctrl+A to the shell (ADR 0011).

**`EscapeHandler` methods on `Terminal`.** The ~98 public handler methods (`setCursor`, `eraseDisplay`, `useAltBuffer`, …) are emulated by writing the equivalent sequence while the parser is in its ground state, and throw `StateError` otherwise (never corrupting a sequence in flight). Methods with no sequence (`unknownCSI`, `unsupportedStyle`, …) are no-ops (⚠️). Subclassing or implementing `EscapeHandler`/`EscapeParser` stays 🚫 (ADR 0004).

**Buffer.** `Buffer`, `BufferLine` and `CellData` are read views materialised lazily from libghostty and cached until the next write. `BufferLine` stays a concrete, constructible class (xterm's tests build one standalone). `Buffer.clear()` and `setCursor()` (used in the wild) and the other mutators that have an equivalent sequence work through sequences on the active buffer; the rest are 🚫 with a reason. `CellOffset.y` counts from the oldest scrollback row, which is libghostty's `PointSpace.screen`.

**Additive members.** `Terminal.dispose()` (the terminal holds native memory the GC does not see; `TerminalView` never disposes it, as in xterm), `Terminal.writeBytes(Uint8List)`, and `Terminal.onOutputBytes` (byte-exact output, for X10 mouse reports that are not UTF-8; `onOutput` decodes UTF-8 and falls back to Latin-1). Additions never change an existing xterm member.

**Widget hooks (`ghostty_dart_flutter`, additive).** The view gains, as public, documented, xterm-agnostic API: a key hook and a text hook before encoding, a mouse report filter and a mouse hook, a select-all action, word boundary characters and a rectangle-drag option, `cursorRect` / `globalCursorRect` / `hasInputConnection` on its state; the controller gains highlights (tracked ranges painted over the text, under the selection). Exact names and signatures are frozen in the plan's `contratos.md`. The seams of ADR 0011 stay internal.

**Known limits of libghostty-vt 1.0.0**, each a ⚠️ row: OSC 1 (icon name) never reaches `onIconChange`; the inactive screen cannot be read (`mainBuffer` while the alternate screen is up); `reflowEnabled` has no effect; `onPrivateOSC` only sees OSCs libghostty does not implement; DECSTBM margins are not exposed; one `TerminalView` per `Terminal`; `onResize`'s pixel values are converted to xterm's cell size from the view's device pixel ratio.

**Evidence (ADR 0004).** `COMPATIBILITY.md` is generated: a tool snapshots xterm 4.0.0's API with the analyzer from the workspace's locked xterm (fail-closed on the lock's sha256 and a hash of xterm's `lib/`) into a committed JSON, a hand-kept status file gives the ⚠️/🚫/❌ reasons, and an analyzer pass over the adapter proves presence; CI checks the file is current. xterm's MIT tests are ported to `test/compat/` with hand-written fakes (no mockito); expected divergences are skipped with a reason that points at `COMPATIBILITY.md`.

**Platforms and publishing.** Native platforms only, like `ghostty_dart_flutter`, until `ghostty_dart` has its wasm backend. The package is a workspace member at `0.0.1-dev` and is not published until the maintainer approves (ADR 0010).

## Consequences
- Typical `flutter_pty` and `dartssh2` apps should migrate with an import change; low-level users of the emulator internals get a precise list of what changed.
- The widget package grows a small public hook API that also serves non-xterm users (custom key handling, highlights for search).
- Native memory must be released with the additive `Terminal.dispose()`; apps that never call it rely on finalizers. `MIGRATING_FROM_XTERM` says so prominently.
- Keys typed into a `TerminalView` produce libghostty's bytes, which differ from xterm's keytab in places (Kitty, modifyOtherKeys, Ctrl+Backspace); `Terminal.keyInput` and custom handlers keep xterm's bytes.
- Web apps cannot migrate until the wasm backend exists.
- The adapter depends on the unpublished `ghostty_dart_flutter`; neither is published before the other is ready.

## Amendment (2026-11-12)

The maintainer approved publishing the adapter once `ghostty_dart_flutter` 0.1.0 was on pub.dev. It is versioned `0.1.0` and released by the same pipeline as the other two packages (ADR 0010, amendment of 2026-11-12 (2)); "Platforms and publishing" and the last consequence above describe the state before that.
