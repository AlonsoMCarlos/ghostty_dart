// Adversarial tests from the correctness review of the sys module (T09).
// Dart handlers are process-wide isolate-local callables, so only pure Dart
// checks run here (see sys_probe.dart for the handler tests).

import 'dart:typed_data';

import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:test/test.dart';

final _badLength = throwsA(
  isA<ArgumentError>().having((e) => e.name, 'name', 'pixels.length'),
);

void main() {
  group('RgbaImage', () {
    test('dimensions whose product overflows 64 bits are rejected', () {
      // 2^31 * 2^31 * 4 = 2^64, which wraps to 0 in a 64-bit multiply.
      expect(
        () => RgbaImage(
          width: 0x80000000,
          height: 0x80000000,
          pixels: Uint8List(0),
        ),
        _badLength,
      );
      expect(
        () => RgbaImage(
          width: 0xFFFFFFFF,
          height: 0xFFFFFFFF,
          pixels: Uint8List(4),
        ),
        _badLength,
      );
    });

    test('a buffer of whole rows but the wrong row count is rejected', () {
      expect(
        () => RgbaImage(width: 2, height: 3, pixels: Uint8List(2 * 4 * 2)),
        throwsArgumentError,
      );
      expect(
        () => RgbaImage(width: 2, height: 1, pixels: Uint8List(2 * 4 * 2)),
        throwsArgumentError,
      );
    });
  });
}
