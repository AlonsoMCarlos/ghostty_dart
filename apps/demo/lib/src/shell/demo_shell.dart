import 'dart:typed_data';

/// A program the demo connects to the terminal: a real shell in a pty on
/// native platforms, or the pure-Dart fake shell.
///
/// The terminal widget is pty-agnostic: the app feeds [output] to
/// `VtTerminalController.writeBytes` and forwards the controller's
/// `onOutput` to [write] and its `onResize` to [resize].
abstract interface class DemoShell {
  /// A short label for the app bar, such as `bash` or `fake shell`.
  String get name;

  /// What the program writes to the terminal.
  Stream<Uint8List> get output;

  /// Completes with the program's exit code when it ends.
  Future<int> get exitCode;

  /// Sends the terminal's input (keys, pastes, replies) to the program.
  void write(Uint8List data);

  /// Tells the program the terminal is now [cols] × [rows] cells.
  void resize(int cols, int rows);

  /// Ends the program and releases its resources. Idempotent.
  void dispose();
}

/// Starts a [DemoShell] for a [cols] × [rows] terminal.
typedef DemoShellFactory = DemoShell Function(int cols, int rows);
