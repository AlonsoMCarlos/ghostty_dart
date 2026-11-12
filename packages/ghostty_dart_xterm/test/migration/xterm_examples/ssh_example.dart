// Ported from package:xterm 4.0.0 (example/lib/ssh.dart).
// Copyright (c) 2020 xuty. MIT License, see test/compat/LICENSE.xterm.
// Changes: imports (package:xterm/xterm.dart ->
// package:ghostty_dart_xterm/xterm.dart; package:dartssh2/dartssh2.dart ->
// fakes.dart, the same SSHClient/SSHSocket/SSHPtyConfig/SSHSession API with
// no network; package:example/src/virtual_keyboard.dart ->
// virtual_keyboard.dart, xterm's file); `withOpacity(0.5)` ->
// `withValues(alpha: 0.5)` (deprecated in the pinned Flutter, so it fails
// our analyzer; unrelated to xterm). Every other line is xterm's
// (reformatted by dart format).

import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:ghostty_dart_xterm/xterm.dart';

import 'fakes.dart';
import 'virtual_keyboard.dart';

const host = 'localhost';
const port = 22;
const username = '<your username>';
const password = '<your password>';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return CupertinoApp(title: 'xterm.dart demo', home: MyHomePage());
  }
}

class MyHomePage extends StatefulWidget {
  MyHomePage({super.key});

  @override
  // ignore: library_private_types_in_public_api
  _MyHomePageState createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  late final terminal = Terminal(inputHandler: keyboard);

  final keyboard = VirtualKeyboard(defaultInputHandler);

  var title = host;

  @override
  void initState() {
    super.initState();
    initTerminal();
  }

  Future<void> initTerminal() async {
    terminal.write('Connecting...\r\n');

    final client = SSHClient(
      await SSHSocket.connect(host, port),
      username: username,
      onPasswordRequest: () => password,
    );

    terminal.write('Connected\r\n');

    final session = await client.shell(
      pty: SSHPtyConfig(width: terminal.viewWidth, height: terminal.viewHeight),
    );

    terminal.buffer.clear();
    terminal.buffer.setCursor(0, 0);

    terminal.onTitleChange = (title) {
      setState(() => this.title = title);
    };

    terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      session.resizeTerminal(width, height, pixelWidth, pixelHeight);
    };

    terminal.onOutput = (data) {
      session.write(utf8.encode(data));
    };

    session.stdout
        .cast<List<int>>()
        .transform(Utf8Decoder())
        .listen(terminal.write);

    session.stderr
        .cast<List<int>>()
        .transform(Utf8Decoder())
        .listen(terminal.write);
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(title),
        backgroundColor: CupertinoTheme.of(
          context,
        ).barBackgroundColor.withValues(alpha: 0.5),
      ),
      child: Column(
        children: [
          Expanded(child: TerminalView(terminal)),
          VirtualKeyboardView(keyboard),
        ],
      ),
    );
  }
}
