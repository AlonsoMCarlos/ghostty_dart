# Migrating from xterm 4.0.0

**English** | [Español](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/packages/ghostty_dart_xterm/MIGRATING_FROM_XTERM.es.md)

`ghostty_dart_xterm` keeps the public API of
[`xterm`](https://pub.dev/packages/xterm) 4.0.0 and replaces what is under
it: libghostty-vt parses the output and holds the screen, and
`ghostty_dart_flutter` draws it. This guide is for app authors. The
complete, generated list of members is
[`COMPATIBILITY.md`](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/packages/ghostty_dart_xterm/COMPATIBILITY.md);
this page explains the differences that matter in practice.

## 1. Change the dependency and the imports

```yaml
dependencies:
  # xterm: ^4.0.0
  ghostty_dart_xterm: ^0.1.0
```

Every xterm library has a counterpart with the same name:

| `xterm` 4.0.0 | `ghostty_dart_xterm` |
|---|---|
| `package:xterm/xterm.dart` | `package:ghostty_dart_xterm/xterm.dart` |
| `package:xterm/core.dart` | `package:ghostty_dart_xterm/core.dart` (no widgets, as in xterm) |
| `package:xterm/ui.dart` | `package:ghostty_dart_xterm/ui.dart` |
| `package:xterm/suggestion.dart` | `package:ghostty_dart_xterm/suggestion.dart` |
| `package:xterm/zmodem.dart` | Not yet (it needs the `zmodem` package) |
| `package:xterm/utils.dart` | Exists but is empty: the debugger is built on xterm's Dart parser |

`xterm.dart` exports `core.dart` and `ui.dart`; unlike xterm's, it does not
export `zmodem.dart` yet.

## 2. Dispose the terminal

A `Terminal` holds native memory (the libghostty-vt terminal) that Dart's
garbage collector does not see. Call `terminal.dispose()` when you are done
with it, usually in your `State.dispose`. `TerminalView` never disposes it,
as in xterm. Afterwards every member that reaches the engine throws
`StateError`. A terminal you never dispose is freed by a finalizer
eventually, but not promptly.

```dart
@override
void dispose() {
  terminal.dispose(); // not in xterm
  super.dispose();
}
```

## 3. Typical code, unchanged

xterm's own examples run with only the import changed; the package's tests
keep them compiling
([`test/migration/`](https://github.com/AlonsoMCarlos/ghostty_dart/tree/main/packages/ghostty_dart_xterm/test/migration)).

### A local shell with `flutter_pty`

```dart
import 'dart:convert';

import 'package:flutter_pty/flutter_pty.dart';
import 'package:ghostty_dart_xterm/xterm.dart';

final terminal = Terminal(maxLines: 10000);

void startShell(String shell) {
  final pty = Pty.start(
    shell,
    columns: terminal.viewWidth,
    rows: terminal.viewHeight,
  );
  pty.output
      .cast<List<int>>()
      .transform(const Utf8Decoder())
      .listen(terminal.write);
  terminal.onOutput = (data) => pty.write(const Utf8Encoder().convert(data));
  terminal.onResize = (w, h, pw, ph) => pty.resize(h, w);
}
```

### A local shell with `flutter_pty2`, without string round trips

The additions `writeBytes` and `onOutputBytes` take and give bytes. Use
them instead of `write` and `onOutput`, not with them: both output
callbacks are called for every chunk.

```dart
import 'package:flutter_pty2/flutter_pty2.dart';
import 'package:ghostty_dart_xterm/xterm.dart';

Future<void> startShell(Terminal terminal, String shell) async {
  final session = await Pty.spawn(
    PtySpawnOptions(
      executable: shell,
      size: PtySize(columns: terminal.viewWidth, rows: terminal.viewHeight),
    ),
  );
  session.output.listen(terminal.writeBytes);
  terminal.onOutputBytes = (bytes) => session.input.write(bytes);
  terminal.onResize = (w, h, pw, ph) =>
      session.resize(PtySize(columns: w, rows: h));
}
```

### An SSH session with `dartssh2`

```dart
final session = await client.shell(
  pty: SSHPtyConfig(width: terminal.viewWidth, height: terminal.viewHeight),
);
terminal.buffer.clear();
terminal.buffer.setCursor(0, 0);
terminal.onTitleChange = (title) => setState(() => this.title = title);
terminal.onResize = (w, h, pw, ph) => session.resizeTerminal(w, h, pw, ph);
terminal.onOutput = (data) => session.write(utf8.encode(data));
session.stdout
    .cast<List<int>>()
    .transform(const Utf8Decoder())
    .listen(terminal.write);
```

A virtual keyboard written as `class VirtualKeyboard extends
TerminalInputHandler with ChangeNotifier` and passed as
`Terminal(inputHandler: keyboard)` works as in xterm.

## 4. What behaves differently

### Keys

- **Typed into `TerminalView`, with the default `inputHandler`:** keys are
  encoded by libghostty-vt, like in the Ghostty app. Most bytes are the
  same as xterm's keytab. They differ where libghostty-vt follows a
  protocol the program asked for (the Kitty keyboard protocol,
  `modifyOtherKeys`) or a common terminal convention, for example
  Ctrl+Backspace. AltGr and IME input work as on any desktop terminal.
- **With your own `inputHandler`** (a virtual keyboard, remapped keys):
  every key goes to it, as in xterm, and its output is sent unchanged.
- **`terminal.keyInput(...)`** always runs xterm's handler chain, so its
  bytes match xterm, with one fix: application cursor keys follow DECCKM
  (`cursorKeysMode`); xterm 4.0.0 reads the keypad mode there.

### Shortcuts

`TerminalView` keeps xterm's `defaultTerminalShortcuts`: Ctrl+Shift+C
copies, Ctrl+V pastes and Ctrl+A selects all (Cmd on Apple platforms). Two
details differ: select all includes the scrollback, not only the screen,
and paste never asks for confirmation (as in xterm; `ghostty_dart_flutter`'s
own view holds back unsafe pastes). If you want Ctrl+V and Ctrl+A to reach
the shell, pass your own `shortcuts:`.

### Mouse

- Mouse reports to the program come from libghostty-vt's encoder: every
  format, and the **correct row**. xterm 4.0.0 reports one row too low in
  its normal and UTF-8 formats; programs that compensated for it will be
  off by one the other way.
- `TerminalController.setPointerInputs` with `drag` or `move` really
  reports drags and motion (xterm 4.0.0 never does). Suspending pointer
  input (`setSuspendPointerInput`) also stops wheel reports.
- `onTapUp` is called for a click that selected nothing and was not
  reported to the program.

### The screen and the scrollback

- **The inactive screen reads as blank.** libghostty-vt exposes only the
  active screen, so while a full-screen program (vim, htop) uses the
  alternate screen, `terminal.mainBuffer` reads as blank lines with the
  cursor at 0, 0, and the other way round. Read the buffer you need while
  it is active.
- **`maxLines` is approximate.** libghostty-vt drops scrollback in whole
  pages, so more lines than `maxLines` are kept (about 300 at 80 columns
  with `maxLines: 30`). There is no byte limit.
- **Lines are snapshots.** `buffer.lines[i]` is built from the engine on
  first access and cached until the terminal changes; changing a
  `BufferLine` you read changes only that copy. Fine for copying and
  searching, too slow to walk the whole scrollback every frame.
- **Reflow.** A `TerminalView` resize always reflows the text;
  `reflowEnabled: false` applies to `terminal.resize(...)` only. Without
  reflow, cells beyond a narrower width are dropped rather than kept for a
  later, wider resize.
- **Anchors** (`buffer.createAnchor`, selections) are tracked by
  libghostty-vt: they follow scrolling and reflow, but not lines moved by
  inserting or deleting lines (IL, DL) or by a scroll region. Each one
  holds a little native memory until it is disposed.
- **Scroll margins** (DECSTBM) are not exposed: `Buffer.marginTop` and
  `marginBottom` do not follow what the program set.

### Callbacks

- Events raised by output (`onBell`, `onTitleChange`, replies on
  `onOutput`, `onPrivateOSC`, `onResize`) are delivered in order **after**
  the chunk passed to `write` is parsed, not in the middle of it. A
  callback may call `write` again.
- `onIconChange` only fires from `setIconName`: libghostty-vt 1.0.0 does
  not report the icon name of OSC 0 and OSC 1.
- `onPrivateOSC` only sees OSC sequences libghostty-vt does not implement
  itself. Ghostty implements many that xterm forwarded (for example OSC 66,
  Kitty's text sizing), so those never reach it.
- `onOutput` gets bytes from libghostty-vt (keys and mouse reports typed
  into the view, replies to queries) decoded as UTF-8, or as Latin-1 for a
  chunk that is not valid UTF-8. `onOutputBytes` has the exact bytes.
- `onResize` receives, when the view resizes the terminal, the cell size
  in logical pixels, from the view's device pixel ratio, as xterm computes
  it; it is called only when the size changes.

### Emulator internals

- `Terminal` is not an `EscapeHandler`, and `EscapeParser` does not exist:
  parsing is native. The handler methods on `Terminal` (`setCursor`,
  `eraseDisplay`, `useAltBuffer`, …) still work: each writes the equivalent
  escape sequence. They throw `StateError` while the output stopped in the
  middle of a sequence. Methods with no sequence (`unknownCSI`, …) do
  nothing.
- `Buffer.clear()` and `setCursor()` work through sequences on the active
  buffer; `Buffer.resize` is not supported (resize the terminal instead).
- `TerminalViewState.renderTerminal` does not exist: the render object is
  `ghostty_dart_flutter`'s. `TerminalView.scrollController` is accepted and
  ignored, because libghostty-vt owns scrolling.

### One view, native platforms

- Show a `Terminal` in **one `TerminalView` at a time**.
- **No web yet.** The package runs on Linux, macOS, Windows, Android and
  iOS. Web needs a wasm backend in `ghostty_dart`; until then, an app that
  targets the web has to keep `xterm` there.
- Cells are measured from the font and snapped to device pixels, so a
  cell can be slightly larger or smaller than xterm's for the same
  `TerminalStyle`, and a screen can fit one column more or less.

## 5. If something does not work

Check the member in
[`COMPATIBILITY.md`](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/packages/ghostty_dart_xterm/COMPATIBILITY.md).
If it says ✅ and behaves differently from xterm 4.0.0, that is a bug:
please [open an issue](https://github.com/AlonsoMCarlos/ghostty_dart/issues)
with the smallest code that shows it.
