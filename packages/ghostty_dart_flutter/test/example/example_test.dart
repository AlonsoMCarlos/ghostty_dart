// The package example (example/lib/main.dart) must keep working: pana
// shows it on pub.dev, and it is the first code users copy.
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart_flutter/ghostty_dart_flutter.dart';

// The example has no pubspec of its own (it uses this package's
// dependencies), so it can only be reached by path.
// ignore: avoid_relative_lib_imports
import '../../example/lib/main.dart';

String _echo(LocalEcho echo, String input) => echo.input(utf8.encode(input));

void main() {
  group('LocalEcho', () {
    test('echoes printable text and answers Enter with a new prompt', () {
      final echo = LocalEcho();
      expect(_echo(echo, 'hi'), 'hi');
      expect(_echo(echo, '\r'), '\r\nyou typed: hi\r\n${LocalEcho.prompt}');
      expect(_echo(echo, '\r'), '\r\n${LocalEcho.prompt}');
    });

    test('Backspace erases one character, never the prompt', () {
      final echo = LocalEcho();
      expect(_echo(echo, 'añ\x7f'), 'añ\b \b');
      expect(_echo(echo, '\x7f\x7f'), '\b \b');
      expect(_echo(echo, '\r'), '\r\n${LocalEcho.prompt}');
    });

    test('a character split across two inputs is echoed once, whole', () {
      final echo = LocalEcho();
      final bytes = utf8.encode('ñ');
      expect(echo.input(Uint8List.sublistView(bytes, 0, 1)), '');
      expect(echo.input(Uint8List.sublistView(bytes, 1)), 'ñ');
    });

    test('escape sequences are swallowed whole', () {
      final echo = LocalEcho();
      // Arrow (CSI), SS3 arrow, focus out (CSI O), Alt+x, then text.
      expect(_echo(echo, '\x1b[A\x1bOB\x1b[O\x1bxok'), 'ok');
      // A sequence split across two writes.
      expect(_echo(echo, '\x1b[1;'), '');
      expect(_echo(echo, '5Cz'), 'z');
      expect(_echo(echo, '\r'), '\r\nyou typed: okz\r\n${LocalEcho.prompt}');
    });
  });

  testWidgets('the app echoes typed keys into its terminal', (tester) async {
    await tester.pumpWidget(const EchoApp());
    await tester.pump();
    final view = tester.widget<VtTerminalView>(find.byType(VtTerminalView));
    final controller = view.controller;

    // Printable text arrives through the text input connection (IME);
    // sendText is the same path. Enter is a key event.
    controller.sendText('a');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    final formatter = TerminalFormatter(controller.terminal);
    final String screen;
    try {
      screen = formatter.formatText();
    } finally {
      formatter.dispose();
    }
    expect(screen, contains('you typed: a'));
  });
}
