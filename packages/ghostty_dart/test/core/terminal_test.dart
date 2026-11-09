// Tests of the minimal VtTerminal from T01. The terminal module (T02) owns
// test/terminal/ and extends these.

import 'dart:typed_data';

import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart/src/core/internal.dart';
import 'package:ghostty_dart/src/ffi/bindings.g.dart';
import 'package:test/test.dart';

import '../support/terminal_support.dart';

void main() {
  test('creates a terminal of the requested size', () {
    withTerminal(80, 24, (terminal) {
      expect(terminal.cols, 80);
      expect(terminal.rows, 24);
      expect(terminal.isDisposed, isFalse);
    });
  });

  test('accepts the full uint16 size range', () {
    withTerminal(1, 1, (terminal) => expect(terminal.cols, 1));
  });

  test('rejects sizes outside 1-65535', () {
    for (final (cols, rows) in [(0, 24), (80, 0), (-1, 1), (65536, 1)]) {
      expect(
        () => VtTerminal(cols: cols, rows: rows),
        throwsRangeError,
        reason: '$cols x $rows',
      );
    }
  });

  test('write feeds VT data, including sequences split across calls', () {
    withTerminal(20, 5, (terminal) {
      writeText(terminal, 'hello \x1b[1');
      writeText(terminal, 'mworld\x1b[0m\r\nline 2');
      terminal.write(Uint8List(0));
      expect(screenText(terminal), 'hello world\nline 2');
    });
  });

  test('write tolerates malformed input', () {
    withTerminal(20, 5, (terminal) {
      terminal.write(Uint8List.fromList([0x1b, 0x5b, 0xff, 0xfe, 0x41, 0x42]));
      expect(terminal.cols, 20);
    });
  });

  test('write and resize bump the handle epoch', () {
    withTerminal(20, 5, (terminal) {
      final handle = handleOf<GhosttyTerminalImpl>(terminal);
      final start = handle.epoch;
      writeText(terminal, 'x');
      terminal.resize(30, 6);
      expect(handle.epoch, start + 2);
    });
  });

  test('resize changes the size and reflows', () {
    withTerminal(10, 3, (terminal) {
      writeText(terminal, '0123456789abc');
      expect(screenText(terminal), '0123456789\nabc');
      terminal.resize(20, 4);
      expect(terminal.cols, 20);
      expect(terminal.rows, 4);
      expect(screenText(terminal), '0123456789abc');
    });
  });

  test('resize keeps the cell pixel size unless given', () {
    withTerminal(10, 4, (terminal) {
      int widthPx() => terminalDataUint32(
        terminal,
        GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_WIDTH_PX,
      );
      int heightPx() => terminalDataUint32(
        terminal,
        GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_HEIGHT_PX,
      );
      expect(widthPx(), 0);
      terminal.resize(10, 4, cellWidthPx: 8, cellHeightPx: 16);
      expect((widthPx(), heightPx()), (80, 64));
      terminal.resize(20, 5);
      expect((widthPx(), heightPx()), (160, 80));
      terminal.resize(20, 5, cellWidthPx: 9);
      expect((widthPx(), heightPx()), (180, 80));
    });
  });

  test('resize validates its arguments', () {
    withTerminal(10, 4, (terminal) {
      expect(() => terminal.resize(0, 4), throwsRangeError);
      expect(() => terminal.resize(10, 65536), throwsRangeError);
      expect(() => terminal.resize(10, 4, cellWidthPx: -1), throwsRangeError);
      expect(
        () => terminal.resize(10, 4, cellHeightPx: 0x100000000),
        throwsRangeError,
      );
      expect(terminal.cols, 10);
    });
  });

  test('dispose is idempotent and blocks further use', () {
    final terminal = VtTerminal(cols: 10, rows: 4)..dispose();
    expect(terminal.isDisposed, isTrue);
    terminal.dispose();
    expect(() => terminal.cols, throwsStateError);
    expect(() => terminal.rows, throwsStateError);
    expect(() => writeText(terminal, 'x'), throwsStateError);
    expect(() => terminal.write(Uint8List(0)), throwsStateError);
    expect(() => terminal.resize(5, 5), throwsStateError);
  });

  test('write refuses to re-enter the same terminal', () {
    withTerminal(10, 4, (terminal) {
      final handle = handleOf<GhosttyTerminalImpl>(terminal);
      handle.use((_) {
        expect(() => writeText(terminal, 'x'), throwsStateError);
      });
      writeText(terminal, 'ok');
      expect(screenText(terminal), 'ok');
    });
  });

  test('many terminals can be created and dropped', () {
    for (var i = 0; i < 200; i++) {
      VtTerminal(cols: 80, rows: 24).dispose();
    }
    // Undisposed terminals are left to the finalizer.
    for (var i = 0; i < 50; i++) {
      VtTerminal(cols: 80, rows: 24);
    }
  });
}
