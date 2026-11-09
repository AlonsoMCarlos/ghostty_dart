// In-process sys tests. Only settings that are safe on any thread run here
// (clearing options, the native stderr logger): Dart handlers are tested
// in a separate process by sys_callbacks_test.dart.

import 'dart:typed_data';

import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart/src/ffi/bindings.g.dart';
import 'package:ghostty_dart/src/sys/sys_types.dart';
import 'package:test/test.dart';

void main() {
  test('VtLogLevel matches GhosttySysLogLevel', () {
    const expected = {
      VtLogLevel.error: GhosttySysLogLevel.GHOSTTY_SYS_LOG_LEVEL_ERROR,
      VtLogLevel.warning: GhosttySysLogLevel.GHOSTTY_SYS_LOG_LEVEL_WARNING,
      VtLogLevel.info: GhosttySysLogLevel.GHOSTTY_SYS_LOG_LEVEL_INFO,
      VtLogLevel.debug: GhosttySysLogLevel.GHOSTTY_SYS_LOG_LEVEL_DEBUG,
    };
    expect(
      expected.keys.toSet(),
      VtLogLevel.values.toSet()..remove(VtLogLevel.unknown),
    );
    expected.forEach((level, raw) {
      expect(vtLogLevelCodec.encode(level), raw);
      expect(vtLogLevelCodec.decode(raw), level);
    });
    expect(vtLogLevelCodec.decode(GHOSTTY_ENUM_MAX_VALUE), VtLogLevel.unknown);
    expect(
      () => vtLogLevelCodec.encode(VtLogLevel.unknown),
      throwsArgumentError,
    );
  });

  group('RgbaImage', () {
    test('holds width * height * 4 bytes', () {
      final pixels = Uint8List(2 * 3 * 4);
      final image = RgbaImage(width: 2, height: 3, pixels: pixels);
      expect(image.width, 2);
      expect(image.height, 3);
      expect(image.pixels, same(pixels));
      expect(image.toString(), 'RgbaImage(2x3)');
    });

    test('rejects a pixel buffer of the wrong size', () {
      expect(
        () => RgbaImage(width: 2, height: 2, pixels: Uint8List(15)),
        throwsArgumentError,
      );
      expect(
        () => RgbaImage(width: 1, height: 1, pixels: Uint8List(3)),
        throwsArgumentError,
      );
    });

    test('rejects empty and oversized dimensions', () {
      expect(
        () => RgbaImage(width: 0, height: 1, pixels: Uint8List(0)),
        throwsRangeError,
      );
      expect(
        () => RgbaImage(width: 1, height: -1, pixels: Uint8List(0)),
        throwsRangeError,
      );
      expect(
        () => RgbaImage(width: 0x100000000, height: 1, pixels: Uint8List(0)),
        throwsRangeError,
      );
    });
  });

  group('options', () {
    // Each test restores the library default (everything cleared), which is
    // also what the other suites running in this process expect.
    test('clearing every option is accepted', () {
      setVtLogHandler(null);
      setVtPngDecoder(null);
      setVtSecureRandomSource(null);
    });

    test('the stderr logger can be installed and removed', () {
      addTearDown(() => setVtLogHandler(null));
      useVtStderrLogging();
      final terminal = VtTerminal(cols: 10, rows: 2);
      addTearDown(terminal.dispose);
      terminal.write(Uint8List.fromList('ok'.codeUnits));
      expect(terminal.cursorX, 2);
    });
  });
}
