/// Mapping between libghostty-vt's raw C enum integers and public Dart enums.
///
/// libghostty-vt minor releases may add enum values (ABI policy), so every
/// public enum decoded from native code has an `unknown` member. A raw value
/// this version of the package does not know decodes to `unknown` instead of
/// throwing.
library;

/// Converts between raw C enum integers and a Dart enum [E] that has an
/// `unknown` member.
///
/// Create one codec per enum, next to the enum, from a function that reads
/// each member's raw value (`null` for `unknown`):
///
/// ```dart
/// enum VtCursorStyle {
///   bar(0),
///   block(1),
///   unknown(null);
///
///   const VtCursorStyle(this._raw);
///   final int? _raw;
/// }
///
/// final vtCursorStyleCodec = RawEnumCodec<VtCursorStyle>(
///   VtCursorStyle.values,
///   raw: (style) => style._raw,
///   unknown: VtCursorStyle.unknown,
/// );
/// ```
///
/// [decode] never throws. [encode] throws [ArgumentError] for members that
/// have no raw value (such as `unknown`), because they cannot be sent to the
/// library.
final class RawEnumCodec<E extends Enum> {
  /// Builds the lookup tables for [values].
  ///
  /// [raw] returns the C value of a member, or `null` for members (like
  /// [unknown]) that have none. Two members must not share a raw value.
  RawEnumCodec(
    Iterable<E> values, {
    required int? Function(E value) raw,
    required E unknown,
  }) : _unknown = unknown {
    for (final value in values) {
      final rawValue = raw(value);
      if (rawValue == null) continue;
      if (_fromRaw.containsKey(rawValue)) {
        throw ArgumentError('Duplicate raw value $rawValue for $value');
      }
      _fromRaw[rawValue] = value;
      _toRaw[value] = rawValue;
    }
    final dense = _fromRaw.keys.every((k) => k >= 0 && k < _denseLimit);
    if (dense) {
      final length = _fromRaw.keys.fold(0, (a, b) => b >= a ? b + 1 : a);
      _dense = List<E>.filled(length, unknown);
      _fromRaw.forEach((k, v) => _dense![k] = v);
    }
  }

  /// Raw values below this bound are looked up in a list instead of a map.
  static const _denseLimit = 256;

  final E _unknown;
  final Map<int, E> _fromRaw = {};
  final Map<E, int> _toRaw = {};
  List<E>? _dense;

  /// Returns the member for [raw], or the `unknown` member if this package
  /// does not know the value. Never throws.
  E decode(int raw) {
    final dense = _dense;
    if (dense != null) {
      return raw >= 0 && raw < dense.length ? dense[raw] : _unknown;
    }
    return _fromRaw[raw] ?? _unknown;
  }

  /// Returns the raw C value of [value].
  ///
  /// Throws [ArgumentError] if [value] has no raw value (e.g. `unknown`).
  int encode(E value) {
    final raw = _toRaw[value];
    if (raw == null) {
      throw ArgumentError.value(
        value,
        'value',
        'has no native value and cannot be passed to libghostty-vt',
      );
    }
    return raw;
  }
}
