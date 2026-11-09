import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart/src/core/internal.dart';
import 'package:ghostty_dart/src/ffi/bindings.g.dart';
import 'package:ghostty_dart/src/selection/selection_enums.dart';
import 'package:test/test.dart';

import '../support/selection_support.dart';
import '../support/terminal_support.dart';

void main() {
  group('codecs', () {
    test('match the header', () {
      void expectCodec<E extends Enum>(
        RawEnumCodec<E> codec,
        List<E> values,
        E unknown,
        Map<E, int> expected,
      ) {
        expect(expected.keys.toSet(), values.toSet()..remove(unknown));
        expected.forEach((value, raw) {
          expect(codec.encode(value), raw, reason: '$value');
          expect(codec.decode(raw), value, reason: '$value');
        });
        expect(codec.decode(9999), unknown);
        expect(() => codec.encode(unknown), throwsArgumentError);
      }

      expectCodec(
        selectionOrderCodec,
        SelectionOrder.values,
        SelectionOrder.unknown,
        {
          SelectionOrder.forward:
              GhosttySelectionOrder.GHOSTTY_SELECTION_ORDER_FORWARD,
          SelectionOrder.reverse:
              GhosttySelectionOrder.GHOSTTY_SELECTION_ORDER_REVERSE,
          SelectionOrder.mirroredForward:
              GhosttySelectionOrder.GHOSTTY_SELECTION_ORDER_MIRRORED_FORWARD,
          SelectionOrder.mirroredReverse:
              GhosttySelectionOrder.GHOSTTY_SELECTION_ORDER_MIRRORED_REVERSE,
        },
      );
      expectCodec(
        selectionGestureBehaviorCodec,
        SelectionGestureBehavior.values,
        SelectionGestureBehavior.unknown,
        {
          SelectionGestureBehavior.cell: GhosttySelectionGestureBehavior
              .GHOSTTY_SELECTION_GESTURE_BEHAVIOR_CELL,
          SelectionGestureBehavior.word: GhosttySelectionGestureBehavior
              .GHOSTTY_SELECTION_GESTURE_BEHAVIOR_WORD,
          SelectionGestureBehavior.line: GhosttySelectionGestureBehavior
              .GHOSTTY_SELECTION_GESTURE_BEHAVIOR_LINE,
          SelectionGestureBehavior.output: GhosttySelectionGestureBehavior
              .GHOSTTY_SELECTION_GESTURE_BEHAVIOR_OUTPUT,
        },
      );
      expectCodec(
        selectionAutoscrollCodec,
        SelectionAutoscroll.values,
        SelectionAutoscroll.unknown,
        {
          SelectionAutoscroll.none: GhosttySelectionGestureAutoscroll
              .GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_NONE,
          SelectionAutoscroll.up: GhosttySelectionGestureAutoscroll
              .GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_UP,
          SelectionAutoscroll.down: GhosttySelectionGestureAutoscroll
              .GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_DOWN,
        },
      );
    });

    test('adjustments match the header', () {
      const expected = {
        SelectionAdjustment.left:
            GhosttySelectionAdjust.GHOSTTY_SELECTION_ADJUST_LEFT,
        SelectionAdjustment.right:
            GhosttySelectionAdjust.GHOSTTY_SELECTION_ADJUST_RIGHT,
        SelectionAdjustment.up:
            GhosttySelectionAdjust.GHOSTTY_SELECTION_ADJUST_UP,
        SelectionAdjustment.down:
            GhosttySelectionAdjust.GHOSTTY_SELECTION_ADJUST_DOWN,
        SelectionAdjustment.home:
            GhosttySelectionAdjust.GHOSTTY_SELECTION_ADJUST_HOME,
        SelectionAdjustment.end:
            GhosttySelectionAdjust.GHOSTTY_SELECTION_ADJUST_END,
        SelectionAdjustment.pageUp:
            GhosttySelectionAdjust.GHOSTTY_SELECTION_ADJUST_PAGE_UP,
        SelectionAdjustment.pageDown:
            GhosttySelectionAdjust.GHOSTTY_SELECTION_ADJUST_PAGE_DOWN,
        SelectionAdjustment.beginningOfLine:
            GhosttySelectionAdjust.GHOSTTY_SELECTION_ADJUST_BEGINNING_OF_LINE,
        SelectionAdjustment.endOfLine:
            GhosttySelectionAdjust.GHOSTTY_SELECTION_ADJUST_END_OF_LINE,
      };
      expect(expected.keys.toSet(), SelectionAdjustment.values.toSet());
      expected.forEach((value, raw) {
        expect(selectionAdjustmentToRaw(value), raw, reason: '$value');
      });
    });
  });

  group('selectRange', () {
    test('selects between two points in any space', () {
      withTerminal(10, 3, (t) {
        writeText(t, 'hello\r\nworld');
        final s = t.selectRange(
          const GridPoint.active(1, 0),
          const GridPoint.viewport(2, 1),
        )!;
        expect(s.isValid, isTrue);
        expect(s.isRectangle, isFalse);
        expect(
          s.start.pointIn(PointSpace.active),
          const GridPoint.active(1, 0),
        );
        expect(s.end.pointIn(PointSpace.active), const GridPoint.active(2, 1));
        expect(s.start.text, 'e');
        expect(selectedText(t, s), 'ello\nwor');
      });
    });

    test('returns null for points outside the space', () {
      withTerminal(10, 3, (t) {
        expect(
          t.selectRange(
            const GridPoint.active(0, 0),
            const GridPoint.active(10, 0),
          ),
          isNull,
        );
        expect(
          t.selectRange(
            const GridPoint.active(0, 3),
            const GridPoint.active(0, 0),
          ),
          isNull,
        );
        expect(
          () => t.selectRange(
            const GridPoint(PointSpace.unknown, 0, 0),
            const GridPoint.active(0, 0),
          ),
          throwsArgumentError,
        );
      });
    });

    test('spans the scrollback', () {
      withTerminal(10, 3, (t) {
        writeText(t, [for (var i = 0; i < 10; i++) 'row$i'].join('\r\n'));
        final s = t.selectRange(
          const GridPoint.history(0, 2),
          const GridPoint.active(3, 1),
        )!;
        expect(selectedText(t, s), 'row2\nrow3\nrow4\nrow5\nrow6\nrow7\nrow8');
        expect(s.start.pointIn(PointSpace.active), isNull);
        expect(
          s.start.pointIn(PointSpace.screen),
          const GridPoint.screen(0, 2),
        );
      });
    });
  });

  group('order, ordered, adjusted, contains', () {
    test('a reversed selection keeps its direction', () {
      withTerminal(10, 3, (t) {
        writeText(t, 'abcdef\r\nghijkl');
        final s = t.selectRange(
          const GridPoint.active(4, 1),
          const GridPoint.active(1, 0),
        )!;
        expect(s.order, SelectionOrder.reverse);
        final forward = s.ordered();
        expect(forward.order, SelectionOrder.forward);
        expect(
          forward.start.pointIn(PointSpace.active),
          const GridPoint.active(1, 0),
        );
        expect(
          forward.end.pointIn(PointSpace.active),
          const GridPoint.active(4, 1),
        );
        final back = forward.ordered(SelectionOrder.reverse);
        expect(back, s);
        expect(selectedText(t, s), selectedText(t, forward));
        expect(() => s.ordered(SelectionOrder.unknown), throwsArgumentError);
      });
    });

    test('mirrored orders of rectangles', () {
      withTerminal(10, 3, (t) {
        writeText(t, 'abcdef\r\nghijkl');
        final topRightToBottomLeft = t.selectRange(
          const GridPoint.active(4, 0),
          const GridPoint.active(1, 1),
          rectangle: true,
        )!;
        expect(topRightToBottomLeft.order, SelectionOrder.mirroredForward);
        final bottomLeftToTopRight = t.selectRange(
          const GridPoint.active(1, 1),
          const GridPoint.active(4, 0),
          rectangle: true,
        )!;
        expect(bottomLeftToTopRight.order, SelectionOrder.mirroredReverse);
        expect(topRightToBottomLeft.ordered().order, SelectionOrder.forward);
      });
    });

    test('adjusted moves the logical end and returns a new value', () {
      withTerminal(10, 3, (t) {
        writeText(t, 'abcdef\r\nghijkl');
        final s = t.selectRange(
          const GridPoint.active(1, 0),
          const GridPoint.active(2, 0),
        )!;
        final right = s.adjusted(SelectionAdjustment.right);
        expect(selectedText(t, right), 'bcd');
        expect(selectedText(t, s), 'bc', reason: 'the original is unchanged');
        expect(
          selectedText(t, s.adjusted(SelectionAdjustment.endOfLine)),
          'bcdef',
        );
        expect(
          s.adjusted(SelectionAdjustment.down).end.pointIn(PointSpace.active),
          const GridPoint.active(2, 1),
        );
        final reversed = t.selectRange(
          const GridPoint.active(3, 1),
          const GridPoint.active(2, 1),
        )!;
        expect(
          reversed
              .adjusted(SelectionAdjustment.left)
              .end
              .pointIn(PointSpace.active),
          const GridPoint.active(1, 1),
        );
        expect(
          s.adjusted(SelectionAdjustment.home).end.pointIn(PointSpace.screen),
          const GridPoint.screen(0, 0),
        );
      });
    });

    test('contains follows linear and rectangular rules', () {
      withTerminal(10, 3, (t) {
        writeText(t, 'abcdef\r\nghijkl\r\nmnopqr');
        final linear = t.selectRange(
          const GridPoint.active(4, 0),
          const GridPoint.active(1, 2),
        )!;
        expect(linear.contains(const GridPoint.active(9, 0)), isTrue);
        expect(linear.contains(const GridPoint.active(0, 1)), isTrue);
        expect(linear.contains(const GridPoint.active(3, 0)), isFalse);
        expect(linear.contains(const GridPoint.active(2, 2)), isFalse);
        final block = t.selectRange(
          const GridPoint.active(1, 0),
          const GridPoint.active(3, 2),
          rectangle: true,
        )!;
        expect(block.contains(const GridPoint.active(2, 1)), isTrue);
        expect(block.contains(const GridPoint.active(5, 1)), isFalse);
        expect(block.contains(const GridPoint.viewport(1, 2)), isTrue);
        expect(block.contains(const GridPoint.active(10, 0)), isFalse);
        expect(block.contains(const GridPoint.active(0, 3)), isFalse);
        expect(
          () => block.contains(const GridPoint(PointSpace.unknown, 0, 0)),
          throwsArgumentError,
        );
      });
    });

    test('equality agrees with ghostty_terminal_selection_equal', () {
      withTerminal(10, 3, (t) {
        writeText(t, 'abcdef');
        final a = t.selectRange(
          const GridPoint.active(1, 0),
          const GridPoint.active(3, 0),
        )!;
        final b = t.selectRange(
          const GridPoint.viewport(1, 0),
          const GridPoint.screen(3, 0),
        )!;
        final c = t.selectRange(
          const GridPoint.active(1, 0),
          const GridPoint.active(4, 0),
        )!;
        final d = t.selectRange(
          const GridPoint.active(1, 0),
          const GridPoint.active(3, 0),
          rectangle: true,
        )!;
        bool nativeEqual(VtSelection x, VtSelection y) => using((arena) {
          final handle = handleOf<GhosttyTerminalImpl>(t);
          GhosttySelection native(VtSelection s) => _toNative(arena, t, s);
          final out = arena<Bool>();
          final na = arena<GhosttySelection>()..ref = native(x);
          final nb = arena<GhosttySelection>()..ref = native(y);
          checkResult(
            ghostty_terminal_selection_equal(handle.pointer, na, nb, out),
            'ghostty_terminal_selection_equal',
          );
          return out.value;
        });
        for (final (x, y, equal) in [
          (a, b, true),
          (a, c, false),
          (a, d, false),
          (a, a.ordered(), true),
        ]) {
          expect(x == y, equal);
          expect(nativeEqual(x, y), equal);
          if (equal) expect(x.hashCode, y.hashCode);
        }
      });
    });
  });

  group('word, line, all, output', () {
    test('selectWord selects the word under a cell', () {
      withTerminal(30, 3, (t) {
        writeText(t, 'echo "hello world" foo:bar');
        expect(
          selectedText(t, t.selectWord(const GridPoint.active(8, 0))!),
          'hello',
        );
        expect(
          selectedText(t, t.selectWord(const GridPoint.active(1, 0))!),
          'echo',
        );
        expect(
          selectedText(t, t.selectWord(const GridPoint.active(20, 0))!),
          'foo',
        );
        expect(
          t.selectWord(const GridPoint.active(29, 0)),
          isNull,
          reason: 'blank',
        );
        expect(
          t.selectWord(const GridPoint.active(30, 0)),
          isNull,
          reason: 'outside',
        );
      });
    });

    test('selectWord handles Unicode, wide characters and combining marks', () {
      withTerminal(40, 3, (t) {
        writeText(t, 'añadir 日本語テキスト éte 👍🏽ok');
        expect(
          selectedText(t, t.selectWord(const GridPoint.active(2, 0))!),
          'añadir',
        );
        // 日 occupies columns 7-8; the tail cell selects the same word.
        expect(
          selectedText(t, t.selectWord(const GridPoint.active(8, 0))!),
          '日本語テキスト',
        );
        expect(
          selectedText(t, t.selectWord(const GridPoint.active(22, 0))!),
          'éte',
        );
        expect(
          selectedText(t, t.selectWord(const GridPoint.active(27, 0))!),
          '👍🏽ok',
        );
      });
    });

    test('selectWord uses custom boundaries', () {
      withTerminal(30, 3, (t) {
        writeText(t, 'path/to/file.txt');
        expect(
          selectedText(t, t.selectWord(const GridPoint.active(5, 0))!),
          'path/to/file.txt',
        );
        expect(
          selectedText(
            t,
            t.selectWord(
              const GridPoint.active(5, 0),
              boundaryCodepoints: '/.'.runes.toList(),
            )!,
          ),
          'to',
        );
        expect(
          () => t.selectWord(
            const GridPoint.active(5, 0),
            boundaryCodepoints: [0x110000],
          ),
          throwsRangeError,
        );
        expect(
          () => t.selectWord(
            const GridPoint.active(5, 0),
            boundaryCodepoints: [-1],
          ),
          throwsRangeError,
        );
      });
    });

    test('selectWordBetween finds the nearest word toward the end', () {
      withTerminal(30, 3, (t) {
        writeText(t, 'one   two');
        // From an empty cell past the content toward the start, the first
        // word found is the last one.
        final back = t.selectWordBetween(
          const GridPoint.active(20, 0),
          const GridPoint.active(0, 0),
        )!;
        expect(selectedText(t, back), 'two');
        final toward = t.selectWordBetween(
          const GridPoint.active(1, 0),
          const GridPoint.active(20, 0),
        )!;
        expect(selectedText(t, toward), 'one');
        expect(
          t.selectWordBetween(
            const GridPoint.active(12, 0),
            const GridPoint.active(20, 0),
          ),
          isNull,
          reason: 'only empty cells in between',
        );
        expect(
          t.selectWordBetween(
            const GridPoint.active(0, 0),
            const GridPoint.active(30, 0),
          ),
          isNull,
          reason: 'end outside the screen',
        );
      });
    });

    test('selectLine follows soft wraps and trims whitespace', () {
      withTerminal(6, 4, (t) {
        writeText(t, '  abcdefgh  \r\nnext');
        final line = t.selectLine(const GridPoint.active(1, 1))!;
        expect(
          TerminalFormatter(t, unwrap: true).formatText(selection: line),
          'abcdefgh',
        );
        expect(
          selectedText(t, t.selectLine(const GridPoint.active(0, 2))!),
          'next',
        );
        expect(
          t.selectLine(const GridPoint.active(0, 3)),
          isNull,
          reason: 'blank',
        );
        final keepSpaces = t.selectLine(
          const GridPoint.active(0, 2),
          whitespace: const [],
        );
        expect(keepSpaces, isNotNull);
      });
    });

    test('selectAll covers the scrollback, null when blank', () {
      withTerminal(10, 3, (t) {
        expect(t.selectAll(), isNull);
        writeText(t, [for (var i = 0; i < 6; i++) 'r$i'].join('\r\n'));
        expect(selectedText(t, t.selectAll()!), 'r0\nr1\nr2\nr3\nr4\nr5');
      });
    });

    test('selectOutput selects command output marked by OSC 133', () {
      withTerminal(20, 8, (t) {
        writeText(
          t,
          '\x1b]133;A\x07\$ \x1b]133;B\x07ls\r\n'
          '\x1b]133;C\x07file1\r\nfile2\r\n'
          '\x1b]133;D;0\x07\x1b]133;A\x07\$ ',
        );
        final output = t.selectOutput(const GridPoint.active(0, 1));
        expect(output, isNotNull);
        expect(selectedText(t, output!), 'file1\nfile2');
        expect(t.selectOutput(const GridPoint.active(0, 7)), isNull);
      });
    });
  });

  group('the terminal selection', () {
    test('is null until set, round-trips and clears', () {
      withTerminal(10, 3, (t) {
        writeText(t, 'abcdef');
        expect(t.selection, isNull);
        final s = t.selectRange(
          const GridPoint.active(1, 0),
          const GridPoint.active(3, 0),
        )!;
        t.selection = s;
        expect(s.isValid, isFalse, reason: 'setting changes the terminal');
        final read = t.selection!;
        expect(selectedText(t, read), 'bcd');
        expect(
          read.start.pointIn(PointSpace.active),
          const GridPoint.active(1, 0),
        );
        t.selection = null;
        expect(t.selection, isNull);
      });
    });

    test('keeps a rectangle flag', () {
      withTerminal(10, 3, (t) {
        writeText(t, 'abc\r\ndef');
        t.selection = t.selectRange(
          const GridPoint.active(0, 0),
          const GridPoint.active(1, 1),
          rectangle: true,
        );
        expect(t.selection!.isRectangle, isTrue);
        expect(selectedText(t, t.selection!), 'ab\nde');
      });
    });

    test('follows content as it scrolls', () {
      withTerminal(10, 3, (t) {
        writeText(t, 'target');
        t.selection = t.selectWord(const GridPoint.active(0, 0));
        writeText(t, '\r\n1\r\n2\r\n3');
        final s = t.selection!;
        expect(s.start.pointIn(PointSpace.active), isNull);
        expect(
          s.start.pointIn(PointSpace.screen),
          const GridPoint.screen(0, 0),
        );
        expect(selectedText(t, s), 'target');
      });
    });

    test('shows up in the render state', () {
      withTerminal(10, 3, (t) {
        writeText(t, 'abcdef\r\nghijkl');
        final state = RenderState();
        addTearDown(state.dispose);
        state.update(t);
        expect(
          state.allRows.map((r) => r.selectionStart),
          everyElement(isNull),
        );

        t.selection = t.selectRange(
          const GridPoint.active(2, 0),
          const GridPoint.active(3, 1),
        );
        state.update(t);
        final spans = [
          for (final row in state.allRows)
            (row.selectionStart, row.selectionEnd),
        ];
        expect(spans, [(2, 9), (0, 3), (null, null)]);

        t.selection = null;
        state.update(t);
        expect(
          state.allRows.map((r) => r.selectionStart),
          everyElement(isNull),
        );
      });
    });

    test('rejects stale selections and other terminals', () {
      withTerminal(10, 3, (t) {
        writeText(t, 'abc');
        final s = t.selectAll()!;
        writeText(t, 'd');
        expect(() => t.selection = s, throwsStateError);
        expect(t.selection, isNull);
        withTerminal(10, 3, (other) {
          writeText(other, 'x');
          expect(() => t.selection = other.selectAll(), throwsArgumentError);
        });
      });
    });
  });

  group('selectTrackedRange', () {
    test('rebuilds a selection from tracked ends after changes', () {
      withTerminal(10, 3, (t) {
        writeText(t, 'keep this');
        final start = t.trackGridRef(const GridPoint.active(0, 0))!;
        final end = t.trackGridRef(const GridPoint.active(3, 0))!;
        addTearDown(start.dispose);
        addTearDown(end.dispose);
        writeText(t, '\r\na\r\nb\r\nc');
        final s = t.selectTrackedRange(start, end)!;
        expect(selectedText(t, s), 'keep');
        expect(
          t.selectTrackedRange(start, end, rectangle: true)!.isRectangle,
          isTrue,
        );
      });
    });

    test('is null for refs of the other screen or of another terminal', () {
      withTerminal(10, 3, (t) {
        writeText(t, 'primary');
        final start = t.trackGridRef(const GridPoint.active(0, 0))!;
        final end = t.trackGridRef(const GridPoint.active(3, 0))!;
        addTearDown(start.dispose);
        addTearDown(end.dispose);
        writeText(t, '\x1b[?1049h');
        expect(t.activeScreen, TerminalScreen.alternate);
        expect(t.selectTrackedRange(start, end), isNull);
        writeText(t, '\x1b[?1049l');
        expect(t.selectTrackedRange(start, end), isNotNull);
        withTerminal(10, 3, (other) {
          writeText(other, 'other');
          expect(other.selectTrackedRange(start, end), isNull);
        });
      });
    });

    test('throws for disposed refs', () {
      withTerminal(10, 3, (t) {
        writeText(t, 'abc');
        final start = t.trackGridRef(const GridPoint.active(0, 0))!;
        final end = t.trackGridRef(const GridPoint.active(1, 0))!..dispose();
        expect(() => t.selectTrackedRange(start, end), throwsStateError);
        start.dispose();
      });
    });
  });

  group('lifetime', () {
    test('a selection goes stale on any change and when disposed', () {
      final t = VtTerminal(cols: 10, rows: 3);
      writeText(t, 'abc');
      final s = t.selectAll()!;
      expect(s.isValid, isTrue);
      expect('$s', 'VtSelection(linear, valid)');
      t.resize(12, 3);
      expect(s.isValid, isFalse);
      expect('$s', 'VtSelection(linear, stale)');
      for (final use in <void Function()>[
        () => s.start,
        () => s.end,
        () => s.order,
        () => s.ordered(),
        () => s.adjusted(SelectionAdjustment.left),
        () => s.contains(const GridPoint.active(0, 0)),
      ]) {
        expect(use, throwsStateError);
      }
      final fresh = t.selectAll()!;
      t.dispose();
      expect(fresh.isValid, isFalse);
      expect(() => fresh.start, throwsStateError);
      for (final use in <void Function()>[
        () => t.selection,
        () => t.selection = null,
        () => t.selectAll(),
        () => t.selectWord(const GridPoint.active(0, 0)),
        () => t.selectRange(
          const GridPoint.active(0, 0),
          const GridPoint.active(0, 0),
        ),
      ]) {
        expect(use, throwsStateError);
      }
    });

    test('a selection cannot be used from inside a terminal callback', () {
      withTerminal(10, 3, (t) {
        writeText(t, 'abc');
        final errors = <Object>[];
        t.onBell = () {
          for (final use in <void Function()>[
            () => t.selectAll(),
            () => t.selection,
            () => t.selection = null,
          ]) {
            try {
              use();
            } catch (e) {
              errors.add(e);
            }
          }
        };
        writeText(t, '\x07');
        expect(errors, hasLength(3));
        expect(errors, everyElement(isA<StateError>()));
      });
    });
  });
}

/// [selection] as a native struct, built from the screen points of its
/// ends with the raw bindings (independent of the module's conversion).
GhosttySelection _toNative(
  Arena arena,
  VtTerminal terminal,
  VtSelection selection,
) {
  final out = arena<GhosttySelection>();
  final start = selection.start;
  final end = selection.end;
  final handle = handleOf<GhosttyTerminalImpl>(terminal);
  void resolve(GridRef ref, Pointer<GhosttyGridRef> into) {
    final point = arena<GhosttyPoint>();
    gridPointToNative(ref.pointIn(PointSpace.screen)!, point.ref);
    checkResult(
      ghostty_terminal_grid_ref(handle.pointer, point.ref, into),
      'ghostty_terminal_grid_ref',
    );
  }

  final startRef = arena<GhosttyGridRef>();
  final endRef = arena<GhosttyGridRef>();
  resolve(start, startRef);
  resolve(end, endRef);
  out.ref
    ..start = startRef.ref
    ..end = endRef.ref
    ..rectangle = selection.isRectangle;
  return out.ref;
}
