import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart/src/ffi/bindings.g.dart';
import 'package:ghostty_dart/src/search/search_enums.dart';
import 'package:test/test.dart';

import '../support/selection_support.dart';
import '../support/terminal_support.dart';

/// The screen row of the start of each selection.
List<int> _rows(Iterable<VtSelection> selections) => [
  for (final s in selections) s.start.pointIn(PointSpace.screen)!.y,
];

/// `count` lines `0 match` .. `<count-1> match`, the even ones also
/// containing `hit`.
String _lines(int count) => [
  for (var i = 0; i < count; i++) '$i ${i.isEven ? 'hit' : 'miss'}',
].join('\r\n');

void main() {
  group('codecs', () {
    test('match the header', () {
      const status = {
        SearchStatus.running: GhosttySearchStatus.GHOSTTY_SEARCH_STATUS_RUNNING,
        SearchStatus.feedRequired:
            GhosttySearchStatus.GHOSTTY_SEARCH_STATUS_FEED_REQUIRED,
        SearchStatus.complete:
            GhosttySearchStatus.GHOSTTY_SEARCH_STATUS_COMPLETE,
      };
      expect(
        status.keys.toSet(),
        SearchStatus.values.toSet()..remove(SearchStatus.unknown),
      );
      status.forEach((v, raw) {
        expect(searchStatusCodec.encode(v), raw);
        expect(searchStatusCodec.decode(raw), v);
      });
      expect(searchStatusCodec.decode(99), SearchStatus.unknown);
      const scroll = {
        SearchScroll.ifNeeded:
            GhosttySearchScroll.GHOSTTY_SEARCH_SCROLL_IF_NEEDED,
        SearchScroll.none: GhosttySearchScroll.GHOSTTY_SEARCH_SCROLL_NONE,
      };
      expect(
        scroll.keys.toSet(),
        SearchScroll.values.toSet()..remove(SearchScroll.unknown),
      );
      scroll.forEach((v, raw) {
        expect(searchScrollCodec.encode(v), raw);
        expect(searchScrollCodec.decode(raw), v);
      });
      expect(
        () => searchScrollCodec.encode(SearchScroll.unknown),
        throwsArgumentError,
      );
    });
  });

  group('TerminalSearch', () {
    test('starts idle', () {
      withTerminal(20, 5, (t) {
        final search = TerminalSearch(t);
        addTearDown(search.dispose);
        expect(search.needle, isNull);
        expect(search.status, SearchStatus.complete);
        expect(search.totalMatches, 0);
        expect(search.matches, isEmpty);
        expect(search.selectedIndex, isNull);
        expect(search.selectedMatch, isNull);
        expect(search.selectNext(), isFalse);
        expect(search.selectScroll, SearchScroll.ifNeeded);
      });
    });

    test('run finds every match across the scrollback, newest first', () {
      withTerminal(20, 5, (t) {
        writeText(t, _lines(40));
        expect(t.scrollbackRows, greaterThan(0));
        final search = TerminalSearch(t, needle: 'hit');
        addTearDown(search.dispose);
        expect(search.needle, 'hit');
        expect(search.status, SearchStatus.feedRequired);
        search.run();
        expect(search.status, SearchStatus.complete);
        expect(search.totalMatches, 20);
        final matches = search.matches;
        expect(matches, hasLength(20));
        expect(_rows(matches), [for (var i = 38; i >= 0; i -= 2) i]);
        expect(matches.map((m) => selectedText(t, m)), everyElement('hit'));
        expect(() => matches.add(matches.first), throwsUnsupportedError);
      });
    });

    test('matches ASCII case-insensitively and UTF-8 exactly', () {
      withTerminal(30, 5, (t) {
        writeText(t, 'Hello HELLO hello\r\nÑandú ñandú');
        final search = TerminalSearch(t, needle: 'hello')..run();
        addTearDown(search.dispose);
        expect(search.totalMatches, 3);
        search
          ..needle = 'ñandú'
          ..run();
        expect(search.totalMatches, 1);
        expect(selectedText(t, search.matches.single), 'ñandú');
      });
    });

    test('selectNext goes toward older content and wraps', () {
      withTerminal(20, 5, (t) {
        writeText(t, _lines(30));
        final search = TerminalSearch(t, needle: 'hit')..run();
        addTearDown(search.dispose);
        final order = <int>[];
        for (var i = 0; i < 16; i++) {
          expect(search.selectNext(), isTrue);
          order.add(search.selectedIndex!);
          expect(
            search.selectedMatch!.start.pointIn(PointSpace.screen)!.y,
            28 - 2 * search.selectedIndex!,
          );
        }
        expect(order, [for (var i = 0; i < 15; i++) i, 0]);
      });
    });

    test('selectPrevious goes toward newer content and wraps', () {
      withTerminal(20, 5, (t) {
        writeText(t, _lines(10));
        final search = TerminalSearch(t, needle: 'hit')..run();
        addTearDown(search.dispose);
        final order = [
          for (var i = 0; i < 6; i++)
            if (search.selectPrevious()) search.selectedIndex!,
        ];
        expect(order, [4, 3, 2, 1, 0, 4]);
        search.selectNext();
        expect(search.selectedIndex, 0, reason: 'next from the oldest wraps');
      });
    });

    test('selecting scrolls the viewport unless told not to', () {
      withTerminal(20, 5, (t) {
        writeText(t, _lines(30));
        final search = TerminalSearch(t, needle: 'hit')..run();
        addTearDown(search.dispose);
        for (var i = 0; i < 10; i++) {
          search.selectNext();
        }
        expect(t.isViewportActive, isFalse);
        final selected = search.selectedMatch!;
        expect(selected.start.pointIn(PointSpace.viewport), isNotNull);

        t.scrollViewport(const ScrollToBottom());
        search.selectScroll = SearchScroll.none;
        expect(search.selectScroll, SearchScroll.none);
        search.selectNext();
        expect(t.isViewportActive, isTrue);
        expect(
          () => search.selectScroll = SearchScroll.unknown,
          throwsArgumentError,
        );
      });
    });

    test('step drives an incremental search to completion', () {
      withTerminal(20, 5, (t) {
        writeText(t, _lines(2000));
        final search = TerminalSearch(t, needle: 'hit');
        addTearDown(search.dispose);
        var steps = 0;
        while (search.step() != SearchStatus.complete) {
          steps++;
          expect(steps, lessThan(100000));
        }
        expect(search.totalMatches, 1000);
        expect(steps, greaterThan(0));
      });
    });

    test('tick and feed are the low-level steps', () {
      withTerminal(20, 5, (t) {
        writeText(t, _lines(10));
        final search = TerminalSearch(t, needle: 'hit');
        addTearDown(search.dispose);
        expect(search.status, SearchStatus.feedRequired);
        expect(
          search.tick(),
          SearchStatus.feedRequired,
          reason: 'nothing copied yet',
        );
        search.feed();
        var status = search.status;
        while (status != SearchStatus.complete) {
          status = status == SearchStatus.feedRequired
              ? (search..feed()).status
              : search.tick();
        }
        expect(search.totalMatches, 5);
      });
    });

    test('new output is found after another feed', () {
      withTerminal(20, 5, (t) {
        writeText(t, 'one hit\r\n');
        final search = TerminalSearch(t, needle: 'hit')..run();
        addTearDown(search.dispose);
        expect(search.totalMatches, 1);
        writeText(t, 'two hit\r\n');
        expect(search.totalMatches, 1, reason: 'not fed yet');
        search.run();
        expect(search.totalMatches, 2);
      });
    });

    test('matches go stale when the terminal changes after the feed', () {
      withTerminal(20, 5, (t) {
        writeText(t, 'a hit\r\n');
        final search = TerminalSearch(t, needle: 'hit')..run();
        addTearDown(search.dispose);
        final before = search.matches.single;
        expect(before.isValid, isTrue);
        writeText(t, 'b');
        expect(before.isValid, isFalse);
        expect(search.matches.single.isValid, isFalse, reason: 'not fed since');
        search.feed();
        expect(search.matches.single.isValid, isTrue);
        t.selection = search.matches.single;
        expect(selectedText(t, t.selection!), 'hit');
      });
    });

    test('changing the needle restarts; the same needle keeps results', () {
      withTerminal(20, 5, (t) {
        writeText(t, 'hit miss hit');
        final search = TerminalSearch(t, needle: 'hit')..run();
        addTearDown(search.dispose);
        expect(search.totalMatches, 2);
        search.needle = 'HIT';
        expect(search.totalMatches, 2, reason: 'same needle ignoring case');
        expect(search.needle, 'hit');
        search.needle = 'miss';
        expect(search.status, SearchStatus.feedRequired);
        expect(search.totalMatches, 0);
        search.run();
        expect(search.totalMatches, 1);
        search.needle = '';
        expect(search.needle, isNull);
        expect(search.status, SearchStatus.complete);
        search.needle = 'hit';
        search.needle = null;
        expect(search.needle, isNull);
      });
    });

    test('follows the alternate screen and back', () {
      withTerminal(20, 5, (t) {
        writeText(t, 'hit hit');
        final search = TerminalSearch(t, needle: 'hit')..run();
        addTearDown(search.dispose);
        expect(search.totalMatches, 2);
        writeText(t, '\x1b[?1049hhit');
        search.run();
        expect(search.totalMatches, 1);
        writeText(t, '\x1b[?1049l');
        search.run();
        expect(search.totalMatches, 2);
      });
    });

    test('viewport matches cover the visible pages', () {
      withTerminal(20, 5, (t) {
        writeText(t, _lines(10));
        final search = TerminalSearch(t, needle: 'hit')..run();
        addTearDown(search.dispose);
        final visible = search.viewportMatches.where(
          (m) => m.start.pointIn(PointSpace.viewport) != null,
        );
        expect(_rows(visible), unorderedEquals([6, 8]));
      });
    });

    test('dispose is idempotent; the terminal disposes its searches', () {
      final t = VtTerminal(cols: 20, rows: 5);
      writeText(t, 'hit');
      final search = TerminalSearch(t, needle: 'hit')..run();
      final kept = TerminalSearch(t, needle: 'hit')..run();
      search
        ..dispose()
        ..dispose();
      expect(search.isDisposed, isTrue);
      expect(() => search.totalMatches, throwsStateError);
      expect(search.run, throwsStateError);
      expect(() => search.needle = 'x', throwsStateError);
      expect(kept.totalMatches, 1);
      t.dispose();
      expect(kept.isDisposed, isTrue);
      expect(kept.selectNext, throwsStateError);
      expect(() => TerminalSearch(t), throwsStateError);
    });

    test('cannot be used from inside a terminal callback', () {
      withTerminal(20, 5, (t) {
        final search = TerminalSearch(t, needle: 'x');
        addTearDown(search.dispose);
        final errors = <Object>[];
        t.onBell = () {
          for (final use in <void Function()>[
            search.run,
            search.feed,
            () => search.matches,
            () => search.totalMatches,
          ]) {
            try {
              use();
            } catch (e) {
              errors.add(e);
            }
          }
        };
        writeText(t, '\x07');
        expect(errors, hasLength(4));
        expect(errors, everyElement(isA<StateError>()));
        // Data getters name themselves, not an internal helper.
        expect(
          errors.last,
          isA<StateError>().having(
            (e) => e.message,
            'message',
            startsWith('TerminalSearch.totalMatches '),
          ),
        );
      });
    });
  });
}
