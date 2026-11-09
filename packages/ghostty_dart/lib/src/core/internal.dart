/// Internal helpers for ghostty_dart modules. Never exported from the public
/// barrels: everything here may expose `dart:ffi` types.
///
/// Modules import it as `import '../core/internal.dart';` together with
/// `import '../ffi/bindings.g.dart';` for the raw functions.
library;

export 'enum_codec.dart' show RawEnumCodec;
export 'handle.dart' show NativeHandle, bindHandle, createNative, handleOf;
export 'library_info.dart'
    show ensureCompatibleLibrary, libraryVersionProblem, optimizeModeCodec;
export 'list_equality.dart' show listEquals;
export 'memory.dart'
    show
        GrowableNativeBuffer,
        SizedStructInit,
        callAllocating,
        callWithSizeQuery,
        copyBytes,
        decodeUtf8,
        readGhosttyString,
        takeLibraryBytes,
        tryCallWithBuffer,
        tryCallWithCodepointBuffer,
        tryCallWithSizeQuery,
        withNativeBytes,
        withScratch,
        withUtf8;
export 'mode.dart' show terminalModeFromRaw, terminalModeToRaw;
export 'modifiers.dart' show keyModifiersFromRaw, keyModifiersToRaw;
export 'native_convert.dart';
export 'point.dart' show pointSpaceCodec;
export 'result.dart'
    show
        checkResult,
        checkResultAllowing,
        checkResultHasValue,
        decodeResult,
        resultCodec,
        resultError;
export 'style.dart' show underlineStyleCodec;
export 'terminal_enums.dart' show vtCursorStyleCodec, terminalScreenCodec;
