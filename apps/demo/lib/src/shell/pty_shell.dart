import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_pty2/flutter_pty2.dart';

import 'demo_shell.dart';

/// The user's shell running in a pseudo-terminal (flutter_pty2 3.0.0).
///
/// What flutter_pty2 still leaves to the app, or does not do, is listed
/// under "Known limitations" in the demo's README.md.
final class PtyShell implements DemoShell {
  /// Wraps a running [session]; [start] is the way to get one.
  ///
  /// [posixSignals] says whether [dispose] can hang up the shell with
  /// SIGHUP first (not on Windows), and [hangUpGrace] how long it waits
  /// for the shell to exit before [PtySession.close] kills what is left.
  @visibleForTesting
  PtyShell.forSession(
    this._session,
    this.name, {
    required bool posixSignals,
    Duration hangUpGrace = const Duration(seconds: 2),
  }) : _posixSignals = posixSignals,
       _hangUpGrace = hangUpGrace {
    // `done`, not `processExit`: it completes once the program has exited
    // *and* all its output was delivered, so the exit banner comes after
    // the program's last line.
    exitCode = _session.done.then(_codeOf, onError: (Object _) => -1);
    unawaited(exitCode.then((_) => _exited = true));
  }

  /// Starts the user's shell in a [cols] × [rows] pty, in the home
  /// directory.
  ///
  /// - Unix: `$SHELL` (or `/bin/sh`) as a login shell (`-l`).
  /// - Windows: `%COMSPEC%` (or `cmd.exe`).
  ///
  /// The future fails with a [PtyException] if the shell cannot be
  /// started: flutter_pty2 reports a failed `exec` (no such file, no
  /// permission, bad working directory) back to the parent instead of
  /// letting the child go on.
  ///
  /// The child inherits the app's whole environment, with `TERM` set to
  /// `xterm-256color` and `COLORTERM` saying 24-bit colour works, which
  /// libghostty-vt supports.
  static Future<PtyShell> start({required int cols, required int rows}) async {
    final env = Platform.environment;
    final windows = Platform.isWindows;
    final String shell;
    if (windows) {
      shell = env['COMSPEC'] ?? 'cmd.exe';
    } else {
      final userShell = env['SHELL'];
      shell = userShell == null || userShell.isEmpty ? '/bin/sh' : userShell;
    }
    final home = windows ? env['USERPROFILE'] : env['HOME'];
    final session = await Pty.spawn(
      PtySpawnOptions(
        executable: shell,
        arguments: windows ? const [] : const ['-l'],
        workingDirectory: home == null || home.isEmpty ? null : home,
        environment: const PtyEnvironment.inherit(
          overrides: {'TERM': 'xterm-256color', 'COLORTERM': 'truecolor'},
        ),
        size: PtySize(columns: cols, rows: rows),
      ),
    );
    return PtyShell.forSession(
      session,
      shell.split(RegExp(r'[/\\]')).last,
      posixSignals: !windows,
    );
  }

  /// The largest write flutter_pty2's `tryWrite` takes in one call.
  static const _maxTryWrite = 64 * 1024;

  /// Input queued in Dart while the program does not read it. Beyond this,
  /// further input is dropped rather than buffered without bound (a big
  /// paste into a program that never reads, such as `sleep 100`).
  static const maxQueuedBytes = 4 * 1024 * 1024;

  final PtySession _session;
  final bool _posixSignals;
  final Duration _hangUpGrace;
  var _disposed = false;
  var _exited = false;
  var _queuedBytes = 0;

  @override
  final String name;

  @override
  Stream<Uint8List> get output => _session.output;

  @override
  late final Future<int> exitCode;

  static int _codeOf(PtyExit exit) => switch (exit) {
    PtyExitCode(:final code) => code,
    // The shell convention for "killed by signal n".
    PtySignalExit(:final signal) => 128 + signal,
  };

  bool get _writable => !_disposed && !_exited;

  /// Sends [data] without blocking the UI thread.
  ///
  /// Small writes go straight to flutter_pty2's native queue (`tryWrite`).
  /// When that queue is full, the data waits in order behind it
  /// (`input.write`, whose future completes when the pty took it), up to
  /// [maxQueuedBytes].
  @override
  void write(Uint8List data) {
    if (!_writable || data.isEmpty) return;
    final input = _session.input;
    try {
      if (_queuedBytes == 0 && data.length <= _maxTryWrite) {
        switch (input.tryWrite(data)) {
          case PtyWriteResult.accepted || PtyWriteResult.closed:
            return;
          case PtyWriteResult.backpressured:
            break;
        }
      }
    } on Object {
      // The pty's input failed (flutter_pty2 closes the session); the exit
      // shows up through [exitCode].
      return;
    }
    if (_queuedBytes + data.length > maxQueuedBytes) return;
    _queuedBytes += data.length;
    // The caller may reuse its buffer; a queued write must not see that.
    final copy = Uint8List.fromList(data);
    unawaited(
      input
          .write(copy)
          .then<void>((_) {}, onError: (Object _) {})
          .whenComplete(() => _queuedBytes -= copy.length),
    );
  }

  @override
  void resize(int cols, int rows) {
    if (!_writable) return;
    try {
      _session.resize(PtySize(columns: cols, rows: rows));
    } on Object {
      // The session is closing; nothing left to resize.
    }
  }

  /// Hangs up the shell, as closing a terminal window does, then closes
  /// the pty.
  ///
  /// Interactive bash and zsh ignore SIGTERM, and flutter_pty2's `close()`
  /// sends SIGKILL, which gives the shell no chance to save its history or
  /// hang up its jobs. So on Unix the shell's process group gets SIGHUP
  /// first and `close()` runs once the shell has exited, or after
  /// [hangUpGrace] at the latest. Windows has no signals: `close()` ends
  /// the program's whole process tree (a job object) right away.
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_exited || !_posixSignals) {
      unawaited(_close());
      return;
    }
    try {
      _session.sendSignal(
        PosixSignal.hup,
        target: PosixSignalTarget.shellProcessGroup,
      );
    } on Object {
      // Already gone or closing: close() below still releases everything.
    }
    unawaited(
      exitCode.timeout(_hangUpGrace, onTimeout: () => -1).whenComplete(_close),
    );
  }

  Future<void> _close() =>
      _session.close().then<void>((_) {}, onError: (Object _) {});
}
