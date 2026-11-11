/// An API-compatible replacement for `package:xterm` 4.0.0 on top of
/// libghostty-vt, Ghostty's terminal emulation engine: the same names as
/// xterm's `package:xterm/xterm.dart`, which exports `core.dart` and
/// `ui.dart`.
///
/// Migrating is meant to be an import change:
///
/// ```dart
/// // import 'package:xterm/xterm.dart';
/// import 'package:ghostty_dart_xterm/xterm.dart';
/// ```
///
/// xterm's `zmodem.dart` (exported by xterm's `xterm.dart`) is not
/// provided yet. `COMPATIBILITY.md` lists every xterm member and its
/// status.
///
/// Work in progress (ADR 0013): see `core.dart` for what exists today.
library;

export 'core.dart';
export 'ui.dart';
