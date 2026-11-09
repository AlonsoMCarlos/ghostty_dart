import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:test/test.dart';

import '../support/expect_support.dart';
import '../support/terminal_support.dart';

/// The encoded bytes as a readable string (`ESC` for 0x1b).

/// 80×24 cells of 10×20 pixels.
const _size = MouseEncoderSize(
  screenWidth: 800,
  screenHeight: 480,
  cellWidth: 10,
  cellHeight: 20,
);

/// A left press in cell (1, 1), zero-based.
const _press = VtMouseEvent(
  action: MouseAction.press,
  button: MouseButton.left,
  x: 15,
  y: 25,
);

void main() {
  late MouseEncoder encoder;

  setUp(() => encoder = MouseEncoder()..configure(size: _size));
  tearDown(() => encoder.dispose());

  /// Enables [modes] (e.g. `'1000;1006'`) on a terminal and syncs.
  void syncWithModes(String modes) => withTerminal(80, 24, (terminal) {
    writeText(terminal, '\x1b[?${modes}h');
    encoder.setFromTerminal(terminal);
  });

  test('nothing is reported while tracking is off (the default)', () {
    expect(encoder.encode(_press), isEmpty);
    withTerminal(80, 24, encoder.setFromTerminal);
    expect(encoder.encode(_press), isEmpty);
  });

  group('SGR format', () {
    setUp(() => syncWithModes('1000;1006'));

    test('press and release', () {
      expect(showEscapes(encoder.encode(_press)), 'ESC[<0;2;2M');
      expect(
        showEscapes(
          encoder.encode(_press.copyWith(action: MouseAction.release)),
        ),
        'ESC[<0;2;2m',
      );
    });

    test('buttons, wheel and modifiers', () {
      expect(
        showEscapes(encoder.encode(_press.copyWith(button: MouseButton.right))),
        'ESC[<2;2;2M',
      );
      expect(
        showEscapes(
          encoder.encode(_press.copyWith(button: MouseButton.middle)),
        ),
        'ESC[<1;2;2M',
      );
      expect(
        showEscapes(encoder.encode(_press.copyWith(button: MouseButton.four))),
        'ESC[<64;2;2M',
      );
      expect(
        showEscapes(
          encoder.encode(
            _press.copyWith(modifiers: KeyModifiers.shift | KeyModifiers.ctrl),
          ),
        ),
        'ESC[<20;2;2M',
      );
    });

    test('positions map to cells using the size', () {
      expect(
        showEscapes(encoder.encode(_press.copyWith(x: 0, y: 0))),
        'ESC[<0;1;1M',
      );
      expect(
        showEscapes(encoder.encode(_press.copyWith(x: 799, y: 479))),
        'ESC[<0;80;24M',
      );
    });

    test('normal tracking does not report plain motion', () {
      final motion = _press.copyWith(
        action: MouseAction.motion,
        clearButton: true,
      );
      expect(encoder.encode(motion), isEmpty);
    });
  });

  test('any-event tracking reports motion without a button', () {
    syncWithModes('1003;1006');
    final motion = _press.copyWith(
      action: MouseAction.motion,
      clearButton: true,
    );
    expect(showEscapes(encoder.encode(motion)), 'ESC[<35;2;2M');
  });

  test('button-event tracking reports drags', () {
    syncWithModes('1002;1006');
    encoder.configure(anyButtonPressed: true);
    final drag = _press.copyWith(action: MouseAction.motion, x: 25);
    expect(showEscapes(encoder.encode(drag)), 'ESC[<32;3;2M');
  });

  test('X10 format is the default format', () {
    syncWithModes('1000');
    expect(encoder.encode(_press), [0x1b, 0x5b, 0x4d, 32 + 0, 32 + 2, 32 + 2]);
  });

  test('configure sets mode and format without a terminal', () {
    encoder.configure(
      trackingMode: MouseTrackingMode.normal,
      format: MouseFormat.sgr,
    );
    expect(showEscapes(encoder.encode(_press)), 'ESC[<0;2;2M');
    encoder.configure(format: MouseFormat.sgrPixels);
    expect(showEscapes(encoder.encode(_press)), 'ESC[<0;15;25M');
    encoder.configure(format: MouseFormat.urxvt);
    expect(showEscapes(encoder.encode(_press)), 'ESC[32;2;2M');
  });

  test('resetOptions restores the defaults', () {
    syncWithModes('1000;1006');
    encoder.resetOptions();
    expect(encoder.encode(_press), isEmpty);
  });

  test('padding shifts the grid', () {
    syncWithModes('1000;1006');
    encoder.configure(
      size: const MouseEncoderSize(
        screenWidth: 820,
        screenHeight: 500,
        cellWidth: 10,
        cellHeight: 20,
        paddingLeft: 10,
        paddingTop: 10,
        paddingRight: 10,
        paddingBottom: 10,
      ),
    );
    expect(showEscapes(encoder.encode(_press)), 'ESC[<0;1;1M');
  });

  group('errors', () {
    test('unknown enum values and bad sizes are rejected', () {
      expect(
        () => encoder.encode(_press.copyWith(action: MouseAction.unknown)),
        throwsArgumentError,
      );
      expect(
        () => encoder.encode(_press.copyWith(button: MouseButton.unknown)),
        throwsArgumentError,
      );
      expect(
        () => encoder.configure(trackingMode: MouseTrackingMode.unknown),
        throwsArgumentError,
      );
      expect(
        () => encoder.configure(format: MouseFormat.unknown),
        throwsArgumentError,
      );
      expect(
        () => encoder.configure(
          size: const MouseEncoderSize(
            screenWidth: 10,
            screenHeight: 10,
            cellWidth: 0,
            cellHeight: 1,
          ),
        ),
        throwsRangeError,
      );
      expect(
        () => encoder.configure(
          size: const MouseEncoderSize(
            screenWidth: 0x100000000,
            screenHeight: 10,
            cellWidth: 1,
            cellHeight: 1,
          ),
        ),
        throwsRangeError,
      );
    });

    test('a failed configure leaves the options unchanged', () {
      syncWithModes('1000;1006');
      expect(
        () => encoder.configure(
          format: MouseFormat.x10,
          size: const MouseEncoderSize(
            screenWidth: 1,
            screenHeight: 1,
            cellWidth: 0,
            cellHeight: 0,
          ),
        ),
        throwsRangeError,
      );
      expect(showEscapes(encoder.encode(_press)), 'ESC[<0;2;2M');
    });

    test('the encoder still works after a rejected event', () {
      syncWithModes('1000;1006');
      expect(
        () => encoder.encode(_press.copyWith(button: MouseButton.unknown)),
        throwsArgumentError,
      );
      expect(showEscapes(encoder.encode(_press)), 'ESC[<0;2;2M');
    });
  });

  group('dispose', () {
    test('is idempotent and blocks further use', () {
      final local = MouseEncoder();
      local.encode(_press);
      local.dispose();
      local.dispose();
      expect(local.isDisposed, isTrue);
      expect(
        () => local.encode(_press),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'MouseEncoder has been disposed',
          ),
        ),
      );
      expect(local.reset, throwsStateError);
      expect(local.resetOptions, throwsStateError);
      expect(() => local.configure(trackLastCell: true), throwsStateError);
      withTerminal(10, 2, (t) {
        expect(() => local.setFromTerminal(t), throwsStateError);
      });
    });

    test('setFromTerminal with a disposed terminal throws', () {
      final terminal = VtTerminal(cols: 10, rows: 2)..dispose();
      expect(() => encoder.setFromTerminal(terminal), throwsStateError);
    });
  });
}
