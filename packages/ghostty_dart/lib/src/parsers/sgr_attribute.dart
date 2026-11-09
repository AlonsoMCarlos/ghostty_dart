/// The typed attributes an SGR (Select Graphic Rendition) sequence sets
/// (`GhosttySgrAttribute` in `sgr.h`).
///
/// Pure Dart: no `dart:ffi`, so a future web backend can reuse it.
library;

import '../core/core.dart';
import '../core/list_equality.dart';

/// One attribute of an SGR sequence, as returned by `SgrParser.parse`.
///
/// The hierarchy is sealed, so a `switch` over it is exhaustive. Match
/// [SgrColorAttribute] to handle the three colour slots at once.
///
/// ```dart
/// var pen = const CellStyle();
/// for (final attribute in parser.parse([1, 38, 5, 196])) {
///   switch (attribute) {
///     case SgrReset():
///       pen = const CellStyle();
///     case SgrFlag(flag: SgrFlagKind.bold):
///       pen = pen.copyWith(bold: true);
///     case SgrFlag():
///       break; // the other flags, handled the same way
///     case SgrUnderline(:final style):
///       pen = pen.copyWith(underline: style);
///     case SgrForeground(:final color):
///       pen = pen.copyWith(foreground: color);
///     case SgrBackground(:final color):
///       pen = pen.copyWith(background: color);
///     case SgrUnderlineColor(:final color):
///       pen = pen.copyWith(underlineColor: color);
///     case SgrUnrecognized():
///       break; // terminals ignore these
///   }
/// }
/// ```
sealed class SgrAttribute {
  /// Base constructor for the subclasses.
  const SgrAttribute();
}

/// SGR 0 (or an empty parameter list): reset every attribute and colour to
/// the default.
final class SgrReset extends SgrAttribute {
  /// The reset attribute. All instances are equal.
  const SgrReset();

  @override
  bool operator ==(Object other) => other is SgrReset;

  @override
  int get hashCode => (SgrReset).hashCode;

  @override
  String toString() => 'SgrReset()';
}

/// An attribute that turns a text property on or off, with no value.
final class SgrFlag extends SgrAttribute {
  /// The attribute [flag].
  const SgrFlag(this.flag);

  /// Which property is set or reset.
  final SgrFlagKind flag;

  @override
  bool operator ==(Object other) => other is SgrFlag && other.flag == flag;

  @override
  int get hashCode => Object.hash(SgrFlag, flag);

  @override
  String toString() => 'SgrFlag(${flag.name})';
}

/// The value-less SGR attributes. The `reset*` members turn a property off.
///
/// Dart-only: decoded from the native tag by the parser, so it has no
/// `unknown` member; tags this package does not know become
/// [SgrUnrecognized].
enum SgrFlagKind {
  /// SGR 1.
  bold,

  /// SGR 22: normal intensity. Turns off both [bold] and [faint].
  resetBold,

  /// SGR 3.
  italic,

  /// SGR 23.
  resetItalic,

  /// SGR 2: dim text.
  faint,

  /// SGR 53.
  overline,

  /// SGR 55.
  resetOverline,

  /// SGR 5 or 6.
  blink,

  /// SGR 25.
  resetBlink,

  /// SGR 7: swap foreground and background.
  inverse,

  /// SGR 27.
  resetInverse,

  /// SGR 8: hidden text.
  invisible,

  /// SGR 28.
  resetInvisible,

  /// SGR 9.
  strikethrough,

  /// SGR 29.
  resetStrikethrough,
}

/// SGR 4 (optionally with a `4:n` style), 21 (double) or 24 (off): the
/// underline style.
final class SgrUnderline extends SgrAttribute {
  /// An underline of [style]; [UnderlineStyle.none] turns it off.
  const SgrUnderline(this.style);

  /// The underline style. `4:n` with an unknown `n` is reported as
  /// [UnderlineStyle.single] by the library.
  final UnderlineStyle style;

  @override
  bool operator ==(Object other) =>
      other is SgrUnderline && other.style == style;

  @override
  int get hashCode => Object.hash(SgrUnderline, style);

  @override
  String toString() => 'SgrUnderline(${style.name})';
}

/// How an SGR colour attribute was written. Keeps the distinction a
/// renderer may need, e.g. "bold is bright" applies only to [standard].
///
/// Dart-only: decoded from the native tag, so it has no `unknown` member.
enum SgrColorForm {
  /// SGR 30–37 / 40–47: palette indices 0–7.
  standard,

  /// SGR 90–97 / 100–107: palette indices 8–15.
  bright,

  /// SGR 38;5;n / 48;5;n / 58;5;n: any palette index.
  indexed,

  /// SGR 38;2;r;g;b and its colon forms: an RGB colour.
  direct,

  /// SGR 39 / 49 / 59: back to the default colour.
  reset,
}

/// The shared shape of the three colour attributes: [SgrForeground],
/// [SgrBackground] and [SgrUnderlineColor]. Two colour attributes are equal
/// only if they set the same slot with the same [color] and [form].
sealed class SgrColorAttribute extends SgrAttribute {
  /// Base constructor: [color] in [form]. Only the subclasses call it.
  const SgrColorAttribute(this.color, this.form);

  /// The new colour: a [PaletteColor], an [RgbColor], or [DefaultColor] when
  /// [form] is [SgrColorForm.reset].
  final ColorRef color;

  /// How the colour was written.
  final SgrColorForm form;

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      other is SgrColorAttribute &&
      other.color == color &&
      other.form == form;

  @override
  int get hashCode => Object.hash(runtimeType, color, form);

  @override
  String toString() => '$runtimeType($color, ${form.name})';
}

/// Sets the foreground (text) colour.
final class SgrForeground extends SgrColorAttribute {
  /// A foreground of [color], written in [form].
  const SgrForeground(super.color, super.form);
}

/// Sets the background colour.
final class SgrBackground extends SgrColorAttribute {
  /// A background of [color], written in [form].
  const SgrBackground(super.color, super.form);
}

/// Sets the underline colour (SGR 58, reset by 59). Never
/// [SgrColorForm.standard] or [SgrColorForm.bright].
final class SgrUnderlineColor extends SgrColorAttribute {
  /// An underline colour of [color], written in [form].
  const SgrUnderlineColor(super.color, super.form);
}

/// Parameters the parser did not recognise (an unknown or malformed
/// attribute), or an attribute tag added by a later libghostty-vt release.
///
/// Terminals ignore these. Parsing continues with the next attribute.
final class SgrUnrecognized extends SgrAttribute {
  /// An unrecognised attribute; see [parameters] and [allParameters].
  SgrUnrecognized({
    required List<int> parameters,
    required List<int> allParameters,
  }) : parameters = List.unmodifiable(parameters),
       allParameters = List.unmodifiable(allParameters);

  /// The parameters from the unrecognised attribute on (`unknown_partial`).
  ///
  /// For a colon group (`99:1:2`) this is the group only. Otherwise it is
  /// the rest of the list from the unrecognised parameter to the end, even
  /// though only that parameter was skipped: for `[99, 1]` it is `[99, 1]`
  /// and the next attribute is still bold. Empty for a tag from a later
  /// library.
  final List<int> parameters;

  /// The whole parameter list given to the parser (`unknown_full`).
  final List<int> allParameters;

  @override
  bool operator ==(Object other) =>
      other is SgrUnrecognized &&
      listEquals(other.parameters, parameters) &&
      listEquals(other.allParameters, allParameters);

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(parameters), Object.hashAll(allParameters));

  @override
  String toString() => 'SgrUnrecognized($parameters of $allParameters)';
}
