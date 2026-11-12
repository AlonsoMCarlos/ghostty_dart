# Changelog

## [0.1.1](https://github.com/AlonsoMCarlos/ghostty_dart/compare/ghostty_dart_xterm-v0.1.0...ghostty_dart_xterm-v0.1.1) (2026-11-12)


### Bug Fixes

* **ghostty_dart_xterm:** ship xterm.dart's licence notice in NOTICES ([9fe8cf9](https://github.com/AlonsoMCarlos/ghostty_dart/commit/9fe8cf9dab247e0c6529d5647929825077dfee9f))

## 0.1.0

- Initial release.
- The public API of `package:xterm` 4.0.0 on libghostty-vt: the
  `xterm.dart`, `core.dart`, `ui.dart`, `suggestion.dart` and `utils.dart`
  libraries with xterm's names, parameters and defaults.
  - `Terminal` owns a `VtTerminalController`; output is parsed by
    libghostty-vt. xterm's `EscapeHandler` methods on `Terminal` write the
    equivalent sequence. `Buffer`, `BufferLine` and `CellAnchor` read the
    engine's active screen.
  - `TerminalView` draws through `ghostty_dart_flutter`'s `VtTerminalView`;
    `TerminalController` (selection, highlights, pointer inputs), themes,
    `TerminalStyle` and `defaultTerminalShortcuts`.
  - xterm's keytab, key and mouse handlers (`TerminalKey`,
    `defaultInputHandler`, `defaultMouseHandler`), value types and
    `SuggestionPortal`, ported from xterm 4.0.0 (MIT, `LICENSE.xterm`).
  - Additions beyond xterm: `Terminal.dispose`, `Terminal.writeBytes` and
    `Terminal.onOutputBytes`.
- Differs from xterm 4.0.0 where libghostty-vt does (keys typed into the
  view, mouse rows, the inactive screen, `maxLines`, anchors, OSC
  callbacks): every member's status is in `COMPATIBILITY.md`, generated
  from both APIs, and the practical differences are in
  `MIGRATING_FROM_XTERM.md`. Not provided: `zmodem.dart` (planned), the
  debugger and `EscapeParser`.
- xterm's own tests are ported under `test/compat/`, and its `flutter_pty`
  and `dartssh2` examples compile and run with only the import changed
  (`test/migration/`). `example/` is xterm's mock-shell example.
