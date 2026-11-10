import 'package:flutter/foundation.dart';

import '../fake_shell/fake_shell.dart';
import 'demo_shell.dart';
import 'pty_shell.dart';

/// `--dart-define=DEMO_SHELL=fake` (`mise run demo:run --fake`) runs the
/// web's fake shell on a native platform too (to try it, or where spawning
/// a process is not allowed).
const _shellChoice = String.fromEnvironment('DEMO_SHELL');

/// Starts the shell of this platform: the user's shell in a pty, unless
/// the app was built with `--dart-define=DEMO_SHELL=fake`.
Future<DemoShell> startDefaultShell(int cols, int rows) {
  if (_shellChoice == 'fake') {
    return Future.value(FakeShell(cols: cols, rows: rows));
  }
  return startShellOrFake(cols, rows, startPty: PtyShell.start);
}

/// Starts a shell with [startPty]; if that fails (no such shell, no pty
/// support, a missing native library), starts the fake shell instead with
/// a notice that says why, rather than leaving an empty terminal.
@visibleForTesting
Future<DemoShell> startShellOrFake(
  int cols,
  int rows, {
  required Future<DemoShell> Function({required int cols, required int rows})
  startPty,
}) async {
  try {
    return await startPty(cols: cols, rows: rows);
  } on Object catch (error) {
    return FakeShell(
      cols: cols,
      rows: rows,
      notice: 'Could not start a pty ($error); running the fake shell.',
    );
  }
}
