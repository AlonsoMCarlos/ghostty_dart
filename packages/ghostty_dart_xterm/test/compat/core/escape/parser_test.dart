// Replaces xterm 4.0.0's test/src/core/escape/parser_test.dart, which drives
// EscapeParser with a mockito EscapeHandler. EscapeParser and EscapeHandler
// are not provided (ADR 0004/0013: libghostty-vt parses), so the same
// sequence is checked through Terminal: xterm's handler answers it with
// Terminal.resize, which calls onResize.
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart_xterm/core.dart';

void main() {
  group('escape parsing through Terminal', () {
    test('can parse window manipulation', () {
      final calls = <List<int>>[];
      final terminal = Terminal(
        onResize: (width, height, pixelWidth, pixelHeight) {
          calls.add([width, height, pixelWidth, pixelHeight]);
        },
      );

      terminal.write('\x1b[8;24;80t');

      expect(calls, [
        [80, 24, 0, 0],
      ]);
      expect(terminal.viewWidth, 80);
      expect(terminal.viewHeight, 24);
    });

    test('keeps a sequence split across writes intact', () {
      final calls = <List<int>>[];
      final terminal = Terminal(
        onResize: (width, height, pixelWidth, pixelHeight) {
          calls.add([width, height, pixelWidth, pixelHeight]);
        },
      );

      terminal.write('\x1b[8;30');
      terminal.write(';100t');

      expect(calls, [
        [100, 30, 0, 0],
      ]);
      expect(terminal.viewWidth, 100);
      expect(terminal.viewHeight, 30);
    });
  });
}
