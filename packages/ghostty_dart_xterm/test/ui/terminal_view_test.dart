// Own tests of the adapter's TerminalView (ADR 0013, plan contract 4.3):
// it drives ghostty_dart_flutter's VtTerminalView over the Terminal's
// engine, routes keys, text and mouse reports through custom handlers,
// gates reports with TerminalController.pointerInputs, and mirrors the
// controller's selection and highlights.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart/ghostty_dart.dart'
    show GridPoint, TerminalMode, VtCursorStyle;
import 'package:ghostty_dart_flutter/ghostty_dart_flutter.dart';
import 'package:ghostty_dart_xterm/src/internal/terminal_internals.dart';
import 'package:ghostty_dart_xterm/xterm.dart';

/// 10 x 10 px cells in the test font.
const _style = TerminalStyle(
  fontFamily: 'FlutterTest',
  fontSize: 10,
  height: 1,
  fontFamilyFallback: [],
);

/// A terminal that records its output, disposed after the test.
(Terminal, List<String>) _terminal({
  TerminalInputHandler? inputHandler = defaultInputHandler,
  TerminalMouseHandler? mouseHandler = defaultMouseHandler,
}) {
  final output = <String>[];
  final terminal = Terminal(
    onOutput: output.add,
    inputHandler: inputHandler,
    mouseHandler: mouseHandler,
  );
  addTearDown(terminal.dispose);
  return (terminal, output);
}

/// Pumps [view] in a 200 x 100 window (20 x 10 cells).
Future<void> _pump(WidgetTester tester, Widget view) async {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = const Size(200, 100);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: view)));
  await tester.pump();
}

VtTerminalController _vt(Terminal terminal) =>
    terminalInternals(terminal).vtController;

VtTerminalView _vtView(WidgetTester tester) =>
    tester.widget<VtTerminalView>(find.byType(VtTerminalView));

/// The centre of viewport cell [col], [row].
Offset _cell(int col, int row) => Offset(col * 10 + 5, row * 10 + 5);

/// Records keyboard events and answers with [answer].
final class _RecordingInputHandler implements TerminalInputHandler {
  _RecordingInputHandler(this.answer);

  final String? Function(TerminalKeyboardEvent event) answer;
  final events = <TerminalKeyboardEvent>[];

  @override
  String? call(TerminalKeyboardEvent event) {
    events.add(event);
    return answer(event);
  }
}

/// Records mouse events and answers with a marker.
final class _RecordingMouseHandler implements TerminalMouseHandler {
  final events = <TerminalMouseEvent>[];

  @override
  String? call(TerminalMouseEvent event) {
    events.add(event);
    return '<${event.button.name}:${event.buttonState.name}>';
  }
}

/// Answers clipboard reads with [paste]; returns the copied texts.
List<String> _mockClipboard(WidgetTester tester, {String paste = ''}) {
  final copied = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      switch (call.method) {
        case 'Clipboard.getData':
          return <String, Object?>{'text': paste};
        case 'Clipboard.setData':
          copied.add(
            (call.arguments as Map<Object?, Object?>)['text']! as String,
          );
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return copied;
}

void main() {
  group('TerminalView', () {
    testWidgets('shows the terminal, sized to the view', (tester) async {
      final (terminal, _) = _terminal();
      await _pump(tester, TerminalView(terminal, textStyle: _style));
      terminal.write('hello');
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(terminal.viewWidth, 20);
      expect(terminal.viewHeight, 10);
      expect(terminal.buffer.lines[0].getText(), startsWith('hello'));
      expect(terminalInternals(terminal).viewDevicePixelRatio, 1);
      final state = tester.state<TerminalViewState>(find.byType(TerminalView));
      expect(state.cursorRect, const Rect.fromLTWH(50, 0, 10, 10));
      expect(state.globalCursorRect, const Rect.fromLTWH(50, 0, 10, 10));
    });

    testWidgets('maps the parameters onto the view', (tester) async {
      final (terminal, _) = _terminal();
      await _pump(
        tester,
        TerminalView(
          terminal,
          textStyle: _style,
          padding: const EdgeInsets.all(5),
          cursorType: TerminalCursorType.verticalBar,
          backgroundOpacity: 0.5,
          readOnly: true,
          alwaysShowCursor: true,
        ),
      );
      final view = _vtView(tester);
      expect(view.textStyle?.fontFamily, 'FlutterTest');
      expect(view.textStyle?.fontSize, 10);
      expect(view.padding, const EdgeInsets.all(5));
      expect(view.cursorStyle, VtCursorStyle.bar);
      expect(view.backgroundOpacity, 0.5);
      expect(view.readOnly, isTrue);
      expect(view.alwaysShowCursor, isTrue);
      // xterm's defaults, not the widget's own.
      expect(view.keyboardType, TextInputType.emailAddress);
      expect(view.deleteDetection, isFalse);
      expect(view.mouseCursor, SystemMouseCursors.text);
      expect(view.shortcuts, same(defaultTerminalShortcuts));
      expect(view.rectangleSelection, isFalse);
    });

    testWidgets('applies the theme to the terminal', (tester) async {
      final (terminal, _) = _terminal();
      await _pump(
        tester,
        TerminalView(
          terminal,
          textStyle: _style,
          theme: TerminalThemes.whiteOnBlack,
        ),
      );
      final theme = _vt(terminal).theme;
      expect(theme.background, TerminalThemes.whiteOnBlack.background);
      expect(theme.foreground, TerminalThemes.whiteOnBlack.foreground);
      expect(theme.cursor, TerminalThemes.whiteOnBlack.cursor);
      expect(theme.brightCyan, TerminalThemes.whiteOnBlack.brightCyan);
      expect(theme.searchHitForeground, const Color(0XFF000000));

      await _pump(
        tester,
        TerminalView(
          terminal,
          textStyle: _style,
          theme: TerminalThemes.defaultTheme,
        ),
      );
      expect(
        _vt(terminal).theme.background,
        TerminalThemes.defaultTheme.background,
      );
    });

    testWidgets('simulateScroll sets the alternate scroll default', (
      tester,
    ) async {
      final (terminal, _) = _terminal();
      await _pump(
        tester,
        TerminalView(terminal, textStyle: _style, simulateScroll: false),
      );
      expect(
        _vt(terminal).isModeEnabled(TerminalMode.mouseAlternateScroll),
        isFalse,
      );
    });

    testWidgets('disposing the view keeps the terminal and its controller', (
      tester,
    ) async {
      final (terminal, output) = _terminal();
      final controller = TerminalController();
      addTearDown(controller.dispose);
      await _pump(
        tester,
        TerminalView(terminal, textStyle: _style, controller: controller),
      );
      await tester.pumpWidget(const SizedBox());
      expect(terminalInternals(terminal).viewDevicePixelRatio, isNull);
      terminal.write('still alive');
      expect(terminal.buffer.lines[0].getText(), startsWith('still alive'));
      terminal.textInput('x');
      expect(output, ['x']);
      // The controller is still usable.
      controller.addListener(() {});
      expect(controller.selection, isNull);
    });
  });

  group('TerminalView keys', () {
    testWidgets('the default handler encodes with libghostty-vt', (
      tester,
    ) async {
      final (terminal, output) = _terminal();
      await _pump(
        tester,
        TerminalView(terminal, textStyle: _style, autofocus: true),
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
      await tester.pump();
      expect(output.join(), '\x04');
    });

    testWidgets('hardwareKeyboardOnly encodes printable keys', (tester) async {
      final (terminal, output) = _terminal();
      await _pump(
        tester,
        TerminalView(
          terminal,
          textStyle: _style,
          autofocus: true,
          hardwareKeyboardOnly: true,
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.pump();
      expect(output.join(), 'abc');
    });

    testWidgets('a custom handler gets the keys, with modifiers', (
      tester,
    ) async {
      final handler = _RecordingInputHandler(
        (event) => event.key == TerminalKey.keyD && event.ctrl ? 'X' : null,
      );
      final (terminal, output) = _terminal(inputHandler: handler);
      await _pump(
        tester,
        TerminalView(terminal, textStyle: _style, autofocus: true),
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
      await tester.pump();
      expect(output.join(), 'X');
      final event = handler.events.single;
      expect(event.key, TerminalKey.keyD);
      expect(event.ctrl, isTrue);
      expect(event.shift, isFalse);
      expect(event.state, same(terminal));
      expect(event.altBuffer, isFalse);

      // A key the handler does not answer is not sent.
      await tester.sendKeyEvent(LogicalKeyboardKey.f5);
      await tester.pump();
      expect(output.join(), 'X');
      expect(handler.events.last.key, TerminalKey.f5);
    });

    testWidgets('a custom handler sees committed text as keys', (tester) async {
      final handler = _RecordingInputHandler((_) => 'AAA');
      final (terminal, output) = _terminal(inputHandler: handler);
      await _pump(
        tester,
        TerminalView(terminal, textStyle: _style, autofocus: true),
      );
      await tester.tap(find.byType(TerminalView));
      await tester.pump();
      tester.testTextInput.enterText('c');
      await tester.pump();
      expect(output.join(), 'AAA');
      expect(handler.events.last.key, TerminalKey.keyC);
      expect(handler.events.last.ctrl, isFalse);
    });

    testWidgets('text the custom handler does not answer is sent as text', (
      tester,
    ) async {
      final handler = _RecordingInputHandler((_) => null);
      final (terminal, output) = _terminal(inputHandler: handler);
      await _pump(
        tester,
        TerminalView(terminal, textStyle: _style, autofocus: true),
      );
      await tester.tap(find.byType(TerminalView));
      await tester.pump();
      tester.testTextInput.enterText('ls');
      await tester.pump();
      expect(output.join(), 'ls');
    });

    testWidgets('without a text input connection, printable keys are '
        'inserted through the custom handler', (tester) async {
      final handler = _RecordingInputHandler((_) => null);
      final (terminal, output) = _terminal(inputHandler: handler);
      await _pump(
        tester,
        TerminalView(
          terminal,
          textStyle: _style,
          autofocus: true,
          hardwareKeyboardOnly: true,
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.pump();
      expect(output.join(), 'a');
      // Once with the key event, once as inserted text (xterm does both).
      expect(handler.events.map((e) => e.key), [
        TerminalKey.keyA,
        TerminalKey.keyA,
      ]);
    });
  });

  group('TerminalView mouse', () {
    Future<List<String>> pressWith(
      WidgetTester tester,
      TerminalController controller,
    ) async {
      final (terminal, output) = _terminal();
      terminal.write('\x1b[?1000h');
      await _pump(
        tester,
        TerminalView(terminal, textStyle: _style, controller: controller),
      );
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.down(_cell(1, 1)));
      await tester.sendEventToBinding(pointer.up());
      await tester.pump();
      return output;
    }

    testWidgets('taps are reported by default and with all inputs', (
      tester,
    ) async {
      final controller = TerminalController();
      addTearDown(controller.dispose);
      expect(await pressWith(tester, controller), isNotEmpty);
    });

    testWidgets('PointerInputs.none() stops reports', (tester) async {
      final controller = TerminalController(
        pointerInputs: const PointerInputs.none(),
      );
      addTearDown(controller.dispose);
      expect(await pressWith(tester, controller), isEmpty);
    });

    testWidgets('suspendPointerInput stops reports', (tester) async {
      final controller = TerminalController(suspendPointerInput: true);
      addTearDown(controller.dispose);
      expect(await pressWith(tester, controller), isEmpty);
    });

    testWidgets('hover motion is reported only with PointerInput.move', (
      tester,
    ) async {
      final controller = TerminalController();
      addTearDown(controller.dispose);
      final (terminal, output) = _terminal();
      terminal.write('\x1b[?1003h\x1b[?1006h');
      await _pump(
        tester,
        TerminalView(terminal, textStyle: _style, controller: controller),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: _cell(0, 0));
      addTearDown(mouse.removePointer);
      await mouse.moveTo(_cell(2, 2));
      await tester.pump();
      expect(output, isEmpty);
      controller.setPointerInputs(const PointerInputs.all());
      await mouse.moveTo(_cell(3, 2));
      await tester.pump();
      expect(output.join(), '\x1b[<35;4;3M');
    });

    testWidgets('a custom mouse handler gets buffer positions', (tester) async {
      final handler = _RecordingMouseHandler();
      final (terminal, output) = _terminal(mouseHandler: handler);
      // 15 lines: 5 in the scrollback, then mouse tracking.
      for (var i = 0; i < 14; i++) {
        terminal.write('line $i\r\n');
      }
      await _pump(tester, TerminalView(terminal, textStyle: _style));
      terminal.write('\x1b[?1000h');
      await tester.pump();
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.down(_cell(2, 1)));
      await tester.sendEventToBinding(pointer.up());
      await tester.pump();
      expect(output.join(), '<left:down><left:up>');
      final scrollback = terminal.buffer.height - terminal.viewHeight;
      expect(handler.events.first.position, CellOffset(2, scrollback + 1));
      expect(handler.events.first.state, same(terminal));
    });
  });

  group('TerminalView with a TerminalController', () {
    Future<(Terminal, TerminalController)> pumpWithController(
      WidgetTester tester,
    ) async {
      final (terminal, _) = _terminal();
      final controller = TerminalController();
      addTearDown(controller.dispose);
      await _pump(
        tester,
        TerminalView(terminal, textStyle: _style, controller: controller),
      );
      return (terminal, controller);
    }

    testWidgets('setSelection selects on the screen', (tester) async {
      final (terminal, controller) = await pumpWithController(tester);
      controller.setSelection(
        terminal.buffer.createAnchor(0, 0),
        terminal.buffer.createAnchor(2, 2),
      );
      final vt = _vt(terminal);
      expect(vt.selection, isNotNull);
      expect(vt.selection!.isRectangle, isFalse);
      final range = controller.selection!;
      expect(range, isA<BufferRangeLine>());
      expect(range.begin, const CellOffset(0, 0));
      expect(range.end, const CellOffset(2, 2));

      controller.setSelectionMode(SelectionMode.block);
      expect(controller.selection, isA<BufferRangeBlock>());
      expect(vt.selection!.isRectangle, isTrue);
      await tester.pump();
      expect(_vtView(tester).rectangleSelection, isTrue);

      controller.clearSelection();
      expect(controller.selection, isNull);
      expect(vt.selection, isNull);
    });

    testWidgets('a mouse selection shows on the controller', (tester) async {
      final (terminal, controller) = await pumpWithController(tester);
      terminal.write('hello world');
      await tester.pump();
      var notified = 0;
      controller.addListener(() => notified++);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: _cell(0, 0));
      addTearDown(mouse.removePointer);
      await mouse.down(_cell(0, 0));
      await mouse.moveTo(_cell(4, 0) + const Offset(3, 0));
      await mouse.up();
      await tester.pump();
      expect(notified, greaterThan(0));
      final range = controller.selection!;
      expect(range, isA<BufferRangeLine>());
      expect(range.begin, const CellOffset(0, 0));
      expect(range.end, const CellOffset(5, 0));
      expect(terminal.buffer.getText(range), 'hello');
    });

    testWidgets('a mouse selection replaces the anchors of setSelection', (
      tester,
    ) async {
      final (terminal, controller) = await pumpWithController(tester);
      terminal.write('hello world');
      await tester.pump();
      final base = terminal.buffer.createAnchor(0, 0);
      final extent = terminal.buffer.createAnchor(2, 0);
      controller.setSelection(base, extent);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: _cell(6, 0));
      addTearDown(mouse.removePointer);
      await mouse.down(_cell(6, 0));
      await mouse.moveTo(_cell(10, 0) + const Offset(3, 0));
      await mouse.up();
      await tester.pump();
      expect(terminal.buffer.getText(controller.selection), 'world');
      // The controller disposed the anchors it owned, as xterm does.
      expect(base.attached, isFalse);
      expect(extent.attached, isFalse);
    });

    testWidgets('highlights are painted by the view', (tester) async {
      final (terminal, _) = _terminal();
      final controller = TerminalController();
      addTearDown(controller.dispose);
      // Made before the view shows the controller.
      final early = controller.highlight(
        p1: terminal.buffer.createAnchor(1, 0),
        p2: terminal.buffer.createAnchor(4, 0),
        color: const Color(0x80FFFF00),
      );
      await _pump(
        tester,
        TerminalView(terminal, textStyle: _style, controller: controller),
      );
      final vt = _vt(terminal);
      final native = vt.highlights.single;
      // xterm's end is exclusive, the widget's inclusive.
      expect(native.start, const GridPoint.screen(1, 0));
      expect(native.end, const GridPoint.screen(3, 0));
      expect(native.color, const Color(0x80FFFF00));

      // An end at column 0 ends on the previous row.
      final wrapped = controller.highlight(
        p1: terminal.buffer.createAnchor(5, 1),
        p2: terminal.buffer.createAnchor(0, 2),
        color: const Color(0x8000FF00),
      );
      expect(vt.highlights.last.end, const GridPoint.screen(19, 1));
      // An empty range paints nothing.
      final empty = controller.highlight(
        p1: terminal.buffer.createAnchor(3, 3),
        p2: terminal.buffer.createAnchor(3, 3),
        color: const Color(0x800000FF),
      );
      expect(controller.highlights, hasLength(3));
      expect(vt.highlights, hasLength(2));

      early.dispose();
      wrapped.dispose();
      empty.dispose();
      expect(controller.highlights, isEmpty);
      expect(vt.highlights, isEmpty);
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('TerminalView shortcuts', () {
    testWidgets('copy, paste and select all (xterm defaults)', (tester) async {
      final copied = _mockClipboard(tester, paste: 'pasted');
      final (terminal, output) = _terminal();
      final controller = TerminalController();
      addTearDown(controller.dispose);
      await _pump(
        tester,
        TerminalView(
          terminal,
          textStyle: _style,
          controller: controller,
          autofocus: true,
        ),
      );
      terminal.write('hello world');
      controller.setSelection(
        terminal.buffer.createAnchor(0, 0),
        terminal.buffer.createAnchor(5, 0),
      );
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
      await tester.pump();
      expect(copied, ['hello']);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.pump();
      expect(output.join(), 'pasted');

      controller.clearSelection();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
      await tester.pump();
      expect(terminal.buffer.getText(controller.selection), contains('hello'));
      // Ctrl+A did not reach the program.
      expect(output.join(), 'pasted');
    });

    testWidgets('a custom shortcut map replaces the defaults', (tester) async {
      final (terminal, output) = _terminal();
      await _pump(
        tester,
        TerminalView(
          terminal,
          textStyle: _style,
          autofocus: true,
          shortcuts: const {},
        ),
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
      await tester.pump();
      expect(output.join(), '\x01');
    });
  });

  group('TerminalView taps', () {
    testWidgets('onTapUp gets a buffer position', (tester) async {
      final (terminal, _) = _terminal();
      for (var i = 0; i < 14; i++) {
        terminal.write('line $i\r\n');
      }
      final taps = <CellOffset>[];
      await _pump(
        tester,
        TerminalView(
          terminal,
          textStyle: _style,
          onTapUp: (_, offset) => taps.add(offset),
        ),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: _cell(3, 2));
      addTearDown(mouse.removePointer);
      await mouse.down(_cell(3, 2));
      await mouse.up();
      await tester.pump(const Duration(milliseconds: 500));
      final scrollback = terminal.buffer.height - terminal.viewHeight;
      expect(taps, [CellOffset(3, scrollback + 2)]);
    });
  });
}
