import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart_xterm/core.dart';
import 'package:ghostty_dart_xterm/src/core/input/keytab/keytab.dart';
import 'package:ghostty_dart_xterm/src/core/input/keytab/keytab_escape.dart';
import 'package:ghostty_dart_xterm/src/core/input/keytab/keytab_parse.dart';
import 'package:ghostty_dart_xterm/src/core/input/keytab/keytab_record.dart';
import 'package:ghostty_dart_xterm/src/core/input/keytab/keytab_token.dart';
import 'package:ghostty_dart_xterm/src/core/input/keytab/qt_keyname.dart';

void main() {
  group('tokenize', () {
    test('splits keyboard and key lines, skipping comments', () {
      final tokens = tokenize('''
# a comment
keyboard "Test"
key Up -Shift+AppCuKeys : "\\EOA"   # trailing comment
key PgUp +Shift : scrollPageUp
''').toList();
      expect(tokens.map((t) => t.type), [
        KeytabTokenType.keyboard,
        KeytabTokenType.input,
        KeytabTokenType.keyDefine,
        KeytabTokenType.keyName,
        KeytabTokenType.modeStatus,
        KeytabTokenType.mode,
        KeytabTokenType.modeStatus,
        KeytabTokenType.mode,
        KeytabTokenType.colon,
        KeytabTokenType.input,
        KeytabTokenType.keyDefine,
        KeytabTokenType.keyName,
        KeytabTokenType.modeStatus,
        KeytabTokenType.mode,
        KeytabTokenType.colon,
        KeytabTokenType.shortcut,
      ]);
      expect(tokens[1].value, 'Test');
      expect(tokens[3].value, 'Up');
      expect(tokens[9].value, r'\EOA');
      expect(tokens.last.value, 'scrollPageUp');
    });

    test('throws TokenizeError for a key line without a colon', () {
      expect(
        () => tokenize('key Up "x"').toList(),
        throwsA(isA<TokenizeError>()),
      );
    });
  });

  group('Keytab.parse', () {
    test('builds records with their modes and actions', () {
      final keytab = Keytab.parse(r'''
keyboard "Mine"
key Up -Shift+AppCuKeys+Mac : "\EOA"
key PgUp +Shift : scrollPageUp
''');
      expect(keytab.name, 'Mine');
      expect(keytab.records, hasLength(2));

      final up = keytab.records.first;
      expect(up.key, TerminalKey.arrowUp);
      expect(up.qtKeyName, 'Up');
      expect(up.shift, isFalse);
      expect(up.appCursorKeys, isTrue);
      expect(up.macos, isTrue);
      expect(up.ctrl, isNull);
      expect(up.action.type, KeytabActionType.input);
      expect(up.action.value, r'\EOA');
      expect(up.action.unescapedValue(), '\x1bOA');
      expect(up.toString(), r'Up -Shift+AppCuKeys+Mac : "\EOA"');

      final pgUp = keytab.records.last;
      expect(pgUp.action.type, KeytabActionType.shortcut);
      expect(pgUp.action.unescapedValue(), 'scrollPageUp');
      expect(keytab.toString(), contains('keyboard "Mine"'));
    });

    test('throws ParseError for an unknown key or mode', () {
      expect(
        () => Keytab.parse('key SysReq : "x"'),
        throwsA(isA<ParseError>()),
      );
      expect(
        () => Keytab.parse('key Up +Hyper : "x"'),
        throwsA(isA<ParseError>()),
      );
    });

    test('the default keytab parses', () {
      expect(Keytab.defaultKeytab.name, 'Default (XFree 4)');
      expect(Keytab.defaultKeytab.records, isNotEmpty);
    });
  });

  group('Keytab.find', () {
    final keytab = Keytab.parse(r'''
key Up -AnyMod+AppCuKeys : "app"
key Up -AnyMod-AppCuKeys : "normal"
key Up +AnyMod           : "mod"
key Up +KeyPad           : "pad"
key Down -Ansi           : "vt52"
key Down +Shift+Control  : "both"
key Left +NewLine        : "nl"
key Left +AppScreen      : "alt"
key Left +AppKeyPad      : "kp"
''');

    test('matches modes and picks the first matching record', () {
      expect(keytab.find(TerminalKey.arrowUp)!.action.value, 'normal');
      expect(
        keytab.find(TerminalKey.arrowUp, appCursorKeys: true)!.action.value,
        'app',
      );
      expect(keytab.find(TerminalKey.arrowUp, alt: true)!.action.value, 'mod');
      expect(
        keytab
            .find(TerminalKey.arrowUp, keyPad: true, ctrl: true)!
            .action
            .value,
        'mod',
      );
      expect(
        keytab
            .find(TerminalKey.arrowDown, shift: true, ctrl: true)!
            .action
            .value,
        'both',
      );
      expect(keytab.find(TerminalKey.arrowDown, shift: true), isNull);
      expect(
        keytab.find(TerminalKey.arrowLeft, newLineMode: true)!.action.value,
        'nl',
      );
      expect(
        keytab.find(TerminalKey.arrowLeft, appScreen: true)!.action.value,
        'alt',
      );
      expect(
        keytab.find(TerminalKey.arrowLeft, appKeyPad: true)!.action.value,
        'kp',
      );
      expect(keytab.find(TerminalKey.arrowRight), isNull);
    });

    test('never matches VT52 (-Ansi) records', () {
      expect(keytab.find(TerminalKey.arrowDown), isNull);
    });
  });

  test('keytabUnescape expands every escape', () {
    expect(keytabUnescape(r'\E\\\"\t\r\n\b\x41\x7f'), '\x1b\\"\t\r\n\bA\x7f');
  });

  test('qtKeynameMap maps keytab names to keys', () {
    expect(qtKeynameMap['Return'], TerminalKey.returnKey);
    expect(qtKeynameMap['Backtab'], TerminalKey.backtab);
    expect(qtKeynameMap['NumEnter'], TerminalKey.numpadEnter);
    expect(qtKeynameMap['A'], TerminalKey.keyA);
    expect(qtKeynameMap, hasLength(133));
  });
}
