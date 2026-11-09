// Terminal option setters, checked through the matching getters or through
// observable behaviour.

import 'dart:convert';

import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart/src/core/internal.dart';
import 'package:ghostty_dart/src/ffi/bindings.g.dart';
import 'package:test/test.dart';

import '../support/terminal_support.dart';
import 'pty_capture.dart';

void main() {
  test('title and pwd setters round-trip; empty clears', () {
    withTerminal(20, 5, (terminal) {
      terminal.title = 'mañana ✓';
      expect(terminal.title, 'mañana ✓');
      terminal.title = '';
      expect(terminal.title, '');
      terminal.pwd = '/tmp/x';
      expect(terminal.pwd, '/tmp/x');
      terminal.pwd = '';
      expect(terminal.pwd, '');
    });
  });

  test('setters bump the epoch (borrowed views must be refreshed)', () {
    withTerminal(20, 5, (terminal) {
      final handle = handleOf<GhosttyTerminalImpl>(terminal);
      final before = handle.epoch;
      terminal.title = 'x';
      terminal.setMode(TerminalMode.insert, enabled: true);
      expect(handle.epoch, before + 2);
    });
  });

  test('default colours: set, read back, unset with null', () {
    withTerminal(20, 5, (terminal) {
      terminal
        ..colorForegroundDefault = const RgbColor(10, 20, 30)
        ..colorBackgroundDefault = const RgbColor.fromValue(0x405060)
        ..colorCursorDefault = const RgbColor(255, 255, 0);
      expect(terminal.colorForegroundDefault, const RgbColor(10, 20, 30));
      expect(terminal.colorForeground, const RgbColor(10, 20, 30));
      expect(terminal.colorBackgroundDefault, const RgbColor(0x40, 0x50, 0x60));
      expect(terminal.colorCursor, const RgbColor(255, 255, 0));
      terminal
        ..colorForegroundDefault = null
        ..colorBackgroundDefault = null
        ..colorCursorDefault = null;
      expect(terminal.colorForeground, isNull);
      expect(terminal.colorBackground, isNull);
      expect(terminal.colorCursor, isNull);
    });
  });

  test('default palette: set 256 colours, restore with null', () {
    withTerminal(20, 5, (terminal) {
      final builtIn = terminal.colorPaletteDefault;
      final grey = List.generate(256, (i) => RgbColor(i, i, i));
      terminal.colorPaletteDefault = grey;
      expect(terminal.colorPaletteDefault, grey);
      expect(terminal.colorPalette, grey);
      terminal.colorPaletteDefault = null;
      expect(terminal.colorPaletteDefault, builtIn);
    });
  });

  test('a palette of the wrong length is rejected before any change', () {
    withTerminal(20, 5, (terminal) {
      final before = terminal.colorPaletteDefault;
      for (final length in [0, 255, 257]) {
        expect(
          () => terminal.colorPaletteDefault = List.filled(
            length,
            const RgbColor(1, 1, 1),
          ),
          throwsArgumentError,
          reason: '$length',
        );
      }
      expect(terminal.colorPaletteDefault, before);
    });
  });

  test('setMode changes the current value only; reset restores it', () {
    withTerminal(20, 5, (terminal) {
      terminal.setMode(TerminalMode.bracketedPaste, enabled: true);
      expect(terminal.isModeEnabled(TerminalMode.bracketedPaste), isTrue);
      terminal.reset();
      expect(terminal.isModeEnabled(TerminalMode.bracketedPaste), isFalse);
    });
  });

  test('setModeDefault survives a reset', () {
    withTerminal(20, 5, (terminal) {
      terminal.setModeDefault(TerminalMode.wraparound, enabled: false);
      expect(terminal.isModeEnabled(TerminalMode.wraparound), isFalse);
      writeText(terminal, '\x1b[?7h');
      expect(terminal.isModeEnabled(TerminalMode.wraparound), isTrue);
      terminal.reset();
      expect(terminal.isModeEnabled(TerminalMode.wraparound), isFalse);
    });
  });

  test('setMode/setModeDefault reject unknown modes with invalidValue', () {
    withTerminal(20, 5, (terminal) {
      final invalid = isA<GhosttyException>()
          .having((e) => e.code, 'code', GhosttyResultCode.invalidValue)
          .having((e) => e.operation, 'operation', 'ghostty_terminal_set');
      const unknown = TerminalMode.dec(31999);
      expect(() => terminal.setMode(unknown, enabled: true), throwsA(invalid));
      expect(
        () => terminal.setModeDefault(unknown, enabled: true),
        throwsA(invalid),
      );
      // The alternate screen mirrors other state: no reset default.
      expect(
        () => terminal.setModeDefault(TerminalMode.altScreen, enabled: true),
        throwsA(invalid),
      );
    });
  });

  group('scrollback limits', () {
    test('byte limit: default, unlimited, explicit', () {
      withTerminal(20, 5, (terminal) {
        expect(
          terminal.scrollbackMaxBytes,
          VtTerminal.defaultScrollbackMaxBytes,
        );
        terminal.scrollbackMaxBytes = null;
        expect(terminal.scrollbackMaxBytes, isNull);
        terminal.scrollbackMaxBytes = 1 << 20;
        expect(terminal.scrollbackMaxBytes, 1 << 20);
        expect(() => terminal.scrollbackMaxBytes = -1, throwsRangeError);
      });
    });

    test('a zero byte limit disables and erases scrollback', () {
      withTerminal(10, 3, (terminal) {
        writeText(terminal, List.generate(20, (i) => '$i').join('\r\n'));
        expect(terminal.scrollbackRows, greaterThan(0));
        terminal.scrollbackMaxBytes = 0;
        expect(terminal.scrollbackRows, 0);
        writeText(terminal, '\r\nmore\r\nlines\r\nhere');
        expect(terminal.scrollbackRows, 0);
      });
    });

    test('line limit: unlimited by default, settable, null removes', () {
      withTerminal(20, 5, (terminal) {
        expect(terminal.scrollbackMaxLines, isNull);
        terminal.scrollbackMaxLines = 500;
        expect(terminal.scrollbackMaxLines, 500);
        terminal.scrollbackMaxLines = null;
        expect(terminal.scrollbackMaxLines, isNull);
        expect(() => terminal.scrollbackMaxLines = -5, throwsRangeError);
      });
    });

    test('limits report the primary screen while the alternate is active', () {
      withTerminal(20, 5, (terminal) {
        terminal.scrollbackMaxLines = 123;
        writeText(terminal, '\x1b[?1049h');
        expect(terminal.scrollbackMaxLines, 123);
      });
    });

    test('a lower line limit prunes history (page granularity)', () {
      withTerminal(10, 3, (terminal) {
        terminal.scrollbackMaxBytes = null;
        writeText(terminal, List.generate(20000, (i) => '$i').join('\r\n'));
        final before = terminal.scrollbackRows;
        terminal.scrollbackMaxLines = 10;
        expect(terminal.scrollbackRows, lessThan(before));
      });
    });
  });

  test('continuation limit round-trips; negative throws', () {
    withTerminal(20, 5, (terminal) {
      expect(terminal.continuationMaxBytes, 0);
      terminal.continuationMaxBytes = 64;
      expect(terminal.continuationMaxBytes, 64);
      terminal.continuationMaxBytes = 0;
      expect(terminal.continuationMaxBytes, 0);
      expect(() => terminal.continuationMaxBytes = -1, throwsRangeError);
    });
  });

  test('clipboard write limit: default 64 MiB, unlimited, explicit', () {
    withTerminal(20, 5, (terminal) {
      expect(
        terminal.clipboardWriteMaxBytes,
        VtTerminal.defaultClipboardWriteMaxBytes,
      );
      terminal.clipboardWriteMaxBytes = null;
      expect(terminal.clipboardWriteMaxBytes, isNull);
      terminal.clipboardWriteMaxBytes = 4096;
      expect(terminal.clipboardWriteMaxBytes, 4096);
    });
  });

  test('write-only limits accept values and null, reject negatives', () {
    withTerminal(20, 5, (terminal) {
      terminal
        ..setApcMaxBytes(1024)
        ..setApcMaxBytes(null)
        ..setKittyApcMaxBytes(4096)
        ..setKittyApcMaxBytes(null)
        ..setUnknownSequenceMaxBytes(2048)
        ..setUnknownSequenceMaxBytes(0);
      expect(() => terminal.setApcMaxBytes(-1), throwsRangeError);
      expect(() => terminal.setKittyApcMaxBytes(-1), throwsRangeError);
      expect(() => terminal.setUnknownSequenceMaxBytes(-1), throwsRangeError);
    });
  });

  test('default cursor style is what DECSCUSR 0 restores', () {
    withTerminal(20, 5, (terminal) {
      terminal
        ..setDefaultCursorStyle(VtCursorStyle.bar)
        ..setDefaultCursorBlink(true)
        ..setDefaultCursorStyle(null)
        ..setDefaultCursorBlink(null);
      writeText(terminal, '\x1b[5 q\x1b[0 q');
      expect(
        () => terminal.setDefaultCursorStyle(VtCursorStyle.unknown),
        throwsArgumentError,
      );
    });
  });

  test('title reports are off by default and can be enabled', () {
    withTerminal(20, 5, (terminal) {
      terminal.title = 'secret';
      expect(
        capturePty(terminal, () => writeText(terminal, '\x1b[21t')),
        isEmpty,
      );
      terminal.setTitleReportEnabled(true);
      final reply = capturePty(terminal, () => writeText(terminal, '\x1b[21t'));
      expect(utf8.decode(reply), contains('secret'));
      terminal.setTitleReportEnabled(false);
      expect(
        capturePty(terminal, () => writeText(terminal, '\x1b[21t')),
        isEmpty,
      );
    });
  });

  test('checksum reports are off by default and can be enabled', () {
    withTerminal(20, 5, (terminal) {
      writeText(terminal, 'abc');
      const request = '\x1b[1;1;1;1;5;20*y';
      expect(capturePty(terminal, () => writeText(terminal, request)), isEmpty);
      terminal.setXtChecksumReportEnabled(true);
      final plain = capturePty(terminal, () => writeText(terminal, request));
      expect(utf8.decode(plain), startsWith('\x1bP1!~'));
      terminal.setXtChecksumExtension(1);
      final unnegated = capturePty(
        terminal,
        () => writeText(terminal, request),
      );
      expect(unnegated, isNot(plain));
      expect(() => terminal.setXtChecksumExtension(32), throwsRangeError);
      expect(() => terminal.setXtChecksumExtension(-1), throwsRangeError);
    });
  });

  test('terminfo name is reported to XTGETTCAP TN; length is limited', () {
    withTerminal(20, 5, (terminal) {
      // XTGETTCAP "TN", hex encoded.
      const query = '\x1bP+q544e\x1b\\';
      terminal.setTerminfoName('xterm-ghostty');
      final reply = utf8.decode(
        capturePty(terminal, () => writeText(terminal, query)),
      );
      final hexName = 'xterm-ghostty'.codeUnits
          .map((c) => c.toRadixString(16).padLeft(2, '0'))
          .join();
      expect(reply.toLowerCase(), contains(hexName));
      terminal.setTerminfoName(null);
      terminal.setTerminfoName('x' * VtTerminal.maxTerminfoNameBytes);
      expect(
        () => terminal.setTerminfoName('é' * 65), // 130 UTF-8 bytes
        throwsArgumentError,
      );
    });
  });

  test('glyph protocol and resize-pull-scrollback toggles', () {
    withTerminal(10, 3, (terminal) {
      terminal
        ..setGlyphProtocolEnabled(true)
        ..setGlyphProtocolEnabled(false);
      writeText(terminal, List.generate(6, (i) => '$i').join('\r\n'));
      terminal.setResizePullScrollback(false);
      terminal.resize(10, 6);
      expect(terminal.scrollbackRows, 3, reason: 'no rows pulled back');
      terminal.setResizePullScrollback(true);
    });
  });

  test('resize pulls scrollback back by default', () {
    withTerminal(10, 3, (terminal) {
      writeText(terminal, List.generate(6, (i) => '$i').join('\r\n'));
      expect(terminal.scrollbackRows, 3);
      terminal.resize(10, 6);
      expect(terminal.scrollbackRows, 0);
    });
  });

  group('kitty image options', () {
    final supported = libghosttyVtBuildInfo.supports(VtFeature.kittyGraphics);

    test('storage limit and media round-trip', () {
      withTerminal(20, 5, (terminal) {
        expect(
          terminal.kittyImageStorageLimit,
          VtTerminal.defaultKittyImageStorageLimit,
        );
        terminal.kittyImageStorageLimit = 1234;
        expect(terminal.kittyImageStorageLimit, 1234);
        terminal.kittyImageStorageLimit = 0;
        expect(terminal.kittyImageStorageLimit, 0);
        expect(() => terminal.kittyImageStorageLimit = -1, throwsRangeError);

        expect(terminal.isKittyImageFileMediumEnabled, isFalse);
        terminal.isKittyImageFileMediumEnabled = true;
        expect(terminal.isKittyImageFileMediumEnabled, isTrue);

        expect(terminal.isKittyImageSharedMemoryMediumEnabled, isFalse);
        terminal.isKittyImageSharedMemoryMediumEnabled = true;
        expect(terminal.isKittyImageSharedMemoryMediumEnabled, isTrue);

        expect(terminal.kittyImageTempFileDirectory, isNull);
        terminal.kittyImageTempFileDirectory = '/tmp/kitty';
        expect(terminal.kittyImageTempFileDirectory, '/tmp/kitty');
        terminal.kittyImageTempFileDirectory = '';
        expect(terminal.kittyImageTempFileDirectory, isNull);
      });
    }, skip: supported ? false : 'built without Kitty graphics');

    test('throw UnsupportedError without Kitty graphics', () {
      withTerminal(20, 5, (terminal) {
        expect(() => terminal.kittyImageStorageLimit, throwsUnsupportedError);
      });
    }, skip: supported ? 'built with Kitty graphics' : false);
  });
}
