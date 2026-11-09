/// Result codes returned by libghostty-vt and their mapping to Dart errors.
///
/// This is the single place where native results become exceptions. Every
/// module calls [checkResult] (or one of its variants) instead of comparing
/// codes by hand.
library;

import 'enum_codec.dart';

/// A result code of a libghostty-vt operation (`GhosttyResult` in `types.h`).
///
/// [success] is zero and every error is negative. Codes added by a later
/// libghostty-vt 1.x release decode to [unknown]; the raw integer stays
/// available in [GhosttyException.rawCode].
enum GhosttyResultCode {
  /// The operation completed successfully.
  success(0),

  /// An allocation failed.
  outOfMemory(-1),

  /// An argument is not valid, e.g. an out-of-range value or a sized struct
  /// that is too small.
  invalidValue(-2),

  /// The provided buffer was too small. This package retries with the size
  /// the library reports, so it only surfaces if the size keeps changing.
  outOfSpace(-3),

  /// The requested value is not set (e.g. no title has been set). Optional
  /// values are returned as `null` instead of throwing this.
  noValue(-4),

  /// Reading from or writing to external I/O failed.
  ioError(-5),

  /// Encoded input exceeded a configured limit.
  limitExceeded(-6),

  /// A safety check rejected the operation (e.g. unsafe pasted text).
  /// Nothing was done; retry with the operation's allow flag set.
  rejected(-7),

  /// This library build cannot do what was asked: the key is newer than the
  /// library, or the optional feature is compiled out. Never carried by a
  /// [GhosttyException]: this package throws [UnsupportedError] instead.
  unsupported(-8),

  /// A code this version of the package does not know.
  unknown(null);

  const GhosttyResultCode(this._raw);

  final int? _raw;

  /// Whether this code is anything other than [success].
  bool get isError => this != success;
}

/// Converts raw `GhosttyResult` integers to [GhosttyResultCode] and back.
final resultCodec = RawEnumCodec<GhosttyResultCode>(
  GhosttyResultCode.values,
  raw: (code) => code._raw,
  unknown: GhosttyResultCode.unknown,
);

/// A libghostty-vt operation failed with an error code.
///
/// [GhosttyResultCode.unsupported] is never reported with this class: it is
/// thrown as [UnsupportedError] instead.
final class GhosttyException implements Exception {
  /// Creates an exception for [operation] failing with [rawCode].
  GhosttyException(this.operation, this.rawCode)
    : code = resultCodec.decode(rawCode);

  /// The operation that failed, usually the C function name
  /// (e.g. `ghostty_terminal_resize`).
  final String operation;

  /// The decoded result code. [GhosttyResultCode.unknown] if the library
  /// returned a code this package does not know; see [rawCode].
  final GhosttyResultCode code;

  /// The raw integer the library returned.
  final int rawCode;

  @override
  String toString() =>
      'GhosttyException: $operation failed with ${code.name} ($rawCode)';
}

/// Decodes [raw] without throwing.
///
/// Non-negative values are successes: the library defines success as zero and
/// every error as negative, so an unknown non-negative code is not an error.
GhosttyResultCode decodeResult(int raw) =>
    raw >= 0 ? GhosttyResultCode.success : resultCodec.decode(raw);

/// Returns the error to throw for the negative result [raw] of [operation]:
/// an [UnsupportedError] for `GHOSTTY_UNSUPPORTED`, a [GhosttyException]
/// otherwise.
Object resultError(int raw, String operation) {
  if (raw == GhosttyResultCode.unsupported._raw) {
    return UnsupportedError(
      '$operation is not supported by this libghostty-vt library '
      '(the value is newer than the library, or the feature is compiled out)',
    );
  }
  return GhosttyException(operation, raw);
}

/// Throws unless [raw] is a success.
///
/// `GHOSTTY_UNSUPPORTED` throws [UnsupportedError]; every other negative code
/// throws [GhosttyException].
void checkResult(int raw, String operation) {
  if (raw < 0) throw resultError(raw, operation);
}

/// Like [checkResult], but returns `false` instead of throwing for
/// `GHOSTTY_NO_VALUE`. Returns `true` on success.
bool checkResultHasValue(int raw, String operation) {
  if (raw >= 0) return true;
  if (raw == GhosttyResultCode.noValue._raw) return false;
  throw resultError(raw, operation);
}

/// Like [checkResult], but returns the code instead of throwing when it is in
/// [allowed]. Returns [GhosttyResultCode.success] on success.
GhosttyResultCode checkResultAllowing(
  int raw,
  String operation,
  Set<GhosttyResultCode> allowed,
) {
  final code = decodeResult(raw);
  if (code == GhosttyResultCode.success || allowed.contains(code)) return code;
  throw resultError(raw, operation);
}
