import 'package:ghostty_dart/ghostty_dart.dart';

import '../../utils/circular_buffer.dart';
import 'buffer_lines.dart';
import 'cell_offset.dart';
import 'line.dart';

/// An anchor created on a line read from a terminal: libghostty-vt tracks
/// its cell (a [TrackedGridRef]), so it follows the cell through
/// scrolling and reflow until the cell leaves the scrollback. Never
/// exported; `TerminalController` reads [ref] and [terminal].
final class TrackedCellAnchor extends CellAnchor {
  /// Creates an anchor at cell [offset] of [owner], tracked by [ref], for
  /// the buffer whose lines are [lines].
  TrackedCellAnchor(
    super.offset, {
    required BufferLine super.owner,
    required this.ref,
    required this.lines,
  });

  /// The tracked reference; disposed with the anchor or the terminal.
  final TrackedGridRef ref;

  /// The lines of the buffer the anchor was created in.
  final BufferLines lines;

  /// The `Terminal` the anchor belongs to.
  Object get terminal => lines.buffer.terminal;

  /// The tracked cell's position (screen space: row 0 is the oldest
  /// scrollback row), or `null` when it left the scrollback, the anchor
  /// was disposed or the terminal was disposed.
  GridPoint? get point {
    if (ref.isDisposed || (lines.engine?.isDisposed ?? true)) return null;
    return ref.pointIn(PointSpace.screen);
  }

  @override
  int get x => point?.x ?? super.x;

  @override
  int get y {
    final point = this.point;
    if (point == null) {
      throw StateError('the anchor is not attached');
    }
    return point.y;
  }

  @override
  CellOffset get offset {
    final point = this.point;
    if (point == null) {
      throw StateError('the anchor is not attached');
    }
    return CellOffset(point.x, point.y);
  }

  /// The current line of the anchored cell (a fresh snapshot), or `null`
  /// when the anchor is not attached.
  @override
  BufferLine? get line {
    final point = this.point;
    if (point == null) return null;
    final length = lines.length;
    return point.y < length ? lines.itemAt(point.y) : null;
  }

  @override
  bool get attached => point != null;

  @override
  void reparent(BufferLine owner, int offset) {
    super.reparent(owner, offset);
    if (ref.isDisposed) return;
    if (owner.attached && identical(indexedItemOwner(owner), lines)) {
      ref.moveTo(GridPoint.screen(offset, owner.index));
    }
  }

  @override
  void reposition(int offset) {
    super.reposition(offset);
    final point = this.point;
    if (point != null) ref.moveTo(GridPoint.screen(offset, point.y));
  }

  @override
  void dispose() {
    super.dispose();
    if (!ref.isDisposed) ref.dispose();
  }
}

/// A tracked anchor at cell [offset] of [line] when [line] is a current
/// line read from a terminal, else `null` (the caller makes xterm's plain
/// anchor).
CellAnchor? createTrackedAnchor(BufferLine line, int offset) {
  final owner = indexedItemOwner(line);
  return owner is BufferLines ? owner.track(line, offset) : null;
}
