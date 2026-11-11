// Highlights (contract 4.2 of the xterm adapter plan, ADR 0013):
// VtTerminalController.addHighlight, VtTerminalHighlight's lifetime, the
// seams' viewport positions, and the renderer's overlay (painted after
// the text and the cursor, outside the row cache).

import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart_flutter/ghostty_dart_flutter.dart';
import 'package:ghostty_dart_flutter/src/seams/controller_seams.dart';

import '../support/fonts.dart';
import 'render_harness.dart';

const _red = Color(0xFFFF0000);
const _blue = Color(0xFF0000FF);

/// The RGBA pixel at the centre of cell [col], [row] of [h]'s grid.
Color _cellPixel(RenderHarness h, Uint8List rgba, int col, int row) {
  final g = h.geometry;
  final dpr = g.devicePixelRatio;
  final width = (g.viewSize.width * dpr).round();
  final x = ((g.padding.left + (col + 0.5) * g.metrics.width) * dpr).floor();
  final y = ((g.padding.top + (row + 0.5) * g.metrics.height) * dpr).floor();
  final i = (y * width + x) * 4;
  return Color.fromARGB(rgba[i + 3], rgba[i], rgba[i + 1], rgba[i + 2]);
}

void main() {
  setUpAll(loadJetBrainsMono);

  group('VtTerminalController.addHighlight', () {
    test('tracks its ends in screen space, in line order', () {
      final controller = VtTerminalController(cols: 10, rows: 3);
      addTearDown(controller.dispose);
      var notified = 0;
      controller.addListener(() => notified++);
      // Given backwards and in another space: normalised.
      final highlight = controller.addHighlight(
        const GridPoint.active(4, 2),
        const GridPoint.viewport(1, 0),
        color: _red,
      );
      expect(notified, 1);
      expect(highlight.controller, same(controller));
      expect(highlight.color, _red);
      expect(highlight.start, const GridPoint.screen(1, 0));
      expect(highlight.end, const GridPoint.screen(4, 2));
      expect(controller.highlights, [highlight]);
      expect(
        () => controller.highlights.add(highlight),
        throwsUnsupportedError,
      );

      // Output scrolls the rows up; the ends stay on their text.
      controller.write('\r\n' * 5);
      expect(highlight.start, const GridPoint.screen(1, 0));
      expect(highlight.end, const GridPoint.screen(4, 2));
    });

    test('keeps creation order; dispose removes, notifies, is idempotent', () {
      final controller = VtTerminalController(cols: 10, rows: 3);
      addTearDown(controller.dispose);
      final a = controller.addHighlight(
        const GridPoint.active(0, 0),
        const GridPoint.active(1, 0),
        color: _red,
      );
      final b = controller.addHighlight(
        const GridPoint.active(0, 1),
        const GridPoint.active(1, 1),
        color: _blue,
      );
      expect(controller.highlights, [a, b]);
      var notified = 0;
      controller.addListener(() => notified++);
      a.dispose();
      a.dispose();
      expect(notified, 1);
      expect(a.isDisposed, isTrue);
      expect(a.start, isNull);
      expect(a.end, isNull);
      expect(controller.highlights, [b]);
    });

    test('rejects points outside the grid and disposed controllers', () {
      final controller = VtTerminalController(cols: 10, rows: 3);
      expect(
        () => controller.addHighlight(
          const GridPoint.active(10, 0),
          const GridPoint.active(1, 0),
          color: _red,
        ),
        throwsRangeError,
      );
      expect(
        () => controller.addHighlight(
          const GridPoint.active(0, 0),
          const GridPoint.active(0, 3),
          color: _red,
        ),
        throwsRangeError,
      );
      expect(controller.highlights, isEmpty);
      final highlight = controller.addHighlight(
        const GridPoint.active(0, 0),
        const GridPoint.active(0, 0),
        color: _red,
      );
      controller.dispose();
      expect(highlight.isDisposed, isTrue);
      expect(highlight.start, isNull);
      highlight.dispose(); // still safe
      expect(
        () => controller.addHighlight(
          const GridPoint.active(0, 0),
          const GridPoint.active(0, 0),
          color: _red,
        ),
        throwsStateError,
      );
      expect(() => controller.highlights, throwsStateError);
    });

    test('a highlight whose text left the scrollback has no ends', () {
      final controller = VtTerminalController(
        cols: 10,
        rows: 3,
        scrollbackMaxLines: 0,
      );
      addTearDown(controller.dispose);
      controller.write('X');
      final highlight = controller.addHighlight(
        const GridPoint.active(0, 0),
        const GridPoint.active(3, 0),
        color: _red,
      );
      // The library prunes whole pages: a few thousand rows.
      for (var i = 0; i < 20 && highlight.start != null; i++) {
        controller.write('line\r\n' * 1000);
      }
      expect(highlight.start, isNull);
      expect(highlight.isDisposed, isFalse);
      expect(ControllerSeams(controller).viewportHighlights(), isEmpty);
    });
  });

  group('viewport positions', () {
    test('follow scrolling of the viewport and of the output', () {
      final controller = VtTerminalController(cols: 10, rows: 3);
      addTearDown(controller.dispose);
      final seams = ControllerSeams(controller);
      controller.addHighlight(
        const GridPoint.active(2, 1),
        const GridPoint.active(5, 2),
        color: _red,
      );
      expect(seams.viewportHighlights(), [
        (color: _red, startX: 2, startY: 1, endX: 5, endY: 2),
      ]);
      // One line of output moves it up one row.
      controller.write('\x1b[3;1H\r\n');
      expect(seams.viewportHighlights(), [
        (color: _red, startX: 2, startY: 0, endX: 5, endY: 1),
      ]);
      // One more: its start is above the viewport, its end on row 0.
      controller.write('\r\n');
      expect(seams.viewportHighlights(), [
        (color: _red, startX: 2, startY: -1, endX: 5, endY: 0),
      ]);
      // Another: it left the viewport.
      controller.write('\r\n');
      expect(seams.viewportHighlights(), isEmpty);
      // Scrolling the viewport back to the top shows it where it began
      // (the tracked ref and the scrollbar agree on screen rows).
      controller.scrollViewport(const ViewportScroll.top());
      final top = controller.terminal
          .gridRef(const GridPoint.viewport(0, 0))!
          .pointIn(PointSpace.screen)!;
      expect(top.y, controller.scrollbar.offset);
      expect(seams.viewportHighlights(), [
        (color: _red, startX: 2, startY: 1, endX: 5, endY: 2),
      ]);
    });

    test('only on the screen it was made on', () {
      final controller = VtTerminalController(cols: 10, rows: 3);
      addTearDown(controller.dispose);
      final seams = ControllerSeams(controller);
      controller.addHighlight(
        const GridPoint.active(0, 0),
        const GridPoint.active(1, 0),
        color: _red,
      );
      controller.write('\x1b[?1049h');
      expect(seams.viewportHighlights(), isEmpty);
      controller.write('\x1b[?1049l');
      expect(seams.viewportHighlights(), hasLength(1));
    });
  });

  group('painting', () {
    testWidgets('fills whole cells over text and cursor, records no row', (
      tester,
    ) async {
      final h = await pumpRenderer(
        tester,
        cols: 6,
        rows: 3,
        initial: 'abcdef\r\nghijkl\r\nmn',
      );
      final before = await h.pixels();
      final recordings = h.render.debugRowRecordings;
      final scans = h.render.debugRowScans;
      // Row 0 from column 4 through row 2 column 2, where the cursor is.
      h.controller.addHighlight(
        const GridPoint.active(4, 0),
        const GridPoint.active(2, 2),
        color: _red,
      );
      await tester.pump();
      expect(h.render.debugRowRecordings, recordings);
      expect(h.render.debugRowScans, scans);
      final rgba = await h.pixels();
      for (var row = 0; row < 3; row++) {
        for (var col = 0; col < 6; col++) {
          final inside =
              (row == 0 && col >= 4) || row == 1 || (row == 2 && col <= 2);
          expect(
            _cellPixel(h, rgba, col, row),
            inside ? _red : _cellPixel(h, before, col, row),
            reason: 'cell ($col, $row)',
          );
        }
      }
    });

    testWidgets('later highlights paint over earlier ones, with alpha', (
      tester,
    ) async {
      final h = await pumpRenderer(tester, cols: 4, rows: 2);
      h.controller.addHighlight(
        const GridPoint.active(0, 0),
        const GridPoint.active(3, 0),
        color: _red,
      );
      final blue = h.controller.addHighlight(
        const GridPoint.active(1, 0),
        const GridPoint.active(1, 0),
        color: const Color(0x800000FF),
      );
      await tester.pump();
      var rgba = await h.pixels();
      expect(_cellPixel(h, rgba, 0, 0), _red);
      final mixed = _cellPixel(h, rgba, 1, 0);
      expect(mixed.r, closeTo(0.5, 0.01));
      expect(mixed.b, closeTo(0.5, 0.01));
      blue.dispose();
      await tester.pump();
      rgba = await h.pixels();
      expect(_cellPixel(h, rgba, 1, 0), _red);
    });

    testWidgets('follows output and stays put while the render is held', (
      tester,
    ) async {
      final h = await pumpRenderer(tester, cols: 4, rows: 3);
      final background = _cellPixel(h, await h.pixels(), 2, 0);
      h.controller.addHighlight(
        const GridPoint.active(0, 2),
        const GridPoint.active(3, 2),
        color: _red,
      );
      await tester.pump();
      expect(_cellPixel(h, await h.pixels(), 2, 2), _red);
      await h.write('\x1b[3;1H\r\n');
      var rgba = await h.pixels();
      expect(_cellPixel(h, rgba, 2, 1), _red);
      expect(_cellPixel(h, rgba, 2, 2), background);
      // While held, the old frame and its highlight positions stay.
      await h.write('\x1b[?2026h\r\n');
      rgba = await h.pixels();
      expect(_cellPixel(h, rgba, 2, 1), _red);
      await h.write('\x1b[?2026l');
      rgba = await h.pixels();
      expect(_cellPixel(h, rgba, 2, 0), _red);
      expect(_cellPixel(h, rgba, 2, 1), background);
    });

    testWidgets('a disposed controller paints none', (tester) async {
      final h = await pumpRenderer(tester, cols: 4, rows: 2);
      h.controller.addHighlight(
        const GridPoint.active(0, 0),
        const GridPoint.active(3, 1),
        color: _red,
      );
      await tester.pump();
      h.controller.dispose();
      h.render.markNeedsPaint();
      await tester.pump();
      expect(_cellPixel(h, await h.pixels(), 0, 0), isNot(_red));
    });
  });
}
