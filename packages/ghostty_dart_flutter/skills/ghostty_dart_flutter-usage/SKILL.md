---
name: ghostty_dart_flutter-usage
description: How to embed a terminal in a Flutter app with ghostty_dart_flutter (VtTerminalController + VtTerminalView on libghostty-vt). Use when adding a terminal widget, connecting it to a pty, socket or SSH channel, theming it, handling copy/paste, resize, focus or soft keyboards, or migrating a screen from package:xterm.
---

# Using ghostty_dart_flutter

`ghostty_dart_flutter` is a Flutter terminal widget on top of
`ghostty_dart`, the Dart bindings for libghostty-vt (Ghostty's terminal
emulation engine). It is unofficial and not affiliated with the Ghostty
project. Native platforms only for now (Linux, macOS, Windows, Android,
iOS); there is no web support until `ghostty_dart` has a wasm backend.

## The two objects

- `VtTerminalController` owns the terminal (a `VtTerminal` from
  `package:ghostty_dart`). It is pty-agnostic: you write the program's
  output into it and forward its `onOutput` bytes to the program's input.
- `VtTerminalView` draws a controller and takes keyboard, IME, mouse and
  touch input. It never disposes the controller.

```dart
import 'package:flutter/material.dart';
import 'package:ghostty_dart_flutter/ghostty_dart_flutter.dart';

class TerminalPage extends StatefulWidget {
  const TerminalPage({super.key, required this.connection});
  final MyConnection connection; // your pty, socket or SSH channel

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage> {
  late final VtTerminalController controller = VtTerminalController(
    onOutput: widget.connection.write, // Uint8List: keys, pastes, replies
    onResize: (cols, rows, pixelWidth, pixelHeight) =>
        widget.connection.resize(rows: rows, cols: cols),
    onTitleChanged: (title) => setState(() {}),
  );

  @override
  void initState() {
    super.initState();
    widget.connection.output.listen(controller.writeBytes); // Uint8List
  }

  @override
  void dispose() {
    controller.dispose(); // the app owns the controller
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => VtTerminalView(
    controller: controller,
    autofocus: true,
    textStyle: const TextStyle(fontFamily: 'JetBrains Mono', fontSize: 14),
  );
}
```

## Rules that matter

- **Feed bytes, not strings**, when you have bytes: `writeBytes(Uint8List)`
  avoids a UTF-8 round trip; `write(String)` is for text you build in Dart.
- **Never call `controller.terminal.write`** or dispose
  `controller.terminal`; go through the controller so the view is notified
  and the output callbacks are delivered.
- **Callbacks are never re-entrant.** `onOutput`, `onBell` and
  `onTitleChanged` are delivered after the terminal finishes parsing, so a
  callback may call `write` again (a local echo).
- **Size comes from layout.** The view needs bounded constraints; with
  `autoResize: true` (default) it fits the largest grid of whole cells and
  reports it once per change through `onResize`, after the frame. Forward
  that to the pty (`TIOCSWINSZ`), or programs will wrap at the wrong width.
- **Bundle a monospace font.** Cells are measured from `textStyle`; Flutter
  has no portable monospace family. Without a font the view falls back to
  `VtTerminalView.defaultTextStyle` (platform monospace fonts by name).
- **Colours live on the controller:** `controller.theme = VtTerminalTheme(...)`
  (or `VtTerminalTheme.defaultTheme`, `VtTerminalTheme.whiteOnBlack`). Do not
  set it from `build`.
- **One controller, one view.** Dispose the controller when done; it is safe
  to call twice, and every other member throws `StateError` afterwards.

## Input behaviour (differs from package:xterm)

- Ctrl+V and Ctrl+A reach the shell (literal next, start of line).
- Copy: Ctrl+Shift+C or Ctrl+Insert; paste: Ctrl+Shift+V or Shift+Insert.
  On macOS and iOS: Cmd+C and Cmd+V. Override with `shortcuts:`.
- Pasting text with a newline into a program without bracketed paste is
  refused unless `onUnsafePaste` returns `true` (Ghostty's paste
  protection). Show your own confirmation dialog there.
- While the program tracks the mouse, presses, motion and the wheel are
  reported to it; hold Shift to select instead.
- `readOnly: true` sends nothing to the program; selection and scrolling
  still work.
- Touch screens: add `VtTerminalKeyToolbar(controller: ...)` for Esc, Ctrl,
  Alt, Tab and arrows.

## Connecting a real shell

The package has no pty dependency. On desktop, `flutter_pty2` (pin an
exact version; its build hook compiles C, so it needs clang, Xcode or MSVC)
works: `session = await Pty.spawn(PtySpawnOptions(executable: shell,
size: PtySize(columns: cols, rows: rows)))`, `session.output` to
`controller.writeBytes`, `onOutput` to `session.input.tryWrite` (or the
asynchronous `session.input.write` when it reports `backpressured`),
`onResize` to `session.resize(PtySize(columns: cols, rows: rows))`, and
`session.done` for the exit. `close()` sends SIGKILL; to hang up a shell
the way closing a terminal does, send `PosixSignal.hup` to
`PosixSignalTarget.shellProcessGroup` first (Unix only). The repository's
`apps/demo` (`lib/src/shell/pty_shell.dart`) does exactly this, including
restart on exit and the fallback when no pty can be started.

## Native library

`ghostty_dart`'s build hook supplies libghostty-vt: by default it downloads
a prebuilt binary pinned by sha256 and fails closed on mismatch. Offline or
custom builds use `hooks: user_defines: ghostty_dart: source: path|system`
in the app's root `pubspec.yaml` (see the `ghostty_dart` README).
