// Adversarial tests from the T06 correctness review.

import 'dart:ffi';

import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart/src/core/internal.dart';
import 'package:ghostty_dart/src/ffi/bindings.g.dart';
import 'package:test/test.dart';

import '../support/terminal_support.dart';
import 'grid_test_support.dart';

void main() {
  group('wide characters', () {
    test('a wide char at the right edge leaves a spacer head', () {
      withTerminal(5, 3, (t) {
        writeText(t, 'abcd中');
        final head = t.gridRef(const GridPoint.active(4, 0))!;
        expect(head.cell.width, CellWidth.spacerHead);
        expect(head.text, '');
        expect(head.codepoints, isEmpty);
        expect(head.row.isWrapped, isTrue);
        final wide = t.gridRef(const GridPoint.active(0, 1))!;
        expect(wide.cell.width, CellWidth.wide);
        expect(wide.text, '中');
        expect(wide.row.isWrapContinuation, isTrue);
        final tail = t.gridRef(const GridPoint.active(1, 1))!;
        expect(tail.cell.width, CellWidth.spacerTail);
        expect(tail.text, '');
      });
    });

    test('spacer tails keep the style of the wide char', () {
      withTerminal(6, 2, (t) {
        writeText(t, '\x1b[1;31m中\x1b[0m');
        final tail = t.gridRef(const GridPoint.active(1, 0))!;
        expect(tail.cell.width, CellWidth.spacerTail);
        final style = t.gridRef(const GridPoint.active(0, 0))!.style;
        expect(style.bold, isTrue);
        expect(style.foreground, const PaletteColor(1));
      });
    });
  });

  group('grapheme clusters', () {
    final clusters = <String>[
      'é', // combining acute
      '👨‍👩‍👧‍👦', // ZWJ family, 7 codepoints
      '🇪🇸', // regional indicator pair
      '👍🏽', // skin tone modifier
      'à́̂̃̄̅̆̇̈̉', // 11
    ];
    for (final cluster in clusters) {
      test('round-trips ${cluster.runes.length} codepoints', () {
        withTerminal(20, 2, (t) {
          // Grapheme clustering (mode 2027) keeps emoji sequences together.
          writeText(t, '\x1b[?2027h$cluster|');
          final ref = t.gridRef(const GridPoint.active(0, 0))!;
          expect(ref.codepoints, cluster.runes.toList());
          expect(ref.text, cluster);
          expect(ref.cell.codepoint, cluster.runes.first);
          expect(ref.cell.hasGrapheme, cluster.runes.length > 1);
          expect(ref.codepoints, isA<List<int>>());
          expect(() => ref.codepoints.add(1), throwsUnsupportedError);
        });
      });
    }

    test('a grapheme survives scrolling into the scrollback', () {
      withTerminal(10, 2, (t) {
        writeText(t, 'é\r\n${numberedLines(50)}');
        final ref = t.gridRef(const GridPoint.screen(0, 0))!;
        expect(ref.text, 'é');
        expect(ref.pointIn(PointSpace.active), isNull);
        expect(ref.pointIn(PointSpace.screen), const GridPoint.screen(0, 0));
      });
    });
  });

  group('hyperlinks', () {
    test('an OSC 8 link that wraps reports its URI on both rows', () {
      withTerminal(5, 3, (t) {
        const uri = 'https://example.com/ñ/例え?q=🙂';
        writeText(t, '\x1b]8;;$uri\x1b\\abcdefgh\x1b]8;;\x1b\\ij');
        for (final point in const [
          GridPoint.active(0, 0),
          GridPoint.active(4, 0),
          GridPoint.active(0, 1),
          GridPoint.active(2, 1),
        ]) {
          final ref = t.gridRef(point)!;
          expect(ref.cell.hasHyperlink, isTrue, reason: '$point');
          expect(ref.hyperlinkUri, uri, reason: '$point');
          expect(ref.row.hasHyperlinks, isTrue);
        }
        final after = t.gridRef(const GridPoint.active(3, 1))!;
        expect(after.text, 'i');
        expect(after.cell.hasHyperlink, isFalse);
        expect(after.hyperlinkUri, isNull);
      });
    });

    test('a URI of exactly the initial buffer size and one byte more', () {
      for (final length in const [255, 256, 257, 1500]) {
        withTerminal(5, 2, (t) {
          final uri = 'h' * length;
          writeText(t, '\x1b]8;;$uri\x1b\\x\x1b]8;;\x1b\\');
          expect(
            t.gridRef(const GridPoint.active(0, 0))!.hyperlinkUri,
            uri,
            reason: 'length $length',
          );
        });
      }
    });

    // libghostty-vt 1.0.0 drops an OSC 8 whose URI is longer than 2046
    // bytes without any error: the text prints, unlinked. Pinned so a
    // library upgrade that changes it is noticed (see
    // docs/internal/research/2026-11-09-upstream-findings.md).
    test('an OSC 8 URI over 2046 bytes is dropped silently', () {
      for (final (length, kept) in const [(2046, true), (2047, false)]) {
        withTerminal(5, 2, (t) {
          final uri = 'h' * length;
          writeText(t, '\x1b]8;;$uri\x1b\\x\x1b]8;;\x1b\\');
          final ref = t.gridRef(const GridPoint.active(0, 0))!;
          expect(ref.text, 'x');
          expect(ref.hyperlinkUri, kept ? uri : isNull, reason: '$length');
          expect(t.isVtGround, isTrue);
        });
      }
    });

    test('a link in the scrollback across a page boundary', () {
      withTerminal(10, 3, (t) {
        writeText(t, '\x1b]8;;https://old\x1b\\O\x1b]8;;\x1b\\\r\n');
        writeText(t, numberedLines(3000));
        final ref = t.gridRef(const GridPoint.screen(0, 0))!;
        expect(ref.text, 'O');
        expect(ref.hyperlinkUri, 'https://old');
      });
    });
  });

  group('styles and backgrounds', () {
    test('an unstyled cell has the default style and background', () {
      withTerminal(5, 2, (t) {
        writeText(t, 'a');
        for (final x in const [0, 1]) {
          final ref = t.gridRef(GridPoint.active(x, 0))!;
          expect(ref.cell.hasStyling, isFalse);
          expect(ref.style.isDefault, isTrue);
          expect(ref.background, const DefaultColor());
          expect(ref.cell.backgroundColor, isNull);
        }
      });
    });

    test('palette and RGB colour-only cells (erase with a background)', () {
      withTerminal(6, 3, (t) {
        writeText(t, '\x1b[42m\x1b[K\r\n\x1b[48;2;1;2;250m\x1b[K\x1b[0m');
        final palette = t.gridRef(const GridPoint.active(5, 0))!;
        expect(palette.cell.hasText, isFalse);
        expect(palette.cell.backgroundColor, const PaletteColor(2));
        expect(palette.background, const PaletteColor(2));
        expect(palette.style.isDefault, isTrue);
        expect(palette.text, '');
        final rgb = t.gridRef(const GridPoint.active(0, 1))!;
        expect(rgb.cell.backgroundColor, const RgbColor(1, 2, 250));
        expect(rgb.background, const RgbColor(1, 2, 250));
        expect(rgb.codepoints, isEmpty);
      });
    });

    test('a text cell with a background reads it from the style', () {
      withTerminal(6, 2, (t) {
        writeText(t, '\x1b[48;5;200mX');
        final ref = t.gridRef(const GridPoint.active(0, 0))!;
        expect(ref.cell.backgroundColor, isNull);
        expect(ref.cell.hasStyling, isTrue);
        expect(ref.background, const PaletteColor(200));
      });
    });
  });

  group('scrollback beyond page boundaries', () {
    test('every screen row reads its own line', () {
      withTerminal(12, 4, (t) {
        t.scrollbackMaxBytes = null;
        writeText(t, numberedLines(6000));
        // Sample rows across many pages, including the very first ones.
        for (final y in const [0, 1, 2, 511, 512, 1000, 2999, 5996]) {
          expect(lineAt(t, PointSpace.screen, y), 'L$y', reason: 'row $y');
          final ref = t.gridRef(GridPoint.screen(1, y))!;
          expect(ref.pointIn(PointSpace.screen), GridPoint.screen(1, y));
          expect(ref.pointIn(PointSpace.active), isNull);
        }
        // The active area is the last rows plus the empty cursor row.
        expect(lineAt(t, PointSpace.active, 2), 'L5999');
        final active = t.gridRef(const GridPoint.active(0, 2))!;
        expect(
          active.pointIn(PointSpace.screen),
          const GridPoint.screen(0, 5999),
        );
      });
    });

    test('points past the end return null, not an exception', () {
      withTerminal(10, 3, (t) {
        writeText(t, numberedLines(10));
        expect(t.gridRef(const GridPoint.screen(0, 0xFFFFFFFF)), isNull);
        expect(t.gridRef(const GridPoint.history(0, 0xFFFFFFFF)), isNull);
        expect(t.gridRef(const GridPoint.viewport(0, 3)), isNull);
        expect(t.gridRef(const GridPoint.active(10, 0)), isNull);
        expect(t.gridRef(const GridPoint.screen(0xFFFF, 0)), isNull);
        expect(t.trackGridRef(const GridPoint.screen(0, 0xFFFFFFFF)), isNull);
      });
    });

    test('history points count from the oldest row like screen points', () {
      // libghostty-vt 1.0.0: getTopLeft(.history) == getTopLeft(.screen).
      withTerminal(10, 3, (t) {
        writeText(t, numberedLines(10));
        expect(lineAt(t, PointSpace.history, 0), 'L0');
        expect(lineAt(t, PointSpace.history, 7), 'L7');
        // A history row past the scrollback resolves into the active area.
        expect(lineAt(t, PointSpace.history, 9), 'L9');
        final ref = t.gridRef(const GridPoint.history(0, 3))!;
        expect(ref.pointIn(PointSpace.history), const GridPoint.history(0, 3));
        expect(ref.pointIn(PointSpace.screen), const GridPoint.screen(0, 3));
      });
    });
  });

  group('viewport', () {
    test('a scrolled viewport resolves viewport points into scrollback', () {
      withTerminal(10, 3, (t) {
        writeText(t, numberedLines(20));
        t.scrollViewport(const ScrollToTop());
        expect(lineAt(t, PointSpace.viewport, 0), 'L0');
        final ref = t.gridRef(const GridPoint.viewport(0, 1))!;
        expect(ref.text, 'L');
        expect(
          ref.pointIn(PointSpace.viewport),
          const GridPoint.viewport(0, 1),
        );
        expect(ref.pointIn(PointSpace.active), isNull);
        expect(ref.pointIn(PointSpace.screen), const GridPoint.screen(0, 1));
        // An active cell is below the viewport while scrolled to the top.
        // Regression: libghostty-vt 1.0.0 returns viewport row 18 here (past
        // the 3-row viewport); the header promises no value.
        final active = t.gridRef(const GridPoint.active(0, 0))!;
        expect(active.pointIn(PointSpace.viewport), isNull);
        final bottom = t.gridRef(const GridPoint.viewport(0, 2))!;
        expect(
          bottom.pointIn(PointSpace.viewport),
          const GridPoint.viewport(0, 2),
        );
        final tracked = t.trackGridRef(const GridPoint.active(0, 0))!;
        addTearDown(tracked.dispose);
        expect(tracked.pointIn(PointSpace.viewport), isNull);
        expect(
          tracked.pointIn(PointSpace.active),
          const GridPoint.active(0, 0),
        );
      });
    });

    test('a tracked ref keeps its viewport position up to date', () {
      withTerminal(10, 3, (t) {
        writeText(t, numberedLines(20));
        final ref = t.trackGridRef(const GridPoint.screen(0, 5))!;
        addTearDown(ref.dispose);
        expect(ref.pointIn(PointSpace.viewport), isNull);
        t.scrollViewport(const ScrollToRow(4));
        expect(
          ref.pointIn(PointSpace.viewport),
          const GridPoint.viewport(0, 1),
        );
        expect(ref.snapshot()!.text, 'L');
      });
    });
  });

  group('resize and reflow', () {
    test('a tracked ref follows a wrapped line through narrow and wide', () {
      withTerminal(10, 5, (t) {
        writeText(t, 'abcdefghij');
        final j = t.trackGridRef(const GridPoint.active(9, 0))!;
        addTearDown(j.dispose);
        t.resize(3, 5);
        expect(j.snapshot()!.text, 'j');
        expect(j.pointIn(PointSpace.screen), isNotNull);
        final narrow = j.pointIn(PointSpace.active)!;
        expect(t.gridRef(narrow)!.text, 'j');
        t.resize(20, 5);
        expect(j.pointIn(PointSpace.active), const GridPoint.active(9, 0));
        expect(j.snapshot()!.text, 'j');
      });
    });

    test('shrinking rows pushes a tracked cell into the scrollback', () {
      withTerminal(10, 6, (t) {
        writeText(t, 'top\r\n1\r\n2\r\n3\r\n4\r\n5');
        final top = t.trackGridRef(const GridPoint.active(0, 0))!;
        addTearDown(top.dispose);
        t.resize(10, 2);
        expect(top.pointIn(PointSpace.active), isNull);
        expect(top.pointIn(PointSpace.screen), const GridPoint.screen(0, 0));
        expect(top.snapshot()!.text, 't');
      });
    });
  });

  group('alternate screen', () {
    test('a primary tracked ref still reads its cell while alt is active', () {
      withTerminal(10, 3, (t) {
        writeText(t, 'P');
        final ref = t.trackGridRef(const GridPoint.active(0, 0))!;
        addTearDown(ref.dispose);
        writeText(t, '\x1b[?1049hA');
        expect(ref.hasValue, isTrue);
        expect(ref.pointIn(PointSpace.active), const GridPoint.active(0, 0));
        final snapshot = ref.snapshot()!;
        expect(snapshot.text, 'P');
        // A snapshot's pointIn resolves against the *active* (alternate)
        // screen, which does not hold the primary page: no value. Use
        // TrackedGridRef.pointIn for such a reference.
        expect(snapshot.pointIn(PointSpace.active), isNull);
        expect(snapshot.pointIn(PointSpace.screen), isNull);
        writeText(t, '\x1b[?1049l');
        expect(
          ref.snapshot()!.pointIn(PointSpace.active),
          const GridPoint.active(0, 0),
        );
      });
    });

    test('a ref made on the alternate screen loses its value on reset', () {
      withTerminal(10, 3, (t) {
        writeText(t, '\x1b[?1049hA');
        final ref = t.trackGridRef(const GridPoint.active(0, 0))!;
        addTearDown(ref.dispose);
        writeText(t, '\x1b[?1049l');
        expect(ref.hasValue, isTrue);
        t.reset();
        expect(ref.hasValue, isFalse);
        expect(ref.snapshot(), isNull);
        expect(ref.pointIn(PointSpace.active), isNull);
        expect(ref.moveTo(const GridPoint.active(1, 1)), isTrue);
        expect(ref.pointIn(PointSpace.active), const GridPoint.active(1, 1));
      });
    });
  });

  group('reset', () {
    test('invalidates grid refs and empties tracked refs', () {
      withTerminal(10, 3, (t) {
        writeText(t, 'abc');
        final plain = t.gridRef(const GridPoint.active(0, 0))!;
        final tracked = t.trackGridRef(const GridPoint.active(1, 0))!;
        addTearDown(tracked.dispose);
        t.reset();
        expect(plain.isValid, isFalse);
        expect(() => plain.text, throwsStateError);
        expect(tracked.hasValue, isFalse);
        expect(t.gridRef(const GridPoint.active(0, 0))!.text, '');
      });
    });

    test('RIS written to the terminal does the same', () {
      withTerminal(10, 3, (t) {
        writeText(t, 'abc');
        final tracked = t.trackGridRef(const GridPoint.active(1, 0))!;
        addTearDown(tracked.dispose);
        writeText(t, '\x1bc');
        expect(tracked.hasValue, isFalse);
      });
    });
  });

  group('borrowed lifetime', () {
    test('every mutating terminal member invalidates refs', () {
      withTerminal(10, 3, (t) {
        writeText(t, numberedLines(10));
        final actions = <String, void Function()>{
          'write': () => writeText(t, 'x'),
          'resize same size': () => t.resize(10, 3),
          'scroll bottom': () => t.scrollViewport(const ScrollToBottom()),
          'scrollback option': () => t.scrollbackMaxLines = 100,
          'title': () => t.title = 'x',
          'mode': () => t.setMode(TerminalMode.cursorVisible, enabled: true),
          'compress': t.compress,
          'reset': t.reset,
        };
        actions.forEach((name, action) {
          final ref = t.gridRef(const GridPoint.active(0, 0))!;
          final snapshot = t.trackGridRef(const GridPoint.active(0, 0))!;
          final fromTracked = snapshot.snapshot()!;
          action();
          expect(ref.isValid, isFalse, reason: name);
          expect(fromTracked.isValid, isFalse, reason: name);
          expect(
            () => ref.pointIn(PointSpace.screen),
            throwsStateError,
            reason: name,
          );
          snapshot.dispose();
        });
      });
    });

    test('a render state update reads the terminal and keeps refs valid', () {
      withTerminal(10, 3, (t) {
        writeText(t, 'abc');
        final ref = t.gridRef(const GridPoint.active(0, 0))!;
        final state = RenderState();
        addTearDown(state.dispose);
        state.update(t);
        expect(ref.isValid, isTrue);
        expect(ref.text, 'a');
      });
    });

    test('a zeroed native ref is rejected by the library', () {
      // Guards the assumption that GridRef never builds a NULL-node ref:
      // the library reports INVALID_VALUE for it, which GridRef would
      // surface as a GhosttyException rather than garbage.
      withTerminal(10, 3, (t) {
        final raw = withScratch(sizeOf<GhosttyGridRef>(), (block) {
          final ref = block.cast<GhosttyGridRef>();
          return ghostty_grid_ref_cell(ref, nullptr);
        });
        expect(decodeResult(raw), GhosttyResultCode.invalidValue);
      });
    });
  });

  group('tracked ref ownership', () {
    test('disposing the ref then the terminal, and the reverse', () {
      for (final refFirst in const [true, false]) {
        final t = VtTerminal(cols: 10, rows: 3);
        writeText(t, 'abc');
        final refs = [
          for (var i = 0; i < 50; i++)
            t.trackGridRef(GridPoint.active(i % 10, 0))!,
        ];
        if (refFirst) {
          for (final ref in refs) {
            ref.dispose();
          }
          t.dispose();
        } else {
          t.dispose();
        }
        for (final ref in refs) {
          expect(ref.isDisposed, isTrue);
          ref.dispose();
        }
      }
    });

    test('a tracked ref disposed inside a callback is freed after it', () {
      withTerminal(10, 3, (t) {
        final ref = t.trackGridRef(const GridPoint.active(0, 0))!;
        var called = false;
        t.onBell = () {
          called = true;
          expect(() => ref.hasValue, throwsStateError);
          ref.dispose();
          expect(ref.isDisposed, isTrue);
        };
        writeText(t, '\x07X');
        expect(called, isTrue);
        expect(ref.isDisposed, isTrue);
        // The terminal is still usable and holds no stale tracked pin.
        final again = t.trackGridRef(const GridPoint.active(0, 0))!;
        expect(again.snapshot()!.text, 'X');
        again.dispose();
      });
    });

    test('pruned refs: snapshot null, pointIn null in every space', () {
      withTerminal(10, 3, (t) {
        t.scrollbackMaxLines = 0;
        writeText(t, 'X');
        final ref = t.trackGridRef(const GridPoint.active(0, 0))!;
        addTearDown(ref.dispose);
        for (var i = 0; i < 20 && ref.hasValue; i++) {
          writeText(t, numberedLines(1000));
        }
        expect(ref.hasValue, isFalse);
        expect(ref.snapshot(), isNull);
        for (final space in const [
          PointSpace.active,
          PointSpace.viewport,
          PointSpace.screen,
          PointSpace.history,
        ]) {
          expect(ref.pointIn(space), isNull, reason: '$space');
        }
      });
    });
  });
}
