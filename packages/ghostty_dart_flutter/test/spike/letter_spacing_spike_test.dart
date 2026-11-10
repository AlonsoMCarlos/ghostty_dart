// Spike (ADR 0011 "to measure"): does a paragraph laid out with
// `letterSpacing = cellWidth - advance` advance by exactly cellWidth per
// glyph?
//
// It reads layout metadata (getBoxesForRange, getGlyphInfoAt) in logical
// pixels from flutter_tester's SkParagraph. It says nothing about where
// Impeller, CanvasKit or skwasm rasterise the glyphs; the renderer's own
// tests check that with pixels.
//
// Uses unpinned system fonts, so it is tagged `spike` and excluded from
// `mise run test:flutter` / CI. Run it with `mise run test:spike`.
@Tags(['spike'])
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart_flutter/ghostty_dart_flutter.dart';

import '../support/fonts.dart';

/// The largest allowed distance between a glyph's left edge and its cell.
const _tolerance = 0.5;

const _fontSizes = [9.0, 11.0, 12.0, 13.0, 14.0, 15.5, 17.0, 20.0, 26.0];
const _devicePixelRatios = [1.0, 1.25, 1.5, 1.75, 2.0, 2.625, 3.0];

/// 200 columns of printable ASCII (U+0020-U+007E), spaces included, so the
/// run is as long as a wide terminal row.
final _row = String.fromCharCodes(
  List.generate(200, (i) => 0x20 + (i * 7) % 95),
);

/// Lays [text] out in one paragraph and measures where each glyph starts.
///
/// - `boxes` / `glyphs`: the largest distance between glyph i's left edge
///   and `i * step`, by `getBoxesForRange` and by `getGlyphInfoAt`.
/// - `offset`: glyph 0's left edge (SkParagraph puts half of the letter
///   spacing before each glyph).
/// - `drift`: the largest distance between glyph i's left edge and
///   `offset + i * step`, i.e. the error that grows along the row.
({double boxes, double glyphs, double offset, double drift}) _maxError(
  String text,
  TextStyle style,
  double step,
) {
  final builder =
      ui.ParagraphBuilder(ui.ParagraphStyle(textDirection: TextDirection.ltr))
        ..pushStyle(style.getTextStyle())
        ..addText(text);
  final paragraph = builder.build()
    ..layout(const ui.ParagraphConstraints(width: double.infinity));
  try {
    var boxes = 0.0;
    var glyphs = 0.0;
    var drift = 0.0;
    final offset = paragraph.getBoxesForRange(0, 1).first.left;
    for (var i = 0; i < text.length; i++) {
      final expected = i * step;
      final box = paragraph.getBoxesForRange(i, i + 1).first;
      boxes = math.max(boxes, (box.left - expected).abs());
      drift = math.max(drift, (box.left - offset - expected).abs());
      final glyph = paragraph.getGlyphInfoAt(i)!;
      glyphs = math.max(
        glyphs,
        (glyph.graphemeClusterLayoutBounds.left - expected).abs(),
      );
    }
    return (boxes: boxes, glyphs: glyphs, offset: offset, drift: drift);
  } finally {
    paragraph.dispose();
  }
}

void main() {
  test('letterSpacing = cellWidth - advance keeps ASCII on the grid', () async {
    final families = await loadSystemMonospace();
    final jetBrains = await loadJetBrainsMono();
    if (jetBrains) families.insert(0, jetBrainsMonoFamily);
    if (families.isEmpty) {
      markTestSkipped('no monospace font available on this host');
      return;
    }

    final rows = <String>[];
    var worstSpaced = 0.0;
    var worstFractional = 0.0;
    var worstDrift = 0.0;
    var cases = 0;
    for (final family in families) {
      for (final fontSize in _fontSizes) {
        for (final dpr in _devicePixelRatios) {
          final base = TextStyle(
            fontFamily: family,
            fontSize: fontSize,
            fontFeatures: const [
              FontFeature.disable('liga'),
              FontFeature.disable('calt'),
            ],
          );
          final metrics = VtCellMetrics.measure(base, devicePixelRatio: dpr);
          // Grid-aligned width with letterSpacing (the ADR 0011 plan).
          final spaced = _maxError(
            _row,
            base.copyWith(letterSpacing: metrics.letterSpacing),
            metrics.width,
          );
          // Fallback: fractional cell width, no letterSpacing.
          final fractional = _maxError(_row, base, metrics.advance);
          worstSpaced = math.max(
            worstSpaced,
            math.max(spaced.boxes, spaced.glyphs),
          );
          worstFractional = math.max(
            worstFractional,
            math.max(fractional.boxes, fractional.glyphs),
          );
          worstDrift = math.max(worstDrift, spaced.drift);
          cases++;
          rows.add(
            '| $family | $fontSize | $dpr | '
            '${metrics.advance.toStringAsFixed(4)} | '
            '${metrics.width.toStringAsFixed(4)} | '
            '${metrics.letterSpacing.toStringAsFixed(4)} | '
            '${spaced.boxes.toStringAsFixed(4)} | '
            '${spaced.glyphs.toStringAsFixed(4)} | '
            '${spaced.offset.toStringAsFixed(4)} | '
            '${spaced.drift.toStringAsFixed(4)} | '
            '${fractional.boxes.toStringAsFixed(4)} |',
          );
        }
      }
    }
    // ignore: avoid_print
    print(
      [
        '| font | size | dpr | advance | cell w | letterSpacing | '
            'max err boxes | max err glyphInfo | glyph 0 offset | drift | '
            'fractional max err |',
        '|---|---|---|---|---|---|---|---|---|---|---|',
        ...rows,
        '',
        'cases: $cases, worst letterSpacing error: '
            '${worstSpaced.toStringAsFixed(4)} px, worst fractional-width '
            'error: ${worstFractional.toStringAsFixed(4)} px, worst drift '
            'with letterSpacing: ${worstDrift.toStringAsFixed(4)} px',
      ].join('\n'),
    );
    expect(worstSpaced, lessThanOrEqualTo(_tolerance));
    expect(worstDrift, lessThanOrEqualTo(_tolerance));
  });
}
