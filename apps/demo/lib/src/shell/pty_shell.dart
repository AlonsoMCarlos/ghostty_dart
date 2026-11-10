import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_pty/flutter_pty.dart';

import 'demo_shell.dart';

/// The user's shell running in a pseudo-terminal (flutter_pty 0.4.2).
///
/// flutter_pty has defects the demo works around here; what cannot be
/// worked around is listed under "Known limitations" in the demo's
/// README.md.
final class PtyShell implements DemoShell {
  PtyShell._(this._pty, this.name) {
    unawaited(_pty.exitCode.then((_) => _exited = true));
  }

  /// Starts the user's shell in a [cols] × [rows] pty, in the home
  /// directory.
  ///
  /// - Unix: `$SHELL` (or `/bin/sh`) as a login shell, always spawned
  ///   through `/bin/sh -c 'exec "$0" "$@"'`. flutter_pty's child returns
  ///   into the app when its `execvp` fails; `/bin/sh` always exists, and
  ///   if *it* cannot exec the user's shell it prints the error and exits.
  /// - Windows: `%COMSPEC%` (or `cmd.exe`).
  ///
  /// The child gets the app's whole environment: flutter_pty otherwise
  /// passes only a handful of variables (on Windows not even `Path` or
  /// `SystemRoot`) and forces `LANG=en_US.UTF-8`. `TERM` is
  /// `xterm-256color`, and `COLORTERM` says 24-bit colour works, which
  /// libghostty-vt supports.
  factory PtyShell.start({required int cols, required int rows}) {
    final env = Platform.environment;
    final String executable;
    final List<String> arguments;
    final String shell;
    if (Platform.isWindows) {
      shell = env['COMSPEC'] ?? 'cmd.exe';
      executable = shell;
      arguments = const [];
    } else {
      final userShell = env['SHELL'];
      shell = userShell == null || userShell.isEmpty ? '/bin/sh' : userShell;
      executable = '/bin/sh';
      arguments = ['-c', r'exec "$0" "$@"', shell, '-l'];
    }
    final pty = Pty.start(
      executable,
      arguments: arguments,
      columns: cols,
      rows: rows,
      workingDirectory: Platform.isWindows ? env['USERPROFILE'] : env['HOME'],
      environment: {...env, 'TERM': 'xterm-256color', 'COLORTERM': 'truecolor'},
    );
    return PtyShell._(pty, shell.split(RegExp(r'[/\\]')).last);
  }

  final Pty _pty;
  var _disposed = false;
  var _exited = false;

  @override
  final String name;

  @override
  Stream<Uint8List> get output => _pty.output;

  @override
  Future<int> get exitCode => _pty.exitCode;

  /// Whether input still goes to the program. After it exits nobody reads
  /// the pty, and flutter_pty's blocking `write` could freeze the UI thread
  /// once the pty's input queue is full.
  bool get _writable => !_disposed && !_exited;

  @override
  void write(Uint8List data) {
    if (_writable) _pty.write(data);
  }

  @override
  void resize(int cols, int rows) {
    if (_writable) _pty.resize(rows, cols);
  }

  /// Hangs up the shell, as closing a terminal window does: interactive
  /// bash and zsh ignore SIGTERM (Windows terminates the process, signals
  /// do not exist there). flutter_pty has no call to close the pty, so its
  /// file descriptors and reader thread stay (README, "Known
  /// limitations").
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (!_exited) _pty.kill(ProcessSignal.sighup);
  }
}
