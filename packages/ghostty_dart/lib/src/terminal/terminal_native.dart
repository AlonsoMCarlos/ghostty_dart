/// Internal native plumbing for `VtTerminal`: typed `ghostty_terminal_get`
/// reads, `ghostty_terminal_set` writes and the reentrancy guard. Not
/// exported.
library;

import 'dart:ffi';

import '../core/color.dart';
import '../core/internal.dart';
import '../ffi/bindings.g.dart';

const _getOperation = 'ghostty_terminal_get';
const _setOperation = 'ghostty_terminal_set';

/// `SIZE_MAX` as Dart reads a `size_t` back (all bits set).
final int sizeMax = sizeOf<Size>() == 8 ? -1 : 0xFFFFFFFF;

/// The size in bytes of the 256-entry palette `GhosttyColorRgb[256]`.
final int _paletteBytes = 256 * sizeOf<GhosttyColorRgb>();

/// Throws [StateError] when `VtTerminal.[member]` is called from inside a
/// callback of the terminal behind [handle]: the library is not reentrant.
void checkNotInCallback(
  NativeHandle<GhosttyTerminalImpl> handle,
  String member,
) {
  if (handle.isInUse) {
    throw StateError(
      'VtTerminal.$member must not be called from inside a callback of '
      'the same terminal',
    );
  }
}

// ---------------------------------------------------------------------------
// Reads
// ---------------------------------------------------------------------------

/// Reads data [key] into [size] bytes of zeroed scratch memory and decodes
/// it with [decode]. Every error throws.
R readData<R>(
  Pointer<GhosttyTerminalImpl> terminal,
  int key,
  int size,
  R Function(Pointer<Uint8> out) decode,
) => withScratch(size, (out) {
  checkResult(ghostty_terminal_get(terminal, key, out.cast()), _getOperation);
  return decode(out);
});

/// Like [readData], but returns `null` for `GHOSTTY_NO_VALUE`.
R? tryReadData<R extends Object>(
  Pointer<GhosttyTerminalImpl> terminal,
  int key,
  int size,
  R Function(Pointer<Uint8> out) decode,
) => withScratch(
  size,
  (out) =>
      checkResultHasValue(
        ghostty_terminal_get(terminal, key, out.cast()),
        _getOperation,
      )
      ? decode(out)
      : null,
);

/// Reads a `uint8_t` field.
int readUint8(Pointer<GhosttyTerminalImpl> t, int key) =>
    readData(t, key, sizeOf<Uint8>(), (out) => out.value);

/// Reads a `uint16_t` field.
int readUint16(Pointer<GhosttyTerminalImpl> t, int key) =>
    readData(t, key, sizeOf<Uint16>(), (out) => out.cast<Uint16>().value);

/// Reads a `uint32_t` field.
int readUint32(Pointer<GhosttyTerminalImpl> t, int key) =>
    readData(t, key, sizeOf<Uint32>(), (out) => out.cast<Uint32>().value);

/// Reads a `uint64_t` field.
int readUint64(Pointer<GhosttyTerminalImpl> t, int key) =>
    readData(t, key, sizeOf<Uint64>(), (out) => out.cast<Uint64>().value);

/// Reads a `size_t` field.
int readSize(Pointer<GhosttyTerminalImpl> t, int key) =>
    readData(t, key, sizeOf<Size>(), (out) => out.cast<Size>().value);

/// Reads a `size_t` field that is `GHOSTTY_NO_VALUE` when unlimited.
int? tryReadSize(Pointer<GhosttyTerminalImpl> t, int key) =>
    tryReadData(t, key, sizeOf<Size>(), (out) => out.cast<Size>().value);

/// Reads a `bool` field.
bool readBool(Pointer<GhosttyTerminalImpl> t, int key) =>
    readData(t, key, sizeOf<Bool>(), (out) => out.cast<Bool>().value);

/// Reads a C enum field (`unsigned int`) as its raw value.
int readEnum(Pointer<GhosttyTerminalImpl> t, int key) => readData(
  t,
  key,
  sizeOf<UnsignedInt>(),
  (out) => out.cast<UnsignedInt>().value,
);

/// Reads a borrowed `GhosttyString` field, copying it.
String readString(Pointer<GhosttyTerminalImpl> t, int key) => readData(
  t,
  key,
  sizeOf<GhosttyString>(),
  (out) => readGhosttyString(out.cast<GhosttyString>().ref),
);

/// Reads a `GhosttyColorRgb` field that may be `GHOSTTY_NO_VALUE`.
RgbColor? tryReadRgb(Pointer<GhosttyTerminalImpl> t, int key) => tryReadData(
  t,
  key,
  sizeOf<GhosttyColorRgb>(),
  (out) => rgbFromNative(out.cast<GhosttyColorRgb>().ref),
);

/// Reads a `GhosttyColorRgb[256]` field as an unmodifiable list.
List<RgbColor> readPalette(Pointer<GhosttyTerminalImpl> t, int key) =>
    readData(t, key, _paletteBytes, (out) {
      final colors = out.cast<GhosttyColorRgb>();
      return List.unmodifiable(
        List.generate(256, (i) => rgbFromNative(colors[i])),
      );
    });

/// Reads whether the mode with the packed [rawMode] (`GhosttyMode`) is set
/// (`GHOSTTY_TERMINAL_DATA_MODE`, an in/out `GhosttyTerminalModeConfig`).
bool readMode(Pointer<GhosttyTerminalImpl> t, int rawMode) =>
    withScratch(sizeOf<GhosttyTerminalModeConfig>(), (out) {
      final config = out.cast<GhosttyTerminalModeConfig>();
      config.ref.mode = rawMode;
      checkResult(
        ghostty_terminal_get(
          t,
          GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_MODE,
          config.cast(),
        ),
        _getOperation,
      );
      return config.ref.value;
    });

/// One key of a [readMulti] batch: the data [key] and the byte size of its
/// output type.
typedef MultiKey = ({int key, int size});

/// Reads several data [keys] with one `ghostty_terminal_get_multi` call.
///
/// [decode] receives the output pointer of each key, in order. Outputs are
/// 8-byte aligned in one scratch block.
R readMulti<R>(
  Pointer<GhosttyTerminalImpl> terminal,
  List<MultiKey> keys,
  R Function(List<Pointer<Uint8>> outputs) decode,
) {
  final count = keys.length;
  final offsets = <int>[];
  var cursor = count * (sizeOf<UnsignedInt>() + sizeOf<Pointer<Void>>());
  cursor = _align8(cursor);
  for (final entry in keys) {
    offsets.add(cursor);
    cursor = _align8(cursor + entry.size);
  }
  return withScratch(cursor, (block) {
    final values = block.cast<Pointer<Void>>();
    final keyArray = (block + count * sizeOf<Pointer<Void>>())
        .cast<UnsignedInt>();
    final outputs = <Pointer<Uint8>>[];
    for (var i = 0; i < count; i++) {
      final output = block + offsets[i];
      keyArray[i] = keys[i].key;
      values[i] = output.cast();
      outputs.add(output);
    }
    checkResult(
      ghostty_terminal_get_multi(terminal, count, keyArray, values, nullptr),
      'ghostty_terminal_get_multi',
    );
    return decode(outputs);
  });
}

int _align8(int offset) => (offset + 7) & ~7;

// ---------------------------------------------------------------------------
// Writes
// ---------------------------------------------------------------------------

/// Sets [option] to the value at [value] (`nullptr` restores the default).
///
/// Runs inside [NativeHandle.use] because setting an option may run
/// callbacks, then bumps the epoch: borrowed views (e.g. the title string)
/// are only valid until the next mutating call.
void setOption(
  NativeHandle<GhosttyTerminalImpl> handle,
  int option,
  Pointer<Void> value,
) {
  final raw = handle.use(
    (terminal) => ghostty_terminal_set(terminal, option, value),
  );
  handle.bumpEpoch();
  checkResult(raw, _setOperation);
}

/// Sets a `bool*` option; `null` restores the default.
void setBoolOption(
  NativeHandle<GhosttyTerminalImpl> handle,
  int option,
  bool? value,
) => value == null
    ? setOption(handle, option, nullptr)
    : withScratch(sizeOf<Bool>(), (out) {
        out.cast<Bool>().value = value;
        setOption(handle, option, out.cast());
      });

/// Sets a `uint8_t*` option; `null` restores the default.
void setUint8Option(
  NativeHandle<GhosttyTerminalImpl> handle,
  int option,
  int? value,
) => value == null
    ? setOption(handle, option, nullptr)
    : withScratch(sizeOf<Uint8>(), (out) {
        out.value = value;
        setOption(handle, option, out.cast());
      });

/// Sets a `size_t*` option; `null` restores the default.
void setSizeOption(
  NativeHandle<GhosttyTerminalImpl> handle,
  int option,
  int? value,
) => value == null
    ? setOption(handle, option, nullptr)
    : withScratch(sizeOf<Size>(), (out) {
        out.cast<Size>().value = value;
        setOption(handle, option, out.cast());
      });

/// Sets a `uint64_t*` option; `null` restores the default.
void setUint64Option(
  NativeHandle<GhosttyTerminalImpl> handle,
  int option,
  int? value,
) => value == null
    ? setOption(handle, option, nullptr)
    : withScratch(sizeOf<Uint64>(), (out) {
        out.cast<Uint64>().value = value;
        setOption(handle, option, out.cast());
      });

/// Sets a C enum (`unsigned int*`) option; `null` restores the default.
void setEnumOption(
  NativeHandle<GhosttyTerminalImpl> handle,
  int option,
  int? value,
) => value == null
    ? setOption(handle, option, nullptr)
    : withScratch(sizeOf<UnsignedInt>(), (out) {
        out.cast<UnsignedInt>().value = value;
        setOption(handle, option, out.cast());
      });

/// Sets a `GhosttyString*` option (the library copies it); `null` passes
/// NULL, which clears it.
void setStringOption(
  NativeHandle<GhosttyTerminalImpl> handle,
  int option,
  String? value,
) => value == null
    ? setOption(handle, option, nullptr)
    : withUtf8(
        value,
        (data, length) => withScratch(sizeOf<GhosttyString>(), (out) {
          out.cast<GhosttyString>().ref
            ..ptr = data
            ..len = length;
          setOption(handle, option, out.cast());
        }),
      );

/// Sets a `GhosttyColorRgb*` option; `null` unsets it.
void setRgbOption(
  NativeHandle<GhosttyTerminalImpl> handle,
  int option,
  RgbColor? value,
) => value == null
    ? setOption(handle, option, nullptr)
    : withScratch(sizeOf<GhosttyColorRgb>(), (out) {
        rgbToNative(value, out.cast<GhosttyColorRgb>().ref);
        setOption(handle, option, out.cast());
      });

/// Sets a `GhosttyColorRgb[256]*` option; `null` restores the built-in
/// palette. Throws [ArgumentError] unless [palette] has exactly 256 entries.
void setPaletteOption(
  NativeHandle<GhosttyTerminalImpl> handle,
  int option,
  List<RgbColor>? palette,
) {
  if (palette == null) return setOption(handle, option, nullptr);
  if (palette.length != 256) {
    throw ArgumentError.value(
      palette.length,
      'palette.length',
      'a palette must have exactly 256 colours',
    );
  }
  withScratch(_paletteBytes, (out) {
    final colors = out.cast<GhosttyColorRgb>();
    for (var i = 0; i < 256; i++) {
      rgbToNative(palette[i], colors[i]);
    }
    setOption(handle, option, out.cast());
  });
}

/// Sets a `GhosttyTerminalModeConfig*` option ([option] is `OPT_MODE` or
/// `OPT_MODE_DEFAULT`).
void setModeOption(
  NativeHandle<GhosttyTerminalImpl> handle,
  int option,
  int rawMode,
  bool enabled,
) => withScratch(sizeOf<GhosttyTerminalModeConfig>(), (out) {
  out.cast<GhosttyTerminalModeConfig>().ref
    ..mode = rawMode
    ..value = enabled;
  setOption(handle, option, out.cast());
});
