/// Dart bindings for libghostty-vt, the terminal emulation engine of Ghostty.
///
/// Create a [VtTerminal], feed it the bytes a program writes to its pty, and
/// read back its state:
///
/// ```dart
/// import 'dart:convert';
///
/// import 'package:ghostty_dart/ghostty_dart.dart';
///
/// void main() {
///   final terminal = VtTerminal(cols: 80, rows: 24);
///   try {
///     terminal.write(utf8.encode('Hello, \x1b[1;32mworld\x1b[0m!\r\n'));
///     terminal.resize(120, 40, cellWidthPx: 9, cellHeightPx: 18);
///     print('${terminal.cols}x${terminal.rows} on $libghosttyVtVersion');
///   } finally {
///     terminal.dispose();
///   }
/// }
/// ```
///
/// ## Where to start
///
/// - **The emulator:** [VtTerminal] (state, options, modes, viewport,
///   paste) and its callbacks in [VtTerminalEffects] (`onWritePty`,
///   `onBell`, `onTitleChanged`, clipboard, ...).
/// - **Drawing:** [RenderState] for dirty rows, cells, styles, colours,
///   the cursor and image placements, once per frame.
/// - **Input:** [KeyEncoder] and [MouseEncoder], synced with the terminal's
///   modes; [encodePaste], [encodeFocusEvent] and the report encoders.
/// - **Text:** selections ([VtTerminalSelection], [SelectionGesture]),
///   [TerminalSearch], and [TerminalFormatter] for plain text, VT or HTML.
/// - **Random access:** [VtTerminalGrid] for cells and rows anywhere in the
///   scrollback, and [TrackedGridRef]s that follow a cell.
/// - **State and images:** [VtTerminalSnapshot] / [SnapshotDecoder] and
///   [VtTerminalKittyGraphics].
/// - **Without a terminal:** [OscParser], [SgrParser], colour parsing
///   ([parseColor]), Unicode cell widths ([textCellWidth]) and process-wide
///   settings such as [setVtLogHandler].
///
/// ## Ownership and errors
///
/// Native objects are owned by their Dart wrappers: call `dispose()` when you
/// are done (a finalizer is the safety net). Using an object after
/// `dispose()` throws [StateError]. Errors from the library are thrown as
/// [GhosttyException], features missing from the loaded build as
/// [UnsupportedError], and an unsupported library version (not 1.x) as
/// [IncompatibleLibraryException]. Check optional features with
/// [libghosttyVtBuildInfo].
library;

export 'src/color/color.dart';
export 'src/core/core.dart';
export 'src/grid/grid.dart';
export 'src/input/input.dart';
export 'src/kitty/kitty.dart';
export 'src/parsers/parsers.dart';
export 'src/render/render.dart';
export 'src/search/search.dart';
export 'src/selection/selection.dart';
export 'src/snapshot/snapshot.dart';
export 'src/sys/sys.dart';
export 'src/terminal/terminal.dart' hide adoptNativeTerminal;
export 'src/text/text.dart';
export 'src/unicode/unicode.dart';
