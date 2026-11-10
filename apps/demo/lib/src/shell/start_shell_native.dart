import '../fake_shell/fake_shell.dart';
import 'demo_shell.dart';
import 'pty_shell.dart';

/// `--dart-define=DEMO_SHELL=fake` (`mise run demo:run --fake`) runs the
/// web's fake shell on a native platform too (to try it, or where spawning
/// a process is not allowed).
const _shellChoice = String.fromEnvironment('DEMO_SHELL');

/// Starts the shell of this platform: the user's shell in a pty, unless
/// the app was built with `--dart-define=DEMO_SHELL=fake`. If the pty
/// cannot be created, the fake shell starts instead and says why.
DemoShell startDefaultShell(int cols, int rows) {
  if (_shellChoice == 'fake') return FakeShell(cols: cols, rows: rows);
  try {
    return PtyShell.start(cols: cols, rows: rows);
  } on Object catch (error) {
    return FakeShell(
      cols: cols,
      rows: rows,
      notice: 'Could not start a pty ($error); running the fake shell.',
    );
  }
}
