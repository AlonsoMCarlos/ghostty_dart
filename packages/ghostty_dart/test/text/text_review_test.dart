// Correctness review of TerminalFormatter: VT round-trip fidelity, HTML
// escaping, option edge cases and lifetime.

import 'dart:convert';
import 'dart:typed_data';

import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:test/test.dart';

import '../support/terminal_support.dart';

/// Every cell of the active screen of [t]: its text, style and link.
List<(String, CellStyle, String?)> _cells(VtTerminal t) => [
  for (var y = 0; y < t.rows; y++)
    for (var x = 0; x < t.cols; x++)
      () {
        final ref = t.gridRef(GridPoint.active(x, y))!;
        return (ref.text, ref.style, ref.hyperlinkUri);
      }(),
];

/// Writes the VT output of [source] into a fresh terminal of the same size
/// and returns it (disposed by the test).
VtTerminal _replay(VtTerminal source, {bool unwrap = false}) {
  final bytes = TerminalFormatter(
    source,
    format: TextFormat.vt,
    unwrap: unwrap,
    trim: false,
  ).formatBytes();
  final copy = VtTerminal(cols: source.cols, rows: source.rows);
  addTearDown(copy.dispose);
  copy.write(bytes);
  return copy;
}

const _styled =
    'plain \x1b[1;3;4;9mBIUS\x1b[0m \x1b[38;2;1;2;3;48;5;200mrgb\x1b[0m\r\n'
    '\x1b[4:3;58;2;9;8;7mcurly\x1b[0m \x1b[2;5;7;8mdim\x1b[0m '
    '\x1b]8;;https://x.test/a?b=1&c="d"\x1b\\link\x1b]8;;\x1b\\\r\n'
    '日本 é \x1b[31mred\x1b[39m';

void main() {
  group('VT round trip', () {
    test('recreates every cell: text, style and hyperlink', () {
      withTerminal(40, 4, (t) {
        writeText(t, _styled);
        final copy = _replay(t);
        expect(screenText(copy), screenText(t));
        expect(_cells(copy), _cells(t));
      });
    });

    test('soft-wrapped lines survive when unwrapped', () {
      withTerminal(8, 4, (t) {
        writeText(t, 'abcdefghij\x1b[1mKLMN\x1b[0m\r\nxy');
        final copy = _replay(t, unwrap: true);
        expect(_cells(copy), _cells(t));
        expect(
          copy.gridRef(const GridPoint.active(0, 0))!.row.isWrapped,
          isTrue,
        );
      });
    });

    test('the palette extra restores changed palette colours', () {
      withTerminal(10, 2, (t) {
        writeText(t, '\x1b]4;1;rgb:12/34/56\x1b\\\x1b[31mx');
        final copy = _replay(t);
        expect(
          copy.gridRef(const GridPoint.active(0, 0))!.style.foreground,
          PaletteColor.red,
        );
        expect(
          utf8.decode(
            TerminalFormatter(t, format: TextFormat.vt).formatBytes(),
          ),
          contains('\x1b]4;1;'),
        );
        expect(
          utf8.decode(
            TerminalFormatter(
              t,
              format: TextFormat.vt,
              extras: FormatterExtras.none,
            ).formatBytes(),
          ),
          isNot(contains('\x1b]4;')),
        );
      });
    });

    test('every extra together still recreates the cells', () {
      withTerminal(20, 4, (t) {
        writeText(t, '\x1b[2;3r\x1b[?7l\x1b[?2004h$_styled\x1b[2;4H');
        final bytes = TerminalFormatter(
          t,
          format: TextFormat.vt,
          extras: FormatterExtras.all,
        ).formatBytes();
        withTerminal(20, 4, (copy) {
          copy.write(bytes);
          expect(_cells(copy), _cells(t));
          expect(copy.cursorX, t.cursorX);
          expect(copy.cursorY, t.cursorY);
          expect(
            copy.isModeEnabled(TerminalMode.bracketedPaste),
            t.isModeEnabled(TerminalMode.bracketedPaste),
          );
        });
      });
    });

    test('VT output of a selection contains only the selection', () {
      withTerminal(20, 3, (t) {
        writeText(t, 'ab\x1b[1mcd\x1b[0mef');
        final s = t.selectRange(
          const GridPoint.active(2, 0),
          const GridPoint.active(3, 0),
        )!;
        final vt = TerminalFormatter(
          t,
          format: TextFormat.vt,
        ).formatText(selection: s);
        expect(vt, contains('cd'));
        expect(vt, isNot(contains('ab')));
        expect(vt, isNot(contains('ef')));
      });
    });
  });

  group('HTML', () {
    test('escapes markup characters in text and in link URLs', () {
      withTerminal(60, 3, (t) {
        writeText(
          t,
          '<script>&amp;"\'</script>\r\n'
          '\x1b]8;;https://x.test/?a=<b>&c="d"\x1b\\L\x1b]8;;\x1b\\',
        );
        final html = TerminalFormatter(t, format: TextFormat.html).formatText();
        expect(html, isNot(contains('<script>')));
        expect(html, contains('&lt;script&gt;&amp;amp;'));
        expect(html, isNot(contains('"d"')));
        expect(html, isNot(contains('<b>')));
      });
    });

    test('carries palette and RGB colours', () {
      withTerminal(40, 2, (t) {
        writeText(t, '\x1b[38;2;18;52;86mrgb\x1b[0m \x1b[41mbg\x1b[0m');
        final html = TerminalFormatter(t, format: TextFormat.html).formatText();
        expect(
          html.toLowerCase(),
          anyOf(
            contains('#123456'),
            contains('18, 52, 86'),
            contains('18,52,86'),
          ),
        );
        expect(html, contains('rgb'));
        expect(html, contains('bg'));
      });
    });

    test('escapes a selection of markup', () {
      withTerminal(20, 2, (t) {
        writeText(t, 'x<&>y');
        final s = t.selectRange(
          const GridPoint.active(1, 0),
          const GridPoint.active(3, 0),
        )!;
        final html = TerminalFormatter(
          t,
          format: TextFormat.html,
        ).formatText(selection: s);
        expect(html, contains('&lt;&amp;&gt;'));
        expect(html, isNot(contains('x')));
      });
    });
  });

  group('options', () {
    test('a rejected value keeps the previous one', () {
      withTerminal(10, 2, (t) {
        final f = TerminalFormatter(t)
          ..extras = FormatterExtras.cursor
          ..format = TextFormat.vt;
        expect(
          () => f.extras = const FormatterExtras.fromValue(1 << 12),
          throwsA(isA<GhosttyException>()),
        );
        expect(f.extras, FormatterExtras.cursor);
        expect(() => f.format = TextFormat.unknown, throwsArgumentError);
        expect(f.format, TextFormat.vt);
        expect(
          () => TerminalFormatter(
            t,
            extras: const FormatterExtras.fromValue(1 << 31),
          ),
          throwsA(isA<GhosttyException>()),
        );
      });
    });

    test('a selection never sticks to later calls', () {
      withTerminal(10, 2, (t) {
        writeText(t, 'abcdef');
        final f = TerminalFormatter(t);
        final s = t.selectRange(
          const GridPoint.active(1, 0),
          const GridPoint.active(2, 0),
        )!;
        expect(f.formatText(selection: s), 'bc');
        expect(f.formatText(), 'abcdef');
        writeText(t, 'g');
        expect(() => f.formatText(selection: s), throwsStateError);
        expect(
          f.formatText(),
          'abcdefg',
          reason: 'the failed call left no selection',
        );
      });
    });

    test('large output is complete', () {
      withTerminal(200, 50, (t) {
        t.scrollbackMaxBytes = null;
        final lines = [for (var i = 0; i < 20000; i++) 'line $i ${'x' * 100}'];
        writeText(t, lines.join('\r\n'));
        final text = TerminalFormatter(t).formatText();
        expect(text.split('\n'), lines);
      });
    });

    test('malformed bytes in content become U+FFFD in text', () {
      withTerminal(10, 2, (t) {
        t.write(Uint8List.fromList([0x61, 0xFF, 0x62]));
        final f = TerminalFormatter(t);
        expect(f.formatText(), 'a�b');
        expect(utf8.decode(f.formatBytes()), 'a�b');
      });
    });
  });

  group('lifetime', () {
    test('many formatters of one terminal are freed with it', () {
      final t = VtTerminal(cols: 10, rows: 2);
      final formatters = [for (var i = 0; i < 50; i++) TerminalFormatter(t)];
      formatters.take(25).forEach((f) => f.dispose());
      t.dispose();
      expect(formatters.every((f) => f.isDisposed), isTrue);
      expect(() => formatters.last.trim, throwsStateError);
      expect(() => formatters.last.trim = false, throwsStateError);
    });

    test('a formatter of a disposed terminal cannot be created', () {
      final t = VtTerminal(cols: 10, rows: 2)..dispose();
      expect(() => TerminalFormatter(t), throwsStateError);
    });
  });
}
