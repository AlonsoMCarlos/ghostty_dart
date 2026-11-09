// Terminal state getters driven by real VT sequences, lifecycle and
// reentrancy.

import 'dart:convert';
import 'dart:typed_data';

import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart/src/core/internal.dart';
import 'package:ghostty_dart/src/ffi/bindings.g.dart';
import 'package:test/test.dart';

import '../support/terminal_support.dart';
import 'pty_capture.dart';

void main() {
  group('cursor', () {
    test('position follows printing and CUP', () {
      withTerminal(20, 5, (terminal) {
        expect((terminal.cursorX, terminal.cursorY), (0, 0));
        writeText(terminal, 'hello');
        expect((terminal.cursorX, terminal.cursorY), (5, 0));
        writeText(terminal, '\x1b[3;7H');
        expect((terminal.cursorX, terminal.cursorY), (6, 2));
      });
    });

    test('visibility follows DECTCEM (mode 25)', () {
      withTerminal(20, 5, (terminal) {
        expect(terminal.isCursorVisible, isTrue);
        writeText(terminal, '\x1b[?25l');
        expect(terminal.isCursorVisible, isFalse);
        writeText(terminal, '\x1b[?25h');
        expect(terminal.isCursorVisible, isTrue);
      });
    });

    test('pending wrap is set after printing the last column', () {
      withTerminal(5, 3, (terminal) {
        writeText(terminal, 'abcd');
        expect(terminal.hasCursorPendingWrap, isFalse);
        writeText(terminal, 'e');
        expect(terminal.hasCursorPendingWrap, isTrue);
        expect(terminal.cursorX, 4);
        writeText(terminal, 'f');
        expect(terminal.hasCursorPendingWrap, isFalse);
        expect((terminal.cursorX, terminal.cursorY), (1, 1));
      });
    });

    test('SGR style of the cursor', () {
      withTerminal(20, 5, (terminal) {
        expect(terminal.cursorSgrStyle.isDefault, isTrue);
        writeText(terminal, '\x1b[1;3;31;48;2;1;2;3;4:3m');
        final style = terminal.cursorSgrStyle;
        expect(style.bold, isTrue);
        expect(style.italic, isTrue);
        expect(style.foreground, PaletteColor.red);
        expect(style.background, const RgbColor(1, 2, 3));
        expect(style.underline, UnderlineStyle.curly);
        writeText(terminal, '\x1b[0m');
        expect(terminal.cursorSgrStyle, const CellStyle());
      });
    });

    test('cursor snapshot matches the individual getters', () {
      withTerminal(10, 4, (terminal) {
        writeText(terminal, '\x1b[2;3H\x1b[?25l\x1b[1m');
        final cursor = terminal.cursor;
        expect(cursor.x, terminal.cursorX);
        expect(cursor.y, terminal.cursorY);
        expect((cursor.x, cursor.y), (2, 1));
        expect(cursor.isVisible, isFalse);
        expect(cursor.hasPendingWrap, isFalse);
        expect(cursor.style, terminal.cursorSgrStyle);
        expect(cursor.style.bold, isTrue);
        writeText(terminal, '\x1b[1;10Hx');
        expect(terminal.cursor.hasPendingWrap, isTrue);
      });
    });

    test('at-prompt follows OSC 133 markers', () {
      withTerminal(20, 5, (terminal) {
        expect(terminal.isCursorAtPrompt, isFalse);
        writeText(terminal, '\x1b]133;A\x07\$ ');
        expect(terminal.isCursorAtPrompt, isTrue);
        writeText(terminal, '\x1b]133;C\x07\r\noutput');
        expect(terminal.isCursorAtPrompt, isFalse);
      });
    });
  });

  group('screen', () {
    test('active screen follows the alternate screen mode 1049', () {
      withTerminal(20, 5, (terminal) {
        writeText(terminal, 'primary');
        expect(terminal.activeScreen, TerminalScreen.primary);
        writeText(terminal, '\x1b[?1049h');
        expect(terminal.activeScreen, TerminalScreen.alternate);
        expect(screenText(terminal), '');
        writeText(terminal, '\x1b[?1049l');
        expect(terminal.activeScreen, TerminalScreen.primary);
        expect(screenText(terminal), 'primary');
      });
    });

    test('title from OSC 0 and OSC 2, empty when unset', () {
      withTerminal(20, 5, (terminal) {
        expect(terminal.title, '');
        writeText(terminal, '\x1b]0;first\x07');
        expect(terminal.title, 'first');
        writeText(terminal, '\x1b]2;sëcond ✓\x1b\\');
        expect(terminal.title, 'sëcond ✓');
      });
    });

    test('pwd from OSC 7', () {
      withTerminal(20, 5, (terminal) {
        expect(terminal.pwd, '');
        writeText(terminal, '\x1b]7;file://localhost/home/user\x07');
        expect(terminal.pwd, contains('/home/user'));
      });
    });

    test('mouse shape from OSC 22, text initially', () {
      withTerminal(20, 5, (terminal) {
        expect(terminal.mouseShape, MouseShape.text);
        writeText(terminal, '\x1b]22;pointer\x07');
        expect(terminal.mouseShape, MouseShape.pointer);
        writeText(terminal, '\x1b]22;nwse-resize\x07');
        expect(terminal.mouseShape, MouseShape.nwseResize);
      });
    });

    test('VT ground state', () {
      withTerminal(20, 5, (terminal) {
        expect(terminal.isVtGround, isTrue);
        writeText(terminal, '\x1b[3');
        expect(terminal.isVtGround, isFalse);
        writeText(terminal, '1m');
        expect(terminal.isVtGround, isTrue);
        terminal.write(Uint8List.fromList([0xE2, 0x9C]));
        expect(terminal.isVtGround, isFalse, reason: 'partial UTF-8');
        terminal.write(Uint8List.fromList([0x93]));
        expect(terminal.isVtGround, isTrue);
      });
    });

    test('no VT processing error for malformed input', () {
      withTerminal(20, 5, (terminal) {
        terminal.write(Uint8List.fromList([0x1b, 0x5b, 0xff, 0x9b, 0x41]));
        expect(terminal.hasVtProcessingError, isFalse);
      });
    });

    test('pixel size is cells times the cell size', () {
      withTerminal(10, 4, (terminal) {
        expect((terminal.widthPx, terminal.heightPx), (0, 0));
        terminal.resize(10, 4, cellWidthPx: 8, cellHeightPx: 16);
        expect((terminal.widthPx, terminal.heightPx), (80, 64));
      });
    });
  });

  group('modes', () {
    test('isModeEnabled follows set/reset sequences', () {
      withTerminal(20, 5, (terminal) {
        expect(terminal.isModeEnabled(TerminalMode.wraparound), isTrue);
        expect(terminal.isModeEnabled(TerminalMode.bracketedPaste), isFalse);
        writeText(terminal, '\x1b[?2004h\x1b[?7l\x1b[4h');
        expect(terminal.isModeEnabled(TerminalMode.bracketedPaste), isTrue);
        expect(terminal.isModeEnabled(TerminalMode.wraparound), isFalse);
        expect(terminal.isModeEnabled(TerminalMode.insert), isTrue);
        expect(terminal.isModeEnabled(TerminalMode.slowScroll), isFalse);
      });
    });

    test('every named mode can be queried', () {
      withTerminal(20, 5, (terminal) {
        for (final mode in TerminalMode.named) {
          expect(() => terminal.isModeEnabled(mode), returnsNormally);
        }
      });
    });

    test('unknown modes throw invalidValue', () {
      withTerminal(20, 5, (terminal) {
        expect(
          () => terminal.isModeEnabled(const TerminalMode.dec(31999)),
          throwsA(
            isA<GhosttyException>()
                .having((e) => e.code, 'code', GhosttyResultCode.invalidValue)
                .having(
                  (e) => e.operation,
                  'operation',
                  'ghostty_terminal_get',
                ),
          ),
        );
      });
    });

    test('mouse tracking reflects any tracking mode', () {
      withTerminal(20, 5, (terminal) {
        expect(terminal.isMouseTracking, isFalse);
        for (final mode in ['9', '1000', '1002', '1003']) {
          writeText(terminal, '\x1b[?${mode}h');
          expect(terminal.isMouseTracking, isTrue, reason: mode);
          writeText(terminal, '\x1b[?${mode}l');
          expect(terminal.isMouseTracking, isFalse, reason: mode);
        }
      });
    });

    test('kitty keyboard flags follow push and pop', () {
      withTerminal(20, 5, (terminal) {
        expect(terminal.kittyKeyboardFlags, KittyKeyboardFlags.disabled);
        writeText(terminal, '\x1b[>1u');
        expect(terminal.kittyKeyboardFlags, KittyKeyboardFlags.disambiguate);
        writeText(terminal, '\x1b[>31u');
        expect(terminal.kittyKeyboardFlags, KittyKeyboardFlags.all);
        writeText(terminal, '\x1b[<u');
        expect(terminal.kittyKeyboardFlags, KittyKeyboardFlags.disambiguate);
        writeText(terminal, '\x1b[<u');
        expect(terminal.kittyKeyboardFlags.isEmpty, isTrue);
      });
    });
  });

  group('colours', () {
    test('no default colours initially; palette has 256 entries', () {
      withTerminal(20, 5, (terminal) {
        expect(terminal.colorForeground, isNull);
        expect(terminal.colorBackground, isNull);
        expect(terminal.colorCursor, isNull);
        expect(terminal.colorForegroundDefault, isNull);
        final palette = terminal.colorPalette;
        expect(palette, hasLength(256));
        expect(palette, terminal.colorPaletteDefault);
        expect(
          () => palette[0] = const RgbColor(0, 0, 0),
          throwsUnsupportedError,
        );
      });
    });

    test('OSC overrides change the effective colour, not the default', () {
      withTerminal(20, 5, (terminal) {
        terminal.colorForegroundDefault = const RgbColor(1, 2, 3);
        writeText(terminal, '\x1b]10;rgb:ff/00/80\x07');
        writeText(terminal, '\x1b]11;#102030\x07');
        writeText(terminal, '\x1b]12;rgb:aa/bb/cc\x07');
        writeText(terminal, '\x1b]4;1;rgb:01/02/03\x07');
        expect(terminal.colorForeground, const RgbColor(0xff, 0, 0x80));
        expect(terminal.colorForegroundDefault, const RgbColor(1, 2, 3));
        expect(terminal.colorBackground, const RgbColor(0x10, 0x20, 0x30));
        expect(terminal.colorBackgroundDefault, isNull);
        expect(terminal.colorCursor, const RgbColor(0xaa, 0xbb, 0xcc));
        expect(terminal.colorPalette[1], const RgbColor(1, 2, 3));
        expect(terminal.colorPaletteDefault[1], isNot(const RgbColor(1, 2, 3)));
        writeText(terminal, '\x1b]110\x07');
        expect(terminal.colorForeground, const RgbColor(1, 2, 3));
      });
    });
  });

  group('scrollback', () {
    test('rows scrolled off the top become scrollback', () {
      withTerminal(10, 3, (terminal) {
        expect(terminal.totalRows, 3);
        expect(terminal.scrollbackRows, 0);
        writeText(terminal, List.generate(10, (i) => 'line $i').join('\r\n'));
        expect(terminal.scrollbackRows, 7);
        expect(terminal.totalRows, 10);
        // The formatter covers the whole screen, scrollback included.
        expect(screenText(terminal).split('\n'), hasLength(10));
        expect(
          terminal.scrollbar,
          const ViewportScrollbar(total: 10, offset: 7, length: 3),
        );
        expect(terminal.scrollbar.isAtBottom, isTrue);
      });
    });

    test('the alternate screen has no scrollback', () {
      withTerminal(10, 3, (terminal) {
        writeText(terminal, '\x1b[?1049h');
        writeText(terminal, List.generate(10, (i) => '$i').join('\r\n'));
        expect(terminal.scrollbackRows, 0);
        expect(terminal.totalRows, 3);
      });
    });
  });

  group('lifecycle', () {
    test('reset restores modes, title and screen and keeps the size', () {
      withTerminal(12, 4, (terminal) {
        writeText(terminal, '\x1b]0;t\x07\x1b[?25l\x1b[?2004hhello\r\n');
        terminal.reset();
        expect(terminal.title, '');
        expect(terminal.isCursorVisible, isTrue);
        expect(terminal.isModeEnabled(TerminalMode.bracketedPaste), isFalse);
        expect(screenText(terminal), '');
        expect((terminal.cols, terminal.rows), (12, 4));
        expect((terminal.cursorX, terminal.cursorY), (0, 0));
      });
    });

    test('reset bumps the epoch', () {
      withTerminal(12, 4, (terminal) {
        final handle = handleOf<GhosttyTerminalImpl>(terminal);
        final before = handle.epoch;
        terminal.reset();
        expect(handle.epoch, before + 1);
      });
    });

    test('write-like calls from inside a callback throw StateError', () {
      withTerminal(20, 3, (terminal) {
        final errors = <String, Object?>{};
        void tryCall(String name, void Function() call) {
          try {
            call();
            errors[name] = null;
          } catch (error) {
            errors[name] = error;
          }
        }

        capturePty(
          terminal,
          // A cursor position report makes the terminal write to the pty.
          () => writeText(terminal, '\x1b[6n'),
          onWrite: () {
            tryCall('write', () => writeText(terminal, 'x'));
            tryCall(
              'writeUntil',
              () =>
                  terminal.writeUntil(utf8.encode('x'), WriteBoundaries.oscEnd),
            );
            tryCall(
              'writeWithStops',
              () => terminal.writeWithStops(
                utf8.encode('x'),
                WriteBoundaries.oscEnd,
                (_, _) => true,
              ),
            );
            tryCall('continuation', () => terminal.continuation);
            tryCall('pasteText', () => terminal.pasteText('x'));
            tryCall('cursorX (a getter is fine)', () => terminal.cursorX);
          },
        );
        for (final name in [
          'write',
          'writeUntil',
          'writeWithStops',
          'continuation',
          'pasteText',
        ]) {
          expect(errors[name], isA<StateError>(), reason: name);
        }
        expect(errors['cursorX (a getter is fine)'], isNull);
        expect(screenText(terminal), '', reason: 'nothing was written');
      });
    });

    test(
      'every member throws StateError after dispose; dispose is idempotent',
      () {
        final terminal = VtTerminal(cols: 10, rows: 3)
          ..dispose()
          ..dispose();
        final members = <String, void Function()>{
          'cursorX': () => terminal.cursorX,
          'cursor': () => terminal.cursor,
          'title': () => terminal.title,
          'set title': () => terminal.title = 'x',
          'isModeEnabled': () => terminal.isModeEnabled(TerminalMode.insert),
          'setMode': () => terminal.setMode(TerminalMode.insert, enabled: true),
          'colorPalette': () => terminal.colorPalette,
          'scrollbar': () => terminal.scrollbar,
          'memoryUsage': () => terminal.memoryUsage,
          'reset': terminal.reset,
          'scrollViewport': () =>
              terminal.scrollViewport(const ViewportScroll.top()),
          'compress': terminal.compress,
          'compressionActivity': () => terminal.compressionActivity,
          'continuation': () => terminal.continuation,
          'writeUntil': () =>
              terminal.writeUntil(Uint8List(1), WriteBoundaries.oscStart),
          'writeWithStops': () => terminal.writeWithStops(
            Uint8List(1),
            WriteBoundaries.oscStart,
            (_, _) => true,
          ),
          'pasteText': () => terminal.pasteText('x'),
          'scrollbackMaxLines=': () => terminal.scrollbackMaxLines = 5,
          'setApcMaxBytes': () => terminal.setApcMaxBytes(1),
          'setTerminfoName': () => terminal.setTerminfoName('x'),
          'writeUntil(empty)': () =>
              terminal.writeUntil(Uint8List(0), WriteBoundaries.ground),
          'writeWithStops(empty)': () => terminal.writeWithStops(
            Uint8List(0),
            WriteBoundaries.oscEnd,
            (_, _) => true,
          ),
        };
        members.forEach((name, member) {
          expect(
            member,
            throwsA(
              isA<StateError>().having(
                (e) => e.message,
                'message',
                'VtTerminal has been disposed',
              ),
            ),
            reason: name,
          );
        });
      },
    );
  });

  group('memory', () {
    test('memory usage reports the primary screen; alternate is empty', () {
      withTerminal(80, 24, (terminal) {
        final usage = terminal.memoryUsage;
        expect(usage.primary.pages, greaterThan(0));
        expect(usage.primary.residentBytes, greaterThan(0));
        expect(
          usage.primary.virtualBytes,
          greaterThanOrEqualTo(usage.primary.residentBytes),
        );
        expect(usage.alternate, ScreenMemoryUsage.empty);
        expect(usage.total, usage.primary);
        writeText(terminal, '\x1b[?1049h');
        expect(terminal.memoryUsage.alternate.pages, greaterThan(0));
      });
    });

    test('compression reports a known result and an activity token', () {
      withTerminal(80, 24, (terminal) {
        terminal.scrollbackMaxBytes = null;
        writeText(terminal, List.generate(5000, (i) => 'row $i').join('\r\n'));
        final activity = terminal.compressionActivity;
        expect(terminal.compressionActivity, activity);
        final supported = terminal.memoryUsage.compressionSupported;
        var result = terminal.compress();
        if (!supported) {
          expect(result, CompressionResult.unsupported);
          return;
        }
        for (var i = 0; i < 10000 && result == CompressionResult.pending; i++) {
          result = terminal.compress();
        }
        expect(result, CompressionResult.complete);
        expect(
          terminal.compress(CompressionMode.full),
          isNot(CompressionResult.unknown),
        );
        expect(screenText(terminal), endsWith('row 4999'));
      });
    });
  });
}
