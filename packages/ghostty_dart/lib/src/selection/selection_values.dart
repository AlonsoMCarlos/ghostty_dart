/// Value types for selection gestures (`selection.h`).
///
/// Pure Dart: no `dart:ffi`, so a future web backend can reuse it.
library;

import 'selection_enums.dart';

/// What single, double and triple clicks select
/// (`GhosttySelectionGestureBehaviors`).
///
/// The default is the usual terminal behaviour: cells, words, lines.
/// Immutable.
final class SelectionGestureBehaviors {
  /// A behaviour table; omitted entries keep the defaults.
  const SelectionGestureBehaviors({
    this.singleClick = SelectionGestureBehavior.cell,
    this.doubleClick = SelectionGestureBehavior.word,
    this.tripleClick = SelectionGestureBehavior.line,
  });

  /// What a single click (and its drag) selects.
  final SelectionGestureBehavior singleClick;

  /// What a double click (and its drag) selects.
  final SelectionGestureBehavior doubleClick;

  /// What a triple click (and its drag) selects.
  final SelectionGestureBehavior tripleClick;

  @override
  bool operator ==(Object other) =>
      other is SelectionGestureBehaviors &&
      other.singleClick == singleClick &&
      other.doubleClick == doubleClick &&
      other.tripleClick == tripleClick;

  @override
  int get hashCode => Object.hash(singleClick, doubleClick, tripleClick);

  @override
  String toString() =>
      'SelectionGestureBehaviors(single: ${singleClick.name}, '
      'double: ${doubleClick.name}, triple: ${tripleClick.name})';
}

/// How the terminal is laid out on screen, in surface pixels
/// (`GhosttySelectionGestureGeometry`).
///
/// Drags and autoscroll ticks of a `SelectionGesture` need it to decide
/// when a drag has crossed 60% of a cell and when the pointer is above or
/// below the terminal. Immutable.
final class SelectionGestureGeometry {
  /// A layout of [columns] cells of [cellWidth] pixels, starting
  /// [paddingLeft] pixels from the left of a surface [screenHeight] pixels
  /// tall.
  ///
  /// [columns], [cellWidth] and [screenHeight] are 1–4294967295 and
  /// [paddingLeft] is 0–4294967295 (`uint32_t`); `SelectionGesture`
  /// throws [RangeError] for values outside those ranges.
  const SelectionGestureGeometry({
    required this.columns,
    required this.cellWidth,
    required this.screenHeight,
    this.paddingLeft = 0,
  });

  /// The number of columns drawn.
  final int columns;

  /// The width of one cell, in pixels.
  final int cellWidth;

  /// The space left of the first column, in pixels.
  final int paddingLeft;

  /// The height of the whole terminal surface, in pixels.
  final int screenHeight;

  @override
  bool operator ==(Object other) =>
      other is SelectionGestureGeometry &&
      other.columns == columns &&
      other.cellWidth == cellWidth &&
      other.paddingLeft == paddingLeft &&
      other.screenHeight == screenHeight;

  @override
  int get hashCode =>
      Object.hash(columns, cellWidth, paddingLeft, screenHeight);

  @override
  String toString() =>
      'SelectionGestureGeometry(columns: $columns, cellWidth: $cellWidth, '
      'paddingLeft: $paddingLeft, screenHeight: $screenHeight)';
}
