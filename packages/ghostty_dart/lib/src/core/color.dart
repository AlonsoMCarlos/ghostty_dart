/// Colour value types shared by every module (`color.h`, `style.h`).
library;

/// A colour as a cell style or a terminal setting refers to it: the default
/// colour, a palette index, or a direct RGB value.
///
/// Mirrors `GhosttyStyleColor` (`style.h`). Switch over it exhaustively:
///
/// ```dart
/// final resolved = switch (style.foreground) {
///   DefaultColor() => theme.foreground,
///   PaletteColor(:final index) => palette[index],
///   RgbColor() && final rgb => rgb,
/// };
/// ```
sealed class ColorRef {
  /// Base constructor for the three subclasses.
  const ColorRef();
}

/// No colour chosen: use the terminal's default colour for this slot.
///
/// A style colour tag added by a later libghostty-vt release also decodes to
/// this, so renderers never see a colour they cannot draw.
final class DefaultColor extends ColorRef {
  /// The default colour. All instances are equal.
  const DefaultColor();

  @override
  bool operator ==(Object other) => other is DefaultColor;

  @override
  int get hashCode => (DefaultColor).hashCode;

  @override
  String toString() => 'DefaultColor()';
}

/// An index into the terminal's 256-colour palette.
///
/// Indices 0–15 are the named ANSI colours ([black] … [brightWhite]), 16–231
/// the 6×6×6 colour cube and 232–255 the grayscale ramp.
final class PaletteColor extends ColorRef {
  /// The palette entry at [index], which must be in 0–255.
  const PaletteColor(this.index)
    : assert(index >= 0 && index <= 255, 'palette index must be 0-255');

  /// The palette index, 0–255.
  final int index;

  /// ANSI black (palette index 0).
  static const black = PaletteColor(0);

  /// ANSI red (palette index 1).
  static const red = PaletteColor(1);

  /// ANSI green (palette index 2).
  static const green = PaletteColor(2);

  /// ANSI yellow (palette index 3).
  static const yellow = PaletteColor(3);

  /// ANSI blue (palette index 4).
  static const blue = PaletteColor(4);

  /// ANSI magenta (palette index 5).
  static const magenta = PaletteColor(5);

  /// ANSI cyan (palette index 6).
  static const cyan = PaletteColor(6);

  /// ANSI white (palette index 7).
  static const white = PaletteColor(7);

  /// ANSI bright black (palette index 8).
  static const brightBlack = PaletteColor(8);

  /// ANSI bright red (palette index 9).
  static const brightRed = PaletteColor(9);

  /// ANSI bright green (palette index 10).
  static const brightGreen = PaletteColor(10);

  /// ANSI bright yellow (palette index 11).
  static const brightYellow = PaletteColor(11);

  /// ANSI bright blue (palette index 12).
  static const brightBlue = PaletteColor(12);

  /// ANSI bright magenta (palette index 13).
  static const brightMagenta = PaletteColor(13);

  /// ANSI bright cyan (palette index 14).
  static const brightCyan = PaletteColor(14);

  /// ANSI bright white (palette index 15).
  static const brightWhite = PaletteColor(15);

  @override
  bool operator ==(Object other) =>
      other is PaletteColor && other.index == index;

  @override
  int get hashCode => Object.hash(PaletteColor, index);

  @override
  String toString() => 'PaletteColor($index)';
}

/// A 24-bit RGB colour (`GhosttyColorRgb`).
///
/// Used both on its own (palette entries, default foreground/background) and
/// as a [ColorRef] for direct-colour styles.
final class RgbColor extends ColorRef {
  /// A colour from its [r], [g] and [b] components, each 0–255.
  const RgbColor(this.r, this.g, this.b)
    : assert(r >= 0 && r <= 255, 'r must be 0-255'),
      assert(g >= 0 && g <= 255, 'g must be 0-255'),
      assert(b >= 0 && b <= 255, 'b must be 0-255');

  /// A colour from a packed `0xRRGGBB` integer. Higher bits are ignored.
  const RgbColor.fromValue(int value)
    : r = (value >> 16) & 0xff,
      g = (value >> 8) & 0xff,
      b = value & 0xff;

  /// Red component, 0–255.
  final int r;

  /// Green component, 0–255.
  final int g;

  /// Blue component, 0–255.
  final int b;

  /// The colour packed as `0xRRGGBB`. Inverse of [RgbColor.fromValue].
  int get value => (r << 16) | (g << 8) | b;

  /// The colour as a lowercase `#rrggbb` string.
  String toHex() => '#${value.toRadixString(16).padLeft(6, '0')}';

  @override
  bool operator ==(Object other) =>
      other is RgbColor && other.r == r && other.g == g && other.b == b;

  @override
  int get hashCode => Object.hash(RgbColor, value);

  @override
  String toString() => 'RgbColor($r, $g, $b)';
}
