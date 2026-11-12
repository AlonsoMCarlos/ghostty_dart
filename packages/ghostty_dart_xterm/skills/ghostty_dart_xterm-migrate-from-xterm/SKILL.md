---
name: ghostty_dart_xterm-migrate-from-xterm
description: How to move a Flutter app from package:xterm 4.0.0 to ghostty_dart_xterm (xterm's API on libghostty-vt). Use when replacing the xterm dependency or imports, wiring Terminal/TerminalView to a pty (flutter_pty, flutter_pty2) or an SSH session (dartssh2), disposing the terminal, or when xterm-based code behaves differently after the switch (keys, mouse rows, alternate screen, maxLines, anchors, OSC callbacks, shortcuts).
---

# Migrating from package:xterm to ghostty_dart_xterm

`ghostty_dart_xterm` keeps the public API of `xterm` 4.0.0 (`Terminal`,
`TerminalView`, `TerminalController`, `TerminalTheme`, `TerminalStyle`,
`TerminalKey`, input and mouse handlers, `SuggestionPortal`) and runs it on
libghostty-vt (Ghostty's terminal engine, via `ghostty_dart`) with
`ghostty_dart_flutter`'s renderer. It is unofficial and not affiliated with
the Ghostty project or the xterm authors. It is **not** a drop-in
replacement: `COMPATIBILITY.md` in the package lists every xterm member as
✅ same, ⚠️ differs, ❌ planned or 🚫 won't support, with the reason.
Native platforms only (Linux, macOS, Windows, Android, iOS); no web yet.

## Steps

1. pubspec: replace `xterm: ^4.0.0` with `ghostty_dart_xterm`.
2. Imports: `package:xterm/<lib>.dart` → `package:ghostty_dart_xterm/<lib>.dart`
   for `xterm`, `core`, `ui` and `suggestion`. `zmodem.dart` does not exist
   yet (keep that feature on xterm or drop it); `utils.dart` is empty (no
   `TerminalDebugger`).
3. Add `terminal.dispose()` where the terminal's owner is disposed
   (usually `State.dispose`). The terminal holds native memory;
   `TerminalView` never disposes it. After `dispose`, members that reach
   the engine throw `StateError`.
4. Keep everything else. `Terminal(maxLines:, onOutput:, onResize:,
   inputHandler:, …)`, `terminal.write`, `viewWidth`/`viewHeight`,
   `buffer.getText`, `buffer.clear()`, `buffer.setCursor(0, 0)`,
   `TerminalView(terminal, controller:, theme:, textStyle:, …)` and
   custom `TerminalInputHandler`s (virtual keyboards) work unchanged.

```dart
import 'dart:convert';

import 'package:ghostty_dart_xterm/xterm.dart'; // was package:xterm/xterm.dart

final terminal = Terminal(maxLines: 10000);

void connect(Pty pty) { // flutter_pty
  pty.output.cast<List<int>>().transform(const Utf8Decoder()).listen(terminal.write);
  terminal.onOutput = (data) => pty.write(const Utf8Encoder().convert(data));
  terminal.onResize = (w, h, pw, ph) => pty.resize(h, w);
}
```

Byte-exact alternative (additions, not in xterm): `terminal.writeBytes(Uint8List)`
for input and `terminal.onOutputBytes` for output. Set **either**
`onOutput` or `onOutputBytes`: both are called for every chunk.

## Differences to expect (check COMPATIBILITY.md for any member)

- **Keys typed into `TerminalView`** with the default `inputHandler` are
  encoded by libghostty-vt (Kitty keyboard protocol and `modifyOtherKeys`
  when the program asks; Ctrl+Backspace differs). A custom `inputHandler`
  gets every key, as in xterm. `terminal.keyInput` keeps xterm's bytes,
  except that application cursor keys follow `cursorKeysMode` (an xterm bug
  fixed).
- **Mouse reports** come from libghostty-vt with the correct row (xterm
  4.0.0 is one row low in normal/UTF-8 formats). `PointerInput.drag`/`move`
  are really reported when enabled; suspending pointer input also stops the
  wheel.
- **Shortcuts**: xterm's `defaultTerminalShortcuts` (Ctrl+V paste, Ctrl+A
  select all; Cmd on Apple). Select all includes the scrollback. Pass
  `shortcuts:` to let Ctrl+V/Ctrl+A reach the shell.
- **Inactive screen**: `mainBuffer` reads as blank lines while the
  alternate screen is active (and `altBuffer` while the main one is); its
  mutators throw `StateError`.
- **`maxLines`** is approximate (scrollback is dropped per page, so more is
  kept). No byte limit.
- **`buffer.lines`** are snapshots built on first access (about 50 µs per
  80-column line, debug); do not walk the whole scrollback every frame.
- **Reflow**: view resizes always reflow; `reflowEnabled: false` affects
  `terminal.resize` only.
- **Anchors** follow scrolling and reflow but not IL/DL or scroll-region
  moves; they hold native memory until disposed.
- **Callbacks** (`onBell`, `onTitleChange`, replies, `onPrivateOSC`,
  `onResize`) run after the written chunk is parsed, never re-entrantly.
  `onIconChange` only fires from `setIconName`. `onPrivateOSC` never sees
  OSCs Ghostty implements (for example OSC 66).
- **Emulator internals**: no `EscapeParser`; `Terminal` is not an
  `EscapeHandler`, but its handler methods write the equivalent sequence
  (and throw `StateError` mid-sequence). No `Buffer.resize`, no
  `TerminalViewState.renderTerminal`; `TerminalView.scrollController` is
  ignored.
- **One `TerminalView` per `Terminal`.** No web.

## When something looks wrong

Look the member up in `COMPATIBILITY.md`. ✅ but behaving differently from
xterm 4.0.0 is a bug worth reporting at
https://github.com/AlonsoMCarlos/ghostty_dart/issues. The human guide with
full examples (flutter_pty, flutter_pty2, dartssh2) is
`MIGRATING_FROM_XTERM.md` in the package.
