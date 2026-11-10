// Where glyphs land after rasterisation on a real device renderer
// (Impeller on desktop; ADR 0011 "to measure", contract step 2 of the
// letterSpacing spike). The same check as ghostty_dart_flutter's
// test/render/grid_pixel_test.dart, which runs on flutter_tester's software
// rasteriser; this one runs inside the app, on the engine the device uses.
//
// Run it with `mise run test:grid-pixels` (flutter drive on a display;
// `xvfb-run` on a headless Linux machine). For every device pixel ratio and
// font size it paints three 200-column rows of `|` (regular, bold, italic)
// through VtTerminalView, reads the pixels back with `toImage`, and checks
// that the first lit device pixel of every cell is at
// `col * widthPx + constant`, within one device pixel.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart_flutter/ghostty_dart_flutter.dart';
import 'package:ghostty_dart_widget_benchmarks/src/report.dart';
import 'package:integration_test/integration_test.dart';

/// Directory with the JetBrains Mono TTFs (`--dart-define=BENCH_FONT_DIR`).
const _fontDir = String.fromEnvironment('BENCH_FONT_DIR');

const _fontFamily = 'JetBrains Mono';
const _cols = 200;
const _rows = 3;

Future<void> _loadFont() async {
  if (_fontDir.isEmpty) {
    fail('BENCH_FONT_DIR is not set: run `mise run test:grid-pixels`.');
  }
  final loader = FontLoader(_fontFamily);
  for (final face in const ['Regular', 'Bold', 'Italic', 'BoldItalic']) {
    final file = File('$_fontDir/JetBrainsMono-$face.ttf');
    if (!file.existsSync()) fail('missing font file ${file.path}');
    loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
  }
  await loader.load();
}

/// The first lit device pixel of every cell of every row (`-1`: none).
List<List<int>> _firstLitPixels(
  ByteData rgba,
  int imageWidth,
  VtCellMetrics metrics,
) {
  final widthPx = metrics.widthPx;
  final heightPx = metrics.heightPx;
  return [
    for (var row = 0; row < _rows; row++)
      [
        for (var col = 0; col < _cols; col++)
          () {
            for (var x = col * widthPx; x < (col + 1) * widthPx; x++) {
              for (var y = row * heightPx; y < (row + 1) * heightPx; y++) {
                // Red channel: the default theme draws #CCCCCC on #1E1E1E.
                if (rgba.getUint8((y * imageWidth + x) * 4) > 0x70) {
                  return x - col * widthPx;
                }
              }
            }
            return -1;
          }(),
      ],
  ];
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final results = <String>[];

  setUpAll(_loadFont);
  tearDownAll(() {
    binding.reportData = {'grid_pixels': results};
  });

  for (final dpr in [1.0, 1.5, 2.0, 3.0]) {
    for (final fontSize in [11.0, 13.0, 15.5]) {
      testWidgets('glyphs stay on the device-pixel grid at dpr $dpr, '
          'size $fontSize', (tester) async {
        tester.view.devicePixelRatio = dpr;
        addTearDown(tester.view.resetDevicePixelRatio);
        final style = TextStyle(fontFamily: _fontFamily, fontSize: fontSize);
        final metrics = VtCellMetrics.measure(style, devicePixelRatio: dpr);
        final controller = VtTerminalController(cols: _cols, rows: _rows);
        addTearDown(controller.dispose);
        final key = GlobalKey();

        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            home: OverflowBox(
              alignment: Alignment.topLeft,
              minWidth: 0,
              maxWidth: double.infinity,
              minHeight: 0,
              maxHeight: double.infinity,
              child: RepaintBoundary(
                key: key,
                child: VtTerminalView(
                  controller: controller,
                  textStyle: style,
                  autoResize: false,
                ),
              ),
            ),
          ),
        );
        controller.write(
          '${'|' * _cols}\x1b[1m${'|' * _cols}'
          '\x1b[0;3m${'|' * _cols}\x1b[?25l',
        );
        // The frame that draws the rows is traced, so the result names the
        // renderer that drew it (Impeller or Skia, from the event names).
        final timeline = await binding.traceTimeline(
          tester.pumpAndSettle,
          streams: const ['Embedder'],
        );
        final renderer = rendererOf([
          for (final event in timeline.traceEvents!)
            if (event.json case final json?) json.cast<String, Object?>(),
        ]);

        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: dpr);
        final ByteData rgba;
        try {
          rgba = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
        } finally {
          image.dispose();
        }
        expect(
          image.width,
          greaterThanOrEqualTo(metrics.widthPx * _cols),
          reason: 'the image holds every column',
        );
        final rows = _firstLitPixels(rgba, image.width, metrics);

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
        final line =
            '$renderer, dpr $dpr size $fontSize: cell ${metrics.widthPx} px, '
            'letterSpacing ${metrics.letterSpacing.toStringAsFixed(4)}, '
            'max |first lit - (col*w + c)| = $worst px, '
            'drift at col ${_cols - 1} = $drift px';
        results.add(line);
        // ignore: avoid_print, the driver's console is the report.
        print('grid_pixels: $line');
        expect(worst, lessThanOrEqualTo(1), reason: line);
      });
    }
  }
}
