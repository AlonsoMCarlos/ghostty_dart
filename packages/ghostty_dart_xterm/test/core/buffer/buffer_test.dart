import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart_xterm/core.dart';

import '../fake_state.dart';

Terminal newTerminal({int maxLines = 1000, Set<int>? wordSeparators}) {
  final terminal = Terminal(maxLines: maxLines, wordSeparators: wordSeparators);
  addTearDown(terminal.dispose);
  return terminal;
}

List<String> rows(Terminal terminal, int from, int to) => [
  for (var i = from; i < to; i++) terminal.buffer.lines[i].toString(),
];

void main() {
  group('lines', () {
    test('are snapshots, reused until the terminal changes', () {
      final terminal = newTerminal();
      terminal.write('one');
      final line = terminal.buffer.lines[0];
      expect(line.attached, isTrue);
      expect(line.index, 0);
      expect(terminal.buffer.lines[0], same(line));

      terminal.write(' two');
      expect(line.attached, isFalse);
      expect(() => line.index, throwsStateError);
      expect(line.toString(), 'one');
      final fresh = terminal.buffer.lines[0];
      expect(fresh, isNot(same(line)));
      expect(fresh.toString(), 'one two');
    });

    test('have the terminal width and cover the scrollback', () {
      final terminal = newTerminal();
      terminal.resize(10, 5);
      terminal.write('a\r\nb\r\nc\r\nd\r\ne\r\nf\r\ng');
      final buffer = terminal.buffer;
      expect(buffer.height, 7);
      expect(buffer.scrollBack, 2);
      expect(buffer.viewHeight, 5);
      expect(buffer.lines.length, 7);
      expect(buffer.lines.maxLength, 1000);
      expect(buffer.lines.isFull, isFalse);
      expect([
        for (final l in buffer.lines.toList()) l.length,
      ], everyElement(10));
      final seen = <String>[];
      buffer.lines.forEach((line) => seen.add(line.toString()));
      expect(seen, ['a', 'b', 'c', 'd', 'e', 'f', 'g']);
      expect((buffer.cursorX, buffer.cursorY), (1, 4));
      expect(buffer.absoluteCursorY, 6);
      expect(buffer.currentLine.toString(), 'g');
      expect(() => buffer.lines[7], throwsRangeError);
      expect(() => buffer.lines[-1], throwsRangeError);
    });

    test('pack wide characters as xterm does', () {
      final terminal = newTerminal();
      terminal.write('a床b');
      final line = terminal.buffer.lines[0];
      expect(line.getCodePoint(0), 'a'.codeUnitAt(0));
      expect(line.getWidth(0), 1);
      expect(line.getCodePoint(1), '床'.runes.single);
      expect(line.getWidth(1), 2);
      expect(line.getContent(2), 0);
      expect(line.getCodePoint(3), 'b'.codeUnitAt(0));
      expect(line.getText(), 'a床b');
      expect(line.getTrimmedLength(), 4);
      expect(line.getText(0, 2), 'a', reason: 'the wide cell does not fit');
    });

    test('isWrapped marks continuation rows', () {
      final terminal = newTerminal();
      terminal.resize(5, 5);
      terminal.write('helloworld!\r\nnext');
      final lines = rows(terminal, 0, 4);
      expect(lines, ['hello', 'world', '!', 'next']);
      expect(
        [for (var i = 0; i < 4; i++) terminal.buffer.lines[i].isWrapped],
        [false, true, true, false],
      );
      expect(terminal.buffer.getText().split('\n').take(2), [
        'helloworld!',
        'next',
      ]);
    });

    test('a wide character that does not fit wraps whole', () {
      final terminal = newTerminal();
      terminal.resize(5, 5);
      terminal.write('abcd床');
      expect(rows(terminal, 0, 2), ['abcd', '床']);
      expect(terminal.buffer.lines[0].getCodePoint(4), 0);
      expect(terminal.buffer.lines[1].isWrapped, isTrue);
    });

    test('carry colours and attributes', () {
      final terminal = newTerminal();
      terminal.write(
        '\x1b[1;3;4;9;31;44mA\x1b[0;38;5;200;48;2;1;2;3mB\x1b[0;2;5;7;8mC'
        '\x1b[0;43m\x1b[K',
      );
      final line = terminal.buffer.lines[0];
      expect(line.getForeground(0), CellColor.named | 1);
      expect(line.getBackground(0), CellColor.named | 4);
      expect(
        line.getAttributes(0),
        CellAttr.bold |
            CellAttr.italic |
            CellAttr.underline |
            CellAttr.strikethrough,
      );
      expect(line.getForeground(1), CellColor.palette | 200);
      expect(line.getBackground(1), CellColor.rgb | 0x010203);
      expect(line.getAttributes(1), 0);
      expect(
        line.getAttributes(2),
        CellAttr.faint | CellAttr.blink | CellAttr.inverse | CellAttr.invisible,
      );
      // A colour-only cell left by EL with a background colour.
      expect(line.getCodePoint(5), 0);
      expect(line.getBackground(5), CellColor.named | 3);
      final cell = CellData.empty();
      line.getCellData(0, cell);
      expect(cell.content, 'A'.codeUnitAt(0) | (1 << CellContent.widthShift));
    });

    test('setters change the snapshot only', () {
      final terminal = newTerminal();
      terminal.write('abc');
      final line = terminal.buffer.lines[0];
      line.setCodePoint(0, 'z'.codeUnitAt(0));
      expect(line.toString(), 'zbc');
      terminal.write('');
      expect(terminal.buffer.lines[0].toString(), 'abc');
    });
  });

  group('getText', () {
    test('handles ranges as xterm', () {
      final terminal = newTerminal();
      terminal.write('Hello World\r\nNice to meet you\r\n');
      final buffer = terminal.buffer;
      expect(buffer.getText(), startsWith('Hello World\nNice to meet you\n'));
      expect(
        buffer.getText(
          BufferRangeLine(const CellOffset(6, 0), const CellOffset(4, 1)),
        ),
        'World\nNice',
      );
      expect(
        buffer.getText(
          BufferRangeLine(const CellOffset(4, 1), const CellOffset(6, 0)),
        ),
        'World\nNice',
      );
      expect(
        buffer.getText(
          BufferRangeBlock(const CellOffset(2, 0), const CellOffset(5, 1)),
        ),
        startsWith('llo\nce '),
      );
      expect(
        buffer.getText(
          BufferRangeLine(
            const CellOffset(-100, -100),
            const CellOffset(100, 100),
          ),
        ),
        startsWith('Hello World'),
      );
    });

    test('skips empty cells inside a line, as xterm', () {
      final terminal = newTerminal();
      terminal.write('a\x1b[5Gb c');
      expect(terminal.buffer.lines[0].getText(), 'ab c');
    });
  });

  group('word boundary', () {
    test('uses the default separators', () {
      final terminal = newTerminal();
      terminal.write('foo bar.baz');
      expect(
        terminal.buffer.getWordBoundary(const CellOffset(5, 0)),
        BufferRangeLine(const CellOffset(4, 0), const CellOffset(7, 0)),
      );
      // On a separator, xterm's algorithm returns the word before it.
      expect(
        terminal.buffer.getWordBoundary(const CellOffset(3, 0)),
        BufferRangeLine(const CellOffset(0, 0), const CellOffset(3, 0)),
      );
      expect(terminal.buffer.getWordBoundary(const CellOffset(4, 1)), isNull);
      expect(terminal.buffer.getWordBoundary(const CellOffset(0, 99)), isNull);
    });

    test('uses the terminal word separators in both buffers', () {
      final terminal = newTerminal(wordSeparators: {'o'.codeUnitAt(0)});
      terminal.write('Hello World');
      expect(terminal.altBuffer.wordSeparators, {'o'.codeUnitAt(0)});
      expect(
        terminal.mainBuffer.getWordBoundary(const CellOffset(5, 0)),
        BufferRangeLine(const CellOffset(5, 0), const CellOffset(7, 0)),
      );
    });
  });

  group('mutators', () {
    test('clear and setCursor, as in the xterm SSH example', () {
      final terminal = newTerminal();
      terminal.resize(10, 3);
      terminal.write('1\r\n2\r\n3\r\n4\r\n5');
      expect(terminal.buffer.height, 5);
      terminal.buffer.clear();
      expect(terminal.buffer.height, 3);
      expect(terminal.buffer.getText().trim(), isEmpty);
      expect(terminal.buffer.cursorX, 1, reason: 'clear keeps the cursor');
      terminal.buffer.setCursor(0, 0);
      expect((terminal.buffer.cursorX, terminal.buffer.cursorY), (0, 0));
    });

    test('deleteLines respects the scroll region', () {
      final terminal = newTerminal();
      terminal.resize(10, 10);
      for (var i = 1; i <= 10; i++) {
        terminal.write('line$i${i < 10 ? '\r\n' : ''}');
      }
      terminal.buffer.setVerticalMargins(3, 7);
      terminal.buffer.setCursor(0, 5);
      terminal.buffer.deleteLines(20);
      expect(rows(terminal, 2, 10), [
        'line3',
        'line4',
        'line5',
        '',
        '',
        '',
        'line9',
        'line10',
      ]);
      terminal.buffer.resetVerticalMargins();
    });

    test('erase, insert and scroll', () {
      final terminal = newTerminal();
      terminal.resize(3, 3);
      terminal.write('123\r\n456\r\n789');
      final buffer = terminal.buffer;
      buffer.setCursor(1, 1);
      buffer.eraseDisplayFromCursor();
      expect(rows(terminal, 0, 3), ['123', '4', '']);
      buffer.eraseDisplayToCursor();
      expect(rows(terminal, 0, 3), ['', '', '']);

      terminal.write('\x1b[H123\r\n456\r\n789');
      List<String> screen() =>
          rows(terminal, buffer.scrollBack, buffer.scrollBack + 3);
      buffer
        ..setCursor(0, 0)
        ..scrollUp(1);
      expect(screen(), ['456', '789', '']);
      // libghostty-vt keeps the line scrolled off a full-screen region in
      // the scrollback (xterm drops it).
      expect(buffer.scrollBack, 1);
      expect(buffer.lines[0].toString(), '123');
      buffer.scrollDown(1);
      expect(screen(), ['', '456', '789']);
      buffer
        ..setCursor(1, 1)
        ..eraseLineToCursor();
      expect(screen()[1], '6');
      buffer.eraseLine();
      expect(screen()[1], '');
    });

    test('write prints text without interpreting it', () {
      final terminal = newTerminal();
      terminal.buffer.write('a\x1b[2Jb');
      terminal.buffer.writeChar('c'.codeUnitAt(0));
      expect(terminal.buffer.lines[0].toString(), 'a[2Jbc');
    });

    test('throw on the inactive buffer', () {
      final terminal = newTerminal();
      terminal.write('\x1b[?1049h');
      expect(() => terminal.mainBuffer.setCursor(0, 0), throwsStateError);
      expect(() => terminal.mainBuffer.clear(), throwsStateError);
      terminal.altBuffer.setCursor(2, 2);
      expect(terminal.altBuffer.cursorX, 2);
    });
  });

  group('screens', () {
    test('the inactive buffer reads as blank lines', () {
      final terminal = newTerminal();
      terminal.write('main text\x1b[?1049halt text');
      expect(terminal.buffer, same(terminal.altBuffer));
      expect(terminal.altBuffer.lines[0].toString(), 'alt text');
      expect(terminal.mainBuffer.height, terminal.viewHeight);
      expect(terminal.mainBuffer.lines[0].toString(), isEmpty);
      expect(
        (terminal.mainBuffer.cursorX, terminal.mainBuffer.cursorY),
        (0, 0),
      );
      terminal.write('\x1b[?1049l');
      expect(terminal.mainBuffer.lines[0].toString(), 'main text');
      expect(terminal.altBuffer.lines[0].toString(), isEmpty);
    });

    test('a buffer for another TerminalState holds blank lines', () {
      final state = FakeState()
        ..viewWidth = 10
        ..viewHeight = 3;
      final buffer = Buffer(state, maxLines: 100, isAltBuffer: false);
      expect(buffer.height, 3);
      expect(buffer.lines[2].length, 10);
      expect(buffer.getText(), '\n\n');
      expect(buffer.marginBottom, 2);
      expect(() => buffer.setCursor(0, 0), throwsStateError);
      final anchor = buffer.createAnchor(1, 1);
      expect(anchor.attached, isTrue);
      expect(anchor.offset, const CellOffset(1, 1));
    });
  });

  group('anchors', () {
    test('follow their cell as output scrolls', () {
      final terminal = newTerminal();
      terminal.resize(20, 5);
      terminal.write('first');
      final anchor = terminal.buffer.createAnchor(2, 0);
      expect(anchor.attached, isTrue);
      terminal.write('\r\n' * 10);
      expect(anchor.offset, const CellOffset(2, 0));
      expect(anchor.line!.toString(), 'first');
      terminal.write('\x1b[2J\x1b[H\x1b[3J');
      expect(anchor.attached, isFalse, reason: 'pruned with the scrollback');
      expect(anchor.line, isNull);
      expect(anchor.toString(), 'CellAnchor(2, detached)');
      anchor.dispose();
    });

    test('follow reflow', () {
      final terminal = newTerminal();
      terminal.write('0123456789abcdefghij');
      final anchor = terminal.buffer.createAnchorFromOffset(
        const CellOffset(15, 0),
      );
      terminal.resize(10, 10);
      expect(anchor.offset, const CellOffset(5, 1));
      anchor.dispose();
    });

    test('createAnchorFromCursor and dispose', () {
      final terminal = newTerminal();
      terminal.write('ab\r\ncd');
      final anchor = terminal.buffer.createAnchorFromCursor();
      expect(anchor.offset, const CellOffset(2, 1));
      final line = anchor.line!;
      expect(line.toString(), 'cd');
      anchor.dispose();
      expect(anchor.attached, isFalse);
    });

    test('clear detaches them, as in xterm', () {
      final terminal = newTerminal();
      final line = terminal.buffer.lines[3];
      final anchor = line.createAnchor(5);
      expect(line.anchors, [anchor]);
      expect(anchor.offset, const CellOffset(5, 3));
      terminal.buffer.clear();
      expect(line.attached, isFalse);
      expect(anchor.attached, isFalse);
    });

    test('an anchor on a standalone line is xterm plain anchor', () {
      final line = BufferLine(10);
      final anchor = line.createAnchor(3);
      expect(anchor.attached, isFalse);
      expect(anchor.x, 3);
      anchor.reposition(4);
      expect(anchor.x, 4);
      line.dispose();
      expect(line.anchors, isEmpty);
    });
  });
}
