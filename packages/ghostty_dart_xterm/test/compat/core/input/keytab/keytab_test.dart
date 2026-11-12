// Ported from package:xterm 4.0.0 (src/core/input/keytab/keytab_test.dart).
// Copyright (c) 2020 xuty. MIT License, see test/compat/LICENSE.xterm.
// Changes: imports (package:test -> flutter_test, package:xterm -> package:ghostty_dart_xterm); the internal imports point at this package's src/ (Keytab is not exported, as in xterm); TerminalKey comes from core.dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart_xterm/core.dart';
import 'package:ghostty_dart_xterm/src/core/input/keytab/keytab.dart';

void main() {
  group('Keytab.find()', () {
    test('can match keyPad', () {
      final keytab = Keytab.parse(r'key Home +KeyPad : "TEST"');
      final record = keytab.find(TerminalKey.home, keyPad: true);
      expect(record!.action.unescapedValue(), 'TEST');

      final record1 = keytab.find(TerminalKey.home);
      expect(record1, isNull);
    });
  });
}
