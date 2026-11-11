// Ported from package:xterm 4.0.0 (lib/src/core/color.dart).
// Copyright (c) 2020 xuty. MIT License, see LICENSE.xterm.

/// The 16 named colours, as the low bits of a [CellColor.named] colour.
abstract class NamedColor {
  /// Black (0).
  static const black = 0;

  /// Red (1).
  static const red = 1;

  /// Green (2).
  static const green = 2;

  /// Yellow (3).
  static const yellow = 3;

  /// Blue (4).
  static const blue = 4;

  /// Magenta (5).
  static const magenta = 5;

  /// Cyan (6).
  static const cyan = 6;

  /// White (7).
  static const white = 7;

  /// Bright black (8).
  static const brightBlack = 8;

  /// Bright red (9).
  static const brightRed = 9;

  /// Bright green (10).
  static const brightGreen = 10;

  /// Bright yellow (11).
  static const brightYellow = 11;

  /// Bright blue (12).
  static const brightBlue = 12;

  /// Bright magenta (13).
  static const brightMagenta = 13;

  /// Bright cyan (14).
  static const brightCyan = 14;

  /// Bright white (15).
  static const brightWhite = 15;
}
