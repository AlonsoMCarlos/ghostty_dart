// Behaviour of the renderer (ADR 0011 "Rendering (v1)"): the row picture
// cache, the render hold, disposal, the cursor overlay and its blink.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart_flutter/ghostty_dart_flutter.dart';
import 'package:ghostty_dart_flutter/src/render/terminal_render.dart';
import 'package:ghostty_dart_flutter/src/seams/controller_seams.dart';
import 'package:ghostty_dart_flutter/src/seams/terminal_geometry.dart';
import 'package:ghostty_dart_flutter/src/seams/terminal_seams.dart';

import '../support/fonts.dart';
import 'render_harness.dart';

/// A frame source that counts [updateFrame] calls.
class _CountingSource extends Fake implements TerminalFrameSource {
  _CountingSource(this.inner);

  final ControllerSeams inner;
  int updates = 0;

  @override
  bool get isDisposed => inner.isDisposed;
  @override
  VtTerminalTheme get theme => inner.theme;
  @override
  bool get isRenderHeld => inner.isRenderHeld;
  @override
  RenderState updateFrame() {
    updates++;
    return inner.updateFrame();
  }

  @override
  void endFrame() => inner.endFrame();
  @override
  List<ViewportHighlight> viewportHighlights() => inner.viewportHighlights();
  @override
  void painted({required bool flooded}) => inner.painted(flooded: flooded);
  @override
  void addListener(VoidCallback listener) => inner.addListener(listener);
  @override
  void removeListener(VoidCallback listener) => inner.removeListener(listener);
}

void main() {
  setUpAll(loadJetBrainsMono);

  group('row picture cache', () {
    testWidgets('the first frame records each distinct row once', (
      tester,
    ) async {
      // "hello", "world" and one picture shared by the three blank rows.
      final h = await pumpRenderer(tester, initial: 'hello\r\nworld');
      expect(h.render.debugRowRecordings, 3);
      expect(h.render.debugCachedRows, 5);
      expect(h.render.debugCachedPictures, 3);
      expect(h.render, paintsExactlyCountTimes(#drawPicture, 5));
    });

    testWidgets('frames without changes record nothing', (tester) async {
      final h = await pumpRenderer(tester, initial: 'hello\r\nworld');
      final recorded = h.render.debugRowRecordings;
      for (var i = 0; i < 5; i++) {
        h.render.markNeedsPaint();
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(h.render.debugRowRecordings, recorded);
    });

    testWidgets('a change to one row records that row only', (tester) async {
      final h = await pumpRenderer(tester, initial: 'one\r\ntwo\r\nthree');
      final recorded = h.render.debugRowRecordings;
      final scanned = h.render.debugRowScans;
      await h.write('!'); // the cursor stays on row 2
      expect(h.render.debugRowRecordings, recorded + 1);
      expect(h.render.debugRowScans, scanned + 1);
      // Row 0 changes. libghostty also flags row 2 (the cursor left and
      // re-entered it): it is scanned, but its content is unchanged, so
      // its picture is kept.
      await h.write('\x1b[1;1HX\x1b[3;6H');
      expect(h.render.debugRowRecordings, recorded + 2);
      expect(h.render.debugRowScans, scanned + 3);
    });

    testWidgets('a cursor move records only the rows libghostty flags', (
      tester,
    ) async {
      final h = await pumpRenderer(tester, initial: 'one\r\ntwo');
      final recorded = h.render.debugRowRecordings;
      final scanned = h.render.debugRowScans;
      await h.write('\x1b[1;1H');
      await h.write('\x1b[4;10H');
      // libghostty flags the rows the cursor left and entered (1 and 0,
      // then 0 and 3); they are scanned, none is recorded.
      expect(h.render.debugRowScans, scanned + 4);
      expect(h.render.debugRowRecordings, recorded);
      await h.write('\x1b[4;11H');
      final afterMoves = h.render.debugRowRecordings;
      h.render.markNeedsPaint();
      await tester.pump();
      expect(h.render.debugRowRecordings, afterMoves);
    });

    testWidgets('only the visible rows stay cached', (tester) async {
      final h = await pumpRenderer(tester);
      await h.write(List.generate(30, (i) => 'line $i').join('\r\n'));
      expect(h.render.debugCachedRows, 5);
      h.controller.scrollViewport(const ViewportScroll.top());
      await tester.pump();
      expect(h.render.debugCachedRows, 5);
    });

    testWidgets('a theme change re-records only rows it changes', (
      tester,
    ) async {
      // The theme reaches rows only through the selection colour; the
      // default colours it pushes into the terminal are colour changes.
      final h = await pumpRenderer(tester, initial: 'hello\r\nworld');
      h.seams.selection = h.seams.terminal.selectRange(
        const GridPoint.viewport(0, 1),
        const GridPoint.viewport(2, 1),
      );
      await tester.pump();
      final recorded = h.render.debugRowRecordings;
      final misses = h.render.debugParagraphs.misses;
      h.controller.theme = VtTerminalTheme.defaultTheme.copyWith(
        selection: const Color(0x8000FF00),
      );
      await tester.pump();
      expect(h.render.debugRowRecordings, recorded + 1);
      expect(h.render.debugParagraphs.misses, misses);
    });

    testWidgets('a text style change drops every picture and paragraph', (
      tester,
    ) async {
      final h = await pumpRenderer(
        tester,
        initial: 'hello',
        textRendering: VtTextRendering.paragraphs,
      );
      final recorded = h.render.debugRowRecordings;
      final style = gridStyle.copyWith(fontSize: 14);
      await h.rebuild(
        textStyle: style,
        geometry: TerminalGeometry(
          metrics: VtCellMetrics.measure(style, devicePixelRatio: 1),
          cols: 20,
          rows: 5,
        ),
      );
      // "hello" and the blank rows' picture.
      expect(h.render.debugRowRecordings, recorded + 2);
      expect(h.render.debugParagraphs.misses, 1); // "hello", laid out again
    });

    testWidgets('a text scaler change drops every picture', (tester) async {
      final h = await pumpRenderer(tester, initial: 'hello');
      final recorded = h.render.debugRowRecordings;
      await h.rebuild(textScaler: const TextScaler.linear(2));
      expect(h.render.debugRowRecordings, recorded + 2);
    });

    testWidgets('a metrics change drops every picture', (tester) async {
      final h = await pumpRenderer(tester, initial: 'hello');
      final recorded = h.render.debugRowRecordings;
      final metrics = VtCellMetrics.measure(gridStyle, devicePixelRatio: 2);
      await h.rebuild(
        geometry: TerminalGeometry(metrics: metrics, cols: 20, rows: 5),
      );
      expect(h.render.debugRowRecordings, recorded + 2);
    });

    testWidgets('a padding change records nothing', (tester) async {
      final h = await pumpRenderer(tester, initial: 'hello');
      final recorded = h.render.debugRowRecordings;
      await h.rebuild(
        geometry: TerminalGeometry(
          metrics: h.geometry.metrics,
          cols: 20,
          rows: 5,
          padding: const EdgeInsets.all(4),
        ),
      );
      expect(h.render.debugRowRecordings, recorded);
    });

    testWidgets('reverse video (DECSCNM) re-scans although no row is dirty', (
      tester,
    ) async {
      // libghostty-vt 1.0.0 reports DECSCNM as a colour change with a clean
      // dirty state, so the renderer must watch the colours itself. Only
      // the row with text looks different; empty rows show the default
      // background, which the view fills.
      final h = await pumpRenderer(tester, initial: 'hello');
      final recorded = h.render.debugRowRecordings;
      final scanned = h.render.debugRowScans;
      await h.write('\x1b[?5h');
      expect(h.render.debugRowScans, scanned + 5);
      expect(h.render.debugRowRecordings, recorded + 1);
    });

    testWidgets('OSC 11 changes the fill, not the rows', (tester) async {
      final h = await pumpRenderer(tester, initial: 'hello');
      final recorded = h.render.debugRowRecordings;
      await h.write('\x1b]11;rgb:10/20/30\x07');
      expect(h.render.debugRowRecordings, recorded);
      expect(h.render, paints..rect(color: const Color(0xFF102030)));
    });

    testWidgets('OSC 10 re-records the rows with default-coloured text', (
      tester,
    ) async {
      final h = await pumpRenderer(tester, initial: 'hello\r\n\x1b[31mred');
      final recorded = h.render.debugRowRecordings;
      await h.write('\x1b]10;rgb:ff/ff/00\x07');
      expect(h.render.debugRowRecordings, recorded + 1);
    });

    testWidgets('OSC 4 re-records the rows that use the entry', (tester) async {
      final h = await pumpRenderer(tester, initial: 'hello\r\n\x1b[31mred');
      final recorded = h.render.debugRowRecordings;
      await h.write('\x1b]4;1;rgb:00/ff/00\x07');
      expect(h.render.debugRowRecordings, recorded + 1);
    });

    testWidgets('OSC 12 (cursor colour) scans no row', (tester) async {
      final h = await pumpRenderer(tester, initial: 'hello');
      final scanned = h.render.debugRowScans;
      await h.write('\x1b]12;rgb:00/ff/00\x07');
      expect(h.render.debugRowScans, scanned);
    });

    testWidgets('a column-count change re-scans every row', (tester) async {
      final h = await pumpRenderer(tester, initial: 'hello\r\nworld');
      final scanned = h.render.debugRowScans;
      await h.resize(30, 5);
      expect(h.render.debugRowScans, scanned + 5);
      expect(h.render.debugCachedRows, 5);
    });

    testWidgets('scrolling 60 rows by one line records one row', (
      tester,
    ) async {
      final h = await pumpRenderer(
        tester,
        cols: 80,
        rows: 60,
        initial: List.generate(
          120,
          (i) => '\x1b[3${i % 8}mline $i ${'x' * (i % 50)}\x1b[0m',
        ).join('\r\n'),
      );
      var recorded = h.render.debugRowRecordings;
      var scanned = h.render.debugRowScans;
      // Output that scrolls (libghostty flags all 60 rows dirty).
      await h.write('\r\nline 120');
      expect(h.render.debugRowScans, scanned + 60);
      expect(h.render.debugRowRecordings, recorded + 1);

      // The viewport scrolled back by one line: the row that comes back
      // was shown a frame ago, so its picture is still in the cache.
      recorded = h.render.debugRowRecordings;
      scanned = h.render.debugRowScans;
      final hits = h.render.debugPictureHits;
      h.controller.scrollViewport(const ViewportScroll.delta(-1));
      await tester.pump();
      expect(h.render.debugRowScans, scanned + 60);
      expect(h.render.debugRowRecordings, recorded);
      expect(h.render.debugPictureHits, hits + 1);
    });

    testWidgets('a full-screen stream of repeated screens records each '
        'row once', (tester) async {
      // Every row is rewritten each frame, cycling through three screens
      // (the warm full-screen benchmark in small): after the first cycle
      // every row comes from the content cache.
      final h = await pumpRenderer(tester, cols: 20, rows: 5);
      String screen(int n) => [
        for (var row = 0; row < 5; row++)
          '\x1b[${row + 1};1H\x1b[3${(n + row) % 8}mscreen $n\x1b[1m'
              ' row $row\x1b[0m',
      ].join();
      final recorded = h.render.debugRowRecordings;
      for (var n = 0; n < 3; n++) {
        await h.write(screen(n));
      }
      expect(h.render.debugRowRecordings, recorded + 15);
      final hits = h.render.debugPictureHits;
      for (var cycle = 0; cycle < 4; cycle++) {
        for (var n = 0; n < 3; n++) {
          await h.write(screen(n));
        }
      }
      expect(h.render.debugRowRecordings, recorded + 15);
      expect(h.render.debugPictureHits, hits + 4 * 15);
    });

    testWidgets('a redraw shifted by one line records one row', (tester) async {
      // A program that scrolls by redrawing every line one row up (no
      // scroll region): the moved rows' content was just on screen.
      final h = await pumpRenderer(tester, cols: 20, rows: 5);
      String lines(int first) => [
        for (var row = 0; row < 5; row++)
          '\x1b[${row + 1};1H\x1b[2K\x1b[3${(first + row) % 8}mline'
              ' ${first + row}\x1b[0m',
      ].join();
      await h.write(lines(0));
      final recorded = h.render.debugRowRecordings;
      await h.write(lines(1));
      expect(h.render.debugRowRecordings, recorded + 1);
    });

    testWidgets('rows that scrolled away leave the row map', (tester) async {
      // Blank lines share one picture with the blank rows still on screen;
      // their ids must still leave the map once they scroll out.
      final h = await pumpRenderer(tester, cols: 20, rows: 5);
      for (var i = 0; i < 200; i++) {
        await h.write('line $i\r\n\r\n');
        expect(h.render.debugCachedRows, lessThanOrEqualTo(5));
      }
    });

    testWidgets('a row that stayed on screen is evicted last', (tester) async {
      // Row 0 shows the same status line for many frames while rows 1-4
      // churn through new content and the cache evicts. Once the status
      // line changes, its old picture is recent, not the oldest.
      // Paragraphs: the atlas would take most of this small budget.
      final h = await pumpRenderer(
        tester,
        cols: 20,
        rows: 5,
        cacheBudget: 160 << 10,
        textRendering: VtTextRendering.paragraphs,
      );
      Future<void> churn(int frame) => h.write(
        [
          for (var row = 2; row <= 5; row++)
            '\x1b[$row;1H\x1b[2Kframe $frame row $row',
        ].join(),
      );
      await h.write('\x1b[1;1Hstatus: ok');
      for (var frame = 0; frame < 60; frame++) {
        await churn(frame);
      }
      final recorded = h.render.debugRowRecordings;
      expect(h.render.debugCachedPictures, lessThan(60 * 4));
      await h.write('\x1b[1;1H\x1b[2Kstatus: busy');
      await churn(60);
      await h.write('\x1b[1;1H\x1b[2Kstatus: ok');
      // "status: busy" and frame 60's rows were recorded; "status: ok"
      // came back from the cache.
      expect(h.render.debugRowRecordings, recorded + 5);
    });

    testWidgets('detaching releases the caches', (tester) async {
      final h = await pumpRenderer(tester, initial: 'hello');
      final key = GlobalKey();
      await h.rebuild(
        wrap: (view) => KeyedSubtree(key: key, child: view),
      );
      final render = h.render;
      expect(render.debugCachedPictures, greaterThan(0));
      // Move the subtree: the render box is detached and reattached.
      await h.rebuild(
        wrap: (view) => Padding(
          padding: EdgeInsets.zero,
          child: KeyedSubtree(key: key, child: view),
        ),
      );
      expect(h.render, same(render));
      expect(render.debugCachedPictures, 0);
      expect(render.debugParagraphs.length, 0);
      // The next change records the screen again.
      final recorded = render.debugRowRecordings;
      await h.write('!');
      expect(render.debugRowRecordings, recorded + 2);
    });

    testWidgets('a hidden view releases its caches', (tester) async {
      // As IndexedStack and Navigator hide a child: offstage, tickers off.
      Widget Function(Widget) visibility(bool visible) =>
          (view) =>
              Visibility(visible: visible, maintainState: true, child: view);
      final h = await pumpRenderer(tester, initial: 'hello');
      await h.rebuild(wrap: visibility(true));
      final render = h.render;
      expect(render.debugCachedPictures, 2);
      await h.rebuild(wrap: visibility(false));
      expect(render.attached, isTrue);
      expect(render.blinkEnabled, isFalse);
      await tester.pump(RenderTerminal.hiddenReleaseDelay);
      expect(render.debugCachedPictures, 0);
      expect(render.debugParagraphs.length, 0);
      await h.rebuild(wrap: visibility(true));
      expect(h.render, same(render));
      expect(render.debugCachedPictures, 2);
    });

    testWidgets('a muted view still on screen keeps its caches', (
      tester,
    ) async {
      // TickerMode off around a subtree that is still painted (a route
      // transition, paused animations).
      Widget Function(Widget) tickers(bool enabled) =>
          (view) => TickerMode(enabled: enabled, child: view);
      final h = await pumpRenderer(tester, initial: 'hello');
      await h.rebuild(wrap: tickers(true));
      final render = h.render;
      await h.rebuild(wrap: tickers(false));
      expect(render.blinkEnabled, isFalse);
      await tester.pump(RenderTerminal.hiddenReleaseDelay * 2);
      expect(render.debugCachedPictures, 2);
      final recorded = render.debugRowRecordings;
      await h.rebuild(wrap: tickers(true));
      expect(render.debugRowRecordings, recorded);
    });

    testWidgets('memory pressure keeps only the visible pictures', (
      tester,
    ) async {
      final h = await pumpRenderer(
        tester,
        initial: 'hello',
        textRendering: VtTextRendering.paragraphs,
      );
      await h.write('\x1b[1;1Hworld');
      await h.write('\x1b[1;1Hagain');
      expect(h.render.debugCachedPictures, 4); // hello, world, again, blank
      expect(h.render.debugParagraphs.length, greaterThan(0));
      tester.binding.handleMemoryPressure();
      expect(h.render.debugCachedPictures, 2); // again, blank
      expect(h.render.debugParagraphs.length, 0);
      expect(h.render.debugCachedRows, 5);
    });

    testWidgets('a system font change drops every picture', (tester) async {
      final h = await pumpRenderer(tester, initial: 'hello');
      final recorded = h.render.debugRowRecordings;
      await tester.binding.handleSystemMessage(<String, Object?>{
        'type': 'fontsChange',
      });
      await tester.pump();
      expect(h.render.debugRowRecordings, recorded + 2);
    });

    testWidgets('a selection change re-records the rows it marks dirty', (
      tester,
    ) async {
      // libghostty-vt 1.0.0 marks every viewport row dirty on a selection
      // change.
      final h = await pumpRenderer(tester, initial: 'one\r\ntwo\r\nthree');
      final recorded = h.render.debugRowRecordings;
      h.seams.selection = h.seams.terminal.selectRange(
        const GridPoint.viewport(0, 1),
        const GridPoint.viewport(2, 1),
      );
      await tester.pump();
      // Every row is flagged; only row 1 looks different.
      expect(h.render.debugRowRecordings, recorded + 1);
    });

    testWidgets('a new source drops the pictures of the old one', (
      tester,
    ) async {
      final h = await pumpRenderer(tester, initial: 'hello');
      final other = VtTerminalController(cols: 20, rows: 5);
      addTearDown(other.dispose);
      final recorded = h.render.debugRowRecordings;
      await h.rebuild(source: ControllerSeams(other));
      // One picture for the five blank rows: nothing came from the old
      // source's cache, although its blank rows had the same content.
      expect(h.render.debugRowRecordings, recorded + 1);
      expect(h.render.debugCachedPictures, 1);
    });
  });

  group('render hold', () {
    testWidgets('while held, the frame is not read and nothing is recorded', (
      tester,
    ) async {
      final h = await pumpRenderer(tester, initial: 'hello');
      final source = _CountingSource(h.seams);
      await h.rebuild(source: source);
      final updates = source.updates;
      final recorded = h.render.debugRowRecordings;

      await h.write('\x1b[?2026hworld');
      expect(h.seams.isRenderHeld, isTrue);
      h.render.markNeedsPaint();
      await tester.pump();
      expect(source.updates, updates);
      expect(h.render.debugRowRecordings, recorded);
      expect(h.render.debugCachedRows, 5);

      await h.write('\x1b[?2026l');
      expect(source.updates, updates + 1); // one frame after the hold
      expect(h.render.debugRowRecordings, recorded + 1);
    });

    testWidgets('a font or theme change during a hold keeps the grid', (
      tester,
    ) async {
      final h = await pumpRenderer(tester, initial: 'hello');
      await h.write('\x1b[?2026h');
      final recorded = h.render.debugRowRecordings;
      await h.rebuild(textStyle: gridStyle.copyWith(fontSize: 14));
      h.controller.theme = VtTerminalTheme.whiteOnBlack;
      await tester.pump();
      // Still the old pictures, not a blank grid.
      expect(h.render.debugCachedRows, 5);
      expect(h.render, paintsExactlyCountTimes(#drawPicture, 5));
      expect(h.render.debugRowRecordings, recorded);

      h.controller.write('\x1b[?2026l');
      await h.rebuild(textStyle: gridStyle.copyWith(fontSize: 14));
      expect(h.render.debugRowRecordings, recorded + 2);
    });
  });

  group('flood', () {
    // Lines that scroll the whole 5-row grid past: every visible row is
    // new.
    String screenful(int frame) =>
        [for (var i = 0; i < 10; i++) '\r\nframe $frame line $i'].join();

    testWidgets('output that scrolls a screen per frame paints on the '
        'pacing\'s vsyncs', (tester) async {
      final h = await pumpRenderer(tester, initial: 'start');
      final period = ControllerSeams.vsyncPeriod(60);
      await h.write(screenful(1));
      expect(h.render.debugFlooded, isFalse); // one frame is not a flood
      await h.write(screenful(2));
      expect(h.render.debugFlooded, isTrue);

      // Balanced at 60 Hz (the default): every second vsync.
      final scans = h.render.debugRowScans;
      h.controller.write(screenful(3));
      expect(h.render.debugNeedsPaint, isFalse);
      expect(h.seams.debugNotificationPending, isTrue);
      await tester.pump(period);
      expect(h.render.debugRowScans, scans); // not painted at this vsync
      h.controller.write(screenful(4)); // coalesced into the same frame
      await tester.pump(period);
      expect(h.render.debugRowScans, scans + 5);
      expect(h.seams.isDisposed, isFalse);
      expect(h.render.debugFlooded, isTrue);
    });

    for (final pacing in VtFloodPacing.values) {
      for (final hz in const [60.0, 120.0, 144.0]) {
        testWidgets('a steady flood paints once every '
            '${ControllerSeams.floodVsyncs(pacing, hz)} vsyncs '
            '(${pacing.name}, $hz Hz)', (tester) async {
          final h = await pumpRenderer(tester, initial: 'start');
          h.seams
            ..floodPacing = pacing
            ..refreshRate = hz;
          final period = ControllerSeams.vsyncPeriod(hz);
          final vsyncs = ControllerSeams.floodVsyncs(pacing, hz);
          // A program writing a screenful between every two vsyncs: each
          // pump is one vsync.
          final painted = <int>[];
          for (var vsync = 0; vsync < 12 * vsyncs; vsync++) {
            final scans = h.render.debugRowScans;
            h.controller.write(screenful(vsync));
            await tester.pump(period);
            if (h.render.debugRowScans != scans) painted.add(vsync);
          }
          // After the two frames that detect the flood, frames are exactly
          // `vsyncs` apart: no gap of twice the interval.
          final steady = painted.skip(2).toList();
          expect(steady.length, greaterThanOrEqualTo(8));
          for (var i = 1; i < steady.length; i++) {
            expect(
              steady[i] - steady[i - 1],
              vsyncs,
              reason: 'frames at vsyncs $painted',
            );
          }
        });
      }
    }

    testWidgets('after a pause the first change paints at the next vsync', (
      tester,
    ) async {
      final h = await pumpRenderer(tester, initial: 'start');
      await h.write(screenful(1));
      await h.write(screenful(2));
      expect(h.render.debugFlooded, isTrue);
      // The pacing is measured on the test's fake clock
      // (flutter_test_config.dart), which only pump advances.
      await tester.pump(ControllerSeams.vsyncPeriod(60) * 3);
      final scans = h.render.debugRowScans;
      await h.write('x');
      expect(h.render.debugRowScans, greaterThan(scans));
      expect(h.render.debugFlooded, isFalse);
    });

    testWidgets('one screenful (a clear) or rows redrawn in place never '
        'flood', (tester) async {
      final h = await pumpRenderer(tester, initial: 'start');
      await h.write(screenful(1));
      final scans = h.render.debugRowScans;
      await h.write('\r\n> ');
      expect(h.render.debugRowScans, greaterThan(scans));
      for (var frame = 0; frame < 4; frame++) {
        await h.write(
          [
            for (var y = 1; y <= 5; y++) '\x1b[$y;1Hredraw $frame row $y',
          ].join(),
        );
        expect(h.render.debugFlooded, isFalse);
      }
    });

    testWidgets('a pending flood repaint is cancelled on detach', (
      tester,
    ) async {
      final h = await pumpRenderer(tester, initial: 'start');
      await h.write(screenful(1));
      await h.write(screenful(2));
      h.controller.write(screenful(3));
      expect(h.seams.debugNotificationPending, isTrue);
      await tester.pumpWidget(const SizedBox());
      // The renderer stopped listening: no timer is left pending (the
      // test framework checks at the end too).
      expect(h.seams.debugNotificationPending, isFalse);
    });
  });

  group('disposal', () {
    testWidgets('a disposed source paints the background only', (tester) async {
      final h = await pumpRenderer(tester, initial: '\x1b[41mred');
      h.controller.dispose();
      h.render.markNeedsPaint();
      await tester.pump();
      expect(h.render.debugCachedRows, 0);
      expect(h.render.debugParagraphs.length, 0);
      expect(h.render, paintsExactlyCountTimes(#drawPicture, 0));
      expect(h.render, paintsExactlyCountTimes(#drawRect, 1));
      expect(
        h.render,
        paints..rect(color: VtTerminalTheme.defaultTheme.background),
      );
    });
  });

  group('cursor', () {
    testWidgets('draws the program shape when focused', (tester) async {
      final h = await pumpRenderer(tester, initial: 'hi');
      expect(h.render.debugPaintedCursor, VtCursorStyle.block);
      await h.write('\x1b[6 q'); // steady bar
      expect(h.render.debugPaintedCursor, VtCursorStyle.bar);
      await h.write('\x1b[4 q'); // steady underline
      expect(h.render.debugPaintedCursor, VtCursorStyle.underline);
    });

    testWidgets('is a hollow block when unfocused', (tester) async {
      final h = await pumpRenderer(tester, initial: 'hi', focused: false);
      expect(h.render.debugPaintedCursor, VtCursorStyle.blockHollow);
    });

    testWidgets('hideCursor and DECTCEM hide it; alwaysShowCursor wins', (
      tester,
    ) async {
      final h = await pumpRenderer(tester, initial: 'hi');
      await h.rebuild(hideCursor: true);
      expect(h.render.debugPaintedCursor, isNull);
      await h.rebuild();
      await h.write('\x1b[?25l');
      expect(h.render.debugPaintedCursor, isNull);
      await h.rebuild(alwaysShowCursor: true);
      expect(h.render.debugPaintedCursor, VtCursorStyle.block);
    });

    testWidgets('cursorStyle overrides the program shape', (tester) async {
      final h = await pumpRenderer(tester, initial: 'hi');
      await h.rebuild(cursorStyle: VtCursorStyle.underline);
      expect(h.render.debugPaintedCursor, VtCursorStyle.underline);
    });

    testWidgets('is not drawn while scrolled out of view', (tester) async {
      final h = await pumpRenderer(tester);
      await h.write(List.generate(30, (i) => 'line $i').join('\r\n'));
      h.controller.scrollViewport(const ViewportScroll.top());
      await tester.pump();
      expect(h.render.debugPaintedCursor, isNull);
    });

    testWidgets('blinks on its own timer without recording rows', (
      tester,
    ) async {
      final h = await pumpRenderer(tester, initial: 'hi\x1b[1 q');
      final recorded = h.render.debugRowRecordings;
      expect(h.render.debugBlinking, isTrue);
      expect(h.render.debugPaintedCursor, VtCursorStyle.block);

      await tester.pump(RenderTerminal.blinkInterval);
      expect(h.render.debugBlinkOn, isFalse);
      expect(h.render.debugPaintedCursor, isNull);
      await tester.pump(RenderTerminal.blinkInterval);
      expect(h.render.debugBlinkOn, isTrue);
      expect(h.render.debugPaintedCursor, VtCursorStyle.block);
      await tester.pump(RenderTerminal.blinkInterval);
      expect(h.render.debugRowRecordings, recorded);

      // Output shows the cursor at once.
      expect(h.render.debugBlinkOn, isFalse);
      await h.write('!');
      expect(h.render.debugBlinkOn, isTrue);
      expect(h.render.debugPaintedCursor, VtCursorStyle.block);
    });

    testWidgets('does not blink while unfocused or steady', (tester) async {
      final h = await pumpRenderer(tester, initial: 'hi\x1b[1 q');
      await h.rebuild(focused: false);
      expect(h.render.debugBlinking, isFalse);
      await h.rebuild();
      expect(h.render.debugBlinking, isTrue);
      await h.write('\x1b[2 q');
      expect(h.render.debugBlinking, isFalse);
    });

    testWidgets('does not blink while tickers are muted (TickerMode)', (
      tester,
    ) async {
      final h = await pumpRenderer(tester, initial: 'hi\x1b[1 q');
      expect(h.render.debugBlinking, isTrue);
      await h.rebuild(
        wrap: (child) => TickerMode(enabled: false, child: child),
      );
      expect(h.render.debugBlinking, isFalse);
      expect(h.render.debugPaintedCursor, VtCursorStyle.block);
      await tester.pump(RenderTerminal.blinkInterval * 3);
      expect(h.render.debugBlinking, isFalse);
    });

    testWidgets('muting the blink in its off half shows the cursor', (
      tester,
    ) async {
      Widget Function(Widget) tickers(bool enabled) =>
          (view) => TickerMode(enabled: enabled, child: view);
      final h = await pumpRenderer(tester, initial: 'hi\x1b[1 q');
      await h.rebuild(wrap: tickers(true));
      await tester.pump(RenderTerminal.blinkInterval);
      expect(h.render.debugPaintedCursor, isNull); // the off half
      await h.rebuild(wrap: tickers(false));
      expect(h.render.debugBlinking, isFalse);
      expect(h.render.debugBlinkOn, isTrue);
      expect(h.render.debugPaintedCursor, VtCursorStyle.block);
      await h.rebuild(wrap: tickers(true));
      expect(h.render.debugPaintedCursor, VtCursorStyle.block);
    });

    testWidgets('stops blinking while the view is not painted', (tester) async {
      final h = await pumpRenderer(tester, initial: 'hi\x1b[1 q');
      Widget Function(Widget) offstage(bool hidden) =>
          (child) => Offstage(offstage: hidden, child: child);
      await h.rebuild(wrap: offstage(false));
      final render = h.render;
      expect(render.debugBlinking, isTrue);
      await h.rebuild(wrap: offstage(true));
      // The first tick's toggle is never painted; the next tick stops.
      await tester.pump(RenderTerminal.blinkInterval);
      expect(render.debugBlinking, isTrue);
      await tester.pump(RenderTerminal.blinkInterval);
      expect(render.debugBlinking, isFalse);
      await h.rebuild(wrap: offstage(false));
      expect(identical(h.render, render), isTrue);
      expect(render.debugBlinking, isTrue);
    });

    testWidgets('uses the theme colour, alpha included, until OSC 12', (
      tester,
    ) async {
      const cursor = Color(0x80FF0000);
      final h = await pumpRenderer(
        tester,
        initial: 'hi\x1b[2 q',
        theme: VtTerminalTheme.defaultTheme.copyWith(cursor: cursor),
      );
      final background = VtTerminalTheme.defaultTheme.background;
      expect(
        h.render,
        paints
          ..rect(color: background)
          ..rect(color: cursor),
      );
      await h.write('\x1b]12;rgb:00/ff/00\x07');
      expect(
        h.render,
        paints
          ..rect(color: background)
          ..rect(color: const Color(0xFF00FF00)),
      );
      // Reset to the default (the theme's colour, pushed opaque).
      await h.write('\x1b]112\x07');
      expect(
        h.render,
        paints
          ..rect(color: background)
          ..rect(color: cursor),
      );
    });

    testWidgets('lets pumpAndSettle settle while blinking', (tester) async {
      await pumpRenderer(tester, initial: 'hi\x1b[1 q');
      await tester.pumpAndSettle();
    });
  });

  group('background', () {
    testWidgets('backgroundOpacity applies to the default background', (
      tester,
    ) async {
      final h = await pumpRenderer(tester, initial: 'hi');
      await h.rebuild(backgroundOpacity: 0.5);
      final background = VtTerminalTheme.defaultTheme.background;
      expect(h.render, paints..rect(color: background.withValues(alpha: 0.5)));
    });
  });
}
