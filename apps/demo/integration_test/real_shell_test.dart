// Runs the demo against a real pty (flutter_pty2), on a desktop device:
//
//   mise run demo:integration     # Linux: under xvfb-run
//
// Not part of `demo:test`, which needs neither a display nor a pty.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_pty2/flutter_pty2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart_demo/src/demo_app.dart';
import 'package:ghostty_dart_demo/src/shell/pty_shell.dart';
import 'package:ghostty_dart_demo/src/shell/start_shell.dart';
import 'package:ghostty_dart_flutter/ghostty_dart_flutter.dart';
import 'package:integration_test/integration_test.dart';

String _screen(VtTerminalController controller) {
  final formatter = TerminalFormatter(controller.terminal);
  try {
    return formatter.formatText();
  } finally {
    formatter.dispose();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the app runs your shell in a real pty', (tester) async {
    await tester.pumpWidget(const DemoApp(startShell: startDefaultShell));
    final controller = tester
        .state<DemoAppState>(find.byType(DemoApp))
        .controller;

    // Real time: the shell is another process.
    Future<void> waitFor(String text) async {
      for (var i = 0; i < 100; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
        if (_screen(controller).contains(text)) return;
      }
      fail('"$text" never appeared; screen:\n${_screen(controller)}');
    }

    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pump();
    expect(find.textContaining('fake shell'), findsNothing);

    // The shell computes 42; its echo of the command line only shows `6*7`.
    controller.sendText(
      r'echo "ok $((6*7))"'
      '\r',
    );
    await waitFor('ok 42');

    controller.sendText('exit 3\r');
    await waitFor('[process exited with code 3]');
    expect(find.byIcon(Icons.refresh), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  test('PtyShell: bytes both ways, then hang-up and close', () async {
    final shell = await PtyShell.start(cols: 80, rows: 24);
    final out = StringBuffer();
    final sub = shell.output.listen((b) => out.write(utf8.decode(b)));
    shell.write(utf8.encode('echo "x\$((20+3))y"\r'));
    for (var i = 0; i < 100 && !out.toString().contains('x23y'); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(out.toString(), contains('x23y'));

    // SIGHUP ends an interactive shell, which ignores SIGTERM: the exit
    // arrives well before the two seconds after which close() would
    // SIGKILL it. Shells differ in the status (bash: killed by SIGHUP,
    // 129; zsh: exits with 1), so only the timing is checked.
    final watch = Stopwatch()..start();
    shell.dispose();
    await shell.exitCode.timeout(const Duration(seconds: 5));
    expect(watch.elapsed, lessThan(const Duration(milliseconds: 1500)));
    await sub.cancel();
  });

  test('a missing executable is an exception, not a forked app', () async {
    await expectLater(
      Pty.spawn(const PtySpawnOptions(executable: '/nonexistent/shell')),
      throwsA(isA<PtySpawnException>()),
    );
  });
}
