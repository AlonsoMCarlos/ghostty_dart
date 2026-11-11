// Ported from package:xterm 4.0.0 (lib/src/core/buffer/range.dart).
// Copyright (c) 2020 xuty. MIT License, see LICENSE.xterm.

import 'cell_offset.dart';
import 'segment.dart';

/// A range of cells between [begin] and [end]: a stream of lines
/// (`BufferRangeLine`) or a rectangle (`BufferRangeBlock`).
abstract class BufferRange {
  /// Where the range starts; may come after [end] (see [isNormalized]).
  final CellOffset begin;

  /// Where the range ends.
  final CellOffset end;

  /// Creates a range from [begin] to [end].
  const BufferRange(this.begin, this.end);

  /// Creates an empty range at [begin].
  BufferRange.collapsed(this.begin) : end = begin;

  /// Whether [begin] does not come after [end].
  bool get isNormalized {
    return begin.isBefore(end) || begin.isEqual(end);
  }

  /// Whether [begin] and [end] are the same position.
  bool get isCollapsed {
    return begin.isEqual(end);
  }

  /// This range with [begin] and [end] swapped if needed, so that [begin]
  /// comes first.
  BufferRange get normalized;

  /// Convert this range to segments of single lines.
  Iterable<BufferSegment> toSegments();

  /// Returns true if the given[position] is within this range.
  bool contains(CellOffset position);

  /// Returns the smallest range that contains both this range and the given
  /// [range].
  BufferRange merge(BufferRange range);

  /// Returns the smallest range that contains both this range and the given
  /// [position].
  BufferRange extend(CellOffset position);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }

    if (other is! BufferRange) {
      return false;
    }

    return begin == other.begin && end == other.end;
  }

  @override
  int get hashCode => begin.hashCode ^ end.hashCode;

  @override
  String toString() => 'Range($begin, $end)';
}
