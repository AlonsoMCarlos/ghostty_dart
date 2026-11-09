/// Logging and process-wide library options (`sys.h`).
///
/// libghostty-vt keeps a few process-global hooks for things it cannot do by
/// itself: delivering its log messages ([setVtLogHandler],
/// [useVtStderrLogging]), decoding PNG images for the Kitty graphics
/// protocol ([setVtPngDecoder]) and drawing secure random bytes
/// ([setVtSecureRandomSource]). Set them once at startup, before other
/// isolates or threads use the library.
library;

import 'system.dart';

export 'sys_types.dart'
    show
        RgbaImage,
        VtLogHandler,
        VtLogLevel,
        VtPngDecoder,
        VtSecureRandomSource;
export 'system.dart'
    show
        setVtLogHandler,
        setVtPngDecoder,
        setVtSecureRandomSource,
        useVtStderrLogging;
