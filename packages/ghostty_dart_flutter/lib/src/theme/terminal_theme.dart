import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:ghostty_dart/ghostty_dart.dart';

/// The colours of a terminal view, shaped like `TerminalTheme` of
/// `package:xterm` 4.0.0 (same fields, same meaning).
///
/// [VtTerminalController] pushes [foreground], [background], [cursor] and
/// the 16 ANSI colours into the terminal as its default colours and palette
/// (the other 240 palette entries are the standard xterm 256-colour cube and
/// grey ramp). Programs that query colours with OSC 4/10/11/12 therefore get
/// the theme's colours, and the renderer reads every cell colour from the
/// terminal's render state. [selection] and the `searchHit*` colours are
/// drawn by the view only. The terminal stores opaque colours, so the alpha
/// channel only matters for [cursor] and [selection], which the view draws
/// itself.
///
/// ```dart
/// final controller = VtTerminalController(
///   theme: VtTerminalTheme.defaultTheme.copyWith(
///     background: const Color(0xFF000000),
///   ),
/// );
/// ```
@immutable
final class VtTerminalTheme {
  /// Creates a theme. Every colour is required, as in xterm's
  /// `TerminalTheme`.
  const VtTerminalTheme({
    required this.cursor,
    required this.selection,
    required this.foreground,
    required this.background,
    required this.black,
    required this.white,
    required this.red,
    required this.green,
    required this.yellow,
    required this.blue,
    required this.magenta,
    required this.cyan,
    required this.brightBlack,
    required this.brightRed,
    required this.brightGreen,
    required this.brightYellow,
    required this.brightBlue,
    required this.brightMagenta,
    required this.brightCyan,
    required this.brightWhite,
    required this.searchHitBackground,
    required this.searchHitBackgroundCurrent,
    required this.searchHitForeground,
  });

  // The two themes below copy the values of xterm 4.0.0's
  // `TerminalThemes.defaultTheme` and `TerminalThemes.whiteOnBlack`
  // (lib/src/ui/themes.dart, MIT licence), so both packages look the same
  // by default.

  /// The default theme: light grey on dark grey (xterm 4.0.0's
  /// `TerminalThemes.defaultTheme`).
  static const defaultTheme = VtTerminalTheme(
    cursor: Color(0xAAAEAFAD),
    selection: Color(0xAAAEAFAD),
    foreground: Color(0xFFCCCCCC),
    background: Color(0xFF1E1E1E),
    black: Color(0xFF000000),
    red: Color(0xFFCD3131),
    green: Color(0xFF0DBC79),
    yellow: Color(0xFFE5E510),
    blue: Color(0xFF2472C8),
    magenta: Color(0xFFBC3FBC),
    cyan: Color(0xFF11A8CD),
    white: Color(0xFFE5E5E5),
    brightBlack: Color(0xFF666666),
    brightRed: Color(0xFFF14C4C),
    brightGreen: Color(0xFF23D18B),
    brightYellow: Color(0xFFF5F543),
    brightBlue: Color(0xFF3B8EEA),
    brightMagenta: Color(0xFFD670D6),
    brightCyan: Color(0xFF29B8DB),
    brightWhite: Color(0xFFFFFFFF),
    searchHitBackground: Color(0xFFFFFF2B),
    searchHitBackgroundCurrent: Color(0xFF31FF26),
    searchHitForeground: Color(0xFF000000),
  );

  /// White on black (xterm 4.0.0's `TerminalThemes.whiteOnBlack`).
  static const whiteOnBlack = VtTerminalTheme(
    cursor: Color(0xFFAEAFAD),
    selection: Color(0xFFAEAFAD),
    foreground: Color(0xFFFFFFFF),
    background: Color(0xFF000000),
    black: Color(0xFF000000),
    red: Color(0xFFCD3131),
    green: Color(0xFF0DBC79),
    yellow: Color(0xFFE5E510),
    blue: Color(0xFF2472C8),
    magenta: Color(0xFFBC3FBC),
    cyan: Color(0xFF11A8CD),
    white: Color(0xFFE5E5E5),
    brightBlack: Color(0xFF666666),
    brightRed: Color(0xFFF14C4C),
    brightGreen: Color(0xFF23D18B),
    brightYellow: Color(0xFFF5F543),
    brightBlue: Color(0xFF3B8EEA),
    brightMagenta: Color(0xFFD670D6),
    brightCyan: Color(0xFF29B8DB),
    brightWhite: Color(0xFFFFFFFF),
    searchHitBackground: Color(0xFFFFFF2B),
    searchHitBackgroundCurrent: Color(0xFF31FF26),
    searchHitForeground: Color(0xFF000000),
  );

  /// The cursor colour. Its alpha is used when the view draws the cursor.
  final Color cursor;

  /// The selection highlight. Its alpha is used when the view draws the
  /// selection.
  final Color selection;

  /// The default text colour.
  final Color foreground;

  /// The default background colour.
  final Color background;

  /// ANSI colour 0.
  final Color black;

  /// ANSI colour 1.
  final Color red;

  /// ANSI colour 2.
  final Color green;

  /// ANSI colour 3.
  final Color yellow;

  /// ANSI colour 4.
  final Color blue;

  /// ANSI colour 5.
  final Color magenta;

  /// ANSI colour 6.
  final Color cyan;

  /// ANSI colour 7.
  final Color white;

  /// ANSI colour 8.
  final Color brightBlack;

  /// ANSI colour 9.
  final Color brightRed;

  /// ANSI colour 10.
  final Color brightGreen;

  /// ANSI colour 11.
  final Color brightYellow;

  /// ANSI colour 12.
  final Color brightBlue;

  /// ANSI colour 13.
  final Color brightMagenta;

  /// ANSI colour 14.
  final Color brightCyan;

  /// ANSI colour 15.
  final Color brightWhite;

  /// The background of search matches.
  final Color searchHitBackground;

  /// The background of the current search match.
  final Color searchHitBackgroundCurrent;

  /// The text colour of search matches.
  final Color searchHitForeground;

  /// The 16 ANSI colours in palette order (0 = [black] … 15 =
  /// [brightWhite]).
  List<Color> get ansiColors => [
    black,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    brightBlack,
    brightRed,
    brightGreen,
    brightYellow,
    brightBlue,
    brightMagenta,
    brightCyan,
    brightWhite,
  ];

  /// The full 256-colour palette this theme gives the terminal: the 16
  /// [ansiColors], then the standard xterm 6×6×6 colour cube (16–231) and
  /// grey ramp (232–255). Alpha is dropped.
  List<RgbColor> toPalette() => [
    for (final color in ansiColors) rgbOf(color),
    for (var i = 0; i < 216; i++)
      RgbColor(
        _cubeLevel(i ~/ 36),
        _cubeLevel((i ~/ 6) % 6),
        _cubeLevel(i % 6),
      ),
    for (var i = 0; i < 24; i++) RgbColor(8 + 10 * i, 8 + 10 * i, 8 + 10 * i),
  ];

  /// The opaque [RgbColor] of [color] (alpha dropped), as the terminal
  /// stores it.
  static RgbColor rgbOf(Color color) =>
      RgbColor.fromValue(color.toARGB32() & 0xFFFFFF);

  static int _cubeLevel(int step) => step == 0 ? 0 : 55 + 40 * step;

  /// A copy with the given colours replaced.
  VtTerminalTheme copyWith({
    Color? cursor,
    Color? selection,
    Color? foreground,
    Color? background,
    Color? black,
    Color? red,
    Color? green,
    Color? yellow,
    Color? blue,
    Color? magenta,
    Color? cyan,
    Color? white,
    Color? brightBlack,
    Color? brightRed,
    Color? brightGreen,
    Color? brightYellow,
    Color? brightBlue,
    Color? brightMagenta,
    Color? brightCyan,
    Color? brightWhite,
    Color? searchHitBackground,
    Color? searchHitBackgroundCurrent,
    Color? searchHitForeground,
  }) => VtTerminalTheme(
    cursor: cursor ?? this.cursor,
    selection: selection ?? this.selection,
    foreground: foreground ?? this.foreground,
    background: background ?? this.background,
    black: black ?? this.black,
    red: red ?? this.red,
    green: green ?? this.green,
    yellow: yellow ?? this.yellow,
    blue: blue ?? this.blue,
    magenta: magenta ?? this.magenta,
    cyan: cyan ?? this.cyan,
    white: white ?? this.white,
    brightBlack: brightBlack ?? this.brightBlack,
    brightRed: brightRed ?? this.brightRed,
    brightGreen: brightGreen ?? this.brightGreen,
    brightYellow: brightYellow ?? this.brightYellow,
    brightBlue: brightBlue ?? this.brightBlue,
    brightMagenta: brightMagenta ?? this.brightMagenta,
    brightCyan: brightCyan ?? this.brightCyan,
    brightWhite: brightWhite ?? this.brightWhite,
    searchHitBackground: searchHitBackground ?? this.searchHitBackground,
    searchHitBackgroundCurrent:
        searchHitBackgroundCurrent ?? this.searchHitBackgroundCurrent,
    searchHitForeground: searchHitForeground ?? this.searchHitForeground,
  );

  List<Color> get _all => [
    cursor,
    selection,
    foreground,
    background,
    ...ansiColors,
    searchHitBackground,
    searchHitBackgroundCurrent,
    searchHitForeground,
  ];

  @override
  bool operator ==(Object other) =>
      other is VtTerminalTheme && listEquals(other._all, _all);

  @override
  int get hashCode => Object.hashAll(_all);

  @override
  String toString() =>
      'VtTerminalTheme(foreground: $foreground, background: $background)';
}
