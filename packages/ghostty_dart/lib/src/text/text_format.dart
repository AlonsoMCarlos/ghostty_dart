/// The output formats and VT extras of `formatter.h`.
///
/// Pure Dart: no `dart:ffi`, so a future web backend can reuse it.
library;

import '../core/enum_codec.dart';

/// What a `TerminalFormatter` produces (`GhosttyFormatterFormat`).
enum TextFormat {
  /// Plain text, without escape sequences: what a copy to the clipboard
  /// gives.
  plain(0),

  /// VT escape sequences that recreate the content, with its colours,
  /// styles and hyperlinks, when written to another terminal. See
  /// [FormatterExtras] for restoring more terminal state.
  vt(1),

  /// HTML with inline styles; text is escaped (`<`, `>`, `&`, ...).
  html(2),

  /// A format added by a later libghostty-vt release.
  unknown(null);

  const TextFormat(this._raw);
  final int? _raw;
}

/// Converts raw `GhosttyFormatterFormat` values to [TextFormat] and back.
final textFormatCodec = RawEnumCodec<TextFormat>(
  TextFormat.values,
  raw: (v) => v._raw,
  unknown: TextFormat.unknown,
);

/// Terminal state that [TextFormat.vt] output also restores, besides the
/// text and its styles (`GhosttyFormatterExtras`).
///
/// Immutable; combine with `|`, remove with [without]:
///
/// ```dart
/// formatter.extras = FormatterExtras.defaults | FormatterExtras.cursor;
/// ```
///
/// Plain text and HTML ignore extras. Bits unknown to this package are
/// kept; the library rejects bits it does not know when they are set.
final class FormatterExtras {
  /// The extras of the raw bitmask [value] (`uint32_t`, higher bits
  /// dropped).
  const FormatterExtras.fromValue(int value) : value = value & 0xFFFFFFFF;

  /// No extras: only the text and its styles.
  static const none = FormatterExtras.fromValue(0);

  /// The colour palette (OSC 4).
  static const palette = FormatterExtras.fromValue(1 << 0);

  /// Terminal modes that differ from their defaults (`CSI h` / `CSI l`).
  static const modes = FormatterExtras.fromValue(1 << 1);

  /// The scrolling region (DECSTBM, DECSLRM).
  static const scrollingRegion = FormatterExtras.fromValue(1 << 2);

  /// Tab stops.
  static const tabstops = FormatterExtras.fromValue(1 << 3);

  /// The working directory (OSC 7).
  static const pwd = FormatterExtras.fromValue(1 << 4);

  /// Keyboard modes such as modifyOtherKeys.
  static const keyboard = FormatterExtras.fromValue(1 << 5);

  /// The cursor position (CUP).
  static const cursor = FormatterExtras.fromValue(1 << 6);

  /// The style the cursor writes new text with (SGR).
  static const style = FormatterExtras.fromValue(1 << 7);

  /// The hyperlink the cursor writes new text with (OSC 8).
  static const hyperlink = FormatterExtras.fromValue(1 << 8);

  /// Character protection (DECSCA).
  static const protection = FormatterExtras.fromValue(1 << 9);

  /// The Kitty keyboard protocol flags.
  static const kittyKeyboard = FormatterExtras.fromValue(1 << 10);

  /// The character sets, such as the line-drawing set.
  static const charsets = FormatterExtras.fromValue(1 << 11);

  /// What a new formatter uses: the extras that change how output looks
  /// ([palette], [style] and [hyperlink]).
  static const defaults = FormatterExtras.fromValue(
    (1 << 0) | (1 << 7) | (1 << 8),
  );

  /// Every extra: recreates the terminal as closely as possible.
  static const all = FormatterExtras.fromValue(0xFFF);

  /// The raw bitmask (`GhosttyFormatterExtras`).
  final int value;

  /// Whether no extra is set.
  bool get isEmpty => value == 0;

  /// Whether every extra set in [other] is also set here.
  bool containsAll(FormatterExtras other) => value & other.value == other.value;

  /// Both sets together.
  FormatterExtras operator |(FormatterExtras other) =>
      FormatterExtras.fromValue(value | other.value);

  /// The extras set in both.
  FormatterExtras operator &(FormatterExtras other) =>
      FormatterExtras.fromValue(value & other.value);

  /// These extras without the ones in [other].
  FormatterExtras without(FormatterExtras other) =>
      FormatterExtras.fromValue(value & ~other.value);

  @override
  bool operator ==(Object other) =>
      other is FormatterExtras && other.value == value;

  @override
  int get hashCode => Object.hash(FormatterExtras, value);

  @override
  String toString() {
    const names = [
      'palette',
      'modes',
      'scrollingRegion',
      'tabstops',
      'pwd',
      'keyboard',
      'cursor',
      'style',
      'hyperlink',
      'protection',
      'kittyKeyboard',
      'charsets',
    ];
    final set = [
      for (var bit = 0; bit < names.length; bit++)
        if (value & (1 << bit) != 0) names[bit],
    ];
    return 'FormatterExtras(${set.join(' | ')})';
  }
}
