import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:ghostty_dart/ghostty_dart.dart';

import '../metrics/cell_metrics.dart';

/// Where the grid sits in the view: cell metrics, grid size and padding,
/// and the conversions every part of the view shares (ADR 0011). Never
/// exported.
///
/// Two coordinate spaces:
/// - **local**: logical pixels from the top-left of the view (what Flutter
///   pointer events and paint use);
/// - **surface**: device pixels from the top-left of the view, padding
///   included (what [MouseEncoder], [SelectionGesture] and
///   `VtTerminal.resize` use).
///
/// [padding] is snapped to whole device pixels, so every cell edge is on a
/// device pixel and painted cells match the encoders' cells exactly.
@immutable
final class TerminalGeometry {
  /// A grid of [cols] × [rows] cells of [metrics], inset by [padding]
  /// (snapped to device pixels), in a view of [viewSize] (the grid plus the
  /// padding when omitted).
  TerminalGeometry({
    required this.metrics,
    required this.cols,
    required this.rows,
    EdgeInsets padding = EdgeInsets.zero,
    Size? viewSize,
  }) : padding = _snap(padding, metrics.devicePixelRatio),
       viewSize =
           viewSize ??
           Size(
             cols * metrics.width +
                 _snap(padding, metrics.devicePixelRatio).horizontal,
             rows * metrics.height +
                 _snap(padding, metrics.devicePixelRatio).vertical,
           ) {
    RangeError.checkValueInInterval(cols, 1, 0xFFFF, 'cols');
    RangeError.checkValueInInterval(rows, 1, 0xFFFF, 'rows');
  }

  /// The largest grid of [metrics] cells that fits in [viewSize] inside
  /// [padding]; at least 1 × 1 and at most 65535 × 65535.
  ///
  /// Counts in device pixels, so an exact fit is never lost to rounding.
  /// Throws [ArgumentError] for an infinite or NaN [viewSize]: give the
  /// view bounded constraints (it cannot size itself inside a `Row`,
  /// `Column` or list without them).
  factory TerminalGeometry.fit(
    Size viewSize,
    VtCellMetrics metrics, {
    EdgeInsets padding = EdgeInsets.zero,
  }) {
    if (!viewSize.width.isFinite || !viewSize.height.isFinite) {
      throw ArgumentError.value(
        viewSize,
        'viewSize',
        'a terminal view needs bounded constraints; wrap it in a SizedBox, '
            'Expanded or another widget that bounds its size',
      );
    }
    final dpr = metrics.devicePixelRatio;
    final snapped = _snap(padding, dpr);
    int cells(double extent, int cellPx) =>
        ((extent * dpr).round() ~/ cellPx).clamp(1, 0xFFFF);
    return TerminalGeometry(
      metrics: metrics,
      cols: cells(viewSize.width - snapped.horizontal, metrics.widthPx),
      rows: cells(viewSize.height - snapped.vertical, metrics.heightPx),
      padding: snapped,
      viewSize: viewSize,
    );
  }

  static EdgeInsets _snap(EdgeInsets padding, double dpr) {
    double px(double value) => (value * dpr).round() / dpr;
    return EdgeInsets.fromLTRB(
      px(padding.left),
      px(padding.top),
      px(padding.right),
      px(padding.bottom),
    );
  }

  /// The size of one cell.
  final VtCellMetrics metrics;

  /// The number of columns.
  final int cols;

  /// The number of rows.
  final int rows;

  /// The space between the view's edges and the grid, in whole device
  /// pixels.
  final EdgeInsets padding;

  /// The size of the whole view (it may be larger than grid plus padding).
  final Size viewSize;

  /// The device pixel ratio of [metrics].
  double get devicePixelRatio => metrics.devicePixelRatio;

  /// The grid's rectangle in local coordinates.
  Rect get gridRect => Rect.fromLTWH(
    padding.left,
    padding.top,
    cols * metrics.width,
    rows * metrics.height,
  );

  /// The top-left corner of the cell at [col], [row] (viewport row) in
  /// local coordinates.
  Offset cellOrigin(int col, int row) => Offset(
    padding.left + col * metrics.width,
    padding.top + row * metrics.height,
  );

  /// The rectangle of [width] cells starting at [col], [row], in local
  /// coordinates.
  Rect cellRect(int col, int row, {int width = 1}) {
    final origin = cellOrigin(col, row);
    return Rect.fromLTWH(
      origin.dx,
      origin.dy,
      width * metrics.width,
      metrics.height,
    );
  }

  /// The viewport cell under [local], clamped to the grid.
  GridPoint viewportCellAt(Offset local) {
    final col = ((local.dx - padding.left) / metrics.width).floor();
    final row = ((local.dy - padding.top) / metrics.height).floor();
    return GridPoint.viewport(
      math.min(math.max(col, 0), cols - 1),
      math.min(math.max(row, 0), rows - 1),
    );
  }

  /// [local] in surface (device) pixels, the record shape
  /// [SelectionGesture] takes.
  ({double x, double y}) toSurface(Offset local) =>
      (x: local.dx * devicePixelRatio, y: local.dy * devicePixelRatio);

  /// The geometry [MouseEncoder] needs, in surface pixels.
  MouseEncoderSize get mouseEncoderSize {
    final width = _px(viewSize.width);
    final height = _px(viewSize.height);
    final left = _px(padding.left);
    final top = _px(padding.top);
    return MouseEncoderSize(
      screenWidth: width,
      screenHeight: height,
      cellWidth: metrics.widthPx,
      cellHeight: metrics.heightPx,
      paddingLeft: left,
      paddingTop: top,
      paddingRight: math.max(0, width - left - cols * metrics.widthPx),
      paddingBottom: math.max(0, height - top - rows * metrics.heightPx),
    );
  }

  /// The geometry [SelectionGesture.drag] needs, in surface pixels.
  SelectionGestureGeometry get selectionGeometry => SelectionGestureGeometry(
    columns: cols,
    cellWidth: metrics.widthPx,
    paddingLeft: _px(padding.left),
    screenHeight: math.max(1, _px(viewSize.height)),
  );

  int _px(double logical) => (logical * devicePixelRatio).round();

  @override
  bool operator ==(Object other) =>
      other is TerminalGeometry &&
      other.metrics == metrics &&
      other.cols == cols &&
      other.rows == rows &&
      other.padding == padding &&
      other.viewSize == viewSize;

  @override
  int get hashCode => Object.hash(metrics, cols, rows, padding, viewSize);

  @override
  String toString() =>
      'TerminalGeometry(${cols}x$rows, $metrics, padding: $padding, '
      'view: $viewSize)';
}
