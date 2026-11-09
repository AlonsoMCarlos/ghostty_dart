/// Conversions between the shared value types and their raw FFI structs.
///
/// Internal: exported only through `internal.dart`. Readers take a struct
/// view (`pointer.ref`) and copy it into an immutable Dart value; writers
/// fill a struct view from a Dart value.
library;

import '../ffi/bindings.g.dart';
import 'color.dart';
import 'point.dart';
import 'style.dart';

/// Reads a `GhosttyColorRgb`.
RgbColor rgbFromNative(GhosttyColorRgb color) =>
    RgbColor(color.r, color.g, color.b);

/// Writes [color] into a `GhosttyColorRgb`.
///
/// Throws [RangeError] if a component is outside 0–255 (the constructor only
/// asserts in debug mode).
void rgbToNative(RgbColor color, GhosttyColorRgb out) {
  out
    ..r = RangeError.checkValueInInterval(color.r, 0, 255, 'r')
    ..g = RangeError.checkValueInInterval(color.g, 0, 255, 'g')
    ..b = RangeError.checkValueInInterval(color.b, 0, 255, 'b');
}

/// Reads a `GhosttyStyleColor`. Unknown tags decode to [DefaultColor].
ColorRef styleColorFromNative(GhosttyStyleColor color) => switch (color.tag) {
  GhosttyStyleColorTag.GHOSTTY_STYLE_COLOR_PALETTE => PaletteColor(
    color.value.palette,
  ),
  GhosttyStyleColorTag.GHOSTTY_STYLE_COLOR_RGB => rgbFromNative(
    color.value.rgb,
  ),
  _ => const DefaultColor(),
};

/// Writes [color] into a `GhosttyStyleColor`, zeroing the unused value bytes
/// as the header requires.
void styleColorToNative(ColorRef color, GhosttyStyleColor out) {
  final rgb = out.value.rgb
    ..r = 0
    ..g = 0
    ..b = 0;
  switch (color) {
    case DefaultColor():
      out.tag = GhosttyStyleColorTag.GHOSTTY_STYLE_COLOR_NONE;
    case PaletteColor(:final index):
      out.tag = GhosttyStyleColorTag.GHOSTTY_STYLE_COLOR_PALETTE;
      out.value.palette = RangeError.checkValueInInterval(
        index,
        0,
        255,
        'index',
      );
    case RgbColor():
      out.tag = GhosttyStyleColorTag.GHOSTTY_STYLE_COLOR_RGB;
      rgbToNative(color, rgb);
  }
}

/// Decodes the attribute bits and underline style of `GhosttyStyleFlags`
/// together with three colours into a [CellStyle].
CellStyle cellStyleFromParts({
  required int flags,
  required ColorRef foreground,
  required ColorRef background,
  required ColorRef underlineColor,
}) => CellStyle(
  foreground: foreground,
  background: background,
  underlineColor: underlineColor,
  bold: flags & GHOSTTY_STYLE_FLAG_BOLD != 0,
  italic: flags & GHOSTTY_STYLE_FLAG_ITALIC != 0,
  faint: flags & GHOSTTY_STYLE_FLAG_FAINT != 0,
  blink: flags & GHOSTTY_STYLE_FLAG_BLINK != 0,
  inverse: flags & GHOSTTY_STYLE_FLAG_INVERSE != 0,
  invisible: flags & GHOSTTY_STYLE_FLAG_INVISIBLE != 0,
  strikethrough: flags & GHOSTTY_STYLE_FLAG_STRIKETHROUGH != 0,
  overline: flags & GHOSTTY_STYLE_FLAG_OVERLINE != 0,
  underline: underlineStyleCodec.decode(
    (flags & GHOSTTY_STYLE_UNDERLINE_MASK) >> GHOSTTY_STYLE_UNDERLINE_SHIFT,
  ),
);

/// Encodes the attributes and underline style of [style] as
/// `GhosttyStyleFlags`.
///
/// Throws [ArgumentError] for [UnderlineStyle.unknown].
int cellStyleFlags(CellStyle style) =>
    (style.bold ? GHOSTTY_STYLE_FLAG_BOLD : 0) |
    (style.italic ? GHOSTTY_STYLE_FLAG_ITALIC : 0) |
    (style.faint ? GHOSTTY_STYLE_FLAG_FAINT : 0) |
    (style.blink ? GHOSTTY_STYLE_FLAG_BLINK : 0) |
    (style.inverse ? GHOSTTY_STYLE_FLAG_INVERSE : 0) |
    (style.invisible ? GHOSTTY_STYLE_FLAG_INVISIBLE : 0) |
    (style.strikethrough ? GHOSTTY_STYLE_FLAG_STRIKETHROUGH : 0) |
    (style.overline ? GHOSTTY_STYLE_FLAG_OVERLINE : 0) |
    (underlineStyleCodec.encode(style.underline) <<
        GHOSTTY_STYLE_UNDERLINE_SHIFT);

/// Reads a `GhosttyStyle`.
CellStyle cellStyleFromNative(GhosttyStyle style) => cellStyleFromParts(
  flags: style.flags,
  foreground: styleColorFromNative(style.fg_color),
  background: styleColorFromNative(style.bg_color),
  underlineColor: styleColorFromNative(style.underline_color),
);

/// Writes [style] into a `GhosttyStyle`, with the reserved field zeroed.
void cellStyleToNative(CellStyle style, GhosttyStyle out) {
  styleColorToNative(style.foreground, out.fg_color);
  styleColorToNative(style.background, out.bg_color);
  styleColorToNative(style.underlineColor, out.underline_color);
  out
    ..flags = cellStyleFlags(style)
    ..reserved = 0;
}

/// Reads a `GhosttyPoint`. Unknown tags decode to [PointSpace.unknown].
GridPoint gridPointFromNative(GhosttyPoint point) => GridPoint(
  pointSpaceCodec.decode(point.tag),
  point.value.coordinate.x,
  point.value.coordinate.y,
);

/// Writes [point] into a `GhosttyPoint`.
///
/// Throws [ArgumentError] for [PointSpace.unknown] and [RangeError] for
/// coordinates outside `uint16_t` / `uint32_t`.
void gridPointToNative(GridPoint point, GhosttyPoint out) {
  out.tag = pointSpaceCodec.encode(point.space);
  out.value.coordinate
    ..x = RangeError.checkValueInInterval(point.x, 0, 0xFFFF, 'x')
    ..y = RangeError.checkValueInInterval(point.y, 0, 0xFFFFFFFF, 'y');
}
