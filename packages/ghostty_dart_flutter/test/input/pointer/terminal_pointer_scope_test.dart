// Widget tests of the pointer layer (ADR 0011): mouse reports, selection,
// wheel, trackpad, touch and stylus, the gesture arena, and the pointer
// cursor.

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart_flutter/ghostty_dart_flutter.dart';
import 'package:ghostty_dart_flutter/src/seams/terminal_geometry.dart';

import 'pointer_test_harness.dart';

const _sgrClicks = '\x1b[?1000h\x1b[?1006h';
const _sgrDrags = '\x1b[?1002h\x1b[?1006h';
const _sgrMotion = '\x1b[?1003h\x1b[?1006h';
const _sgrPixelDrags = '\x1b[?1002h\x1b[?1016h';

/// The device id `TestPointer` gives a mouse (flutter_test
/// `test_pointer.dart`); `debugDeviceActiveCursor` reads its cursor.
const _mouseDevice = 1;

/// Six ticks of Ghostty's 15 ms `selection_scroll_ms` autoscroll timer.
const _sixAutoscrollTicks = Duration(milliseconds: 15 * 6);

Future<TestGesture> _mouse(
  WidgetTester tester,
  Offset at, {
  int buttons = kPrimaryMouseButton,
  int? pointer,
}) async {
  final gesture = await tester.createGesture(
    kind: PointerDeviceKind.mouse,
    buttons: buttons,
    pointer: pointer,
  );
  await gesture.addPointer(location: at);
  addTearDown(gesture.removePointer);
  return gesture;
}

Future<void> _click(
  TestGesture gesture,
  Offset at, {
  Duration time = Duration.zero,
}) async {
  await gesture.down(at, timeStamp: time);
  await gesture.up(timeStamp: time);
}

Future<void> _drag(TestGesture mouse, Offset from, Offset to) async {
  await mouse.down(from);
  await mouse.moveTo(to);
  await mouse.up();
}

Future<void> _withKeys(
  WidgetTester tester,
  List<LogicalKeyboardKey> keys,
  Future<void> Function() body,
) async {
  for (final key in keys) {
    await tester.sendKeyDownEvent(key);
  }
  try {
    await body();
  } finally {
    for (final key in keys.reversed) {
      await tester.sendKeyUpEvent(key);
    }
  }
}

/// The first frame runs the scope's post-frame cursor re-read, whose
/// `setState` the second frame applies.
Future<void> _settleCursor(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

MouseCursor? _activeCursor() =>
    RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(_mouseDevice);

void main() {
  group('mouse reports', () {
    testWidgets('a click is reported while the program tracks the mouse', (
      tester,
    ) async {
      final h = await pumpPointerScope(tester);
      h.controller.write(_sgrClicks);
      final mouse = await _mouse(tester, h.cell(3, 1));
      await _click(mouse, h.cell(3, 1));
      expect(h.takeOutput(), '\x1b[<0;4;2M\x1b[<0;4;2m');
      expect(h.controller.selection, isNull);
    });

    testWidgets('right button presses are reported', (tester) async {
      final h = await pumpPointerScope(tester);
      h.controller.write(_sgrClicks);
      final right = await _mouse(
        tester,
        h.cell(0, 0),
        buttons: kSecondaryMouseButton,
      );
      await _click(right, h.cell(0, 0));
      expect(h.takeOutput(), '\x1b[<2;1;1M\x1b[<2;1;1m');
    });

    testWidgets('button-event tracking reports drags once per cell', (
      tester,
    ) async {
      final h = await pumpPointerScope(tester);
      h.controller.write(_sgrDrags);
      final mouse = await _mouse(tester, h.cell(1, 1));
      await mouse.down(h.cell(1, 1));
      await mouse.moveTo(h.cell(1, 1, dx: 0.9)); // same cell: dropped
      await mouse.moveTo(h.cell(2, 1));
      await mouse.moveTo(h.cell(2, 2));
      await mouse.up();
      expect(
        h.takeOutput(),
        '\x1b[<0;2;2M\x1b[<32;3;2M\x1b[<32;3;3M\x1b[<0;3;3m',
      );
    });

    testWidgets('X10 and normal tracking report no motion', (tester) async {
      final h = await pumpPointerScope(tester);
      final mouse = await _mouse(tester, h.cell(1, 1));
      h.controller.write('\x1b[?1000h\x1b[?1006h');
      await _drag(mouse, h.cell(1, 1), h.cell(4, 2));
      expect(h.takeOutput(), '\x1b[<0;2;2M\x1b[<0;5;3m');

      h.controller.write('\x1b[?1000l\x1b[?9h');
      await _drag(mouse, h.cell(1, 1), h.cell(4, 2));
      expect(h.takeOutput(), '\x1b[<0;2;2M', reason: 'X10: presses only');
    });

    testWidgets('SGR-Pixels reports every move, also within one cell', (
      tester,
    ) async {
      final h = await pumpPointerScope(tester);
      h.controller.write(_sgrPixelDrags);
      final mouse = await _mouse(tester, h.cell(1, 1, dx: 0.2));
      await mouse.down(h.cell(1, 1, dx: 0.2));
      await mouse.moveTo(h.cell(1, 1, dx: 0.6));
      await mouse.moveTo(h.cell(1, 1, dx: 0.8));
      await mouse.up();
      final reports = RegExp(r'\x1b\[<32;').allMatches(h.takeOutput());
      expect(reports, hasLength(2));
    });

    testWidgets('hover motion is reported only in any-event tracking', (
      tester,
    ) async {
      final h = await pumpPointerScope(tester);
      h.controller.write(_sgrDrags);
      final mouse = await _mouse(tester, h.cell(0, 0));
      await mouse.moveTo(h.cell(4, 0));
      expect(h.takeOutput(), isEmpty, reason: '1002 needs a held button');

      h.controller.write(_sgrMotion);
      await mouse.moveTo(h.cell(5, 2));
      expect(h.takeOutput(), '\x1b[<35;6;3M');
    });

    testWidgets('a second button during a drag is reported, without an '
        'extra motion report', (tester) async {
      final h = await pumpPointerScope(tester);
      h.controller.write(_sgrPixelDrags);
      final mouse = await _mouse(tester, h.cell(1, 1), pointer: 42);
      await mouse.down(h.cell(1, 1));
      h.takeOutput();
      await mouse.updateWithCustomEvent(
        PointerMoveEvent(
          pointer: 42,
          device: _mouseDevice,
          kind: PointerDeviceKind.mouse,
          position: h.cell(1, 1),
          buttons: kPrimaryMouseButton | kSecondaryMouseButton,
        ),
      );
      final second = h.takeOutput();
      expect(second, startsWith('\x1b[<2;'));
      expect(second, endsWith('M'));
      expect(second.split('\x1b'), hasLength(2), reason: 'one report only');
      await mouse.up();
      expect(RegExp('m').allMatches(h.takeOutput()), hasLength(2));
    });

    testWidgets('a cancelled press releases the reported button', (
      tester,
    ) async {
      final h = await pumpPointerScope(tester);
      h.controller.write(_sgrClicks);
      final mouse = await _mouse(tester, h.cell(2, 0));
      await mouse.down(h.cell(2, 0));
      await mouse.cancel();
      expect(h.takeOutput(), '\x1b[<0;3;1M\x1b[<0;3;1m');
    });

    testWidgets('disposing the scope releases a held button', (tester) async {
      final h = await pumpPointerScope(tester);
      h.controller.write(_sgrClicks);
      final mouse = await _mouse(tester, h.cell(2, 0));
      await mouse.down(h.cell(2, 0));
      await tester.pumpWidget(const SizedBox());
      expect(h.takeOutput(), '\x1b[<0;3;1M\x1b[<0;3;1m');
    });

    testWidgets('a new pointer sink releases the held button on the old '
        'one', (tester) async {
      final a = createHarness();
      final b = createHarness();
      await tester.pumpWidget(
        testApp(pointerScopeUnderTest(a.seams, a.geometry)),
      );
      a.controller.write(_sgrClicks);
      b.controller.write(_sgrClicks);
      final mouse = await _mouse(tester, a.cell(2, 0));
      await mouse.down(a.cell(2, 0));
      await tester.pumpWidget(
        testApp(pointerScopeUnderTest(b.seams, b.geometry)),
      );
      expect(a.takeOutput(), '\x1b[<0;3;1M\x1b[<0;3;1m');
      await mouse.up();
      expect(b.takeOutput(), isEmpty, reason: 'the press belonged to a');
    });

    testWidgets('Shift bypasses tracking and selects', (tester) async {
      final h = await pumpPointerScope(tester);
      h.controller.write('hello world\r\n$_sgrClicks');
      final mouse = await _mouse(tester, h.cell(0, 0));
      await _withKeys(tester, [LogicalKeyboardKey.shiftLeft], () async {
        await _drag(mouse, h.cell(0, 0, dx: 0.1), h.cell(4, 0, dx: 0.9));
      });
      expect(h.takeOutput(), isEmpty);
      expect(h.controller.selectedText, 'hello');
    });

    testWidgets('onPointerDown runs for presses the program consumes', (
      tester,
    ) async {
      final downs = <PointerDeviceKind>[];
      final h = await pumpPointerScope(
        tester,
        onPointerDown: (event) => downs.add(event.kind),
      );
      h.controller.write(_sgrClicks);
      final mouse = await _mouse(tester, h.cell(1, 1));
      await _click(mouse, h.cell(1, 1));
      await tester.tapAt(h.cell(2, 2));
      expect(downs, [PointerDeviceKind.mouse, PointerDeviceKind.touch]);
      expect(h.takeOutput(), isNotEmpty);
    });
  });

  group('DPR 2 with padding', () {
    const padding = EdgeInsets.fromLTRB(3, 5, 3, 5);

    testWidgets('reports use device pixels: same cells, doubled pixels', (
      tester,
    ) async {
      final h = await pumpPointerScope(
        tester,
        devicePixelRatio: 2,
        padding: padding,
      );
      h.controller.write(_sgrClicks);
      final mouse = await _mouse(tester, h.cell(3, 1));
      await _click(mouse, h.cell(3, 1));
      expect(h.takeOutput(), '\x1b[<0;4;2M\x1b[<0;4;2m');

      // SGR-Pixels: the position inside the grid (padding excluded) in
      // device pixels. The cell (3, 1) centre is 3.5 x 10 by 1.5 x 20
      // logical px past the padding: 70 x 60 device px.
      h.controller.write('\x1b[?1016h');
      await _click(mouse, h.cell(3, 1));
      expect(h.takeOutput(), '\x1b[<0;70;60M\x1b[<0;70;60m');
    });

    testWidgets('selection and double click use device pixels', (tester) async {
      final h = await pumpPointerScope(
        tester,
        devicePixelRatio: 2,
        padding: padding,
      );
      h.controller.write('hello brave world');
      final mouse = await _mouse(tester, h.cell(0, 0));
      await _drag(mouse, h.cell(6, 0, dx: 0.1), h.cell(10, 0, dx: 0.9));
      expect(h.controller.selectedText, 'brave');

      // Two presses 6 logical px apart (12 device px) are within one
      // cell width (20 device px): a double click.
      const t0 = Duration(seconds: 10);
      await _click(mouse, h.cell(1, 0, dx: 0.2), time: t0);
      await _click(
        mouse,
        h.cell(1, 0, dx: 0.8),
        time: t0 + const Duration(milliseconds: 100),
      );
      expect(h.controller.selectedText, 'hello');
    });
  });

  group('selection', () {
    testWidgets('dragging selects cells', (tester) async {
      final h = await pumpPointerScope(tester);
      h.controller.write('hello world\r\nsecond line');
      final mouse = await _mouse(tester, h.cell(6, 0));
      await _drag(mouse, h.cell(6, 0, dx: 0.1), h.cell(5, 1, dx: 0.9));
      expect(h.controller.selectedText, 'world\nsecond');
      expect(h.takeOutput(), isEmpty);
    });

    testWidgets('a single click clears the selection', (tester) async {
      final h = await pumpPointerScope(tester);
      h.controller
        ..write('hello world')
        ..selectAll();
      expect(h.controller.selection, isNotNull);
      final mouse = await _mouse(tester, h.cell(2, 0));
      await _click(mouse, h.cell(2, 0));
      expect(h.controller.selection, isNull);
    });

    testWidgets('a double click selects a word, a triple click the line', (
      tester,
    ) async {
      final h = await pumpPointerScope(tester);
      h.controller.write('hello brave world');
      final mouse = await _mouse(tester, h.cell(7, 0));
      const t0 = Duration(seconds: 10);
      await _click(mouse, h.cell(7, 0), time: t0);
      await _click(
        mouse,
        h.cell(7, 0),
        time: t0 + const Duration(milliseconds: 100),
      );
      expect(h.controller.selectedText, 'brave');
      await _click(
        mouse,
        h.cell(7, 0),
        time: t0 + const Duration(milliseconds: 200),
      );
      expect(h.controller.selectedText, 'hello brave world');
    });

    testWidgets('clicks farther apart than the interval stay single', (
      tester,
    ) async {
      final h = await pumpPointerScope(tester);
      h.controller.write('hello brave world');
      final mouse = await _mouse(tester, h.cell(7, 0));
      await _click(mouse, h.cell(7, 0), time: const Duration(seconds: 1));
      await _click(mouse, h.cell(7, 0), time: const Duration(seconds: 2));
      expect(h.controller.selection, isNull);
    });

    testWidgets('a new cell width starts a new click sequence', (tester) async {
      final h = createHarness();
      await tester.pumpWidget(
        testApp(pointerScopeUnderTest(h.seams, h.geometry)),
      );
      h.controller.write('hello brave world');
      final mouse = await _mouse(tester, h.cell(7, 0));
      const t0 = Duration(seconds: 10);
      await _click(mouse, h.cell(7, 0), time: t0);
      final wider = TerminalGeometry(
        metrics: VtCellMetrics.aligned(
          advance: 11,
          ascent: 15,
          descent: 5,
          devicePixelRatio: 1,
        ),
        cols: 20,
        rows: 5,
      );
      await tester.pumpWidget(testApp(pointerScopeUnderTest(h.seams, wider)));
      await _click(
        mouse,
        wider.cellOrigin(7, 0) + const Offset(5, 10),
        time: t0 + const Duration(milliseconds: 100),
      );
      expect(h.controller.selection, isNull);
    });

    testWidgets('Ctrl+Alt drag selects a block off Apple platforms', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        final h = await pumpPointerScope(tester);
        h.controller.write('abcdef\r\nghijkl\r\nmnopqr');
        final mouse = await _mouse(tester, h.cell(1, 0));
        await _withKeys(tester, [
          LogicalKeyboardKey.controlLeft,
          LogicalKeyboardKey.altLeft,
        ], () => _drag(mouse, h.cell(1, 0, dx: 0.1), h.cell(2, 2, dx: 0.9)));
        expect(h.controller.selection?.isRectangle, isTrue);
        expect(h.controller.selectedText, 'bc\nhi\nno');

        // Alt alone is a plain drag here.
        await _withKeys(tester, [
          LogicalKeyboardKey.altLeft,
        ], () => _drag(mouse, h.cell(1, 0, dx: 0.1), h.cell(2, 2, dx: 0.9)));
        expect(h.controller.selection?.isRectangle, isFalse);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('Option drag selects a block on macOS, toggled mid-drag', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        final h = await pumpPointerScope(tester);
        h.controller.write('abcdef\r\nghijkl');
        final mouse = await _mouse(tester, h.cell(1, 0));
        await mouse.down(h.cell(1, 0, dx: 0.1));
        await mouse.moveTo(h.cell(2, 1, dx: 0.9));
        expect(h.controller.selection?.isRectangle, isFalse);
        await _withKeys(tester, [LogicalKeyboardKey.altLeft], () async {
          await mouse.moveTo(h.cell(2, 1, dx: 0.95));
          expect(h.controller.selection?.isRectangle, isTrue);
        });
        await mouse.moveTo(h.cell(2, 1, dx: 0.9));
        expect(h.controller.selection?.isRectangle, isFalse);
        await mouse.up();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('Shift+click extends the selection after output scrolled '
        'it', (tester) async {
      final h = await pumpPointerScope(tester);
      h.controller.write('one two three four\r\n');
      final mouse = await _mouse(tester, h.cell(0, 0));
      await _drag(mouse, h.cell(4, 0, dx: 0.1), h.cell(6, 0, dx: 0.9));
      expect(h.controller.selectedText, 'two');

      // Six lines push "one two ..." into the scrollback; viewport row 0
      // now shows "line 2", so a kept snapshot would point elsewhere.
      writeLines(h.controller, 6);
      expect(h.bar.offset, 3);
      await _withKeys(tester, [LogicalKeyboardKey.shiftLeft], () async {
        await _click(mouse, h.cell(3, 0, dx: 0.9));
      });
      expect(h.controller.selectedText, 'two three four\nline 0\nline 1\nline');

      await _withKeys(tester, [
        LogicalKeyboardKey.shiftLeft,
      ], () => _drag(mouse, h.cell(3, 0, dx: 0.9), h.cell(5, 1, dx: 0.9)));
      expect(
        h.controller.selectedText,
        'two three four\nline 0\nline 1\nline 2\nline 3',
      );
    });

    testWidgets('dragging past the top edge autoscrolls into history', (
      tester,
    ) async {
      final h = await pumpPointerScope(tester);
      writeLines(h.controller, 30);
      final bottom = h.bar.offset;
      expect(bottom, greaterThan(10));
      final mouse = await _mouse(tester, h.cell(0, 3));
      await mouse.down(h.cell(0, 3));
      await mouse.moveTo(const Offset(5, -15));
      await tester.pump(_sixAutoscrollTicks);
      final scrolled = h.bar.offset;
      expect(scrolled, lessThan(bottom));
      expect(h.controller.selection, isNotNull);

      await mouse.up();
      await tester.pump(_sixAutoscrollTicks);
      expect(h.bar.offset, scrolled, reason: 'the timer stops on release');
    });

    testWidgets('unmounting during autoscroll stops the timer', (tester) async {
      final h = await pumpPointerScope(tester);
      writeLines(h.controller, 30);
      final mouse = await _mouse(tester, h.cell(0, 3));
      await mouse.down(h.cell(0, 3));
      await mouse.moveTo(const Offset(5, -15));
      await tester.pump(_sixAutoscrollTicks);
      await tester.pumpWidget(const SizedBox());
      final offset = h.bar.offset;
      await tester.pump(_sixAutoscrollTicks);
      expect(h.bar.offset, offset);
    });

    testWidgets('a terminal smaller than the layout does not throw', (
      tester,
    ) async {
      final h = await pumpPointerScope(tester);
      h.controller
        ..write('hello')
        // The public resize, before the next layout catches up.
        ..resize(10, 3);
      final mouse = await _mouse(tester, h.cell(0, 0));
      await _drag(mouse, h.cell(0, 0, dx: 0.1), h.cell(18, 4));
      expect(tester.takeException(), isNull);
      expect(h.controller.selection, isNotNull);
    });

    testWidgets('a click that selects nothing calls onTapUp with its cell', (
      tester,
    ) async {
      final taps = <GridPoint>[];
      final h = await pumpPointerScope(
        tester,
        onTapUp: (_, cell) => taps.add(cell),
      );
      final mouse = await _mouse(tester, h.cell(3, 2));
      await _click(mouse, h.cell(3, 2));
      expect(taps, [const GridPoint.viewport(3, 2)]);

      await _drag(mouse, h.cell(3, 2), h.cell(8, 2));
      expect(taps, hasLength(1), reason: 'a drag is not a tap');
    });

    testWidgets('secondary taps go to the callbacks unless tracked', (
      tester,
    ) async {
      final events = <String>[];
      final h = await pumpPointerScope(
        tester,
        onSecondaryTapDown: (_, cell) => events.add('down ${cell.x},${cell.y}'),
        onSecondaryTapUp: (_, cell) => events.add('up ${cell.x},${cell.y}'),
      );
      final right = await _mouse(
        tester,
        h.cell(1, 1),
        buttons: kSecondaryMouseButton,
      );
      await _click(right, h.cell(1, 1));
      expect(events, ['down 1,1', 'up 1,1']);

      h.controller.write(_sgrClicks);
      await _click(right, h.cell(1, 1));
      expect(events, hasLength(2), reason: 'reported to the program instead');
      expect(h.takeOutput(), isNotEmpty);
    });
  });

  group('wheel', () {
    testWidgets('scrolls the viewport by accumulated rows', (tester) async {
      final h = await pumpPointerScope(tester);
      writeLines(h.controller, 30);
      final bottom = h.bar.offset;

      await sendWheel(tester, h.cell(1, 1), const Offset(0, -60)); // 3 rows
      expect(h.bar.offset, bottom - 3);
      await sendWheel(tester, h.cell(1, 1), const Offset(0, -10));
      expect(h.bar.offset, bottom - 3, reason: 'half a row is kept pending');
      await sendWheel(tester, h.cell(1, 1), const Offset(0, -10));
      expect(h.bar.offset, bottom - 4);
      await sendWheel(tester, h.cell(1, 1), const Offset(0, 400));
      expect(h.bar.isAtBottom, isTrue);
    });

    testWidgets('an inertia cancel drops the pending distance', (tester) async {
      final h = await pumpPointerScope(tester);
      writeLines(h.controller, 30);
      final bottom = h.bar.offset;
      await sendWheel(tester, h.cell(1, 1), const Offset(0, -10));
      final pointer = TestPointer(77, PointerDeviceKind.mouse)
        ..hover(h.cell(1, 1));
      await tester.sendEventToBinding(pointer.scrollInertiaCancel());
      await sendWheel(tester, h.cell(1, 1), const Offset(0, -10));
      expect(h.bar.offset, bottom);
    });

    testWidgets('is reported while tracked, horizontally as buttons 6/7', (
      tester,
    ) async {
      final h = await pumpPointerScope(tester);
      writeLines(h.controller, 30);
      final bottom = h.bar.offset;
      h.controller.write(_sgrClicks);
      await sendWheel(tester, h.cell(2, 1), const Offset(0, -40));
      expect(h.takeOutput(), '\x1b[<64;3;2M\x1b[<64;3;2M');
      await sendWheel(tester, h.cell(2, 1), const Offset(0, 20));
      expect(h.takeOutput(), '\x1b[<65;3;2M');
      await sendWheel(tester, h.cell(2, 1), const Offset(-10, 0));
      expect(h.takeOutput(), '\x1b[<66;3;2M');
      await sendWheel(tester, h.cell(2, 1), const Offset(10, 0));
      expect(h.takeOutput(), '\x1b[<67;3;2M');
      expect(h.bar.offset, bottom);
    });

    testWidgets('Shift scrolls the scrollback, also a horizontal wheel', (
      tester,
    ) async {
      final h = await pumpPointerScope(tester);
      writeLines(h.controller, 30);
      final bottom = h.bar.offset;
      h.controller.write(_sgrClicks);
      await _withKeys(tester, [LogicalKeyboardKey.shiftLeft], () async {
        await sendWheel(tester, h.cell(2, 1), const Offset(0, -40));
        expect(h.bar.offset, bottom - 2);
        // Platforms that turn Shift+wheel horizontal.
        await sendWheel(tester, h.cell(2, 1), const Offset(-40, 0));
        expect(h.bar.offset, bottom - 4);
      });
      expect(h.takeOutput(), isEmpty);
    });

    testWidgets('alternate screen + DEC 1007 writes raw cursor keys, as '
        'Ghostty, whatever the keyboard protocol', (tester) async {
      final h = await pumpPointerScope(tester);
      // libghostty-vt sets DEC 1007 by default, as Ghostty; clear it first.
      h.controller.write('\x1b[?1049h\x1b[?1007l');
      await sendWheel(tester, h.cell(1, 1), const Offset(0, -40));
      expect(h.takeOutput(), isEmpty, reason: 'no 1007: nothing');

      h.controller.write('\x1b[?1007h');
      await sendWheel(tester, h.cell(1, 1), const Offset(0, -40));
      expect(h.takeOutput(), '\x1b[A\x1b[A');
      await sendWheel(tester, h.cell(1, 1), const Offset(0, 20));
      expect(h.takeOutput(), '\x1b[B');

      // Kitty flags 2 (event types) + 8 (all keys as escapes) would change
      // an encoded arrow and add a release; the raw bytes stay.
      h.controller.write('\x1b[>10u');
      await sendWheel(tester, h.cell(1, 1), const Offset(0, -20));
      expect(h.takeOutput(), '\x1b[A');

      h.controller.write('\x1b[<u\x1b[?1h'); // application cursor keys
      await sendWheel(tester, h.cell(1, 1), const Offset(0, -20));
      expect(h.takeOutput(), '\x1bOA');
    });

    testWidgets('without a text sink the arrows go through the key encoder', (
      tester,
    ) async {
      final h = await pumpPointerScope(tester, rawAlternateScroll: false);
      h.controller.write('\x1b[?1049h');
      await sendWheel(tester, h.cell(1, 1), const Offset(0, -20));
      expect(h.takeOutput(), '\x1b[A');
    });

    testWidgets('a scrolled-back viewport stays while output arrives, and '
        'input returns it to the bottom', (tester) async {
      final h = await pumpPointerScope(tester);
      writeLines(h.controller, 30);
      await sendWheel(tester, h.cell(1, 1), const Offset(0, -100));
      final anchored = h.bar.offset;
      expect(h.bar.isAtBottom, isFalse);

      writeLines(h.controller, 10, from: 30);
      expect(h.bar.offset, anchored);

      h.seams.sendKey(const VtKeyEvent(key: VtKey.a, text: 'a'));
      expect(h.bar.isAtBottom, isTrue);
    });
  });

  group('touch, stylus and trackpad', () {
    testWidgets('a trackpad pan scrolls like the wheel', (tester) async {
      final h = await pumpPointerScope(tester);
      writeLines(h.controller, 30);
      final bottom = h.bar.offset;
      final pad = await tester.createGesture(kind: PointerDeviceKind.trackpad);
      await pad.panZoomStart(h.cell(2, 2));
      await pad.panZoomUpdate(h.cell(2, 2), pan: const Offset(0, 30));
      expect(h.bar.offset, bottom - 1);
      await pad.panZoomUpdate(h.cell(2, 2), pan: const Offset(0, 50));
      expect(h.bar.offset, bottom - 2);
      await pad.panZoomEnd();
    });

    testWidgets('a vertical touch drag scrolls the scrollback', (tester) async {
      final h = await pumpPointerScope(tester);
      writeLines(h.controller, 30);
      final bottom = h.bar.offset;
      final touch = await tester.startGesture(h.cell(5, 1));
      await touch.moveBy(const Offset(0, 30)); // past the slop: 1 row
      await touch.moveBy(const Offset(0, 40)); // 2 more rows
      await touch.up();
      expect(h.bar.offset, bottom - 3);
      expect(h.controller.selection, isNull);
    });

    testWidgets('a stylus drag scrolls too', (tester) async {
      final h = await pumpPointerScope(tester);
      writeLines(h.controller, 30);
      final bottom = h.bar.offset;
      final pen = await tester.startGesture(
        h.cell(5, 1),
        kind: PointerDeviceKind.stylus,
      );
      await pen.moveBy(const Offset(0, 40));
      await pen.up();
      expect(h.bar.offset, bottom - 2);
    });

    testWidgets('a long press selects a word; a drag extends it either way', (
      tester,
    ) async {
      final h = await pumpPointerScope(tester);
      h.controller.write('alpha beta gamma');
      final touch = await tester.startGesture(h.cell(7, 0));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      expect(h.controller.selectedText, 'beta');
      await touch.moveTo(h.cell(15, 0));
      expect(h.controller.selectedText, 'beta gamma');
      await touch.moveTo(h.cell(2, 0));
      expect(h.controller.selectedText, 'pha beta', reason: 'keeps the word');
      await touch.up();
    });

    testWidgets('a tap clears the selection, or clicks while tracked', (
      tester,
    ) async {
      final taps = <GridPoint>[];
      final h = await pumpPointerScope(
        tester,
        onTapUp: (_, cell) => taps.add(cell),
      );
      h.controller
        ..write('alpha')
        ..selectAll();
      await tester.tapAt(h.cell(2, 0));
      expect(h.controller.selection, isNull);
      expect(taps, [const GridPoint.viewport(2, 0)]);

      h.controller.write(_sgrClicks);
      await tester.tapAt(h.cell(2, 0));
      expect(h.takeOutput(), '\x1b[<0;3;1M\x1b[<0;3;1m');
    });
  });

  group('inside other gesture handlers', () {
    Widget Function(Widget) inList(ScrollController list) =>
        (Widget view) => SizedBox(
          width: 400,
          height: 300,
          child: ListView(
            controller: list,
            children: [view, const SizedBox(height: 1000)],
          ),
        );

    testWidgets('a ListView does not scroll while the terminal does', (
      tester,
    ) async {
      final list = ScrollController();
      addTearDown(list.dispose);
      final h = await pumpPointerScope(tester, wrap: inList(list));
      writeLines(h.controller, 30);
      final bottom = h.bar.offset;

      final touch = await tester.startGesture(h.cell(5, 1));
      await touch.moveBy(const Offset(0, 60));
      await touch.up();
      await tester.pumpAndSettle();
      expect(h.bar.offset, bottom - 3);
      expect(list.offset, 0);

      final pad = await tester.createGesture(kind: PointerDeviceKind.trackpad);
      await pad.panZoomStart(h.cell(5, 1));
      await pad.panZoomUpdate(h.cell(5, 1), pan: const Offset(0, 40));
      await pad.panZoomEnd();
      await tester.pumpAndSettle();
      expect(h.bar.offset, bottom - 5);
      expect(list.offset, 0);
    });

    testWidgets('with nothing to scroll the ListView gets the drag', (
      tester,
    ) async {
      final list = ScrollController();
      addTearDown(list.dispose);
      await pumpPointerScope(tester, wrap: inList(list));
      final touch = await tester.startGesture(const Offset(50, 50));
      // The list drops the distance before it accepts (DragStartBehavior
      // .start), so move again after the slop.
      await touch.moveBy(const Offset(0, -30));
      await touch.moveBy(const Offset(0, -30));
      await touch.up();
      await tester.pumpAndSettle();
      expect(list.offset, greaterThan(0));
    });

    testWidgets('a long-press drag in a PageView selects, the page stays', (
      tester,
    ) async {
      final pages = PageController();
      addTearDown(pages.dispose);
      final h = await pumpPointerScope(
        tester,
        wrap: (view) => SizedBox(
          width: 400,
          height: 300,
          child: PageView(
            controller: pages,
            children: [
              Align(alignment: Alignment.topLeft, child: view),
              const SizedBox.expand(),
            ],
          ),
        ),
      );
      h.controller.write('alpha beta gamma');
      final touch = await tester.startGesture(h.cell(1, 0));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await touch.moveBy(const Offset(120, 0));
      await touch.up();
      await tester.pumpAndSettle();
      expect(pages.page, 0);
      expect(h.controller.selectedText, 'alpha beta gam');
    });
  });

  group('cursor', () {
    testWidgets('I-beam over text, arrow while tracked, OSC 22 shapes', (
      tester,
    ) async {
      final h = await pumpPointerScope(tester);
      await _mouse(tester, h.cell(1, 1));
      await tester.pump();
      expect(_activeCursor(), SystemMouseCursors.text);

      h.controller.write(_sgrClicks);
      await _settleCursor(tester);
      expect(_activeCursor(), SystemMouseCursors.basic);

      await _withKeys(tester, [LogicalKeyboardKey.shiftLeft], () async {
        await _settleCursor(tester);
        expect(_activeCursor(), SystemMouseCursors.text);
      });
      await _settleCursor(tester);
      expect(_activeCursor(), SystemMouseCursors.basic);

      h.controller.write('\x1b]22;pointer\x1b\\');
      await _settleCursor(tester);
      expect(_activeCursor(), SystemMouseCursors.click);
    });

    testWidgets('mouseCursor replaces the I-beam', (tester) async {
      final h = await pumpPointerScope(
        tester,
        mouseCursor: SystemMouseCursors.precise,
      );
      await _mouse(tester, h.cell(1, 1));
      await tester.pump();
      expect(_activeCursor(), SystemMouseCursors.precise);
    });

    testWidgets('other keys schedule no frame', (tester) async {
      await pumpPointerScope(tester);
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
      expect(SchedulerBinding.instance.hasScheduledFrame, isFalse);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
    });
  });

  testWidgets('events after the controller is disposed do nothing', (
    tester,
  ) async {
    final h = await pumpPointerScope(tester);
    final mouse = await _mouse(tester, h.cell(1, 1));
    h.controller.dispose();
    await _drag(mouse, h.cell(1, 1), h.cell(3, 1));
    await sendWheel(tester, h.cell(1, 1), const Offset(0, -60));
    await tester.tapAt(h.cell(1, 1));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
