// Replaces xterm 4.0.0's test/src/core/tabs_test.dart, which tests the
// internal TabStops class (not provided: libghostty-vt keeps the tab stops).
// The same expectations, checked through Terminal's public behaviour.
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart_xterm/core.dart';

void main() {
  group('tab stops', () {
    test('are set every 8 columns by default', () {
      final terminal = Terminal();

      terminal.write('\t');
      expect(terminal.buffer.cursorX, 8);

      terminal.write('\t');
      expect(terminal.buffer.cursorX, 16);

      terminal.write('\r1234567\t');
      expect(terminal.buffer.cursorX, 8);
    });

    test('a tab moves past the stop under the cursor (end excluded)', () {
      final terminal = Terminal();

      terminal.write('12345678\t');
      expect(terminal.buffer.cursorX, 16);

      terminal.write('\r1\t');
      expect(terminal.buffer.cursorX, 8);
    });

    test('can be set and cleared through Terminal', () {
      final terminal = Terminal();

      terminal.write('123');
      terminal.setTapStop();
      terminal.write('\r\t');
      expect(terminal.buffer.cursorX, 3);

      terminal.clearTabStopUnderCursor();
      terminal.write('\r\t');
      expect(terminal.buffer.cursorX, 8);
    });
  });
}
