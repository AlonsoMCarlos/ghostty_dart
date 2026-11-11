// Ported from package:xterm 4.0.0 (lib/src/core/cell.dart, with the
// four-argument case of lib/src/utils/hash_values.dart).
// Copyright (c) 2020 xuty. MIT License, see LICENSE.xterm.

/// One cell in xterm's packed format: colours as [CellColor] values,
/// [flags] as [CellAttr] bits, and [content] as the code point plus the
/// width shifted by [CellContent.widthShift].
class CellData {
  /// Creates a cell from its packed values.
  CellData({
    required this.foreground,
    required this.background,
    required this.flags,
    required this.content,
  });

  /// An empty cell: default colours, no attributes, no content.
  factory CellData.empty() {
    return CellData(foreground: 0, background: 0, flags: 0, content: 0);
  }

  /// The foreground colour, a [CellColor] value.
  int foreground;

  /// The background colour, a [CellColor] value.
  int background;

  /// The [CellAttr] bits.
  int flags;

  /// The code point, with the cell width at [CellContent.widthShift].
  int content;

  /// A hash of the four values, the same one xterm computes.
  int getHash() {
    var hash = 0;
    hash = _combine(hash, foreground);
    hash = _combine(hash, background);
    hash = _combine(hash, flags);
    hash = _combine(hash, content);
    return _finish(hash);
  }

  // Jenkins one-at-a-time hashing, as xterm's (and Flutter's former)
  // `hashValues`.
  static int _combine(int hash, int value) {
    hash = 0x1fffffff & (hash + value.hashCode);
    hash = 0x1fffffff & (hash + ((0x0007ffff & hash) << 10));
    return hash ^ (hash >> 6);
  }

  static int _finish(int hash) {
    hash = 0x1fffffff & (hash + ((0x03ffffff & hash) << 3));
    hash = hash ^ (hash >> 11);
    return 0x1fffffff & (hash + ((0x00003fff & hash) << 15));
  }

  @override
  String toString() {
    return 'CellData{foreground: $foreground, background: $background, '
        'flags: $flags, content: $content}';
  }
}

/// The attribute bits of [CellData.flags] and of `CursorStyle.attrs`.
abstract class CellAttr {
  /// Bold.
  static const bold = 1 << 0;

  /// Faint.
  static const faint = 1 << 1;

  /// Italic.
  static const italic = 1 << 2;

  /// Underlined.
  static const underline = 1 << 3;

  /// Blinking.
  static const blink = 1 << 4;

  /// Inverse video.
  static const inverse = 1 << 5;

  /// Invisible.
  static const invisible = 1 << 6;

  /// Struck through.
  static const strikethrough = 1 << 7;
}

/// The packing of a colour value: the colour in the low 24 bits
/// ([valueMask]) and its kind at [typeShift].
abstract class CellColor {
  /// The bits that hold the colour: a named or palette index, or 0xRRGGBB.
  static const valueMask = 0xFFFFFF;

  /// Where the kind of colour starts.
  static const typeShift = 25;

  /// The bits that hold the kind of colour.
  static const typeMask = 3 << typeShift;

  /// The default colour.
  static const normal = 0 << typeShift;

  /// One of the 16 named colours (`NamedColor`).
  static const named = 1 << typeShift;

  /// An index into the 256-colour palette.
  static const palette = 2 << typeShift;

  /// A 24-bit RGB colour.
  static const rgb = 3 << typeShift;
}

/// The packing of [CellData.content].
abstract class CellContent {
  /// The bits that hold the code point.
  static const codepointMask = 0x1fffff;

  /// Where the cell width starts.
  static const widthShift = 22;
}
