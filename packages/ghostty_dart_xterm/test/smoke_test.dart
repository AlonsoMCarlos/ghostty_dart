import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart_flutter/ghostty_dart_flutter.dart';
import 'package:ghostty_dart_xterm/src/internal/terminal_internals.dart';
import 'package:ghostty_dart_xterm/xterm.dart';

class _Internals implements TerminalInternals {
  _Internals(this.vtController);

  @override
  final VtTerminalController vtController;

  @override
  double? viewDevicePixelRatio;
}

void main() {
  test('xterm value types behave as in xterm 4.0.0', () {
    const a = CellOffset(3, 1);
    const b = CellOffset(0, 2);
    expect(a.isBefore(b), isTrue);
    expect(b.isAfterOrSame(a), isTrue);
    expect(a, const CellOffset(3, 1));

    final style = CursorStyle()
      ..setBold()
      ..setForegroundColorRgb(1, 2, 3);
    expect(style.isBold, isTrue);
    expect(style.foreground, CellColor.rgb | 0x010203);

    expect(
      CellData(foreground: 1, background: 2, flags: 3, content: 4).getHash(),
      // xterm 4.0.0's hashValues(1, 2, 3, 4).
      _xtermHash([1, 2, 3, 4]),
    );
    expect(MouseMode.upDownScroll.reportScroll, isTrue);
    expect(TerminalTargetPlatform.values.last, TerminalTargetPlatform.web);
  });

  test('the engine loads and internals bind to a terminal object', () {
    // Proves the ghostty_dart build hook runs for this package's tests.
    final controller = VtTerminalController(cols: 10, rows: 2);
    addTearDown(controller.dispose);
    final terminal = Object();
    bindTerminalInternals(terminal, _Internals(controller));
    controller.write('hi');
    expect(terminalInternals(terminal).vtController.terminal.cursorX, 2);
    expect(() => terminalInternals(Object()), throwsStateError);
  });
}

// xterm 4.0.0's `hashValues` (lib/src/utils/hash_values.dart), written
// independently of the port to check it.
int _xtermHash(List<int> values) {
  var hash = 0;
  for (final value in values) {
    hash = 0x1fffffff & (hash + value.hashCode);
    hash = 0x1fffffff & (hash + ((0x0007ffff & hash) << 10));
    hash = hash ^ (hash >> 6);
  }
  hash = 0x1fffffff & (hash + ((0x03ffffff & hash) << 3));
  hash = hash ^ (hash >> 11);
  return 0x1fffffff & (hash + ((0x00003fff & hash) << 15));
}
