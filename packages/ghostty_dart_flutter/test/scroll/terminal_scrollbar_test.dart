// Tests of the viewport scrollbar (ADR 0011): thumb geometry, when it
// shows and fades, what it lets through, dragging and scrolling over it.

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart_flutter/src/scroll/terminal_scrollbar.dart';

import '../input/pointer/pointer_test_harness.dart';

/// The painted thumb.
Finder get _thumb => find.descendant(
  of: find.byType(TerminalScrollbar),
  matching: find.byType(DecoratedBox),
);

double _opacity(WidgetTester tester) => tester
    .widget<AnimatedOpacity>(
      find.descendant(
        of: find.byType(TerminalScrollbar),
        matching: find.byType(AnimatedOpacity),
      ),
    )
    .opacity;

/// A little longer than the fade delay plus the fade.
const _afterFade = Duration(milliseconds: 1000);

/// 36 rows of content in a 20 x 5 terminal, with the scrollbar shown by a
/// one-row wheel scroll up.
Future<PointerHarness> _shownBar(WidgetTester tester) async {
  final h = await pumpPointerScope(tester);
  writeLines(h.controller, 35);
  await sendWheel(tester, h.cell(1, 1), const Offset(0, -20));
  await tester.pump();
  expect(_opacity(tester), 1);
  return h;
}

/// A point on the thumb (its middle).
Offset _onThumb(WidgetTester tester) => tester.getCenter(_thumb);

void main() {
  group('scrollbarThumb', () {
    test('nothing to scroll or no room: no thumb', () {
      expect(
        scrollbarThumb(
          const ViewportScrollbar(total: 5, offset: 0, length: 5),
          100,
        ),
        isNull,
      );
      expect(
        scrollbarThumb(
          const ViewportScrollbar(total: 0, offset: 0, length: 0),
          100,
        ),
        isNull,
      );
      const bar = ViewportScrollbar(total: 50, offset: 0, length: 5);
      expect(
        scrollbarThumb(bar, 2 * kTerminalScrollbarMinThumbExtent - 1),
        isNull,
      );
      expect(scrollbarThumb(bar, 0), isNull);
    });

    test('proportional, positioned by offset', () {
      const top = ViewportScrollbar(total: 40, offset: 0, length: 10);
      expect(scrollbarThumb(top, 200), (top: 0.0, extent: 50.0));
      const bottom = ViewportScrollbar(total: 40, offset: 30, length: 10);
      expect(scrollbarThumb(bottom, 200), (top: 150.0, extent: 50.0));
      const middle = ViewportScrollbar(total: 40, offset: 15, length: 10);
      expect(scrollbarThumb(middle, 200)!.top, 75.0);
    });

    test('never shorter than the minimum extent', () {
      const huge = ViewportScrollbar(total: 100000, offset: 0, length: 10);
      expect(
        scrollbarThumb(huge, 200)!.extent,
        kTerminalScrollbarMinThumbExtent,
      );
    });

    test('scrollbarRowAt inverts the thumb position, clamped', () {
      const bar = ViewportScrollbar(total: 40, offset: 7, length: 10);
      expect(scrollbarRowAt(bar, 200, 0), 0);
      expect(scrollbarRowAt(bar, 200, 75), 15);
      expect(scrollbarRowAt(bar, 200, 150), 30);
      expect(scrollbarRowAt(bar, 200, -40), 0);
      expect(scrollbarRowAt(bar, 200, 999), 30);
      expect(scrollbarRowAt(bar, 20, 5), 7, reason: 'no thumb: stays');
    });
  });

  testWidgets('hidden without scrollback', (tester) async {
    final h = await pumpPointerScope(tester);
    h.controller.write('a few\r\nlines');
    await tester.pump();
    expect(_thumb, findsNothing);
  });

  testWidgets('output does not show it, at the bottom or anchored above', (
    tester,
  ) async {
    final h = await pumpPointerScope(tester);
    writeLines(h.controller, 30);
    await tester.pump();
    expect(_thumb, findsOneWidget);
    expect(_opacity(tester), 0);

    h.controller.scrollViewport(const ViewportScroll.delta(-5));
    await tester.pump(_afterFade);
    expect(_opacity(tester), 0);

    // More output under the anchored viewport only grows the total.
    writeLines(h.controller, 10, from: 30);
    await tester.pump();
    expect(_opacity(tester), 0);
  });

  testWidgets('scrolling shows it; it fades after the delay and then lets '
      'the pointer through', (tester) async {
    final h = await _shownBar(tester);
    await tester.pump(kTerminalScrollbarTimeToFade);
    await tester.pump(kTerminalScrollbarFadeDuration);
    expect(_opacity(tester), 0);

    // A click on where the thumb was reaches the terminal, which clears
    // the selection.
    h.controller.selectAll();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: _onThumb(tester));
    addTearDown(mouse.removePointer);
    await mouse.down(_onThumb(tester));
    await mouse.up();
    expect(h.controller.selection, isNull);
  });

  testWidgets('while shown, only the thumb takes the pointer: the last '
      'column stays selectable', (tester) async {
    final h = await _shownBar(tester);
    final thumb = tester.getRect(_thumb);
    // A row of the last column that the thumb does not cover.
    final row = thumb.top > h.geometry.metrics.height ? 0 : 4;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    final start = h.cell(19, row, dx: 0.9);
    await mouse.addPointer(location: start);
    addTearDown(mouse.removePointer);
    await mouse.down(start);
    await mouse.moveTo(h.cell(0, row, dx: 0.1));
    await mouse.up();
    expect(h.controller.selectedText, matches(RegExp(r'^line \d+$')));
  });

  testWidgets('a trackpad pan over the thumb still scrolls', (tester) async {
    final h = await _shownBar(tester);
    final before = h.bar.offset;
    final pad = await tester.createGesture(kind: PointerDeviceKind.trackpad);
    await pad.panZoomStart(_onThumb(tester));
    await pad.panZoomUpdate(_onThumb(tester), pan: const Offset(0, 40));
    await pad.panZoomEnd();
    expect(h.bar.offset, before - 2);
  });

  testWidgets('the wheel over the thumb is routed like over the terminal', (
    tester,
  ) async {
    final h = await _shownBar(tester);
    final before = h.bar.offset;
    await sendWheel(tester, _onThumb(tester), const Offset(0, -40));
    expect(h.bar.offset, before - 2);

    h.controller.write('\x1b[?1000h\x1b[?1006h');
    await sendWheel(tester, _onThumb(tester), const Offset(0, -20));
    expect(h.takeOutput(), startsWith('\x1b[<64;20;'));
    expect(h.bar.offset, before - 2);
  });

  testWidgets('the painted thumb follows the viewport', (tester) async {
    final h = await pumpPointerScope(tester);
    writeLines(h.controller, 35); // 36 rows, 5 visible
    final height = h.geometry.viewSize.height;
    h.controller.scrollViewport(const ViewportScroll.top());
    await tester.pump();
    final top = tester.getRect(_thumb);
    expect(top.top, 0);
    expect(top.right, h.geometry.viewSize.width);
    expect(top.width, kTerminalScrollbarThickness);
    expect(top.height, scrollbarThumb(h.bar, height)!.extent);

    h.controller.scrollViewport(const ViewportScroll.bottom());
    await tester.pump();
    expect(tester.getRect(_thumb).bottom, height);
  });

  testWidgets('dragging the thumb scrolls; it stays while dragged; a second '
      'pointer is ignored', (tester) async {
    final h = await _shownBar(tester);
    final thumb = tester.getRect(_thumb);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: thumb.center);
    addTearDown(mouse.removePointer);
    await mouse.down(thumb.center);
    await mouse.moveBy(Offset(0, -thumb.top - 10));
    expect(h.bar.offset, 0);

    final touch = await tester.startGesture(tester.getCenter(_thumb));
    await touch.moveBy(const Offset(0, 200));
    await touch.up();
    expect(h.bar.offset, 0, reason: 'only the first pointer drags');

    await tester.pump(_afterFade);
    expect(_opacity(tester), 1);
    await mouse.moveBy(Offset(0, h.geometry.viewSize.height));
    expect(h.bar.isAtBottom, isTrue);
    await mouse.up();
    await tester.pump(_afterFade);
    expect(_opacity(tester), 0);
  });

  testWidgets('a new viewport is followed, the old one is not', (tester) async {
    final a = createHarness();
    final b = createHarness();
    writeLines(a.controller, 30);
    writeLines(b.controller, 30);
    await tester.pumpWidget(
      testApp(pointerScopeUnderTest(a.seams, a.geometry)),
    );
    await tester.pumpWidget(
      testApp(pointerScopeUnderTest(b.seams, b.geometry)),
    );

    a.controller.scrollViewport(const ViewportScroll.top());
    await tester.pump();
    expect(_opacity(tester), 0);
    b.controller.scrollViewport(const ViewportScroll.top());
    await tester.pump();
    expect(_opacity(tester), 1);
    expect(tester.getRect(_thumb).top, 0);
    // Drain the fade timer.
    await tester.pump(_afterFade);
  });

  testWidgets('a notification during build is polled after the frame', (
    tester,
  ) async {
    final h = createHarness();
    writeLines(h.controller, 30);
    late StateSetter rebuild;
    var scrollInBuild = false;
    await tester.pumpWidget(
      testApp(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            if (scrollInBuild) {
              scrollInBuild = false;
              // Notifies the mounted scrollbar while the tree is built.
              h.controller.scrollViewport(const ViewportScroll.top());
            }
            return pointerScopeUnderTest(h.seams, h.geometry);
          },
        ),
      ),
    );
    rebuild(() => scrollInBuild = true);
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pump();
    expect(tester.getRect(_thumb).top, 0);
    expect(_opacity(tester), 1);
    // Drain the fade timer.
    await tester.pump(_afterFade);
  });
}
