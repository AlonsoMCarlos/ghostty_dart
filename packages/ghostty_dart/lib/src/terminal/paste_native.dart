/// Internal implementation of `VtTerminal.paste` over
/// `ghostty_terminal_paste`. Not exported.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../core/internal.dart';
import '../core/result.dart';
import '../ffi/bindings.g.dart';
import 'paste.dart';

const _operation = 'ghostty_terminal_paste';

/// Pastes into the terminal behind [handle]. See `VtTerminal.paste`.
///
/// The MIME reader is a [NativeCallable.isolateLocal] that lives only for
/// this synchronous call. An exception thrown by [read] is rethrown after
/// the native call returns.
PasteResult pasteInto(
  NativeHandle<GhosttyTerminalImpl> handle, {
  required List<String> mimeTypes,
  required Uint8List? Function(String mimeType) read,
  required ClipboardLocation location,
  required PasteSource source,
  required bool allowUnsafe,
}) => using((arena) {
  final count = mimeTypes.length;
  final mimes = arena<GhosttyString>(count == 0 ? 1 : count);
  final addresses = <int, String>{};
  for (var i = 0; i < count; i++) {
    final bytes = utf8.encode(mimeTypes[i]);
    final data = arena<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    data.asTypedList(bytes.length).setAll(0, bytes);
    mimes[i]
      ..ptr = data
      ..len = bytes.length;
    addresses[data.address] = mimeTypes[i];
  }

  Object? readError;
  StackTrace? readStack;
  bool onRead(Pointer<Void> _, GhosttyString mime, GhosttyWriter writer) {
    try {
      final type = addresses[mime.ptr.address] ?? readGhosttyString(mime);
      final data = read(type);
      if (data == null) return false;
      if (data.isEmpty) return true;
      final write = writer.write.asFunction<DartGhosttyWriterFnFunction>();
      return withNativeBytes(
        data,
        (pointer, length) => write(writer.userdata, pointer, length),
      );
    } catch (error, stack) {
      readError = error;
      readStack = stack;
      return false;
    }
  }

  final reader = NativeCallable<GhosttyMimeReaderFnFunction>.isolateLocal(
    onRead,
    exceptionalReturn: false,
  );
  try {
    final paste = arena<GhosttyPaste>()..initSized(sizeOf<GhosttyPaste>());
    paste.ref
      ..location = clipboardLocationCodec.encode(location)
      ..source = pasteSourceToRaw(source)
      ..mimes = count == 0 ? nullptr : mimes
      ..mimes_len = count
      ..allow_unsafe = allowUnsafe;
    paste.ref.reader
      ..read = reader.nativeFunction
      ..userdata = nullptr;
    final pasted = arena<Bool>();
    final raw = handle.use(
      (terminal) => ghostty_terminal_paste(terminal, paste, pasted),
    );
    if (readError != null) Error.throwWithStackTrace(readError!, readStack!);
    final code = checkResultAllowing(raw, _operation, {
      GhosttyResultCode.rejected,
    });
    if (code == GhosttyResultCode.rejected) return PasteResult.rejected;
    return pasted.value ? PasteResult.pasted : PasteResult.nothingToPaste;
  } finally {
    reader.close();
  }
});
