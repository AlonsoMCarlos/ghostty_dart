import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:test/test.dart';

const _black = RgbColor(0, 0, 0);
const _white = RgbColor(255, 255, 255);

void main() {
  group('defaultColorPalette', () {
    test('has 256 entries with the xterm cube and ramp', () {
      final palette = defaultColorPalette;
      expect(palette, hasLength(256));
      expect(palette[16], _black); // cube origin
      expect(palette[231], _white); // cube end
      expect(palette[196], const RgbColor(255, 0, 0));
      expect(palette[232], const RgbColor(8, 8, 8)); // ramp start
      expect(palette[255], const RgbColor(238, 238, 238)); // ramp end
    });

    test('is unmodifiable and cached', () {
      expect(identical(defaultColorPalette, defaultColorPalette), isTrue);
      expect(() => defaultColorPalette[0] = _black, throwsUnsupportedError);
    });
  });

  group('generateColorPalette', () {
    test('keeps 0-15 and generates the rest', () {
      final base = List<RgbColor>.generate(256, RgbColor.fromValue);
      final palette = generateColorPalette(
        background: _black,
        foreground: _white,
        base: base,
      );
      expect(palette, hasLength(256));
      expect(palette.sublist(0, 16), base.sublist(0, 16));
      expect(palette[16], isNot(base[16]));
      expect(palette[255], isNot(base[255]));
      expect(() => palette[0] = _black, throwsUnsupportedError);
    });

    test('preserve keeps the chosen indices from base', () {
      final base = List<RgbColor>.filled(256, const RgbColor(1, 2, 3));
      final palette = generateColorPalette(
        background: _black,
        foreground: _white,
        base: base,
        preserve: const [16, 63, 64, 127, 128, 255],
      );
      for (final index in [16, 63, 64, 127, 128, 255]) {
        expect(palette[index], const RgbColor(1, 2, 3), reason: '$index');
      }
      expect(palette[17], isNot(const RgbColor(1, 2, 3)));
      expect(palette[254], isNot(const RgbColor(1, 2, 3)));
    });

    test('without base starts from the default palette', () {
      final palette = generateColorPalette(
        background: _black,
        foreground: _white,
      );
      expect(palette.sublist(0, 16), defaultColorPalette.sublist(0, 16));
    });

    test('the grayscale ramp runs from background to foreground', () {
      const bg = RgbColor(0x10, 0x10, 0x10);
      const fg = RgbColor(0xf0, 0xf0, 0xf0);
      final palette = generateColorPalette(background: bg, foreground: fg);
      expect(
        palette[232].perceivedLuminance,
        lessThan(palette[255].perceivedLuminance),
      );
    });

    test('harmonious changes light themes', () {
      const bg = RgbColor(0xfd, 0xf6, 0xe3);
      const fg = RgbColor(0x65, 0x7b, 0x83);
      final plain = generateColorPalette(background: bg, foreground: fg);
      final harmonious = generateColorPalette(
        background: bg,
        foreground: fg,
        harmonious: true,
      );
      expect(plain.sublist(16), isNot(harmonious.sublist(16)));
    });

    test('validates arguments', () {
      expect(
        () => generateColorPalette(
          background: _black,
          foreground: _white,
          base: const [_black],
        ),
        throwsArgumentError,
      );
      for (final bad in [-1, 256]) {
        expect(
          () => generateColorPalette(
            background: _black,
            foreground: _white,
            preserve: [bad],
          ),
          throwsRangeError,
        );
      }
    });
  });

  group('RgbColorMetrics', () {
    test('luminance spans black to white', () {
      expect(_black.luminance, 0);
      expect(_white.luminance, closeTo(1, 1e-9));
      expect(const RgbColor(255, 0, 0).luminance, closeTo(0.2126, 1e-4));
    });

    test('perceived luminance and isLight', () {
      expect(_black.perceivedLuminance, 0);
      expect(_white.perceivedLuminance, closeTo(1, 1e-9));
      expect(_white.isLight, isTrue);
      expect(_black.isLight, isFalse);
      expect(const RgbColor(0xfd, 0xf6, 0xe3).isLight, isTrue);
      expect(const RgbColor(0x00, 0x2b, 0x36).isLight, isFalse);
    });

    test('contrast is symmetric, 1 to 21', () {
      expect(_black.contrastWith(_white), closeTo(21, 1e-9));
      expect(_white.contrastWith(_black), closeTo(21, 1e-9));
      expect(_white.contrastWith(_white), closeTo(1, 1e-9));
      const a = RgbColor(0x12, 0x34, 0x56);
      const b = RgbColor(0xab, 0xcd, 0xef);
      expect(a.contrastWith(b), closeTo(b.contrastWith(a), 1e-12));
    });
  });
}
