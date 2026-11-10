import '../fake_shell/fake_shell.dart';
import 'demo_shell.dart';

/// Starts the shell of this platform: the fake shell, because there is no
/// pty (the web).
DemoShell startDefaultShell(int cols, int rows) =>
    FakeShell(cols: cols, rows: rows);
