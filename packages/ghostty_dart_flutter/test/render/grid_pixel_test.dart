// Where glyphs land after rasterisation (ADR 0011 "to measure"; the
// layout-only spike is test/spike/letter_spacing_spike_test.dart).
//
// Paints 200-column rows of `|` in the regular, bold and italic faces of the
// bundled JetBrains Mono through the real renderer, reads the pixels back,
// and checks that the first lit device pixel of every cell is at
// `col * widthPx + constant`, within one device pixel. This is the check on
// flutter_tester's software rasteriser; Impeller and the web renderers need
// the same check on a real device or browser.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fonts.dart';
import 'render_harness.dart';

const _cols = 200;

/// The first lit device pixel of every cell of every row.
Future<List<List<int>>> _firstLitPixels(
  WidgetTester tester,
  RenderHarness h,
  int rows, {
  int cols = _cols,
}) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(terminalKey),
  );
  final dpr = h.geometry.devicePixelRatio;
  final bytes = (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: dpr);
    try {
      return await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    } finally {
      image.dispose();
    }
  }))!;
  final widthPx = h.geometry.metrics.widthPx;
  final heightPx = h.geometry.metrics.heightPx;
  final imageWidth = (h.geometry.viewSize.width * dpr).round();
  final result = <List<int>>[];
  for (var row = 0; row < rows; row++) {
    final firsts = <int>[];
    for (var col = 0; col < cols; col++) {
      var first = -1;
      // Scan the cell's columns left to right, every pixel row of the cell.
      for (var x = col * widthPx; x < (col + 1) * widthPx && first < 0; x++) {
        for (var y = row * heightPx; y < (row + 1) * heightPx; y++) {
          // Red channel: the default theme draws #CCCCCC on #1E1E1E.
          if (bytes.getUint8((y * imageWidth + x) * 4) > 0x70) {
            first = x - col * widthPx;
            break;
          }
        }
      }
      firsts.add(first);
    }
    result.add(firsts);
  }
  return result;
}

void main() {
  setUpAll(() async {
    if (!skipWithoutBundledFonts) await requireJetBrainsMono();
  });

  for (final dpr in [1.0, 1.5, 2.0, 3.0]) {
    for (final fontSize in [11.0, 13.0, 15.5]) {
      testWidgets(
        'glyphs stay on the device-pixel grid at dpr $dpr, size $fontSize',
        (tester) async {
          final style = gridStyle.copyWith(fontSize: fontSize);
          // Rows 0-2: one run each (regular, bold, italic). Row 3: 25 runs
          // of 8 cells, regular and bold in light colours, laid out as one
          // row paragraph.
          final mixed = [
            for (var i = 0; i < _cols ~/ 8; i++)
              '\x1b[0;${const ['', '1', '93', '1;97'][i % 4]}m${'|' * 8}',
          ].join();
          final h = await pumpRenderer(
            tester,
            cols: _cols,
            rows: 4,
            devicePixelRatio: dpr,
            textStyle: style,
            initial:
                '${'|' * _cols}\x1b[1m${'|' * _cols}'
                '\x1b[0;3m${'|' * _cols}$mixed\x1b[?25l',
          );
          final rows = await _firstLitPixels(tester, h, 4);
          var worst = 0;
          var drift = 0;
          for (final (index, firsts) in rows.indexed) {
            expect(firsts, isNot(contains(-1)), reason: 'row $index');
            final constant = firsts.first;
            for (final first in firsts) {
              worst = math.max(worst, (first - constant).abs());
            }
            drift = math.max(drift, (firsts.last - constant).abs());
          }
          expect(
            worst,
            lessThanOrEqualTo(1),
            reason:
                'dpr $dpr size $fontSize cell ${h.geometry.metrics.widthPx} px, '
                'letterSpacing ${h.geometry.metrics.letterSpacing}: max '
                '|first lit - (col*w + c)| = $worst px, drift at col 199 = '
                '$drift px',
          );
        },
        skip: skipWithoutBundledFonts,
      );
    }
  }

  testWidgets('a run from a font with another advance is placed cell by cell', (
    tester,
  ) async {
    // The cells are measured with JetBrains Mono, but the text style is
    // the test framework's FlutterTest font, whose glyphs are one em wide
    // (13 px against an 8 px cell). The run "a a a …" measures off the
    // grid, so it is drawn per cell, each glyph scaled into its cell:
    // letters light their own cells and the blanks between them stay
    // dark. Drawn as one run, the letters would drift over the blanks.
    const cols = 24;
    final h = await pumpRenderer(
      tester,
      cols: cols,
      rows: 1,
      initial: '${List.filled(cols ~/ 2, 'a').join(' ')}\x1b[?25l',
    );
    await h.rebuild(textStyle: gridStyle.copyWith(fontFamily: 'FlutterTest'));
    final firsts = (await _firstLitPixels(tester, h, 1, cols: cols)).single;
    for (var col = 0; col < cols - 1; col++) {
      if (col.isEven) {
        expect(firsts[col], firsts[0], reason: 'letter cell $col: $firsts');
      } else {
        expect(firsts[col], -1, reason: 'blank cell $col: $firsts');
      }
    }
  }, skip: skipWithoutBundledFonts);

  testWidgets('an off-grid row of several runs is placed cell by cell', (
    tester,
  ) async {
    // As above, with a style change every other letter: the row paragraph
    // measures off the grid, so the row falls back to its runs, which
    // fall back to cells.
    const cols = 24;
    final h = await pumpRenderer(
      tester,
      cols: cols,
      rows: 1,
      initial:
          '${List.generate(cols ~/ 2, (i) => i.isEven ? 'a' : '\x1b[1ma\x1b[0m').join(' ')}'
          '\x1b[?25l',
    );
    await h.rebuild(textStyle: gridStyle.copyWith(fontFamily: 'FlutterTest'));
    final firsts = (await _firstLitPixels(tester, h, 1, cols: cols)).single;
    for (var col = 0; col < cols - 1; col++) {
      if (col.isEven) {
        expect(
          (firsts[col] - firsts[0]).abs(),
          lessThanOrEqualTo(1),
          reason: 'letter cell $col: $firsts',
        );
      } else {
        expect(firsts[col], -1, reason: 'blank cell $col: $firsts');
      }
    }
  }, skip: skipWithoutBundledFonts);

  testWidgets(
    'box drawing joins without seams',
    (tester) async {
      // At 11 px a JetBrains Mono glyph advances 6.6 px in a 7 px cell. A
      // centred "─" would leave 0.2 px gaps at both cell edges, which
      // antialias into a dimmer pixel column at every cell boundary; the
      // renderer stretches box drawing to the cell instead.
      const cols = 40;
      final h = await pumpRenderer(
        tester,
        cols: cols,
        rows: 1,
        textStyle: gridStyle.copyWith(fontSize: 11),
        initial: '${'─' * cols}\x1b[?25l',
      );
      final bytes = await h.pixels();
      final width = (h.geometry.viewSize.width).round();
      final height = h.geometry.metrics.heightPx;
      // Exact raster values: Linux only, like the goldens (`golden` tag).
      // The pixel row where the line is brightest.
      var lineY = 0;
      var best = -1;
      for (var y = 0; y < height; y++) {
        final red = bytes[(y * width + width ~/ 2) * 4];
        if (red > best) {
          best = red;
          lineY = y;
        }
      }
      final dimmest = [
        for (var x = 0; x < cols * h.geometry.metrics.widthPx; x++)
          bytes[(lineY * width + x) * 4],
      ].reduce(math.min);
      // Measured 2026-11-10 (flutter_tester, Linux): stretched 195 / 190,
      // centred 186 / 177. The stretched glyph still antialiases a little
      // at its own ends, hence the small allowance.
      expect(
        dimmest,
        greaterThanOrEqualTo(best - 6),
        reason: 'line brightness $best, dimmest $dimmest',
      );
    },
    tags: ['golden'],
    skip: skipWithoutBundledFonts,
  );

  testWidgets(
    'vertical box drawing does not overdraw at row joins',
    (tester) async {
      // A "│" taller than its cell used to spill into the rows above and
      // below; the antialiased overlap drew a brighter dot at every row
      // boundary. Each cluster is clipped to its cell now.
      for (final size in [11.0, 13.0, 22.0]) {
        const rows = 8;
        final h = await pumpRenderer(
          tester,
          cols: 1,
          rows: rows,
          textStyle: gridStyle.copyWith(fontSize: size),
          initial: '${List.filled(rows, '│').join('\r\n')}\x1b[?25l',
        );
        final bytes = await h.pixels();
        final width = (h.geometry.viewSize.width).round();
        final cellHeight = h.geometry.metrics.heightPx;
        // The brightest pixel column in the middle of the first cell.
        var lineX = 0;
        var best = -1;
        for (var x = 0; x < width; x++) {
          final red = bytes[(cellHeight ~/ 2 * width + x) * 4];
          if (red > best) {
            best = red;
            lineX = x;
          }
        }
        final column = [
          for (var y = 0; y < rows * cellHeight; y++)
            bytes[(y * width + lineX) * 4],
        ];
        expect(
          column.reduce(math.max) - column.reduce(math.min),
          lessThanOrEqualTo(2),
          reason: 'font size $size: line column $lineX, values $column',
        );
      }
    },
    tags: ['golden'],
    skip: skipWithoutBundledFonts,
  );
}
