import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart_xterm/core.dart';

BufferLine lineOf(String text, [int length = 10]) {
  final line = BufferLine(length);
  var i = 0;
  for (final rune in text.runes) {
    line.setCodePoint(i, rune);
    i += line.getWidth(i).clamp(1, 2);
  }
  return line;
}

void main() {
  group('a standalone BufferLine', () {
    test('is writable and not attached', () {
      final line = lineOf('ABCDEF');
      expect(line.length, 10);
      expect(line.attached, isFalse);
      expect(() => line.index, throwsStateError);
      expect(line.getText(), 'ABCDEF');
      expect(line.getTrimmedLength(), 6);
      expect(line.getTrimmedLength(1000), 6);
      expect(line.getTrimmedLength(-1000), 0);
      expect(line.isWrapped, isFalse);
      expect(BufferLine(3, isWrapped: true).isWrapped, isTrue);
    });

    test('uses xterm Unicode 11 widths', () {
      final line = lineOf('a😀b');
      expect(line.getWidth(1), 2);
      expect(line.getText(), 'a😀b');
      expect(line.getTrimmedLength(), 4);
    });

    test('resize keeps cells and grows storage', () {
      final line = lineOf('ABCDEF')..resize(300);
      expect(line.length, 300);
      expect(line.data.length, greaterThanOrEqualTo(300 * 4));
      expect(line.getText(), 'ABCDEF');
    });

    test('erase, insert and remove cells as xterm', () {
      final style = CursorStyle()..setBold();
      final line = lineOf('ABCDEF');
      line.eraseRange(1, 3, style);
      expect(line.getText(), 'ADEF');
      expect(line.getAttributes(1), CellAttr.bold);
      line.insertCells(0, 2);
      expect(line.getText(), 'ADEF');
      expect(line.getCodePoint(2), 'A'.codeUnitAt(0));
      line.removeCells(0, 2);
      expect(line.getCodePoint(0), 'A'.codeUnitAt(0));
      line.resetCell(0);
      expect(line.getContent(0), 0);
    });

    test('copyFrom and cell data', () {
      final source = lineOf('XYZ');
      final line = BufferLine(5)..copyFrom(source, 1, 0, 2);
      expect(line.getText(), 'YZ');
      final cell = CellData(
        foreground: CellColor.named | 2,
        background: 0,
        flags: CellAttr.italic,
        content: 'Q'.codeUnitAt(0) | (1 << CellContent.widthShift),
      );
      line.setCellData(4, cell);
      final read = CellData.empty();
      line.getCellData(4, read);
      expect(read.getHash(), cell.getHash());
      expect(line.createCellData(4).content, 0);
      expect(line.getContent(4), 0);
    });

    test('plain anchors move with inserted and removed cells', () {
      final line = lineOf('ABCDEF');
      final anchor = line.createAnchor(4);
      final removed = line.createAnchor(1);
      line.insertCells(0, 2);
      expect(anchor.x, 6);
      line.removeCells(0, 2);
      expect(anchor.x, 4);
      expect(removed.line, isNull, reason: 'inside the removed cells');
      final other = BufferLine(10);
      anchor.reparent(other, 2);
      expect(anchor.line, other);
      expect(other.anchors, [anchor]);
      expect(line.anchors, isNot(contains(anchor)));
      other.dispose();
      expect(anchor.line, isNull);
    });
  });

  group('CellFlags', () {
    test('match the CellAttr bits', () {
      expect(CellFlags.bold, CellAttr.bold);
      expect(CellFlags.invisible, CellAttr.invisible);
    });
  });
}
