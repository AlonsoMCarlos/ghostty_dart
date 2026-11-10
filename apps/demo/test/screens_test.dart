import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart_demo/src/fake_shell/screens.dart';

/// The visible text of [line]: escape sequences removed.
String _visible(String line) =>
    line.replaceAll(RegExp(r'\x1b\[[0-9;:?]*[A-Za-z]'), '');

void main() {
  group('topFrame', () {
    test('is deterministic per tick and changes between ticks', () {
      final a = topFrame(cols: 80, rows: 24, tick: 3);
      expect(topFrame(cols: 80, rows: 24, tick: 3), a);
      expect(topFrame(cols: 80, rows: 24, tick: 4), isNot(a));
    });

    test('is one synchronized update that homes and clears the rest', () {
      final frame = topFrame(cols: 80, rows: 24, tick: 0);
      expect(frame, startsWith('\x1b[?2026h\x1b[H'));
      expect(frame, endsWith('\x1b[J\x1b[?2026l'));
    });

    for (final (cols, rows) in [
      (80, 24),
      (200, 60),
      (40, 10),
      (12, 3),
      (20, 1),
    ]) {
      test('fits $cols x $rows exactly', () {
        final body = topFrame(cols: cols, rows: rows, tick: 1)
            .replaceFirst('\x1b[?2026h\x1b[H', '')
            .replaceFirst('\x1b[J\x1b[?2026l', '');
        final lines = body.split('\r\n');
        expect(lines, hasLength(rows));
        for (final line in lines) {
          expect(_visible(line).length, lessThanOrEqualTo(cols), reason: line);
        }
        expect(_visible(lines.last), startsWith(' q: quit'.substring(0, 8)));
      });
    }
  });

  test('colorsChart ends every line with reset + CRLF', () {
    final chart = colorsChart();
    for (final line in chart.split('\r\n').where((l) => l.isNotEmpty)) {
      expect(line, endsWith('\x1b[0m'));
    }
    expect(chart, endsWith('\r\n'));
  });
}
