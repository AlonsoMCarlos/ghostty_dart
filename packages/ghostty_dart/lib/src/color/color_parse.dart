/// Parsing colour strings the way Ghostty's config and theme files do, and
/// Ghostty's X11 colour name table (`color.h`).
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../core/core.dart';
import '../core/internal.dart';
import '../ffi/bindings.g.dart';
import 'color_feature.dart';

/// Parses a colour in Ghostty's terminal colour syntax.
///
/// Accepts X11 colour names (`'medium spring green'`), hex colours with 3,
/// 6, 9 or 12 digits (`'#abc'`, `'#aabbcc'`; the `#` is optional for 3 and
/// 6 digits), and `rgb:<r>/<g>/<b>` or `rgbi:<r>/<g>/<b>` specifications.
/// Leading and trailing spaces and tabs are ignored.
///
/// ```dart
/// parseColor('#abc'); // RgbColor(170, 187, 204)
/// ```
///
/// Throws [FormatException] if [value] is not a colour, and
/// [UnsupportedError] if the library was built without the colour feature.
/// See [tryParseColor] for a version that returns `null`.
RgbColor parseColor(String value) =>
    tryParseColor(value) ??
    (throw FormatException('Not a valid colour', value));

/// Like [parseColor], but returns `null` if [value] is not a colour.
RgbColor? tryParseColor(String value) =>
    _parse(value, 'ghostty_color_parse', ghostty_color_parse);

/// Parses an X11 colour name from Ghostty's embedded `rgb.txt` table, such as
/// `'DarkSlateGray'` or `'dark slate gray'`.
///
/// Matching is ASCII case-insensitive and ignores leading and trailing spaces
/// and tabs. Hex values are not accepted; use [parseColor] for those.
///
/// Throws [FormatException] if no colour has that name, and
/// [UnsupportedError] if the library was built without the colour feature.
/// See [tryParseX11Color] for a version that returns `null`.
RgbColor parseX11Color(String name) =>
    tryParseX11Color(name) ??
    (throw FormatException('Not an X11 colour name', name));

/// Like [parseX11Color], but returns `null` if no colour has that name.
RgbColor? tryParseX11Color(String name) =>
    _parse(name, 'ghostty_color_parse_x11', ghostty_color_parse_x11);

/// Parses a palette entry in Ghostty's `palette` config syntax, `N=COLOR`.
///
/// `N` is a palette index from 0 to 255, in decimal or with a `0x`, `0o` or
/// `0b` prefix. `COLOR` uses the syntax of [parseColor]. Spaces and tabs
/// around both parts are ignored.
///
/// ```dart
/// final entry = parsePaletteEntry('0x10 = #ff0000');
/// // (index: 16, color: RgbColor(255, 0, 0))
/// ```
///
/// Throws [FormatException] if [value] is not a valid entry (including an
/// index above 255), and [UnsupportedError] if the library was built without
/// the colour feature. See [tryParsePaletteEntry].
({int index, RgbColor color}) parsePaletteEntry(String value) =>
    tryParsePaletteEntry(value) ??
    (throw FormatException('Not a valid palette entry', value));

/// Like [parsePaletteEntry], but returns `null` if [value] is not a valid
/// entry.
({int index, RgbColor color})? tryParsePaletteEntry(String value) {
  const operation = 'ghostty_color_parse_palette_entry';
  ensureColorFeature(operation);
  return withUtf8(
    value,
    (data, length) => using((arena) {
      final index = arena<Uint8>();
      final rgb = arena<GhosttyColorRgb>();
      final raw = ghostty_color_parse_palette_entry(
        data.cast(),
        length,
        index,
        rgb,
      );
      if (_isInvalid(raw, operation)) return null;
      return (index: index.value, color: rgbFromNative(rgb.ref));
    }),
  );
}

/// Every name in Ghostty's X11 colour table, mapped to its colour, in
/// `rgb.txt` order.
///
/// The keys are the exact spellings `rgb.txt` supports, and aliases are
/// separate keys (`'medium spring green'` and `'MediumSpringGreen'`);
/// [parseX11Color] also accepts them in any letter case. The map is
/// unmodifiable and built once, on first use.
///
/// Throws [UnsupportedError] if the library was built without the colour
/// feature.
Map<String, RgbColor> get x11ColorNames {
  ensureColorFeature('ghostty_color_x11_names');
  return _x11ColorNames;
}

final Map<String, RgbColor> _x11ColorNames = _readX11Names();

Map<String, RgbColor> _readX11Names() {
  final count = ghostty_color_x11_name_count();
  final table = ghostty_color_x11_names();
  final names = <String, RgbColor>{};
  // The table is static library memory; the count excludes the NULL-name
  // terminator, which is also checked in case the two ever disagree.
  for (var i = 0; i < count; i++) {
    final entry = (table + i).ref;
    if (entry.name == nullptr) break;
    names[entry.name.cast<Utf8>().toDartString()] = rgbFromNative(entry.color);
  }
  return Map.unmodifiable(names);
}

RgbColor? _parse(
  String value,
  String operation,
  int Function(Pointer<Char> value, int length, Pointer<GhosttyColorRgb> out)
  parse,
) {
  ensureColorFeature(operation);
  return withUtf8(
    value,
    (data, length) => withScratch(sizeOf<GhosttyColorRgb>(), (memory) {
      final out = memory.cast<GhosttyColorRgb>();
      if (_isInvalid(parse(data.cast(), length, out), operation)) return null;
      return rgbFromNative(out.ref);
    }),
  );
}

/// Whether [raw] is the `GHOSTTY_INVALID_VALUE` these parsers return for
/// input that does not parse. Other errors throw.
bool _isInvalid(int raw, String operation) =>
    checkResultAllowing(raw, operation, const {
      GhosttyResultCode.invalidValue,
    }) ==
    GhosttyResultCode.invalidValue;
