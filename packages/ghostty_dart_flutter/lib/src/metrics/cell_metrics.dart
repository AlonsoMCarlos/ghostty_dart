import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// The size of one terminal cell, aligned to device pixels, and where the
/// text baseline sits in it.
///
/// Every value is in logical pixels, and [width], [height] and [baseline]
/// are whole multiples of `1 / devicePixelRatio`, so cell edges never fall
/// between device pixels (no seams between background rectangles, no blurry
/// glyph edges). [widthPx] and [heightPx] are the same cell in device
/// pixels: the view passes them to `VtTerminal.resize` and the mouse
/// encoder.
///
/// ```dart
/// final metrics = VtCellMetrics.measure(
///   const TextStyle(fontFamily: 'JetBrains Mono', fontSize: 14),
///   devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
/// );
/// final cols = (constraints.maxWidth / metrics.width).floor();
/// ```
@immutable
final class VtCellMetrics {
  /// Creates metrics from already aligned values. Prefer [aligned] or
  /// [measure], which do the alignment.
  ///
  /// [width] and [height] must be positive and [devicePixelRatio] greater
  /// than zero.
  const VtCellMetrics({
    required this.width,
    required this.height,
    required this.baseline,
    required this.advance,
    required this.devicePixelRatio,
  }) : assert(width > 0),
       assert(height > 0),
       assert(devicePixelRatio > 0);

  /// Aligns raw font metrics to the device pixel grid.
  ///
  /// - [advance] is the font's horizontal advance of one narrow glyph.
  ///   [width] is that advance rounded to the nearest device pixel (at
  ///   least one device pixel).
  /// - [ascent] and [descent] are the font's line metrics (both positive).
  ///   [height] is `(ascent + descent) * lineHeight` rounded up to a whole
  ///   device pixel, and the extra space is split evenly above and below
  ///   the text, as [TextLeadingDistribution.even] does.
  /// - [baseline] is the distance from the top of the cell to the baseline,
  ///   rounded to the nearest device pixel.
  factory VtCellMetrics.aligned({
    required double advance,
    required double ascent,
    required double descent,
    required double devicePixelRatio,
    double lineHeight = 1.0,
  }) {
    if (!(devicePixelRatio > 0) || !devicePixelRatio.isFinite) {
      throw ArgumentError.value(
        devicePixelRatio,
        'devicePixelRatio',
        'must be a positive finite number',
      );
    }
    if (!(advance > 0) || !(ascent + descent > 0) || !(lineHeight > 0)) {
      throw ArgumentError(
        'advance, ascent + descent and lineHeight must be positive '
        '(advance: $advance, ascent: $ascent, descent: $descent, '
        'lineHeight: $lineHeight)',
      );
    }
    final dpr = devicePixelRatio;
    final widthPx = math.max(1, (advance * dpr).round());
    final heightPx = math.max(
      1,
      ((ascent + descent) * lineHeight * dpr).ceil(),
    );
    final height = heightPx / dpr;
    final leading = height - (ascent + descent);
    final baselinePx = ((leading / 2 + ascent) * dpr).round();
    return VtCellMetrics(
      width: widthPx / dpr,
      height: height,
      baseline: baselinePx / dpr,
      advance: advance,
      devicePixelRatio: dpr,
    );
  }

  /// Measures [style]'s font and returns metrics aligned for
  /// [devicePixelRatio].
  ///
  /// The advance is the average advance of a run of 100 `M`s, so
  /// fractional rounding in the engine averages out; ascent and descent
  /// come from the line metrics of the same run. [lineHeight] multiplies
  /// the natural line height (1.0 by default). [textScaler] is applied to
  /// the font size first.
  ///
  /// Needs the Flutter engine (`dart:ui` text layout), so it works in apps
  /// and in `flutter test`, not in plain Dart.
  static VtCellMetrics measure(
    TextStyle style, {
    required double devicePixelRatio,
    TextScaler textScaler = TextScaler.noScaling,
    double lineHeight = 1.0,
  }) {
    const sample = 100;
    final builder =
        ui.ParagraphBuilder(ui.ParagraphStyle(textDirection: TextDirection.ltr))
          ..pushStyle(
            style
                .copyWith(height: null, letterSpacing: 0, wordSpacing: 0)
                .getTextStyle(textScaler: textScaler),
          )
          ..addText('M' * sample);
    final paragraph = builder.build()
      ..layout(const ui.ParagraphConstraints(width: double.infinity));
    try {
      final line = paragraph.computeLineMetrics().first;
      return VtCellMetrics.aligned(
        advance: paragraph.maxIntrinsicWidth / sample,
        ascent: line.ascent,
        descent: line.descent,
        devicePixelRatio: devicePixelRatio,
        lineHeight: lineHeight,
      );
    } finally {
      paragraph.dispose();
    }
  }

  /// The cell width in logical pixels, a whole number of device pixels.
  final double width;

  /// The cell height in logical pixels, a whole number of device pixels.
  final double height;

  /// The distance from the top of the cell to the text baseline, in logical
  /// pixels, a whole number of device pixels.
  final double baseline;

  /// The font's natural advance of one narrow glyph, in logical pixels
  /// (not aligned).
  final double advance;

  /// The device pixel ratio these metrics are aligned for.
  final double devicePixelRatio;

  /// The letter spacing that makes a run of glyphs advance by exactly
  /// [width] per glyph: `width - advance`.
  double get letterSpacing => width - advance;

  /// The cell width in device pixels.
  int get widthPx => (width * devicePixelRatio).round();

  /// The cell height in device pixels.
  int get heightPx => (height * devicePixelRatio).round();

  /// The cell size in logical pixels.
  Size get size => Size(width, height);

  @override
  bool operator ==(Object other) =>
      other is VtCellMetrics &&
      other.width == width &&
      other.height == height &&
      other.baseline == baseline &&
      other.advance == advance &&
      other.devicePixelRatio == devicePixelRatio;

  @override
  int get hashCode =>
      Object.hash(width, height, baseline, advance, devicePixelRatio);

  @override
  String toString() =>
      'VtCellMetrics(${width}x$height, baseline: $baseline, '
      'advance: $advance, dpr: $devicePixelRatio)';
}
