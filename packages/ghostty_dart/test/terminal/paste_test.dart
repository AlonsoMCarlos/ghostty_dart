// VtTerminal.paste / pasteText over ghostty_terminal_paste.

import 'dart:convert';
import 'dart:typed_data';

import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:test/test.dart';

import '../support/terminal_support.dart';
import 'pty_capture.dart';

void main() {
  test('plain text is written as is', () {
    withTerminal(20, 3, (terminal) {
      late PasteResult result;
      final out = capturePty(terminal, () => result = terminal.pasteText('ls'));
      expect(result, PasteResult.pasted);
      expect(utf8.decode(out), 'ls');
    });
  });

  test('bracketed paste mode frames the text', () {
    withTerminal(20, 3, (terminal) {
      writeText(terminal, '\x1b[?2004h');
      late PasteResult result;
      final out = capturePty(
        terminal,
        () => result = terminal.pasteText('a\nb'),
      );
      expect(result, PasteResult.pasted);
      expect(utf8.decode(out), startsWith('\x1b[200~'));
      expect(utf8.decode(out), endsWith('\x1b[201~'));
    });
  });

  test('unsafe text is rejected unless allowed', () {
    withTerminal(20, 3, (terminal) {
      late PasteResult result;
      var out = capturePty(
        terminal,
        () => result = terminal.pasteText('rm -rf ~\n'),
      );
      expect(result, PasteResult.rejected);
      expect(out, isEmpty);
      out = capturePty(
        terminal,
        () => result = terminal.pasteText('rm -rf ~\n', allowUnsafe: true),
      );
      expect(result, PasteResult.pasted);
      expect(out, isNotEmpty);
    });
  });

  test('empty text and no MIME types paste nothing', () {
    withTerminal(20, 3, (terminal) {
      capturePty(terminal, () {
        expect(terminal.pasteText(''), PasteResult.nothingToPaste);
        expect(
          terminal.paste(mimeTypes: const [], read: (_) => null),
          PasteResult.nothingToPaste,
        );
      });
    });
  });

  test('reads only the first text representation', () {
    withTerminal(20, 3, (terminal) {
      final requested = <String>[];
      final out = capturePty(terminal, () {
        final result = terminal.paste(
          mimeTypes: const ['image/png', 'text/plain', 'text/html'],
          read: (mime) {
            requested.add(mime);
            return Uint8List.fromList(utf8.encode('from $mime'));
          },
        );
        expect(result, PasteResult.pasted);
      });
      expect(requested, ['text/plain']);
      expect(utf8.decode(out), 'from text/plain');
    });
  });

  test('a null read fails with ioError; reader exceptions are rethrown', () {
    withTerminal(20, 3, (terminal) {
      capturePty(terminal, () {
        expect(
          () => terminal.paste(
            mimeTypes: const ['text/plain'],
            read: (_) => null,
          ),
          throwsA(
            isA<GhosttyException>().having(
              (e) => e.code,
              'code',
              GhosttyResultCode.ioError,
            ),
          ),
        );
        expect(
          () => terminal.paste(
            mimeTypes: const ['text/plain'],
            read: (_) => throw const FormatException('boom'),
          ),
          throwsFormatException,
        );
      });
    });
  });

  test('without a write-pty callback the paste is invalid', () {
    withTerminal(20, 3, (terminal) {
      expect(
        () => terminal.pasteText('x'),
        throwsA(
          isA<GhosttyException>()
              .having((e) => e.code, 'code', GhosttyResultCode.invalidValue)
              .having(
                (e) => e.operation,
                'operation',
                'ghostty_terminal_paste',
              ),
        ),
      );
    });
  });

  test('large pastes stream completely', () {
    withTerminal(20, 3, (terminal) {
      final text = 'x' * 200000;
      final out = capturePty(terminal, () {
        expect(terminal.pasteText(text), PasteResult.pasted);
      });
      expect(out, hasLength(text.length));
    });
  });

  test('ClipboardLocation.unknown is rejected', () {
    withTerminal(20, 3, (terminal) {
      capturePty(terminal, () {
        expect(
          () => terminal.pasteText('x', location: ClipboardLocation.unknown),
          throwsArgumentError,
        );
        expect(
          terminal.pasteText(
            'x',
            location: ClipboardLocation.primary,
            source: PasteSource.text,
          ),
          PasteResult.pasted,
        );
      });
    });
  });
}
