// Ported from package:xterm 4.0.0 (lib/src/ui/terminal_theme.dart).
// Copyright (c) 2020 xuty. MIT License, see LICENSE.xterm.

import 'package:flutter/widgets.dart';

/// The colours of a `TerminalView`: the cursor, the selection, the default
/// foreground and background, the 16 ANSI colours, and three search-hit
/// colours that xterm 4.0.0 never paints (kept for the API).
///
/// `TerminalView` converts it to `ghostty_dart_flutter`'s `VtTerminalTheme`,
/// which has the same 23 fields.
class TerminalTheme {
  /// Creates a theme from its 23 colours.
  const TerminalTheme({
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

  /// The cursor's colour.
  final Color cursor;

  /// The selection's colour, painted over the selected cells.
  final Color selection;

  /// The default text colour.
  final Color foreground;

  /// The default background colour.
  final Color background;

  /// ANSI colour black (palette entries 0-7).
  final Color black;

  /// ANSI colour red (palette entries 0-7).
  final Color red;

  /// ANSI colour green (palette entries 0-7).
  final Color green;

  /// ANSI colour yellow (palette entries 0-7).
  final Color yellow;

  /// ANSI colour blue (palette entries 0-7).
  final Color blue;

  /// ANSI colour magenta (palette entries 0-7).
  final Color magenta;

  /// ANSI colour cyan (palette entries 0-7).
  final Color cyan;

  /// ANSI colour white (palette entries 0-7).
  final Color white;

  /// ANSI colour bright black (palette entries 8-15).
  final Color brightBlack;

  /// ANSI colour bright red (palette entries 8-15).
  final Color brightRed;

  /// ANSI colour bright green (palette entries 8-15).
  final Color brightGreen;

  /// ANSI colour bright yellow (palette entries 8-15).
  final Color brightYellow;

  /// ANSI colour bright blue (palette entries 8-15).
  final Color brightBlue;

  /// ANSI colour bright magenta (palette entries 8-15).
  final Color brightMagenta;

  /// ANSI colour bright cyan (palette entries 8-15).
  final Color brightCyan;

  /// ANSI colour bright white (palette entries 8-15).
  final Color brightWhite;

  /// The `searchHitBackground` colour; never painted, as in xterm 4.0.0.
  final Color searchHitBackground;

  /// The `searchHitBackgroundCurrent` colour; never painted, as in xterm 4.0.0.
  final Color searchHitBackgroundCurrent;

  /// The `searchHitForeground` colour; never painted, as in xterm 4.0.0.
  final Color searchHitForeground;
}
