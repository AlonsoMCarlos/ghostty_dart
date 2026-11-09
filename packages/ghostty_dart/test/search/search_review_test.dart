// Correctness review of TerminalSearch: adversarial cases the main suite
// does not cover (evicted scrollback mid-search, wrapped and overlapping
// matches, Unicode needles, many matches, garbage collection).

import 'dart:typed_data';

import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart/src/core/internal.dart';
import 'package:test/test.dart';

import '../support/selection_support.dart';
import '../support/terminal_support.dart';

/// `count` numbered lines, each containing `hit`.
String _hits(int from, int count) => [
  for (var i = from; i < from + count; i++) '${'x' * (i % 7)} hit $i',
].join('\r\n');

/// Whether both ends of [s] are cells of the active screen now.
bool _onScreen(VtSelection s) =>
    s.start.pointIn(PointSpace.screen) != null &&
    s.end.pointIn(PointSpace.screen) != null;

/// Leaves a terminal, a search with results and a gesture with a tracked
/// press undisposed, and returns weak references to their native handles.
List<WeakReference<Object>> _forgotten() {
  final t = VtTerminal(cols: 10, rows: 3);
  writeText(t, 'a hit\r\nb hit');
  final search = TerminalSearch(t, needle: 'hit')..run();
  final gesture = SelectionGesture(t)..press(const GridPoint.viewport(0, 0));
  return [
    WeakReference(handleOf(t)),
    WeakReference(handleOf(search)),
    WeakReference(handleOf(gesture)),
  ];
}

void main() {
  group('evicted scrollback', () {
    // libghostty-vt 1.0.0 drops evicted history matches only when the
    // history search completes or a match is selected; a mid-search feed
    // (and a tick after it) returns matches whose pages were freed.
    for (final (before, after) in [
      ('ftftf', 'f'),
      ('ftf', 'ft'),
      ('ftftf', 'ft'),
    ]) {
      test('matches on freed pages are stale ($before | prune | $after)', () {
        withTerminal(40, 5, (t) {
          t.scrollbackMaxBytes = null;
          writeText(t, _hits(0, 30000));
          final search = TerminalSearch(t, needle: 'hit');
          addTearDown(search.dispose);
          void drive(String ops) {
            for (final op in ops.split('')) {
              op == 'f' ? search.feed() : search.tick();
            }
          }

          drive(before);
          expect(search.status, isNot(SearchStatus.complete));
          t.scrollbackMaxLines = 1200;
          drive(after);
          final matches = search.matches;
          expect(matches, hasLength(search.totalMatches));
          final live = matches.where((m) => m.isValid).toList();
          expect(live, isNotEmpty);
          expect(
            live.length,
            lessThan(matches.length),
            reason: 'the library still returns evicted matches here',
          );
          for (final m in live) {
            expect(_onScreen(m), isTrue);
          }
          for (final m in matches.where((m) => !m.isValid)) {
            expect(() => m.start, throwsStateError);
            expect(
              () => TerminalFormatter(t).formatText(selection: m),
              throwsStateError,
            );
          }
          // Completing the search drops them for good.
          search.run();
          expect(
            search.matches.every((m) => m.isValid && _onScreen(m)),
            isTrue,
          );
        });
      });
    }

    test('matches stay correct while output evicts and reuses pages', () {
      withTerminal(40, 5, (t) {
        t
          ..scrollbackMaxBytes = null
          ..scrollbackMaxLines = 2500;
        writeText(t, _hits(0, 6000));
        final formatter = TerminalFormatter(t);
        final search = TerminalSearch(t, needle: 'hit');
        addTearDown(search.dispose);
        for (final ops in ['ftf', 'ft', 'f']) {
          for (final op in ops.split('')) {
            op == 'f' ? search.feed() : search.tick();
          }
          writeText(t, '\r\n${_hits(6000, 1500)}');
          search.feed();
          for (final m in search.matches.where((m) => m.isValid)) {
            expect(formatter.formatText(selection: m).toLowerCase(), 'hit');
          }
        }
      });
    });

    test('erasing the scrollback mid-search keeps only live matches', () {
      withTerminal(40, 5, (t) {
        t.scrollbackMaxBytes = null;
        writeText(t, _hits(0, 20000));
        final search = TerminalSearch(t, needle: 'hit')
          ..feed()
          ..tick()
          ..feed();
        addTearDown(search.dispose);
        writeText(t, '\x1b[3J');
        search.feed();
        expect(search.matches.every((m) => m.isValid && _onScreen(m)), isTrue);
        expect(search.totalMatches, 5);
      });
    });

    test('a selected match survives pruning or is dropped', () {
      withTerminal(40, 5, (t) {
        t.scrollbackMaxBytes = null;
        writeText(t, _hits(0, 20000));
        final search = TerminalSearch(t, needle: 'hit')..run();
        addTearDown(search.dispose);
        for (var i = 0; i < 3000; i++) {
          search.selectPrevious();
        }
        expect(search.selectedMatch, isNotNull);
        t.scrollbackMaxLines = 100;
        search.feed();
        final selected = search.selectedMatch;
        if (selected != null) expect(_onScreen(selected), isTrue);
        expect(search.selectNext(), isTrue);
        expect(_onScreen(search.selectedMatch!), isTrue);
      });
    });
  });

  group('matching', () {
    test('finds a needle across a soft wrap', () {
      withTerminal(10, 4, (t) {
        writeText(t, '12345678needle');
        final search = TerminalSearch(t, needle: 'needle')..run();
        addTearDown(search.dispose);
        expect(search.totalMatches, 1);
        final m = search.matches.single;
        expect(
          m.start.pointIn(PointSpace.active),
          const GridPoint.active(8, 0),
        );
        expect(m.end.pointIn(PointSpace.active), const GridPoint.active(3, 1));
        expect(selectedText(t, m, unwrap: true), 'needle');
      });
    });

    test('does not find a needle across a hard line break', () {
      withTerminal(10, 4, (t) {
        writeText(t, 'nee\r\ndle');
        final search = TerminalSearch(t, needle: 'needle')..run();
        addTearDown(search.dispose);
        expect(search.totalMatches, 0);
      });
    });

    test('overlapping occurrences are each a match', () {
      withTerminal(20, 3, (t) {
        writeText(t, 'aaaaa');
        final search = TerminalSearch(t, needle: 'aa')..run();
        addTearDown(search.dispose);
        expect([
          for (final m in search.matches) selectedText(t, m, unwrap: true),
        ], everyElement('aa'));
        final starts = [
          for (final m in search.matches) m.start.pointIn(PointSpace.active)!.x,
        ]..sort();
        expect(starts, [0, 1, 2, 3]);
        expect(search.totalMatches, 4);
      });
    });

    test(
      'Unicode needles: wide, combining, emoji; case folding is ASCII only',
      () {
        withTerminal(30, 4, (t) {
          writeText(t, 'x 日本語 y\r\ncafé Café CAFÉ\r\n👩‍💻 ok');
          TerminalSearch s(String needle) =>
              TerminalSearch(t, needle: needle)..run();
          final wide = s('日本');
          expect(wide.totalMatches, 1);
          expect(selectedText(t, wide.matches.single, unwrap: true), '日本');
          expect(s('café').totalMatches, 1);
          // `É` is not ASCII, so `CAFÉ` matches `Café` only in the ASCII part.
          expect(s('café').totalMatches, 1);
          expect(s('CAFé').totalMatches, 1);
          final emoji = s('👩‍💻');
          expect(emoji.totalMatches, 1);
          expect(selectedText(t, emoji.matches.single, unwrap: true), '👩‍💻');
          expect(s('日本').needle, '日本');
        });
      },
    );

    test('an unpaired surrogate in the needle does not throw', () {
      withTerminal(10, 2, (t) {
        final search = TerminalSearch(t, needle: 'a\uD800')..run();
        addTearDown(search.dispose);
        expect(search.totalMatches, 0);
        expect(search.needle, 'a�');
      });
    });

    test('a needle longer than the screen finds nothing', () {
      withTerminal(10, 2, (t) {
        writeText(t, 'abc');
        final search = TerminalSearch(t, needle: 'abc' * 100)..run();
        addTearDown(search.dispose);
        expect(search.totalMatches, 0);
        expect(search.selectNext(), isFalse);
        expect(search.selectedMatch, isNull);
      });
    });

    test('thousands of matches: every one is valid and in order', () {
      withTerminal(80, 24, (t) {
        t.scrollbackMaxBytes = null;
        writeText(
          t,
          [for (var i = 0; i < 5000; i++) '$i hit hit'].join('\r\n'),
        );
        final search = TerminalSearch(t, needle: 'hit')..run();
        addTearDown(search.dispose);
        final matches = search.matches;
        expect(matches, hasLength(10000));
        expect(search.totalMatches, 10000);
        expect(matches.every((m) => m.isValid), isTrue);
        final rows = [
          for (final m in matches) m.start.pointIn(PointSpace.screen)!.y,
        ];
        for (var i = 1; i < rows.length; i++) {
          expect(rows[i], lessThanOrEqualTo(rows[i - 1]));
        }
        expect(() => matches.add(matches.first), throwsUnsupportedError);
      });
    });
  });

  group('selection index', () {
    test('selectedIndex indexes matches; next and previous are inverse', () {
      withTerminal(20, 3, (t) {
        writeText(t, [for (var i = 0; i < 12; i++) 'hit $i'].join('\r\n'));
        final search = TerminalSearch(t, needle: 'hit')..run();
        addTearDown(search.dispose);
        final n = search.totalMatches;
        expect(n, 12);
        for (var i = 0; i < n + 2; i++) {
          expect(search.selectNext(), isTrue);
          expect(search.selectedIndex, i % n);
          expect(
            search.selectedMatch,
            search.matches[i % n],
            reason: 'the selected match is the indexed one',
          );
        }
        final index = search.selectedIndex!;
        search
          ..selectNext()
          ..selectPrevious();
        expect(search.selectedIndex, index);
      });
    });

    test('clearing the needle drops the selection', () {
      withTerminal(20, 3, (t) {
        writeText(t, 'hit');
        final search = TerminalSearch(t, needle: 'hit')..run();
        addTearDown(search.dispose);
        expect(search.selectNext(), isTrue);
        search.needle = '';
        expect(search.needle, isNull);
        expect(search.selectedIndex, isNull);
        expect(search.selectedMatch, isNull);
        expect(search.matches, isEmpty);
        expect(search.status, SearchStatus.complete);
        expect(search.selectNext(), isFalse);
      });
    });
  });

  group('lifetime', () {
    test(
      'a forgotten terminal, search and gesture are all collected',
      () async {
        final refs = _forgotten();
        // The search and gesture are freed by Dart Finalizers, which run
        // between event-loop turns; only then is the terminal handle (held by
        // their tokens) unreachable. Allocate until everything is collected.
        var garbage = <Object>[];
        for (var i = 0; i < 2000 && refs.any((r) => r.target != null); i++) {
          garbage = [for (var j = 0; j < 64; j++) Uint8List(1 << 16)];
          await Future<void>.delayed(Duration.zero);
        }
        expect(garbage, isNotEmpty);
        expect(refs[1].target, isNull, reason: 'search not collected');
        expect(refs[2].target, isNull, reason: 'gesture not collected');
        expect(refs[0].target, isNull, reason: 'terminal not collected');
      },
    );

    test('disposing the terminal mid-search leaves the search disposed', () {
      final t = VtTerminal(cols: 20, rows: 3);
      writeText(t, _hits(0, 3000));
      final search = TerminalSearch(t, needle: 'hit')
        ..feed()
        ..tick();
      final match = search.matches.first;
      t.dispose();
      expect(search.isDisposed, isTrue);
      expect(() => search.matches, throwsStateError);
      expect(() => search.feed(), throwsStateError);
      expect(match.isValid, isFalse);
      expect(() => match.start, throwsStateError);
      search.dispose();
    });
  });
}
