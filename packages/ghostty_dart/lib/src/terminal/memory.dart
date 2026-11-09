/// Terminal memory figures and scrollback compression
/// (`GhosttyTerminalMemoryUsage`, `GhosttyTerminalCompression*`).
library;

import '../core/enum_codec.dart';

/// How much compression work `VtTerminal.compress` does before returning
/// (`GhosttyTerminalCompressionMode`).
enum CompressionMode {
  /// One bounded step, suitable for an idle callback. Repeat while the
  /// result is [CompressionResult.pending].
  incremental(0),

  /// One synchronous pass over every eligible page. Can stall on a large
  /// scrollback.
  full(1);

  const CompressionMode(this._raw);

  final int _raw;
}

/// The raw `GhosttyTerminalCompressionMode` value of [mode].
int compressionModeToRaw(CompressionMode mode) => mode._raw;

/// What `VtTerminal.compress` says to do next
/// (`GhosttyTerminalCompressionResult`).
enum CompressionResult {
  /// Compression cannot free memory on this platform. Stop scheduling it.
  unsupported(0),

  /// More incremental work remains; call again while the terminal is idle.
  pending(1),

  /// The pass finished. Nothing to do until `VtTerminal.compressionActivity`
  /// changes. Not every page is necessarily compressed.
  complete(2),

  /// A result added by a later libghostty-vt release. Treat it as
  /// [complete].
  unknown(null);

  const CompressionResult(this._raw);

  final int? _raw;
}

/// Converts raw `GhosttyTerminalCompressionResult` values to
/// [CompressionResult].
final compressionResultCodec = RawEnumCodec<CompressionResult>(
  CompressionResult.values,
  raw: (result) => result._raw,
  unknown: CompressionResult.unknown,
);

/// The memory held by one screen of a terminal (the `primary_*` or
/// `alternate_*` fields of `GhosttyTerminalMemoryUsage`).
final class ScreenMemoryUsage {
  /// Creates the figures for one screen.
  const ScreenMemoryUsage({
    required this.pages,
    required this.virtualBytes,
    required this.residentBytes,
    required this.compressedPages,
    required this.compressedBytes,
    required this.imageBytes,
  });

  /// No memory: the figures of a screen that was never used.
  static const empty = ScreenMemoryUsage(
    pages: 0,
    virtualBytes: 0,
    residentBytes: 0,
    compressedPages: 0,
    compressedBytes: 0,
    imageBytes: 0,
  );

  /// The number of pages, including compressed ones.
  final int pages;

  /// Bytes of address space reserved for the pages, including compressed
  /// and spare pages. Always at least [residentBytes].
  final int virtualBytes;

  /// Bytes of physical memory used by the pages; a compressed page counts
  /// its compressed size. Budget against this figure.
  final int residentBytes;

  /// The number of compressed pages.
  final int compressedPages;

  /// Bytes of compressed data, already included in [residentBytes].
  final int compressedBytes;

  /// Bytes of Kitty graphics image data, not included in [residentBytes].
  /// Always 0 without Kitty graphics support.
  final int imageBytes;

  /// The sum of this screen and [other], field by field.
  ScreenMemoryUsage operator +(ScreenMemoryUsage other) => ScreenMemoryUsage(
    pages: pages + other.pages,
    virtualBytes: virtualBytes + other.virtualBytes,
    residentBytes: residentBytes + other.residentBytes,
    compressedPages: compressedPages + other.compressedPages,
    compressedBytes: compressedBytes + other.compressedBytes,
    imageBytes: imageBytes + other.imageBytes,
  );

  @override
  bool operator ==(Object other) =>
      other is ScreenMemoryUsage &&
      other.pages == pages &&
      other.virtualBytes == virtualBytes &&
      other.residentBytes == residentBytes &&
      other.compressedPages == compressedPages &&
      other.compressedBytes == compressedBytes &&
      other.imageBytes == imageBytes;

  @override
  int get hashCode => Object.hash(
    pages,
    virtualBytes,
    residentBytes,
    compressedPages,
    compressedBytes,
    imageBytes,
  );

  @override
  String toString() =>
      'ScreenMemoryUsage(pages: $pages, virtualBytes: $virtualBytes, '
      'residentBytes: $residentBytes, compressedPages: $compressedPages, '
      'compressedBytes: $compressedBytes, imageBytes: $imageBytes)';
}

/// How much memory a terminal holds (`GhosttyTerminalMemoryUsage`), read
/// with `VtTerminal.memoryUsage`.
final class TerminalMemoryUsage {
  /// Creates the figures for a terminal.
  const TerminalMemoryUsage({
    required this.compressionSupported,
    required this.primary,
    required this.alternate,
  });

  /// Whether compressing scrollback can free memory on this platform. When
  /// `false`, `VtTerminal.compress` reports [CompressionResult.unsupported]
  /// and the compressed figures are always 0.
  final bool compressionSupported;

  /// The primary screen.
  final ScreenMemoryUsage primary;

  /// The alternate screen; [ScreenMemoryUsage.empty] until a program first
  /// switches to it.
  final ScreenMemoryUsage alternate;

  /// Both screens added together: the terminal's total.
  ScreenMemoryUsage get total => primary + alternate;

  @override
  bool operator ==(Object other) =>
      other is TerminalMemoryUsage &&
      other.compressionSupported == compressionSupported &&
      other.primary == primary &&
      other.alternate == alternate;

  @override
  int get hashCode => Object.hash(compressionSupported, primary, alternate);

  @override
  String toString() =>
      'TerminalMemoryUsage(compressionSupported: $compressionSupported, '
      'primary: $primary, alternate: $alternate)';
}
