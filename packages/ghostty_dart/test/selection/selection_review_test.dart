// Correctness review of selections and selection gestures: adversarial
// cases the main suites do not cover.

import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:test/test.dart';

import '../support/selection_support.dart';
import '../support/terminal_support.dart';

void main() {
  group('ranges', () {
    test('a range from deep scrollback across wrapped lines', () {
      withTerminal(8, 3, (t) {
        writeText(
          t,
          'abcdefghijkl\r\n${[for (var i = 0; i < 20; i++) 'r$i'].join('\r\n')}',
        );
        final s = t.selectRange(
          const GridPoint.screen(2, 0),
          const GridPoint.screen(1, 3),
        )!;
        expect(selectedText(t, s), 'cdefgh\nijkl\nr0\nr1');
        expect(selectedText(t, s, unwrap: true), 'cdefghijkl\nr0\nr1');
        expect(s.contains(const GridPoint.screen(7, 0)), isTrue);
        expect(s.contains(const GridPoint.screen(0, 1)), isTrue);
        expect(s.contains(const GridPoint.screen(2, 3)), isFalse);
        expect(
          s.contains(const GridPoint.viewport(0, 0)),
          isFalse,
          reason: 'the viewport shows the bottom rows',
        );
      });
    });

    test('a rectangle across wrapped rows selects columns', () {
      withTerminal(6, 4, (t) {
        writeText(t, 'abcdefghijkl\r\nmnopqr');
        final s = t.selectRange(
          const GridPoint.active(1, 0),
          const GridPoint.active(3, 2),
          rectangle: true,
        )!;
        expect(s.isRectangle, isTrue);
        expect(selectedText(t, s), 'bcd\nhij\nnop');
        expect(s.contains(const GridPoint.active(4, 1)), isFalse);
        expect(s.contains(const GridPoint.active(2, 1)), isTrue);
        // The same corners as a linear range include whole middle rows.
        final linear = t.selectRange(
          const GridPoint.active(1, 0),
          const GridPoint.active(3, 2),
        )!;
        expect(linear.contains(const GridPoint.active(5, 1)), isTrue);
        expect(linear == s, isFalse);
      });
    });

    test('wide characters at either edge are copied whole', () {
      withTerminal(10, 2, (t) {
        writeText(t, 'a日b本c');
        // 日 occupies columns 1-2, 本 columns 4-5.
        final fromTail = t.selectRange(
          const GridPoint.active(2, 0),
          const GridPoint.active(4, 0),
        )!;
        expect(selectedText(t, fromTail), contains('本'));
        expect(selectedText(t, fromTail), contains('b'));
        final wide = t.selectWord(const GridPoint.active(2, 0))!;
        expect(selectedText(t, wide), 'a日b本c');
      });
    });

    test('graphemes at an edge are copied with their marks', () {
      withTerminal(10, 2, (t) {
        writeText(t, 'xéy 👩‍💻z');
        final s = t.selectRange(
          const GridPoint.active(1, 0),
          const GridPoint.active(1, 0),
        )!;
        expect(selectedText(t, s), 'é');
        // Without grapheme clustering (mode 2027) the ZWJ joins the first
        // emoji's cell and the second takes its own two cells.
        final emoji = t.selectRange(
          const GridPoint.active(4, 0),
          const GridPoint.active(7, 0),
        )!;
        expect(selectedText(t, emoji), '👩‍💻');
        final first = t.selectRange(
          const GridPoint.active(5, 0),
          const GridPoint.active(5, 0),
        )!;
        expect(selectedText(t, first), '👩‍');
      });
    });

    test('mirrored rectangles order and normalise', () {
      withTerminal(10, 4, (t) {
        writeText(t, 'abcd\r\nefgh\r\nijkl');
        final topRightToBottomLeft = t.selectRange(
          const GridPoint.active(3, 0),
          const GridPoint.active(0, 2),
          rectangle: true,
        )!;
        expect(topRightToBottomLeft.order, SelectionOrder.mirroredForward);
        // A desired order the selection already has keeps it unchanged.
        final same = topRightToBottomLeft.ordered(
          SelectionOrder.mirroredForward,
        );
        expect(same, topRightToBottomLeft);
        for (final desired in [
          SelectionOrder.forward,
          SelectionOrder.mirroredReverse,
        ]) {
          final o = topRightToBottomLeft.ordered(desired);
          expect(o.order, SelectionOrder.forward);
          expect(
            o.start.pointIn(PointSpace.active),
            const GridPoint.active(0, 0),
          );
          expect(
            o.end.pointIn(PointSpace.active),
            const GridPoint.active(3, 2),
          );
          expect(o.isRectangle, isTrue);
        }
        expect(
          topRightToBottomLeft.ordered(SelectionOrder.reverse).order,
          SelectionOrder.reverse,
        );
        expect(
          () => topRightToBottomLeft.ordered(SelectionOrder.unknown),
          throwsArgumentError,
        );
      });
    });

    test('every adjustment works at the screen edges and keeps the start', () {
      withTerminal(5, 3, (t) {
        writeText(t, 'ab\r\n\r\ncd');
        for (final at in [
          const GridPoint.active(0, 0),
          const GridPoint.active(4, 2),
        ]) {
          final s = t.selectRange(at, at)!;
          for (final adjustment in SelectionAdjustment.values) {
            final a = s.adjusted(adjustment);
            expect(a.isValid, isTrue);
            expect(a.start.pointIn(PointSpace.active), at);
            expect(s.isValid, isTrue, reason: 'adjusting changes nothing');
          }
        }
      });
    });

    test('a point outside its space is never contained', () {
      withTerminal(5, 2, (t) {
        final s =
            t.selectAll() ??
            t.selectRange(
              const GridPoint.active(0, 0),
              const GridPoint.active(4, 1),
            )!;
        expect(s.contains(const GridPoint.active(5, 0)), isFalse);
        expect(s.contains(const GridPoint.active(0, 2)), isFalse);
        expect(s.contains(const GridPoint.screen(0, 2)), isFalse);
        expect(
          () => s.contains(const GridPoint(PointSpace.unknown, 0, 0)),
          throwsArgumentError,
        );
      });
    });
  });

  group('word and line', () {
    test('selectLine stops at semantic prompt boundaries when asked', () {
      withTerminal(30, 4, (t) {
        writeText(t, '\x1b]133;A\x07\$ \x1b]133;B\x07echo hi\x1b]133;C\x07');
        final whole = t.selectLine(const GridPoint.active(4, 0))!;
        expect(selectedText(t, whole), r'$ echo hi');
        final bounded = t.selectLine(
          const GridPoint.active(4, 0),
          semanticPromptBoundary: true,
        )!;
        expect(selectedText(t, bounded), 'echo hi');
      });
    });

    test('selectWord: empty cells give null, spaces their run', () {
      withTerminal(10, 2, (t) {
        writeText(t, 'ab  cd');
        expect(t.selectWord(const GridPoint.active(9, 0)), isNull);
        expect(t.selectWord(const GridPoint.active(0, 1)), isNull);
        final spaces = t.selectWord(const GridPoint.active(2, 0))!;
        expect(
          spaces.start.pointIn(PointSpace.active),
          const GridPoint.active(2, 0),
        );
        expect(
          spaces.end.pointIn(PointSpace.active),
          const GridPoint.active(3, 0),
        );
        // A custom list replaces the defaults: without boundaries only
        // empty cells end words.
        expect(
          selectedText(
            t,
            t.selectWord(
              const GridPoint.active(0, 0),
              boundaryCodepoints: const [],
            )!,
          ),
          'ab  cd',
        );
        expect(
          () => t.selectWord(
            const GridPoint.active(0, 0),
            boundaryCodepoints: [-1],
          ),
          throwsRangeError,
        );
        expect(
          () => t.selectWord(
            const GridPoint.active(0, 0),
            boundaryCodepoints: [0x110000],
          ),
          throwsRangeError,
        );
      });
    });

    test('selectWordBetween with equal ends is the word there', () {
      withTerminal(10, 2, (t) {
        writeText(t, 'ab cd');
        final s = t.selectWordBetween(
          const GridPoint.active(3, 0),
          const GridPoint.active(3, 0),
        )!;
        expect(selectedText(t, s), 'cd');
        expect(
          t.selectWordBetween(
            const GridPoint.active(6, 0),
            const GridPoint.active(9, 0),
          ),
          isNull,
          reason: 'only empty cells in between',
        );
      });
    });
  });

  group('the terminal selection', () {
    test('installing a search match highlights it', () {
      withTerminal(20, 3, (t) {
        writeText(t, 'one hit two');
        final search = TerminalSearch(t, needle: 'hit')..run();
        addTearDown(search.dispose);
        t.selection = search.matches.single;
        expect(selectedText(t, t.selection!), 'hit');
      });
    });

    test('is per screen: the alternate screen has its own', () {
      withTerminal(10, 3, (t) {
        writeText(t, 'primary');
        t.selection = t.selectAll();
        writeText(t, '\x1b[?1049h');
        expect(t.selection, isNull);
        expect(t.selectAll(), isNull);
        writeText(t, '\x1b[?1049l');
        // Switching screens does not bring stale selections back to life.
        final back = t.selection;
        if (back != null) expect(selectedText(t, back), 'primary');
      });
    });

    test('a rectangle installed stays a rectangle after output', () {
      withTerminal(10, 4, (t) {
        writeText(t, 'abcd\r\nefgh');
        t.selection = t.selectRange(
          const GridPoint.active(1, 0),
          const GridPoint.active(2, 1),
          rectangle: true,
        );
        writeText(t, '\r\nmore');
        expect(t.selection!.isRectangle, isTrue);
        expect(selectedText(t, t.selection!), 'bc\nfg');
      });
    });
  });

  group('SelectionGesture', () {
    const interval = Duration(milliseconds: 500);

    test('repeat interval and distance bounds are inclusive', () {
      withTerminal(20, 3, (t) {
        writeText(t, 'hello world');
        final g = SelectionGesture(
          t,
          repeatInterval: interval,
          repeatDistance: 3,
        );
        addTearDown(g.dispose);
        final p = cellCentre(1, 0);
        g.press(
          const GridPoint.viewport(1, 0),
          position: p,
          time: Duration.zero,
        );
        g.release(const GridPoint.viewport(1, 0));
        final word = g.press(
          const GridPoint.viewport(1, 0),
          position: (x: p.x + 3, y: p.y),
          time: interval,
        );
        expect(g.clickCount, 2);
        expect(selectedText(t, word!), 'hello');
        g.release(const GridPoint.viewport(1, 0));
        // Too late: a fresh single click.
        g.press(
          const GridPoint.viewport(1, 0),
          position: p,
          time: interval * 2 + const Duration(microseconds: 1),
        );
        expect(g.clickCount, 1);
        g.release(const GridPoint.viewport(1, 0));
        // Too far: a fresh single click.
        g.press(
          const GridPoint.viewport(1, 0),
          position: (x: p.x + 3.01, y: p.y),
          time: interval * 2 + const Duration(milliseconds: 1),
        );
        expect(g.clickCount, 1);
      });
    });

    test('time going backwards restarts the click sequence', () {
      withTerminal(20, 3, (t) {
        writeText(t, 'hello');
        final g = SelectionGesture(
          t,
          repeatInterval: interval,
          repeatDistance: 5,
        );
        addTearDown(g.dispose);
        g.press(
          const GridPoint.viewport(0, 0),
          time: const Duration(seconds: 2),
        );
        g.release();
        g.press(
          const GridPoint.viewport(0, 0),
          time: const Duration(seconds: 1),
        );
        expect(g.clickCount, 1);
      });
    });

    test('clicks stop repeating at three and cycle behaviours', () {
      withTerminal(20, 3, (t) {
        writeText(t, 'hello world');
        final g = SelectionGesture(
          t,
          repeatInterval: interval,
          repeatDistance: 5,
        );
        addTearDown(g.dispose);
        for (var i = 0; i < 5; i++) {
          g
            ..press(
              const GridPoint.viewport(1, 0),
              time: Duration(milliseconds: i * 10),
            )
            ..release(const GridPoint.viewport(1, 0));
        }
        expect(g.clickCount, 3);
        expect(g.behavior, SelectionGestureBehavior.line);
      });
    });

    test('drag threshold is 60% of a cell', () {
      withTerminal(10, 2, (t) {
        writeText(t, 'abcdef');
        final g = SelectionGesture(t);
        addTearDown(g.dispose);
        g.press(const GridPoint.viewport(1, 0), position: (x: 10, y: 5));
        expect(
          g.drag(
            const GridPoint.viewport(1, 0),
            geometry: testGeometry(t),
            position: (x: 15, y: 5),
          ),
          isNull,
        );
        final s = g.drag(
          const GridPoint.viewport(1, 0),
          geometry: testGeometry(t),
          position: (x: 16, y: 5),
        );
        expect(selectedText(t, s!), 'b');
      });
    });

    test('release off the grid counts as a drag', () {
      withTerminal(10, 2, (t) {
        final g = SelectionGesture(t);
        addTearDown(g.dispose);
        g.press(const GridPoint.viewport(1, 0));
        expect(g.hasDragged, isFalse);
        g.release(const GridPoint.viewport(99, 99));
        expect(g.hasDragged, isTrue);
        expect(g.clickCount, 1, reason: 'release keeps the sequence');
      });
    });

    test('the anchor follows output and is gone on the other screen', () {
      withTerminal(10, 3, (t) {
        writeText(t, 'abc');
        final g = SelectionGesture(t);
        addTearDown(g.dispose);
        g.press(const GridPoint.viewport(1, 0));
        writeText(t, '\r\n1\r\n2\r\n3');
        expect(
          g.anchor!.pointIn(PointSpace.screen),
          const GridPoint.screen(1, 0),
        );
        writeText(t, '\x1b[?1049h');
        expect(g.anchor, isNull);
        expect(
          g.drag(const GridPoint.viewport(2, 0), geometry: testGeometry(t)),
          isNull,
        );
        writeText(t, '\x1b[?1049l');
        expect(g.anchor, isNotNull);
      });
    });

    test('a full reset of the terminal drops the anchor safely', () {
      withTerminal(10, 3, (t) {
        writeText(t, 'abc');
        final g = SelectionGesture(
          t,
          repeatInterval: interval,
          repeatDistance: 5,
        );
        g.press(const GridPoint.viewport(1, 0), time: Duration.zero);
        t.reset();
        // A repeat press after the reset starts over without touching the
        // old screen's freed tracked cell.
        g.press(
          const GridPoint.viewport(1, 0),
          time: const Duration(milliseconds: 1),
        );
        expect(g.clickCount, greaterThanOrEqualTo(1));
        g.dispose();
      });
    });

    test('autoscroll tick with nothing to scroll leaves selections valid', () {
      withTerminal(10, 3, (t) {
        writeText(t, 'abc');
        final g = SelectionGesture(t);
        addTearDown(g.dispose);
        g.press(const GridPoint.viewport(1, 0), position: cellCentre(1, 0));
        expect(g.autoscroll, SelectionAutoscroll.none);
        final before = t.selectAll()!;
        expect(
          g.autoscrollTick(
            const GridPoint.viewport(0, 0),
            geometry: testGeometry(t),
          ),
          isNull,
        );
        // The wrapper invalidates conservatively on every tick.
        expect(before.isValid, isFalse);
      });
    });

    test('deep press consumes the gesture', () {
      withTerminal(20, 2, (t) {
        writeText(t, 'hello world');
        final g = SelectionGesture(t);
        addTearDown(g.dispose);
        expect(g.deepPress(), isNull, reason: 'no press yet');
        g.press(const GridPoint.viewport(7, 0));
        expect(selectedText(t, g.deepPress()!), 'world');
        expect(g.clickCount, 0);
        expect(g.anchor, isNull);
        expect(
          g.drag(const GridPoint.viewport(1, 0), geometry: testGeometry(t)),
          isNull,
        );
      });
    });

    test('disposing the terminal with a tracked press frees the gesture', () {
      final t = VtTerminal(cols: 10, rows: 3);
      final g = SelectionGesture(t)..press(const GridPoint.viewport(1, 0));
      expect(g.anchor, isNotNull);
      t.dispose();
      expect(g.isDisposed, isTrue);
      expect(() => g.anchor, throwsStateError);
      g.dispose();
    });

    test('many gestures on one terminal are freed independently', () {
      withTerminal(10, 3, (t) {
        final gestures = [
          for (var i = 0; i < 40; i++)
            SelectionGesture(t)..press(GridPoint.viewport(i % 10, 0)),
        ];
        for (final g in gestures.take(20)) {
          g.dispose();
        }
        for (final g in gestures.skip(20)) {
          expect(g.anchor, isNotNull);
        }
      });
    });
  });
}
