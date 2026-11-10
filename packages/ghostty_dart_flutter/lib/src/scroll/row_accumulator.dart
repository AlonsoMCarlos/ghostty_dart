/// Turns pixel scroll deltas into whole rows (ADR 0011: scrolling is
/// driven by pointer deltas with fractional-row accumulation). Never
/// exported.
library;

/// Accumulates pixel deltas and hands out whole rows, keeping the
/// remainder for the next delta.
///
/// Mirrors Ghostty's `scrollCallback` (`src/Surface.zig` at tag `vt-1.0.0`): a
/// delta smaller than one cell is kept pending, and a larger one scrolls by
/// the number of whole cells it covers, rounded towards zero. Unlike
/// Ghostty the remainder is kept exactly, so slow trackpad scrolling never
/// loses distance.
final class RowAccumulator {
  double _pending = 0;

  /// The distance not yet turned into rows, in the units of [add].
  double get pending => _pending;

  /// Adds [delta] (positive is down, towards newer output) and returns the
  /// whole rows of [rowExtent] it completes, negative for up.
  ///
  /// A non-finite [delta] or a non-positive [rowExtent] adds nothing.
  int add(double delta, double rowExtent) {
    if (!delta.isFinite || !(rowExtent > 0) || !rowExtent.isFinite) return 0;
    final total = _pending + delta;
    final rows = (total / rowExtent).truncate();
    _pending = total - rows * rowExtent;
    return rows;
  }

  /// Drops the pending distance (at the start or end of a gesture, or
  /// when scrolling is cancelled).
  void reset() => _pending = 0;
}
