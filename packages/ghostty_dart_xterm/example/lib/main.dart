// Ported from package:xterm 4.0.0 (example/lib/mock.dart).
// Copyright (c) 2020 xuty. MIT License, see LICENSE.xterm.
// Changes: the import (package:xterm -> package:ghostty_dart_xterm); const
// constructors, keys and dartdoc for our lints; the state disposes the
// terminal (Terminal.dispose, an addition: it frees native memory); the
// fake shell walks runes instead of UTF-16 code units, so an emoji is
// echoed whole; greeting text.
//
// A self-contained app whose "program" is a tiny fake shell written in Dart,
// so it runs without a pty. With a real shell, write the pty's output into
// the terminal and send `terminal.onOutput` to the pty: see the migration
// guide (MIGRATING_FROM_XTERM.md) for flutter_pty and dartssh2.
import 'package:flutter/material.dart';
import 'package:ghostty_dart_xterm/xterm.dart';

void main() => runApp(const MyApp());

/// The app: one terminal connected to [MockRepl].
class MyApp extends StatelessWidget {
  /// Creates the app.
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'ghostty_dart_xterm example',
      debugShowCheckedModeBanner: false,
      home: MyHomePage(),
    );
  }
}

/// The page that shows the terminal.
class MyHomePage extends StatefulWidget {
  /// Creates the page.
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final terminal = Terminal(maxLines: 1000);

  late final MockRepl pty;

  @override
  void initState() {
    super.initState();

    // What the program prints goes into the terminal, and what the user
    // types (terminal.onOutput) goes to the program.
    pty = MockRepl(terminal.write);
    terminal.onOutput = pty.write;
  }

  @override
  void dispose() {
    // Not in xterm: the terminal holds native memory (libghostty-vt), and
    // TerminalView never disposes it.
    terminal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(child: TerminalView(terminal, backgroundOpacity: 0.7)),
    );
  }
}

/// A fake shell: it echoes what is typed, answers Enter with a new prompt
/// and erases one character on Backspace.
class MockRepl {
  /// Creates the shell and prints its greeting through [onOutput].
  MockRepl(this.onOutput) {
    onOutput('Welcome to ghostty_dart_xterm!\r\n');
    onOutput('Type something and press Enter.\r\n');
    onOutput('\n');
    onOutput('\$ ');
  }

  /// Receives everything the shell prints.
  final void Function(String data) onOutput;

  /// Handles [input] typed into the terminal.
  void write(String input) {
    for (final char in input.runes) {
      switch (char) {
        case 13: // carriage return
          onOutput('\r\n');
          onOutput('\$ ');
        case 127: // backspace
          onOutput('\b \b');
        default:
          onOutput(String.fromCharCode(char));
      }
    }
  }
}
