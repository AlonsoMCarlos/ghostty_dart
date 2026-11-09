// Adversarial tests from the correctness review of the render module.
//
// The main tool is an oracle: a second render state driven only through the
// raw bindings, reading every cell one native call at a time
// (`row_cells_get` RAW / STYLE / BG_COLOR / FG_COLOR / GRAPHEMES_BUF /
// SELECTED and `ghostty_cell_get`). The Dart fast path (packed-cell
// decoding, per-row style-id cache, global style cache) must agree with it
// cell by cell on every screen these tests build.

import 'dart:convert';
import 'dart:ffi';
import 'dart:math';

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

/// One cell as read by the oracle.
typedef _OracleCell = ({
  String text,
  int wide,
  CellStyle style,
  RgbColor? background,
  RgbColor? foreground,
  bool hyperlink,
  bool protected,
  int semantic,
  bool selected,
});

/// Every captured row of [terminal] read through the raw bindings, with the
/// overscan request of the Dart state applied.
List<List<_OracleCell>> _oracle(VtTerminal terminal, {int above = 0}) => using((
  arena,
) {
  final stateOut = arena<GhosttyRenderState>();
  checkResult(ghostty_render_state_new(nullptr, stateOut), 'new');
  final state = stateOut.value;
  final itOut = arena<GhosttyRenderStateRowIterator>();
  final cellsOut = arena<GhosttyRenderStateRowCells>();
  checkResult(ghostty_render_state_row_iterator_new(nullptr, itOut), 'it');
  checkResult(ghostty_render_state_row_cells_new(nullptr, cellsOut), 'c');
  try {
    if (above > 0) {
      final o = arena<GhosttyRenderStateOverscan>()
        ..ref.above = above
        ..ref.below = 0;
      checkResult(
        ghostty_render_state_set(
          state,
          GhosttyRenderStateOption.GHOSTTY_RENDER_STATE_OPT_OVERSCAN,
          o.cast(),
        ),
        'set',
      );
    }
    checkResult(
      ghostty_render_state_update(
        state,
        handleOf<GhosttyTerminalImpl>(terminal).pointer,
      ),
      'update',
    );
    checkResult(
      ghostty_render_state_get(
        state,
        GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR,
        itOut.cast(),
      ),
      'get',
    );
    final raw = arena<Uint64>();
    final style = arena<GhosttyStyle>();
    final rgb = arena<GhosttyColorRgb>();
    final flag = arena<Bool>();
    final u32 = arena<Uint32>();
    final cps = arena<Uint32>(64);
    final buf = arena<GhosttyCodepointBuffer>();
    final rows = <List<_OracleCell>>[];
    while (ghostty_render_state_row_iterator_next(itOut.value)) {
      checkResult(
        ghostty_render_state_row_get(
          itOut.value,
          GhosttyRenderStateRowData.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
          cellsOut.cast(),
        ),
        'row_get',
      );
      final row = <_OracleCell>[];
      while (ghostty_render_state_row_cells_next(cellsOut.value)) {
        final c = cellsOut.value;
        int get(int key, Pointer<Void> out) =>
            ghostty_render_state_row_cells_get(c, key, out);
        RgbColor? color(int key) =>
            get(key, rgb.cast()) == 0 ? rgbFromNative(rgb.ref) : null;
        checkResult(
          get(
            GhosttyRenderStateRowCellsData
                .GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW,
            raw.cast(),
          ),
          'raw',
        );
        checkResult(
          get(
            GhosttyRenderStateRowCellsData
                .GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE,
            style.cast(),
          ),
          'style',
        );
        buf.ref
          ..ptr = cps
          ..cap = 64
          ..len = 0;
        checkResult(
          get(
            GhosttyRenderStateRowCellsData
                .GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF,
            buf.cast(),
          ),
          'graphemes',
        );
        checkResult(
          get(
            GhosttyRenderStateRowCellsData
                .GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_SELECTED,
            flag.cast(),
          ),
          'selected',
        );
        final selected = flag.value;
        int cellU32(int key) {
          u32.value = 0;
          checkResult(ghostty_cell_get(raw.value, key, u32.cast()), 'cg');
          return u32.value;
        }

        bool cellBool(int key) {
          flag.value = false;
          checkResult(ghostty_cell_get(raw.value, key, flag.cast()), 'cg');
          return flag.value;
        }

        row.add((
          text: String.fromCharCodes(cps.asTypedList(buf.ref.len)),
          wide: cellU32(GhosttyCellData.GHOSTTY_CELL_DATA_WIDE),
          style: cellStyleFromNative(style.ref),
          background: color(
            GhosttyRenderStateRowCellsData
                .GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR,
          ),
          foreground: color(
            GhosttyRenderStateRowCellsData
                .GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR,
          ),
          hyperlink: cellBool(GhosttyCellData.GHOSTTY_CELL_DATA_HAS_HYPERLINK),
          protected: cellBool(GhosttyCellData.GHOSTTY_CELL_DATA_PROTECTED),
          semantic: cellU32(GhosttyCellData.GHOSTTY_CELL_DATA_SEMANTIC_CONTENT),
          selected: selected,
        ));
      }
      rows.add(row);
    }
    return rows;
  } finally {
    ghostty_render_state_row_cells_free(cellsOut.value);
    ghostty_render_state_row_iterator_free(itOut.value);
    ghostty_render_state_free(state);
  }
});

/// The same cells read through the Dart API of [state].
List<List<_OracleCell>> _dart(RenderState state) => [
  for (final row in state.allRows)
    [
      for (var x = 0; x < row.length; x++)
        (
          text: row.textAt(x),
          wide: cellWidthCodec.encode(row.widthAt(x)),
          style: row.styleAt(x),
          background: row.backgroundRgbAt(x),
          foreground: row.foregroundRgbAt(x),
          hyperlink: row.hasHyperlinkAt(x),
          protected: row.isProtectedAt(x),
          semantic: cellSemanticContentCodec.encode(row.semanticContentAt(x)),
          selected: row.isSelectedAt(x),
        ),
    ],
];

/// Asserts that the fast path and the transcoding path of the Dart API both
/// match the oracle on the current content of [terminal]. Returns the
/// number of captured rows.
int _expectMatchesOracle(VtTerminal terminal, {int above = 0}) {
  final expected = _oracle(terminal, above: above);
  for (final state in [RenderState(), newTranscodingRenderStateForTesting()]) {
    try {
      if (above > 0) state.overscanRequest = RenderOverscan(above: above);
      state.update(terminal);
      final actual = _dart(state);
      expect(actual.length, expected.length, reason: 'row count');
      for (var y = 0; y < expected.length; y++) {
        expect(actual[y], expected[y], reason: 'row $y');
      }
    } finally {
      state.dispose();
    }
  }
  return expected.length;
}

void main() {
  group('oracle: fast path equals per-cell native reads', () {
    test('every SGR attribute, 256 and 24-bit colours', () {
      withTerminal(40, 12, (terminal) {
        writeText(
          terminal,
          '\x1b[1mB\x1b[0m\x1b[2mF\x1b[0m\x1b[3mI\x1b[0m\x1b[4mU\x1b[0m'
          '\x1b[4:3mC\x1b[0m\x1b[21mD\x1b[0m\x1b[4:4md\x1b[0m\x1b[4:5mh\x1b[0m'
          '\x1b[5mK\x1b[0m\x1b[7mR\x1b[0m\x1b[8mH\x1b[0m\x1b[9mS\x1b[0m'
          '\x1b[53mO\x1b[0m\r\n'
          '\x1b[31ma\x1b[91mb\x1b[38;5;196mc\x1b[38;2;1;2;3md\x1b[0m'
          '\x1b[41me\x1b[101mf\x1b[48;5;17mg\x1b[48;2;250;128;7mh\x1b[0m'
          '\x1b[4;58;5;33mi\x1b[58;2;9;8;7mj\x1b[0m\r\n'
          '\x1b[1;3;4;7;9;53;38;2;10;20;30;48;5;200mZ\x1b[0m\r\n'
          // Colour-only cells (erase with a background) of each kind.
          '\x1b[48;5;100m\x1b[K\x1b[0m\r\n\x1b[48;2;5;6;7m\x1b[K\x1b[0m\r\n'
          '\x1b[42m   \x1b[0m',
        );
        _expectMatchesOracle(terminal);
      });
    });

    test('a palette change (OSC 4) re-resolves palette colours', () {
      withTerminal(10, 2, (terminal) {
        writeText(terminal, '\x1b[38;5;196;48;5;100mX\x1b[0m');
        _expectMatchesOracle(terminal);
        writeText(terminal, '\x1b]4;196;rgb:12/34/56\x07');
        writeText(terminal, '\x1b]4;100;rgb:ab/cd/ef\x07');
        _expectMatchesOracle(terminal);
        withRender(10, 2, (_, state) {
          state.update(terminal);
          final row = state.allRows.first;
          expect(row.styleAt(0).foreground, const PaletteColor(196));
          expect(row.foregroundRgbAt(0), const RgbColor(0x12, 0x34, 0x56));
          expect(row.backgroundRgbAt(0), const RgbColor(0xab, 0xcd, 0xef));
          expect(state.colors.palette[196], const RgbColor(0x12, 0x34, 0x56));
        });
      });
    });

    test('combining marks, ZWJ emoji, flags, VS16, with and without 2027', () {
      for (final mode2027 in [false, true]) {
        withTerminal(20, 4, (terminal) {
          if (mode2027) writeText(terminal, '\x1b[?2027h');
          writeText(
            terminal,
            'éạ̈|'
            '\u{1F468}‍\u{1F469}‍\u{1F467}|'
            '\u{1F1EA}\u{1F1F8}|❤️|\u{1F44D}\u{1F3FD}',
          );
          _expectMatchesOracle(terminal);
          withRender(20, 4, (_, state) {
            state.update(terminal);
            final row = state.allRows.first;
            expect(row.textAt(0), 'é');
            expect(row.hasGraphemeAt(0), isTrue);
            expect(row.widthAt(0), CellWidth.narrow);
            expect(row.textAt(1), 'ạ̈');
            expect(row.codepointsAt(1), [0x61, 0x308, 0x323]);
            final sink = StringBuffer();
            row.writeTextTo(1, sink);
            expect(sink.toString(), 'ạ̈');
          });
        });
      }
    });

    test('wide characters at the last column (spacer head) and wrapping', () {
      withTerminal(5, 4, (terminal) {
        writeText(terminal, 'abcd中ef\r\n中中中');
        _expectMatchesOracle(terminal);
        withRender(5, 4, (_, state) {
          state.update(terminal);
          final rows = [for (final r in state.allRows) r.cellsToList()];
          expect(rows[0][4].width, CellWidth.spacerHead);
          expect(rows[0][4].text, '');
          expect(rows[1][0].width, CellWidth.wide);
          expect(rows[1][0].text, '中');
          expect(rows[1][1].width, CellWidth.spacerTail);
          expect(rows[1][1].text, '');
          // Three wide chars in 5 columns: the third wraps again.
          expect(rows[2][4].width, CellWidth.spacerHead);
          expect(rows[3][0].text, '中');
        });
      });
    });

    test('OSC 8 hyperlinks, protected cells and OSC 133 semantics', () {
      withTerminal(30, 4, (terminal) {
        writeText(
          terminal,
          '\x1b]8;id=a;https://example.com\x1b\\link\x1b]8;;\x1b\\ plain '
          '\x1b]8;;file:///x\x1b\\\x1b[1mB\x1b]8;;\x1b\\\x1b[0m\r\n'
          '\x1b[1"qPROT\x1b[0"qfree\r\n'
          '\x1b]133;A\x07\$ \x1b]133;B\x07ls\x1b]133;C\x07\r\nout',
        );
        _expectMatchesOracle(terminal);
        withRender(30, 4, (_, state) {
          state.update(terminal);
          final rows = [for (final r in state.allRows) r.cellsToList()];
          expect(rows[0].take(4).every((c) => c.hasHyperlink), isTrue);
          expect(rows[0][4].hasHyperlink, isFalse);
          expect(rows[0][11].hasHyperlink, isTrue);
          expect(rows[0][11].style.bold, isTrue);
          expect(rows[1].take(4).every((c) => c.isProtected), isTrue);
          expect(rows[1][4].isProtected, isFalse);
          expect(rows[2][0].semanticContent, CellSemanticContent.prompt);
          expect(rows[2][2].semanticContent, CellSemanticContent.input);
        });
      });
    });

    test('random byte streams (property test, fixed seeds)', () {
      const pieces = [
        'a',
        'Z',
        ' ',
        '中',
        'é',
        'é',
        '\u{1F600}',
        '\u{1F44D}\u{1F3FD}',
        '\r\n',
        '\r',
        '\t',
        '\b',
        '\x1b[0m',
        '\x1b[1;4m',
        '\x1b[3;9m',
        '\x1b[38;5;123m',
        '\x1b[48;2;9;99;199m',
        '\x1b[7m',
        '\x1b[K',
        '\x1b[2J',
        '\x1b[H',
        '\x1b[5;3H',
        '\x1b[2@',
        '\x1b[3P',
        '\x1b[L',
        '\x1b[M',
        '\x1b]8;;u\x1b\\',
        '\x1b]8;;\x1b\\',
        '\x1b[1"q',
        '\x1b[0"q',
        '\x1b[?1049h',
        '\x1b[?1049l',
        '\x1b[41m\x1b[K',
        '\x1b[?2027h',
        '\x1b]133;A\x07',
        '\x1b[S',
        '\x1b[T',
        '\x1b[4:3;58;5;9m',
      ];
      for (var seed = 0; seed < 12; seed++) {
        final random = Random(seed);
        withTerminal(23, 7, (terminal) {
          final text = StringBuffer();
          for (var i = 0; i < 400; i++) {
            text.write(pieces[random.nextInt(pieces.length)]);
          }
          writeText(terminal, text.toString());
          _expectMatchesOracle(terminal);
        });
      }
    });

    test('scrollback over several pages, many styles, with overscan', () {
      // Style ids are per page; enough scrollback spans several pages, and
      // the overscan rows cross page boundaries.
      withTerminal(80, 10, (terminal) {
        terminal.scrollbackMaxBytes = 64 * 1024 * 1024;
        final text = StringBuffer();
        for (var i = 0; i < 3000; i++) {
          text.write(
            '\x1b[38;2;${i % 256};${(i ~/ 7) % 256};${(i ~/ 3) % 256}m'
            'line $i \x1b[${1 + i % 9}m${'x' * (i % 50)}\x1b[0m\r\n',
          );
        }
        writeText(terminal, text.toString());
        terminal.scrollViewport(const ViewportScroll.delta(-1500));
        expect(_expectMatchesOracle(terminal, above: 1200), 1210);
      });
    });
  });

  group('screens and viewport', () {
    test('viewport scrolled into scrollback shows the older rows', () {
      withRender(10, 3, (terminal, state) {
        writeText(terminal, '1\r\n2\r\n3\r\n4\r\n5');
        state.update(terminal);
        expect(stateLines(state), ['3', '4', '5']);
        state.markClean();
        terminal.scrollViewport(const ViewportScroll.top());
        state.update(terminal);
        expect(stateLines(state), ['1', '2', '3']);
        // The viewport moved: every row must be redrawn.
        expect([for (final r in state.dirtyRows) r.index], [0, 1, 2]);
        expect(state.cursor.position, isNull);
        // New output while scrolled back does not move the viewport.
        state.markClean();
        writeText(terminal, '\r\n6');
        state.update(terminal);
        expect(stateLines(state), ['1', '2', '3']);
        terminal.scrollViewport(const ViewportScroll.delta(100));
        state.update(terminal);
        expect(stateLines(state), ['4', '5', '6']);
        expect(state.cursor.position, GridPoint.viewport(1, 2));
      });
    });

    test('alternate screen switch and back', () {
      withRender(10, 3, (terminal, state) {
        writeText(terminal, 'main');
        state.update(terminal);
        state.markClean();
        writeText(terminal, '\x1b[?1049h\x1b[Halt');
        state.update(terminal);
        expect(state.dirty, RenderDirtyState.full);
        expect(stateLines(state), ['alt', '', '']);
        state.markClean();
        writeText(terminal, '\x1b[?1049l');
        state.update(terminal);
        expect(state.dirty, RenderDirtyState.full);
        expect(stateLines(state), ['main', '', '']);
        expect(state.cursor.position, GridPoint.viewport(4, 0));
      });
    });

    test('resize between updates changes the row length and row count', () {
      withRender(10, 3, (terminal, state) {
        writeText(terminal, '0123456789abc');
        state.update(terminal);
        final iterator = state.allRows.iterator..moveNext();
        final first = iterator.current;
        expect(first.length, 10);
        terminal.resize(4, 6);
        state.update(terminal);
        expect(state.cols, 4);
        expect(state.rows, 6);
        // The view captured before the resize is dead, not reading freed
        // or resized native memory.
        expect(() => first.codepointAt(0), throwsStateError);
        expect(iterator.moveNext, throwsStateError);
        final lengths = [for (final r in state.allRows) r.length];
        expect(lengths, List.filled(6, 4));
        _expectMatchesOracle(terminal);
        terminal.resize(30, 2);
        _expectMatchesOracle(terminal);
      });
    });

    test('the state is a copy: later output and dispose of the terminal '
        'do not change it', () {
      final terminal = VtTerminal(cols: 10, rows: 2);
      final state = RenderState();
      try {
        writeText(terminal, '\x1b[?2027h\x1b[1mA\u{1F468}‍\u{1F469}');
        state.update(terminal);
        writeText(terminal, '\x1b[2J\x1b[Hgone');
        expect(stateLines(state).first, 'A\u{1F468}‍\u{1F469}');
        terminal.dispose();
        // Graphemes and styles are read lazily from render-state memory.
        final row = state.allRows.first;
        expect(row.styleAt(0).bold, isTrue);
        expect(row.textAt(1), '\u{1F468}‍\u{1F469}');
      } finally {
        state.dispose();
        terminal.dispose();
      }
    });
  });

  group('dirty semantics', () {
    test('iterating does not clear; markClean clears rows and global', () {
      withRender(10, 3, (terminal, state) {
        // Park the cursor on row 1 first: moving the cursor also dirties
        // the row it leaves.
        writeText(terminal, '\x1b[2;1H');
        state.update(terminal);
        state.markClean();
        writeText(terminal, 'x');
        state.update(terminal);
        expect(state.dirty, RenderDirtyState.partial);
        expect([for (final r in state.dirtyRows) r.index], [1]);
        expect([for (final r in state.dirtyRows) r.index], [1]);
        state.markClean();
        expect(state.dirty, RenderDirtyState.clean);
        expect(state.dirtyRows, isEmpty);
        // An update with no change stays clean.
        state.update(terminal);
        expect(state.dirty, RenderDirtyState.clean);
        // Forcing partial after clean: no row is dirty any more.
        state.dirty = RenderDirtyState.partial;
        expect(state.dirtyRows, isEmpty);
        expect(
          [for (final r in state.allRows) r.isDirty],
          [false, false, false],
        );
        // Updates only raise the dirty state: a forced value survives an
        // update without changes until markClean.
        state.update(terminal);
        expect(state.dirty, RenderDirtyState.partial);
      });
    });

    test('row dirty flags accumulate across updates until markClean', () {
      withRender(10, 4, (terminal, state) {
        writeText(terminal, '\x1b[2;1H');
        state.update(terminal);
        state.markClean();
        writeText(terminal, 'a');
        state.update(terminal); // frame skipped: no markClean
        writeText(terminal, '\x1b[3;1H\x1b[4;1Hb');
        state.update(terminal);
        expect(state.dirty, RenderDirtyState.partial);
        expect([for (final r in state.dirtyRows) r.index], [1, 2, 3]);
      });
    });

    test('a row kept dirty survives into the next partial update', () {
      withRender(10, 3, (terminal, state) {
        state.update(terminal);
        state.markClean();
        writeText(terminal, '\x1b[1;1Ha');
        state.update(terminal);
        state.dirty = RenderDirtyState.partial;
        for (final row in state.allRows) {
          row.isDirty = row.index == 2;
        }
        expect([for (final r in state.dirtyRows) r.index], [2]);
      });
    });

    test('markClean during an iteration updates the current view', () {
      withRender(10, 2, (terminal, state) {
        state.update(terminal);
        for (final row in state.dirtyRows) {
          expect(row.isDirty, isTrue);
          state.markClean();
          expect(row.isDirty, isFalse);
          break;
        }
      });
    });
  });

  group('two-phase update', () {
    test('begin twice needs only one end', () {
      withRender(10, 2, (terminal, state) {
        writeText(terminal, 'one');
        state.beginUpdate(terminal);
        writeText(terminal, '\rtwo');
        state.beginUpdate(terminal);
        expect(() => state.dirty, throwsStateError);
        expect(() => state.allRows.first, throwsStateError);
        state.endUpdate();
        expect(stateLines(state).first, 'two');
        _expectMatchesOracle(terminal);
      });
    });

    test('the terminal may change between begin and end', () {
      withRender(10, 2, (terminal, state) {
        writeText(terminal, '\x1b[1mbold');
        state.beginUpdate(terminal);
        writeText(terminal, '\x1b[2J\x1b[H\x1b[0mlater');
        state.endUpdate();
        final row = state.allRows.first;
        expect(rowText(row), 'bold');
        expect(row.styleAt(0).bold, isTrue);
      });
    });
  });

  group('cursor', () {
    test('on the tail of a wide character', () {
      withRender(10, 2, (terminal, state) {
        writeText(terminal, 'a中\x1b[3G');
        state.update(terminal);
        expect(state.cursor.position, GridPoint.viewport(2, 0));
        expect(state.cursor.isOnWideTail, isTrue);
        writeText(terminal, '\x1b[2G');
        state.update(terminal);
        expect(state.cursor.isOnWideTail, isFalse);
      });
    });

    test('hidden cursor (DECTCEM) and style DECSCUSR', () {
      withRender(10, 2, (terminal, state) {
        writeText(terminal, '\x1b[?25l\x1b[6 q');
        state.update(terminal);
        expect(state.cursor.isVisible, isFalse);
        expect(state.cursor.style, VtCursorStyle.bar);
        expect(state.cursor.isPasswordInput, isFalse);
      });
    });
  });

  group('images', () {
    final hasKitty = libghosttyVtBuildInfo.supports(VtFeature.kittyGraphics);

    test('placement units: cells for grid and position, pixels for size', () {
      withRender(10, 5, (terminal, state) {
        terminal.resize(10, 5, cellWidthPx: 8, cellHeightPx: 16);
        // A 2x2 RGBA image shown over 3 columns x 2 rows, at cell (2, 1)
        // with a pixel offset, cropped to its right column.
        writeText(
          terminal,
          '\x1b[2;3H\x1b_Ga=T,f=32,s=2,v=2,i=9,p=4,c=3,r=2,X=3,Y=5,'
          'x=1,y=0,w=1,h=2,z=-5,q=2;'
          '${base64.encode(List.filled(16, 255))}\x1b\\',
        );
        state.update(terminal);
        final p = state.imagePlacements().single;
        expect(p.imageId, 9);
        expect(p.kittyPlacementId, 4);
        expect(p.viewportCol, 2);
        expect(p.viewportRow, 1);
        expect(p.gridCols, 3);
        expect(p.gridRows, 2);
        expect(p.cellOffsetX, 3);
        expect(p.cellOffsetY, 5);
        expect(p.pixelWidth, 3 * 8 - 3);
        expect(p.pixelHeight, 2 * 16 - 5);
        expect(p.sourceX, 1);
        expect(p.sourceWidth, 1);
        expect(p.sourceHeight, 2);
        expect(p.z, -5);
        expect(p.layer, ImageLayer.belowText);
      });
    }, skip: hasKitty ? false : 'built without Kitty graphics');

    test('a placement scrolled above the viewport has a negative row', () {
      withRender(10, 3, (terminal, state) {
        terminal.resize(10, 3, cellWidthPx: 8, cellHeightPx: 16);
        writeText(
          terminal,
          '\x1b_Ga=T,f=24,s=1,v=1,i=3,r=2,q=2;AAAA\x1b\\'
          '\x1b[3;1H\r\n',
        );
        state.update(terminal);
        final p = state.imagePlacements().single;
        expect(p.viewportRow, -1);
        expect(p.gridRows, 2);
      });
    }, skip: hasKitty ? false : 'built without Kitty graphics');
  });

  group('lifetime', () {
    test('dispose inside an iteration stops it with StateError', () {
      final state = RenderState();
      withTerminal(10, 3, (terminal) {
        state.update(terminal);
        final iterator = state.allRows.iterator..moveNext();
        final row = iterator.current;
        state.dispose();
        expect(iterator.moveNext, throwsStateError);
        expect(() => row.length, throwsStateError);
        expect(state.dispose, returnsNormally);
      });
    });

    test('many states created and dropped do not leak handles', () {
      withTerminal(20, 5, (terminal) {
        for (var i = 0; i < 200; i++) {
          final state = RenderState()..update(terminal);
          state.allRows.first.styleAt(0);
          state.dispose();
        }
      });
    });
  });

  group('manifest guard', () {
    Map<String, Object?> manifest() =>
        jsonDecode(ghostty_type_json().cast<Utf8>().toDartString())
            as Map<String, Object?>;
    Map<String, Object?> type(Map<String, Object?> m, String name) =>
        (m['types']! as Map<String, Object?>)[name]! as Map<String, Object?>;

    test('a renumbered enum value makes the layout non-canonical', () {
      expect(cellLayoutMatchesManifest(manifest()), isTrue);
      for (final (name, value) in [
        ('GhosttyCellContentTag', 'BG_COLOR_RGB'),
        ('GhosttyCellWide', 'SPACER_TAIL'),
        ('GhosttyCellSemanticContent', 'PROMPT'),
      ]) {
        final m = manifest();
        (type(m, name)['values']! as Map)[value] = 7;
        expect(cellLayoutMatchesManifest(m), isFalse, reason: '$name.$value');
      }
    });

    test('a retyped field or a different union tag is rejected', () {
      final retyped = manifest();
      ((type(retyped, 'GhosttyCell')['bits']! as Map)['style_id']
              as Map)['type'] =
          'GhosttyOtherId';
      expect(cellLayoutMatchesManifest(retyped), isFalse);

      final tag = manifest();
      ((type(tag, 'GhosttyCell')['bits']! as Map)['content'] as Map)['tag'] =
          'wide';
      expect(cellLayoutMatchesManifest(tag), isFalse);
    });

    test('a new semantic value is still canonical (decodes as unknown)', () {
      final m = manifest();
      (type(m, 'GhosttyCellSemanticContent')['values']! as Map)['NEW'] = 3;
      expect(cellLayoutMatchesManifest(m), isTrue);
    });
  });
}
