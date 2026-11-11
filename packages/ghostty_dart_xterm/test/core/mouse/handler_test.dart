import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart_xterm/core.dart';

import '../fake_state.dart';

void main() {
  late FakeState state;

  setUp(() => state = FakeState());

  String? report(
    TerminalMouseButton button,
    TerminalMouseButtonState buttonState, [
    CellOffset position = const CellOffset(9, 9),
    TerminalMouseHandler handler = defaultMouseHandler,
  ]) {
    return handler(
      TerminalMouseEvent(
        button: button,
        buttonState: buttonState,
        position: position,
        state: state,
        platform: TerminalTargetPlatform.linux,
      ),
    );
  }

  const down = TerminalMouseButtonState.down;
  const up = TerminalMouseButtonState.up;

  test('buttons keep xterm 4.0.0 ids and order', () {
    expect(TerminalMouseButton.values.map((b) => b.name), [
      'left',
      'middle',
      'right',
      'wheelUp',
      'wheelDown',
      'wheelLeft',
      'wheelRight',
    ]);
    expect(TerminalMouseButton.values.map((b) => b.id), [
      0, 1, 2, 68, 69, 70, 71, //
    ]);
    expect(TerminalMouseButton.values.where((b) => b.isWheel), hasLength(4));
    expect(TerminalMouseButtonState.values, [up, down]);
  });

  test('defaultMouseHandler is the const click + up/down cascade', () {
    expect(
      identical(
        defaultMouseHandler,
        const CascadeMouseHandler([ClickMouseHandler(), UpDownMouseHandler()]),
      ),
      isTrue,
    );
  });

  test('reports nothing while the program does not track the mouse', () {
    for (final button in TerminalMouseButton.values) {
      expect(report(button, down), isNull);
      expect(report(button, up), isNull);
    }
  });

  group('clickOnly (X10)', () {
    setUp(() => state.mouseMode = MouseMode.clickOnly);

    test('reports presses of the three buttons only', () {
      // Cell (9, 9) is column 10, row 10: 32 + 10 = '*'.
      expect(report(TerminalMouseButton.left, down), '\x1b[M **');
      expect(report(TerminalMouseButton.middle, down), '\x1b[M!**');
      expect(report(TerminalMouseButton.right, down), '\x1b[M"**');
      expect(report(TerminalMouseButton.left, up), isNull);
      expect(report(TerminalMouseButton.wheelUp, down), isNull);
    });
  });

  group('upDownScroll and the modes that extend it', () {
    for (final mode in [
      MouseMode.upDownScroll,
      MouseMode.upDownScrollDrag,
      MouseMode.upDownScrollMove,
    ]) {
      test('$mode reports presses, releases and wheel steps', () {
        state.mouseMode = mode;
        expect(report(TerminalMouseButton.left, down), '\x1b[M **');
        expect(report(TerminalMouseButton.left, up), '\x1b[M#**');
        expect(report(TerminalMouseButton.wheelUp, down), '\x1b[Md**');
        expect(report(TerminalMouseButton.wheelDown, down), '\x1b[Me**');
        expect(report(TerminalMouseButton.wheelUp, up), isNull);
      });
    }
  });

  group('report formats', () {
    setUp(() => state.mouseMode = MouseMode.upDownScroll);

    test('normal encodes the 1-based row without xterm\'s off-by-one', () {
      // xterm 4.0.0 sends '\x1b[M +,' here (row 11).
      expect(
        report(TerminalMouseButton.left, down, const CellOffset(9, 9)),
        '\x1b[M **',
      );
      expect(
        report(TerminalMouseButton.left, down, const CellOffset(0, 0)),
        '\x1b[M !!',
      );
    });

    test('normal sends NUL beyond column or row 223', () {
      expect(
        report(TerminalMouseButton.left, down, const CellOffset(222, 222)),
        '\x1b[M \xff\xff',
      );
      expect(
        report(TerminalMouseButton.left, down, const CellOffset(223, 223)),
        '\x1b[M \x00\x00',
      );
    });

    test('utf encodes large positions as characters up to 2015', () {
      state.mouseReportMode = MouseReportMode.utf;
      expect(
        report(TerminalMouseButton.left, down, const CellOffset(299, 499)),
        '\x1b[M ${String.fromCharCode(332)}${String.fromCharCode(532)}',
      );
      expect(
        report(TerminalMouseButton.left, down, const CellOffset(2015, 0)),
        '\x1b[M \x00!',
      );
    });

    test('sgr uses decimal positions and M/m for press/release', () {
      state.mouseReportMode = MouseReportMode.sgr;
      expect(report(TerminalMouseButton.left, down), '\x1b[<0;10;10M');
      expect(report(TerminalMouseButton.right, up), '\x1b[<2;10;10m');
      expect(
        report(TerminalMouseButton.wheelDown, down, const CellOffset(299, 0)),
        '\x1b[<69;300;1M',
      );
    });

    test('urxvt uses 32 + button and decimal positions', () {
      state.mouseReportMode = MouseReportMode.urxvt;
      expect(report(TerminalMouseButton.left, down), '\x1b[32;10;10M');
      expect(report(TerminalMouseButton.left, up), '\x1b[35;10;10M');
      expect(report(TerminalMouseButton.wheelUp, down), '\x1b[100;10;10M');
    });
  });

  test('a custom handler can run before the default one', () {
    state.mouseMode = MouseMode.upDownScroll;
    final handler = CascadeMouseHandler([_RightOnly(), defaultMouseHandler]);
    expect(
      report(TerminalMouseButton.right, down, const CellOffset(0, 0), handler),
      'right',
    );
    expect(
      report(TerminalMouseButton.left, down, const CellOffset(0, 0), handler),
      '\x1b[M !!',
    );
    expect(
      const CascadeMouseHandler([])(
        TerminalMouseEvent(
          button: TerminalMouseButton.left,
          buttonState: down,
          position: const CellOffset(0, 0),
          state: state,
          platform: TerminalTargetPlatform.linux,
        ),
      ),
      isNull,
    );
  });
}

class _RightOnly extends TerminalMouseHandler {
  @override
  String? call(TerminalMouseEvent event) {
    return event.button == TerminalMouseButton.right ? 'right' : null;
  }
}
