// Adversarial tests from the T02 correctness review: callbacks that mutate
// the terminal, stoppable-write offsets, string/limit edge cases and the
// library's documented defaults.

import 'dart:convert';
import 'dart:typed_data';

import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart/src/core/internal.dart';
import 'package:ghostty_dart/src/ffi/bindings.g.dart';
import 'package:test/test.dart';

import '../support/terminal_support.dart';
import 'pty_capture.dart';

Uint8List _bytes(String text) => utf8.encode(text);

void main() {
  group('mutations from inside a callback', () {
    test('a resize inside a resize callback keeps the inner cell size', () {
      withTerminal(10, 3, (terminal) {
        terminal.resize(10, 3, cellWidthPx: 5, cellHeightPx: 9);
        // Mode 2048: every resize writes an in-band size report to the pty.
        writeText(terminal, '\x1b[?2048h');
        var nested = false;
        capturePty(
          terminal,
          () => terminal.resize(20, 3, cellWidthPx: 6, cellHeightPx: 10),
          onWrite: () {
            if (nested) return;
            nested = true;
            terminal.resize(30, 4, cellWidthPx: 7, cellHeightPx: 11);
          },
        );
        expect(nested, isTrue);
        expect((terminal.cols, terminal.rows), (30, 4));
        expect((terminal.widthPx, terminal.heightPx), (30 * 7, 4 * 11));
        // Omitted pixel sizes keep the cell size the library holds now.
        terminal.resize(25, 5);
        expect((terminal.widthPx, terminal.heightPx), (25 * 7, 5 * 11));
      });
    });

    test('reset and resize inside a write callback; the rest is processed', () {
      withTerminal(20, 3, (terminal) {
        writeText(terminal, 'old text');
        terminal.title = 'old';
        var calls = 0;
        capturePty(
          terminal,
          () => writeText(terminal, '\x1b[6nabc'),
          onWrite: () {
            calls++;
            terminal.reset();
            terminal.resize(15, 4);
          },
        );
        expect(calls, 1);
        expect(screenText(terminal), 'abc');
        expect(terminal.title, '');
        expect((terminal.cols, terminal.rows), (15, 4));
      });
    });

    test('dispose inside a write callback defers the free', () {
      final terminal = VtTerminal(cols: 20, rows: 3);
      capturePty(
        terminal,
        () => writeText(terminal, '\x1b[6nabc'),
        onWrite: terminal.dispose,
      );
      expect(terminal.isDisposed, isTrue);
      expect(() => terminal.cursorX, throwsStateError);
      terminal.dispose();
    });
  });

  group('writeUntil offsets', () {
    test('consumed is relative to start; end limits the input', () {
      withTerminal(20, 3, (terminal) {
        final bytes = _bytes('xx\x1b]0;t\x07yy');
        // Only "xx\x1b]" (start 0, end 4): stops after the introducer.
        final first = terminal.writeUntil(
          bytes,
          WriteBoundaries.oscStart | WriteBoundaries.oscEnd,
          end: 4,
        );
        expect(first.consumed, 4);
        expect(first.reached, WriteBoundaries.oscStart);
        // From 4 to the end: stops after BEL at index 7 (3 bytes from 4).
        final second = terminal.writeUntil(
          bytes,
          WriteBoundaries.oscEnd,
          start: 4,
        );
        expect(second.consumed, 4);
        expect(second.end, ControlStringEnd.bel);
        expect(terminal.title, 't');
        final rest = terminal.writeUntil(
          bytes,
          WriteBoundaries.oscStart,
          start: 4 + second.consumed,
        );
        expect(rest.reachedBoundary, isFalse);
        expect(rest.consumed, 2);
        expect(screenText(terminal), 'xxyy');
      });
    });

    test(
      'an empty range at ground stops at ground having consumed nothing',
      () {
        withTerminal(10, 2, (terminal) {
          final stop = terminal.writeUntil(
            _bytes('abc'),
            WriteBoundaries.ground,
            start: 1,
            end: 1,
          );
          expect(stop.consumed, 0);
          expect(stop.reached, WriteBoundaries.ground);
          expect(screenText(terminal), '');
        });
      },
    );

    test('an out-of-range window throws before writing', () {
      withTerminal(10, 2, (terminal) {
        final epoch = handleOf<GhosttyTerminalImpl>(terminal).epoch;
        expect(
          () => terminal.writeUntil(
            _bytes('abc'),
            WriteBoundaries.ground,
            start: 2,
            end: 1,
          ),
          throwsRangeError,
        );
        expect(
          () => terminal.writeUntil(
            _bytes('abc'),
            WriteBoundaries.ground,
            end: 4,
          ),
          throwsRangeError,
        );
        expect(handleOf<GhosttyTerminalImpl>(terminal).epoch, epoch);
      });
    });

    test('writeWithStops offsets point just after each stopping byte', () {
      withTerminal(40, 3, (terminal) {
        final bytes = _bytes('a\x1b]2;one\x07b\x1b]2;two\x1b\\c');
        final offsets = <int>[];
        final written = terminal.writeWithStops(
          bytes,
          WriteBoundaries.oscStart | WriteBoundaries.oscEnd,
          (stop, offset) {
            offsets.add(offset);
            return true;
          },
        );
        expect(written, bytes.length);
        // ']' at 2, BEL at 8, ']' at 11, ESC of ST at 17.
        expect(offsets, [3, 9, 12, 18]);
        expect(terminal.title, 'two');
        expect(screenText(terminal), 'abc');
      });
    });
  });

  group('string options', () {
    test('Unicode titles and directories round-trip byte-exact', () {
      withTerminal(10, 2, (terminal) {
        const title = 'título ✓ 🚀 日本';
        terminal.title = title;
        expect(terminal.title, title);
        terminal.pwd = '/tmp/ñ 🚀';
        expect(terminal.pwd, '/tmp/ñ 🚀');
        // OSC replaces a programmatic title.
        writeText(terminal, '\x1b]2;from osc\x07');
        expect(terminal.title, 'from osc');
      });
    });

    test('the terminfo limit counts UTF-8 bytes, not characters', () {
      withTerminal(10, 2, (terminal) {
        terminal.setTerminfoName('é' * 64); // 128 bytes: allowed
        expect(
          () => terminal.setTerminfoName('é' * 64 + 'x'),
          throwsArgumentError,
        );
        terminal.setTerminfoName(null);
        terminal.setTerminfoName('');
      });
    });

    test('checksum extension bits outside 0-31 are rejected', () {
      withTerminal(10, 2, (terminal) {
        terminal.setXtChecksumExtension(31);
        terminal.setXtChecksumExtension(0);
        expect(() => terminal.setXtChecksumExtension(32), throwsRangeError);
        expect(() => terminal.setXtChecksumExtension(-1), throwsRangeError);
      });
    });
  });

  group('limits', () {
    test('SIZE_MAX (null) is unlimited, not an overflow, for every limit', () {
      withTerminal(10, 3, (terminal) {
        terminal.scrollbackMaxBytes = null;
        terminal.scrollbackMaxLines = null;
        terminal.clipboardWriteMaxBytes = null;
        expect(terminal.scrollbackMaxBytes, isNull);
        expect(terminal.scrollbackMaxLines, isNull);
        expect(terminal.clipboardWriteMaxBytes, isNull);
        // Unlimited history really keeps everything.
        writeText(terminal, List.generate(2000, (i) => '$i').join('\r\n'));
        expect(terminal.scrollbackRows, 2000 - 3);
        expect(terminal.totalRows, 2000);
      });
    });

    test('defaults match the documented library defaults', () {
      withTerminal(10, 3, (terminal) {
        expect(terminal.scrollbackMaxBytes, 10000);
        expect(terminal.scrollbackMaxLines, isNull);
        expect(terminal.clipboardWriteMaxBytes, 64 * 1024 * 1024);
        expect(terminal.continuationMaxBytes, 0);
        if (libghosttyVtBuildInfo.supports(VtFeature.kittyGraphics)) {
          expect(terminal.kittyImageStorageLimit, 10 * 1000 * 1000);
          expect(terminal.isKittyImageFileMediumEnabled, isFalse);
          expect(terminal.isKittyImageSharedMemoryMediumEnabled, isFalse);
          expect(terminal.kittyImageTempFileDirectory, isNull);
        }
      });
    });
  });

  group('colours', () {
    test('OSC 4 changes the effective palette, not the default one', () {
      withTerminal(10, 2, (terminal) {
        final custom = List.generate(256, (i) => RgbColor(i, 255 - i, 7));
        terminal.colorPaletteDefault = custom;
        writeText(terminal, '\x1b]4;1;rgb:12/34/56\x07');
        expect(terminal.colorPalette[1], const RgbColor(0x12, 0x34, 0x56));
        expect(terminal.colorPalette[2], custom[2]);
        expect(terminal.colorPaletteDefault, custom);
        // The last entry is index 255 (an off-by-one would lose it).
        expect(terminal.colorPalette[255], const RgbColor(255, 0, 7));
      });
    });
  });

  group('paste', () {
    test('the first text type is read even after non-text types', () {
      withTerminal(20, 3, (terminal) {
        final requested = <String>[];
        final out = capturePty(terminal, () {
          final result = terminal.paste(
            mimeTypes: const ['image/png', 'text/plain;charset=utf-8'],
            read: (type) {
              requested.add(type);
              return _bytes('héllo 🚀');
            },
          );
          expect(result, PasteResult.pasted);
        });
        expect(requested, ['text/plain;charset=utf-8']);
        expect(utf8.decode(out), 'héllo 🚀');
      });
    });

    test('pasting after dispose throws StateError and never reads', () {
      final terminal = VtTerminal(cols: 10, rows: 2)..dispose();
      var read = false;
      expect(
        () => terminal.paste(
          mimeTypes: const ['text/plain'],
          read: (_) {
            read = true;
            return Uint8List(0);
          },
        ),
        throwsStateError,
      );
      expect(read, isFalse);
    });
  });
}
