/// The Kitty keyboard protocol flags (`GhosttyKittyKeyFlags`).
library;

/// The progressive-enhancement flags of the
/// [Kitty keyboard protocol](https://sw.kovidgoyal.net/kitty/keyboard-protocol/)
/// (`GhosttyKittyKeyFlags`).
///
/// Programs push and pop them with `CSI > flags u` / `CSI < u`; read the
/// current set with `VtTerminal.kittyKeyboardFlags`. Immutable. Combine with
/// `|`:
///
/// ```dart
/// final flags = KittyKeyboardFlags.disambiguate |
///     KittyKeyboardFlags.reportEvents;
/// ```
///
/// The integer [value] is the one defined by the protocol, so it can be
/// stored or sent as is. Unknown bits from a newer library are kept.
final class KittyKeyboardFlags {
  /// A set of flags from its protocol [value] (0–255, higher bits dropped).
  const KittyKeyboardFlags.fromValue(int value) : value = value & 0xFF;

  /// The protocol is off: legacy key encoding.
  static const disabled = KittyKeyboardFlags.fromValue(0);

  /// Flag 1: disambiguate escape codes.
  static const disambiguate = KittyKeyboardFlags.fromValue(1 << 0);

  /// Flag 2: report key repeat and release events.
  static const reportEvents = KittyKeyboardFlags.fromValue(1 << 1);

  /// Flag 4: report alternate (shifted and base layout) keys.
  static const reportAlternates = KittyKeyboardFlags.fromValue(1 << 2);

  /// Flag 8: report every key as an escape code, including text keys.
  static const reportAll = KittyKeyboardFlags.fromValue(1 << 3);

  /// Flag 16: report the text associated with a key.
  static const reportAssociated = KittyKeyboardFlags.fromValue(1 << 4);

  /// Every flag defined by the protocol.
  static const all = KittyKeyboardFlags.fromValue(0x1F);

  /// The flags as the protocol integer (`GhosttyKittyKeyFlags`).
  final int value;

  /// Whether no flag is set, i.e. the protocol is off.
  bool get isEmpty => value == 0;

  /// Whether every flag set in [other] is also set here.
  bool containsAll(KittyKeyboardFlags other) =>
      value & other.value == other.value;

  /// The union of both sets.
  KittyKeyboardFlags operator |(KittyKeyboardFlags other) =>
      KittyKeyboardFlags.fromValue(value | other.value);

  /// The flags set in both.
  KittyKeyboardFlags operator &(KittyKeyboardFlags other) =>
      KittyKeyboardFlags.fromValue(value & other.value);

  @override
  bool operator ==(Object other) =>
      other is KittyKeyboardFlags && other.value == value;

  @override
  int get hashCode => Object.hash(KittyKeyboardFlags, value);

  @override
  String toString() {
    final names = <String>[
      if (containsAll(disambiguate)) 'disambiguate',
      if (containsAll(reportEvents)) 'reportEvents',
      if (containsAll(reportAlternates)) 'reportAlternates',
      if (containsAll(reportAll)) 'reportAll',
      if (containsAll(reportAssociated)) 'reportAssociated',
      if (value & ~all.value != 0)
        '0x${(value & ~all.value).toRadixString(16)}',
    ];
    return 'KittyKeyboardFlags(${names.join(' | ')})';
  }
}
