// Tests of VtTerminalView's hooks and options for apps and adapters
// (contract 4.1 of the xterm adapter plan, ADR 0013): the key, text and
// mouse hooks, the mouse report filter, select all, word boundaries,
// rectangle selection, and the cursor rectangle.

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart_flutter/ghostty_dart_flutter.dart';
import 'package:ghostty_dart_flutter/src/render/terminal_render.dart';
import 'package:ghostty_dart_flutter/src/seams/controller_seams.dart';

import 'view_harness.dart';

/// Pumps a view with the hooks under test in a 200 x 100 window (20 x 10
/// cells of 10 x 10 px).
Future<ViewHarness> pumpHooked(
  WidgetTester tester, {
  VtTerminalKeyHook? onTerminalKey,
  VtTerminalTextHook? onTerminalText,
  VtTerminalMouseFilter? mouseReportFilter,
  VtTerminalMouseHook? onTerminalMouse,
  List<int>? wordBoundaryCodepoints,
  bool rectangleSelection = false,
  bool readOnly = false,
  bool hardwareKeyboardOnly = false,
  Map<ShortcutActivator, Intent>? shortcuts,
  void Function(TapUpDetails, GridPoint)? onTapUp,
  EdgeInsets padding = EdgeInsets.zero,
}) async {
  setWindow(tester);
  final h = createViewHarness(tester);
  await h.pumpView(
    VtTerminalView(
      key: h.viewKey,
      controller: h.controller,
      textStyle: viewStyle,
      autofocus: true,
      readOnly: readOnly,
      hardwareKeyboardOnly: hardwareKeyboardOnly,
      shortcuts: shortcuts,
      onTapUp: onTapUp,
      padding: padding,
      onTerminalKey: onTerminalKey,
      onTerminalText: onTerminalText,
      mouseReportFilter: mouseReportFilter,
      onTerminalMouse: onTerminalMouse,
      wordBoundaryCodepoints: wordBoundaryCodepoints,
      rectangleSelection: rectangleSelection,
    ),
  );
  await tester.pump();
  return h;
}

/// Sends `TextInputClient.updateEditingStateWithDeltas` with one delta.
Future<void> sendDelta(
  WidgetTester tester, {
  required String oldText,
  required String text,
  required int start,
  required int end,
}) async {
  final client =
      tester.testTextInput.log
              .lastWhere((call) => call.method == 'TextInput.setClient')
              .arguments
          as List<Object?>;
  final length = oldText.length - (end - start) + text.length;
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    SystemChannels.textInput.name,
    SystemChannels.textInput.codec.encodeMethodCall(
      MethodCall('TextInputClient.updateEditingStateWithDeltas', <Object?>[
        client[0],
        <String, Object?>{
          'deltas': [
            {
              'oldText': oldText,
              'deltaText': text,
              'deltaStart': start,
              'deltaEnd': end,
              'selectionBase': length,
              'selectionExtent': length,
              'selectionAffinity': 'TextAffinity.downstream',
              'selectionIsDirectional': false,
              'composingBase': -1,
              'composingExtent': -1,
            },
          ],
        },
      ]),
    ),
    (_) {},
  );
  await tester.pump();
}

/// A mouse at [at], removed after the test (one per test: the test
/// mouse is a single device).
Future<TestGesture> mouseAt(WidgetTester tester, Offset at) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: at);
  addTearDown(gesture.removePointer);
  return gesture;
}

/// Clicks with [mouse] at [at] at [time].
Future<void> click(
  TestGesture mouse,
  Offset at, {
  Duration time = Duration.zero,
}) async {
  await mouse.down(at, timeStamp: time);
  await mouse.up(timeStamp: time);
}

/// A double click at [at].
Future<void> doubleClick(
  WidgetTester tester,
  TestGesture mouse,
  Offset at, {
  Duration t0 = const Duration(seconds: 10),
}) async {
  await click(mouse, at, time: t0);
  await click(mouse, at, time: t0 + const Duration(milliseconds: 100));
  await tester.pump();
}

void main() {
  group('onTerminalKey', () {
    testWidgets('a string replaces the key; null encodes it', (tester) async {
      final calls = <(KeyEvent, KeyModifiers)>[];
      final h = await pumpHooked(
        tester,
        onTerminalKey: (event, modifiers) {
          calls.add((event, modifiers));
          return event.logicalKey == LogicalKeyboardKey.f1 ? 'help' : null;
        },
      );
      expect(await tester.sendKeyDownEvent(LogicalKeyboardKey.f1), isTrue);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.f1);
      expect(h.takeOutput(), 'help');
      await tapKey(tester, LogicalKeyboardKey.enter);
      expect(h.takeOutput(), '\r');
      // Presses only: never a release.
      expect(calls.map((c) => c.$1.runtimeType), [KeyDownEvent, KeyDownEvent]);
      expect(calls.map((c) => c.$1.logicalKey), [
        LogicalKeyboardKey.f1,
        LogicalKeyboardKey.enter,
      ]);
      expect(calls.first.$2, KeyModifiers.none);
    });

    testWidgets('an empty string sends nothing and leaves the key', (
      tester,
    ) async {
      final h = await pumpHooked(tester, onTerminalKey: (_, _) => '');
      expect(await tester.sendKeyDownEvent(LogicalKeyboardKey.enter), isFalse);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
      expect(h.takeOutput(), '');
    });

    testWidgets('modifiers include held and latched ones; a consumed key '
        'clears the latch', (tester) async {
      final mods = <KeyModifiers>[];
      final h = await pumpHooked(
        tester,
        onTerminalKey: (event, modifiers) {
          mods.add(modifiers);
          return event.logicalKey == LogicalKeyboardKey.keyX ? 'x!' : null;
        },
      );
      final latch = ControllerSeams(h.controller).latchedModifiers;
      latch.value = KeyModifiers.alt;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tapKey(tester, LogicalKeyboardKey.keyX, character: 'x');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(mods.single.hasCtrl, isTrue);
      expect(mods.single.hasAlt, isTrue);
      expect(latch.value, KeyModifiers.none);
      expect(h.takeOutput(), 'x!');
    });

    testWidgets('repeats follow their press', (tester) async {
      final calls = <Type>[];
      final h = await pumpHooked(
        tester,
        onTerminalKey: (event, _) {
          calls.add(event.runtimeType);
          return event.logicalKey == LogicalKeyboardKey.f2 ? '2' : null;
        },
      );
      // A consumed press: its repeats come to the hook too.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.f2);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.f2);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.f2);
      expect(calls, [KeyDownEvent, KeyRepeatEvent]);
      expect(h.takeOutput(), '22');
      // An encoded press: its repeats go straight to the encoder.
      calls.clear();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
      expect(calls, [KeyDownEvent]);
      expect(h.takeOutput(), '\r\r');
    });

    testWidgets('the replacement waits for text the platform still owes', (
      tester,
    ) async {
      final h = await pumpHooked(
        tester,
        onTerminalKey: (event, _) =>
            event.logicalKey == LogicalKeyboardKey.enter ? '<enter>' : null,
      );
      // `a` is left to the platform text input; its text comes later.
      await tapKey(tester, LogicalKeyboardKey.keyA, character: 'a');
      await tapKey(tester, LogicalKeyboardKey.enter);
      expect(h.takeOutput(), '');
      await sendDelta(tester, oldText: '  ', text: 'a', start: 2, end: 2);
      expect(h.takeOutput(), 'a<enter>');
    });

    testWidgets('soft-keyboard Backspace and IME actions are synthesised '
        'presses', (tester) async {
      final calls = <KeyEvent>[];
      final h = await pumpHooked(
        tester,
        onTerminalKey: (event, _) {
          calls.add(event);
          return event.logicalKey == LogicalKeyboardKey.backspace ? 'BS' : null;
        },
      );
      // The keyboard deletes the hidden sentinel: a Backspace.
      await sendDelta(tester, oldText: '  ', text: '', start: 1, end: 2);
      expect(h.takeOutput(), 'BS');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(h.takeOutput(), '\r'); // null: encoded as today
      expect(calls.map((e) => e.logicalKey), [
        LogicalKeyboardKey.backspace,
        LogicalKeyboardKey.enter,
      ]);
      expect(calls.map((e) => e.physicalKey), [
        PhysicalKeyboardKey.backspace,
        PhysicalKeyboardKey.enter,
      ]);
      for (final event in calls) {
        expect(event, isA<KeyDownEvent>());
        expect(event.synthesized, isTrue);
        expect(event.timeStamp, Duration.zero);
      }
    });

    testWidgets('readOnly views never call it', (tester) async {
      var calls = 0;
      final h = await pumpHooked(
        tester,
        readOnly: true,
        onTerminalKey: (_, _) {
          calls++;
          return 'x';
        },
      );
      await tapKey(tester, LogicalKeyboardKey.enter);
      expect(calls, 0);
      expect(h.takeOutput(), '');
    });

    testWidgets('shortcuts and onKeyEvent come first', (tester) async {
      var calls = 0;
      setWindow(tester);
      final h = createViewHarness(tester);
      await h.pumpView(
        VtTerminalView(
          controller: h.controller,
          textStyle: viewStyle,
          autofocus: true,
          onKeyEvent: (_, event) => event.logicalKey == LogicalKeyboardKey.f3
              ? KeyEventResult.handled
              : KeyEventResult.ignored,
          onTerminalKey: (_, _) {
            calls++;
            return null;
          },
        ),
      );
      await tester.pump();
      await tapKey(tester, LogicalKeyboardKey.f3);
      expect(calls, 0);
      await tapKey(tester, LogicalKeyboardKey.f4);
      expect(calls, 1);
    });
  });

  group('onTerminalText', () {
    testWidgets('replaces committed text; null keeps it; empty drops it', (
      tester,
    ) async {
      final seen = <String>[];
      final h = await pumpHooked(
        tester,
        onTerminalText: (text) {
          seen.add(text);
          return switch (text) {
            'ls' => 'LS',
            'drop' => '',
            _ => null,
          };
        },
      );
      await sendDelta(tester, oldText: '  ', text: 'ls', start: 2, end: 2);
      expect(h.takeOutput(), 'LS');
      await sendDelta(tester, oldText: '  ', text: 'cd', start: 2, end: 2);
      expect(h.takeOutput(), 'cd');
      await sendDelta(tester, oldText: '  ', text: 'drop', start: 2, end: 2);
      expect(h.takeOutput(), '');
      expect(seen, ['ls', 'cd', 'drop']);
    });

    testWidgets('pastes do not go through it', (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => call.method == 'Clipboard.getData'
            ? <String, Object?>{'text': 'pasted'}
            : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      var calls = 0;
      final h = await pumpHooked(
        tester,
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.f5): PasteTextIntent(
            SelectionChangedCause.keyboard,
          ),
        },
        onTerminalText: (_) {
          calls++;
          return '';
        },
      );
      await tapKey(tester, LogicalKeyboardKey.f5);
      await tester.pump();
      expect(h.takeOutput(), 'pasted');
      expect(calls, 0);
    });
  });

  group('mouseReportFilter and onTerminalMouse', () {
    testWidgets('a refused press selects instead, and taps reach onTapUp', (
      tester,
    ) async {
      final seen = <VtMouseEvent>[];
      final taps = <GridPoint>[];
      final h = await pumpHooked(
        tester,
        onTapUp: (_, cell) => taps.add(cell),
        mouseReportFilter: (event) {
          seen.add(event);
          return false;
        },
      );
      h.controller.write('hello world\x1b[?1002h\x1b[?1006h');
      await tester.pump();
      final mouse = await mouseAt(tester, h.cell(0, 0));
      await mouse.down(h.cell(0, 0));
      await mouse.moveTo(h.cell(4, 0) + const Offset(3, 0));
      await mouse.up();
      await tester.pump();
      expect(h.controller.selectedText, 'hello');
      expect(h.takeOutput(), '');
      // Only the press was asked about; the drag was a selection.
      expect(seen, hasLength(1));
      expect(seen.single.action, MouseAction.press);
      expect(seen.single.button, MouseButton.left);
      // A click: onTapUp, as if untracked.
      await click(mouse, h.cell(2, 3));
      await tester.pump();
      expect(taps, [const GridPoint.viewport(2, 3)]);
      // A touch tap too.
      await tester.tapAt(h.cell(5, 5));
      await tester.pump();
      expect(taps.last, const GridPoint.viewport(5, 5));
      expect(h.takeOutput(), '');
    });

    testWidgets('an allowed press is reported, then its release even when '
        'the filter changed its mind', (tester) async {
      var allow = true;
      final h = await pumpHooked(tester, mouseReportFilter: (event) => allow);
      h.controller.write('\x1b[?1002h\x1b[?1006h');
      final drag = await tester.startGesture(
        h.cell(1, 1),
        kind: PointerDeviceKind.mouse,
      );
      expect(h.takeOutput(), '\x1b[<0;2;2M');
      allow = false;
      await drag.moveTo(h.cell(3, 1));
      expect(h.takeOutput(), ''); // motion refused
      await drag.up();
      expect(h.takeOutput(), '\x1b[<0;4;2m'); // the release still goes
      expect(h.controller.selection, isNull);
    });

    testWidgets('a refused second button is not reported, nor its release', (
      tester,
    ) async {
      final h = await pumpHooked(
        tester,
        mouseReportFilter: (event) => event.button != MouseButton.right,
      );
      h.controller.write('\x1b[?1000h\x1b[?1006h');
      final at = h.cell(1, 1);
      final pointer = TestPointer(9, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.down(at));
      expect(h.takeOutput(), '\x1b[<0;2;2M');
      await tester.sendEventToBinding(
        pointer.move(at, buttons: kPrimaryButton | kSecondaryButton),
      );
      await tester.sendEventToBinding(
        pointer.move(at, buttons: kPrimaryButton),
      );
      expect(h.takeOutput(), '');
      await tester.sendEventToBinding(pointer.up());
      expect(h.takeOutput(), '\x1b[<0;2;2m');
    });

    testWidgets('refused wheel steps scroll the scrollback', (tester) async {
      final seen = <VtMouseEvent>[];
      final h = await pumpHooked(
        tester,
        mouseReportFilter: (event) {
          seen.add(event);
          return false;
        },
      );
      writeLines(h.controller, 30);
      h.controller.write('\x1b[?1000h\x1b[?1006h');
      await tester.pump();
      final bottom = h.controller.scrollbar.offset;
      await sendWheel(tester, h.cell(5, 5), const Offset(0, -53));
      expect(h.controller.scrollbar.offset, bottom - 5);
      expect(h.takeOutput(), '');
      expect(seen.map((e) => (e.action, e.button)), [
        for (var i = 0; i < 5; i++) (MouseAction.press, MouseButton.four),
      ]);
    });

    testWidgets('refused wheel steps send alternate-scroll arrows', (
      tester,
    ) async {
      final h = await pumpHooked(
        tester,
        mouseReportFilter: (event) => event.button != MouseButton.five,
      );
      h.controller.write('\x1b[?1049h\x1b[?1007h\x1b[?1000h\x1b[?1006h');
      await tester.pump();
      await sendWheel(tester, h.cell(5, 5), const Offset(0, 20));
      expect(h.takeOutput(), '\x1b[B\x1b[B');
      await sendWheel(tester, h.cell(5, 5), const Offset(0, -10));
      expect(h.takeOutput(), '\x1b[<64;6;6M');
    });

    testWidgets('hover motion: the button is null; refused motion is '
        'dropped', (tester) async {
      final seen = <VtMouseEvent>[];
      var allow = false;
      final h = await pumpHooked(
        tester,
        mouseReportFilter: (event) {
          seen.add(event);
          return allow;
        },
      );
      h.controller.write('\x1b[?1003h\x1b[?1006h');
      final mouse = await mouseAt(tester, h.cell(0, 0));
      await mouse.moveTo(h.cell(2, 2));
      expect(h.takeOutput(), '');
      expect(seen.last.action, MouseAction.motion);
      expect(seen.last.button, isNull);
      allow = true;
      await mouse.moveTo(h.cell(3, 2));
      expect(h.takeOutput(), '\x1b[<35;4;3M');
    });

    testWidgets('onTerminalMouse replaces reports and gets the cell', (
      tester,
    ) async {
      final seen = <(MouseAction, MouseButton?, GridPoint)>[];
      final h = await pumpHooked(
        tester,
        padding: const EdgeInsets.all(10),
        onTerminalMouse: (event, cell) {
          seen.add((event.action, event.button, cell));
          return switch (event.action) {
            MouseAction.press => 'P${cell.x},${cell.y}',
            MouseAction.release => '',
            _ => null,
          };
        },
      );
      h.controller.write('\x1b[?1002h\x1b[?1006h');
      // The view is padded by 10 px: cell (2, 1) is at 35, 25.
      final drag = await tester.startGesture(
        const Offset(35, 25),
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveTo(const Offset(55, 25));
      await drag.up();
      // The motion returned null: encoded as usual.
      expect(h.takeOutput(), 'P2,1\x1b[<32;5;2M');
      expect(seen, [
        (MouseAction.press, MouseButton.left, const GridPoint.viewport(2, 1)),
        (MouseAction.motion, MouseButton.left, const GridPoint.viewport(4, 1)),
        (MouseAction.release, MouseButton.left, const GridPoint.viewport(4, 1)),
      ]);
      // Wheel reports go through it too.
      seen.clear();
      await sendWheel(tester, const Offset(15, 15), const Offset(0, 10));
      expect(seen, [
        (MouseAction.press, MouseButton.five, const GridPoint.viewport(0, 0)),
      ]);
      expect(h.takeOutput(), 'P0,0');
    });

    testWidgets('without tracking or in a readOnly view nothing is asked', (
      tester,
    ) async {
      var calls = 0;
      final h = await pumpHooked(
        tester,
        readOnly: true,
        mouseReportFilter: (_) {
          calls++;
          return true;
        },
        onTerminalMouse: (_, _) {
          calls++;
          return null;
        },
      );
      h.controller.write('\x1b[?1003h\x1b[?1006h');
      final mouse = await mouseAt(tester, h.cell(0, 0));
      await click(mouse, h.cell(1, 1));
      await mouse.moveTo(h.cell(4, 4));
      await sendWheel(tester, h.cell(5, 5), const Offset(0, -10));
      expect(calls, 0);
      expect(h.takeOutput(), '');
    });
  });

  group('selection options', () {
    testWidgets('SelectAllTextIntent selects everything; Ctrl+A still '
        'reaches the shell by default', (tester) async {
      final h = await pumpHooked(tester);
      h.controller.write('one\r\ntwo');
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tapKey(tester, LogicalKeyboardKey.keyA, character: 'a');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(h.takeOutput(), '\x01');
      expect(h.controller.selection, isNull);

      final context = tester.element(find.byType(TerminalRenderWidget));
      const intent = SelectAllTextIntent(SelectionChangedCause.keyboard);
      expect(Actions.maybeFind<SelectAllTextIntent>(context), isNotNull);
      Actions.invoke(context, intent);
      expect(h.controller.selectedText, startsWith('one\ntwo'));
    });

    testWidgets('a shortcut map can bind select all', (tester) async {
      final h = await pumpHooked(
        tester,
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.keyA, control: true):
              SelectAllTextIntent(SelectionChangedCause.keyboard),
        },
      );
      h.controller.write('abc');
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tapKey(tester, LogicalKeyboardKey.keyA, character: 'a');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(h.takeOutput(), '');
      expect(h.controller.selectedText, startsWith('abc'));
    });

    testWidgets('wordBoundaryCodepoints shape double-click words', (
      tester,
    ) async {
      var h = await pumpHooked(tester);
      h.controller.write('foo.bar baz');
      await tester.pump();
      final mouse = await mouseAt(tester, h.cell(5, 0));
      await doubleClick(tester, mouse, h.cell(5, 0));
      expect(h.controller.selectedText, 'foo.bar');

      h = await pumpHooked(tester, wordBoundaryCodepoints: ' .'.runes.toList());
      h.controller.write('foo.bar baz');
      await tester.pump();
      await doubleClick(
        tester,
        mouse,
        h.cell(5, 0),
        t0: const Duration(seconds: 20),
      );
      expect(h.controller.selectedText, 'bar');
    });

    testWidgets('changing wordBoundaryCodepoints rebuilds the gesture', (
      tester,
    ) async {
      final h = await pumpHooked(tester);
      h.controller.write('foo.bar baz');
      await tester.pump();
      final mouse = await mouseAt(tester, h.cell(1, 0));
      await doubleClick(tester, mouse, h.cell(1, 0));
      expect(h.controller.selectedText, 'foo.bar');
      await h.pumpView(
        VtTerminalView(
          key: h.viewKey,
          controller: h.controller,
          textStyle: viewStyle,
          wordBoundaryCodepoints: const [0x20, 0x2E],
        ),
      );
      await doubleClick(
        tester,
        mouse,
        h.cell(1, 0),
        t0: const Duration(seconds: 20),
      );
      expect(h.controller.selectedText, 'foo');
    });

    testWidgets('wordBoundaryCodepoints shape long-press words', (
      tester,
    ) async {
      final h = await pumpHooked(
        tester,
        wordBoundaryCodepoints: ' .'.runes.toList(),
      );
      h.controller.write('foo.bar baz');
      await tester.pump();
      await tester.longPressAt(h.cell(5, 0));
      await tester.pump();
      expect(h.controller.selectedText, 'bar');
    });

    testWidgets('rectangleSelection makes a plain drag select a block', (
      tester,
    ) async {
      Future<VtSelection?> dragAcross(ViewHarness h) async {
        final drag = await tester.startGesture(
          h.cell(1, 0),
          kind: PointerDeviceKind.mouse,
        );
        await drag.moveTo(h.cell(3, 2) + const Offset(3, 0));
        await drag.up();
        await tester.pump();
        return h.controller.selection;
      }

      const text = 'abcde\r\nfghij\r\nklmno';
      var h = await pumpHooked(tester);
      h.controller.write(text);
      expect((await dragAcross(h))!.isRectangle, isFalse);

      h = await pumpHooked(tester, rectangleSelection: true);
      h.controller.write(text);
      final block = await dragAcross(h);
      expect(block!.isRectangle, isTrue);
      expect(h.controller.selectedText, 'bcd\nghi\nlmn');
    });
  });

  group('VtTerminalViewState', () {
    testWidgets('cursorRect and globalCursorRect', (tester) async {
      setWindow(tester, width: 300, height: 200);
      final h = createViewHarness(tester);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Padding(
            padding: const EdgeInsets.only(left: 40, top: 30),
            child: SizedBox(
              width: 200,
              height: 100,
              child: VtTerminalView(
                key: h.viewKey,
                controller: h.controller,
                textStyle: viewStyle,
                padding: const EdgeInsets.all(5),
              ),
            ),
          ),
        ),
      );
      final state = h.viewKey.currentState!;
      h.controller.write('abc\r\nde');
      await tester.pump();
      expect(state.cursorRect, const Rect.fromLTWH(25, 15, 10, 10));
      expect(state.globalCursorRect, const Rect.fromLTWH(65, 45, 10, 10));
      // Scrolled away: no cursor on screen.
      writeLines(h.controller, 30);
      h.controller.scrollViewport(const ViewportScroll.top());
      await tester.pump();
      expect(state.cursorRect, Rect.zero);
      expect(state.globalCursorRect, Rect.zero);
    });

    testWidgets('hasInputConnection follows the keyboard', (tester) async {
      final h = await pumpHooked(tester);
      final state = h.viewKey.currentState!;
      expect(state.hasInputConnection, isTrue);
      state.closeKeyboard();
      await tester.pump();
      expect(state.hasInputConnection, isFalse);
      state.requestKeyboard();
      await tester.pump();
      expect(state.hasInputConnection, isTrue);

      final hw = await pumpHooked(tester, hardwareKeyboardOnly: true);
      expect(hw.viewKey.currentState!.hasInputConnection, isFalse);
    });
  });
}
