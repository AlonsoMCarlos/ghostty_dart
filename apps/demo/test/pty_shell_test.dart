import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_pty2/flutter_pty2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart_demo/src/fake_shell/fake_shell.dart';
import 'package:ghostty_dart_demo/src/shell/demo_shell.dart';
import 'package:ghostty_dart_demo/src/shell/pty_shell.dart';
import 'package:ghostty_dart_demo/src/shell/start_shell_native.dart';

/// A [PtySession] that records what the shell does to it; no process, no
/// pty.
final class _FakeSession implements PtySession {
  final calls = <String>[];
  final outputController = StreamController<Uint8List>();
  final doneCompleter = Completer<PtyExit>();
  final fakeInput = _FakeInput();

  @override
  int get pid => 4242;
  @override
  PtyCapabilities get capabilities => throw UnimplementedError();
  @override
  Stream<Uint8List> get output => outputController.stream;
  @override
  PtyInput get input => fakeInput;
  @override
  Future<PtyExit> get processExit => doneCompleter.future;
  @override
  Future<PtyExit> get done => doneCompleter.future;

  @override
  void resize(PtySize size) => calls.add('resize ${size.columns}x${size.rows}');
  @override
  void kill() => calls.add('kill');
  @override
  void sendSignal(
    PosixSignal signal, {
    PosixSignalTarget target = PosixSignalTarget.foregroundProcessGroup,
  }) => calls.add('signal ${signal.name} ${target.name}');
  @override
  Future<void> close() async => calls.add('close');
}

final class _FakeInput implements PtyInput {
  /// What [tryWrite] answers.
  var tryResult = PtyWriteResult.accepted;
  final tried = <String>[];
  final queued = <String>[];
  final pending = <Completer<void>>[];

  @override
  PtyWriteResult tryWrite(Uint8List data) {
    if (tryResult == PtyWriteResult.accepted) tried.add(utf8.decode(data));
    return tryResult;
  }

  @override
  Future<void> write(Uint8List data) {
    queued.add(utf8.decode(data));
    final completer = Completer<void>();
    pending.add(completer);
    return completer.future;
  }

  @override
  Future<void> flush() => Future.wait([for (final c in pending) c.future]);
}

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

void main() {
  group('PtyShell', () {
    late _FakeSession session;

    PtyShell shell({bool posix = true, Duration? grace}) => PtyShell.forSession(
      session,
      'bash',
      posixSignals: posix,
      hangUpGrace: grace ?? const Duration(seconds: 2),
    );

    setUp(() => session = _FakeSession());

    test('exit code: the code, or 128 + the signal', () async {
      expect(shell().name, 'bash');
      session.doneCompleter.complete(const PtyExitCode(3));
      expect(await shell().exitCode, 3);

      session = _FakeSession()..doneCompleter.complete(const PtySignalExit(9));
      expect(await shell().exitCode, 137);
    });

    test('resize passes columns and rows in that order', () {
      shell().resize(100, 30);
      expect(session.calls, ['resize 100x30']);
    });

    test('writes without waiting; queues in order when backpressured', () {
      final s = shell();
      s.write(_bytes('a'));
      expect(session.fakeInput.tried, ['a']);

      session.fakeInput.tryResult = PtyWriteResult.backpressured;
      s.write(_bytes('b'));
      // While anything is queued, later input queues behind it (no
      // reordering through tryWrite).
      session.fakeInput.tryResult = PtyWriteResult.accepted;
      s.write(_bytes('c'));
      expect(session.fakeInput.tried, ['a']);
      expect(session.fakeInput.queued, ['b', 'c']);
    });

    test('input beyond the queue limit is dropped', () {
      session.fakeInput.tryResult = PtyWriteResult.backpressured;
      final s = shell();
      final chunk = Uint8List(PtyShell.maxQueuedBytes ~/ 2);
      s
        ..write(chunk)
        ..write(chunk)
        ..write(_bytes('x'));
      expect(session.fakeInput.queued, hasLength(2));
    });

    test('dispose hangs up the shell, then closes after it exits', () async {
      final s = shell();
      s.dispose();
      expect(session.calls, ['signal hup shellProcessGroup']);
      // Idempotent, and no input or resize reaches a disposed shell.
      s
        ..dispose()
        ..write(_bytes('late'))
        ..resize(10, 10);
      await pumpEventQueue();
      expect(session.calls, ['signal hup shellProcessGroup']);
      expect(session.fakeInput.tried, isEmpty);

      session.doneCompleter.complete(const PtySignalExit(1));
      await pumpEventQueue();
      expect(session.calls, ['signal hup shellProcessGroup', 'close']);
    });

    test('dispose closes anyway when the shell ignores the hang-up', () async {
      shell(grace: const Duration(milliseconds: 10)).dispose();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(session.calls, ['signal hup shellProcessGroup', 'close']);
    });

    test('dispose after the exit, or on Windows, only closes', () async {
      final exited = shell();
      session.doneCompleter.complete(const PtyExitCode(0));
      await exited.exitCode;
      await pumpEventQueue();
      exited
        ..dispose()
        ..write(_bytes('after exit'));
      await pumpEventQueue();
      expect(session.calls, ['close']);
      expect(session.fakeInput.tried, isEmpty);

      session = _FakeSession();
      shell(posix: false).dispose();
      await pumpEventQueue();
      expect(session.calls, ['close']);
    });
  });

  group('startShellOrFake', () {
    test('returns the pty shell when it starts', () async {
      final pty = PtyShell.forSession(
        _FakeSession(),
        'zsh',
        posixSignals: true,
      );
      final shell = await startShellOrFake(
        80,
        24,
        startPty: ({required cols, required rows}) => Future.value(pty),
      );
      expect(shell, same(pty));
    });

    test('falls back to the fake shell, saying why', () async {
      final shell = await startShellOrFake(
        80,
        24,
        startPty: ({required cols, required rows}) =>
            Future<DemoShell>.error(const PtySpawnException('no such file')),
      );
      expect(shell, isA<FakeShell>());
      final out = StringBuffer();
      shell.output.listen((b) => out.write(utf8.decode(b)));
      await pumpEventQueue();
      expect(
        out.toString(),
        contains(
          'Could not start a pty (PtySpawnException: no such file); '
          'running the fake shell.',
        ),
      );
      shell.dispose();
    });
  });
}
