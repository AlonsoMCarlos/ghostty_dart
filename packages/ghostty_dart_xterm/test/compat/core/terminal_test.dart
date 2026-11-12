// Ported from package:xterm 4.0.0 (src/terminal_test.dart).
// Copyright (c) 2020 xuty. MIT License, see test/compat/LICENSE.xterm.
// Changes: imports (package:test -> flutter_test, package:xterm -> package:ghostty_dart_xterm);
// "can handle mouse events", "preserves hidden cells when reflow is disabled" and both
// onPrivateOSC "works with" tests are skipped as documented differences, each followed by a
// marked ghostty_dart_xterm test of the documented behaviour; `[]` typed as `<String>[]`.

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart_xterm/core.dart';

void main() {
  group('Terminal.inputHandler', () {
    test('can be set to null', () {
      final terminal = Terminal(inputHandler: null);
      expect(() => terminal.keyInput(TerminalKey.keyA), returnsNormally);
    });

    test('can be changed', () {
      final handler1 = _TestInputHandler();
      final handler2 = _TestInputHandler();
      final terminal = Terminal(inputHandler: handler1);

      terminal.keyInput(TerminalKey.keyA);
      expect(handler1.events, isNotEmpty);

      terminal.inputHandler = handler2;

      terminal.keyInput(TerminalKey.keyA);
      expect(handler2.events, isNotEmpty);
    });
  });

  group('Terminal.mouseInput', () {
    test(
      'can handle mouse events',
      () {
        final output = <String>[];

        final terminal = Terminal(onOutput: output.add);

        terminal.mouseInput(
          TerminalMouseButton.left,
          TerminalMouseButtonState.down,
          CellOffset(10, 10),
        );

        expect(output, isEmpty);

        // enable mouse reporting
        terminal.write('\x1b[?1000h');

        terminal.mouseInput(
          TerminalMouseButton.left,
          TerminalMouseButtonState.down,
          CellOffset(10, 10),
        );

        expect(output, ['\x1B[M +,']);
      },
      skip:
          'differs from xterm: normal and UTF-8 mouse reports encode the row as 32 + y; xterm sends 32 + y + 1 (an off-by-one; ClickMouseHandler.call), see COMPATIBILITY.md',
    );

    // ghostty_dart_xterm: the same scenario with the correct row (32 + 11).
    // Not part of xterm's suite.
    test('can handle mouse events (correct row)', () {
      final output = <String>[];

      final terminal = Terminal(onOutput: output.add);

      terminal.mouseInput(
        TerminalMouseButton.left,
        TerminalMouseButtonState.down,
        CellOffset(10, 10),
      );

      expect(output, isEmpty);

      terminal.write('\x1b[?1000h');

      terminal.mouseInput(
        TerminalMouseButton.left,
        TerminalMouseButtonState.down,
        CellOffset(10, 10),
      );

      expect(output, ['\x1B[M ++']);
    });
  });

  group('Terminal.reflowEnabled', () {
    test('prevents reflow when set to false', () {
      final terminal = Terminal(reflowEnabled: false);

      terminal.write('Hello World');
      terminal.resize(5, 5);

      expect(terminal.buffer.lines[0].toString(), 'Hello');
      expect(terminal.buffer.lines[1].toString(), isEmpty);
    });

    test(
      'preserves hidden cells when reflow is disabled',
      () {
        final terminal = Terminal(reflowEnabled: false);

        terminal.write('Hello World');
        terminal.resize(5, 5);
        terminal.resize(20, 5);

        expect(terminal.buffer.lines[0].toString(), 'Hello World');
        expect(terminal.buffer.lines[1].toString(), isEmpty);
      },
      skip:
          'differs from xterm: without reflow libghostty-vt drops the cells beyond a narrower width instead of keeping them (Terminal.reflowEnabled), see COMPATIBILITY.md',
    );

    // ghostty_dart_xterm: the documented behaviour instead (libghostty-vt
    // drops the cells beyond the narrower width). Not part of xterm's suite.
    test('drops hidden cells when reflow is disabled', () {
      final terminal = Terminal(reflowEnabled: false);

      terminal.write('Hello World');
      terminal.resize(5, 5);
      terminal.resize(20, 5);

      expect(terminal.buffer.lines[0].toString(), 'Hello');
      expect(terminal.buffer.lines[1].toString(), isEmpty);
    });

    test('can be set at runtime', () {
      final terminal = Terminal(reflowEnabled: true);

      terminal.resize(5, 5);
      terminal.write('Hello World');
      terminal.reflowEnabled = false;
      terminal.resize(20, 5);

      expect(terminal.buffer.lines[0].toString(), 'Hello');
      expect(terminal.buffer.lines[1].toString(), ' Worl');
      expect(terminal.buffer.lines[2].toString(), 'd');
    });
  });

  group('Terminal.mouseInput', () {
    test('applys to the main buffer', () {
      final terminal = Terminal(wordSeparators: {'z'.codeUnitAt(0)});

      expect(terminal.mainBuffer.wordSeparators, contains('z'.codeUnitAt(0)));
    });

    test('applys to the alternate buffer', () {
      final terminal = Terminal(wordSeparators: {'z'.codeUnitAt(0)});

      expect(terminal.altBuffer.wordSeparators, contains('z'.codeUnitAt(0)));
    });
  });

  group('Terminal.onPrivateOSC', () {
    test(
      r'works with \a end',
      () {
        String? lastCode;
        List<String>? lastData;

        final terminal = Terminal(
          onPrivateOSC: (String code, List<String> data) {
            lastCode = code;
            lastData = data;
          },
        );

        terminal.write('\x1b]6\x07');

        expect(lastCode, '6');
        expect(lastData, <String>[]);

        terminal.write('\x1b]66;hello world\x07');

        expect(lastCode, '66');
        expect(lastData, ['hello world']);

        terminal.write('\x1b]666;hello;world\x07');

        expect(lastCode, '666');
        expect(lastData, ['hello', 'world']);

        terminal.write('\x1b]hello;world\x07');

        expect(lastCode, 'hello');
        expect(lastData, ['world']);
      },
      skip:
          'differs from xterm: OSC 66 is Kitty text sizing, implemented by libghostty-vt, so it never reaches onPrivateOSC (Terminal.onPrivateOSC), see COMPATIBILITY.md',
    );

    // ghostty_dart_xterm: the same scenario with an OSC number libghostty-vt
    // does not implement (65) in place of 66, plus the documented difference
    // that OSC 66 is not forwarded. Not part of xterm's suite.
    test(r'works with \a end (OSC 65; OSC 66 is not private)', () {
      String? lastCode;
      List<String>? lastData;

      final terminal = Terminal(
        onPrivateOSC: (String code, List<String> data) {
          lastCode = code;
          lastData = data;
        },
      );

      terminal.write('\x1b]6\x07');

      expect(lastCode, '6');
      expect(lastData, <String>[]);

      terminal.write('\x1b]66;hello world\x07');

      expect(lastCode, '6');
      expect(lastData, <String>[]);

      terminal.write('\x1b]65;hello world\x07');

      expect(lastCode, '65');
      expect(lastData, ['hello world']);

      terminal.write('\x1b]666;hello;world\x07');

      expect(lastCode, '666');
      expect(lastData, ['hello', 'world']);

      terminal.write('\x1b]hello;world\x07');

      expect(lastCode, 'hello');
      expect(lastData, ['world']);
    });

    test(
      r'works with \x1b\ end',
      () {
        String? lastCode;
        List<String>? lastData;

        final terminal = Terminal(
          onPrivateOSC: (String code, List<String> data) {
            lastCode = code;
            lastData = data;
          },
        );

        terminal.write('\x1b]6\x1b\\');

        expect(lastCode, '6');
        expect(lastData, <String>[]);

        terminal.write('\x1b]66;hello world\x1b\\');

        expect(lastCode, '66');
        expect(lastData, ['hello world']);

        terminal.write('\x1b]666;hello;world\x1b\\');

        expect(lastCode, '666');
        expect(lastData, ['hello', 'world']);

        terminal.write('\x1b]hello;world\x1b\\');

        expect(lastCode, 'hello');
        expect(lastData, ['world']);
      },
      skip:
          'differs from xterm: OSC 66 is Kitty text sizing, implemented by libghostty-vt, so it never reaches onPrivateOSC (Terminal.onPrivateOSC), see COMPATIBILITY.md',
    );

    // ghostty_dart_xterm: the same scenario with an OSC number libghostty-vt
    // does not implement (65) in place of 66, plus the documented difference
    // that OSC 66 is not forwarded. Not part of xterm's suite.
    test(r'works with \x1b\ end (OSC 65; OSC 66 is not private)', () {
      String? lastCode;
      List<String>? lastData;

      final terminal = Terminal(
        onPrivateOSC: (String code, List<String> data) {
          lastCode = code;
          lastData = data;
        },
      );

      terminal.write('\x1b]6\x1b\\');

      expect(lastCode, '6');
      expect(lastData, <String>[]);

      terminal.write('\x1b]66;hello world\x1b\\');

      expect(lastCode, '6');
      expect(lastData, <String>[]);

      terminal.write('\x1b]65;hello world\x1b\\');

      expect(lastCode, '65');
      expect(lastData, ['hello world']);

      terminal.write('\x1b]666;hello;world\x1b\\');

      expect(lastCode, '666');
      expect(lastData, ['hello', 'world']);

      terminal.write('\x1b]hello;world\x1b\\');

      expect(lastCode, 'hello');
      expect(lastData, ['world']);
    });

    test('do not receive common osc', () {
      String? lastCode;
      List<String>? lastData;

      final terminal = Terminal(
        onPrivateOSC: (String code, List<String> data) {
          lastCode = code;
          lastData = data;
        },
      );

      terminal.write('\x1b]0;hello world\x07');

      expect(lastCode, isNull);
      expect(lastData, isNull);
    });
  });
}

class _TestInputHandler implements TerminalInputHandler {
  final events = <TerminalKeyboardEvent>[];

  @override
  String? call(TerminalKeyboardEvent event) {
    events.add(event);
    return null;
  }
}
