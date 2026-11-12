// Ported from package:xterm 4.0.0 (src/core/input/handler_test.dart).
// Copyright (c) 2020 xuty. MIT License, see test/compat/LICENSE.xterm.
// Changes: imports (package:test -> flutter_test, package:xterm -> package:ghostty_dart_xterm); the internal keytab import points at this package's src/ (Keytab is not exported, as in xterm).

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart_xterm/src/core/input/keytab/keytab.dart';
import 'package:ghostty_dart_xterm/xterm.dart';

void main() {
  group('defaultInputHandler', () {
    test('supports numpad enter', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);
      terminal.keyInput(TerminalKey.numpadEnter);
      expect(output, ['\r']);
    });
  });

  group('KeytabInputHandler', () {
    test('can insert modifier code', () {
      final handler = KeytabInputHandler(
        Keytab.parse(r'key Home +AnyMod : "\E[1;*H"'),
      );

      final terminal = Terminal(inputHandler: handler);

      late String output;

      terminal.onOutput = (data) {
        output = data;
      };

      terminal.keyInput(TerminalKey.home, ctrl: true);

      expect(output, '\x1b[1;5H');

      terminal.keyInput(TerminalKey.home, shift: true);

      expect(output, '\x1b[1;2H');
    });
  });
}
