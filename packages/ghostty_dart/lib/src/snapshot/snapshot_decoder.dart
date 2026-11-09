/// [SnapshotDecoder]: restore a terminal from a snapshot, in one call or in
/// pieces (`ghostty_snapshot_decoder_*`).
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../core/core.dart';
import '../core/internal.dart';
import '../ffi/bindings.g.dart';
import '../terminal/terminal.dart' show VtTerminal, adoptNativeTerminal;
import 'snapshot_progress.dart';

/// Restores a [VtTerminal] from a snapshot made by
/// `VtTerminal.encodeSnapshot` (`GhosttySnapshotDecoder`).
///
/// **The snapshot format is not covered by libghostty-vt's ABI promise.** A
/// snapshot written by another library version may be rejected, so never
/// persist snapshots across library upgrades (see `VtTerminalSnapshot`).
/// Snapshots are untrusted input; malformed ones are rejected with a
/// [GhosttyException] and never corrupt memory.
///
/// In one call:
///
/// ```dart
/// final decoder = SnapshotDecoder(snapshot);
/// final terminal = decoder.decode();
/// decoder.dispose();
/// ```
///
/// Or in pieces, so a large scrollback does not delay the first frame:
/// [ready] returns a terminal that can already be drawn and fed live input,
/// and each [next] restores one more history page (or the pixels of one
/// Kitty image) until it returns `null`:
///
/// ```dart
/// final decoder = SnapshotDecoder(snapshot);
/// final terminal = decoder.ready();
/// for (var p = decoder.next(); p != null; p = decoder.next()) {
///   if (p is SnapshotPage) redrawScrollbar();
/// }
/// decoder.dispose();
/// ```
///
/// ## Lifecycle
///
/// Set options ([maxContinuationBytes], [retainContinuation],
/// [compressHistory], [kittyImageStorageLimit]) first; they freeze once
/// decoding starts. Then call either [decode] or [ready] once. A failure
/// while reading input poisons the decoder: every member except
/// [isDisposed] and [dispose] then throws [StateError]. A terminal already
/// returned by [ready] stays usable with the history restored so far.
///
/// ## Ownership
///
/// The returned terminal belongs to the caller, who disposes it as usual;
/// disposing the decoder never disposes it. Between [ready] and the end of
/// the snapshot the decoder writes into that terminal, so it keeps it
/// alive, and disposing the terminal disposes the decoder first. Dispose
/// the decoder when done; a forgotten one is freed after it is garbage
/// collected. Snapshots are an optional build feature: without it the
/// constructors throw [UnsupportedError].
final class SnapshotDecoder implements Finalizable {
  /// Creates a decoder over a snapshot held in memory.
  ///
  /// The bytes are copied once into native memory, which the decoder keeps
  /// until it is disposed. Bytes after the end of the snapshot are ignored;
  /// [sourceOffset] tells where it ended.
  ///
  /// Throws [UnsupportedError] without the snapshot build feature and
  /// [GhosttyException] if the library runs out of memory.
  factory SnapshotDecoder(Uint8List snapshot) {
    ensureCompatibleLibrary();
    final length = snapshot.length;
    final source = malloc<Uint8>(length == 0 ? 1 : length);
    source.asTypedList(length).setAll(0, snapshot);
    try {
      final pointer = createNative<GhosttySnapshotDecoderImpl>(
        'ghostty_snapshot_decoder_new_buf',
        (out) => ghostty_snapshot_decoder_new_buf(nullptr, out, source, length),
      );
      return SnapshotDecoder._(pointer, source: source);
    } catch (_) {
      malloc.free(source);
      rethrow;
    }
  }

  /// Creates a decoder that pulls the snapshot from [read], so it never has
  /// to be in memory at once.
  ///
  /// [read] fills the start of `buffer` (a view of native memory valid only
  /// during the call; do not keep it) and returns how many bytes it wrote,
  /// from 1 to `buffer.length`. Returning 0 means the end of the input, for
  /// good: a source that has no data *yet* must block until it does. It is
  /// called synchronously, only from inside [ready], [next] and [decode],
  /// and must not use this decoder. If it throws, or returns a count out of
  /// range ([RangeError]), the call that was reading rethrows that error and
  /// the decoder is poisoned.
  ///
  /// Throws [UnsupportedError] without the snapshot build feature and
  /// [GhosttyException] if the library runs out of memory.
  factory SnapshotDecoder.fromReader(int Function(Uint8List buffer) read) {
    ensureCompatibleLibrary();
    final reader = _Reader(read);
    final callable = NativeCallable<GhosttyReaderFnFunction>.isolateLocal(
      reader.call,
      exceptionalReturn: false,
    )..keepIsolateAlive = false;
    try {
      final pointer = using(
        (arena) => createNative<GhosttySnapshotDecoderImpl>(
          'ghostty_snapshot_decoder_new',
          (out) {
            final native = arena<GhosttyReader>();
            native.ref
              ..read = callable.nativeFunction
              ..userdata = nullptr;
            return ghostty_snapshot_decoder_new(nullptr, out, native.ref);
          },
        ),
      );
      return SnapshotDecoder._(pointer, reader: reader, callable: callable);
    } catch (_) {
      callable.close();
      rethrow;
    }
  }

  SnapshotDecoder._(
    Pointer<GhosttySnapshotDecoderImpl> pointer, {
    Pointer<Uint8>? source,
    _Reader? reader,
    NativeCallable<GhosttyReaderFnFunction>? callable,
  }) : _reader = reader,
       _handle = NativeHandle(
         pointer,
         typeName: 'SnapshotDecoder',
         free: (p) => ghostty_snapshot_decoder_free(p),
         finalizer: _finalizer,
       ) {
    bindHandle(this, _handle);
    // Freed after the decoder (cleanups run after the free). If the decoder
    // is garbage collected instead, the finalizers may run in any order;
    // that is fine because `ghostty_snapshot_decoder_free` reads neither.
    if (source != null) {
      _sourceFinalizer.attach(this, source.cast(), detach: this);
      _handle.addCleanup(() {
        _sourceFinalizer.detach(this);
        malloc.free(source);
      });
    }
    if (callable != null) {
      _callableFinalizer.attach(this, callable, detach: this);
      _handle.addCleanup(() {
        _callableFinalizer.detach(this);
        callable.close();
      });
    }
  }

  /// `ghostty_snapshot_decoder_free` only releases the decoder itself, so a
  /// native finalizer is safe (contratos.md §4.2a).
  static final _finalizer = NativeFinalizer(
    Native.addressOf<NativeFunction<Void Function(GhosttySnapshotDecoder)>>(
      ghostty_snapshot_decoder_free,
    ).cast(),
  );

  static final _sourceFinalizer = NativeFinalizer(malloc.nativeFree);

  /// Closes the reader callable of a decoder that was never disposed. By
  /// then the native decoder is unreachable, so nothing can call it.
  static final _callableFinalizer =
      Finalizer<NativeCallable<GhosttyReaderFnFunction>>(
        (callable) => callable.close(),
      );

  final NativeHandle<GhosttySnapshotDecoderImpl> _handle;
  final _Reader? _reader;
  _State _state = _State.configuring;

  /// The terminal returned by [ready], kept alive while the decoder writes
  /// into it.
  VtTerminal? _terminal;

  /// Whether [dispose] has been called (directly, or by disposing the
  /// terminal returned by [ready]).
  bool get isDisposed => _handle.isDisposed;

  /// Whether the whole snapshot has been read and validated: [decode]
  /// returned, or [next] returned `null`.
  bool get isFinished {
    _handle.checkNotDisposed();
    return _state == _State.finished;
  }

  // -------------------------------------------------------------------------
  // Options (before decoding starts)
  // -------------------------------------------------------------------------

  /// The largest unfinished escape sequence (parser continuation) the
  /// snapshot may carry, in bytes; 0 accepts only snapshots whose parser was
  /// at ground. Defaults to the largest built-in APC limit (65 MiB); `null`
  /// restores that default.
  ///
  /// With [retainContinuation] on, it also becomes the restored terminal's
  /// `continuationMaxBytes`. Throws [RangeError] for a negative value and
  /// [StateError] once decoding has started.
  int get maxContinuationBytes => _getRequired(
    GhosttySnapshotDecoderData
        .GHOSTTY_SNAPSHOT_DECODER_DATA_MAX_CONTINUATION_BYTES,
    sizeOf<Size>(),
    (out) => out.cast<Size>().value,
  );
  set maxContinuationBytes(int? bytes) {
    if (bytes != null) RangeError.checkNotNegative(bytes, 'bytes');
    _setOption(
      GhosttySnapshotDecoderOption
          .GHOSTTY_SNAPSHOT_DECODER_OPT_MAX_CONTINUATION_BYTES,
      bytes == null ? null : sizeOf<Size>(),
      (out) => out.cast<Size>().value = bytes!,
    );
  }

  /// Whether the restored terminal keeps continuation tracking on, with
  /// [maxContinuationBytes] as its limit, so `VtTerminal.continuation` can
  /// export the exact unfinished input restored from the snapshot. `false`
  /// by default.
  ///
  /// Tracking then stays on (even with an empty continuation): set the
  /// terminal's `continuationMaxBytes` to 0 after exporting if you do not
  /// need it, before writing new input. Throws [StateError] once decoding
  /// has started.
  bool get retainContinuation => _getRequired(
    GhosttySnapshotDecoderData
        .GHOSTTY_SNAPSHOT_DECODER_DATA_RETAIN_CONTINUATION,
    sizeOf<Bool>(),
    (out) => out.cast<Bool>().value,
  );
  set retainContinuation(bool retain) => _setOption(
    GhosttySnapshotDecoderOption
        .GHOSTTY_SNAPSHOT_DECODER_OPT_RETAIN_CONTINUATION,
    sizeOf<Bool>(),
    (out) => out.cast<Bool>().value = retain,
  );

  /// Whether history pages are compressed as they are restored, so the
  /// restored terminal starts out compressed without the memory spike of
  /// decoding first and calling `VtTerminal.compress` afterwards. `false`
  /// by default.
  ///
  /// A page on screen when it is restored stays uncompressed; platforms
  /// without compression ignore it. Throws [StateError] once decoding has
  /// started.
  bool get compressHistory => _getRequired(
    GhosttySnapshotDecoderData.GHOSTTY_SNAPSHOT_DECODER_DATA_COMPRESS_HISTORY,
    sizeOf<Bool>(),
    (out) => out.cast<Bool>().value,
  );
  set compressHistory(bool compress) => _setOption(
    GhosttySnapshotDecoderOption.GHOSTTY_SNAPSHOT_DECODER_OPT_COMPRESS_HISTORY,
    sizeOf<Bool>(),
    (out) => out.cast<Bool>().value = compress,
  );

  /// The Kitty image storage limit of each restored screen, in bytes; 0
  /// disables Kitty graphics on the restored terminal. Defaults to a new
  /// terminal's limit (`VtTerminal.defaultKittyImageStorageLimit`); `null`
  /// restores that default.
  ///
  /// The limit of the terminal that wrote the snapshot is not part of it.
  /// Images are restored oldest first, and ones that do not fit evict older
  /// ones. Throws [RangeError] for a negative value and [StateError] once
  /// decoding has started.
  int get kittyImageStorageLimit => _getRequired(
    GhosttySnapshotDecoderData
        .GHOSTTY_SNAPSHOT_DECODER_DATA_KITTY_IMAGE_STORAGE_LIMIT,
    sizeOf<Uint64>(),
    (out) => out.cast<Uint64>().value,
  );
  set kittyImageStorageLimit(int? bytes) {
    if (bytes != null) RangeError.checkNotNegative(bytes, 'bytes');
    _setOption(
      GhosttySnapshotDecoderOption
          .GHOSTTY_SNAPSHOT_DECODER_OPT_KITTY_IMAGE_STORAGE_LIMIT,
      bytes == null ? null : sizeOf<Uint64>(),
      (out) => out.cast<Uint64>().value = bytes!,
    );
  }

  // -------------------------------------------------------------------------
  // Decoding
  // -------------------------------------------------------------------------

  /// Decodes and validates the whole snapshot and returns the restored
  /// terminal, which the caller owns.
  ///
  /// May only be called once, before [ready]. Throws [StateError] otherwise,
  /// [GhosttyException] for a truncated, corrupt or incompatible snapshot
  /// (the decoder is then poisoned), and whatever a reader threw.
  VtTerminal decode() {
    _checkState(_State.configuring, 'decode');
    final pointer = _start(
      'ghostty_snapshot_decoder_decode',
      ghostty_snapshot_decoder_decode,
    );
    _state = _State.finished;
    return adoptNativeTerminal(pointer);
  }

  /// Decodes the part of the snapshot needed to draw (screens, cursor,
  /// modes, colours, image metadata) and returns the restored terminal,
  /// which the caller owns. Older scrollback and image pixels follow with
  /// [next].
  ///
  /// The terminal is usable at once: draw it, resize it and write live input
  /// to it between calls to [next]. Its Kitty images are known but their
  /// pixels arrive later (`KittyImage.hasPixels`).
  ///
  /// May only be called once, before [decode]. Throws [StateError]
  /// otherwise, [GhosttyException] for a truncated, corrupt or incompatible
  /// snapshot (the decoder is then poisoned), and whatever a reader threw.
  VtTerminal ready() {
    _checkState(_State.configuring, 'ready');
    final pointer = _start(
      'ghostty_snapshot_decoder_ready',
      ghostty_snapshot_decoder_ready,
    );
    final terminal = adoptNativeTerminal(pointer);
    _terminal = terminal;
    _state = _State.streaming;
    handleOf<GhosttyTerminalImpl>(terminal).addDependent(_handle);
    return terminal;
  }

  /// Restores the next history page or image pixels into the terminal
  /// returned by [ready], and says which; returns `null` once the whole
  /// snapshot has been read and validated (and on every later call).
  ///
  /// Like a write, this changes the terminal: borrowed views (render rows,
  /// grid references) become invalid. Pages that can no longer be applied
  /// safely, because live input changed the terminal, are still read and
  /// report zero rows; dropped pixels report zero bytes.
  ///
  /// After [decode] (the snapshot is then complete) it returns `null`.
  ///
  /// Throws [StateError] before [ready], when called from a callback of the
  /// terminal, or once poisoned; [GhosttyException] for corrupt input (the
  /// decoder is then poisoned, and the terminal keeps the history restored
  /// so far); and whatever a reader threw.
  SnapshotProgress? next() {
    if (_state == _State.finished) {
      _handle.checkNotDisposed();
      return null;
    }
    _checkState(_State.streaming, 'next');
    final terminal = handleOf<GhosttyTerminalImpl>(_terminal!);
    if (terminal.isInUse) {
      throw StateError(
        'SnapshotDecoder.next must not be called from inside a callback of '
        'its terminal',
      );
    }
    final int raw;
    try {
      raw = terminal.use(
        (_) => _call(
          'ghostty_snapshot_decoder_next',
          ghostty_snapshot_decoder_next,
        ),
      );
    } finally {
      // Also when the reader threw: the record may be partly applied.
      terminal.bumpEpoch();
    }
    if (!checkResultHasValue(raw, 'ghostty_snapshot_decoder_next')) {
      _state = _State.finished;
      return null;
    }
    return _readProgress();
  }

  // -------------------------------------------------------------------------
  // Progress figures
  // -------------------------------------------------------------------------

  /// The snapshot bytes read so far. Once [isFinished], the offset of the
  /// first byte after the snapshot (trailing bytes are not read).
  int get sourceOffset => _getRequired(
    GhosttySnapshotDecoderData.GHOSTTY_SNAPSHOT_DECODER_DATA_SOURCE_OFFSET,
    sizeOf<Size>(),
    (out) => out.cast<Size>().value,
  );

  /// The total scrollback rows of the primary screen, once [ready] or
  /// [decode] validated the snapshot, else `null`. Advisory, for sizing a
  /// scrollbar while [next] restores them.
  int? get historyRowsPrimary => _get(
    GhosttySnapshotDecoderData
        .GHOSTTY_SNAPSHOT_DECODER_DATA_HISTORY_ROWS_PRIMARY,
    sizeOf<Uint64>(),
    (out) => out.cast<Uint64>().value,
  );

  /// Like [historyRowsPrimary] for the alternate screen; also `null` when
  /// the snapshot has no alternate screen.
  int? get historyRowsAlternate => _get(
    GhosttySnapshotDecoderData
        .GHOSTTY_SNAPSHOT_DECODER_DATA_HISTORY_ROWS_ALTERNATE,
    sizeOf<Uint64>(),
    (out) => out.cast<Uint64>().value,
  );

  /// The Kitty images restored for the primary screen (their pixels follow
  /// with [next]), once the snapshot was validated, else `null`. 0 for a
  /// library built without Kitty graphics.
  int? get kittyImagesPrimary => _get(
    GhosttySnapshotDecoderData
        .GHOSTTY_SNAPSHOT_DECODER_DATA_KITTY_IMAGES_PRIMARY,
    sizeOf<Uint32>(),
    (out) => out.cast<Uint32>().value,
  );

  /// Like [kittyImagesPrimary] for the alternate screen; also `null` when
  /// the snapshot has no alternate screen.
  int? get kittyImagesAlternate => _get(
    GhosttySnapshotDecoderData
        .GHOSTTY_SNAPSHOT_DECODER_DATA_KITTY_IMAGES_ALTERNATE,
    sizeOf<Uint32>(),
    (out) => out.cast<Uint32>().value,
  );

  /// The Kitty pixel bytes of the primary screen still to come when [ready]
  /// returned, for a progress indicator (add up [SnapshotImagePixels.bytes]
  /// against it; dropped pixels count 0, so the sum may end below it), once
  /// the snapshot was validated, else `null`.
  int? get kittyPendingBytesPrimary => _get(
    GhosttySnapshotDecoderData
        .GHOSTTY_SNAPSHOT_DECODER_DATA_KITTY_PENDING_BYTES_PRIMARY,
    sizeOf<Uint64>(),
    (out) => out.cast<Uint64>().value,
  );

  /// Like [kittyPendingBytesPrimary] for the alternate screen; also `null`
  /// when the snapshot has no alternate screen.
  int? get kittyPendingBytesAlternate => _get(
    GhosttySnapshotDecoderData
        .GHOSTTY_SNAPSHOT_DECODER_DATA_KITTY_PENDING_BYTES_ALTERNATE,
    sizeOf<Uint64>(),
    (out) => out.cast<Uint64>().value,
  );

  /// Frees the decoder (and its copy of the snapshot). Safe to call more
  /// than once. The terminal it returned is not disposed; abandoning an
  /// incremental decode leaves it with the history restored so far.
  void dispose() => _handle.dispose();

  // -------------------------------------------------------------------------
  // Plumbing
  // -------------------------------------------------------------------------

  void _checkState(_State expected, String member) {
    _handle.checkNotDisposed();
    if (_state == expected) return;
    throw StateError(switch (_state) {
      _State.failed =>
        'SnapshotDecoder.$member: the decoder failed and can only be disposed',
      _State.configuring => 'SnapshotDecoder.$member: call ready() first',
      _State.streaming || _State.finished =>
        'SnapshotDecoder.$member: decoding has already started',
    });
  }

  void _checkUsable() {
    _handle.checkNotDisposed();
    if (_state == _State.failed) {
      throw StateError('SnapshotDecoder failed and can only be disposed');
    }
  }

  /// Runs the `ready`/`decode` [call] and returns the terminal it made.
  Pointer<GhosttyTerminalImpl> _start(
    String operation,
    int Function(
      Pointer<GhosttySnapshotDecoderImpl> decoder,
      Pointer<Pointer<GhosttyTerminalImpl>> terminal,
    )
    call,
  ) => withScratch(sizeOf<Pointer<Void>>(), (out) {
    final terminal = out.cast<Pointer<GhosttyTerminalImpl>>();
    final raw = _call(operation, (decoder) => call(decoder, terminal));
    checkResult(raw, operation);
    return terminal.value;
  });

  /// Runs a decoding [call] inside the handle (a dispose from the reader is
  /// deferred), rethrows a reader error, and poisons the decoder on any
  /// failure. Returns the raw result for the caller to map.
  int _call(
    String operation,
    int Function(Pointer<GhosttySnapshotDecoderImpl> decoder) call,
  ) {
    final raw = _handle.use(call);
    final readerError = _reader?.takeError();
    if (raw < 0 && decodeResult(raw) != GhosttyResultCode.noValue ||
        readerError != null) {
      _state = _State.failed;
    }
    if (readerError != null) {
      Error.throwWithStackTrace(readerError.$1, readerError.$2);
    }
    return raw;
  }

  SnapshotProgress _readProgress() {
    final screen = terminalScreenCodec.decode(
      _getRequired(
        GhosttySnapshotDecoderData
            .GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_SCREEN,
        sizeOf<UnsignedInt>(),
        (out) => out.cast<UnsignedInt>().value,
      ),
    );
    final kind = snapshotProgressKindCodec.decode(
      _getRequired(
        GhosttySnapshotDecoderData.GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_KIND,
        sizeOf<UnsignedInt>(),
        (out) => out.cast<UnsignedInt>().value,
      ),
    );
    int uint32(int key) =>
        _getRequired(key, sizeOf<Uint32>(), (out) => out.cast<Uint32>().value);
    int size(int key) =>
        _getRequired(key, sizeOf<Size>(), (out) => out.cast<Size>().value);
    return switch (kind) {
      SnapshotProgressKind.page => SnapshotPage(
        screen: screen,
        rows: size(
          GhosttySnapshotDecoderData
              .GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_ROWS,
        ),
        remaining: uint32(
          GhosttySnapshotDecoderData
              .GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_REMAINING,
        ),
      ),
      SnapshotProgressKind.image => SnapshotImagePixels(
        screen: screen,
        imageId: uint32(
          GhosttySnapshotDecoderData
              .GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_IMAGE_ID,
        ),
        frame: uint32(
          GhosttySnapshotDecoderData
              .GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_IMAGE_FRAME,
        ),
        bytes: size(
          GhosttySnapshotDecoderData
              .GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_IMAGE_BYTES,
        ),
      ),
      SnapshotProgressKind.unknown => UnknownSnapshotProgress(screen: screen),
    };
  }

  /// Reads data [key] ([size] bytes), or `null` for `GHOSTTY_NO_VALUE`.
  R? _get<R extends Object>(
    int key,
    int size,
    R Function(Pointer<Uint8> out) decode,
  ) {
    _checkUsable();
    return withScratch(size, (out) {
      final hasValue = checkResultHasValue(
        ghostty_snapshot_decoder_get(_handle.pointer, key, out.cast()),
        'ghostty_snapshot_decoder_get',
      );
      return hasValue ? decode(out) : null;
    });
  }

  /// Like [_get] for data the library always has in a usable decoder.
  R _getRequired<R extends Object>(
    int key,
    int size,
    R Function(Pointer<Uint8> out) decode,
  ) =>
      _get(key, size, decode) ??
      (throw GhosttyException(
        'ghostty_snapshot_decoder_get',
        resultCodec.encode(GhosttyResultCode.noValue),
      ));

  /// Sets [option] to the value [write] stores in [size] bytes, or restores
  /// its default when [size] is `null`.
  void _setOption(int option, int? size, void Function(Pointer<Uint8>) write) {
    _checkState(_State.configuring, 'options');
    withScratch(size ?? 0, (out) {
      if (size != null) write(out);
      checkResult(
        ghostty_snapshot_decoder_set(
          _handle.pointer,
          option,
          size == null ? nullptr : out.cast(),
        ),
        'ghostty_snapshot_decoder_set',
      );
    });
  }
}

enum _State { configuring, streaming, finished, failed }

/// The Dart side of a `GhosttyReader`: the user's read function and the
/// error it threw, if any. The callable captures only this object, never the
/// decoder, so an open callable does not keep a forgotten decoder alive.
final class _Reader {
  _Reader(this._read);

  final int Function(Uint8List buffer) _read;
  (Object, StackTrace)? _error;

  bool call(
    Pointer<Void> userdata,
    Pointer<Uint8> buffer,
    int capacity,
    Pointer<Size> outRead,
  ) {
    if (_error != null) return false;
    try {
      final count = _read(buffer.asTypedList(capacity));
      RangeError.checkValueInInterval(count, 0, capacity, 'bytes read');
      outRead.value = count;
      return true;
    } catch (error, stack) {
      _error = (error, stack);
      return false;
    }
  }

  /// The error [call] caught since the last call, cleared.
  (Object, StackTrace)? takeError() {
    final error = _error;
    _error = null;
    return error;
  }
}
