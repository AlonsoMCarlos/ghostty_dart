// Ported from package:xterm 4.0.0 (lib/src/core/buffer/cell_flags.dart).
// Copyright (c) 2020 xuty. MIT License, see LICENSE.xterm.

/// Cell attribute bits; the same values as `CellAttr`, without
/// strikethrough. Unused by xterm 4.0.0 itself, kept for its API.
abstract class CellFlags {
  /// Bold.
  static const bold = 1 << 0;

  /// Faint (dim).
  static const faint = 1 << 1;

  /// Italic.
  static const italic = 1 << 2;

  /// Underline.
  static const underline = 1 << 3;

  /// Blink.
  static const blink = 1 << 4;

  /// Inverse video.
  static const inverse = 1 << 5;

  /// Invisible (concealed).
  static const invisible = 1 << 6;
}
