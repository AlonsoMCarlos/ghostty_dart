import 'dart:convert';

import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart/src/ffi/bindings.g.dart';
import 'package:ghostty_dart/src/text/text_format.dart';
import 'package:test/test.dart';

import '../support/terminal_support.dart';

void main() {
  group('codecs and values', () {
    test('TextFormat matches the header', () {
      final expected = {
        TextFormat.plain: GhosttyFormatterFormat.GHOSTTY_FORMATTER_FORMAT_PLAIN,
        TextFormat.vt: GhosttyFormatterFormat.GHOSTTY_FORMATTER_FORMAT_VT,
        TextFormat.html: GhosttyFormatterFormat.GHOSTTY_FORMATTER_FORMAT_HTML,
      };
      expect(
        expected.keys.toSet(),
        TextFormat.values.toSet()..remove(TextFormat.unknown),
      );
      expected.forEach((value, raw) {
        expect(textFormatCodec.encode(value), raw);
        expect(textFormatCodec.decode(raw), value);
      });
      expect(textFormatCodec.decode(99), TextFormat.unknown);
      expect(
        () => textFormatCodec.encode(TextFormat.unknown),
        throwsArgumentError,
      );
    });

    test('FormatterExtras bits match the header', () {
      // The header's #defines are not in the generated bindings; these are
      // the documented values (formatter.h, 1u << n).
      expect(FormatterExtras.palette.value, 1 << 0);
      expect(FormatterExtras.charsets.value, 1 << 11);
      expect(FormatterExtras.all.value, 0xFFF);
      expect(
        FormatterExtras.defaults,
        FormatterExtras.palette |
            FormatterExtras.style |
            FormatterExtras.hyperlink,
      );
      final mixed = FormatterExtras.defaults | FormatterExtras.cursor;
      expect(mixed.containsAll(FormatterExtras.cursor), isTrue);
      expect(
        mixed
            .without(FormatterExtras.palette)
            .containsAll(FormatterExtras.palette),
        isFalse,
      );
      expect((mixed & FormatterExtras.cursor), FormatterExtras.cursor);
      expect(FormatterExtras.none.isEmpty, isTrue);
      expect(FormatterExtras.fromValue(0x1000).value, 0x1000);
      expect(
        '${FormatterExtras.cursor | FormatterExtras.pwd}',
        'FormatterExtras(pwd | cursor)',
      );
    });
  });

  group('TerminalFormatter', () {
    test('formats plain text like the raw formatter', () {
      withTerminal(20, 4, (t) {
        writeText(t, 'hello\r\nworld   ');
        final f = TerminalFormatter(t);
        expect(f.formatText(), 'hello\nworld');
        expect(f.formatText(), screenText(t));
        expect(utf8.decode(f.formatBytes()), 'hello\nworld');
        f.dispose();
      });
    });

    test('reads and writes every option', () {
      withTerminal(20, 4, (t) {
        final f = TerminalFormatter(t);
        expect(f.format, TextFormat.plain);
        expect(f.unwrap, isFalse);
        expect(f.trim, isTrue);
        expect(f.extras, FormatterExtras.defaults);
        f
          ..format = TextFormat.html
          ..unwrap = true
          ..trim = false
          ..extras = FormatterExtras.all;
        expect(f.format, TextFormat.html);
        expect(f.unwrap, isTrue);
        expect(f.trim, isFalse);
        expect(f.extras, FormatterExtras.all);

        final g = TerminalFormatter(
          t,
          format: TextFormat.vt,
          unwrap: true,
          trim: false,
          extras: FormatterExtras.none,
        );
        expect(g.format, TextFormat.vt);
        expect(g.unwrap, isTrue);
        expect(g.trim, isFalse);
        expect(g.extras, FormatterExtras.none);
      });
    });

    test('rejects unknown values', () {
      withTerminal(20, 4, (t) {
        final f = TerminalFormatter(t);
        expect(() => f.format = TextFormat.unknown, throwsArgumentError);
        expect(
          () => f.extras = FormatterExtras.fromValue(1 << 20),
          throwsA(
            isA<GhosttyException>().having(
              (e) => e.code,
              'code',
              GhosttyResultCode.invalidValue,
            ),
          ),
        );
        expect(f.extras, FormatterExtras.defaults, reason: 'unchanged');
        expect(
          () => TerminalFormatter(t, format: TextFormat.unknown),
          throwsArgumentError,
        );
      });
    });

    test('VT extras add the cursor position', () {
      withTerminal(20, 3, (t) {
        writeText(t, 'ab\x1b[3;5H');
        final f = TerminalFormatter(t, format: TextFormat.vt);
        final without = f.formatText();
        f.extras = FormatterExtras.defaults | FormatterExtras.cursor;
        final withCursor = f.formatText();
        expect(withCursor.length, greaterThan(without.length));
        expect(withCursor, contains('\x1b[3;5H'));
      });
    });

    test('unwraps soft-wrapped lines', () {
      withTerminal(5, 4, (t) {
        writeText(t, 'abcdefghij\r\nxy');
        final f = TerminalFormatter(t);
        expect(f.formatText(), 'abcde\nfghij\nxy');
        f.unwrap = true;
        expect(f.formatText(), 'abcdefghij\nxy');
      });
    });

    test('trim keeps or drops trailing spaces', () {
      withTerminal(10, 3, (t) {
        writeText(t, 'ab   \x1b[1Cc  ');
        final f = TerminalFormatter(t, trim: false);
        expect(f.formatText(), startsWith('ab    c  '));
        f.trim = true;
        expect(f.formatText(), 'ab    c');
      });
    });

    test('includes the scrollback', () {
      withTerminal(10, 3, (t) {
        writeText(t, [for (var i = 0; i < 8; i++) 'L$i'].join('\r\n'));
        expect(
          TerminalFormatter(t).formatText(),
          [for (var i = 0; i < 8; i++) 'L$i'].join('\n'),
        );
      });
    });

    test('formats Unicode text', () {
      withTerminal(20, 3, (t) {
        writeText(t, 'héllo 中文 👍🏽 é');
        expect(TerminalFormatter(t).formatText(), 'héllo 中文 👍🏽 é');
      });
    });

    test('empty content formats as empty', () {
      withTerminal(10, 3, (t) {
        final f = TerminalFormatter(t);
        expect(f.formatText(), '');
        expect(f.formatBytes(), isEmpty);
      });
    });

    test('formats a selection across the scrollback', () {
      withTerminal(10, 3, (t) {
        writeText(t, [for (var i = 0; i < 8; i++) 'line$i'].join('\r\n'));
        final f = TerminalFormatter(t);
        final selection = t.selectRange(
          const GridPoint.screen(2, 1),
          const GridPoint.screen(3, 6),
        )!;
        expect(
          f.formatText(selection: selection),
          'ne1\nline2\nline3\nline4\nline5\nline',
        );
        // Without a selection the whole screen comes back.
        expect(f.formatText(), startsWith('line0\n'));
      });
    });

    test('formats a rectangular selection', () {
      withTerminal(10, 4, (t) {
        writeText(t, 'abcdef\r\nghijkl\r\nmnopqr');
        final block = t.selectRange(
          const GridPoint.active(1, 0),
          const GridPoint.active(3, 2),
          rectangle: true,
        )!;
        expect(
          TerminalFormatter(t).formatText(selection: block),
          'bcd\nhij\nnop',
        );
      });
    });

    test('formats the terminal selection as Ghostty copies it', () {
      withTerminal(5, 4, (t) {
        writeText(t, 'abcdefghij   \r\nxy');
        t.selection = t.selectAll();
        final f = TerminalFormatter(t, unwrap: true);
        expect(f.formatText(selection: t.selection), 'abcdefghij\nxy');
      });
    });

    test('rejects stale selections and selections of other terminals', () {
      withTerminal(10, 3, (t) {
        writeText(t, 'abc');
        final f = TerminalFormatter(t);
        final selection = t.selectAll()!;
        writeText(t, 'd');
        expect(() => f.formatText(selection: selection), throwsStateError);
        withTerminal(10, 3, (other) {
          writeText(other, 'xyz');
          expect(
            () => f.formatText(selection: other.selectAll()),
            throwsArgumentError,
          );
        });
        expect(
          f.formatText(),
          'abcd',
          reason: 'a failed call leaves no selection',
        );
      });
    });

    test('dispose is idempotent and later use throws', () {
      withTerminal(10, 3, (t) {
        final f = TerminalFormatter(t);
        expect(f.isDisposed, isFalse);
        f
          ..dispose()
          ..dispose();
        expect(f.isDisposed, isTrue);
        expect(f.formatText, throwsStateError);
        expect(() => f.format, throwsStateError);
        expect(() => f.trim = false, throwsStateError);
      });
    });

    test('disposing the terminal disposes the formatter', () {
      final t = VtTerminal(cols: 10, rows: 3);
      final f = TerminalFormatter(t);
      t.dispose();
      expect(f.isDisposed, isTrue);
      expect(f.formatText, throwsStateError);
      expect(() => TerminalFormatter(t), throwsStateError);
    });

    test('cannot format from inside a terminal callback', () {
      withTerminal(10, 3, (t) {
        final f = TerminalFormatter(t);
        Object? error;
        t.onBell = () {
          try {
            f.formatText();
          } catch (e) {
            error = e;
          }
        };
        writeText(t, 'x\x07');
        expect(error, isA<StateError>());
        expect(f.formatText(), 'x');
      });
    });
  });
}
