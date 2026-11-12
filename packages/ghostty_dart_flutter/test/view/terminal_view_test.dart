// Tests of the integrated VtTerminalView (ADR 0011): layout and resize,
// keyboard and IME input, pointer routing, scrolling, focus, theme and
// lifetime. The parts have their own tests; these check the wiring.

import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart_flutter/ghostty_dart_flutter.dart';
import 'package:ghostty_dart_flutter/src/input/text_input/composing_overlay.dart';

import 'view_harness.dart';

/// Sends `TextInputClient.updateEditingStateWithDeltas` as the engine does.
Future<void> sendDelta(
  WidgetTester tester, {
  required String oldText,
  required String text,
  required int start,
  required int end,
  int composingBase = -1,
  int composingExtent = -1,
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
              'composingBase': composingBase,
              'composingExtent': composingExtent,
            },
          ],
        },
      ]),
    ),
    (_) {},
  );
  await tester.pump();
}

void main() {
  group('layout', () {
    testWidgets('fits the terminal and reports onResize once, after the '
        'frame', (tester) async {
      setWindow(tester);
      final h = createViewHarness(tester);
      await h.pumpView(
        VtTerminalView(controller: h.controller, textStyle: viewStyle),
      );
      expect(h.resizes.single, (20, 10, 200, 100));
      expect(h.resizePhases.single, SchedulerPhase.postFrameCallbacks);
      expect((h.controller.cols, h.controller.rows), (20, 10));

      // Another frame with the same size resizes nothing.
      await tester.pump();
      expect(h.resizes, hasLength(1));

      tester.view.physicalSize = const Size(305, 100);
      await tester.pump();
      expect(h.resizes, [(20, 10, 200, 100), (30, 10, 300, 100)]);
    });

    testWidgets('padding and the device pixel ratio', (tester) async {
      final h = await pumpTerminalView(
        tester,
        dpr: 2,
        padding: const EdgeInsets.all(5),
      );
      // 190 x 90 logical px of 10 x 10 cells; cells are 20 device px.
      expect(h.resizes.single, (19, 9, 380, 180));
    });

    testWidgets('the text style height sets the line height', (tester) async {
      setWindow(tester);
      final h = createViewHarness(tester);
      await h.pumpView(
        VtTerminalView(
          controller: h.controller,
          textStyle: viewStyle.copyWith(height: 2),
        ),
      );
      expect((h.controller.cols, h.controller.rows), (20, 5));
    });

    testWidgets('autoResize: false keeps the controller size and follows '
        'a resize from the app', (tester) async {
      setWindow(tester);
      final h = createViewHarness(tester, cols: 8);
      await h.pumpView(
        VtTerminalView(
          controller: h.controller,
          textStyle: viewStyle,
          autoResize: false,
        ),
      );
      expect(h.resizes, isEmpty);
      expect((h.controller.cols, h.controller.rows), (8, 24));
      h.controller.resize(12, 4);
      await tester.pump();
      // The view leaves the terminal alone: no cell size was given.
      expect(h.resizes, [(12, 4, 0, 0)]);
      final geometry = h.render.geometry;
      expect((geometry.cols, geometry.rows), (12, 4));
    });

    testWidgets('a resize from the app is fitted again', (tester) async {
      final h = await pumpTerminalView(tester);
      h.controller.resize(5, 5);
      await tester.pump();
      await tester.pump();
      expect((h.controller.cols, h.controller.rows), (20, 10));
    });

    testWidgets('unbounded constraints fail with a clear message', (
      tester,
    ) async {
      final h = createViewHarness(tester);
      // Two errors are reported (the ArgumentError, then the error widget
      // overflowing the Column), and `takeException` only returns a summary
      // string for several, so the errors are collected directly.
      final errors = <Object>[];
      final previous = FlutterError.onError;
      FlutterError.onError = (details) => errors.add(details.exception);
      try {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Column(
              children: [
                VtTerminalView(controller: h.controller, textStyle: viewStyle),
              ],
            ),
          ),
        );
      } finally {
        FlutterError.onError = previous;
      }
      expect(
        errors.first,
        isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('bounded constraints'),
        ),
      );
    });
  });

  group('keyboard and text', () {
    testWidgets('keys reach onOutput', (tester) async {
      final h = await pumpTerminalView(tester);
      await tapKey(tester, LogicalKeyboardKey.enter);
      await tapKey(tester, LogicalKeyboardKey.arrowUp);
      expect(h.takeOutput(), '\r\x1b[A');
    });

    testWidgets('printable keys with hardwareKeyboardOnly', (tester) async {
      final h = await pumpTerminalView(tester, hardwareKeyboardOnly: true);
      expect(tester.testTextInput.hasAnyClients, isFalse);
      await tapKey(tester, LogicalKeyboardKey.keyA, character: 'a');
      expect(h.takeOutput(), 'a');
    });

    testWidgets('IME commit reaches onOutput; composing hides the cursor', (
      tester,
    ) async {
      final h = await pumpTerminalView(tester);
      expect(tester.testTextInput.hasAnyClients, isTrue);
      await sendDelta(
        tester,
        oldText: '  ',
        text: 'k',
        start: 2,
        end: 2,
        composingBase: 2,
        composingExtent: 3,
      );
      expect(h.render.isCursorHidden, isTrue);
      expect(h.takeOutput(), '');
      await sendDelta(tester, oldText: '  k', text: 'か', start: 2, end: 3);
      expect(h.render.isCursorHidden, isFalse);
      expect(h.takeOutput(), latin1Of('か'));
    });

    testWidgets('readOnly sends nothing', (tester) async {
      final h = await pumpTerminalView(tester, readOnly: true);
      await tapKey(tester, LogicalKeyboardKey.enter);
      expect(h.takeOutput(), '');
      expect(tester.testTextInput.hasAnyClients, isFalse);
    });

    testWidgets('focus changes are reported when the program asks', (
      tester,
    ) async {
      final h = await pumpTerminalView(tester, autofocus: false);
      h.controller.write('\x1b[?1004h');
      await tester.tap(find.byType(VtTerminalView));
      await tester.pump();
      expect(h.render.focused, isTrue);
      FocusManager.instance.primaryFocus!.unfocus();
      // The focus listeners run after the frame; the view rebuilds next.
      await tester.pump();
      await tester.pump();
      expect(h.render.focused, isFalse);
      expect(h.takeOutput(), '\x1b[I\x1b[O');
    });

    testWidgets('macosOptionAsAlt comes from the controller', (tester) async {
      final h = await pumpTerminalView(tester);
      h.controller.macosOptionAsAlt = OptionAsAlt.both;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      expect(h.takeOutput(), '\x1b[1;3D');
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('closeKeyboard survives a rebuild', (tester) async {
      final h = await pumpTerminalView(tester);
      h.viewKey.currentState!.closeKeyboard();
      await h.pumpView(
        VtTerminalView(
          key: h.viewKey,
          controller: h.controller,
          textStyle: viewStyle,
          padding: const EdgeInsets.all(1),
        ),
      );
      expect(tester.testTextInput.hasAnyClients, isFalse);
    });

    testWidgets('requestKeyboard and closeKeyboard', (tester) async {
      final h = await pumpTerminalView(tester);
      h.viewKey.currentState!.closeKeyboard();
      await tester.pump();
      expect(tester.testTextInput.hasAnyClients, isFalse);
      h.viewKey.currentState!.requestKeyboard();
      await tester.pump();
      expect(tester.testTextInput.hasAnyClients, isTrue);
    });
  });

  group('pointer', () {
    testWidgets('a mouse press focuses the view', (tester) async {
      final h = await pumpTerminalView(tester, autofocus: false);
      expect(h.render.focused, isFalse);
      final gesture = await tester.startGesture(
        h.cell(2, 2),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.up();
      await tester.pump();
      expect(h.render.focused, isTrue);
    });

    testWidgets('a touch tap shows the keyboard, a touch drag does not', (
      tester,
    ) async {
      final h = await pumpTerminalView(tester);
      h.viewKey.currentState!.closeKeyboard();
      await tester.pump();
      await tester.dragFrom(h.cell(5, 2), const Offset(0, 40));
      await tester.pumpAndSettle();
      expect(tester.testTextInput.hasAnyClients, isFalse);
      await tester.tapAt(h.cell(5, 2));
      await tester.pump();
      expect(tester.testTextInput.hasAnyClients, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
    });

    testWidgets('a mouse drag selects; with tracking it is reported', (
      tester,
    ) async {
      final h = await pumpTerminalView(tester);
      h.controller.write('hello world');
      await tester.pump();
      final drag = await tester.startGesture(
        h.cell(0, 0),
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveTo(h.cell(4, 0) + const Offset(3, 0));
      await drag.up();
      await tester.pump();
      expect(h.controller.selectedText, 'hello');
      expect(h.takeOutput(), '');

      h.controller.write('\x1b[?1000h\x1b[?1006h');
      final click = await tester.startGesture(
        h.cell(3, 1),
        kind: PointerDeviceKind.mouse,
      );
      await click.up();
      await tester.pump();
      expect(h.takeOutput(), '\x1b[<0;4;2M\x1b[<0;4;2m');
    });

    testWidgets('a readOnly view reports nothing and selects instead', (
      tester,
    ) async {
      final h = await pumpTerminalView(tester, readOnly: true);
      h.controller.write('hello world\x1b[?1000h\x1b[?1006h');
      await tester.pump();
      final drag = await tester.startGesture(
        h.cell(0, 0),
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveTo(h.cell(4, 0) + const Offset(3, 0));
      await drag.up();
      await tester.pump();
      expect(h.controller.selectedText, 'hello');
      // Alternate screen with DEC 1007: no arrow keys either.
      h.controller.write('\x1b[?1000l\x1b[?1049h\x1b[?1007h');
      await sendWheel(tester, h.cell(5, 5), const Offset(0, -53));
      expect(h.takeOutput(), '');
    });

    testWidgets('onTapUp and onSecondaryTapDown get the cell', (tester) async {
      setWindow(tester);
      final h = createViewHarness(tester);
      final taps = <(String, GridPoint, Offset, PointerDeviceKind?)>[];
      await h.pumpView(
        VtTerminalView(
          controller: h.controller,
          textStyle: viewStyle,
          onTapUp: (d, cell) =>
              taps.add(('tap', cell, d.globalPosition, d.kind)),
          onSecondaryTapDown: (d, cell) =>
              taps.add(('secondary', cell, d.globalPosition, d.kind)),
          onSecondaryTapUp: (d, cell) =>
              taps.add(('secondary up', cell, d.localPosition, d.kind)),
        ),
      );
      final tap = await tester.startGesture(
        h.cell(3, 4),
        kind: PointerDeviceKind.mouse,
      );
      await tap.up();
      final right = await tester.startGesture(
        h.cell(6, 1),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryButton,
      );
      await right.up();
      await tester.pump();
      const mouse = PointerDeviceKind.mouse;
      expect(taps, [
        ('tap', const GridPoint.viewport(3, 4), h.cell(3, 4), mouse),
        ('secondary', const GridPoint.viewport(6, 1), h.cell(6, 1), mouse),
        ('secondary up', const GridPoint.viewport(6, 1), h.cell(6, 1), mouse),
      ]);
      // A touch tap passes the recognizer's details.
      taps.clear();
      await tester.tapAt(h.cell(2, 2));
      await tester.pump();
      expect(taps, [
        (
          'tap',
          const GridPoint.viewport(2, 2),
          h.cell(2, 2),
          PointerDeviceKind.touch,
        ),
      ]);
    });

    testWidgets('the wheel scrolls the scrollback', (tester) async {
      final h = await pumpTerminalView(tester);
      writeLines(h.controller, 30);
      await tester.pump();
      final bottom = h.controller.scrollbar.offset;
      // Linux and Windows deliver whole notches of 53 or 60 px.
      await sendWheel(tester, h.cell(5, 5), const Offset(0, -53));
      expect(h.controller.scrollbar.offset, bottom - 5);
    });

    testWidgets('one slow macOS wheel notch scrolls three rows', (
      tester,
    ) async {
      final h = await pumpTerminalView(tester);
      writeLines(h.controller, 30);
      await tester.pump();
      final bottom = h.controller.scrollbar.offset;
      // 0.1 line x 40 px: less than one 10 px row.
      await sendWheel(tester, h.cell(5, 5), const Offset(0, -4));
      expect(h.controller.scrollbar.offset, bottom - 3);
      // A lone fast notch of 2.5 lines, a second later, scrolls 7 (7.5,
      // truncated).
      await sendWheel(
        tester,
        h.cell(5, 5),
        const Offset(0, -100),
        timeStamp: const Duration(seconds: 1),
      );
      expect(h.controller.scrollbar.offset, bottom - 10);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('a stream of small macOS wheel events accumulates pixels', (
      tester,
    ) async {
      final h = await pumpTerminalView(tester);
      writeLines(h.controller, 30);
      await tester.pump();
      final bottom = h.controller.scrollbar.offset;
      // A smooth-scrolling mouse without gesture phases: 2 px every 10 ms.
      // The first event counts as a notch (3 rows); the next nine add
      // 18 px, one more 10 px row.
      final pointer = TestPointer(77, PointerDeviceKind.mouse)
        ..hover(h.cell(5, 5));
      for (var i = 0; i < 10; i++) {
        await tester.sendEventToBinding(
          pointer.scroll(
            const Offset(0, -2),
            timeStamp: Duration(seconds: 5, milliseconds: 10 * i),
          ),
        );
      }
      await tester.pump();
      expect(h.controller.scrollbar.offset, bottom - 4);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  });

  group('theme and lifetime', () {
    testWidgets('cacheBudget reaches the renderer and can change', (
      tester,
    ) async {
      final h = await pumpTerminalView(tester);
      expect(h.render.cacheBudget, VtTerminalView.defaultCacheBudget);
      expect(VtTerminalView.defaultCacheBudget, 16 << 20);
      h.controller.write('kept');
      await tester.pump();
      final recordings = h.render.debugRowRecordings;
      await h.pumpView(
        VtTerminalView(
          key: h.viewKey,
          controller: h.controller,
          textStyle: viewStyle,
          autofocus: true,
          cacheBudget: 4 << 20,
        ),
      );
      expect(h.render.cacheBudget, 4 << 20);
      // A budget change keeps what fits: nothing is recorded again.
      expect(h.render.debugRowRecordings, recordings);
    });

    testWidgets('a theme change repaints with the new colours', (tester) async {
      final h = await pumpTerminalView(tester);
      h.controller.write('colours');
      await tester.pump();
      final before = h.render.debugRowRecordings;
      h.controller.theme = VtTerminalTheme.whiteOnBlack;
      expect(h.render.debugNeedsPaint, isTrue);
      await tester.pump();
      expect(h.render.debugRowRecordings, greaterThan(before));
      expect(
        h.controller.terminal.colorBackground,
        VtTerminalTheme.rgbOf(VtTerminalTheme.whiteOnBlack.background),
      );
    });

    testWidgets('disposing the controller while mounted', (tester) async {
      final h = await pumpTerminalView(tester);
      h.controller
        ..write('bye')
        ..dispose();
      // Rebuild, relayout and repaint with the disposed controller.
      tester.view.physicalSize = const Size(300, 100);
      await h.pumpView(
        VtTerminalView(
          key: h.viewKey,
          controller: h.controller,
          textStyle: viewStyle,
          padding: const EdgeInsets.all(2),
        ),
      );
      await tapKey(tester, LogicalKeyboardKey.enter);
      await sendWheel(tester, h.cell(1, 1), const Offset(0, -53));
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    });

    testWidgets('a new controller replaces the old one', (tester) async {
      final h = await pumpTerminalView(tester);
      final other = VtTerminalController(cols: 4, rows: 4);
      addTearDown(other.dispose);
      await h.pumpView(VtTerminalView(controller: other, textStyle: viewStyle));
      await tester.pump();
      expect((other.cols, other.rows), (20, 10));
      // The old controller can drive a view again (frame ownership freed).
      await h.pumpView(
        VtTerminalView(controller: h.controller, textStyle: viewStyle),
      );
      expect(tester.takeException(), isNull);
    });

    group('one view per controller', () {
      /// One view per controller in an IndexedStack, as a tabbed terminal
      /// builds it: IndexedStack wraps each child in an unkeyed Visibility,
      /// so closing a tab re-creates the views after it.
      Widget tabs(List<VtTerminalController> controllers, int index) =>
          wrapView(
            IndexedStack(
              index: index,
              children: [
                for (final controller in controllers)
                  KeyedSubtree(
                    key: ObjectKey(controller),
                    child: VtTerminalView(
                      controller: controller,
                      textStyle: viewStyle,
                    ),
                  ),
              ],
            ),
          );

      testWidgets('closing a tab re-creates the next view in the same frame', (
        tester,
      ) async {
        setWindow(tester);
        final first = VtTerminalController();
        final second = VtTerminalController();
        addTearDown(first.dispose);
        addTearDown(second.dispose);
        second.write('second');
        await tester.pumpWidget(tabs([first, second], 1));
        // Close the first tab: the second tab's view is unmounted and a new
        // one for the same controller paints in the same frame.
        await tester.pumpWidget(tabs([second], 0));
        expect(tester.takeException(), isNull);
        second.write('!');
        await tester.pump();
        expect(tester.takeException(), isNull);
      });

      testWidgets('a view moved by a GlobalKey keeps reading frames', (
        tester,
      ) async {
        setWindow(tester);
        final controller = VtTerminalController();
        addTearDown(controller.dispose);
        final key = GlobalKey<VtTerminalViewState>();
        Widget at({required bool left}) => wrapView(
          Row(
            children: [
              Expanded(
                child: left
                    ? VtTerminalView(
                        key: key,
                        controller: controller,
                        textStyle: viewStyle,
                      )
                    : const SizedBox(),
              ),
              Expanded(
                child: left
                    ? const SizedBox()
                    : VtTerminalView(
                        key: key,
                        controller: controller,
                        textStyle: viewStyle,
                      ),
              ),
            ],
          ),
        );
        await tester.pumpWidget(at(left: true));
        await tester.pumpWidget(at(left: false));
        expect(tester.takeException(), isNull);
        controller.write('x');
        await tester.pump();
        expect(tester.takeException(), isNull);
      });

      testWidgets('two views painting one controller still fail (debug)', (
        tester,
      ) async {
        setWindow(tester);
        final controller = VtTerminalController();
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          wrapView(
            Row(
              children: [
                for (var i = 0; i < 2; i++)
                  Expanded(
                    child: VtTerminalView(
                      controller: controller,
                      textStyle: viewStyle,
                    ),
                  ),
              ],
            ),
          ),
        );
        expect(
          tester.takeException(),
          isA<AssertionError>().having(
            (e) => e.message,
            'message',
            contains('Two views read frames'),
          ),
        );
        await tester.pumpWidget(const SizedBox());
      });
    });

    group('focus node swap', () {
      /// The node the view's Focus widget holds now.
      FocusNode heldNode(WidgetTester tester) => tester
          .widget<Focus>(
            find
                .descendant(
                  of: find.byType(VtTerminalView),
                  matching: find.byType(Focus),
                )
                .first,
          )
          .focusNode!;

      testWidgets('own node to app node: focus kept, no report blip, own '
          'node disposed after it is let go', (tester) async {
        final h = await pumpTerminalView(tester);
        h.controller.write('\x1b[?1004h');
        await tester.pump();
        final own = heldNode(tester);
        expect(own.hasFocus, isTrue);
        h.takeOutput();
        final app = FocusNode();
        addTearDown(app.dispose);
        await h.pumpView(
          VtTerminalView(
            key: h.viewKey,
            controller: h.controller,
            textStyle: viewStyle,
            focusNode: app,
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(app.hasFocus, isTrue);
        expect(h.render.focused, isTrue);
        expect(tester.testTextInput.hasAnyClients, isTrue);
        expect(h.takeOutput(), '');
        expect(
          () => ChangeNotifier.debugAssertNotDisposed(own),
          throwsA(isA<FlutterError>()),
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets('app node to app node and back to an own node', (
        tester,
      ) async {
        setWindow(tester);
        final h = createViewHarness(tester);
        final first = FocusNode();
        final second = FocusNode();
        addTearDown(first.dispose);
        addTearDown(second.dispose);
        Future<void> pump(FocusNode? node) => h.pumpView(
          VtTerminalView(
            key: h.viewKey,
            controller: h.controller,
            textStyle: viewStyle,
            focusNode: node,
          ),
        );
        await pump(first);
        first.requestFocus();
        await tester.pump();
        await pump(second);
        await tester.pump();
        expect(second.hasFocus, isTrue);
        await pump(null);
        await tester.pump();
        expect(heldNode(tester).hasFocus, isTrue);
        expect(h.render.focused, isTrue);
        await tester.pumpWidget(const SizedBox());
        // The app's nodes are never disposed by the view.
        ChangeNotifier.debugAssertNotDisposed(first);
        ChangeNotifier.debugAssertNotDisposed(second);
      });
    });

    testWidgets('a controller swap moves the focus report', (tester) async {
      final h = await pumpTerminalView(tester);
      await tester.pump();
      h.controller.write('\x1b[?1004h');
      final output = <String>[];
      final other = VtTerminalController(
        onOutput: (bytes) => output.add(String.fromCharCodes(bytes)),
      );
      addTearDown(other.dispose);
      other.write('\x1b[?1004h');
      h.takeOutput();
      await h.pumpView(
        VtTerminalView(key: h.viewKey, controller: other, textStyle: viewStyle),
      );
      expect(h.takeOutput(), '\x1b[O');
      expect(output, ['\x1b[I']);
    });

    testWidgets('the preedit background follows theme and OSC 11', (
      tester,
    ) async {
      final h = await pumpTerminalView(tester);
      await sendDelta(
        tester,
        oldText: '  ',
        text: 'k',
        start: 2,
        end: 2,
        composingBase: 2,
        composingExtent: 3,
      );
      Color? background() => tester
          .widget<ComposingOverlay>(find.byType(ComposingOverlay))
          .backgroundColor;
      expect(background(), VtTerminalTheme.defaultTheme.background);
      h.controller.theme = VtTerminalTheme.whiteOnBlack;
      await tester.pump();
      expect(background(), VtTerminalTheme.whiteOnBlack.background);
      h.controller.write('\x1b]11;#102030\x07');
      await tester.pump();
      expect(background(), const Color(0xFF102030));
    });

    testWidgets('setting the theme during a build is delivered after it', (
      tester,
    ) async {
      final h = await pumpTerminalView(tester);
      var rebuilds = 0;
      late StateSetter rebuildOther;
      h.controller.addListener(() => rebuildOther(() => rebuilds++));
      var theme = VtTerminalTheme.defaultTheme;
      await tester.pumpWidget(
        wrapView(
          Column(
            children: [
              StatefulBuilder(
                builder: (context, setState) {
                  rebuildOther = setState;
                  return const SizedBox(height: 1);
                },
              ),
              Expanded(
                child: Builder(
                  builder: (context) {
                    // An adapter pushing its `theme` parameter (from build:
                    // the worst case).
                    h.controller.theme = theme;
                    return VtTerminalView(
                      key: h.viewKey,
                      controller: h.controller,
                      textStyle: viewStyle,
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      );
      rebuilds = 0;
      theme = VtTerminalTheme.whiteOnBlack;
      tester.element(find.byType(Builder).last).markNeedsBuild();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(rebuilds, 1);
      expect(
        h.controller.terminal.colorBackground,
        VtTerminalTheme.rgbOf(VtTerminalTheme.whiteOnBlack.background),
      );
    });
  });

  group('composing, then a rebuild closes the connection', () {
    Future<ViewHarness> startComposing(WidgetTester tester) async {
      final h = await pumpTerminalView(tester);
      await sendDelta(
        tester,
        oldText: '  ',
        text: 'k',
        start: 2,
        end: 2,
        composingBase: 2,
        composingExtent: 3,
      );
      expect(h.render.isCursorHidden, isTrue);
      return h;
    }

    final triggers = <String, VtTerminalView Function(ViewHarness h)>{
      'readOnly': (h) => VtTerminalView(
        key: h.viewKey,
        controller: h.controller,
        textStyle: viewStyle,
        readOnly: true,
      ),
      'hardwareKeyboardOnly': (h) => VtTerminalView(
        key: h.viewKey,
        controller: h.controller,
        textStyle: viewStyle,
        hardwareKeyboardOnly: true,
      ),
      'deleteDetection': (h) => VtTerminalView(
        key: h.viewKey,
        controller: h.controller,
        textStyle: viewStyle,
        deleteDetection: false,
      ),
      'focus node swap': (h) => VtTerminalView(
        key: h.viewKey,
        controller: h.controller,
        textStyle: viewStyle,
        focusNode: FocusNode(),
      ),
      'disposed controller': (h) {
        h.controller.dispose();
        return VtTerminalView(
          key: h.viewKey,
          controller: h.controller,
          textStyle: viewStyle,
          padding: const EdgeInsets.all(1),
        );
      },
    };
    for (final MapEntry(key: name, value: build) in triggers.entries) {
      testWidgets(name, (tester) async {
        final h = await startComposing(tester);
        final view = build(h);
        final node = view.focusNode;
        if (node != null) addTearDown(node.dispose);
        await h.pumpView(view);
        await tester.pump();
        expect(tester.takeException(), isNull);
        // A focus node swap keeps the focus, so the IME keeps composing;
        // every other trigger closes the connection.
        if (name != 'focus node swap') {
          expect(h.render.isCursorHidden, isFalse);
        }
      });
    }
  });
}

/// [text] as the Latin-1 view of its UTF-8 bytes (what takeOutput gives).
String latin1Of(String text) =>
    String.fromCharCodes(const Utf8Encoder().convert(text));
