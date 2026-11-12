// Contract tests of the internal seams (ADR 0011): what the renderer, the
// input layers and the scrollbar can rely on.

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart_flutter/ghostty_dart_flutter.dart';
import 'package:ghostty_dart_flutter/src/seams/controller_seams.dart';
import 'package:ghostty_dart_flutter/src/seams/terminal_geometry.dart';

ControllerSeams _seams({int cols = 20, int rows = 5}) {
  final controller = VtTerminalController(cols: cols, rows: rows);
  addTearDown(controller.dispose);
  return ControllerSeams(controller);
}

List<int> _dirtyRows(RenderState state) => [
  for (final row in state.dirtyRows) row.viewportY,
];

void main() {
  group('TerminalFrameSource', () {
    test('updateFrame returns the one render state; endFrame cleans it', () {
      final seams = _seams();
      final first = seams.updateFrame();
      expect(identical(seams.updateFrame(), first), isTrue);
      expect(seams.isDisposed, isFalse);
      expect(first.cols, 20);
      expect(first.rows, 5);
      seams.endFrame();

      seams.controller.write('\x1b[3;1Hhello');
      final state = seams.updateFrame();
      expect(state.dirty, isNot(RenderDirtyState.clean));
      expect(_dirtyRows(state), contains(2));
      seams.endFrame();

      expect(seams.updateFrame().dirty, RenderDirtyState.clean);
      expect(_dirtyRows(seams.updateFrame()), isEmpty);
    });

    test('a selection change dirties the selected rows', () {
      final seams = _seams();
      seams.controller.write('one\r\ntwo\r\nthree');
      seams.updateFrame();
      seams.endFrame();

      final vt = seams.terminal;
      seams.selection = vt.selectRange(
        const GridPoint.viewport(0, 1),
        const GridPoint.viewport(2, 1),
      );
      final state = seams.updateFrame();
      expect(_dirtyRows(state), contains(1));
      final row = state.allRows.elementAt(1);
      expect(row.selectionStart, 0);
      expect(row.selectionEnd, 2);
    });

    test('two seams objects cannot both read frames (debug)', () {
      final seams = _seams();
      seams.updateFrame();
      final other = ControllerSeams(seams.controller);
      expect(other.updateFrame, throwsAssertionError);
      seams.release();
      expect(other.updateFrame, returnsNormally);
    });

    test('notifies its listeners on output', () {
      final seams = _seams();
      var notified = 0;
      void listener() => notified++;
      seams.addListener(listener);
      seams.controller.write('x');
      expect(notified, 1);
      seams.removeListener(listener);
      seams.controller.write('y');
      expect(notified, 1);
    });

    testWidgets('while flooded, notifies every listener once per '
        'floodInterval', (tester) async {
      {
        final seams = _seams();
        final calls = <String>[];
        seams
          ..addListener(() => calls.add('render'))
          ..addListener(() => calls.add('scrollbar'))
          ..painted(flooded: true);
        seams.controller
          ..write('a')
          ..write('b');
        expect(calls, isEmpty);
        expect(seams.debugNotificationPending, isTrue);
        await tester.pump(ControllerSeams.floodInterval);
        expect(calls, ['render', 'scrollbar']);

        // A paint cancels the pending notification (it showed the change);
        // not flooded, changes are delivered at once.
        seams.controller.write('c');
        seams.painted(flooded: false);
        expect(seams.debugNotificationPending, isFalse);
        seams.controller.write('d');
        expect(calls, ['render', 'scrollbar', 'render', 'scrollbar']);
      }
    });

    testWidgets('while flooded and waiting for a slow frame, writes do not '
        'notify again before floodInterval', (tester) async {
      {
        final seams = _seams();
        var notified = 0;
        seams
          ..addListener(() => notified++)
          ..painted(flooded: true);
        // The interval is measured on the test's fake clock
        // (flutter_test_config.dart), which only pump advances.
        await tester.pump(ControllerSeams.floodInterval * 1.5);
        seams.controller.write('a');
        expect(notified, 1);
        // No paint follows (the frame is slow): the writes after that
        // notification wait for an interval after it, not after the paint.
        seams.controller
          ..write('b')
          ..write('c');
        expect(notified, 1);
        expect(seams.debugNotificationPending, isTrue);
        await tester.pump(ControllerSeams.floodInterval);
        expect(notified, 2);
      }
    });

    testWidgets('a flood that lasts sustainedFloodAfter notifies once per '
        'sustainedFloodInterval until it ends', (tester) async {
      {
        final seams = _seams();
        var notified = 0;
        seams
          ..addListener(() => notified++)
          ..painted(flooded: true);
        // The flood's age is measured on the test's fake clock
        // (flutter_test_config.dart), which only pump advances.
        await tester.pump(ControllerSeams.sustainedFloodAfter);
        seams
          ..painted(flooded: true)
          ..controller.write('a');
        expect(seams.debugNotificationPending, isTrue);
        await tester.pump(ControllerSeams.floodInterval);
        expect(notified, 0);
        await tester.pump(
          ControllerSeams.sustainedFloodInterval -
              ControllerSeams.floodInterval,
        );
        expect(notified, 1);

        // The flood ends: the next one starts with floodInterval again.
        seams
          ..painted(flooded: false)
          ..painted(flooded: true)
          ..controller.write('b');
        await tester.pump(ControllerSeams.floodInterval);
        expect(notified, 2);
      }
    });

    test('an error in one listener does not skip the others', () {
      final seams = _seams();
      var notified = 0;
      seams
        ..addListener(() => throw StateError('listener'))
        ..addListener(() => notified++);
      final errors = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = errors.add;
      addTearDown(() => FlutterError.onError = previous);
      seams.controller.write('x');
      expect(notified, 1);
      expect(errors.single.exception, isStateError);
    });

    testWidgets('removing the last listener cancels a pending '
        'notification', (tester) async {
      {
        final seams = _seams();
        void listener() {}
        seams
          ..addListener(listener)
          ..painted(flooded: true);
        seams.controller.write('x');
        expect(seams.debugNotificationPending, isTrue);
        seams.removeListener(listener);
        expect(seams.debugNotificationPending, isFalse);
        // The test framework fails a test that leaves a timer pending.
      }
    });
  });

  group('disposal', () {
    test('sinks are no-ops once the controller is disposed', () {
      final controller = VtTerminalController();
      final seams = ControllerSeams(controller);
      final output = <List<int>>[];
      controller.onOutput = output.add;
      controller.dispose();
      expect(seams.isDisposed, isTrue);
      expect(seams.sendKey(const VtKeyEvent(key: VtKey.enter)), isFalse);
      seams
        ..sendText('x')
        ..sendFocus(focused: true)
        ..scrollViewport(const ViewportScroll.top())
        ..setMouseGeometry(
          const MouseEncoderSize(
            screenWidth: 1,
            screenHeight: 1,
            cellWidth: 1,
            cellHeight: 1,
          ),
        )
        ..setMouseButtonsPressed(anyPressed: true)
        ..selection = null;
      expect(seams.paste('x'), PasteResult.nothingToPaste);
      expect(
        seams.sendMouse(
          const VtMouseEvent(action: MouseAction.motion, x: 0, y: 0),
        ),
        isFalse,
      );
      expect(seams.selectedText, isNull);
      expect(seams.cursorViewportCell, isNull);
      expect(seams.isPasswordInput, isFalse);
      expect(seams.isMouseTracking, isFalse);
      expect(seams.isAlternateScreen, isFalse);
      expect(seams.isRenderHeld, isFalse);
      expect(seams.mouseShape, MouseShape.defaultShape);
      expect(seams.selection, isNull);
      expect(seams.scrollbar.isAtBottom, isTrue);
      expect(seams.updateFrame, throwsStateError);
      expect(() => seams.terminal, throwsStateError);
      seams.removeListener(() {});
      expect(output, isEmpty);
    });
  });

  group('TerminalTextSink', () {
    test('notifies when output moves the cursor', () {
      final seams = _seams();
      var notified = 0;
      seams.addListener(() => notified++);
      seams.controller.write('\x1b[3;4H');
      expect(notified, 1);
      expect(seams.cursorViewportCell, const GridPoint.viewport(3, 2));
    });

    test('cursorViewportCell follows the cursor and the viewport', () {
      final seams = _seams();
      expect(seams.cursorViewportCell, const GridPoint.viewport(0, 0));
      seams.controller.write('abc');
      expect(seams.cursorViewportCell, const GridPoint.viewport(3, 0));
      seams.controller.write(List.filled(10, '\r\n').join());
      expect(seams.cursorViewportCell, const GridPoint.viewport(0, 4));
      seams.scrollViewport(const ViewportScroll.delta(-2));
      expect(seams.cursorViewportCell, isNull);
      seams.scrollViewport(const ViewportScroll.delta(1));
      expect(seams.cursorViewportCell, isNull);
      seams.scrollViewport(const ViewportScroll.bottom());
      expect(seams.cursorViewportCell, const GridPoint.viewport(0, 4));
    });
  });

  group('TerminalKeySink', () {
    test('latchedModifiers starts empty and is shared', () {
      final seams = _seams();
      expect(seams.latchedModifiers.value, KeyModifiers.none);
      final again = ControllerSeams(seams.controller);
      seams.latchedModifiers.value = KeyModifiers.ctrl;
      expect(again.latchedModifiers.value, KeyModifiers.ctrl);
    });
  });

  group('TerminalGeometry', () {
    const metrics = VtCellMetrics(
      width: 8.5,
      height: 17,
      baseline: 13,
      advance: 8.4,
      devicePixelRatio: 2,
    );

    test('fit takes the largest grid inside the padding', () {
      final geometry = TerminalGeometry.fit(
        const Size(200, 100),
        metrics,
        padding: const EdgeInsets.all(4),
      );
      expect(geometry.cols, 22); // 192 / 8.5 = 22.6
      expect(geometry.rows, 5); // 92 / 17 = 5.4
      expect(geometry.viewSize, const Size(200, 100));
      expect(geometry.gridRect, const Rect.fromLTWH(4, 4, 187, 85));
    });

    test('fit never goes below one cell', () {
      final geometry = TerminalGeometry.fit(Size.zero, metrics);
      expect((geometry.cols, geometry.rows), (1, 1));
    });

    test('fit counts device pixels, so exact fits are kept', () {
      // 7 device px cells at dpr 3: 80 cells are 560 px = 186.666... lp.
      final cell = VtCellMetrics.aligned(
        advance: 7 / 3,
        ascent: 4,
        descent: 1,
        devicePixelRatio: 3,
      );
      expect(cell.widthPx, 7);
      final geometry = TerminalGeometry.fit(Size(560 / 3, 100), cell);
      expect(geometry.cols, 80);
    });

    test('fit rejects unbounded sizes with a clear error', () {
      expect(
        () => TerminalGeometry.fit(const Size(double.infinity, 100), metrics),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('bounded constraints'),
          ),
        ),
      );
    });

    test('padding is snapped to device pixels', () {
      final cell = VtCellMetrics.aligned(
        advance: 8,
        ascent: 12,
        descent: 4,
        devicePixelRatio: 1.25,
      );
      final geometry = TerminalGeometry(
        metrics: cell,
        cols: 2,
        rows: 2,
        padding: const EdgeInsets.all(5), // 6.25 device px
      );
      expect(geometry.padding.left * 1.25, 6);
      expect(geometry.cellOrigin(0, 0).dx * 1.25, 6);
      expect(geometry.mouseEncoderSize.paddingLeft, 6);
    });

    test('cells and points', () {
      final geometry = TerminalGeometry(
        metrics: metrics,
        cols: 10,
        rows: 4,
        padding: const EdgeInsets.only(left: 2, top: 3),
      );
      expect(geometry.cellOrigin(2, 1), const Offset(19, 20));
      expect(
        geometry.cellRect(2, 1, width: 2),
        const Rect.fromLTWH(19, 20, 17, 17),
      );
      expect(
        geometry.viewportCellAt(const Offset(19, 20)),
        const GridPoint.viewport(2, 1),
      );
      expect(
        geometry.viewportCellAt(const Offset(-50, 1000)),
        const GridPoint.viewport(0, 3),
      );
      expect(geometry.toSurface(const Offset(1.5, 2)), (x: 3.0, y: 4.0));
    });

    test('encoder geometries are in device pixels', () {
      final geometry = TerminalGeometry(
        metrics: metrics,
        cols: 10,
        rows: 4,
        padding: const EdgeInsets.only(left: 2, top: 3),
        viewSize: const Size(100, 80),
      );
      expect(
        geometry.mouseEncoderSize,
        const MouseEncoderSize(
          screenWidth: 200,
          screenHeight: 160,
          cellWidth: 17,
          cellHeight: 34,
          paddingLeft: 4,
          paddingTop: 6,
          paddingRight: 26,
          paddingBottom: 18,
        ),
      );
      final selection = geometry.selectionGeometry;
      expect(selection.columns, 10);
      expect(selection.cellWidth, 17);
      expect(selection.paddingLeft, 4);
      expect(selection.screenHeight, 160);
    });

    test('rejects grids outside 1-65535', () {
      expect(
        () => TerminalGeometry(metrics: metrics, cols: 0, rows: 1),
        throwsRangeError,
      );
    });
  });
}
