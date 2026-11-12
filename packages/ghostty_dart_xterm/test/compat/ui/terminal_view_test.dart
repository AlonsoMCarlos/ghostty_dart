// Ported from package:xterm 4.0.0 (test/src/terminal_view_test.dart).
// Copyright (c) 2020 xuty. MIT License, see test/compat/LICENSE.xterm.
// Changes: imports package:ghostty_dart_xterm/xterm.dart instead of
// package:xterm/xterm.dart; fixtures come from the shared
// test/compat/_fixture/ (verbatim copies of xterm's test/_fixture files); the mockito
// MockTerminalInputHandler is replaced by the hand-written
// _FakeInputHandler (records events, answers 'AAA'; `verify(call(any))`
// becomes `events` is not empty). xterm's goldens are pixels of xterm's own
// renderer and run on macOS only, so the four golden assertions are replaced
// by behaviour: the htop and colors tests check the rendered screen's text
// and cell colours and that the view painted without errors; the textScaler
// tests check that scaling the text by 2 halves the terminal's columns and
// rows, and that a parent MediaQuery's scaler gives the same grid as the same
// scaler passed explicitly. The htop test asserts on `CPU%`, not on the
// header's last word: the 800 px test window is narrower than htop's 80
// columns, as in xterm's golden. `Duration(seconds: 1)` became
// const (lints).

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart_xterm/xterm.dart';

import '../_fixture/_fixture.dart';

/// Replaces mockito's `MockTerminalInputHandler`: records every event and
/// answers 'AAA', as the original `when(...).thenAnswer` did.
final class _FakeInputHandler implements TerminalInputHandler {
  final events = <TerminalKeyboardEvent>[];

  @override
  String? call(TerminalKeyboardEvent event) {
    events.add(event);
    return 'AAA';
  }
}

/// The text of every line of the active screen (the last `viewHeight`
/// lines of the buffer).
List<String> _screenText(Terminal terminal) {
  final lines = terminal.buffer.lines;
  final first = lines.length - terminal.viewHeight;
  return [for (var i = first; i < lines.length; i++) lines[i].getText()];
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('htop golden test', (tester) async {
    final terminal = Terminal();
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: TerminalView(terminal))),
    );

    terminal.write(TestFixtures.htop_80x25_3s());
    await tester.pump();

    // Behaviour instead of xterm's golden (see the header).
    expect(tester.takeException(), isNull);
    expect(terminal.isUsingAltBuffer, isTrue);
    final screen = _screenText(terminal);
    final header = screen.indexWhere((line) => line.contains('PID USER'));
    expect(header, greaterThanOrEqualTo(0));
    expect(screen[header], contains('CPU%'));
    expect(screen.any((line) => line.contains('Load average:')), isTrue);
    // The header row is black on green (`ESC[30m ESC[42m`).
    final line = terminal
        .buffer
        .lines[terminal.buffer.lines.length - terminal.viewHeight + header];
    final pid = line.getText().indexOf('PID');
    expect(line.getForeground(pid), CellColor.named | NamedColor.black);
    expect(line.getBackground(pid), CellColor.named | NamedColor.green);
  });

  testWidgets('color golden test', (tester) async {
    final terminal = Terminal();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalView(terminal, textStyle: TerminalStyle(fontSize: 8)),
        ),
      ),
    );

    terminal.write(TestFixtures.colors().replaceAll('\n', '\r\n'));
    await tester.pump();

    // Behaviour instead of xterm's golden (see the header): the fixture's
    // first block prints each `\e[0;F;Bm` sample in its own colours.
    expect(tester.takeException(), isNull);
    const sample = r'\e[0;31;42m';
    final lines = terminal.buffer.lines;
    for (var i = 0; i < lines.length; i++) {
      final x = lines[i].getText().indexOf(sample);
      if (x < 0) continue;
      expect(lines[i].getForeground(x), CellColor.named | NamedColor.red);
      expect(lines[i].getBackground(x), CellColor.named | NamedColor.green);
      return;
    }
    fail('no line contains $sample:\n${terminal.buffer.getText()}');
  });

  group('TerminalView.readOnly', () {
    testWidgets('works', (tester) async {
      final terminalOutput = <String>[];
      final terminal = Terminal(onOutput: terminalOutput.add);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(terminal, readOnly: true, autofocus: true),
          ),
        ),
      );

      // https://github.com/flutter/flutter/issues/11181#issuecomment-314936646
      await tester.tap(find.byType(TerminalView));
      await tester.pump(const Duration(seconds: 1));

      binding.testTextInput.enterText('ls -al');
      await binding.idle();

      expect(terminalOutput.join(), isEmpty);
    });

    testWidgets('does not block input when false', (tester) async {
      final terminalOutput = <String>[];
      final terminal = Terminal(onOutput: terminalOutput.add);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(terminal, readOnly: false, autofocus: true),
          ),
        ),
      );

      // https://github.com/flutter/flutter/issues/11181#issuecomment-314936646
      await tester.tap(find.byType(TerminalView));
      await tester.pump(const Duration(seconds: 1));

      binding.testTextInput.enterText('ls -al');
      await binding.idle();

      expect(terminalOutput.join(), 'ls -al');
    });
  });

  group('TerminalView.focusNode', () {
    testWidgets('is not listened when terminal is disposed', (tester) async {
      final terminal = Terminal();

      final focusNode = FocusNode();

      final isActive = ValueNotifier(true);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: isActive,
              builder: (context, isActive, child) {
                if (!isActive) {
                  return Container();
                }
                return TerminalView(
                  terminal,
                  focusNode: focusNode,
                  autofocus: true,
                );
              },
            ),
          ),
        ),
      );

      // ignore: invalid_use_of_protected_member
      expect(focusNode.hasListeners, isTrue);

      isActive.value = false;
      await tester.pumpAndSettle();

      // ignore: invalid_use_of_protected_member
      expect(focusNode.hasListeners, isFalse);
    });

    testWidgets('does not dispose external focus node', (tester) async {
      final terminal = Terminal();

      final focusNode = FocusNode();

      final isActive = ValueNotifier(true);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: isActive,
              builder: (context, isActive, child) {
                if (!isActive) {
                  return Container();
                }
                return TerminalView(
                  terminal,
                  focusNode: focusNode,
                  autofocus: true,
                );
              },
            ),
          ),
        ),
      );

      isActive.value = false;
      await tester.pumpAndSettle();

      expect(() => focusNode.addListener(() {}), returnsNormally);
    });
  });

  group('TerminalController.pointerInputs', () {
    testWidgets('works', (tester) async {
      final output = <String>[];

      final terminal = Terminal(onOutput: output.add);

      // enable mouse reporting
      terminal.write('\x1b[?1000h');

      final terminalView = TerminalController(
        pointerInputs: PointerInputs.all(),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(terminal, controller: terminalView),
          ),
        ),
      );

      final pointer = TestPointer(1, PointerDeviceKind.mouse);

      await tester.sendEventToBinding(pointer.down(const Offset(1, 1)));

      await tester.pumpAndSettle();

      expect(output, isNotEmpty);
    });

    testWidgets('does not respond when disabled', (tester) async {
      final output = <String>[];

      final terminal = Terminal(onOutput: output.add);

      // enable mouse reporting
      terminal.write('\x1b[?1000h');

      final terminalView = TerminalController(
        pointerInputs: PointerInputs.none(),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(terminal, controller: terminalView),
          ),
        ),
      );

      final pointer = TestPointer(1, PointerDeviceKind.mouse);

      await tester.sendEventToBinding(pointer.down(const Offset(1, 1)));

      await tester.pumpAndSettle();

      expect(output, isEmpty);
    });
  });

  group('TerminalView.autofocus', () {
    testWidgets('works', (tester) async {
      final terminal = Terminal();
      final focusNode = FocusNode();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(terminal, autofocus: true, focusNode: focusNode),
          ),
        ),
      );

      expect(focusNode.hasFocus, isTrue);
    });

    testWidgets('works in hardwareKeyboardOnly mode', (tester) async {
      final terminal = Terminal();
      final focusNode = FocusNode();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              terminal,
              autofocus: true,
              focusNode: focusNode,
              hardwareKeyboardOnly: true,
            ),
          ),
        ),
      );

      expect(focusNode.hasFocus, isTrue);
    });
  });

  group('TerminalView.hardwareKeyboardOnly', () {
    testWidgets('works', (tester) async {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              terminal,
              autofocus: true,
              hardwareKeyboardOnly: true,
            ),
          ),
        ),
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);

      expect(output.join(), 'abc');
    });
  });

  group('TerminalView.textScaler', () {
    testWidgets('works', (tester) async {
      final terminal = Terminal();

      final textScaler = ValueNotifier(TextScaler.linear(1.0));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<TextScaler>(
              valueListenable: textScaler,
              builder: (context, textScaler, child) {
                return TerminalView(terminal, textScaler: textScaler);
              },
            ),
          ),
        ),
      );

      terminal.write('Hello World');
      await tester.pump();

      // Behaviour instead of xterm's golden (see the header).
      final cols1x = terminal.viewWidth;
      final rows1x = terminal.viewHeight;

      textScaler.value = TextScaler.linear(2.0);
      await tester.pump();

      expect(terminal.viewWidth, closeTo(cols1x / 2, 1));
      expect(terminal.viewHeight, closeTo(rows1x / 2, 1));
      expect(terminal.buffer.getText(), contains('Hello World'));
    });

    testWidgets('can obtain textScaler from parent', (tester) async {
      final terminal = Terminal();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
              child: TerminalView(terminal),
            ),
          ),
        ),
      );

      terminal.write('Hello World');
      await tester.pump();

      // Behaviour instead of xterm's golden (see the header): the same
      // grid as an explicit `textScaler: TextScaler.linear(2.0)` under the
      // same parent MediaQuery minus its scaler (the bare MediaQueryData
      // also sets devicePixelRatio 1, and our cells snap to device pixels,
      // so the reference must share it), in a fresh view state (key).
      final reference = Terminal();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(),
              child: TerminalView(
                reference,
                key: UniqueKey(),
                textScaler: const TextScaler.linear(2.0),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(terminal.viewWidth, reference.viewWidth);
      expect(terminal.viewHeight, reference.viewHeight);

      // And the scaler did apply: half the columns of the unscaled grid.
      final unscaled = Terminal();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(),
              child: TerminalView(unscaled, key: UniqueKey()),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(terminal.viewWidth, closeTo(unscaled.viewWidth / 2, 1));
      expect(terminal.buffer.getText(), contains('Hello World'));
    });
  });

  group('TerminalView.inputHandler', () {
    testWidgets('works', (tester) async {
      final terminalOutput = <String>[];
      final terminal = Terminal(onOutput: terminalOutput.add);

      await tester.pumpWidget(
        MaterialApp(home: TerminalView(terminal, autofocus: true)),
      );

      await tester.tap(find.byType(TerminalView));
      await tester.pump(const Duration(seconds: 1));

      await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyD);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyD);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.control);

      await tester.pumpAndSettle();

      expect(terminalOutput.join(), '\x04');
    });

    testWidgets('can convert text input to key events', (tester) async {
      final inputHandler = _FakeInputHandler();

      final terminalOutput = <String>[];
      final terminal = Terminal(
        inputHandler: inputHandler,
        onOutput: terminalOutput.add,
      );

      await tester.pumpWidget(
        MaterialApp(home: TerminalView(terminal, autofocus: true)),
      );

      await tester.tap(find.byType(TerminalView));
      await tester.pump(const Duration(seconds: 1));

      binding.testTextInput.enterText('c');
      await binding.idle();

      await tester.pumpAndSettle();

      expect(inputHandler.events, isNotEmpty);
      expect(terminalOutput.join(), 'AAA');
    });
  });

  group('TerminalView.simulateScroll', () {
    testWidgets('works', (tester) async {
      final terminalOutput = <String>[];
      final terminal = Terminal(onOutput: terminalOutput.add);
      terminal.useAltBuffer();

      await tester.pumpWidget(
        MaterialApp(
          home: TerminalView(terminal, autofocus: true, simulateScroll: true),
        ),
      );

      await tester.drag(find.byType(TerminalView), const Offset(0, -100));

      expect(terminalOutput.join(), contains('\x1B[B'));
    });

    testWidgets('does nothing when disabled', (tester) async {
      final terminalOutput = <String>[];
      final terminal = Terminal(onOutput: terminalOutput.add);
      terminal.useAltBuffer();

      await tester.pumpWidget(
        MaterialApp(
          home: TerminalView(terminal, autofocus: true, simulateScroll: false),
        ),
      );

      await tester.drag(find.byType(TerminalView), const Offset(0, -100));

      expect(terminalOutput.join(), isEmpty);
    });
  });
}
