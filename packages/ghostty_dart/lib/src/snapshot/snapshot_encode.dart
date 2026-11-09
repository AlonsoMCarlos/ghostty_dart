/// The [VtTerminalSnapshot] extension: encode a terminal's complete state
/// as a snapshot (`ghostty_snapshot_encode*`).
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../core/internal.dart';
import '../ffi/bindings.g.dart';
import '../terminal/terminal.dart' show VtTerminal;
import '../terminal/terminal_native.dart' show checkNotInCallback;

/// Encodes the complete state of a [VtTerminal] (screens, scrollback,
/// cursor, modes, colours, Kitty images, unfinished parser state, ...) as a
/// snapshot, to save it and bring it back later.
///
/// ```dart
/// final terminal = VtTerminal(cols: 80, rows: 24)
///   ..continuationMaxBytes = 1 << 20;   // before writing, see below
/// terminal.write(ptyOutput);
/// final Uint8List snapshot = terminal.encodeSnapshot();
/// ```
///
/// **The snapshot format is not covered by libghostty-vt's ABI promise.** It
/// is versioned separately from the library, so a snapshot written by one
/// library version may be rejected by another. Use snapshots to hand a
/// terminal over within one run of a program, or between processes that
/// load the same libghostty-vt build; do not persist them across library
/// upgrades.
///
/// A terminal whose parser is in the middle of a sequence (the input
/// stopped partway through an escape sequence or a UTF-8 character) can
/// only be encoded if continuation tracking (`continuationMaxBytes`) was
/// turned on before that input was written; otherwise encoding throws
/// [GhosttyException] (`invalidValue`). Terminals at ground always encode.
///
/// Snapshots are an optional build feature: when the loaded library lacks
/// it (`libghosttyVtBuildInfo.supports(VtFeature.snapshot)` is `false`), the
/// members throw [UnsupportedError]. They throw [StateError] after
/// [VtTerminal.dispose] or when called from inside a callback of the
/// terminal.
extension VtTerminalSnapshot on VtTerminal {
  /// Encodes the terminal's complete state and returns the snapshot bytes.
  ///
  /// The whole snapshot is held in memory, twice briefly (the library's
  /// buffer and the Dart copy); for a terminal with a large scrollback,
  /// [encodeSnapshotTo] streams it instead.
  ///
  /// Throws [GhosttyException] if the terminal cannot be encoded (see
  /// [VtTerminalSnapshot]) or the library runs out of memory.
  Uint8List encodeSnapshot() {
    final handle = handleOf<GhosttyTerminalImpl>(this);
    checkNotInCallback(handle, 'encodeSnapshot');
    final terminal = handle.pointer;
    return callAllocating(
      'ghostty_snapshot_encode_alloc',
      (out, length) =>
          ghostty_snapshot_encode_alloc(terminal, nullptr, out, length),
    );
  }

  /// Encodes the terminal's complete state and passes the snapshot to
  /// [sink] in order, one chunk at a time, without holding it all in
  /// memory.
  ///
  /// [sink] runs synchronously during this call; each chunk is a Dart copy
  /// and may be kept. It must not call this terminal at all (the library
  /// forbids it; [VtTerminal.write] and the other guarded members throw
  /// [StateError]). If [sink] throws, encoding stops and the error is
  /// rethrown; what [sink] already received is then an incomplete snapshot
  /// and must be discarded.
  ///
  /// Throws [GhosttyException] if the terminal cannot be encoded (see
  /// [VtTerminalSnapshot]) or the library fails; the chunks received so far
  /// must then be discarded too.
  void encodeSnapshotTo(void Function(Uint8List chunk) sink) {
    final handle = handleOf<GhosttyTerminalImpl>(this);
    checkNotInCallback(handle, 'encodeSnapshotTo');
    handle.checkNotDisposed();
    Object? sinkError;
    StackTrace? sinkStack;
    bool write(Pointer<Void> userdata, Pointer<Uint8> data, int length) {
      try {
        sink(copyBytes(data, length));
        return true;
      } catch (error, stack) {
        sinkError = error;
        sinkStack = stack;
        return false;
      }
    }

    // Closed right after the call: the library only uses the writer during
    // ghostty_snapshot_encode, which is synchronous.
    final callable = NativeCallable<GhosttyWriterFnFunction>.isolateLocal(
      write,
      exceptionalReturn: false,
    )..keepIsolateAlive = false;
    try {
      // Inside use(): a sink that touches the terminal hits the reentrancy
      // guard instead of mutating it mid-encode, and a dispose from the sink
      // is deferred until the library is done.
      final raw = handle.use(
        (terminal) => using((arena) {
          final writer = arena<GhosttyWriter>();
          writer.ref
            ..write = callable.nativeFunction
            ..userdata = nullptr;
          return ghostty_snapshot_encode(terminal, writer.ref);
        }),
      );
      final error = sinkError;
      if (error != null) Error.throwWithStackTrace(error, sinkStack!);
      checkResult(raw, 'ghostty_snapshot_encode');
    } finally {
      callable.close();
    }
  }
}
