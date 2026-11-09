/// Ghostty's 256-colour palettes, luminance and contrast (`color.h`).
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../core/core.dart';
import '../core/internal.dart';
import '../ffi/bindings.g.dart';
import 'color_feature.dart';

/// The number of entries in a terminal palette.
const _paletteLength = 256;

/// Ghostty's built-in 256-colour palette: its base16 defaults (indices
/// 0–15), the xterm 6×6×6 colour cube (16–231) and the grayscale ramp
/// (232–255).
///
/// Unmodifiable and read once, on first use. Throws [UnsupportedError] if
/// the library was built without the colour feature.
List<RgbColor> get defaultColorPalette {
  ensureColorFeature('ghostty_color_palette_default');
  return _defaultPalette;
}

final List<RgbColor> _defaultPalette = using((arena) {
  final out = arena<GhosttyColorRgb>(_paletteLength);
  ghostty_color_palette_default(out);
  return _readPalette(out);
});

/// Generates a 256-colour palette that fits a theme's [background] and
/// [foreground], the way Ghostty does for themes that only define 16
/// colours.
///
/// Indices 0–15 always come from [base] ([defaultColorPalette] if omitted),
/// and so do the indices in [preserve]. The rest are generated: the colour
/// cube (16–231) by trilinear CIELAB interpolation, and the grayscale ramp
/// (232–255) from [background] to [foreground]. For light themes,
/// [harmonious] keeps that background-to-foreground direction; when `false`
/// (Ghostty's default) the cube and ramp run dark-to-light.
///
/// Returns a new unmodifiable list of 256 colours.
///
/// ```dart
/// final palette = generateColorPalette(
///   background: const RgbColor(0xfd, 0xf6, 0xe3),
///   foreground: const RgbColor(0x65, 0x7b, 0x83),
/// );
/// ```
///
/// Throws [ArgumentError] if [base] does not have exactly 256 entries,
/// [RangeError] for a [preserve] index outside 0–255, and [UnsupportedError]
/// if the library was built without the colour feature.
List<RgbColor> generateColorPalette({
  required RgbColor background,
  required RgbColor foreground,
  List<RgbColor>? base,
  Iterable<int> preserve = const [],
  bool harmonious = false,
}) {
  ensureColorFeature('ghostty_color_palette_generate');
  if (base != null && base.length != _paletteLength) {
    throw ArgumentError.value(
      base.length,
      'base',
      'must have exactly $_paletteLength entries',
    );
  }
  return using((arena) {
    final mask = arena<GhosttyColorPaletteMask>();
    for (final index in preserve) {
      RangeError.checkValueInInterval(index, 0, 255, 'preserve');
      mask.ref.bits[index >> 6] |= 1 << (index & 63);
    }
    final basePointer = base == null
        ? nullptr
        : _writePalette(base, arena<GhosttyColorRgb>(_paletteLength));
    final bg = arena<GhosttyColorRgb>();
    final fg = arena<GhosttyColorRgb>();
    rgbToNative(background, bg.ref);
    rgbToNative(foreground, fg.ref);
    final out = arena<GhosttyColorRgb>(_paletteLength);
    ghostty_color_palette_generate(basePointer, mask, bg, fg, harmonious, out);
    return _readPalette(out);
  });
}

Pointer<GhosttyColorRgb> _writePalette(
  List<RgbColor> palette,
  Pointer<GhosttyColorRgb> out,
) {
  for (var i = 0; i < _paletteLength; i++) {
    rgbToNative(palette[i], (out + i).ref);
  }
  return out;
}

List<RgbColor> _readPalette(Pointer<GhosttyColorRgb> palette) =>
    List.unmodifiable([
      for (var i = 0; i < _paletteLength; i++) rgbFromNative((palette + i).ref),
    ]);

/// Luminance and contrast of an [RgbColor], computed by Ghostty so that UI
/// decisions agree with the terminal's.
///
/// Each member throws [UnsupportedError] if the library was built without
/// the colour feature.
extension RgbColorMetrics on RgbColor {
  /// The W3C relative luminance, from 0.0 (black) to 1.0 (white), as used by
  /// WCAG contrast ratios.
  double get luminance {
    ensureColorFeature('ghostty_color_luminance');
    return _withRgb(this, ghostty_color_luminance);
  }

  /// The perceived luminance, from 0.0 (black) to 1.0 (white).
  ///
  /// Ghostty treats a background as light when this exceeds 0.5 (see
  /// [isLight]). Palette generation uses CIELAB lightness instead.
  double get perceivedLuminance {
    ensureColorFeature('ghostty_color_perceived_luminance');
    return _withRgb(this, ghostty_color_perceived_luminance);
  }

  /// Whether Ghostty considers this colour light, i.e. its
  /// [perceivedLuminance] exceeds 0.5.
  bool get isLight => perceivedLuminance > 0.5;

  /// The WCAG contrast ratio between this colour and [other], from 1.0
  /// (identical) to 21.0 (black and white). Symmetric.
  double contrastWith(RgbColor other) {
    ensureColorFeature('ghostty_color_contrast');
    return using((arena) {
      final a = arena<GhosttyColorRgb>();
      final b = arena<GhosttyColorRgb>();
      rgbToNative(this, a.ref);
      rgbToNative(other, b.ref);
      return ghostty_color_contrast(a, b);
    });
  }
}

double _withRgb(
  RgbColor color,
  double Function(Pointer<GhosttyColorRgb> color) metric,
) => withScratch(sizeOf<GhosttyColorRgb>(), (memory) {
  final rgb = memory.cast<GhosttyColorRgb>();
  rgbToNative(color, rgb.ref);
  return metric(rgb);
});
