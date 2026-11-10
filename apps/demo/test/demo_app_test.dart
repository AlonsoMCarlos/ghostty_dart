import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart_demo/src/demo_app.dart';
import 'package:ghostty_dart_demo/src/fake_shell/fake_shell.dart';
import 'package:ghostty_dart_demo/src/shell/demo_shell.dart';
import 'package:ghostty_dart_flutter/ghostty_dart_flutter.dart';

/// The screen's text, as a user would copy it.
String _screen(VtTerminalController controller) {
  final formatter = TerminalFormatter(controller.terminal);
  try {
    return formatter.formatText();
  } finally {
    formatter.dispose();
  }
}

/// Counts the input the app forwards to a [FakeShell].
final class _SpyShell implements DemoShell {
  _SpyShell(this._inner);

  final FakeShell _inner;
  var writes = 0;

  @override
  String get name => _inner.name;
  @override
  Stream<Uint8List> get output => _inner.output;
  @override
  Future<int> get exitCode => _inner.exitCode;
  @override
  void write(Uint8List data) {
    writes++;
    _inner.write(data);
  }

  @override
  void resize(int cols, int rows) => _inner.resize(cols, rows);
  @override
  void dispose() => _inner.dispose();
}

void main() {
  late List<FakeShell> shells;

  DemoShell start(int cols, int rows) {
    final shell = FakeShell(cols: cols, rows: rows);
    shells.add(shell);
    return shell;
  }

  setUp(() => shells = []);

  testWidgets('connects the terminal to the shell both ways', (tester) async {
    await tester.pumpWidget(DemoApp(startShell: start));
    await tester.pump();
    final controller = tester
        .state<DemoAppState>(find.byType(DemoApp))
        .controller;

    expect(find.byType(VtTerminalView), findsOneWidget);
    expect(find.text('ghostty_dart · fake shell'), findsOneWidget);
    expect(_screen(controller), contains('demo@ghostty:~\$'));

    // The user's input reaches the shell through onOutput, and the shell's
    // output comes back through writeBytes.
    controller.sendText('echo round trip\r');
    await tester.pump();
    expect(_screen(controller), contains('\nround trip\n'));

    // onResize resizes the shell's terminal.
    controller.resize(100, 30);
    controller.sendText('top\r');
    await tester.pump();
    expect(controller.isAlternateScreen, isTrue);
    expect(shells.single.isTopRunning, isTrue);
    controller.sendText('q');
    await tester.pump();
    expect(controller.isAlternateScreen, isFalse);

    // OSC 0 from the program sets the app bar title.
    controller.sendText('title hello\r');
    await tester.pump();
    await tester.pump();
    expect(find.text('hello'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('offers a restart after the shell exits', (tester) async {
    await tester.pumpWidget(DemoApp(startShell: start));
    await tester.pump();
    final controller = tester
        .state<DemoAppState>(find.byType(DemoApp))
        .controller;
    expect(find.byIcon(Icons.refresh), findsNothing);

    controller.sendText('exit 2\r');
    await tester.pump();
    await tester.pump();
    expect(_screen(controller), contains('[process exited with code 2]'));
    expect(find.byIcon(Icons.refresh), findsOneWidget);

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();
    await tester.pump();
    expect(shells, hasLength(2));
    expect(find.byIcon(Icons.refresh), findsNothing);
    final screen = _screen(controller);
    expect(screen, isNot(contains('process exited')));
    expect(screen, contains('demo@ghostty:~\$'));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('input after the program exited is not forwarded', (
    tester,
  ) async {
    late _SpyShell spy;
    await tester.pumpWidget(
      DemoApp(
        startShell: (cols, rows) =>
            spy = _SpyShell(FakeShell(cols: cols, rows: rows)),
      ),
    );
    await tester.pump();
    final controller = tester
        .state<DemoAppState>(find.byType(DemoApp))
        .controller;
    controller.sendText('exit\r');
    await tester.pump();
    await tester.pump();
    final before = spy.writes;
    controller.sendText('ls\r');
    expect(spy.writes, before);

    await tester.pumpWidget(const SizedBox());
  });
}
