import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart/src/core/internal.dart';
import 'package:ghostty_dart/src/ffi/bindings.g.dart';
import 'package:test/test.dart';

import '../support/terminal_support.dart';

String _lines(int count) =>
    [for (var i = 0; i < count; i++) 'line$i'].join('\r\n');

void main() {
  group('TrackedGridRef', () {
    test('follows its cell as the screen scrolls', () {
      withTerminal(10, 3, (t) {
        writeText(t, 'ABC');
        final ref = t.trackGridRef(const GridPoint.active(1, 0))!;
        addTearDown(ref.dispose);
        expect(ref.hasValue, isTrue);
        expect(ref.pointIn(PointSpace.active), const GridPoint.active(1, 0));
        writeText(t, '\r\n\r\n\r\n\r\n');
        // Scrolled two rows into the history.
        expect(ref.pointIn(PointSpace.screen), const GridPoint.screen(1, 0));
        expect(ref.pointIn(PointSpace.active), isNull);
        expect(ref.pointIn(PointSpace.viewport), isNull);
        expect(ref.snapshot()!.text, 'B');
      });
    });

    test('follows its cell through resize reflow', () {
      withTerminal(10, 3, (t) {
        writeText(t, 'abcdefgh');
        final ref = t.trackGridRef(const GridPoint.active(6, 0))!;
        addTearDown(ref.dispose);
        t.resize(4, 3);
        expect(ref.pointIn(PointSpace.active), const GridPoint.active(2, 1));
        expect(ref.snapshot()!.text, 'g');
      });
    });

    test('has no value once its cell is pruned from the scrollback', () {
      withTerminal(10, 3, (t) {
        t.scrollbackMaxLines = 0;
        writeText(t, 'X');
        final ref = t.trackGridRef(const GridPoint.active(0, 0))!;
        addTearDown(ref.dispose);
        // The library prunes whole pages, so it takes a few thousand rows.
        for (var i = 0; i < 20 && ref.hasValue; i++) {
          writeText(t, _lines(1000));
        }
        expect(ref.hasValue, isFalse);
        expect(ref.snapshot(), isNull);
        expect(ref.pointIn(PointSpace.screen), isNull);
        // moveTo points it at a cell again.
        expect(ref.moveTo(const GridPoint.active(0, 0)), isTrue);
        expect(ref.hasValue, isTrue);
        expect(ref.pointIn(PointSpace.active), const GridPoint.active(0, 0));
      });
    });

    test('moveTo changes the tracked cell', () {
      withTerminal(10, 3, (t) {
        writeText(t, 'abc');
        final ref = t.trackGridRef(const GridPoint.active(0, 0))!;
        addTearDown(ref.dispose);
        expect(ref.moveTo(const GridPoint.active(2, 0)), isTrue);
        expect(ref.snapshot()!.text, 'c');
      });
    });

    test('moveTo outside the grid returns false and keeps the cell', () {
      withTerminal(10, 3, (t) {
        writeText(t, 'abc');
        final ref = t.trackGridRef(const GridPoint.active(1, 0))!;
        addTearDown(ref.dispose);
        expect(ref.moveTo(const GridPoint.active(10, 0)), isFalse);
        expect(ref.moveTo(const GridPoint.active(0, 3)), isFalse);
        expect(ref.pointIn(PointSpace.active), const GridPoint.active(1, 0));
        expect(ref.snapshot()!.text, 'b');
        expect(
          () => ref.moveTo(const GridPoint(PointSpace.unknown, 0, 0)),
          throwsArgumentError,
        );
      });
    });

    test('trackGridRef returns null outside the grid', () {
      withTerminal(10, 3, (t) {
        expect(t.trackGridRef(const GridPoint.active(10, 0)), isNull);
        expect(t.trackGridRef(const GridPoint.viewport(0, 3)), isNull);
        expect(t.trackGridRef(const GridPoint.screen(0, 3)), isNull);
      });
    });

    test('stays on the screen it was created on', () {
      withTerminal(10, 3, (t) {
        writeText(t, 'primary');
        final ref = t.trackGridRef(const GridPoint.active(0, 0))!;
        addTearDown(ref.dispose);
        writeText(t, '\x1b[?1049h\x1b[Halt');
        expect(t.activeScreen, TerminalScreen.alternate);
        expect(ref.hasValue, isTrue);
        expect(ref.snapshot()!.text, 'p');
        // Moving it resolves against the alternate screen, now active.
        expect(ref.moveTo(const GridPoint.active(0, 0)), isTrue);
        expect(ref.snapshot()!.text, 'a');
      });
    });

    test('snapshots are borrowed grid refs', () {
      withTerminal(10, 3, (t) {
        writeText(t, '\x1b]8;;https://a.example\x1b\\L\x1b]8;;\x1b\\');
        final ref = t.trackGridRef(const GridPoint.active(0, 0))!;
        addTearDown(ref.dispose);
        final snapshot = ref.snapshot()!;
        expect(snapshot.hyperlinkUri, 'https://a.example');
        expect(
          snapshot.pointIn(PointSpace.active),
          const GridPoint.active(0, 0),
        );
        writeText(t, 'x');
        expect(snapshot.isValid, isFalse);
        expect(() => snapshot.cell, throwsStateError);
        expect(ref.snapshot()!.isValid, isTrue);
      });
    });

    test('rejects an unknown point space in pointIn', () {
      withTerminal(10, 3, (t) {
        final ref = t.trackGridRef(const GridPoint.active(0, 0))!;
        addTearDown(ref.dispose);
        expect(() => ref.pointIn(PointSpace.unknown), throwsArgumentError);
      });
    });
  });

  group('TrackedGridRef ownership', () {
    test('dispose is idempotent and blocks further use', () {
      withTerminal(10, 3, (t) {
        final ref = t.trackGridRef(const GridPoint.active(0, 0))!;
        expect(ref.isDisposed, isFalse);
        ref
          ..dispose()
          ..dispose();
        expect(ref.isDisposed, isTrue);
        final disposed = throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'TrackedGridRef has been disposed',
          ),
        );
        expect(() => ref.hasValue, disposed);
        expect(() => ref.pointIn(PointSpace.active), disposed);
        expect(() => ref.snapshot(), disposed);
        expect(() => ref.moveTo(const GridPoint.active(0, 0)), disposed);
      });
    });

    test('disposing the terminal disposes its tracked refs', () {
      final t = VtTerminal(cols: 10, rows: 3);
      final a = t.trackGridRef(const GridPoint.active(0, 0))!;
      final b = t.trackGridRef(const GridPoint.active(1, 0))!;
      b.dispose();
      t.dispose();
      expect(a.isDisposed, isTrue);
      expect(b.isDisposed, isTrue);
      expect(() => a.hasValue, throwsStateError);
      a.dispose();
    });

    test('is bound to a native handle', () {
      withTerminal(10, 3, (t) {
        final ref = t.trackGridRef(const GridPoint.active(0, 0))!;
        final handle = handleOf<GhosttyTrackedGridRefImpl>(ref);
        expect(handle.typeName, 'TrackedGridRef');
        ref.dispose();
        expect(handle.isDisposed, isTrue);
      });
    });

    test('many refs can be created and disposed', () {
      withTerminal(10, 3, (t) {
        for (var i = 0; i < 2000; i++) {
          t.trackGridRef(GridPoint.active(i % 10, i % 3))!.dispose();
        }
        // Forgotten refs are freed by their finalizer or with the terminal.
        for (var i = 0; i < 100; i++) {
          t.trackGridRef(const GridPoint.active(0, 0));
        }
      });
    });
  });
}
