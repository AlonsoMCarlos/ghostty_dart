/// Internal implementation of `VtTerminal.memoryUsage`,
/// `VtTerminal.compressionActivity` and `VtTerminal.compress`. Not exported.
library;

import 'dart:ffi';

import '../core/internal.dart';
import '../ffi/bindings.g.dart';
import 'memory.dart';

/// Reads `GHOSTTY_TERMINAL_DATA_MEMORY_USAGE` (a sized struct).
TerminalMemoryUsage readMemoryUsage(Pointer<GhosttyTerminalImpl> terminal) =>
    withScratch(sizeOf<GhosttyTerminalMemoryUsage>(), (out) {
      final usage = out.cast<GhosttyTerminalMemoryUsage>()
        ..initSized(sizeOf<GhosttyTerminalMemoryUsage>());
      checkResult(
        ghostty_terminal_get(
          terminal,
          GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_MEMORY_USAGE,
          usage.cast(),
        ),
        'ghostty_terminal_get',
      );
      final u = usage.ref;
      return TerminalMemoryUsage(
        compressionSupported: u.compression_supported,
        primary: ScreenMemoryUsage(
          pages: u.primary_pages,
          virtualBytes: u.primary_virtual_bytes,
          residentBytes: u.primary_resident_bytes,
          compressedPages: u.primary_compressed_pages,
          compressedBytes: u.primary_compressed_bytes,
          imageBytes: u.primary_image_bytes,
        ),
        alternate: ScreenMemoryUsage(
          pages: u.alternate_pages,
          virtualBytes: u.alternate_virtual_bytes,
          residentBytes: u.alternate_resident_bytes,
          compressedPages: u.alternate_compressed_pages,
          compressedBytes: u.alternate_compressed_bytes,
          imageBytes: u.alternate_image_bytes,
        ),
      );
    });

/// Reads the opaque `ghostty_terminal_compression_activity` token.
int readCompressionActivity(Pointer<GhosttyTerminalImpl> terminal) =>
    withScratch(sizeOf<Uint64>(), (out) {
      checkResult(
        ghostty_terminal_compression_activity(terminal, out.cast<Uint64>()),
        'ghostty_terminal_compression_activity',
      );
      return out.cast<Uint64>().value;
    });

/// Runs `ghostty_terminal_compress` on the terminal behind [handle]: inside
/// [NativeHandle.use], then bumps the epoch (compression moves page
/// storage, so borrowed views must be refreshed).
CompressionResult compressTerminal(
  NativeHandle<GhosttyTerminalImpl> handle,
  CompressionMode mode,
) {
  final (raw, result) = withScratch(sizeOf<UnsignedInt>(), (out) {
    final raw = handle.use(
      (terminal) => ghostty_terminal_compress(
        terminal,
        compressionModeToRaw(mode),
        out.cast(),
      ),
    );
    return (raw, out.cast<UnsignedInt>().value);
  });
  handle.bumpEpoch();
  checkResult(raw, 'ghostty_terminal_compress');
  return compressionResultCodec.decode(result);
}
