// Helpers for the render module's tests.

import 'package:ghostty_dart/ghostty_dart.dart';

import '../support/terminal_support.dart';

/// Creates a terminal and a render state, runs [body] and disposes both.
R withRender<R>(
  int cols,
  int rows,
  R Function(VtTerminal terminal, RenderState state) body,
) => withTerminal(cols, rows, (terminal) {
  final state = RenderState();
  try {
    return body(terminal, state);
  } finally {
    state.dispose();
  }
});

/// The text of [row] with spacers skipped and empty cells as spaces,
/// trailing spaces trimmed.
String rowText(RenderRow row) {
  final buffer = StringBuffer();
  for (var x = 0; x < row.length; x++) {
    if (row.widthAt(x).isSpacer) continue;
    if (row.hasTextAt(x)) {
      row.writeTextTo(x, buffer);
    } else {
      buffer.write(' ');
    }
  }
  return buffer.toString().trimRight();
}

/// The text of every captured row of [state], top to bottom.
List<String> stateLines(RenderState state) => [
  for (final row in state.allRows) rowText(row),
];

/// The snapshot of row [y] of [state] (an [RenderRow.cellsToList] copy).
List<RenderCell> rowCells(RenderState state, int y) =>
    state.allRows.elementAt(y).cellsToList();
