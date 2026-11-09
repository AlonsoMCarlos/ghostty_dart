import 'package:ghostty_dart/ghostty_dart.dart';

/// The text of row [y] in [space], read cell by cell through grid refs,
/// skipping spacers, stopping at the first unresolvable cell and trimming
/// trailing blanks.
String lineAt(VtTerminal terminal, PointSpace space, int y) {
  final buffer = StringBuffer();
  for (var x = 0; x < terminal.cols; x++) {
    final ref = terminal.gridRef(GridPoint(space, x, y));
    if (ref == null) break;
    if (ref.cell.width.isSpacer) continue;
    final text = ref.text;
    buffer.write(text.isEmpty ? ' ' : text);
  }
  return buffer.toString().trimRight();
}

/// `count` numbered lines, `L0` to `L<count-1>`, each ended by CRLF.
String numberedLines(int count) =>
    [for (var i = 0; i < count; i++) 'L$i\r\n'].join();
