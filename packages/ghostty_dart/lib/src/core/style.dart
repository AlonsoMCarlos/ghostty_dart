/// The visual style of a terminal cell (`style.h`, `GhosttySgrUnderline`).
library;

import 'color.dart';
import 'enum_codec.dart';

/// How text is underlined (`GhosttySgrUnderline` in `sgr.h`).
enum UnderlineStyle {
  /// Not underlined.
  none(0),

  /// A single straight line (SGR 4 / 4:1).
  single(1),

  /// A double line (SGR 21 / 4:2).
  double(2),

  /// A curly line (SGR 4:3).
  curly(3),

  /// A dotted line (SGR 4:4).
  dotted(4),

  /// A dashed line (SGR 4:5).
  dashed(5),

  /// A style added by a later libghostty-vt release. Draw it as [single].
  unknown(null);

  const UnderlineStyle(this._raw);

  final int? _raw;
}

/// Converts raw `GhosttySgrUnderline` values to [UnderlineStyle] and back.
final underlineStyleCodec = RawEnumCodec<UnderlineStyle>(
  UnderlineStyle.values,
  raw: (style) => style._raw,
  unknown: UnderlineStyle.unknown,
);

/// The complete visual style of a terminal cell (`GhosttyStyle`).
///
/// Immutable; compare with `==`. `const CellStyle()` is the default style:
/// default colours and no attributes.
///
/// ```dart
/// const warning = CellStyle(foreground: PaletteColor.yellow, bold: true);
/// ```
final class CellStyle {
  /// A style with the given colours and attributes. Every argument defaults
  /// to the default style's value.
  const CellStyle({
    this.foreground = const DefaultColor(),
    this.background = const DefaultColor(),
    this.underlineColor = const DefaultColor(),
    this.bold = false,
    this.italic = false,
    this.faint = false,
    this.blink = false,
    this.inverse = false,
    this.invisible = false,
    this.strikethrough = false,
    this.overline = false,
    this.underline = UnderlineStyle.none,
  });

  /// Foreground (text) colour.
  final ColorRef foreground;

  /// Background colour.
  final ColorRef background;

  /// Underline colour. [DefaultColor] means "same as the foreground".
  final ColorRef underlineColor;

  /// Bold text.
  final bool bold;

  /// Italic text.
  final bool italic;

  /// Faint (dim) text.
  final bool faint;

  /// Blinking text.
  final bool blink;

  /// Foreground and background swapped.
  final bool inverse;

  /// Hidden text.
  final bool invisible;

  /// Struck-through text.
  final bool strikethrough;

  /// Overlined text.
  final bool overline;

  /// The underline style; [UnderlineStyle.none] when not underlined.
  final UnderlineStyle underline;

  /// Whether this is the default style: all colours default and no
  /// attributes set (same rule as `ghostty_style_is_default`).
  bool get isDefault => this == const CellStyle();

  /// Returns a copy with the given fields replaced.
  CellStyle copyWith({
    ColorRef? foreground,
    ColorRef? background,
    ColorRef? underlineColor,
    bool? bold,
    bool? italic,
    bool? faint,
    bool? blink,
    bool? inverse,
    bool? invisible,
    bool? strikethrough,
    bool? overline,
    UnderlineStyle? underline,
  }) => CellStyle(
    foreground: foreground ?? this.foreground,
    background: background ?? this.background,
    underlineColor: underlineColor ?? this.underlineColor,
    bold: bold ?? this.bold,
    italic: italic ?? this.italic,
    faint: faint ?? this.faint,
    blink: blink ?? this.blink,
    inverse: inverse ?? this.inverse,
    invisible: invisible ?? this.invisible,
    strikethrough: strikethrough ?? this.strikethrough,
    overline: overline ?? this.overline,
    underline: underline ?? this.underline,
  );

  @override
  bool operator ==(Object other) =>
      other is CellStyle &&
      other.foreground == foreground &&
      other.background == background &&
      other.underlineColor == underlineColor &&
      other.bold == bold &&
      other.italic == italic &&
      other.faint == faint &&
      other.blink == blink &&
      other.inverse == inverse &&
      other.invisible == invisible &&
      other.strikethrough == strikethrough &&
      other.overline == overline &&
      other.underline == underline;

  @override
  int get hashCode => Object.hash(
    foreground,
    background,
    underlineColor,
    bold,
    italic,
    faint,
    blink,
    inverse,
    invisible,
    strikethrough,
    overline,
    underline,
  );

  @override
  String toString() {
    final parts = <String>[
      if (foreground is! DefaultColor) 'foreground: $foreground',
      if (background is! DefaultColor) 'background: $background',
      if (underlineColor is! DefaultColor) 'underlineColor: $underlineColor',
      if (bold) 'bold',
      if (italic) 'italic',
      if (faint) 'faint',
      if (blink) 'blink',
      if (inverse) 'inverse',
      if (invisible) 'invisible',
      if (strikethrough) 'strikethrough',
      if (overline) 'overline',
      if (underline != UnderlineStyle.none) 'underline: ${underline.name}',
    ];
    return 'CellStyle(${parts.join(', ')})';
  }
}
