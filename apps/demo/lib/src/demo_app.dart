import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:ghostty_dart_flutter/ghostty_dart_flutter.dart';

import 'shell/demo_shell.dart';

/// The grid font. The demo bundles no font yet, so it asks for JetBrains
/// Mono and falls back to the monospace fonts common on each platform.
/// Without a bundled font, Flutter on the web downloads fallback glyphs
/// from fonts.gstatic.com.
const demoTextStyle = TextStyle(
  fontFamily: 'JetBrains Mono',
  fontFamilyFallback: [
    'DejaVu Sans Mono',
    'Liberation Mono',
    'Noto Sans Mono',
    'Menlo',
    'SF Mono',
    'Consolas',
    'Cascadia Mono',
    'Roboto Mono',
    'monospace',
  ],
  fontSize: 14,
);

/// The demo: one [VtTerminalView] connected to a [DemoShell].
///
/// The wiring is what any app does with a pty: the shell's output goes to
/// [VtTerminalController.writeBytes], the controller's `onOutput` goes to
/// the shell's input, and `onResize` resizes the shell's pty.
class DemoApp extends StatefulWidget {
  /// Creates the demo; [startShell] starts the program to connect.
  const DemoApp({super.key, required this.startShell});

  /// Starts the program shown in the terminal (again after it exits and
  /// the user restarts it).
  final DemoShellFactory startShell;

  @override
  State<DemoApp> createState() => DemoAppState();
}

/// The state of [DemoApp]: owns the controller and the running shell.
class DemoAppState extends State<DemoApp> {
  /// The terminal shown by the demo.
  late final VtTerminalController controller = VtTerminalController(
    // Input after the program exited goes nowhere (nobody reads it).
    onOutput: (data) {
      if (_exitCode == null) _shell?.write(data);
    },
    onResize: (cols, rows, _, _) => _shell?.resize(cols, rows),
    onTitleChanged: (title) => setState(() => _title = title),
  );

  DemoShell? _shell;
  StreamSubscription<void>? _output;
  String _title = '';
  int? _exitCode;

  /// Bumped by every start and stop, so a shell whose spawn finishes after
  /// a newer start, a stop or the app's disposal is disposed at once
  /// instead of being connected.
  var _epoch = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    final epoch = ++_epoch;
    _exitCode = null;
    final DemoShell shell;
    try {
      shell = await widget.startShell(controller.cols, controller.rows);
    } on Object catch (error) {
      if (!mounted || epoch != _epoch) return;
      controller.write('\r\n[could not start a shell: $error]\r\n');
      // Offer Restart, as after an exit.
      setState(() => _exitCode = -1);
      return;
    }
    if (!mounted || epoch != _epoch) {
      shell.dispose();
      return;
    }
    setState(() => _shell = shell);
    _output = shell.output.listen(controller.writeBytes);
    // The terminal may have been resized while the shell was starting.
    shell.resize(controller.cols, controller.rows);
    unawaited(
      shell.exitCode.then((code) {
        if (!mounted || !identical(_shell, shell)) return;
        controller.write('\r\n[process exited with code $code]\r\n');
        setState(() => _exitCode = code);
      }),
    );
  }

  void _restart() {
    _stop();
    // RIS: a fresh screen and modes for the new program.
    controller.write('\x1bc');
    setState(() => _exitCode = null);
    unawaited(_start());
  }

  void _stop() {
    _epoch++;
    unawaited(_output?.cancel());
    _output = null;
    _shell?.dispose();
    _shell = null;
  }

  @override
  void dispose() {
    _stop();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mobile =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    final name = _shell?.name ?? '';
    return MaterialApp(
      title: 'ghostty_dart demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
      ),
      home: Scaffold(
        appBar: AppBar(
          title: Text(_title.isEmpty ? 'ghostty_dart · $name' : _title),
          actions: [
            if (_exitCode != null)
              IconButton(
                tooltip: 'Restart',
                icon: const Icon(Icons.refresh),
                onPressed: _restart,
              ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: VtTerminalView(
                  controller: controller,
                  textStyle: demoTextStyle,
                  padding: const EdgeInsets.all(4),
                  autofocus: true,
                ),
              ),
              if (mobile) VtTerminalKeyToolbar(controller: controller),
            ],
          ),
        ),
      ),
    );
  }
}
