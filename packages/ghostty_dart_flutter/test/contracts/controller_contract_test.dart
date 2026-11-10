// Contract tests of VtTerminalController (ADR 0011). Every later change
// must keep them passing.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart_flutter/ghostty_dart_flutter.dart';
import 'package:ghostty_dart_flutter/src/seams/controller_seams.dart';
import 'package:ghostty_dart_flutter/src/seams/terminal_geometry.dart';

/// A controller that records its output as one string per [onOutput] call.
({VtTerminalController controller, List<String> output}) _recording({
  int cols = 20,
  int rows = 5,
}) {
  final output = <String>[];
  final controller = VtTerminalController(
    cols: cols,
    rows: rows,
    onOutput: (data) => output.add(latin1.decode(data)),
  );
  addTearDown(controller.dispose);
  return (controller: controller, output: output);
}

void main() {
  group('output', () {
    test('sendText sends UTF-8 unchanged', () {
      final (:controller, :output) = _recording();
      final bytes = <int>[];
      controller.onOutput = bytes.addAll;
      controller.sendText('ls ñ\r');
      expect(utf8.decode(bytes), 'ls ñ\r');
      controller.sendText('');
      expect(output, isEmpty);
    });

    test('sendKey encodes with the terminal modes', () {
      final (:controller, :output) = _recording();
      expect(controller.sendKey(const VtKeyEvent(key: VtKey.enter)), isTrue);
      expect(
        controller.sendKey(
          const VtKeyEvent(
            key: VtKey.c,
            modifiers: KeyModifiers.ctrl,
            text: 'c',
            unshiftedCodepoint: 0x63,
          ),
        ),
        isTrue,
      );
      expect(controller.sendKey(const VtKeyEvent(key: VtKey.arrowUp)), isTrue);
      controller.write('\x1b[?1h'); // application cursor keys
      controller.sendKey(const VtKeyEvent(key: VtKey.arrowUp));
      expect(output, ['\r', '\x03', '\x1b[A', '\x1bOA']);
    });

    test('sendKey returns false when nothing is encoded', () {
      final (:controller, :output) = _recording();
      expect(
        controller.sendKey(
          const VtKeyEvent(key: VtKey.shiftLeft, modifiers: KeyModifiers.shift),
        ),
        isFalse,
      );
      expect(output, isEmpty);
    });

    test('replies to queries arrive after write returns, in order', () {
      final (:controller, :output) = _recording();
      controller.onOutput = (data) {
        // Reading the selection throws StateError from inside a terminal
        // callback, so this proves onOutput runs after the write.
        expect(controller.selection, isNull);
        output.add(latin1.decode(data));
      };
      controller.write('\x1b[6n\x1b[6n');
      expect(output, ['\x1b[1;1R', '\x1b[1;1R']);
    });

    test('onOutput may write back (local echo)', () {
      final (:controller, :output) = _recording();
      controller.onOutput = (data) {
        output.add(latin1.decode(data));
        controller.writeBytes(Uint8List.fromList(utf8.encode('echo')));
      };
      controller.write('\x1b[6n');
      expect(output, ['\x1b[1;1R']);
      expect(controller.terminal.cursorX, 4);
    });

    test('paste honours bracketed paste and rejects unsafe text', () {
      final (:controller, :output) = _recording();
      expect(controller.paste('ls'), PasteResult.pasted);
      expect(controller.paste('rm -rf x\r'), PasteResult.rejected);
      expect(
        controller.paste('rm -rf x\r', allowUnsafe: true),
        PasteResult.pasted,
      );
      controller.write('\x1b[?2004h');
      expect(controller.paste('a\rb'), PasteResult.pasted);
      expect(output, ['ls', 'rm -rf x\r', '\x1b[200~a\rb\x1b[201~']);
    });

    test('sendFocus reports only while DEC 1004 is set', () {
      final (:controller, :output) = _recording();
      controller.sendFocus(focused: true);
      expect(output, isEmpty);
      controller.write('\x1b[?1004h');
      controller
        ..sendFocus(focused: true)
        ..sendFocus(focused: false);
      expect(output, ['\x1b[I', '\x1b[O']);
    });

    test('events raised from a callback come after the queued ones', () {
      final (:controller, :output) = _recording();
      controller.onOutput = (data) {
        final reply = latin1.decode(data);
        output.add(reply);
        // The first reply triggers another query (status report).
        if (reply == '\x1b[1;1R') controller.write('\x1b[5n');
      };
      controller.write('\x1b[6n\x1b[c');
      expect(output, hasLength(3));
      expect(output[0], '\x1b[1;1R');
      expect(output[1], startsWith('\x1b[?'), reason: 'DA reply second');
      expect(output[2], '\x1b[0n');
    });

    test('a throwing callback keeps the remaining events queued', () {
      final (:controller, :output) = _recording();
      var first = true;
      controller.onOutput = (data) {
        if (first) {
          first = false;
          throw StateError('boom');
        }
        output.add(latin1.decode(data));
      };
      expect(() => controller.write('\x1b[6n\x1b[6n'), throwsStateError);
      controller.write('x');
      expect(output, ['\x1b[1;1R']);
    });

    test('macosOptionAsAlt can be set back to none', () {
      final (:controller, :output) = _recording();
      expect(controller.macosOptionAsAlt, OptionAsAlt.none);
      controller.write('\x1b[?1036h'); // Alt sends an ESC prefix
      const optionW = VtKeyEvent(
        key: VtKey.w,
        modifiers: KeyModifiers(alt: true),
        text: '∑',
        unshiftedCodepoint: 0x77,
      );
      controller
        ..macosOptionAsAlt = OptionAsAlt.both
        ..sendKey(optionW)
        ..macosOptionAsAlt = OptionAsAlt.none
        ..sendKey(optionW);
      expect(controller.macosOptionAsAlt, OptionAsAlt.none);
      // Option-as-Alt is compiled in only on macOS (key_encode.zig).
      if (Platform.isMacOS) {
        expect(output, ['\x1bw', '∑']);
      } else {
        expect(output, hasLength(2));
        expect(output[0], output[1]);
      }
    });

    test('sendMouse reports only while the program tracks the mouse', () {
      final (:controller, :output) = _recording();
      final seams = ControllerSeams(controller)
        ..setMouseGeometry(
          const MouseEncoderSize(
            screenWidth: 200,
            screenHeight: 100,
            cellWidth: 10,
            cellHeight: 20,
          ),
        );
      const press = VtMouseEvent(
        action: MouseAction.press,
        button: MouseButton.left,
        x: 15,
        y: 25,
      );
      expect(controller.isMouseTracking, isFalse);
      expect(seams.sendMouse(press), isFalse);
      controller.write('\x1b[?1000h\x1b[?1006h');
      expect(controller.isMouseTracking, isTrue);
      expect(seams.sendMouse(press), isTrue);
      expect(output, ['\x1b[<0;2;2M']);
    });
  });

  group('effects', () {
    test('bell and title are delivered after the write', () {
      final (:controller, output: _) = _recording();
      var bells = 0;
      final titles = <String>[];
      controller
        ..onBell = (() => bells++)
        ..onTitleChanged = titles.add
        ..write('\x07\x1b]0;hello\x07');
      expect(bells, 1);
      expect(titles, ['hello']);
      expect(controller.title, 'hello');
    });

    test('synchronized output holds rendering', () {
      final (:controller, output: _) = _recording();
      final seams = ControllerSeams(controller);
      controller.write('\x1b[?2026h');
      expect(seams.isRenderHeld, isTrue);
      var notified = 0;
      controller.addListener(() => notified++);
      controller.write('\x1b[?2026l');
      expect(seams.isRenderHeld, isFalse);
      expect(notified, greaterThanOrEqualTo(1));
    });
  });

  group('render hold', () {
    testWidgets('a hold that never ends expires after the timeout', (
      tester,
    ) async {
      final (:controller, output: _) = _recording();
      final seams = ControllerSeams(controller);
      var notified = 0;
      controller
        ..addListener(() => notified++)
        ..write('\x1b[?2026h');
      expect(seams.isRenderHeld, isTrue);
      notified = 0;
      await tester.pump(
        VtTerminalController.renderHoldTimeout -
            const Duration(milliseconds: 1),
      );
      expect(seams.isRenderHeld, isTrue);
      await tester.pump(const Duration(milliseconds: 1));
      expect(seams.isRenderHeld, isFalse);
      expect(notified, 1);
      expect(
        controller.isModeEnabled(TerminalMode.synchronizedOutput),
        isFalse,
      );
      // A later hold starts again.
      controller.write('\x1b[?2026h');
      expect(seams.isRenderHeld, isTrue);
      controller.write('\x1b[?2026l');
      expect(seams.isRenderHeld, isFalse);
      await tester.pump(VtTerminalController.renderHoldTimeout);
      expect(notified, greaterThanOrEqualTo(2));
    });
  });

  group('size', () {
    testWidgets('a resize from layout notifies after the frame', (
      tester,
    ) async {
      final (:controller, output: _) = _recording();
      final seams = ControllerSeams(controller);
      final calls = <List<int>>[];
      controller.onResize = (c, r, w, h) => calls.add([c, r, w, h]);
      const metrics = VtCellMetrics(
        width: 10,
        height: 20,
        baseline: 15,
        advance: 10,
        devicePixelRatio: 1,
      );
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              // A listener outside the LayoutBuilder: rebuilding it during
              // layout would throw.
              ListenableBuilder(
                listenable: controller,
                builder: (context, _) => Text('${controller.cols}'),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final geometry = TerminalGeometry.fit(
                      constraints.biggest,
                      metrics,
                    );
                    seams.resizeDuringLayout(geometry);
                    expect(calls, isEmpty, reason: 'deferred past layout');
                    return const SizedBox.expand();
                  },
                ),
              ),
            ],
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(calls, hasLength(1));
      expect(calls.single, [
        controller.cols,
        controller.rows,
        controller.cols * 10,
        controller.rows * 20,
      ]);
      await tester.pump();
      expect(find.text('${controller.cols}'), findsOneWidget);
    });

    test('resize propagates to the terminal and onResize', () {
      final (:controller, output: _) = _recording();
      final calls = <List<int>>[];
      var notified = 0;
      controller
        ..onResize = ((c, r, w, h) => calls.add([c, r, w, h]))
        ..addListener(() => notified++)
        ..resize(30, 10, cellWidthPx: 8, cellHeightPx: 16);
      expect(controller.cols, 30);
      expect(controller.rows, 10);
      expect(calls, [
        [30, 10, 240, 160],
      ]);
      expect(notified, 1);

      controller.resize(30, 10, cellWidthPx: 8, cellHeightPx: 16);
      controller.resize(30, 10);
      expect(calls, hasLength(1), reason: 'an unchanged resize is a no-op');

      controller.resize(30, 10, cellWidthPx: 9);
      expect(calls.last, [30, 10, 270, 160]);
    });
  });

  group('notifications', () {
    test('each mutating call notifies once', () {
      final (:controller, output: _) = _recording();
      var notified = 0;
      controller.addListener(() => notified++);
      controller.write('a\x1b[6nb');
      expect(notified, 1);
      controller.scrollViewport(const ViewportScroll.top());
      expect(notified, 2);
      controller.selectAll();
      expect(notified, 3);
      controller.theme = VtTerminalTheme.whiteOnBlack;
      expect(notified, 4);
      controller.theme = VtTerminalTheme.whiteOnBlack;
      expect(notified, 4, reason: 'an equal theme is a no-op');
      controller.writeBytes(Uint8List(0));
      expect(notified, 4, reason: 'empty writes are no-ops');
      controller.sendText('x');
      expect(notified, 4, reason: 'input at the bottom does not notify');
    });

    test('paste while scrolled up notifies once', () {
      final (:controller, output: _) = _recording();
      controller.write(List.generate(30, (i) => '$i').join('\r\n'));
      controller.scrollViewport(const ViewportScroll.delta(-5));
      var notified = 0;
      controller.addListener(() => notified++);
      controller.paste('ls');
      expect(notified, 1);
      expect(controller.scrollbar.isAtBottom, isTrue);
    });
  });

  group('theme', () {
    test('is pushed into the terminal defaults and palette', () {
      final (:controller, output: _) = _recording();
      final seams = ControllerSeams(controller);
      const theme = VtTerminalTheme.whiteOnBlack;
      controller.theme = theme.copyWith(red: const Color(0xFF102030));
      final colors = seams.updateFrame().colors;
      expect(colors.foreground, VtTerminalTheme.rgbOf(theme.foreground));
      expect(colors.background, VtTerminalTheme.rgbOf(theme.background));
      expect(colors.palette[1], const RgbColor(0x10, 0x20, 0x30));
      expect(colors.palette[16], const RgbColor(0, 0, 0));
      expect(colors.palette[231], const RgbColor(255, 255, 255));
      expect(colors.palette[232], const RgbColor(8, 8, 8));
      expect(colors.palette[255], const RgbColor(238, 238, 238));
      expect(controller.terminal.colorForeground, colors.foreground);
    });

    test('a program colour change wins over the theme default', () {
      final (:controller, output: _) = _recording();
      controller.write('\x1b]10;#ff0000\x1b\\');
      expect(controller.terminal.colorForeground, const RgbColor(0xFF, 0, 0));
    });
  });

  group('selection and viewport', () {
    test('selectAll, selectedText and clearSelection', () {
      final (:controller, output: _) = _recording();
      controller.write('hello\r\nworld');
      expect(controller.selectedText, isNull);
      controller.selectAll();
      expect(controller.selectedText, 'hello\nworld');
      controller.clearSelection();
      expect(controller.selection, isNull);
      expect(controller.selectedText, isNull);
    });

    test('user input scrolls back to the bottom', () {
      final (:controller, output: _) = _recording();
      controller.write(List.generate(30, (i) => 'line $i').join('\r\n'));
      controller.scrollViewport(const ViewportScroll.delta(-5));
      expect(controller.scrollbar.isAtBottom, isFalse);
      controller.sendText('x');
      expect(controller.scrollbar.isAtBottom, isTrue);

      controller.scrollViewport(const ViewportScroll.delta(-5));
      controller.write('\x1b[>11u'); // Kitty: report releases and modifiers
      controller
        ..sendKey(
          const VtKeyEvent(key: VtKey.shiftLeft, modifiers: KeyModifiers.shift),
        )
        ..sendKey(
          const VtKeyEvent(key: VtKey.enter, action: KeyAction.release),
        );
      expect(
        controller.scrollbar.isAtBottom,
        isFalse,
        reason: 'lone modifiers and releases never scroll',
      );
      controller.write('\x1b[<u');

      controller
        ..scrollToBottomOnInput = false
        ..scrollViewport(const ViewportScroll.delta(-5))
        ..sendText('x');
      expect(controller.scrollbar.isAtBottom, isFalse);
    });

    test('alternate screen is reported', () {
      final (:controller, output: _) = _recording();
      expect(controller.isAlternateScreen, isFalse);
      controller.write('\x1b[?1049h');
      expect(controller.isAlternateScreen, isTrue);
    });
  });

  group('lifetime', () {
    test('dispose is idempotent and frees the terminal', () {
      final controller = VtTerminalController();
      final terminal = controller.terminal;
      controller.dispose();
      controller.dispose();
      expect(controller.isDisposed, isTrue);
      expect(terminal.isDisposed, isTrue);
    });

    test('members throw StateError after dispose', () {
      final controller = VtTerminalController()..dispose();
      expect(() => controller.write('x'), throwsStateError);
      expect(() => controller.sendText('x'), throwsStateError);
      expect(
        () => controller.sendKey(const VtKeyEvent(key: VtKey.enter)),
        throwsStateError,
      );
      expect(() => controller.resize(10, 10), throwsStateError);
      expect(() => controller.cols, throwsStateError);
      expect(() => controller.theme, throwsStateError);
      expect(() => controller.selection, throwsStateError);
      expect(() => ControllerSeams(controller), throwsStateError);
    });

    test('a callback may dispose the controller', () {
      final controller = VtTerminalController();
      controller.onOutput = (_) => controller.dispose();
      controller.write('\x1b[6n\x1b[6n');
      expect(controller.isDisposed, isTrue);
    });

    test('invalid arguments throw at construction', () {
      expect(() => VtTerminalController(cols: 0), throwsRangeError);
      expect(
        () => VtTerminalController(macosOptionAsAlt: OptionAsAlt.unknown),
        throwsArgumentError,
      );
    });

    test('scrollback limits', () {
      final controller = VtTerminalController();
      addTearDown(controller.dispose);
      expect(
        controller.terminal.scrollbackMaxBytes,
        VtTerminalController.defaultScrollbackMaxBytes,
      );
      expect(controller.terminal.scrollbackMaxLines, isNull);
      final unlimited = VtTerminalController(
        scrollbackMaxBytes: null,
        scrollbackMaxLines: 1000,
      );
      addTearDown(unlimited.dispose);
      expect(unlimited.terminal.scrollbackMaxBytes, isNull);
      expect(unlimited.terminal.scrollbackMaxLines, 1000);
    });
  });
}
