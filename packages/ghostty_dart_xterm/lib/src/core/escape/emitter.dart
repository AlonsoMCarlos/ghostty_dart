// Ported from package:xterm 4.0.0 (lib/src/core/escape/emitter.dart).
// Copyright (c) 2020 xuty. MIT License, see LICENSE.xterm.

/// The replies xterm's `Terminal` sends for its `send*` methods, and its
/// bracketed paste wrapper. Never exported, as in xterm.
class EscapeEmitter {
  /// Creates the emitter.
  const EscapeEmitter();

  /// Primary device attributes (DA1).
  String primaryDeviceAttributes() {
    return '\x1b[?1;2c';
  }

  /// Secondary device attributes (DA2).
  String secondaryDeviceAttributes() {
    const model = 0;
    const version = 0;
    return '\x1b[>$model;$version;0c';
  }

  /// Tertiary device attributes (DA3).
  String tertiaryDeviceAttributes() {
    return '\x1bP!|00000000\x1b\\';
  }

  /// Operating status report: "OK".
  String operatingStatus() {
    return '\x1b[0n';
  }

  /// Cursor position report with xterm's [x] and [y], as given.
  String cursorPosition(int x, int y) {
    return '\x1b[$y;${x}R';
  }

  /// [text] wrapped in bracketed-paste markers.
  String bracketedPaste(String text) {
    return '\x1b[200~$text\x1b[201~';
  }

  /// Text area size report, in characters.
  String size(int rows, int cols) {
    return '\x1b[8;$rows;${cols}t';
  }
}
