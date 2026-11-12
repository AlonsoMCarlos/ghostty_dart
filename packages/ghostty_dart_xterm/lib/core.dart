/// The terminal model of `package:xterm` 4.0.0, on libghostty-vt: the
/// same names as xterm's `package:xterm/core.dart`, so code written for
/// xterm compiles after changing the import.
///
/// Parsing and the screen live in libghostty-vt (through `ghostty_dart`),
/// not in Dart: xterm's `EscapeParser` and `EscapeHandler` are not
/// provided (ADR 0004). `COMPATIBILITY.md` lists every xterm member and
/// whether it is the same, differs, is planned or will not be supported.
///
/// It provides `Terminal`, its `Buffer`s, lines, ranges and anchors,
/// xterm's value types (`CellOffset`, `CursorStyle`, `TerminalState`, …)
/// and its key and mouse handlers (`TerminalKey`, `defaultInputHandler`,
/// `defaultMouseHandler`, …). `Terminal` holds native memory: call its
/// additive `dispose()` when you are done with it.
library;

export 'src/core/buffer/buffer.dart';
export 'src/core/buffer/cell_flags.dart';
export 'src/core/buffer/cell_offset.dart';
export 'src/core/buffer/line.dart';
export 'src/core/buffer/range.dart';
export 'src/core/buffer/range_block.dart';
export 'src/core/buffer/range_line.dart';
export 'src/core/buffer/segment.dart';
export 'src/core/cell.dart';
export 'src/core/color.dart';
export 'src/core/cursor.dart';
export 'src/core/input/handler.dart';
export 'src/core/input/keys.dart';
export 'src/core/mouse/button.dart';
export 'src/core/mouse/button_state.dart';
export 'src/core/mouse/handler.dart';
export 'src/core/mouse/mode.dart';
export 'src/core/platform.dart';
export 'src/core/state.dart';
export 'src/terminal.dart';
