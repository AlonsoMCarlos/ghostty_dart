/// A snapshot of the terminal cursor.
library;

import '../core/style.dart';

/// The cursor of a terminal at one moment, read in a single native call by
/// `VtTerminal.cursor`.
///
/// For the cursor *shape* (block, bar, ...), which a renderer draws, see
/// the render state; this is the emulator's view of the cursor.
final class TerminalCursor {
  /// Creates a cursor snapshot.
  const TerminalCursor({
    required this.x,
    required this.y,
    required this.isVisible,
    required this.hasPendingWrap,
    required this.style,
  });

  /// The column, 0-based.
  final int x;

  /// The row within the active area, 0-based.
  final int y;

  /// Whether the cursor is visible (DEC mode 25, DECTCEM).
  final bool isVisible;

  /// Whether the next printed character soft-wraps to the next line first
  /// (the cursor is past the last column).
  final bool hasPendingWrap;

  /// The SGR style applied to newly printed characters (bold, colours,
  /// ...). Not the cursor's shape.
  final CellStyle style;

  @override
  bool operator ==(Object other) =>
      other is TerminalCursor &&
      other.x == x &&
      other.y == y &&
      other.isVisible == isVisible &&
      other.hasPendingWrap == hasPendingWrap &&
      other.style == style;

  @override
  int get hashCode => Object.hash(x, y, isVisible, hasPendingWrap, style);

  @override
  String toString() =>
      'TerminalCursor(x: $x, y: $y, isVisible: $isVisible, '
      'hasPendingWrap: $hasPendingWrap, style: $style)';
}
