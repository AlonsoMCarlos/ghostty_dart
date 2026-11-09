/// Moving bytes and strings between Dart and native memory, following the
/// libghostty-vt buffer conventions (`types.h`, `allocator.h`).
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../ffi/bindings.g.dart';
import 'result.dart';

/// A reusable malloc'd block for short-lived native copies.
///
/// The pool is isolate-global. A nested request (e.g. a callback during
/// `vt_write` that writes to another terminal) finds it busy and gets a
/// fresh temporary allocation instead, so nested users never share memory.
final class _ScratchPool {
  _ScratchPool(this._minCapacity);

  /// Blocks larger than this are never retained between calls.
  static const _maxRetained = 1 << 20;

  final int _minCapacity;
  Pointer<Uint8> _block = nullptr;
  int _capacity = 0;
  bool _busy = false;

  R run<R>(int length, R Function(Pointer<Uint8> memory) action) {
    if (_busy || length > _maxRetained) {
      final temp = malloc<Uint8>(math.max(length, 1));
      try {
        return action(temp);
      } finally {
        malloc.free(temp);
      }
    }
    // Also allocate on first use, so a zero-length request still gets a
    // valid (non-NULL) pointer.
    if (length > _capacity || _block == nullptr) {
      if (_block != nullptr) malloc.free(_block);
      _capacity = math.min(
        _maxRetained,
        math.max(length, math.max(_minCapacity, _capacity * 2)),
      );
      _block = malloc<Uint8>(_capacity);
    }
    _busy = true;
    try {
      return action(_block);
    } finally {
      _busy = false;
    }
  }
}

final _bytesPool = _ScratchPool(4096);
final _scratchPool = _ScratchPool(256);

/// Copies [bytes] into native memory and runs [action] with it.
///
/// The memory is only valid during [action], which must be synchronous. A
/// pooled block is reused across calls, so hot paths such as `vt_write` do
/// not allocate. An empty [bytes] still gets a valid (non-NULL) pointer.
R withNativeBytes<R>(
  Uint8List bytes,
  R Function(Pointer<Uint8> data, int length) action,
) {
  final length = bytes.length;
  return _bytesPool.run(length, (memory) {
    memory.asTypedList(length).setAll(0, bytes);
    return action(memory, length);
  });
}

/// Encodes [text] as UTF-8 into native memory and runs [action] with it.
///
/// Same lifetime rules as [withNativeBytes]. The bytes are not
/// NUL-terminated; pass the length.
R withUtf8<R>(
  String text,
  R Function(Pointer<Uint8> data, int length) action,
) => withNativeBytes(utf8.encode(text), action);

/// Runs [action] with at least [size] bytes of zeroed native scratch memory,
/// for out-parameters and small structs.
///
/// The memory is only valid during [action], which must be synchronous. Cast
/// it to the type you need: `withScratch(sizeOf<Uint16>(), (p) => ...)`.
R withScratch<R>(int size, R Function(Pointer<Uint8> memory) action) =>
    _scratchPool.run(size, (memory) {
      memory.asTypedList(size).fillRange(0, size, 0);
      return action(memory);
    });

/// Copies [length] bytes at [data] into a new Dart [Uint8List].
///
/// Returns an empty list for a zero [length], even if [data] is NULL.
Uint8List copyBytes(Pointer<Uint8> data, int length) =>
    length == 0 ? Uint8List(0) : Uint8List.fromList(data.asTypedList(length));

/// Decodes [length] bytes of UTF-8 at [data] into a [String] (copying).
///
/// Malformed sequences become U+FFFD, because terminal content is
/// untrusted input.
String decodeUtf8(Pointer<Uint8> data, int length) => length == 0
    ? ''
    : utf8.decode(data.asTypedList(length), allowMalformed: true);

/// Decodes a borrowed `GhosttyString` (copying it).
String readGhosttyString(GhosttyString string) =>
    decodeUtf8(string.ptr, string.len);

/// Copies a buffer that the library allocated with its default allocator and
/// frees it with `ghostty_free`.
///
/// Use for the outputs of `*_alloc` functions.
Uint8List takeLibraryBytes(Pointer<Uint8> data, int length) {
  try {
    return copyBytes(data, length);
  } finally {
    ghostty_free(nullptr, data, length);
  }
}

/// Calls a `*_alloc`-style function and returns its output as Dart bytes.
///
/// [call] receives the `out_ptr` and `out_len` out-parameters (pass `nullptr`
/// as the allocator to the C function). Its result is checked with
/// [checkResult]; the native buffer is always freed with `ghostty_free`.
///
/// ```dart
/// final bytes = callAllocating('ghostty_formatter_format_alloc',
///     (out, len) => ghostty_formatter_format_alloc(f, nullptr, out, len));
/// ```
Uint8List callAllocating(
  String operation,
  int Function(Pointer<Pointer<Uint8>> outPtr, Pointer<Size> outLength) call,
) => using((arena) {
  final outPtr = arena<Pointer<Uint8>>();
  final outLength = arena<Size>();
  checkResult(call(outPtr, outLength), operation);
  return takeLibraryBytes(outPtr.value, outLength.value);
});

/// The most retries the size-query helpers make before giving up. The size
/// only changes between attempts if the source changes, so one retry is
/// normal.
const _maxSizeRetries = 4;

/// Calls a function that writes into a caller buffer `(buf, buf_len,
/// out_written)` and returns `GHOSTTY_OUT_OF_SPACE` with the required size in
/// `out_written` when the buffer is too small.
///
/// Tries a buffer of [initialCapacity] bytes first, then retries with the
/// reported size. Returns `null` for `GHOSTTY_NO_VALUE`; other errors throw
/// via [checkResult]. Partial output from a failed attempt is discarded.
Uint8List? tryCallWithSizeQuery(
  String operation,
  int Function(Pointer<Uint8> buffer, int capacity, Pointer<Size> outLength)
  call, {
  int initialCapacity = 128,
}) => using((arena) {
  final outLength = arena<Size>();
  return _retryWhileOutOfSpace<Uint8List>(
    operation,
    initialCapacity,
    (capacity) => _bytesPool.run(capacity, (buffer) {
      outLength.value = 0;
      final raw = call(buffer, capacity, outLength);
      return raw >= 0 ? copyBytes(buffer, outLength.value) : raw;
    }),
    requiredCapacity: () => outLength.value,
  );
});

/// Like [tryCallWithSizeQuery], but `GHOSTTY_NO_VALUE` throws a
/// [GhosttyException] instead of returning `null`.
Uint8List callWithSizeQuery(
  String operation,
  int Function(Pointer<Uint8> buffer, int capacity, Pointer<Size> outLength)
  call, {
  int initialCapacity = 128,
}) =>
    tryCallWithSizeQuery(operation, call, initialCapacity: initialCapacity) ??
    (throw GhosttyException(operation, _noValue));

/// Calls a function that fills a `GhosttyBuffer` (`ptr`, `cap`, `len`) and
/// returns `GHOSTTY_OUT_OF_SPACE` with the required size in `len` when `cap`
/// is too small.
///
/// Same retry and `GHOSTTY_NO_VALUE` rules as [tryCallWithSizeQuery].
Uint8List? tryCallWithBuffer(
  String operation,
  int Function(Pointer<GhosttyBuffer> buffer) call, {
  int initialCapacity = 128,
}) => using((arena) {
  final descriptor = arena<GhosttyBuffer>();
  return tryCallWithSizeQuery(operation, (buffer, capacity, outLength) {
    descriptor.ref
      ..ptr = buffer
      ..cap = capacity
      ..len = 0;
    final raw = call(descriptor);
    outLength.value = descriptor.ref.len;
    return raw;
  }, initialCapacity: initialCapacity);
});

/// Calls a function that fills a `GhosttyCodepointBuffer` and returns the
/// codepoints.
///
/// The library sets `len` to the total count even when it returns
/// `GHOSTTY_OUT_OF_SPACE`; this retries with that capacity. Returns `null`
/// for `GHOSTTY_NO_VALUE`; other errors throw via [checkResult].
Uint32List? tryCallWithCodepointBuffer(
  String operation,
  int Function(Pointer<GhosttyCodepointBuffer> buffer) call, {
  int initialCapacity = 16,
}) => using((arena) {
  final descriptor = arena<GhosttyCodepointBuffer>();
  return _retryWhileOutOfSpace<Uint32List>(
    operation,
    initialCapacity,
    (capacity) => _bytesPool.run(capacity * sizeOf<Uint32>(), (memory) {
      final codepoints = memory.cast<Uint32>();
      descriptor.ref
        ..ptr = codepoints
        ..cap = capacity
        ..len = 0;
      final raw = call(descriptor);
      if (raw < 0) return raw;
      final length = descriptor.ref.len;
      return length == 0
          ? Uint32List(0)
          : Uint32List.fromList(codepoints.asTypedList(length));
    }),
    requiredCapacity: () => descriptor.ref.len,
  );
});

/// The retry loop shared by the size-query helpers.
///
/// [attempt] runs the native call with a buffer of the given capacity and
/// returns the copied output ([T]) on success, or the raw negative result.
/// `GHOSTTY_NO_VALUE` returns `null`, `GHOSTTY_OUT_OF_SPACE` retries with
/// [requiredCapacity] (at least one more than before), and every other error
/// throws via [resultError].
T? _retryWhileOutOfSpace<T extends Object>(
  String operation,
  int initialCapacity,
  Object Function(int capacity) attempt, {
  required int Function() requiredCapacity,
}) {
  var capacity = initialCapacity;
  for (var retry = 0; retry <= _maxSizeRetries; retry++) {
    final result = attempt(capacity);
    if (result is T) return result;
    final raw = result as int;
    if (raw == _noValue) return null;
    if (raw != _outOfSpace) throw resultError(raw, operation);
    capacity = math.max(requiredCapacity(), capacity + 1);
  }
  throw GhosttyException(operation, _outOfSpace);
}

final _noValue = resultCodec.encode(GhosttyResultCode.noValue);
final _outOfSpace = resultCodec.encode(GhosttyResultCode.outOfSpace);

/// Initialises a sized struct (one whose first field is `size_t size`) with
/// `ghostty_sized_init`: zeroes [size] bytes and stores [size] in the `size`
/// field. Always pass `sizeOf<TheStruct>()`:
///
/// ```dart
/// final usage = arena<GhosttyTerminalMemoryUsage>()
///   ..initSized(sizeOf<GhosttyTerminalMemoryUsage>());
/// ```
///
/// Fixed-layout structs such as `GhosttyStyle` have no `size` field and must
/// not be passed here.
extension SizedStructInit<T extends Struct> on Pointer<T> {
  /// Zeroes the struct and sets its `size` field to [size]. See
  /// [SizedStructInit].
  void initSized(int size) => ghostty_sized_init(cast(), size);
}

/// A growable native buffer owned by one Dart object, for hot paths that call
/// the same buffer-filling function many times (e.g. per-cell graphemes).
///
/// Freed by [dispose], or by a finalizer if the owner forgets. Not shared:
/// create one per owner.
final class GrowableNativeBuffer implements Finalizable {
  /// Creates a buffer of [initialCapacity] bytes.
  GrowableNativeBuffer([int initialCapacity = 256])
    : _capacity = math.max(initialCapacity, 1) {
    _pointer = malloc<Uint8>(_capacity);
    _finalizer.attach(this, _pointer.cast(), detach: this);
  }

  static final _finalizer = NativeFinalizer(malloc.nativeFree);

  late Pointer<Uint8> _pointer;
  int _capacity;
  bool _disposed = false;

  /// The start of the buffer. Invalidated by [ensureCapacity] and [dispose].
  Pointer<Uint8> get pointer {
    if (_disposed) throw StateError('GrowableNativeBuffer has been disposed');
    return _pointer;
  }

  /// The current capacity in bytes.
  int get capacity => _capacity;

  /// Grows the buffer to at least [bytes] bytes (contents are not kept).
  void ensureCapacity(int bytes) {
    if (_disposed) throw StateError('GrowableNativeBuffer has been disposed');
    if (bytes <= _capacity) return;
    _finalizer.detach(this);
    malloc.free(_pointer);
    _capacity = math.max(bytes, _capacity * 2);
    _pointer = malloc<Uint8>(_capacity);
    _finalizer.attach(this, _pointer.cast(), detach: this);
  }

  /// Frees the buffer. Safe to call more than once.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _finalizer.detach(this);
    malloc.free(_pointer);
    _pointer = nullptr;
  }
}
