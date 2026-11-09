import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart/src/core/internal.dart';
import 'package:ghostty_dart/src/ffi/bindings.g.dart';
import 'package:ghostty_dart/src/grid/grid_enums.dart';
import 'package:test/test.dart';

import '../support/terminal_support.dart';
import 'grid_test_support.dart';

void main() {
  group('VtTerminalGrid.gridRef', () {
    test('reads the text and width of cells', () {
      withTerminal(10, 3, (t) {
        writeText(t, 'hi中');
        final h = t.gridRef(const GridPoint.active(0, 0))!;
        expect(h.cell.codepoint, 'h'.codeUnitAt(0));
        expect(h.cell.hasText, isTrue);
        expect(h.cell.width, CellWidth.narrow);
        expect(h.text, 'h');
        expect(h.codepoints, ['h'.codeUnitAt(0)]);
        final wide = t.gridRef(const GridPoint.active(2, 0))!;
        expect(wide.cell.width, CellWidth.wide);
        expect(wide.text, '中');
        final tail = t.gridRef(const GridPoint.active(3, 0))!;
        expect(tail.cell.width, CellWidth.spacerTail);
        expect(tail.text, '');
        final empty = t.gridRef(const GridPoint.active(9, 2))!;
        expect(empty.cell, const GridCell());
        expect(empty.cell.hasText, isFalse);
        expect(empty.codepoints, isEmpty);
        expect(empty.text, '');
      });
    });

    test('returns null outside the coordinate space', () {
      withTerminal(10, 3, (t) {
        expect(t.gridRef(const GridPoint.active(9, 2)), isNotNull);
        expect(t.gridRef(const GridPoint.active(10, 0)), isNull);
        expect(t.gridRef(const GridPoint.active(0, 3)), isNull);
        expect(t.gridRef(const GridPoint.viewport(0, 3)), isNull);
        expect(t.gridRef(const GridPoint.screen(0, 3)), isNull);
        expect(t.gridRef(const GridPoint.history(0, 3)), isNull);
        expect(t.gridRef(const GridPoint.active(0xFFFF, 0xFFFFFFFF)), isNull);
      });
    });

    test('rejects an unknown point space', () {
      withTerminal(10, 3, (t) {
        expect(
          () => t.gridRef(const GridPoint(PointSpace.unknown, 0, 0)),
          throwsArgumentError,
        );
        expect(
          () => t.trackGridRef(const GridPoint(PointSpace.unknown, 0, 0)),
          throwsArgumentError,
        );
      });
    });

    test('reads multi-codepoint grapheme clusters', () {
      withTerminal(10, 3, (t) {
        writeText(t, 'éx');
        final ref = t.gridRef(const GridPoint.active(0, 0))!;
        expect(ref.cell.hasGrapheme, isTrue);
        expect(ref.cell.codepoint, 'e'.codeUnitAt(0));
        expect(ref.codepoints, [0x65, 0x301]);
        expect(ref.text, 'é');
        expect(ref.row.hasGraphemes, isTrue);
        expect(t.gridRef(const GridPoint.active(1, 0))!.text, 'x');
      });
    });

    test('reads clusters longer than the initial buffer', () {
      withTerminal(10, 3, (t) {
        // A family emoji (7 codepoints) plus combining marks: more than
        // the 8 codepoints the first call asks for.
        final cluster = 'a${'́̂̃̄' * 4}';
        writeText(t, cluster);
        final ref = t.gridRef(const GridPoint.active(0, 0))!;
        expect(ref.codepoints, cluster.runes.toList());
        expect(ref.text, cluster);
        expect(ref.codepoints, isA<List<int>>());
        expect(() => ref.codepoints.add(1), throwsUnsupportedError);
      });
    });

    test('reads emoji with modifiers', () {
      withTerminal(10, 3, (t) {
        writeText(t, '\x1b[?2027h👍🏽!');
        final ref = t.gridRef(const GridPoint.active(0, 0))!;
        expect(ref.text, '👍🏽');
        expect(ref.cell.width, CellWidth.wide);
        expect(lineAt(t, PointSpace.active, 0), '👍🏽!');
      });
    });

    test('reads the style', () {
      withTerminal(10, 3, (t) {
        writeText(t, '\x1b[1;3;31;48;2;1;2;3mA\x1b[0mB');
        final a = t.gridRef(const GridPoint.active(0, 0))!;
        expect(a.cell.hasStyling, isTrue);
        expect(
          a.style,
          const CellStyle(
            bold: true,
            italic: true,
            foreground: PaletteColor.red,
            background: RgbColor(1, 2, 3),
          ),
        );
        expect(a.background, const RgbColor(1, 2, 3));
        expect(a.row.hasStyling, isTrue);
        final b = t.gridRef(const GridPoint.active(1, 0))!;
        expect(b.cell.hasStyling, isFalse);
        expect(b.style.isDefault, isTrue);
        expect(b.background, const DefaultColor());
      });
    });

    test('reads the background of colour-only cells', () {
      withTerminal(10, 3, (t) {
        writeText(t, '\x1b[44m\x1b[2K\r\n\x1b[48;2;10;20;30m\x1b[2K');
        final palette = t.gridRef(const GridPoint.active(5, 0))!;
        expect(palette.cell.hasText, isFalse);
        expect(palette.cell.backgroundColor, PaletteColor.blue);
        expect(palette.background, PaletteColor.blue);
        final rgb = t.gridRef(const GridPoint.active(0, 1))!;
        expect(rgb.cell.backgroundColor, const RgbColor(10, 20, 30));
        expect(rgb.background, const RgbColor(10, 20, 30));
        expect(
          t.gridRef(const GridPoint.active(0, 2))!.cell.backgroundColor,
          isNull,
        );
      });
    });

    test('reads OSC 8 hyperlinks', () {
      withTerminal(20, 3, (t) {
        writeText(t, 'a\x1b]8;;https://example.com/ü\x1b\\link\x1b]8;;\x1b\\b');
        final plain = t.gridRef(const GridPoint.active(0, 0))!;
        expect(plain.cell.hasHyperlink, isFalse);
        expect(plain.hyperlinkUri, isNull);
        for (var x = 1; x <= 4; x++) {
          final ref = t.gridRef(GridPoint.active(x, 0))!;
          expect(ref.cell.hasHyperlink, isTrue, reason: 'x=$x');
          expect(ref.hyperlinkUri, 'https://example.com/ü');
        }
        expect(t.gridRef(const GridPoint.active(5, 0))!.hyperlinkUri, isNull);
        expect(plain.row.hasHyperlinks, isTrue);
      });
    });

    test('reads protected cells', () {
      withTerminal(20, 3, (t) {
        writeText(t, '\x1b[1"qP\x1b[0"qx');
        expect(
          t.gridRef(const GridPoint.active(0, 0))!.cell.isProtected,
          isTrue,
        );
        expect(
          t.gridRef(const GridPoint.active(1, 0))!.cell.isProtected,
          isFalse,
        );
      });
    });

    test('reads semantic content and prompt rows (OSC 133)', () {
      withTerminal(20, 3, (t) {
        writeText(t, '\x1b]133;A\x07\$ \x1b]133;B\x07ls');
        final prompt = t.gridRef(const GridPoint.active(0, 0))!;
        expect(prompt.cell.semanticContent, CellSemanticContent.prompt);
        expect(
          t.gridRef(const GridPoint.active(2, 0))!.cell.semanticContent,
          CellSemanticContent.input,
        );
        expect(prompt.row.semanticPrompt, RowSemanticPrompt.prompt);
        expect(
          t.gridRef(const GridPoint.active(0, 1))!.row.semanticPrompt,
          RowSemanticPrompt.none,
        );
      });
    });
  });

  group('GridRef.row', () {
    test('reports soft wraps', () {
      withTerminal(5, 3, (t) {
        writeText(t, 'abcdefg\r\nxy');
        final first = t.gridRef(const GridPoint.active(0, 0))!.row;
        expect(first.isWrapped, isTrue);
        expect(first.isWrapContinuation, isFalse);
        final second = t.gridRef(const GridPoint.active(4, 1))!.row;
        expect(second.isWrapped, isFalse);
        expect(second.isWrapContinuation, isTrue);
        final third = t.gridRef(const GridPoint.active(0, 2))!.row;
        expect(third, isNot(first));
        expect(third.isWrapped || third.isWrapContinuation, isFalse);
        expect(third.hasGraphemes || third.hasKittyVirtualPlaceholder, isFalse);
      });
    });

    test('reports dirty rows', () {
      withTerminal(5, 3, (t) {
        writeText(t, 'a');
        expect(t.gridRef(const GridPoint.active(0, 0))!.row.isDirty, isTrue);
        final state = RenderState()..update(t);
        try {
          for (final row in state.allRows) {
            row.isDirty = false;
          }
          state.markClean();
          // A render state update clears the terminal's row dirty flags.
          expect(t.gridRef(const GridPoint.active(0, 0))!.row.isDirty, isFalse);
        } finally {
          state.dispose();
        }
      });
    });
  });

  group('coordinate spaces', () {
    test('reads the scrollback by screen and history points', () {
      withTerminal(10, 3, (t) {
        writeText(t, [for (var i = 0; i < 8; i++) 'line$i'].join('\r\n'));
        expect(t.scrollbackRows, 5);
        expect(lineAt(t, PointSpace.screen, 0), 'line0');
        expect(lineAt(t, PointSpace.history, 4), 'line4');
        // libghostty-vt 1.0.0 counts history points like screen points and
        // lets them run on into the active area.
        expect(lineAt(t, PointSpace.history, 5), 'line5');
        expect(t.gridRef(const GridPoint.history(0, 8)), isNull);
        expect(lineAt(t, PointSpace.active, 0), 'line5');
        expect(lineAt(t, PointSpace.screen, 7), 'line7');
        expect(t.gridRef(const GridPoint.screen(0, 8)), isNull);
      });
    });

    test('pointIn converts between spaces', () {
      withTerminal(10, 3, (t) {
        writeText(t, [for (var i = 0; i < 8; i++) 'line$i'].join('\r\n'));
        final old = t.gridRef(const GridPoint.screen(2, 1))!;
        expect(old.pointIn(PointSpace.screen), const GridPoint.screen(2, 1));
        expect(old.pointIn(PointSpace.history), const GridPoint.history(2, 1));
        expect(old.pointIn(PointSpace.active), isNull);
        expect(old.pointIn(PointSpace.viewport), isNull);
        final active = t.gridRef(const GridPoint.active(3, 2))!;
        expect(active.pointIn(PointSpace.screen), const GridPoint.screen(3, 7));
        expect(
          active.pointIn(PointSpace.viewport),
          const GridPoint.viewport(3, 2),
        );
        // 1.0.0 also gives active cells a history position (see above).
        expect(
          active.pointIn(PointSpace.history),
          const GridPoint.history(3, 7),
        );
        expect(() => active.pointIn(PointSpace.unknown), throwsArgumentError);
      });
    });

    test('viewport points follow viewport scrolling', () {
      withTerminal(10, 3, (t) {
        writeText(t, [for (var i = 0; i < 8; i++) 'line$i'].join('\r\n'));
        t.scrollViewport(const ScrollToTop());
        expect(lineAt(t, PointSpace.viewport, 0), 'line0');
        expect(lineAt(t, PointSpace.active, 0), 'line5');
        final top = t.gridRef(const GridPoint.viewport(0, 0))!;
        expect(top.pointIn(PointSpace.screen), const GridPoint.screen(0, 0));
      });
    });

    test('reads the alternate screen while it is active', () {
      withTerminal(10, 3, (t) {
        writeText(t, 'primary\x1b[?1049h\x1b[Halt');
        expect(t.activeScreen, TerminalScreen.alternate);
        expect(lineAt(t, PointSpace.active, 0), 'alt');
        writeText(t, '\x1b[?1049l');
        expect(lineAt(t, PointSpace.active, 0), 'primary');
      });
    });

    test('reads after a resize reflows the text', () {
      withTerminal(10, 3, (t) {
        writeText(t, 'abcdefgh');
        t.resize(4, 3);
        expect(lineAt(t, PointSpace.active, 0), 'abcd');
        expect(lineAt(t, PointSpace.active, 1), 'efgh');
        expect(t.gridRef(const GridPoint.active(0, 0))!.row.isWrapped, isTrue);
        expect(t.gridRef(const GridPoint.active(4, 0)), isNull);
      });
    });
  });

  group('borrowed lifetime', () {
    test('a write invalidates the reference', () {
      withTerminal(10, 3, (t) {
        final ref = t.gridRef(const GridPoint.active(0, 0))!;
        expect(ref.isValid, isTrue);
        expect(ref.toString(), 'GridRef(valid)');
        writeText(t, 'x');
        expect(ref.isValid, isFalse);
        expect(ref.toString(), 'GridRef(stale)');
        final stale = throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'GridRef is no longer valid: the terminal changed',
          ),
        );
        expect(() => ref.cell, stale);
        expect(() => ref.row, stale);
        expect(() => ref.style, stale);
        expect(() => ref.background, stale);
        expect(() => ref.codepoints, stale);
        expect(() => ref.text, stale);
        expect(() => ref.hyperlinkUri, stale);
        expect(() => ref.pointIn(PointSpace.active), stale);
      });
    });

    test('reads do not invalidate it', () {
      withTerminal(10, 3, (t) {
        writeText(t, 'abc');
        final ref = t.gridRef(const GridPoint.active(1, 0))!;
        t.gridRef(const GridPoint.active(2, 0))!.cell;
        expect(t.cursorX, 3);
        expect(ref.isValid, isTrue);
        expect(ref.text, 'b');
      });
    });

    test('disposing the terminal invalidates it', () {
      final t = VtTerminal(cols: 10, rows: 3);
      final ref = t.gridRef(const GridPoint.active(0, 0))!;
      t.dispose();
      expect(ref.isValid, isFalse);
      expect(
        () => ref.cell,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('disposed'),
          ),
        ),
      );
      expect(() => t.gridRef(const GridPoint.active(0, 0)), throwsStateError);
      expect(
        () => t.trackGridRef(const GridPoint.active(0, 0)),
        throwsStateError,
      );
    });

    test('is not usable inside a callback of the terminal', () {
      withTerminal(10, 3, (t) {
        final ref = t.gridRef(const GridPoint.active(0, 0))!;
        final tracked = t.trackGridRef(const GridPoint.active(0, 0))!;
        addTearDown(tracked.dispose);
        // Simulates a native call that is running Dart callbacks.
        handleOf<GhosttyTerminalImpl>(t).use((_) {
          expect(ref.isValid, isFalse);
          expect(() => ref.cell, throwsStateError);
          expect(
            () => t.gridRef(const GridPoint.active(0, 0)),
            throwsStateError,
          );
          expect(
            () => t.trackGridRef(const GridPoint.active(0, 0)),
            throwsStateError,
          );
          expect(() => tracked.hasValue, throwsStateError);
          expect(() => tracked.snapshot(), throwsStateError);
          expect(() => tracked.pointIn(PointSpace.active), throwsStateError);
          expect(
            () => tracked.moveTo(const GridPoint.active(0, 0)),
            throwsStateError,
          );
        });
        expect(ref.isValid, isTrue);
        expect(tracked.hasValue, isTrue);
      });
    });
  });

  group('cell decoding matches ghostty_cell_get', () {
    test('for varied content', () {
      withTerminal(16, 6, (t) {
        writeText(
          t,
          'a\x1b[1;31mb\x1b[0m中é\x1b[44m\x1b[K\r\n'
          '\x1b[48;2;9;8;7m\x1b[K\x1b[0m\x1b]8;;u\x1b\\L\x1b]8;;\x1b\\'
          '\x1b[1"qP\x1b[0"q\r\n\x1b]133;A\x07\$ \x1b]133;B\x07in',
        );
        for (var y = 0; y < 6; y++) {
          for (var x = 0; x < 16; x++) {
            final ref = t.gridRef(GridPoint.active(x, y))!;
            expect(ref.cell, _oracleCell(t, x, y), reason: '($x, $y)');
          }
        }
      });
    });
  });

  group('value types', () {
    test('GridCell equality, hash and toString', () {
      const a = GridCell(codepoint: 0x41, hasStyling: true);
      expect(a, const GridCell(codepoint: 0x41, hasStyling: true));
      expect(
        a.hashCode,
        const GridCell(codepoint: 0x41, hasStyling: true).hashCode,
      );
      expect(a, isNot(const GridCell(codepoint: 0x41)));
      expect(a.toString(), 'GridCell(U+0041, CellWidth.narrow, styled)');
      expect(
        const GridCell(backgroundColor: PaletteColor.red).toString(),
        contains('background'),
      );
    });

    test('GridRow equality, hash and toString', () {
      const a = GridRow(isWrapped: true, isDirty: true);
      expect(a, const GridRow(isWrapped: true, isDirty: true));
      expect(
        a.hashCode,
        const GridRow(isWrapped: true, isDirty: true).hashCode,
      );
      expect(a, isNot(const GridRow(isWrapped: true)));
      expect(a.toString(), 'GridRow(wrapped, dirty)');
      expect(const GridRow().toString(), 'GridRow()');
    });

    test('RowSemanticPrompt codec matches the bindings', () {
      final expected = {
        RowSemanticPrompt.none:
            GhosttyRowSemanticPrompt.GHOSTTY_ROW_SEMANTIC_NONE,
        RowSemanticPrompt.prompt:
            GhosttyRowSemanticPrompt.GHOSTTY_ROW_SEMANTIC_PROMPT,
        RowSemanticPrompt.promptContinuation:
            GhosttyRowSemanticPrompt.GHOSTTY_ROW_SEMANTIC_PROMPT_CONTINUATION,
      };
      expect(
        expected.keys.toSet(),
        RowSemanticPrompt.values.toSet()..remove(RowSemanticPrompt.unknown),
      );
      expected.forEach((value, raw) {
        expect(rowSemanticPromptCodec.encode(value), raw);
        expect(rowSemanticPromptCodec.decode(raw), value);
      });
      expect(rowSemanticPromptCodec.decode(9999), RowSemanticPrompt.unknown);
      expect(rowSemanticPromptCodec.decode(-1), RowSemanticPrompt.unknown);
      expect(
        () => rowSemanticPromptCodec.encode(RowSemanticPrompt.unknown),
        throwsArgumentError,
      );
    });
  });
}

/// The cell at active ([x], [y]) read field by field with the raw
/// `ghostty_cell_get`, as an independent oracle for the packed decoding.
GridCell _oracleCell(VtTerminal t, int x, int y) => using((arena) {
  final point = arena<GhosttyPoint>();
  point.ref.tag = GhosttyPointTag.GHOSTTY_POINT_TAG_ACTIVE;
  point.ref.value.coordinate
    ..x = x
    ..y = y;
  final ref = arena<GhosttyGridRef>();
  checkResult(
    ghostty_terminal_grid_ref(
      handleOf<GhosttyTerminalImpl>(t).pointer,
      point.ref,
      ref,
    ),
    'ghostty_terminal_grid_ref',
  );
  final cellOut = arena<Uint64>();
  checkResult(ghostty_grid_ref_cell(ref, cellOut), 'ghostty_grid_ref_cell');
  final cell = cellOut.value;
  final out = arena<Uint64>();
  int read(int key) {
    out.value = 0;
    checkResult(ghostty_cell_get(cell, key, out.cast()), 'ghostty_cell_get');
    return out.value;
  }

  bool flag(int key) => read(key) & 0xFF != 0;
  final tag = read(GhosttyCellData.GHOSTTY_CELL_DATA_CONTENT_TAG) & 0xFFFFFFFF;
  ColorRef? background;
  if (tag == GhosttyCellContentTag.GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE) {
    background = PaletteColor(
      read(GhosttyCellData.GHOSTTY_CELL_DATA_COLOR_PALETTE) & 0xFF,
    );
  } else if (tag == GhosttyCellContentTag.GHOSTTY_CELL_CONTENT_BG_COLOR_RGB) {
    final rgb = read(GhosttyCellData.GHOSTTY_CELL_DATA_COLOR_RGB);
    background = RgbColor(rgb & 0xFF, rgb >> 8 & 0xFF, rgb >> 16 & 0xFF);
  }
  final codepoint =
      read(GhosttyCellData.GHOSTTY_CELL_DATA_CODEPOINT) & 0xFFFFFFFF;
  final hasText = flag(GhosttyCellData.GHOSTTY_CELL_DATA_HAS_TEXT);
  expect(hasText, codepoint != 0, reason: 'HAS_TEXT is codepoint != 0');
  return GridCell(
    codepoint: codepoint,
    hasGrapheme:
        tag == GhosttyCellContentTag.GHOSTTY_CELL_CONTENT_CODEPOINT_GRAPHEME,
    width: CellWidth
        .values[read(GhosttyCellData.GHOSTTY_CELL_DATA_WIDE) & 0xFFFFFFFF],
    hasStyling: flag(GhosttyCellData.GHOSTTY_CELL_DATA_HAS_STYLING),
    hasHyperlink: flag(GhosttyCellData.GHOSTTY_CELL_DATA_HAS_HYPERLINK),
    isProtected: flag(GhosttyCellData.GHOSTTY_CELL_DATA_PROTECTED),
    semanticContent:
        CellSemanticContent.values[read(
              GhosttyCellData.GHOSTTY_CELL_DATA_SEMANTIC_CONTENT,
            ) &
            0xFFFFFFFF],
    backgroundColor: background,
  );
});
