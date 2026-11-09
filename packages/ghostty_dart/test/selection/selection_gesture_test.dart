import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:test/test.dart';

import '../support/selection_support.dart';
import '../support/terminal_support.dart';

/// A position in viewport cell ([x], [y]), past its middle: a drag to the
/// right includes a cell once the pointer crosses half of it.
({double x, double y}) _past(int x, int y) => (
  x: x * testCellSize + testCellSize * 0.8,
  y: y * testCellSize + testCellSize / 2,
);

void main() {
  group('SelectionGesture', () {
    test('click and drag selects cells', () {
      withTerminal(10, 3, (t) {
        writeText(t, 'abcdefgh\r\nijklmnop');
        final g = SelectionGesture(t);
        addTearDown(g.dispose);
        expect(g.clickCount, 0);
        expect(g.anchor, isNull);
        expect(
          g.press(const GridPoint.viewport(1, 0), position: cellCentre(1, 0)),
          isNull,
          reason: 'a single click selects nothing',
        );
        expect(g.clickCount, 1);
        expect(g.behavior, SelectionGestureBehavior.cell);
        expect(
          g.anchor!.pointIn(PointSpace.viewport),
          const GridPoint.viewport(1, 0),
        );
        expect(g.hasDragged, isFalse);

        final s = g.drag(
          const GridPoint.viewport(4, 1),
          geometry: testGeometry(t),
          position: _past(4, 1),
        )!;
        expect(g.hasDragged, isTrue);
        expect(g.autoscroll, SelectionAutoscroll.none);
        expect(selectedText(t, s), 'bcdefgh\nijklm');
        expect(t.selection, isNull, reason: 'the gesture never installs it');
        t.selection = s;
        g.release(const GridPoint.viewport(4, 1));
        expect(selectedText(t, t.selection!), 'bcdefgh\nijklm');
      });
    });

    test('a rectangular drag selects a block', () {
      withTerminal(10, 3, (t) {
        writeText(t, 'abcdefgh\r\nijklmnop');
        final g = SelectionGesture(t);
        addTearDown(g.dispose);
        g.press(const GridPoint.viewport(1, 0), position: cellCentre(1, 0));
        final s = g.drag(
          const GridPoint.viewport(3, 1),
          geometry: testGeometry(t),
          position: _past(3, 1),
          rectangle: true,
        )!;
        expect(s.isRectangle, isTrue);
        expect(selectedText(t, s), 'bcd\njkl');
      });
    });

    test('double and triple clicks select words and lines', () {
      withTerminal(20, 3, (t) {
        writeText(t, 'hello big world');
        final g = SelectionGesture(
          t,
          repeatInterval: const Duration(milliseconds: 500),
          repeatDistance: 5,
        );
        addTearDown(g.dispose);
        const at = GridPoint.viewport(7, 0);
        Duration ms(int n) => Duration(milliseconds: n);
        expect(g.press(at, position: cellCentre(7, 0), time: ms(1000)), isNull);
        g.release(at);
        final word = g.press(at, position: cellCentre(7, 0), time: ms(1100))!;
        expect(g.clickCount, 2);
        expect(g.behavior, SelectionGestureBehavior.word);
        expect(selectedText(t, word), 'big');
        g.release(at);
        final line = g.press(at, position: cellCentre(7, 0), time: ms(1200))!;
        expect(g.clickCount, 3);
        expect(g.behavior, SelectionGestureBehavior.line);
        expect(selectedText(t, line), 'hello big world');
        g.release(at);

        // Too late: a fresh single click.
        expect(g.press(at, position: cellCentre(7, 0), time: ms(5000)), isNull);
        expect(g.clickCount, 1);
      });
    });

    test('without timing, clicks never repeat', () {
      withTerminal(20, 3, (t) {
        writeText(t, 'hello big world');
        final g = SelectionGesture(t);
        addTearDown(g.dispose);
        const at = GridPoint.viewport(7, 0);
        g
          ..press(at, position: cellCentre(7, 0), time: Duration.zero)
          ..release(at)
          ..press(
            at,
            position: cellCentre(7, 0),
            time: const Duration(milliseconds: 1),
          );
        expect(g.clickCount, 1);
      });
    });

    test('custom behaviors and word boundaries', () {
      withTerminal(30, 3, (t) {
        writeText(t, 'path/to/file');
        final g = SelectionGesture(
          t,
          behaviors: const SelectionGestureBehaviors(
            singleClick: SelectionGestureBehavior.word,
          ),
          wordBoundaryCodepoints: '/'.runes.toList(),
        );
        addTearDown(g.dispose);
        final s = g.press(
          const GridPoint.viewport(5, 0),
          position: cellCentre(5, 0),
        )!;
        expect(g.behavior, SelectionGestureBehavior.word);
        expect(selectedText(t, s), 'to');
        expect(g.wordBoundaryCodepoints, ['/'.runes.first]);
        expect(() => g.wordBoundaryCodepoints!.add(1), throwsUnsupportedError);
      });
    });

    test('deep press selects the word under the press', () {
      withTerminal(20, 3, (t) {
        writeText(t, 'hello big world');
        final g = SelectionGesture(t);
        addTearDown(g.dispose);
        expect(g.deepPress(), isNull, reason: 'no press yet');
        g.press(const GridPoint.viewport(12, 0), position: cellCentre(12, 0));
        expect(selectedText(t, g.deepPress()!), 'world');
      });
    });

    test('dragging above the terminal autoscrolls into the scrollback', () {
      withTerminal(10, 3, (t) {
        writeText(t, [for (var i = 0; i < 10; i++) 'line$i'].join('\r\n'));
        final g = SelectionGesture(t);
        addTearDown(g.dispose);
        final geometry = testGeometry(t);
        g.press(const GridPoint.viewport(2, 1), position: cellCentre(2, 1));
        g.drag(
          const GridPoint.viewport(0, 0),
          geometry: geometry,
          position: (x: 0, y: 0),
        );
        expect(g.autoscroll, SelectionAutoscroll.up);
        expect(t.isViewportActive, isTrue);
        final before = t.selectAll()!;
        final s = g.autoscrollTick(
          const GridPoint.viewport(0, 0),
          geometry: geometry,
          position: (x: 0, y: 0),
        )!;
        expect(
          before.isValid,
          isFalse,
          reason: 'scrolling changes the terminal',
        );
        expect(t.isViewportActive, isFalse);
        // One row of scrollback came into view; the drag continues at its
        // top-left cell, back to the press (exclusive at its middle).
        expect(selectedText(t, s), 'line6\nline7\nli');
        expect(s.order, SelectionOrder.reverse);
        g.release();
        expect(
          () => g.autoscrollTick(
            const GridPoint.active(0, 0),
            geometry: geometry,
          ),
          throwsArgumentError,
        );
      });
    });

    test('reset cancels the click sequence', () {
      withTerminal(10, 3, (t) {
        writeText(t, 'abc');
        final g = SelectionGesture(t);
        addTearDown(g.dispose);
        g.press(const GridPoint.viewport(0, 0));
        expect(g.clickCount, 1);
        g.reset();
        expect(g.clickCount, 0);
        expect(g.anchor, isNull);
      });
    });

    test('validates its arguments', () {
      withTerminal(10, 3, (t) {
        expect(
          () =>
              SelectionGesture(t, repeatInterval: const Duration(seconds: -1)),
          throwsRangeError,
        );
        expect(() => SelectionGesture(t, repeatDistance: -1), throwsRangeError);
        expect(
          () => SelectionGesture(t, wordBoundaryCodepoints: [0x110000]),
          throwsRangeError,
        );
        final g = SelectionGesture(t);
        addTearDown(g.dispose);
        expect(
          () => g.press(const GridPoint.viewport(10, 0)),
          throwsArgumentError,
        );
        expect(
          () => g.press(const GridPoint(PointSpace.unknown, 0, 0)),
          throwsArgumentError,
        );
        g.press(const GridPoint.viewport(0, 0));
        expect(
          () => g.drag(
            const GridPoint.viewport(1, 0),
            geometry: const SelectionGestureGeometry(
              columns: 0,
              cellWidth: 10,
              screenHeight: 30,
            ),
          ),
          throwsRangeError,
        );
        // Releasing off the grid is fine.
        g.release(const GridPoint.viewport(99, 99));
      });
    });

    test('values have equality', () {
      expect(
        const SelectionGestureBehaviors(),
        const SelectionGestureBehaviors(
          singleClick: SelectionGestureBehavior.cell,
          doubleClick: SelectionGestureBehavior.word,
          tripleClick: SelectionGestureBehavior.line,
        ),
      );
      expect(
        const SelectionGestureGeometry(
          columns: 1,
          cellWidth: 2,
          screenHeight: 3,
        ),
        isNot(
          const SelectionGestureGeometry(
            columns: 1,
            cellWidth: 2,
            screenHeight: 3,
            paddingLeft: 4,
          ),
        ),
      );
    });

    test('dispose is idempotent; the terminal disposes its gestures', () {
      final t = VtTerminal(cols: 10, rows: 3);
      final g = SelectionGesture(t)..press(const GridPoint.viewport(0, 0));
      final kept = SelectionGesture(t)..press(const GridPoint.viewport(1, 0));
      g
        ..dispose()
        ..dispose();
      expect(g.isDisposed, isTrue);
      expect(() => g.clickCount, throwsStateError);
      expect(() => g.press(const GridPoint.viewport(0, 0)), throwsStateError);
      t.dispose();
      expect(kept.isDisposed, isTrue);
      expect(kept.reset, throwsStateError);
      expect(() => SelectionGesture(t), throwsStateError);
    });

    test('cannot be used from inside a terminal callback', () {
      withTerminal(10, 3, (t) {
        final g = SelectionGesture(t);
        addTearDown(g.dispose);
        Object? error;
        Object? readError;
        t.onBell = () {
          try {
            g.press(const GridPoint.viewport(0, 0));
          } catch (e) {
            error = e;
          }
          try {
            g.clickCount;
          } catch (e) {
            readError = e;
          }
        };
        writeText(t, '\x07');
        expect(error, isA<StateError>());
        expect(
          readError,
          isA<StateError>().having(
            (e) => e.message,
            'message',
            startsWith('SelectionGesture.clickCount '),
          ),
        );
      });
    });
  });
}
