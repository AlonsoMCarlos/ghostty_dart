import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart/src/core/internal.dart';
import 'package:ghostty_dart/src/ffi/bindings.g.dart';
import 'package:ghostty_dart/src/render/cell_layout.dart';
import 'package:ghostty_dart/src/render/render_enums.dart';
import 'package:ghostty_dart/src/render/render_state.dart';
import 'package:test/test.dart';

import '../support/terminal_support.dart';
import 'render_test_support.dart';

void main() {
  group('lifecycle', () {
    test('a new state is empty until the first update', () {
      final state = RenderState();
      addTearDown(state.dispose);
      expect(state.cols, 0);
      expect(state.rows, 0);
      expect(state.allRows, isEmpty);
      expect(state.isDisposed, isFalse);
    });

    test('dispose is idempotent and blocks every member', () {
      final state = RenderState()..dispose();
      state.dispose();
      expect(state.isDisposed, isTrue);
      withTerminal(4, 2, (terminal) {
        expect(() => state.update(terminal), throwsStateError);
        expect(() => state.beginUpdate(terminal), throwsStateError);
      });
      expect(() => state.endUpdate(), throwsStateError);
      expect(() => state.cols, throwsStateError);
      expect(() => state.dirty, throwsStateError);
      expect(() => state.cursor, throwsStateError);
      expect(() => state.colors, throwsStateError);
      expect(() => state.overscan, throwsStateError);
      expect(() => state.allRows.first, throwsStateError);
      expect(() => state.markClean(), throwsStateError);
      expect(() => state.imagePlacements(), throwsStateError);
      expect(
        () => state.allRows.first,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'RenderState has been disposed',
          ),
        ),
      );
    });

    test('updating from a disposed terminal throws StateError', () {
      final terminal = VtTerminal(cols: 4, rows: 2)..dispose();
      final state = RenderState();
      addTearDown(state.dispose);
      expect(() => state.update(terminal), throwsStateError);
    });

    test('outlives the terminal it was updated from', () {
      final state = RenderState();
      addTearDown(state.dispose);
      withTerminal(10, 2, (terminal) {
        writeText(terminal, 'kept');
        state.update(terminal);
      });
      expect(stateLines(state), ['kept', '']);
    });

    test('beginUpdate/endUpdate is a two-phase update', () {
      withRender(10, 2, (terminal, state) {
        writeText(terminal, 'two');
        state.beginUpdate(terminal);
        expect(() => state.cols, throwsStateError);
        expect(() => state.allRows.first, throwsStateError);
        state.endUpdate();
        expect(state.cols, 10);
        expect(stateLines(state).first, 'two');
        state.endUpdate(); // a no-op without beginUpdate
        expect(state.cols, 10);
      });
    });
  });

  group('cells', () {
    test('reads text, size and the default dirty state of a first update', () {
      withRender(20, 3, (terminal, state) {
        writeText(terminal, 'Hello\r\nworld');
        state.update(terminal);
        expect(state.cols, 20);
        expect(state.rows, 3);
        expect(state.dirty, RenderDirtyState.full);
        expect(stateLines(state), ['Hello', 'world', '']);
        final row = state.allRows.first;
        expect(row.length, 20);
        expect(row.index, 0);
        expect(row.viewportY, 0);
        expect(row.codepointAt(0), 'H'.codeUnitAt(0));
        expect(row.hasTextAt(4), isTrue);
        expect(row.hasTextAt(5), isFalse);
        expect(row.codepointAt(5), 0);
        expect(row.textAt(5), '');
        expect(row.codepointsAt(5), isEmpty);
        expect(row.widthAt(0), CellWidth.narrow);
        expect(row.hasStylingAt(0), isFalse);
        expect(row.styleAt(0), const CellStyle());
        expect(row.backgroundAt(0), const DefaultColor());
        expect(row.backgroundRgbAt(0), isNull);
        expect(row.foregroundRgbAt(0), isNull);
      });
    });

    test('out-of-range columns throw RangeError', () {
      withRender(5, 1, (terminal, state) {
        state.update(terminal);
        final row = state.allRows.first;
        expect(() => row.codepointAt(5), throwsRangeError);
        expect(() => row.codepointAt(-1), throwsRangeError);
        expect(() => row.styleAt(5), throwsRangeError);
        expect(() => row.isSelectedAt(5), throwsRangeError);
      });
    });

    test('SGR styles decode and equal styles share an instance', () {
      withRender(20, 2, (terminal, state) {
        writeText(
          terminal,
          '\x1b[1;31mAB\x1b[0m C\x1b[3;4;38;2;10;20;30;48;5;200mD\x1b[0m'
          '\r\n\x1b[1;31mE',
        );
        state.update(terminal);
        final rows = <List<RenderCell>>[];
        CellStyle? firstRowStyle;
        for (final row in state.allRows) {
          rows.add(row.cellsToList());
          if (row.index == 0) {
            firstRowStyle = row.styleAt(0);
            expect(row.hasStylingAt(0), isTrue);
            expect(identical(row.styleAt(0), row.styleAt(1)), isTrue);
            expect(row.styleRunEnd(0), 2);
            expect(row.styleRunEnd(2), 4);
            expect(row.styleRunEnd(4), 5);
            expect(row.styleRunEnd(19), 20);
            expect(row.foregroundRgbAt(0), state.colors.palette[1]);
            expect(row.foregroundRgbAt(4), const RgbColor(10, 20, 30));
            expect(row.backgroundRgbAt(4), state.colors.palette[200]);
          } else if (row.index == 1) {
            expect(identical(row.styleAt(0), firstRowStyle), isTrue);
          }
        }
        expect(
          rows[0][0].style,
          const CellStyle(bold: true, foreground: PaletteColor.red),
        );
        expect(rows[0][2].style, const CellStyle());
        expect(
          rows[0][4].style,
          const CellStyle(
            italic: true,
            underline: UnderlineStyle.single,
            foreground: RgbColor(10, 20, 30),
            background: PaletteColor(200),
          ),
        );
        expect(rows[0][4].background, const PaletteColor(200));
      });
    });

    test('wide CJK characters take a wide cell and a spacer', () {
      withRender(10, 1, (terminal, state) {
        writeText(terminal, '中a文');
        state.update(terminal);
        final cells = rowCells(state, 0);
        expect(cells.map((c) => c.width).take(5), [
          CellWidth.wide,
          CellWidth.spacerTail,
          CellWidth.narrow,
          CellWidth.wide,
          CellWidth.spacerTail,
        ]);
        expect(cells.map((c) => c.text).take(5), ['中', '', 'a', '文', '']);
        expect(CellWidth.spacerTail.isSpacer, isTrue);
        expect(stateLines(state), ['中a文']);
      });
    });

    test('a wide character that does not fit leaves a spacer head', () {
      withRender(3, 2, (terminal, state) {
        writeText(terminal, 'ab中');
        state.update(terminal);
        final rows = [for (final row in state.allRows) row.cellsToList()];
        expect(rows[0][2].width, CellWidth.spacerHead);
        expect(rows[1][0].width, CellWidth.wide);
        expect(rows[1][0].text, '中');
      });
    });

    test('multi-codepoint graphemes', () {
      withRender(10, 1, (terminal, state) {
        // Mode 2027 turns on grapheme clustering for emoji sequences.
        writeText(terminal, '\x1b[?2027hé 👍🏽 👨‍👩‍👧');
        state.update(terminal);
        final row = state.allRows.first;
        expect(row.hasGraphemeAt(0), isTrue);
        expect(row.textAt(0), 'é');
        expect(row.codepointsAt(0), [0x65, 0x301]);
        expect(row.codepointAt(0), 0x65);
        expect(row.widthAt(2), CellWidth.wide);
        expect(row.textAt(2), '👍🏽');
        expect(row.codepointsAt(2), [0x1F44D, 0x1F3FD]);
        // A ZWJ family: 5 codepoints, more than fit a small first buffer.
        final family = '👨‍👩‍👧';
        expect(row.textAt(5), family);
        expect(row.codepointsAt(5), family.runes.toList());
        final buffer = StringBuffer();
        for (var x = 0; x < row.length; x++) {
          row.writeTextTo(x, buffer);
        }
        expect(buffer.toString(), 'e\u{301} \u{1F44D}\u{1F3FD} $family');
      });
    });

    test('long graphemes grow the native buffer', () {
      withRender(4, 1, (terminal, state) {
        final grapheme = 'a${'́' * 40}';
        writeText(terminal, grapheme);
        state.update(terminal);
        final row = state.allRows.first;
        expect(row.codepointsAt(0).length, 41);
        expect(row.textAt(0), grapheme);
      });
    });

    test('colour-only cells from erasing with a background colour', () {
      withRender(6, 2, (terminal, state) {
        writeText(terminal, 'a\x1b[41m\x1b[K\r\n\x1b[48;2;10;20;30m\x1b[K');
        state.update(terminal);
        final rows = [for (final row in state.allRows) row.cellsToList()];
        expect(rows[0][0].background, const DefaultColor());
        expect(rows[0][1].background, PaletteColor.red);
        expect(rows[0][1].text, '');
        expect(rows[1][0].background, const RgbColor(10, 20, 30));
        final row = state.allRows.first;
        expect(row.backgroundRgbAt(1), state.colors.palette[1]);
      });
    });

    test('hyperlinks and protected cells are flagged', () {
      withRender(12, 1, (terminal, state) {
        writeText(
          terminal,
          'a\x1b]8;;https://example.com\x1b\\link\x1b]8;;\x1b\\b'
          '\x1b[1"qP\x1b[0"q',
        );
        state.update(terminal);
        final row = state.allRows.first;
        expect(row.hasHyperlinkAt(0), isFalse);
        expect(
          [for (var x = 1; x < 5; x++) row.hasHyperlinkAt(x)],
          [true, true, true, true],
        );
        expect(row.hasHyperlinkAt(5), isFalse);
        expect(row.isProtectedAt(5), isFalse);
        expect(row.isProtectedAt(6), isTrue);
      });
    });

    test('semantic prompt content (OSC 133)', () {
      withRender(12, 1, (terminal, state) {
        writeText(terminal, '\x1b]133;A\x07\$ \x1b]133;B\x07ls\x1b]133;C\x07');
        state.update(terminal);
        final row = state.allRows.first;
        expect(row.semanticContentAt(0), CellSemanticContent.prompt);
        expect(row.semanticContentAt(2), CellSemanticContent.input);
      });
    });

    test('no selection by default', () {
      withRender(5, 1, (terminal, state) {
        writeText(terminal, 'abc');
        state.update(terminal);
        final row = state.allRows.first;
        expect(row.selectionStart, isNull);
        expect(row.selectionEnd, isNull);
        expect(row.isSelectedAt(0), isFalse);
      });
    });
  });

  group('dirty tracking', () {
    test('partial updates report only the changed rows', () {
      withRender(10, 6, (terminal, state) {
        writeText(terminal, 'top');
        state
          ..update(terminal)
          ..markClean();
        expect(state.dirty, RenderDirtyState.clean);
        expect(state.allRows.where((row) => row.isDirty), isEmpty);

        state.update(terminal);
        expect(state.dirty, RenderDirtyState.clean);
        expect(state.dirtyRows, isEmpty);

        writeText(terminal, '\x1b[4;1Hx');
        state.update(terminal);
        expect(state.dirty, RenderDirtyState.partial);
        final dirty = [for (final row in state.dirtyRows) row.index];
        expect(dirty, contains(3));
        expect(dirty, isNot(contains(5)));
        expect([
          for (final row in state.allRows)
            if (row.isDirty) row.index,
        ], dirty);
        state.markClean();
        expect(state.dirtyRows, isEmpty);
      });
    });

    test('a full dirty state yields every row', () {
      withRender(10, 4, (terminal, state) {
        state.update(terminal);
        expect(state.dirty, RenderDirtyState.full);
        expect([for (final row in state.dirtyRows) row.index], [0, 1, 2, 3]);
      });
    });

    test('dirty and row dirty flags can be overridden', () {
      withRender(10, 3, (terminal, state) {
        state
          ..update(terminal)
          ..markClean()
          ..dirty = RenderDirtyState.partial;
        expect(state.dirty, RenderDirtyState.partial);
        expect(state.dirtyRows, isEmpty);
        state.allRows.elementAt(1).isDirty = true;
        expect([for (final row in state.dirtyRows) row.index], [1]);
        final row = state.allRows.elementAt(1);
        expect(row.isDirty, isTrue);
        row.isDirty = false;
        expect(row.isDirty, isFalse);
        expect(state.dirtyRows, isEmpty);
        expect(
          () => state.dirty = RenderDirtyState.unknown,
          throwsArgumentError,
        );
      });
    });

    test('resizing makes the next update full', () {
      withRender(10, 3, (terminal, state) {
        state
          ..update(terminal)
          ..markClean();
        terminal.resize(12, 4);
        state.update(terminal);
        expect(state.dirty, RenderDirtyState.full);
        expect(state.cols, 12);
        expect(state.rows, 4);
        expect(state.allRows.first.length, 12);
      });
    });
  });

  group('row views', () {
    test('a row view is invalid after the iteration ends', () {
      withRender(5, 2, (terminal, state) {
        state.update(terminal);
        final rows = state.allRows.toList();
        expect(rows, hasLength(2));
        expect(identical(rows[0], rows[1]), isTrue, reason: 'reused view');
        expect(() => rows[0].codepointAt(0), throwsStateError);
        expect(() => rows[0].length, throwsStateError);
        expect(rows[0].toString(), 'RenderRow(invalid)');
      });
    });

    test('a row view is invalid after an update or dispose', () {
      withTerminal(5, 2, (terminal) {
        final state = RenderState();
        state.update(terminal);
        final row = state.allRows.first;
        expect(row.codepointAt(0), 0);
        state.update(terminal);
        expect(() => row.codepointAt(0), throwsStateError);

        final again = state.allRows.first;
        state.dispose();
        expect(
          () => again.styleAt(0),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'RenderState has been disposed',
            ),
          ),
        );
      });
    });

    test('starting another iteration invalidates the first one', () {
      withRender(5, 3, (terminal, state) {
        state.update(terminal);
        final outer = state.allRows.iterator..moveNext();
        final inner = state.allRows.iterator..moveNext();
        expect(inner.current.index, 0);
        expect(outer.moveNext, throwsStateError);
      });
    });

    test('updating during an iteration stops it', () {
      withRender(5, 3, (terminal, state) {
        state.update(terminal);
        expect(() {
          for (final _ in state.allRows) {
            state.update(terminal);
          }
        }, throwsStateError);
      });
    });

    test('current before moveNext throws', () {
      withRender(5, 1, (terminal, state) {
        state.update(terminal);
        expect(() => state.allRows.iterator.current, throwsStateError);
      });
    });

    test('row ids follow rows as they scroll', () {
      withRender(10, 3, (terminal, state) {
        writeText(terminal, 'one\r\ntwo\r\nthree');
        state.update(terminal);
        final before = [for (final row in state.allRows) row.id];
        expect(before.toSet(), hasLength(3));
        writeText(terminal, '\r\nfour');
        state.update(terminal);
        final after = [for (final row in state.allRows) row.id];
        expect(stateLines(state), ['two', 'three', 'four']);
        expect(after[0], before[1]);
        expect(after[1], before[2]);
        expect(before, isNot(contains(after[2])));
      });
    });
  });

  group('cursor', () {
    test('position, visibility, style and blink', () {
      withRender(10, 3, (terminal, state) {
        writeText(terminal, 'abc');
        state.update(terminal);
        var cursor = state.cursor;
        expect(cursor.position, const GridPoint.viewport(3, 0));
        expect(cursor.isVisible, isTrue);
        expect(cursor.isOnWideTail, isFalse);
        expect(cursor.isPasswordInput, isFalse);
        state.update(terminal);
        expect(identical(state.cursor, cursor), isTrue);

        writeText(terminal, '\x1b[?25l\x1b[5 q\r\n');
        state.update(terminal);
        cursor = state.cursor;
        expect(cursor.isVisible, isFalse);
        expect(cursor.style, VtCursorStyle.bar);
        expect(cursor.isBlinking, isTrue);
        expect(cursor.position, const GridPoint.viewport(0, 1));

        writeText(terminal, '\x1b[2 q');
        state.update(terminal);
        expect(state.cursor.style, VtCursorStyle.block);
        expect(state.cursor.isBlinking, isFalse);
      });
    });

    test('is outside the viewport when scrolled back', () {
      withRender(10, 2, (terminal, state) {
        writeText(terminal, '1\r\n2\r\n3\r\n4');
        // Scroll the viewport up with the raw API (owned by the terminal
        // module).
        using((arena) {
          final behavior = arena<GhosttyTerminalScrollViewport>();
          behavior.ref.tag = GhosttyTerminalScrollViewportTag
              .GHOSTTY_TERMINAL_SCROLL_VIEWPORT_TOP;
          checkResult(
            ghostty_terminal_scroll_viewport(
              handleOf<GhosttyTerminalImpl>(terminal).pointer,
              behavior.ref,
            ),
            'ghostty_terminal_scroll_viewport',
          );
        });
        state.update(terminal);
        expect(state.cursor.position, isNull);
        expect(state.cursor.isOnWideTail, isFalse);
      });
    });
  });

  group('colors', () {
    test('defaults, palette changes and cursor colour', () {
      withRender(5, 1, (terminal, state) {
        state.update(terminal);
        final colors = state.colors;
        expect(colors.palette, hasLength(256));
        expect(colors.cursor, isNull);
        expect(
          () => colors.palette[0] = colors.background,
          throwsUnsupportedError,
        );
        state.update(terminal);
        expect(identical(state.colors, colors), isTrue);

        writeText(
          terminal,
          '\x1b]4;1;rgb:12/34/56\x1b\\\x1b]12;rgb:ff/00/00\x1b\\'
          '\x1b]10;rgb:01/02/03\x1b\\\x1b]11;rgb:04/05/06\x1b\\',
        );
        state.update(terminal);
        final changed = state.colors;
        expect(identical(changed, colors), isFalse);
        expect(changed.palette[1], const RgbColor(0x12, 0x34, 0x56));
        expect(changed.cursor, const RgbColor(0xff, 0, 0));
        expect(changed.foreground, const RgbColor(1, 2, 3));
        expect(changed.background, const RgbColor(4, 5, 6));
        expect(changed.resolve(PaletteColor.red), changed.palette[1]);
        expect(changed.resolve(const DefaultColor()), isNull);
        expect(
          changed.resolve(const RgbColor(9, 9, 9)),
          const RgbColor(9, 9, 9),
        );
      });
    });
  });

  group('overscan', () {
    test('captures rows above the viewport from scrollback', () {
      withRender(10, 3, (terminal, state) {
        for (var i = 0; i < 10; i++) {
          writeText(terminal, '${i == 0 ? '' : '\r\n'}line $i');
        }
        expect(state.overscanRequest, RenderOverscan.none);
        state.overscanRequest = const RenderOverscan(above: 2, below: 5);
        expect(state.overscanRequest, const RenderOverscan(above: 2, below: 5));
        state.update(terminal);
        expect(state.overscan, const RenderOverscan(above: 2));
        expect(state.rows, 3);
        final rows = [
          for (final row in state.allRows) (row.index, row.viewportY),
        ];
        expect(rows, [(0, -2), (1, -1), (2, 0), (3, 1), (4, 2)]);
        expect(stateLines(state).first, 'line 5');

        state.overscanRequest = null;
        expect(state.overscanRequest, RenderOverscan.none);
        state.update(terminal);
        expect(state.overscan, RenderOverscan.none);
        expect(state.allRows, hasLength(3));
      });
    });

    test('rejects out-of-range requests', () {
      withRender(5, 1, (terminal, state) {
        // The constructor asserts in debug builds; the setter range-checks
        // in release builds too.
        expect(
          () => state.overscanRequest = RenderOverscan(above: _tooMany),
          throwsA(anyOf(isA<AssertionError>(), isA<RangeError>())),
        );
      });
    });
  });

  group('images', () {
    final hasKitty = libghosttyVtBuildInfo.supports(VtFeature.kittyGraphics);

    test('reports a Kitty placement', () {
      withRender(10, 5, (terminal, state) {
        terminal.resize(10, 5, cellWidthPx: 8, cellHeightPx: 16);
        state.update(terminal);
        expect(state.imagePlacements(), isEmpty);
        final before = state.imagePlacementsGeneration;
        // A 1x1 RGB image (3 zero bytes), transmitted and displayed.
        writeText(terminal, '\x1b_Ga=T,f=24,s=1,v=1,i=7,q=2;AAAA\x1b\\');
        state.update(terminal);
        final placements = state.imagePlacements();
        expect(placements, hasLength(1));
        final placement = placements.single;
        expect(placement.protocol, ImageProtocol.kitty);
        expect(placement.imageId, 7);
        expect(placement.layer, ImageLayer.aboveText);
        expect(placement.z, 0);
        expect(placement.viewportCol, 0);
        expect(placement.viewportRow, 0);
        expect(placement.gridCols, 1);
        expect(placement.gridRows, 1);
        expect(placement.sourceWidth, 1);
        expect(placement.sourceHeight, 1);
        expect(placement.kittyKind, KittyPlacementKind.fixed);
        expect(placement.kittyPlacementId, isNotNull);
        expect(state.imagePlacementsGeneration, isNot(before));
        expect(placements, state.imagePlacements());
      });
    }, skip: hasKitty ? false : 'built without Kitty graphics');
  });

  group('cell decoding', () {
    test('the loaded library uses the canonical packed cell layout', () {
      expect(nativeCellLayoutIsCanonical, isTrue);
    });

    test('the manifest check rejects any moved or missing field', () {
      final json = ghostty_type_json().cast<Utf8>().toDartString();
      Map<String, Object?> manifest() =>
          jsonDecode(json) as Map<String, Object?>;
      expect(cellLayoutMatchesManifest(manifest()), isTrue);
      expect(cellLayoutMatchesManifest(null), isFalse);
      expect(cellLayoutMatchesManifest(manifest()..['schema'] = 2), isFalse);

      final moved = manifest();
      final bits =
          ((moved['types']! as Map)['GhosttyCell']! as Map)['bits']! as Map;
      (bits['wide'] as Map)['lsb'] = 43;
      expect(cellLayoutMatchesManifest(moved), isFalse);

      final missing = manifest();
      (((missing['types']! as Map)['GhosttyCell']! as Map)['bits']! as Map)
          .remove('hyperlink');
      expect(cellLayoutMatchesManifest(missing), isFalse);
    });

    test('transcoding with ghostty_cell_get_multi matches the fast path', () {
      withTerminal(16, 4, (terminal) {
        writeText(
          terminal,
          '\x1b[?2027h\x1b[1;31mA\x1b[0m中é👍🏽'
          '\x1b]8;;x\x1b\\L\x1b]8;;\x1b\\\x1b[1"qP\x1b[0"q'
          '\r\n\x1b[41m\x1b[K\r\n\x1b[48;2;1;2;3m\x1b[K\x1b[0m'
          '\x1b]133;A\x07\$ ',
        );
        final fast = RenderState();
        final slow = newTranscodingRenderStateForTesting();
        try {
          fast.update(terminal);
          slow.update(terminal);
          final fastRows = [for (final r in fast.allRows) r.cellsToList()];
          final slowRows = [for (final r in slow.allRows) r.cellsToList()];
          expect(slowRows, fastRows);
          expect(fastRows[0][0].style.bold, isTrue);
        } finally {
          fast.dispose();
          slow.dispose();
        }
      });
    });
  });

  group('enum codecs match the C constants', () {
    test('every raw value', () {
      void expectRaw<E extends Enum>(
        List<E> values,
        E unknown,
        Map<E, int> expected,
        int Function(E) encode,
        E Function(int) decode,
      ) {
        expect(expected.keys.toSet(), values.toSet()..remove(unknown));
        expected.forEach((value, raw) {
          expect(encode(value), raw, reason: '$value');
          expect(decode(raw), value, reason: '$value');
        });
        expect(decode(9999), unknown);
        expect(decode(GHOSTTY_ENUM_MAX_VALUE), unknown);
        expect(() => encode(unknown), throwsArgumentError);
      }

      expectRaw(
        RenderDirtyState.values,
        RenderDirtyState.unknown,
        {
          RenderDirtyState.clean:
              GhosttyRenderStateDirty.GHOSTTY_RENDER_STATE_DIRTY_FALSE,
          RenderDirtyState.partial:
              GhosttyRenderStateDirty.GHOSTTY_RENDER_STATE_DIRTY_PARTIAL,
          RenderDirtyState.full:
              GhosttyRenderStateDirty.GHOSTTY_RENDER_STATE_DIRTY_FULL,
        },
        renderDirtyStateCodec.encode,
        renderDirtyStateCodec.decode,
      );
      expectRaw(
        CellWidth.values,
        CellWidth.unknown,
        {
          CellWidth.narrow: GhosttyCellWide.GHOSTTY_CELL_WIDE_NARROW,
          CellWidth.wide: GhosttyCellWide.GHOSTTY_CELL_WIDE_WIDE,
          CellWidth.spacerTail: GhosttyCellWide.GHOSTTY_CELL_WIDE_SPACER_TAIL,
          CellWidth.spacerHead: GhosttyCellWide.GHOSTTY_CELL_WIDE_SPACER_HEAD,
        },
        cellWidthCodec.encode,
        cellWidthCodec.decode,
      );
      expectRaw(
        CellSemanticContent.values,
        CellSemanticContent.unknown,
        {
          CellSemanticContent.output:
              GhosttyCellSemanticContent.GHOSTTY_CELL_SEMANTIC_OUTPUT,
          CellSemanticContent.input:
              GhosttyCellSemanticContent.GHOSTTY_CELL_SEMANTIC_INPUT,
          CellSemanticContent.prompt:
              GhosttyCellSemanticContent.GHOSTTY_CELL_SEMANTIC_PROMPT,
        },
        cellSemanticContentCodec.encode,
        cellSemanticContentCodec.decode,
      );
      expectRaw(
        ImageProtocol.values,
        ImageProtocol.unknown,
        {
          ImageProtocol.kitty:
              GhosttyImageProtocol.GHOSTTY_IMAGE_PROTOCOL_KITTY,
        },
        imageProtocolCodec.encode,
        imageProtocolCodec.decode,
      );
      expectRaw(
        ImageLayer.values,
        ImageLayer.unknown,
        {
          ImageLayer.belowBackground:
              GhosttyImageLayer.GHOSTTY_IMAGE_LAYER_BELOW_BACKGROUND,
          ImageLayer.belowText:
              GhosttyImageLayer.GHOSTTY_IMAGE_LAYER_BELOW_TEXT,
          ImageLayer.aboveText:
              GhosttyImageLayer.GHOSTTY_IMAGE_LAYER_ABOVE_TEXT,
        },
        imageLayerCodec.encode,
        imageLayerCodec.decode,
      );
      expectRaw(
        KittyPlacementKind.values,
        KittyPlacementKind.unknown,
        {
          KittyPlacementKind.virtual: GhosttyRenderStateKittyPlacementKind
              .GHOSTTY_RENDER_STATE_KITTY_PLACEMENT_KIND_VIRTUAL,
          KittyPlacementKind.relative: GhosttyRenderStateKittyPlacementKind
              .GHOSTTY_RENDER_STATE_KITTY_PLACEMENT_KIND_RELATIVE,
          KittyPlacementKind.fixed: GhosttyRenderStateKittyPlacementKind
              .GHOSTTY_RENDER_STATE_KITTY_PLACEMENT_KIND_FIXED,
        },
        kittyPlacementKindCodec.encode,
        kittyPlacementKindCodec.decode,
      );
    });

    test('canonical cell tags match the C constants', () {
      expect(
        CellBits.tagCodepoint,
        GhosttyCellContentTag.GHOSTTY_CELL_CONTENT_CODEPOINT,
      );
      expect(
        CellBits.tagGrapheme,
        GhosttyCellContentTag.GHOSTTY_CELL_CONTENT_CODEPOINT_GRAPHEME,
      );
      expect(
        CellBits.tagBgPalette,
        GhosttyCellContentTag.GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE,
      );
      expect(
        CellBits.tagBgRgb,
        GhosttyCellContentTag.GHOSTTY_CELL_CONTENT_BG_COLOR_RGB,
      );
    });
  });

  group('value types', () {
    test('equality and toString', () {
      expect(
        const RenderOverscan(above: 1, below: 2),
        const RenderOverscan(above: 1, below: 2),
      );
      expect(const RenderRowId(1, 2), const RenderRowId(1, 2));
      expect(const RenderRowId(1, 2), isNot(const RenderRowId(2, 1)));
      expect(const RenderRowId(-1, 2).toString(), contains('ffffffffffffffff'));
      expect(
        () => RenderColors(
          background: const RgbColor(0, 0, 0),
          foreground: const RgbColor(0, 0, 0),
          palette: const [],
        ),
        throwsArgumentError,
      );
    });
  });
}

final _tooMany = int.parse('70000');
