// Migration evidence: xterm 4.0.0's own examples (example/lib/main.dart with
// flutter_pty, example/lib/ssh.dart with dartssh2 and its virtual keyboard)
// compile against ghostty_dart_xterm with only their imports changed, and
// work. The ported files are in xterm_examples/ (each lists its changes);
// flutter_pty and dartssh2 are replaced by fakes with the same API
// (xterm_examples/fakes.dart), so no process or network is involved.
//
// Also covers this package's example/ (pana shows it on pub.dev).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart_xterm/xterm.dart';

// The package example has no pubspec of its own (it uses this package's
// dependencies), so it can only be reached by path.
// ignore: avoid_relative_lib_imports
import '../../example/lib/main.dart' as example;
import 'xterm_examples/fakes.dart';
import 'xterm_examples/pty_example.dart' as pty_example;
import 'xterm_examples/ssh_example.dart' as ssh_example;

Terminal _terminalOf(WidgetTester tester) =>
    tester.widget<TerminalView>(find.byType(TerminalView)).terminal;

String _screen(Terminal terminal) => terminal.buffer.getText();

/// Unmounts the app, then frees the terminal (xterm's examples never do:
/// in xterm there is nothing to free; here it is native memory).
Future<void> _tearDown(WidgetTester tester, Terminal terminal) async {
  await tester.pumpWidget(const SizedBox());
  terminal.dispose();
}

void main() {
  testWidgets('xterm example/lib/main.dart: a shell in a pty', (tester) async {
    Pty.last = null;
    await tester.pumpWidget(pty_example.MyApp());
    // The example starts the pty after the first frame.
    await tester.pump();
    final terminal = _terminalOf(tester);
    final pty = Pty.last!;

    // Started with the size the view laid the terminal out at.
    expect(pty.columns, terminal.viewWidth);
    expect(pty.rows, terminal.viewHeight);
    expect(terminal.viewWidth, greaterThan(10));

    // Program output reaches the screen.
    pty.emit('\x1b[1mhello\x1b[0m from the shell\r\n');
    await tester.pump();
    expect(_screen(terminal), contains('hello from the shell'));

    // What the user types reaches the program.
    terminal.textInput('ls');
    terminal.keyInput(TerminalKey.enter);
    expect(pty.written, 'ls\r');

    // Resizes reach the pty, rows first as flutter_pty wants.
    terminal.resize(100, 30);
    expect((pty.columns, pty.rows), (100, 30));

    // The selection + getText path of its right-click handler.
    final controller = tester
        .widget<TerminalView>(find.byType(TerminalView))
        .controller!;
    controller.setSelection(
      terminal.buffer.createAnchor(0, 0),
      terminal.buffer.createAnchor(5, 0),
    );
    expect(terminal.buffer.getText(controller.selection), 'hello');
    controller.clearSelection();
    expect(controller.selection, isNull);

    pty.exit(3);
    await tester.pump();
    expect(_screen(terminal), contains('the process exited with exit code 3'));

    await _tearDown(tester, terminal);
  });

  testWidgets('xterm example/lib/ssh.dart: dartssh2 and a virtual keyboard', (
    tester,
  ) async {
    SSHClient.last = null;
    await tester.pumpWidget(ssh_example.MyApp());
    await tester.pump();
    final terminal = _terminalOf(tester);
    final session = SSHClient.last!.session!;

    // The pty was requested with the terminal's size, and the example's
    // buffer.clear() + setCursor(0, 0) wiped "Connecting... Connected".
    expect(session.pty!.width, terminal.viewWidth);
    expect(session.pty!.height, terminal.viewHeight);
    expect(_screen(terminal).trim(), isEmpty);
    expect(terminal.buffer.cursorX, 0);
    expect(terminal.buffer.cursorY, 0);

    // Remote output, and its title (OSC 2) in the navigation bar.
    session.emit('\x1b]2;remote title\x07user@host:~\$ ');
    await tester.pump();
    expect(_screen(terminal), contains(r'user@host:~$'));
    // onTitleChange runs after the chunk is parsed (COMPATIBILITY.md,
    // Terminal.write); its setState needs one more frame.
    await tester.pump();
    expect(find.text('remote title'), findsOneWidget);

    // Typing goes to the session.
    terminal.textInput('x');
    expect(session.written, 'x');

    // The virtual keyboard: a custom TerminalInputHandler that adds Ctrl.
    await tester.tap(find.text('Ctrl'));
    await tester.pump();
    terminal.keyInput(TerminalKey.keyC);
    expect(session.written, 'x\x03');

    // Resizes go to the session with all four arguments.
    terminal.resize(90, 20);
    expect(session.lastResize?.$1, 90);
    expect(session.lastResize?.$2, 20);

    await _tearDown(tester, terminal);
  });

  testWidgets('example/lib/main.dart: the fake shell echoes input', (
    tester,
  ) async {
    await tester.pumpWidget(const example.MyApp());
    await tester.pump();
    final terminal = _terminalOf(tester);
    expect(_screen(terminal), contains('Welcome to ghostty_dart_xterm!'));

    terminal.textInput('hi');
    terminal.keyInput(TerminalKey.enter);
    terminal.textInput('ab');
    terminal.keyInput(TerminalKey.backspace);
    await tester.pump();
    final lines = _screen(terminal).trimRight().split('\n');
    expect(lines[lines.length - 2].trimRight(), r'$ hi');
    expect(lines.last.trimRight(), r'$ a');

    // The example's State.dispose disposes the terminal.
    await tester.pumpWidget(const SizedBox());
    expect(() => terminal.write('x'), throwsStateError);
  });

  test('MockRepl answers Enter with a prompt and Backspace with an erase', () {
    final out = StringBuffer();
    final repl = example.MockRepl(out.write);
    out.clear();
    repl.write('a\x7f\r');
    expect(out.toString(), 'a\b \b\r\n\$ ');
  });
}
