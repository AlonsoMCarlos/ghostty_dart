// Test helpers shared by the selection, search and text tests.

import 'package:ghostty_dart/ghostty_dart.dart';

/// The plain text of [selection], formatted by a short-lived formatter
/// of [terminal] (soft wraps kept as line breaks unless [unwrap]).
String selectedText(
  VtTerminal terminal,
  VtSelection selection, {
  bool unwrap = false,
}) {
  final formatter = TerminalFormatter(terminal, unwrap: unwrap);
  try {
    return formatter.formatText(selection: selection);
  } finally {
    formatter.dispose();
  }
}

/// The side of the square cells the gesture tests lay out, in pixels.
const testCellSize = 10;

/// The surface position of the centre of viewport cell ([x], [y]).
({double x, double y}) cellCentre(int x, int y) => (
  x: x * testCellSize + testCellSize / 2,
  y: y * testCellSize + testCellSize / 2,
);

/// A layout of [terminal] in [testCellSize] cells, without padding.
SelectionGestureGeometry testGeometry(VtTerminal terminal) =>
    SelectionGestureGeometry(
      columns: terminal.cols,
      cellWidth: testCellSize,
      screenHeight: terminal.rows * testCellSize,
    );
