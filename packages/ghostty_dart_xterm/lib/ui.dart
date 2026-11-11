/// The Flutter widgets of `package:xterm` 4.0.0 (`TerminalView`,
/// `TerminalController`, themes and styles), drawn by
/// `ghostty_dart_flutter`: the same names as xterm's
/// `package:xterm/ui.dart`.
///
/// ```dart
/// TerminalView(terminal, controller: controller, autofocus: true)
/// ```
///
/// xterm's debugger (`TerminalDebugger`, `TerminalDebuggerView`) is not
/// provided: it is built on xterm's Dart escape parser (ADR 0013).
/// `COMPATIBILITY.md` lists every xterm member and its status.
library;

export 'src/terminal_view.dart';
export 'src/ui/controller.dart';
export 'src/ui/cursor_type.dart';
export 'src/ui/keyboard_visibility.dart';
export 'src/ui/pointer_input.dart';
export 'src/ui/selection_mode.dart';
export 'src/ui/shortcut/shortcuts.dart';
export 'src/ui/terminal_text_style.dart';
export 'src/ui/terminal_theme.dart';
export 'src/ui/themes.dart';
