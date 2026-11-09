// Adversarial tests from the correctness review of the colour utilities.

import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:test/test.dart';

const _black = RgbColor(0, 0, 0);
const _white = RgbColor(255, 255, 255);

void main() {
  group('parsing (review)', () {
    test('empty, non-ASCII and partial input is not a colour', () {
      expect(tryParseColor('rgb:'), isNull);
      expect(tryParseColor('rød'), isNull);
      expect(tryParseColor('👍'), isNull);
      expect(tryParseX11Color(''), isNull);
      expect(tryParseX11Color('   '), isNull);
    });

    test('palette entry index bounds', () {
      expect(tryParsePaletteEntry('0xff=#000'), (index: 255, color: _black));
      expect(tryParsePaletteEntry('0x100=#000'), isNull);
      expect(tryParsePaletteEntry(''), isNull);
    });

    test('long input does not overflow', () {
      expect(tryParseColor('#${'a' * 100000}'), isNull);
      expect(tryParseX11Color('x' * 100000), isNull);
    });
  });

  group('palettes (review)', () {
    test('preserving every index returns base unchanged', () {
      final base = [for (var i = 0; i < 256; i++) RgbColor(i, 255 - i, i ~/ 2)];
      final palette = generateColorPalette(
        background: _black,
        foreground: _white,
        base: base,
        preserve: [for (var i = 0; i < 256; i++) i, 0, 255],
      );
      expect(palette, base);
    });

    test('preserve sets the right mask bit at word edges', () {
      final base = List.filled(256, const RgbColor(1, 2, 3));
      final generated = generateColorPalette(
        background: _black,
        foreground: _white,
        base: base,
      );
      for (final index in [16, 63, 64, 127, 128, 191, 192, 255]) {
        final palette = generateColorPalette(
          background: _black,
          foreground: _white,
          base: base,
          preserve: [index],
        );
        for (var i = 16; i < 256; i++) {
          expect(
            palette[i],
            i == index ? base[i] : generated[i],
            reason: 'preserve [$index], entry $i',
          );
        }
      }
    });
  });
}
