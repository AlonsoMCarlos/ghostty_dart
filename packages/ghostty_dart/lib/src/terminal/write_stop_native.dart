/// Internal implementation of `VtTerminal.writeUntil`,
/// `VtTerminal.writeWithStops` and `VtTerminal.continuation`. Not exported.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../core/internal.dart';
import '../core/result.dart';
import '../ffi/bindings.g.dart';
import 'terminal_native.dart';
import 'write_stop.dart';

/// See `VtTerminal.writeUntil`: validates, then makes one
/// `ghostty_terminal_vt_write_until` call over `bytes[start..end)`.
WriteStop writeUntilInto(
  NativeHandle<GhosttyTerminalImpl> handle,
  Uint8List bytes,
  WriteBoundaries boundaries, {
  required int start,
  required int? end,
}) {
  checkNotInCallback(handle, 'writeUntil');
  _checkBoundaries(boundaries);
  final stopAt = RangeError.checkValidRange(start, end, bytes.length);
  return withNativeBytes(
    Uint8List.sublistView(bytes, start, stopAt),
    (data, length) => _withWriteStop(
      (stop) => _writeUntil(handle, data, length, boundaries, stop),
    ),
  );
}

/// See `VtTerminal.writeWithStops`: copies [bytes] to native memory once and
/// calls `ghostty_terminal_vt_write_until` until it is consumed, [onStop]
/// returns `false`, or [onStop] disposes the terminal.
int writeWithStopsInto(
  NativeHandle<GhosttyTerminalImpl> handle,
  Uint8List bytes,
  WriteBoundaries boundaries,
  bool Function(WriteStop stop, int offset) onStop,
) {
  checkNotInCallback(handle, 'writeWithStops');
  _checkBoundaries(boundaries);
  if (boundaries.containsAny(WriteBoundaries.ground)) {
    throw ArgumentError.value(
      boundaries,
      'boundaries',
      'ground is not supported by writeWithStops; use writeUntil',
    );
  }
  handle.checkNotDisposed();
  if (bytes.isEmpty) return 0;
  return withNativeBytes(
    bytes,
    (data, length) => _withWriteStop((stopStruct) {
      var offset = 0;
      while (offset < length) {
        checkNotInCallback(handle, 'writeWithStops');
        final stop = _writeUntil(
          handle,
          data + offset,
          length - offset,
          boundaries,
          stopStruct,
        );
        // A start or end stop always consumes its own byte; the guard only
        // protects against a library that reports otherwise.
        offset += stop.consumed == 0 ? length - offset : stop.consumed;
        if (!stop.reachedBoundary) break;
        if (!onStop(stop, offset) || handle.isDisposed) return offset;
      }
      return offset;
    }),
  );
}

/// See `VtTerminal.continuation`: `ghostty_terminal_continuation_alloc`,
/// with `GHOSTTY_INVALID_VALUE` (tracking off or unavailable) as `null`.
Uint8List? readContinuation(NativeHandle<GhosttyTerminalImpl> handle) {
  checkNotInCallback(handle, 'continuation');
  const operation = 'ghostty_terminal_continuation_alloc';
  return using((arena) {
    final outPtr = arena<Pointer<Uint8>>();
    final outLength = arena<Size>();
    final code = checkResultAllowing(
      ghostty_terminal_continuation_alloc(
        handle.pointer,
        nullptr,
        outPtr,
        outLength,
      ),
      operation,
      {GhosttyResultCode.invalidValue},
    );
    if (code == GhosttyResultCode.invalidValue) return null;
    return takeLibraryBytes(outPtr.value, outLength.value);
  });
}

void _checkBoundaries(WriteBoundaries boundaries) {
  if (boundaries.isEmpty || !WriteBoundaries.all.containsAll(boundaries)) {
    throw ArgumentError.value(
      boundaries,
      'boundaries',
      'must be non-empty and contain only known boundaries',
    );
  }
}

/// Runs [action] with a `GhosttyTerminalWriteStop` initialised once with its
/// size; the library resets the other fields on every call.
R _withWriteStop<R>(
  R Function(Pointer<GhosttyTerminalWriteStop> stop) action,
) => withScratch(sizeOf<GhosttyTerminalWriteStop>(), (memory) {
  final stop = memory.cast<GhosttyTerminalWriteStop>()
    ..initSized(sizeOf<GhosttyTerminalWriteStop>());
  return action(stop);
});

/// One `ghostty_terminal_vt_write_until` call over [length] bytes at [data],
/// inside [NativeHandle.use] and followed by an epoch bump.
/// `GHOSTTY_NO_VALUE` (no boundary reached) is a normal result.
WriteStop _writeUntil(
  NativeHandle<GhosttyTerminalImpl> handle,
  Pointer<Uint8> data,
  int length,
  WriteBoundaries boundaries,
  Pointer<GhosttyTerminalWriteStop> stop,
) {
  final raw = handle.use(
    (terminal) => ghostty_terminal_vt_write_until(
      terminal,
      data,
      length,
      writeBoundariesToRaw(boundaries),
      stop,
    ),
  );
  handle.bumpEpoch();
  checkResultAllowing(raw, 'ghostty_terminal_vt_write_until', {
    GhosttyResultCode.noValue,
  });
  final s = stop.ref;
  return writeStopFromRaw(
    consumed: s.consumed,
    reached: s.reached,
    kind: s.kind,
    introducer: s.introducer,
    end: s.end,
    byte: s.byte,
  );
}
