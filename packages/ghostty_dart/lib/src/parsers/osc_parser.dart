/// The standalone OSC parser (`osc.h`).
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../core/core.dart';
import '../core/internal.dart';
import '../ffi/bindings.g.dart';
import 'osc_command.dart';

/// Turns one OSC (Operating System Command) sequence into an [OscCommand],
/// exactly as the terminal reads it.
///
/// A terminal parses OSC by itself; use this for OSC sequences outside of
/// one. Feed it the bytes between `ESC ]` and the terminator. A sequence
/// may arrive in pieces: call [add] for each piece, then [end].
///
/// ```dart
/// final parser = OscParser();
/// final command = parser.parse(utf8.encode('2;hello'));
/// // OscWindowTitleCommand(hello)
/// parser.dispose();
/// ```
///
/// ## Ownership
///
/// The parser owns a native object. Reuse one parser for many sequences and
/// call [dispose] when done; a finalizer frees it if you forget. After
/// [dispose], every member except [isDisposed] and [dispose] throws
/// [StateError]. Returned commands are plain Dart values (copied out of the
/// parser), so they stay valid after later calls and after [dispose].
final class OscParser implements Finalizable {
  /// Creates a parser. See [unknownMaxBytes] for keeping sequences the
  /// parser does not implement.
  ///
  /// Throws [RangeError] for a negative [unknownMaxBytes],
  /// [GhosttyException] if the library cannot allocate the parser and
  /// [IncompatibleLibraryException] if the loaded libghostty-vt is not a
  /// supported 1.x version.
  OscParser({int unknownMaxBytes = 0})
    : _handle = NativeHandle(
        createNative<GhosttyOscParserImpl>(
          'ghostty_osc_new',
          (out) => ghostty_osc_new(nullptr, out),
        ),
        typeName: 'OscParser',
        free: (p) => ghostty_osc_free(p),
        finalizer: _finalizer,
      ) {
    bindHandle(this, _handle);
    if (unknownMaxBytes != 0) {
      // Free the parser at once if the option is rejected.
      try {
        this.unknownMaxBytes = unknownMaxBytes;
      } catch (_) {
        dispose();
        rethrow;
      }
    }
  }

  static final _finalizer = NativeFinalizer(
    Native.addressOf<NativeFunction<Void Function(GhosttyOscParser)>>(
      ghostty_osc_free,
    ).cast(),
  );

  /// The byte [end] passes for each terminator, per `ghostty_osc_end`.
  static const _bel = 0x07;
  static const _st = 0x5C;

  final NativeHandle<GhosttyOscParserImpl> _handle;
  int _unknownMaxBytes = 0;

  /// Whether [dispose] has been called.
  bool get isDisposed => _handle.isDisposed;

  /// The most bytes kept from each sequence whose number the parser does
  /// not implement (`GHOSTTY_OSC_OPT_UNKNOWN_MAX_BYTES`).
  ///
  /// 0, the default, discards such sequences: [end] returns `null` for them.
  /// Any other value makes them [OscUnimplementedCommand]s, whose content is
  /// cut to this many bytes ([OscUnimplementedCommand.isTruncated]). Limits
  /// up to 2048 use a buffer the parser already owns; larger ones allocate
  /// for each such sequence.
  ///
  /// Kept across [reset]. A sequence already being parsed may still use the
  /// old limit. Throws [RangeError] for a negative value and [StateError]
  /// after [dispose].
  int get unknownMaxBytes {
    _handle.checkNotDisposed();
    return _unknownMaxBytes;
  }

  set unknownMaxBytes(int value) {
    RangeError.checkNotNegative(value, 'unknownMaxBytes');
    using((arena) {
      final limit = arena<Size>()..value = value;
      checkResult(
        ghostty_osc_set(
          _handle.pointer,
          GhosttyOscOption.GHOSTTY_OSC_OPT_UNKNOWN_MAX_BYTES,
          limit.cast(),
        ),
        'ghostty_osc_set',
      );
    });
    _unknownMaxBytes = value;
  }

  /// Feeds the next [bytes] of the current sequence.
  ///
  /// Throws [StateError] after [dispose].
  void add(Uint8List bytes) {
    final parser = _handle.pointer;
    for (final byte in bytes) {
      ghostty_osc_next(parser, byte);
    }
  }

  /// Feeds one [byte] (0–255) of the current sequence.
  ///
  /// Throws [RangeError] for a value outside 0–255 and [StateError] after
  /// [dispose].
  void addByte(int byte) {
    RangeError.checkValueInInterval(byte, 0, 255, 'byte');
    ghostty_osc_next(_handle.pointer, byte);
  }

  /// Ends the current sequence, returns its command and resets the parser
  /// for the next sequence.
  ///
  /// [terminator] says how the sequence ended; it only matters for commands
  /// that reply, which end their reply the same way. Returns `null` if the
  /// bytes are not a valid command, or are an unimplemented one while
  /// [unknownMaxBytes] is 0. To drop a sequence cancelled with CAN or SUB,
  /// call [reset] instead.
  ///
  /// Throws [ArgumentError] for [OscTerminator.unknown] and [StateError]
  /// after [dispose].
  OscCommand? end({OscTerminator terminator = OscTerminator.st}) {
    final byte = switch (terminator) {
      OscTerminator.st => _st,
      OscTerminator.bel => _bel,
      OscTerminator.unknown => throw ArgumentError.value(
        terminator,
        'terminator',
        'must be st or bel',
      ),
    };
    final parser = _handle.pointer;
    try {
      return _readCommand(ghostty_osc_end(parser, byte));
    } finally {
      ghostty_osc_reset(parser);
    }
  }

  /// Discards the sequence being parsed. Options such as [unknownMaxBytes]
  /// are kept.
  ///
  /// Throws [StateError] after [dispose].
  void reset() => ghostty_osc_reset(_handle.pointer);

  /// Parses one complete sequence: [reset], [add] of [bytes], then [end]
  /// with [terminator].
  ///
  /// Throws the errors of [end].
  OscCommand? parse(
    Uint8List bytes, {
    OscTerminator terminator = OscTerminator.st,
  }) {
    reset();
    add(bytes);
    return end(terminator: terminator);
  }

  /// Frees the native parser. Safe to call more than once.
  void dispose() => _handle.dispose();

  /// Copies the command into Dart. Its data is owned by the parser and only
  /// valid until the next `ghostty_osc_*` call, so this runs before the
  /// reset.
  static OscCommand? _readCommand(GhosttyOscCommand command) {
    final rawType = ghostty_osc_command_type(command);
    if (rawType == GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_INVALID) {
      return null;
    }
    return switch (oscCommandTypeCodec.decode(rawType)) {
      OscCommandType.changeWindowTitle => OscWindowTitleCommand(
        _readString(
          command,
          GhosttyOscCommandData.GHOSTTY_OSC_DATA_CHANGE_WINDOW_TITLE_STR,
          readGhosttyString,
        ),
      ),
      OscCommandType.unimplemented => OscUnimplementedCommand(
        content: _readString(
          command,
          GhosttyOscCommandData.GHOSTTY_OSC_DATA_UNKNOWN_CONTENT,
          (string) => copyBytes(string.ptr, string.len),
        ),
        isTruncated: _read<Bool, bool>(
          command,
          GhosttyOscCommandData.GHOSTTY_OSC_DATA_UNKNOWN_TRUNCATED,
          sizeOf<Bool>(),
          (value) => value.value,
        ),
        terminator: oscTerminatorCodec.decode(
          _read<UnsignedInt, int>(
            command,
            GhosttyOscCommandData.GHOSTTY_OSC_DATA_UNKNOWN_TERMINATOR,
            sizeOf<UnsignedInt>(),
            (value) => value.value,
          ),
        ),
      ),
      final type => OscOtherCommand(type),
    };
  }

  /// Reads a `GhosttyString` data value and converts it with [convert],
  /// which must copy: the bytes belong to the parser.
  static R _readString<R>(
    GhosttyOscCommand command,
    int data,
    R Function(GhosttyString string) convert,
  ) => _read<GhosttyString, R>(
    command,
    data,
    sizeOf<GhosttyString>(),
    (string) => convert(string.ref),
  );

  /// Reads one `ghostty_osc_command_data` value of [size] bytes into scratch
  /// memory and converts it with [convert] while that memory is valid.
  static R _read<T extends NativeType, R>(
    GhosttyOscCommand command,
    int data,
    int size,
    R Function(Pointer<T> value) convert,
  ) => withScratch(size, (memory) {
    checkResult(
      ghostty_osc_command_data(command, data, memory.cast()),
      'ghostty_osc_command_data',
    );
    return convert(memory.cast<T>());
  });
}
