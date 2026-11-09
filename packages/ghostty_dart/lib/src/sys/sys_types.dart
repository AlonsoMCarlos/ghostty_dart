/// Pure Dart types of the process-wide system interface (`sys.h`).
library;

import 'dart:typed_data';

import '../core/enum_codec.dart';

/// The severity of a libghostty-vt log message (`GhosttySysLogLevel`).
///
/// Which levels reach a [VtLogHandler] depends on how the library was built:
/// debug builds emit every level, release builds emit [info] and above
/// ([debug] messages are compiled out). Check
/// `libghosttyVtBuildInfo.optimizeMode` to know which one is loaded.
enum VtLogLevel {
  /// Something failed.
  error(0),

  /// Something unexpected that the library recovered from, such as
  /// malformed input from a program.
  warning(1),

  /// Informational messages.
  info(2),

  /// Detailed diagnostics; only emitted by debug builds.
  debug(3),

  /// A level added by a later libghostty-vt release.
  unknown(null);

  const VtLogLevel(this._raw);

  final int? _raw;
}

/// Converts raw `GhosttySysLogLevel` values to [VtLogLevel] and back.
final vtLogLevelCodec = RawEnumCodec<VtLogLevel>(
  VtLogLevel.values,
  raw: (level) => level._raw,
  unknown: VtLogLevel.unknown,
);

/// Receives one libghostty-vt log message.
///
/// [scope] names the library subsystem (for example `osc` or `kitty`), or is
/// `''` for unscoped messages. Both strings are Dart copies; malformed UTF-8
/// is replaced with U+FFFD. Install one with `setVtLogHandler`.
typedef VtLogHandler =
    void Function(VtLogLevel level, String scope, String message);

/// A decoded image in 8-bit RGBA: four bytes per pixel, row by row from the
/// top-left corner, with no padding between rows (`GhosttySysImage`).
///
/// A [VtPngDecoder] returns one. The constructor checks that [pixels] holds
/// exactly `width * height * 4` bytes.
final class RgbaImage {
  /// Creates an image of [width] × [height] pixels from [pixels].
  ///
  /// Throws [RangeError] unless both sizes are 1–0xFFFFFFFF, and
  /// [ArgumentError] unless `pixels.length == width * height * 4`. The list
  /// is not copied; do not change it afterwards.
  RgbaImage({required this.width, required this.height, required this.pixels}) {
    RangeError.checkValueInInterval(width, 1, _maxDimension, 'width');
    RangeError.checkValueInInterval(height, 1, _maxDimension, 'height');
    // Divide instead of multiplying: width * height * 4 overflows 64 bits
    // for dimensions near the uint32 limit and could wrap to a small value
    // that matches a short buffer.
    final length = pixels.length;
    if (length % (width * bytesPerPixel) != 0 ||
        length ~/ (width * bytesPerPixel) != height) {
      throw ArgumentError.value(
        pixels.length,
        'pixels.length',
        'must be width * height * $bytesPerPixel '
            '($width * $height * $bytesPerPixel)',
      );
    }
  }

  /// The number of bytes of one pixel: red, green, blue and alpha.
  static const bytesPerPixel = 4;

  /// The largest width or height (`uint32_t`).
  static const _maxDimension = 0xFFFFFFFF;

  /// The width in pixels.
  final int width;

  /// The height in pixels.
  final int height;

  /// The RGBA pixel bytes, `width * height * 4` of them.
  final Uint8List pixels;

  @override
  String toString() => 'RgbaImage(${width}x$height)';
}

/// Decodes the PNG file in [png] into an [RgbaImage], or returns `null` when
/// it cannot be decoded (the image is then rejected).
///
/// [png] is a Dart copy of untrusted data sent by a program: a decoder must
/// cope with malformed and very large input. Install one with
/// `setVtPngDecoder`.
typedef VtPngDecoder = RgbaImage? Function(Uint8List png);

/// Fills all of [buffer] with cryptographically secure random bytes and
/// returns `true`, or returns `false` when no entropy is available.
///
/// [buffer] is a view of library memory that is valid only during the call;
/// do not keep it. Install one with `setVtSecureRandomSource`.
typedef VtSecureRandomSource = bool Function(Uint8List buffer);
