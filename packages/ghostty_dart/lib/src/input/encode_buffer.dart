/// The reusable output buffer of the stateful encoders. Internal: not
/// exported by the input barrel.
library;

import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import '../core/core.dart';
import '../core/internal.dart';

/// A native output buffer plus its `out_written` slot, owned by one encoder
/// and reused for every event, so encoding a key or mouse event does not
/// allocate native memory.
///
/// Both blocks have their own finalizer; [dispose] frees them at once.
final class EncodeBuffer {
  /// Creates a buffer of [initialCapacity] bytes. Most sequences are short,
  /// so the default fits all but unusual Kitty reports in one call.
  EncodeBuffer([int initialCapacity = 64])
    : _data = GrowableNativeBuffer(initialCapacity),
      _written = GrowableNativeBuffer(sizeOf<Size>());

  final GrowableNativeBuffer _data;
  final GrowableNativeBuffer _written;

  /// The most attempts [encode] makes. The required size is exact, so one
  /// retry is the normal worst case.
  static const _maxAttempts = 4;

  /// Runs an `encode(buf, buf_len, out_written)`-style [call] and returns a
  /// copy of the bytes written (empty when the event produces no output).
  ///
  /// On `GHOSTTY_OUT_OF_SPACE` the buffer grows to the reported size and the
  /// call is retried; partial output is discarded. Other errors throw via
  /// the core result helpers, with [operation] as the C function name.
  Uint8List encode(
    String operation,
    int Function(Pointer<Uint8> buffer, int capacity, Pointer<Size> written)
    call,
  ) {
    for (var attempt = 0; attempt < _maxAttempts; attempt++) {
      final written = _written.pointer.cast<Size>()..value = 0;
      final data = _data.pointer;
      final code = checkResultAllowing(
        call(data, _data.capacity, written),
        operation,
        const {GhosttyResultCode.outOfSpace},
      );
      if (code == GhosttyResultCode.success) {
        return copyBytes(data, written.value);
      }
      _data.ensureCapacity(math.max(written.value, _data.capacity + 1));
    }
    throw GhosttyException(
      operation,
      resultCodec.encode(GhosttyResultCode.outOfSpace),
    );
  }

  /// Frees both native blocks. Safe to call more than once.
  void dispose() {
    _data.dispose();
    _written.dispose();
  }
}
