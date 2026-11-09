/// What one step of an incremental snapshot decode restored
/// (`GhosttySnapshotDecoderProgressKind` and the `PROGRESS_*` data).
///
/// Pure Dart, so a future web backend can reuse it.
library;

import '../core/enum_codec.dart';
import '../core/terminal_enums.dart';

/// What `SnapshotDecoder.next` restored: a [SnapshotPage] of scrollback, the
/// [SnapshotImagePixels] of a Kitty graphics image, or an
/// [UnknownSnapshotProgress] of a kind added by a later library release.
sealed class SnapshotProgress {
  /// Base constructor: progress on [screen]. Only the subclasses call it.
  const SnapshotProgress(this.screen);

  /// The screen (primary or alternate) the record belongs to.
  final TerminalScreen screen;
}

/// One history page prepended to a screen's scrollback, together with the
/// Kitty graphics placements pinned to it.
final class SnapshotPage extends SnapshotProgress {
  /// Creates a page record; `SnapshotDecoder.next` creates these.
  const SnapshotPage({
    required TerminalScreen screen,
    required this.rows,
    required this.remaining,
  }) : super(screen);

  /// The rows the page added. 0 means it was read and validated but could
  /// not be applied, because live input changed the terminal too much.
  final int rows;

  /// The pages still to come for the same screen (not for the whole
  /// snapshot).
  final int remaining;

  @override
  bool operator ==(Object other) =>
      other is SnapshotPage &&
      other.screen == screen &&
      other.rows == rows &&
      other.remaining == remaining;

  @override
  int get hashCode => Object.hash(SnapshotPage, screen, rows, remaining);

  @override
  String toString() =>
      'SnapshotPage(${screen.name}, $rows rows, $remaining remaining)';
}

/// The pixels of one Kitty graphics image or animation frame.
final class SnapshotImagePixels extends SnapshotProgress {
  /// Creates an image record; `SnapshotDecoder.next` creates these.
  const SnapshotImagePixels({
    required TerminalScreen screen,
    required this.imageId,
    required this.frame,
    required this.bytes,
  }) : super(screen);

  /// The id of the image the pixels belong to.
  final int imageId;

  /// The frame, numbered as the Kitty protocol does: 1 is the image itself,
  /// 2 and up its animation frames.
  final int frame;

  /// The pixel bytes attached to the image. 0 means they were read and
  /// validated but dropped (the image was deleted or replaced by live input,
  /// did not fit the storage limit, or its screen is gone).
  final int bytes;

  @override
  bool operator ==(Object other) =>
      other is SnapshotImagePixels &&
      other.screen == screen &&
      other.imageId == imageId &&
      other.frame == frame &&
      other.bytes == bytes;

  @override
  int get hashCode =>
      Object.hash(SnapshotImagePixels, screen, imageId, frame, bytes);

  @override
  String toString() =>
      'SnapshotImagePixels(${screen.name}, image #$imageId frame $frame, '
      '$bytes bytes)';
}

/// A record of a kind added by a later libghostty-vt release. It was read
/// and applied; there is nothing to report about it.
final class UnknownSnapshotProgress extends SnapshotProgress {
  /// Creates a record of an unknown kind.
  const UnknownSnapshotProgress({required TerminalScreen screen})
    : super(screen);

  @override
  bool operator ==(Object other) =>
      other is UnknownSnapshotProgress && other.screen == screen;

  @override
  int get hashCode => Object.hash(UnknownSnapshotProgress, screen);

  @override
  String toString() => 'UnknownSnapshotProgress(${screen.name})';
}

/// The kinds of [SnapshotProgress] (`GhosttySnapshotDecoderProgressKind`).
/// Internal: the public API exposes the sealed classes instead.
enum SnapshotProgressKind {
  /// A [SnapshotPage].
  page(0),

  /// A [SnapshotImagePixels].
  image(1),

  /// A kind added by a later libghostty-vt release.
  unknown(null);

  const SnapshotProgressKind(this._raw);

  final int? _raw;
}

/// Converts raw `GhosttySnapshotDecoderProgressKind` values to
/// [SnapshotProgressKind] and back.
final snapshotProgressKindCodec = RawEnumCodec<SnapshotProgressKind>(
  SnapshotProgressKind.values,
  raw: (kind) => kind._raw,
  unknown: SnapshotProgressKind.unknown,
);
