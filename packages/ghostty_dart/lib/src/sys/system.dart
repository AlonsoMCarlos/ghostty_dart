/// The process-wide system interface of libghostty-vt (`ghostty_sys_set`):
/// logging, PNG decoding for Kitty graphics and the secure random source.
library;

import 'dart:async';
import 'dart:ffi';

import '../core/internal.dart';
import '../ffi/bindings.g.dart';
import 'sys_types.dart';

// How these functions relate to isolates and threads (checked against the
// libghostty-vt 1.0.0 sources, src/terminal/c/sys.zig and callers).
//
// - `ghostty_sys_set` stores one function pointer per option for the whole
//   process. The library never spawns threads (the search thread is compiled
//   out of the C library), so each sys callback runs synchronously on the
//   thread of the library call that needed it:
//   - log: any call that logs, mostly `vt_write` (protocol warnings) and a
//     few setters; `std.log` is routed to the callback in `sys.zig logFn`.
//   - PNG decoder: only while a Kitty `f=100` transmission completes, inside
//     `vt_write`.
//   - secure random: only for Kitty clipboard grant tokens (paste with the
//     5522 protocol), inside the paste/write call.
// - `NativeCallable.isolateLocal` aborts the process when invoked on another
//   thread. Both alternatives were rejected: `NativeCallable.listener` runs
//   after the C call returned, when the borrowed message, PNG and output
//   pointers are already invalid (copying them needs native code), and
//   `NativeCallable.isolateGroupBound` is experimental in Dart 3.13 and only
//   accepts trivially shareable callbacks, not user closures.
// - So a Dart handler is safe while only the installing isolate uses the
//   library. One more source of foreign-thread calls is `NativeFinalizer`s,
//   which may run `*_free` on a GC helper thread. No `_free` logs on Linux
//   or Windows; on Apple platforms `ghostty_terminal_free` can log a warning
//   if `madvise(MADV_FREE_REUSE)` fails while releasing a compressed
//   scrollback page (`mem.zig recommit`). The public docs therefore ask
//   for explicit disposal of terminals while a Dart log handler is
//   installed.
//
// Each option has at most one callable per isolate, created on the first
// non-null set and kept for the isolate's lifetime (contratos.md §9a): a
// handler may clear or replace itself while the library is running on its
// callable, so closing it early would be undefined behaviour. Callables do
// not keep the isolate alive.

/// Routes libghostty-vt's log messages to [handler], or discards them when
/// [handler] is `null` (the default).
///
/// ```dart
/// setVtLogHandler((level, scope, message) {
///   if (level == VtLogLevel.error) stderr.writeln('[$scope] $message');
/// });
/// ```
///
/// The handler runs synchronously inside the library call that logged
/// (usually `VtTerminal.write`), so keep it cheap and do not call
/// libghostty-vt from it. An error it throws is reported to the [Zone] that
/// was current when it was installed, as an uncaught error. Which levels
/// arrive depends on the build (see [VtLogLevel]). Replaces any earlier
/// handler, including [useVtStderrLogging].
///
/// **Process-wide and not thread-safe.** The setting applies to every
/// terminal of the process. Call it at startup, before other isolates or
/// threads use libghostty-vt, never while one does. While a Dart handler is
/// installed, only the isolate that installed it may use the library: a
/// message logged by a call made on another thread aborts the process. Pass
/// `null` before that isolate exits if others keep using the library. For
/// multi-isolate programs, prefer [useVtStderrLogging], which is safe on any
/// thread.
///
/// Dispose terminals explicitly (`VtTerminal.dispose`) while a Dart handler
/// is installed. A forgotten terminal is freed by a finalizer that may run
/// on a garbage-collector thread, and on Apple platforms freeing a terminal
/// with compressed scrollback can log a warning if the OS rejects a memory
/// hint, which would then reach the handler from that thread.
///
/// Throws [UnsupportedError] if the library does not know the option.
void setVtLogHandler(VtLogHandler? handler) {
  if (handler == null) {
    _setOption(GhosttySysOption.GHOSTTY_SYS_OPT_LOG, nullptr);
    _log = null;
    return;
  }
  final callable = _logCallable ??=
      NativeCallable<GhosttySysLogFnFunction>.isolateLocal(_onLog)
        ..keepIsolateAlive = false;
  _setOption(
    GhosttySysOption.GHOSTTY_SYS_OPT_LOG,
    callable.nativeFunction.cast(),
  );
  _log = _Installed(handler);
}

/// Makes libghostty-vt write its log messages to the process's standard
/// error, formatted as `[level](scope): message`.
///
/// This uses the library's own native logger, so unlike a Dart
/// [setVtLogHandler] handler it is safe when several isolates or threads use
/// the library. Replaces any earlier handler; `setVtLogHandler(null)` turns
/// logging off again.
///
/// **Process-wide and not thread-safe** to call: call it at startup, before
/// other isolates or threads use libghostty-vt.
///
/// Throws [UnsupportedError] if the library does not know the option.
void useVtStderrLogging() {
  _setOption(
    GhosttySysOption.GHOSTTY_SYS_OPT_LOG,
    Native.addressOf<NativeFunction<GhosttySysLogFnFunction>>(
      ghostty_sys_log_stderr,
    ).cast(),
  );
  _log = null;
}

/// Lets terminals accept PNG images in the Kitty graphics protocol, using
/// [decoder] to turn them into pixels; `null` (the default) rejects PNG
/// images again.
///
/// libghostty-vt has no PNG decoder of its own. Without one, a program that
/// sends a PNG (`f=100`) gets an error and the image is not stored; raw
/// RGB/RGBA/gray images work either way. Stored images are always raw
/// pixels, so renderers never see PNG data.
///
/// ```dart
/// setVtPngDecoder((png) {
///   final image = myPngLibrary.decode(png);   // any decoder you trust
///   return image == null
///       ? null
///       : RgbaImage(width: image.width, height: image.height,
///           pixels: image.rgbaBytes);
/// });
/// ```
///
/// The decoder runs synchronously inside the `VtTerminal.write` that
/// received the image, on untrusted input; it must not call libghostty-vt.
/// Returning `null` or throwing rejects the image; a thrown error is also
/// reported to the [Zone] that was current when the decoder was installed.
/// The pixels are copied into memory the library owns.
///
/// **Process-wide and not thread-safe**, with the same isolate rules as
/// [setVtLogHandler]: while a Dart decoder is installed, only the isolate
/// that installed it may write PNG images to terminals.
///
/// Throws [UnsupportedError] if the library does not know the option.
void setVtPngDecoder(VtPngDecoder? decoder) {
  if (decoder == null) {
    _setOption(GhosttySysOption.GHOSTTY_SYS_OPT_DECODE_PNG, nullptr);
    _png = null;
    return;
  }
  final callable = _pngCallable ??=
      NativeCallable<GhosttySysDecodePngFnFunction>.isolateLocal(
        _onDecodePng,
        exceptionalReturn: false,
      )..keepIsolateAlive = false;
  _setOption(
    GhosttySysOption.GHOSTTY_SYS_OPT_DECODE_PNG,
    callable.nativeFunction.cast(),
  );
  _png = _Installed(decoder);
}

/// Replaces the platform's secure random source with [source]; `null` (the
/// default) restores the platform source (`getrandom`/`arc4random_buf` on
/// POSIX, CNG on Windows).
///
/// The library uses secure random bytes for secrets (for example Kitty
/// clipboard grant tokens), so [source] must be a real CSPRNG such as
/// `Random.secure()` from `dart:math`; a predictable source is a security
/// hole. Returning `false` or throwing makes the operation that needed
/// entropy fail; a thrown error is also reported to the [Zone] that was
/// current when the source was installed. Native platforms always have a
/// default, so most programs never need this.
///
/// **Process-wide and not thread-safe**, with the same isolate rules as
/// [setVtLogHandler].
///
/// Throws [UnsupportedError] if the library does not know the option.
void setVtSecureRandomSource(VtSecureRandomSource? source) {
  if (source == null) {
    _setOption(GhosttySysOption.GHOSTTY_SYS_OPT_RANDOM_SECURE, nullptr);
    _random = null;
    return;
  }
  final callable = _randomCallable ??=
      NativeCallable<GhosttySysRandomSecureFnFunction>.isolateLocal(
        _onRandomSecure,
        exceptionalReturn: false,
      )..keepIsolateAlive = false;
  _setOption(
    GhosttySysOption.GHOSTTY_SYS_OPT_RANDOM_SECURE,
    callable.nativeFunction.cast(),
  );
  _random = _Installed(source);
}

/// A Dart handler and the zone it was installed in (errors it throws are
/// reported there).
final class _Installed<F extends Function> {
  _Installed(this.callback) : zone = Zone.current;

  final F callback;
  final Zone zone;

  /// Runs [invoke] with the handler; an error is reported to [zone] and
  /// [fallback] is returned, so nothing unwinds through native frames.
  R run<R>(R fallback, R Function(F callback) invoke) {
    try {
      return invoke(callback);
    } catch (error, stack) {
      zone.handleUncaughtError(error, stack);
      return fallback;
    }
  }
}

_Installed<VtLogHandler>? _log;
_Installed<VtPngDecoder>? _png;
_Installed<VtSecureRandomSource>? _random;

NativeCallable<GhosttySysLogFnFunction>? _logCallable;
NativeCallable<GhosttySysDecodePngFnFunction>? _pngCallable;
NativeCallable<GhosttySysRandomSecureFnFunction>? _randomCallable;

void _setOption(int option, Pointer<Void> value) {
  ensureCompatibleLibrary();
  checkResult(ghostty_sys_set(option, value), 'ghostty_sys_set');
}

void _onLog(
  Pointer<Void> userdata,
  int level,
  Pointer<Uint8> scope,
  int scopeLength,
  Pointer<Uint8> message,
  int messageLength,
) {
  _log?.run<void>(
    null,
    (handler) => handler(
      vtLogLevelCodec.decode(level),
      decodeUtf8(scope, scopeLength),
      decodeUtf8(message, messageLength),
    ),
  );
}

bool _onDecodePng(
  Pointer<Void> userdata,
  Pointer<GhosttyAllocator> allocator,
  Pointer<Uint8> data,
  int length,
  Pointer<GhosttySysImage> out,
) =>
    _png?.run(false, (decoder) {
      final image = decoder(copyBytes(data, length));
      if (image == null) return false;
      final size = image.pixels.length;
      // The library frees the buffer with this allocator and `data_len`,
      // so the allocation must be exactly the pixel size.
      final buffer = ghostty_alloc(allocator, size);
      if (buffer == nullptr) return false;
      buffer.asTypedList(size).setAll(0, image.pixels);
      out.ref
        ..width = image.width
        ..height = image.height
        ..data = buffer
        ..data_len = size;
      return true;
    }) ??
    false;

bool _onRandomSecure(
  Pointer<Void> userdata,
  Pointer<Uint8> buffer,
  int length,
) =>
    _random?.run(false, (source) => source(buffer.asTypedList(length))) ??
    false;
