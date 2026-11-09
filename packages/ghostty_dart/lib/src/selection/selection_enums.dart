/// The enums of `selection.h` and their raw-value codecs.
///
/// Pure Dart: no `dart:ffi`, so a future web backend can reuse it.
library;

import '../core/enum_codec.dart';

/// The order of a selection's two ends in the terminal
/// (`GhosttySelectionOrder`), read with `VtSelection.order`.
///
/// "Before" means earlier in top-left to bottom-right order.
enum SelectionOrder {
  /// The start is before the end.
  forward(0),

  /// The end is before the start (the user dragged up or to the left).
  reverse(1),

  /// A rectangular selection from its top-right to its bottom-left corner.
  mirroredForward(2),

  /// A rectangular selection from its bottom-left to its top-right corner.
  mirroredReverse(3),

  /// An order added by a later libghostty-vt release.
  unknown(null);

  const SelectionOrder(this._raw);
  final int? _raw;
}

/// Converts raw `GhosttySelectionOrder` values to [SelectionOrder] and back.
final selectionOrderCodec = RawEnumCodec<SelectionOrder>(
  SelectionOrder.values,
  raw: (v) => v._raw,
  unknown: SelectionOrder.unknown,
);

/// How `VtSelection.adjusted` moves a selection's end
/// (`GhosttySelectionAdjust`), as for keyboard selection
/// (shift+arrow keys).
///
/// The logical end (`VtSelection.end`) always moves, whichever way the
/// selection runs, so extending a reversed selection keeps working.
enum SelectionAdjustment {
  /// Left to the previous non-empty cell, wrapping to the row above.
  left(0),

  /// Right to the next non-empty cell, wrapping to the row below.
  right(1),

  /// Up one row in the same column, or to the start of the line at the
  /// top.
  up(2),

  /// Down to the next non-blank row in the same column, or to the end of
  /// the line if there is none.
  down(3),

  /// To the top-left cell of the screen.
  home(4),

  /// To the right edge of the last non-blank row of the screen.
  end(5),

  /// Up one page (the terminal's height), or [home] past the top.
  pageUp(6),

  /// Down one page (the terminal's height), or [end] past the bottom.
  pageDown(7),

  /// To the left edge of the current line.
  beginningOfLine(8),

  /// To the right edge of the current line.
  endOfLine(9);

  const SelectionAdjustment(this._raw);
  final int _raw;
}

/// The raw `GhosttySelectionAdjust` value of [adjustment].
int selectionAdjustmentToRaw(SelectionAdjustment adjustment) => adjustment._raw;

/// What a click of a `SelectionGesture` selects
/// (`GhosttySelectionGestureBehavior`).
enum SelectionGestureBehavior {
  /// Cell by cell: a press selects nothing, a drag selects cells.
  cell(0),

  /// A press selects the word under the pointer; a drag extends by words.
  word(1),

  /// A press selects the line under the pointer; a drag extends by lines.
  line(2),

  /// A press selects the command output under the pointer (needs shell
  /// integration, OSC 133); a drag extends by outputs.
  output(3),

  /// A behaviour added by a later libghostty-vt release.
  unknown(null);

  const SelectionGestureBehavior(this._raw);
  final int? _raw;
}

/// Converts raw `GhosttySelectionGestureBehavior` values to
/// [SelectionGestureBehavior] and back.
final selectionGestureBehaviorCodec = RawEnumCodec<SelectionGestureBehavior>(
  SelectionGestureBehavior.values,
  raw: (v) => v._raw,
  unknown: SelectionGestureBehavior.unknown,
);

/// Which way a selection drag wants the viewport to scroll
/// (`GhosttySelectionGestureAutoscroll`), read with
/// `SelectionGesture.autoscroll`.
enum SelectionAutoscroll {
  /// No scrolling is needed.
  none(0),

  /// The pointer is above the terminal: scroll toward older content.
  up(1),

  /// The pointer is below the terminal: scroll toward newer content.
  down(2),

  /// A direction added by a later libghostty-vt release.
  unknown(null);

  const SelectionAutoscroll(this._raw);
  final int? _raw;
}

/// Converts raw `GhosttySelectionGestureAutoscroll` values to
/// [SelectionAutoscroll] and back.
final selectionAutoscrollCodec = RawEnumCodec<SelectionAutoscroll>(
  SelectionAutoscroll.values,
  raw: (v) => v._raw,
  unknown: SelectionAutoscroll.unknown,
);
