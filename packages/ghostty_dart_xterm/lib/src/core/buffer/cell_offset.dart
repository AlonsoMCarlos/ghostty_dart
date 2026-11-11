// Ported from package:xterm 4.0.0 (lib/src/core/buffer/cell_offset.dart).
// Copyright (c) 2020 xuty. MIT License, see LICENSE.xterm.

import 'range.dart';

/// A cell position in a buffer: column [x] and buffer row [y], where row 0
/// is the oldest scrollback row (not the top of the screen).
class CellOffset {
  /// The column.
  final int x;

  /// The buffer row, counted from the oldest scrollback row.
  final int y;

  /// Creates the position of column [x], buffer row [y].
  const CellOffset(this.x, this.y);

  /// Whether [other] is the same position.
  bool isEqual(CellOffset other) {
    return other.x == x && other.y == y;
  }

  /// Whether this position comes before [other] in reading order.
  bool isBefore(CellOffset other) {
    return y < other.y || (y == other.y && x < other.x);
  }

  /// Whether this position comes after [other] in reading order.
  bool isAfter(CellOffset other) {
    return y > other.y || (y == other.y && x > other.x);
  }

  /// Whether this position comes before [other] or is the same.
  bool isBeforeOrSame(CellOffset other) {
    return y < other.y || (y == other.y && x <= other.x);
  }

  /// Whether this position comes after [other] or is the same.
  bool isAfterOrSame(CellOffset other) {
    return y > other.y || (y == other.y && x >= other.x);
  }

  /// Whether this position is on the same row as [other].
  bool isAtSameRow(CellOffset other) {
    return y == other.y;
  }

  /// Whether this position is in the same column as [other].
  bool isAtSameColumn(CellOffset other) {
    return x == other.x;
  }

  /// Whether [range] contains this position.
  bool isWithin(BufferRange range) {
    return range.contains(this);
  }

  @override
  String toString() => 'CellOffset($x, $y)';

  @override
  int get hashCode => x.hashCode ^ y.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CellOffset &&
          runtimeType == other.runtimeType &&
          x == other.x &&
          y == other.y;
}
