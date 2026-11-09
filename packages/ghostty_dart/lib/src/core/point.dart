/// Positions in the terminal grid (`point.h`).
library;

import 'enum_codec.dart';

/// The coordinate system of a [GridPoint] (`GhosttyPointTag`).
///
/// The same row has a different `y` in each system.
enum PointSpace {
  /// The active area, where the cursor can move. Row 0 is the top of the
  /// active area.
  active(0),

  /// The visible viewport, which moves when the user scrolls. Row 0 is the
  /// top visible row.
  viewport(1),

  /// The full screen including scrollback. Row 0 is the oldest scrollback
  /// row.
  screen(2),

  /// Scrollback history only (the rows above the active area).
  history(3),

  /// A coordinate system added by a later libghostty-vt release.
  unknown(null);

  const PointSpace(this._raw);

  final int? _raw;
}

/// Converts raw `GhosttyPointTag` values to [PointSpace] and back.
final pointSpaceCodec = RawEnumCodec<PointSpace>(
  PointSpace.values,
  raw: (space) => space._raw,
  unknown: PointSpace.unknown,
);

/// A cell position in the terminal grid (`GhosttyPoint`): a column [x] and a
/// row [y] in the coordinate system [space].
///
/// ```dart
/// const topLeftVisible = GridPoint.viewport(0, 0);
/// ```
final class GridPoint {
  /// A point at column [x] and row [y] in [space].
  ///
  /// [x] is 0–65535 (`uint16_t`) and [y] is 0–4294967295 (`uint32_t`).
  const GridPoint(this.space, this.x, this.y)
    : assert(x >= 0 && x <= 0xFFFF, 'x must fit in uint16'),
      assert(y >= 0 && y <= 0xFFFFFFFF, 'y must fit in uint32');

  /// A point in the active area ([PointSpace.active]).
  const GridPoint.active(int x, int y) : this(PointSpace.active, x, y);

  /// A point in the viewport ([PointSpace.viewport]).
  const GridPoint.viewport(int x, int y) : this(PointSpace.viewport, x, y);

  /// A point in the full screen ([PointSpace.screen]).
  const GridPoint.screen(int x, int y) : this(PointSpace.screen, x, y);

  /// A point in the scrollback history ([PointSpace.history]).
  const GridPoint.history(int x, int y) : this(PointSpace.history, x, y);

  /// The coordinate system of [x] and [y].
  final PointSpace space;

  /// Column, 0-indexed.
  final int x;

  /// Row, 0-indexed, in [space].
  final int y;

  @override
  bool operator ==(Object other) =>
      other is GridPoint &&
      other.space == space &&
      other.x == x &&
      other.y == y;

  @override
  int get hashCode => Object.hash(space, x, y);

  @override
  String toString() => 'GridPoint.${space.name}($x, $y)';
}
