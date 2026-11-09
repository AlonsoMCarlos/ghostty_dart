/// Viewport scrolling targets and scrollbar state (`terminal.h`).
library;

/// Where to move the viewport, for `VtTerminal.scrollViewport`
/// (`GhosttyTerminalScrollViewport`).
///
/// ```dart
/// terminal.scrollViewport(const ViewportScroll.delta(-5)); // up 5 rows
/// terminal.scrollViewport(const ViewportScroll.bottom());
/// ```
sealed class ViewportScroll {
  /// Base constructor for the subclasses; use the factories.
  const ViewportScroll();

  /// Scroll to the top of the scrollback.
  const factory ViewportScroll.top() = ScrollToTop;

  /// Scroll to the bottom, so the viewport follows the active area again.
  const factory ViewportScroll.bottom() = ScrollToBottom;

  /// Scroll by [rows] rows; negative is up (into history).
  const factory ViewportScroll.delta(int rows) = ScrollByRows;

  /// Scroll so that [row] (0 = top of the scrollback) is the first visible
  /// row. Same row space as [ViewportScrollbar.offset].
  const factory ViewportScroll.row(int row) = ScrollToRow;

  /// Scroll by [prompts] shell prompts; negative is backwards. Needs
  /// semantic prompt markers (OSC 133) from the shell.
  const factory ViewportScroll.prompts(int prompts) = ScrollByPrompts;
}

/// Scroll to the top of the scrollback (`GHOSTTY_TERMINAL_SCROLL_VIEWPORT_TOP`).
final class ScrollToTop extends ViewportScroll {
  /// Creates the target. Prefer `const ViewportScroll.top()`.
  const ScrollToTop();

  @override
  bool operator ==(Object other) => other is ScrollToTop;

  @override
  int get hashCode => (ScrollToTop).hashCode;

  @override
  String toString() => 'ViewportScroll.top()';
}

/// Scroll to the bottom (the active area)
/// (`GHOSTTY_TERMINAL_SCROLL_VIEWPORT_BOTTOM`).
final class ScrollToBottom extends ViewportScroll {
  /// Creates the target. Prefer `const ViewportScroll.bottom()`.
  const ScrollToBottom();

  @override
  bool operator ==(Object other) => other is ScrollToBottom;

  @override
  int get hashCode => (ScrollToBottom).hashCode;

  @override
  String toString() => 'ViewportScroll.bottom()';
}

/// Scroll by a number of rows (`GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA`).
final class ScrollByRows extends ViewportScroll {
  /// Scroll by [rows]; negative is up. Prefer `ViewportScroll.delta`.
  const ScrollByRows(this.rows);

  /// The number of rows to scroll; negative is up (into history).
  final int rows;

  @override
  bool operator ==(Object other) => other is ScrollByRows && other.rows == rows;

  @override
  int get hashCode => Object.hash(ScrollByRows, rows);

  @override
  String toString() => 'ViewportScroll.delta($rows)';
}

/// Scroll to an absolute row (`GHOSTTY_TERMINAL_SCROLL_VIEWPORT_ROW`).
///
/// The library clamps the row so the viewport never goes past the top of
/// the active area. Without scrollback (e.g. on the alternate screen) the
/// viewport stays on the active area.
final class ScrollToRow extends ViewportScroll {
  /// Scroll to [row] (0 or more). Prefer `ViewportScroll.row`.
  const ScrollToRow(this.row);

  /// The row offset from the top of the scrollback that becomes the first
  /// visible row.
  final int row;

  @override
  bool operator ==(Object other) => other is ScrollToRow && other.row == row;

  @override
  int get hashCode => Object.hash(ScrollToRow, row);

  @override
  String toString() => 'ViewportScroll.row($row)';
}

/// Scroll by a number of shell prompts
/// (`GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA_PROMPT`).
///
/// Counts from the viewport top. Zero, or no matching prompt, does nothing;
/// if fewer prompts remain than requested, the viewport stops at the last
/// one (clamped to the active area).
final class ScrollByPrompts extends ViewportScroll {
  /// Scroll by [prompts]; negative is backwards. Prefer
  /// `ViewportScroll.prompts`.
  const ScrollByPrompts(this.prompts);

  /// The number of prompts to move; negative is backwards.
  final int prompts;

  @override
  bool operator ==(Object other) =>
      other is ScrollByPrompts && other.prompts == prompts;

  @override
  int get hashCode => Object.hash(ScrollByPrompts, prompts);

  @override
  String toString() => 'ViewportScroll.prompts($prompts)';
}

/// What a scrollbar for the viewport needs (`GhosttyTerminalScrollbar`), in
/// rows.
///
/// There is no change notification: poll `VtTerminal.scrollbar` once per
/// frame or per write batch and compare with `==`.
final class ViewportScrollbar {
  /// Creates a scrollbar state.
  const ViewportScrollbar({
    required this.total,
    required this.offset,
    required this.length,
  });

  /// The total size of the scrollable area (scrollback plus active area).
  final int total;

  /// Where the viewport starts within [total]; 0 is the top of the
  /// scrollback. Pass it to `ViewportScroll.row` to restore a position.
  final int offset;

  /// The number of visible rows.
  final int length;

  /// Whether the viewport shows the bottom of the scrollable area.
  bool get isAtBottom => offset + length >= total;

  @override
  bool operator ==(Object other) =>
      other is ViewportScrollbar &&
      other.total == total &&
      other.offset == offset &&
      other.length == length;

  @override
  int get hashCode => Object.hash(total, offset, length);

  @override
  String toString() =>
      'ViewportScrollbar(total: $total, offset: $offset, length: $length)';
}
