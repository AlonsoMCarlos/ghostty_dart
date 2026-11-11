// Ported from package:xterm 4.0.0 (lib/src/core/mouse/reporter.dart).
// Copyright (c) 2020 xuty. MIT License, see LICENSE.xterm.
// Changed: the row is encoded as `32 + y` in the normal and utf formats;
// xterm encodes `32 + y + 1`, one row too low.

import '../buffer/cell_offset.dart';
import 'button.dart';
import 'button_state.dart';
import 'mode.dart';

/// Encodes mouse reports for `ClickMouseHandler` and `UpDownMouseHandler`.
///
/// Not exported, as in xterm. `TerminalView` reports the mouse with
/// libghostty's encoder; this one serves `Terminal.mouseInput` and custom
/// mouse handlers.
abstract class MouseReporter {
  /// Encodes [button] in [state] at the 0-based cell [position] in
  /// [reportMode]: `CSI M` with three bytes for [MouseReportMode.normal]
  /// and [MouseReportMode.utf], `CSI < b ; x ; y M/m` for
  /// [MouseReportMode.sgr], `CSI b ; x ; y M` for [MouseReportMode.urxvt].
  ///
  /// The position is sent 1-based. In the normal and utf formats a
  /// coordinate beyond the format's range (223 and 2015) is sent as a NUL
  /// character, as in xterm.
  static String report(
    TerminalMouseButton button,
    TerminalMouseButtonState state,
    CellOffset position,
    MouseReportMode reportMode,
  ) {
    // x and y offsets have to be incremented by 1 as the offset if 0-based,
    // The position has to be reported using 1-based coordinates.
    final x = position.x + 1;
    final y = position.y + 1;
    switch (reportMode) {
      case MouseReportMode.normal:
      case MouseReportMode.utf:
        // Button ID 3 is used to signal a button release.
        final buttonID = state == TerminalMouseButtonState.up ? 3 : button.id;
        // The button ID is reported as shifted by 32 to produce a printable
        // character.
        final btn = String.fromCharCode(32 + buttonID);
        // Normal mode only supports a maximum position of 223, while utf
        // supports positions up to 2015. Both modes send a null byte if the
        // position exceeds that limit.
        final col =
            (reportMode == MouseReportMode.normal && x > 223) ||
                (reportMode == MouseReportMode.utf && x > 2015)
            ? '\x00'
            : String.fromCharCode(32 + x);
        // Changed from xterm (`32 + y + 1`): `y` is already 1-based.
        final row =
            (reportMode == MouseReportMode.normal && y > 223) ||
                (reportMode == MouseReportMode.utf && y > 2015)
            ? '\x00'
            : String.fromCharCode(32 + y);
        return "\x1b[M$btn$col$row";
      case MouseReportMode.sgr:
        final buttonID = button.id;
        final upDown = state == TerminalMouseButtonState.down ? 'M' : 'm';
        return "\x1b[<$buttonID;$x;$y$upDown";
      case MouseReportMode.urxvt:
        // The button ID uses the same id as to report it as in normal mode.
        final buttonID =
            32 + (state == TerminalMouseButtonState.up ? 3 : button.id);
        return "\x1b[$buttonID;$x;${y}M";
    }
  }
}
