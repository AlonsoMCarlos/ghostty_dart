// Adversarial cross-module tests from the T10 correctness review.

import 'dart:convert';
import 'dart:typed_data';

import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:test/test.dart';

import '../support/terminal_support.dart';

/// Every kind of packed cell: text, wide + spacer, grapheme, palette and
/// RGB colour-only cells, protected, hyperlink and prompt/input content.
const _cells =
    '\x1b[1;31mAB\x1b[0m 漢 👍🏽 é\r\n'
    '\x1b[44m\x1b[K\x1b[0m\r\n'
    '\x1b[48;2;1;2;3m\x1b[K\x1b[0m\r\n'
    '\x1b[1"qprot\x1b[0"q \x1b]8;;https://x.test\x1b\\ln\x1b]8;;\x1b\\\r\n'
    '\x1b]133;A\x07\$ \x1b]133;B\x07cmd\x1b]133;C\x07\r\nout';

void main() {
  test('PackedCell decodes identically for RenderRow and GridRef', () {
    withTerminal(16, 6, (terminal) {
      writeText(terminal, _cells);
      final state = RenderState()..update(terminal);
      try {
        var colourOnly = 0;
        var checked = 0;
        for (final row in state.allRows) {
          final y = row.viewportY;
          for (var x = 0; x < row.length; x++) {
            final ref = terminal.gridRef(GridPoint.viewport(x, y))!;
            final cell = ref.cell;
            final where = '($x, $y)';
            expect(row.codepointAt(x), cell.codepoint, reason: where);
            expect(row.hasGraphemeAt(x), cell.hasGrapheme, reason: where);
            expect(row.widthAt(x), cell.width, reason: where);
            expect(row.hasHyperlinkAt(x), cell.hasHyperlink, reason: where);
            expect(row.isProtectedAt(x), cell.isProtected, reason: where);
            expect(
              row.semanticContentAt(x),
              cell.semanticContent,
              reason: where,
            );
            expect(row.hasStylingAt(x), cell.hasStyling, reason: where);
            expect(
              row.backgroundAt(x),
              cell.backgroundColor ?? ref.style.background,
              reason: where,
            );
            expect(row.textAt(x), ref.text, reason: where);
            if (cell.backgroundColor != null) colourOnly++;
            checked++;
          }
        }
        expect(checked, 16 * 6);
        // Rows 1 and 2 are erased with a palette and an RGB background.
        expect(colourOnly, greaterThanOrEqualTo(32));
        GridCell at(int x, int y) =>
            terminal.gridRef(GridPoint.viewport(x, y))!.cell;
        expect(at(0, 1).backgroundColor, PaletteColor.blue);
        expect(at(15, 2).backgroundColor, const RgbColor(1, 2, 3));
        expect(at(3, 0).width, CellWidth.wide);
        expect(at(4, 0).width, CellWidth.spacerTail);
        expect(at(6, 0).width, CellWidth.wide);
        expect(at(11, 0).hasGrapheme, isTrue);
        expect(at(0, 3).isProtected, isTrue);
        expect(at(5, 3).hasHyperlink, isTrue);
        expect(at(0, 4).semanticContent, CellSemanticContent.prompt);
        expect(at(2, 4).semanticContent, CellSemanticContent.input);
      } finally {
        state.dispose();
      }
    });
  });

  // Acceptance criterion 8, across every owned type in one place: an
  // idempotent dispose(), isDisposed, and StateError on use after dispose.
  group('every owned type: idempotent dispose, then StateError', () {
    final snapshot = () {
      final t = VtTerminal(cols: 8, rows: 2);
      try {
        t.write(utf8.encode('snap'));
        return t.encodeSnapshot();
      } finally {
        t.dispose();
      }
    }();

    void check<T extends Object>(
      String name,
      T Function(VtTerminal terminal) create,
      bool Function(T o) isDisposed,
      void Function(T o) dispose,
      void Function(T o) use,
    ) {
      test(name, () {
        withTerminal(8, 2, (terminal) {
          writeText(terminal, 'ab cd');
          final o = create(terminal);
          expect(isDisposed(o), isFalse);
          use(o);
          dispose(o);
          dispose(o);
          expect(isDisposed(o), isTrue);
          expect(() => use(o), throwsStateError);
        });
      });
    }

    check<VtTerminal>(
      'VtTerminal',
      (_) => VtTerminal(cols: 4, rows: 2),
      (o) => o.isDisposed,
      (o) => o.dispose(),
      (o) => o.write(Uint8List(1)),
    );
    check<RenderState>(
      'RenderState',
      (_) => RenderState(),
      (o) => o.isDisposed,
      (o) => o.dispose(),
      (o) => o.cols,
    );
    check<KeyEncoder>(
      'KeyEncoder',
      (_) => KeyEncoder(),
      (o) => o.isDisposed,
      (o) => o.dispose(),
      (o) => o.encode(const VtKeyEvent(key: VtKey.enter)),
    );
    check<MouseEncoder>(
      'MouseEncoder',
      (_) => MouseEncoder(),
      (o) => o.isDisposed,
      (o) => o.dispose(),
      (o) => o.resetOptions(),
    );
    check<OscParser>(
      'OscParser',
      (_) => OscParser(),
      (o) => o.isDisposed,
      (o) => o.dispose(),
      (o) => o.reset(),
    );
    check<SgrParser>(
      'SgrParser',
      (_) => SgrParser(),
      (o) => o.isDisposed,
      (o) => o.dispose(),
      (o) => o.parseString('1;31'),
    );
    check<TerminalFormatter>(
      'TerminalFormatter',
      TerminalFormatter.new,
      (o) => o.isDisposed,
      (o) => o.dispose(),
      (o) => o.formatText(),
    );
    check<TerminalSearch>(
      'TerminalSearch',
      (t) => TerminalSearch(t, needle: 'ab'),
      (o) => o.isDisposed,
      (o) => o.dispose(),
      (o) => o.totalMatches,
    );
    check<SelectionGesture>(
      'SelectionGesture',
      SelectionGesture.new,
      (o) => o.isDisposed,
      (o) => o.dispose(),
      (o) => o.clickCount,
    );
    check<TrackedGridRef>(
      'TrackedGridRef',
      (t) => t.trackGridRef(const GridPoint.active(0, 0))!,
      (o) => o.isDisposed,
      (o) => o.dispose(),
      (o) => o.hasValue,
    );
    check<SnapshotDecoder>(
      'SnapshotDecoder',
      (_) => SnapshotDecoder(snapshot),
      (o) => o.isDisposed,
      (o) => o.dispose(),
      (o) => o.sourceOffset,
    );
  });

  test('borrowed views cannot outlive their scope', () {
    withTerminal(8, 2, (terminal) {
      writeText(terminal, 'abc');
      final ref = terminal.gridRef(const GridPoint.active(0, 0))!;
      final selection = terminal.selectAll()!;
      final state = RenderState()..update(terminal);
      try {
        final row = state.allRows.first;
        expect(row.textAt(0), 'a');
        writeText(terminal, 'd');
        expect(() => ref.text, throwsStateError);
        expect(selection.isValid, isFalse);
        state.update(terminal);
        expect(() => row.textAt(0), throwsStateError);
      } finally {
        state.dispose();
      }
    });
  });
}
