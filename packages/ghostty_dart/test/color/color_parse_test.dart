import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart/src/core/internal.dart';
import 'package:ghostty_dart/src/ffi/bindings.g.dart';
import 'package:test/test.dart';

void main() {
  group('parseColor', () {
    test('accepts every syntax Ghostty accepts', () {
      expect(parseColor('#abc'), const RgbColor(0xaa, 0xbb, 0xcc));
      expect(parseColor('abc'), const RgbColor(0xaa, 0xbb, 0xcc));
      expect(parseColor('#12ab34'), const RgbColor(0x12, 0xab, 0x34));
      expect(parseColor('12AB34'), const RgbColor(0x12, 0xab, 0x34));
      expect(parseColor('rgb:ff/00/80'), const RgbColor(0xff, 0, 0x80));
      expect(parseColor('rgbi:1/0/0'), const RgbColor(0xff, 0, 0));
      expect(parseColor('red'), const RgbColor(0xff, 0, 0));
      expect(
        parseColor(' \tDarkSlateGray \t'),
        parseX11Color('dark slate gray'),
      );
      expect(parseColor('#fffffffff'), const RgbColor(0xff, 0xff, 0xff));
      expect(parseColor('#ffffffffffff'), const RgbColor(0xff, 0xff, 0xff));
    });

    test('rejects what is not a colour', () {
      for (final bad in ['', '#', '#ab', '#ggg', 'notacolor', 'rgb:1/2', 'é']) {
        expect(tryParseColor(bad), isNull, reason: bad);
        expect(() => parseColor(bad), throwsFormatException, reason: bad);
      }
    });

    test('does not stop at an embedded NUL', () {
      expect(tryParseColor('red\u0000'), isNull);
    });
  });

  group('parseX11Color', () {
    test('is case-insensitive and trims', () {
      expect(parseX11Color('MediumSpringGreen'), const RgbColor(0, 250, 154));
      expect(
        parseX11Color('  medium spring GREEN\t'),
        const RgbColor(0, 250, 154),
      );
    });

    test('rejects hex and unknown names', () {
      expect(tryParseX11Color('#ff0000'), isNull);
      expect(tryParseX11Color('nope'), isNull);
      expect(() => parseX11Color('nope'), throwsFormatException);
    });
  });

  group('parsePaletteEntry', () {
    test('accepts decimal and prefixed indices', () {
      expect(parsePaletteEntry('1=#ff0000'), (
        index: 1,
        color: const RgbColor(255, 0, 0),
      ));
      expect(parsePaletteEntry(' 0x10 = red '), (
        index: 16,
        color: const RgbColor(255, 0, 0),
      ));
      expect(parsePaletteEntry('0b11=blue').index, 3);
      expect(parsePaletteEntry('0o17=blue').index, 15);
      expect(parsePaletteEntry('255=#000').index, 255);
    });

    test('rejects malformed entries and overflowing indices', () {
      for (final bad in ['256=red', '=red', '1=', 'red', '1=nope', '-1=red']) {
        expect(tryParsePaletteEntry(bad), isNull, reason: bad);
        expect(
          () => parsePaletteEntry(bad),
          throwsFormatException,
          reason: bad,
        );
      }
    });
  });

  group('x11ColorNames', () {
    test('matches the native table', () {
      final names = x11ColorNames;
      expect(names.length, ghostty_color_x11_name_count());
      expect(names['MediumSpringGreen'], const RgbColor(0, 250, 154));
      expect(names['medium spring green'], const RgbColor(0, 250, 154));
      expect(names.keys.first, isNotEmpty);
    });

    test('every name parses to its colour', () {
      x11ColorNames.forEach((name, color) {
        expect(parseX11Color(name), color, reason: name);
      });
    });

    test('is unmodifiable and cached', () {
      expect(identical(x11ColorNames, x11ColorNames), isTrue);
      expect(
        () => x11ColorNames['x'] = const RgbColor(0, 0, 0),
        throwsUnsupportedError,
      );
    });
  });

  test('the library reads GhosttyColorRgb the way the bindings do', () {
    // ghostty_color_rgb_get exists for wasm hosts; it must agree with the
    // struct layout the Dart side relies on.
    using((arena) {
      final color = arena<GhosttyColorRgb>();
      rgbToNative(const RgbColor(1, 2, 3), color.ref);
      final out = arena<Uint8>(3);
      ghostty_color_rgb_get(color, out, out + 1, out + 2);
      expect(out.asTypedList(3), [1, 2, 3]);
    });
  });
}
