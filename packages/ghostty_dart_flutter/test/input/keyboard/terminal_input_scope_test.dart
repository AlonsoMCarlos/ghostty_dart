import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart/ghostty_dart.dart';

import 'input_harness.dart';

const _nonApple = TargetPlatformVariant({
  TargetPlatform.linux,
  TargetPlatform.windows,
  TargetPlatform.android,
  TargetPlatform.fuchsia,
});
const _apple = TargetPlatformVariant({
  TargetPlatform.macOS,
  TargetPlatform.iOS,
});

void main() {
  group('hardware keys', () {
    testWidgets('printable keys are encoded with their text (hardware only)', (
      tester,
    ) async {
      final h = await InputHarness.pump(tester, hardwareKeyboardOnly: true);
      expect(
        await tapKey(tester, LogicalKeyboardKey.keyA, character: 'a'),
        isTrue,
      );
      await tapKey(
        tester,
        LogicalKeyboardKey.keyA,
        character: 'A',
        modifiers: [LogicalKeyboardKey.shiftLeft],
      );
      expect(h.sent, 'aA');
    });

    testWidgets('Ctrl+V and Ctrl+A reach the shell', (tester) async {
      final h = await InputHarness.pump(tester);
      FakeClipboard(tester, paste: 'clip');
      await tapKey(
        tester,
        LogicalKeyboardKey.keyV,
        character: 'v',
        modifiers: [LogicalKeyboardKey.controlLeft],
      );
      await tapKey(
        tester,
        LogicalKeyboardKey.keyA,
        character: 'a',
        modifiers: [LogicalKeyboardKey.controlLeft],
      );
      await tester.pump();
      expect(h.output, ['\x16', '\x01']);
    }, variant: TargetPlatformVariant.all());

    testWidgets(
      'Tab, Esc, Enter, Space and arrows are handled, never traversal',
      (tester) async {
        final h = await InputHarness.pump(tester, hardwareKeyboardOnly: true);
        for (final key in [
          LogicalKeyboardKey.tab,
          LogicalKeyboardKey.escape,
          LogicalKeyboardKey.enter,
          LogicalKeyboardKey.arrowDown,
          LogicalKeyboardKey.arrowUp,
        ]) {
          expect(await tapKey(tester, key), isTrue, reason: '$key');
        }
        expect(
          await tapKey(tester, LogicalKeyboardKey.space, character: ' '),
          isTrue,
        );
        await tester.pump();
        expect(h.focusNode.hasFocus, isTrue);
        expect(h.sent, '\t\x1b\r\x1b[B\x1b[A ');
      },
    );

    testWidgets('Tab is handled with a text input connection too', (
      tester,
    ) async {
      final h = await InputHarness.pump(tester);
      expect(h.scopeKey.currentState!.hasTextInputConnection, isTrue);
      expect(await tapKey(tester, LogicalKeyboardKey.tab), isTrue);
      await tester.pump();
      expect(h.focusNode.hasFocus, isTrue);
      expect(h.sent, '\t');
    });

    testWidgets('cursor keys follow DECCKM', (tester) async {
      final h = await InputHarness.pump(tester);
      h.controller.write('\x1b[?1h');
      await tapKey(tester, LogicalKeyboardKey.arrowLeft);
      expect(h.sent, '\x1bOD');
    });

    testWidgets('Kitty: press, repeat and release all reach the encoder', (
      tester,
    ) async {
      final h = await InputHarness.pump(tester, hardwareKeyboardOnly: true);
      // Disambiguate | report events | report all keys as escape codes.
      h.controller.write('\x1b[>11u');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA, character: 'a');
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyA, character: 'a');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
      expect(h.output, ['\x1b[97u', '\x1b[97;1:2u', '\x1b[97;1:3u']);
    });

    testWidgets('Kitty: lone modifiers are reported, press and release', (
      tester,
    ) async {
      final h = await InputHarness.pump(tester);
      h.controller.write('\x1b[>11u');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(h.output, hasLength(2));
      expect(h.output.first, '\x1b[57441;2u');
      expect(h.output.last, startsWith('\x1b[57441;'));
      expect(h.output.last, endsWith(':3u'));
    });

    testWidgets('Kitty 2/8 with a text input connection: printable keys are '
        'encoded, press, repeat and release', (tester) async {
      final h = await InputHarness.pump(tester);
      expect(h.scopeKey.currentState!.hasTextInputConnection, isTrue);
      h.controller.write('\x1b[>11u');
      expect(
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA, character: 'a'),
        isTrue,
      );
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyA, character: 'a');
      expect(await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA), isTrue);
      expect(h.output, ['\x1b[97u', '\x1b[97;1:2u', '\x1b[97;1:3u']);
    });

    testWidgets('Kitty disambiguate only: printable keys stay with the IME', (
      tester,
    ) async {
      final h = await InputHarness.pump(tester);
      h.controller.write('\x1b[>1u');
      expect(
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA, character: 'a'),
        isFalse,
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
      await tester.pump(const Duration(milliseconds: 200));
      expect(h.output, isEmpty);
    });

    testWidgets('AltGr drops Ctrl and Alt on Linux', (tester) async {
      final h = await InputHarness.pump(tester, hardwareKeyboardOnly: true);
      // The Linux key map of flutter_test has no AltGraph; the web one has.
      await tester.sendKeyDownEvent(
        LogicalKeyboardKey.altGraph,
        platform: 'web',
        physicalKey: PhysicalKeyboardKey.altRight,
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyQ, character: '@');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyQ);
      await tester.sendKeyUpEvent(
        LogicalKeyboardKey.altGraph,
        platform: 'web',
        physicalKey: PhysicalKeyboardKey.altRight,
      );
      expect(h.sent, '@');
    }, variant: const TargetPlatformVariant({TargetPlatform.linux}));

    testWidgets('AltGr reported as Ctrl+right Alt drops both on Windows', (
      tester,
    ) async {
      final h = await InputHarness.pump(tester, hardwareKeyboardOnly: true);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altRight);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyQ, character: '@');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyQ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(h.sent, '@');
    }, variant: const TargetPlatformVariant({TargetPlatform.windows}));

    testWidgets('Alt+key sends an ESC prefix', (tester) async {
      final h = await InputHarness.pump(tester);
      await tapKey(
        tester,
        LogicalKeyboardKey.keyB,
        character: 'b',
        modifiers: [LogicalKeyboardKey.altLeft],
      );
      expect(h.sent, '\x1bb');
    }, variant: const TargetPlatformVariant({TargetPlatform.linux}));

    testWidgets('latched toolbar modifiers apply to the next key once', (
      tester,
    ) async {
      final h = await InputHarness.pump(tester, hardwareKeyboardOnly: true);
      h.seams.latchedModifiers.value = KeyModifiers.ctrl;
      await tapKey(tester, LogicalKeyboardKey.keyC, character: 'c');
      expect(h.seams.latchedModifiers.value, KeyModifiers.none);
      await tapKey(tester, LogicalKeyboardKey.keyC, character: 'c');
      expect(h.output, ['\x03', 'c']);
    });

    testWidgets('a latched Ctrl takes the key from the text input', (
      tester,
    ) async {
      final h = await InputHarness.pump(tester);
      h.seams.latchedModifiers.value = KeyModifiers.ctrl;
      expect(
        await tapKey(tester, LogicalKeyboardKey.keyD, character: 'd'),
        isTrue,
      );
      expect(h.sent, '\x04');
    });

    testWidgets('unidentified keys without text are ignored', (tester) async {
      final h = await InputHarness.pump(tester, hardwareKeyboardOnly: true);
      expect(await tapKey(tester, LogicalKeyboardKey.brightnessUp), isFalse);
      expect(h.output, isEmpty);
    });
  });

  group('shortcuts', () {
    Future<InputHarness> withSelection(WidgetTester tester) async {
      final h = await InputHarness.pump(tester);
      h.controller
        ..write('hello')
        ..selectAll();
      return h;
    }

    testWidgets('Ctrl+Shift+C and Ctrl+Insert copy; paste with Ctrl+Shift+V '
        'and Shift+Insert', (tester) async {
      final h = await withSelection(tester);
      final clipboard = FakeClipboard(tester, paste: 'pasted');
      await tapKey(
        tester,
        LogicalKeyboardKey.keyC,
        character: 'C',
        modifiers: [
          LogicalKeyboardKey.controlLeft,
          LogicalKeyboardKey.shiftLeft,
        ],
      );
      await tapKey(
        tester,
        LogicalKeyboardKey.insert,
        modifiers: [LogicalKeyboardKey.controlLeft],
      );
      await tester.pump();
      expect(clipboard.copied, ['hello', 'hello']);
      await tapKey(
        tester,
        LogicalKeyboardKey.keyV,
        character: 'V',
        modifiers: [
          LogicalKeyboardKey.controlLeft,
          LogicalKeyboardKey.shiftLeft,
        ],
      );
      await tapKey(
        tester,
        LogicalKeyboardKey.insert,
        modifiers: [LogicalKeyboardKey.shiftLeft],
      );
      await tester.pump();
      expect(h.output, ['pasted', 'pasted']);
    }, variant: _nonApple);

    testWidgets('Cmd+C copies and Cmd+V pastes on Apple platforms', (
      tester,
    ) async {
      final h = await withSelection(tester);
      final clipboard = FakeClipboard(tester, paste: 'pasted');
      await tapKey(
        tester,
        LogicalKeyboardKey.keyC,
        character: 'c',
        modifiers: [LogicalKeyboardKey.metaLeft],
      );
      await tapKey(
        tester,
        LogicalKeyboardKey.keyV,
        character: 'v',
        modifiers: [LogicalKeyboardKey.metaLeft],
      );
      await tester.pump();
      expect(clipboard.copied, ['hello']);
      expect(h.output, ['pasted']);
      // Ctrl+V is the shell's.
      await tapKey(
        tester,
        LogicalKeyboardKey.keyV,
        character: 'v',
        modifiers: [LogicalKeyboardKey.controlLeft],
      );
      await tester.pump();
      expect(h.output, ['pasted', '\x16']);
    }, variant: _apple);

    testWidgets('copy without a selection falls through to the program', (
      tester,
    ) async {
      final h = await InputHarness.pump(tester);
      final clipboard = FakeClipboard(tester);
      await tapKey(
        tester,
        LogicalKeyboardKey.insert,
        modifiers: [LogicalKeyboardKey.controlLeft],
      );
      await tester.pump();
      expect(clipboard.copied, isEmpty);
      expect(h.sent, '\x1b[2;5~');
    }, variant: const TargetPlatformVariant({TargetPlatform.linux}));

    testWidgets('an unsafe paste asks onUnsafePaste, else is dropped', (
      tester,
    ) async {
      final asked = <String>[];
      var allow = false;
      final h = await InputHarness.pump(
        tester,
        onUnsafePaste: (text) async {
          asked.add(text);
          return allow;
        },
      );
      FakeClipboard(tester, paste: 'rm -rf x\n');
      Future<void> paste() async {
        await tapKey(
          tester,
          LogicalKeyboardKey.insert,
          modifiers: [LogicalKeyboardKey.shiftLeft],
        );
        await tester.pump();
      }

      await paste();
      expect(asked, ['rm -rf x\n']);
      expect(h.output, isEmpty);
      allow = true;
      await paste();
      expect(h.sent, 'rm -rf x\r');
    }, variant: const TargetPlatformVariant({TargetPlatform.linux}));

    testWidgets('shortcuts replaces the default policy', (tester) async {
      final h = await InputHarness.pump(
        tester,
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.keyV, control: true):
              PasteTextIntent(SelectionChangedCause.keyboard),
        },
      );
      FakeClipboard(tester, paste: 'xterm');
      await tapKey(
        tester,
        LogicalKeyboardKey.keyV,
        character: 'v',
        modifiers: [LogicalKeyboardKey.controlLeft],
      );
      await tester.pump();
      expect(h.output, ['xterm']);
      // The default Shift+Insert is gone: the key is encoded.
      await tapKey(
        tester,
        LogicalKeyboardKey.insert,
        modifiers: [LogicalKeyboardKey.shiftLeft],
      );
      await tester.pump();
      expect(h.output, ['xterm', '\x1b[2;2~']);
    }, variant: const TargetPlatformVariant({TargetPlatform.linux}));

    testWidgets('onKeyEvent runs first; handled stops encoding', (
      tester,
    ) async {
      final seen = <LogicalKeyboardKey>[];
      final h = await InputHarness.pump(
        tester,
        hardwareKeyboardOnly: true,
        onKeyEvent: (node, event) {
          seen.add(event.logicalKey);
          return event.logicalKey == LogicalKeyboardKey.keyX
              ? KeyEventResult.handled
              : KeyEventResult.ignored;
        },
      );
      expect(
        await tapKey(tester, LogicalKeyboardKey.keyX, character: 'x'),
        isTrue,
      );
      await tapKey(tester, LogicalKeyboardKey.keyY, character: 'y');
      expect(h.sent, 'y');
      expect(seen, [
        LogicalKeyboardKey.keyX,
        LogicalKeyboardKey.keyX,
        LogicalKeyboardKey.keyY,
        LogicalKeyboardKey.keyY,
      ]);
    });
  });

  group('focus, readOnly, hardwareKeyboardOnly', () {
    testWidgets('focus changes are reported (DEC 1004)', (tester) async {
      final h = await InputHarness.pump(tester, focus: false);
      h.controller.write('\x1b[?1004h');
      h.focusNode.requestFocus();
      await tester.pump();
      h.otherNode.requestFocus();
      await tester.pump();
      expect(h.output, ['\x1b[I', '\x1b[O']);
    });

    testWidgets('readOnly sends nothing but still copies', (tester) async {
      final h = await InputHarness.pump(tester, readOnly: true);
      h.controller
        ..write('\x1b[?1004hro')
        ..selectAll();
      final clipboard = FakeClipboard(tester, paste: 'p');
      expect(h.scopeKey.currentState!.hasTextInputConnection, isFalse);
      expect(tester.testTextInput.hasAnyClients, isFalse);
      expect(
        await tapKey(tester, LogicalKeyboardKey.keyA, character: 'a'),
        isFalse,
      );
      await tapKey(
        tester,
        LogicalKeyboardKey.insert,
        modifiers: [LogicalKeyboardKey.shiftLeft],
      );
      await tapKey(
        tester,
        LogicalKeyboardKey.insert,
        modifiers: [LogicalKeyboardKey.controlLeft],
      );
      h.otherNode.requestFocus();
      await tester.pump();
      expect(h.output, isEmpty);
      expect(clipboard.copied, ['ro']);
    }, variant: const TargetPlatformVariant({TargetPlatform.linux}));

    testWidgets('hardwareKeyboardOnly opens no text input connection', (
      tester,
    ) async {
      final h = await InputHarness.pump(tester, hardwareKeyboardOnly: true);
      expect(h.scopeKey.currentState!.hasTextInputConnection, isFalse);
      expect(tester.testTextInput.hasAnyClients, isFalse);
      h.scopeKey.currentState!.requestKeyboard();
      await tester.pump();
      expect(tester.testTextInput.hasAnyClients, isFalse);
    });

    testWidgets('a disposed controller makes the keys no-ops', (tester) async {
      final h = await InputHarness.pump(tester, hardwareKeyboardOnly: true);
      h.controller.dispose();
      expect(
        await tapKey(tester, LogicalKeyboardKey.keyA, character: 'a'),
        isFalse,
      );
      expect(h.output, isEmpty);
    });
  });
}
