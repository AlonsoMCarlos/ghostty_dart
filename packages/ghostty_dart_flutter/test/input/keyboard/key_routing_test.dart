import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart_flutter/src/input/keyboard/terminal_input_scope.dart';

import 'input_harness.dart';

const _linux = TargetPlatformVariant({TargetPlatform.linux});

/// Sends the macOS/iOS `performSelectors` message as the engine does.
Future<void> _performSelector(WidgetTester tester, String selector) async {
  final client =
      tester.testTextInput.log
              .lastWhere((call) => call.method == 'TextInput.setClient')
              .arguments
          as List<Object?>;
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    SystemChannels.textInput.name,
    SystemChannels.textInput.codec.encodeMethodCall(
      MethodCall('TextInputClient.performSelectors', <Object?>[
        client[0],
        [selector],
      ]),
    ),
    (_) {},
  );
  await tester.pump();
}

void main() {
  group('order with text the platform has not committed yet', () {
    testWidgets('an encoded key waits for the text of an earlier key', (
      tester,
    ) async {
      final h = await InputHarness.pump(tester);
      // "l" and "s" go to the platform text input; Enter is encoded.
      expect(
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyL, character: 'l'),
        isFalse,
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyL);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyS, character: 's');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyS);
      expect(await tapKey(tester, LogicalKeyboardKey.enter), isTrue);
      expect(h.output, isEmpty);
      // The platform commits late, one key at a time.
      await sendDeltas(tester, [delta('  ', 'l', 2, 2)]);
      expect(h.output, ['l']);
      await sendDeltas(tester, [delta('  ', 's', 2, 2)]);
      expect(h.output, ['l', 's', '\r']);
    });

    testWidgets('text committed in one update answers several keys', (
      tester,
    ) async {
      final h = await InputHarness.pump(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyL, character: 'l');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyS, character: 's');
      await tapKey(tester, LogicalKeyboardKey.arrowLeft);
      await sendDeltas(tester, [delta('  ', 'ls', 2, 2)]);
      expect(h.output, ['ls', '\x1b[D']);
    });

    testWidgets('without a commit the keys go after the timeout', (
      tester,
    ) async {
      final h = await InputHarness.pump(tester);
      // A dead key: the platform produces nothing yet.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.quote);
      await tapKey(tester, LogicalKeyboardKey.tab);
      expect(h.output, isEmpty);
      await tester.pump(TerminalInputScope.commitTimeout);
      expect(h.output, ['\t']);
    });

    testWidgets('a composition start releases the waiting keys', (
      tester,
    ) async {
      final h = await InputHarness.pump(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyN, character: 'n');
      await sendDeltas(tester, [
        delta('  ', 'n', 2, 2, composingBase: 2, composingExtent: 3),
      ]);
      // While composing, keys belong to the IME and nothing waits.
      expect(h.output, isEmpty);
      await sendDeltas(tester, [delta('  n', 'ん', 2, 3)]);
      expect(h.output, ['ん']);
    });

    testWidgets('a paste keeps its place while the clipboard is read', (
      tester,
    ) async {
      final h = await InputHarness.pump(tester, hardwareKeyboardOnly: true);
      final clipboard = FakeClipboard(tester, paste: 'P')
        ..gate = Completer<void>();
      await tapKey(
        tester,
        LogicalKeyboardKey.insert,
        modifiers: [LogicalKeyboardKey.shiftLeft],
      );
      await tapKey(tester, LogicalKeyboardKey.keyX, character: 'x');
      expect(h.output, isEmpty);
      clipboard.gate!.complete();
      await tester.pump();
      expect(h.output, ['P', 'x']);
    }, variant: _linux);

    testWidgets('a fast second delta before the reset is sent once', (
      tester,
    ) async {
      final h = await InputHarness.pump(tester);
      await sendDeltas(tester, [delta('  ', 'a', 2, 2)]);
      // The platform had not seen the reset to the sentinel yet.
      await sendDeltas(tester, [delta('  a', 'b', 3, 3)]);
      expect(h.output, ['a', 'b']);
    });
  });

  group('handled only when the terminal used the key', () {
    testWidgets('Cmd+Q reaches the platform on macOS', (tester) async {
      final h = await InputHarness.pump(tester);
      expect(
        await tapKey(
          tester,
          LogicalKeyboardKey.keyQ,
          character: 'q',
          modifiers: [LogicalKeyboardKey.metaLeft],
        ),
        isFalse,
      );
      expect(h.output, isEmpty);
    }, variant: const TargetPlatformVariant({TargetPlatform.macOS}));

    testWidgets('media and volume keys reach the platform', (tester) async {
      final h = await InputHarness.pump(tester, hardwareKeyboardOnly: true);
      expect(await tapKey(tester, LogicalKeyboardKey.audioVolumeUp), isFalse);
      expect(await tapKey(tester, LogicalKeyboardKey.mediaPlayPause), isFalse);
      expect(h.output, isEmpty);
      // The volume rocker of an Android device with a hardware keyboard.
    }, variant: const TargetPlatformVariant({TargetPlatform.android}));
  });

  group('copy shortcut without a selection', () {
    testWidgets('Ctrl+Shift+C is consumed and sends nothing', (tester) async {
      final h = await InputHarness.pump(tester);
      final clipboard = FakeClipboard(tester);
      expect(
        await tapKey(
          tester,
          LogicalKeyboardKey.keyC,
          character: 'C',
          modifiers: [
            LogicalKeyboardKey.controlLeft,
            LogicalKeyboardKey.shiftLeft,
          ],
        ),
        isTrue,
      );
      await tester.pump();
      expect(h.output, isEmpty);
      expect(clipboard.copied, isEmpty);
    }, variant: _linux);

    testWidgets('Cmd+C is consumed and sends nothing', (tester) async {
      final h = await InputHarness.pump(tester);
      FakeClipboard(tester);
      expect(
        await tapKey(
          tester,
          LogicalKeyboardKey.keyC,
          character: 'c',
          modifiers: [LogicalKeyboardKey.metaLeft],
        ),
        isTrue,
      );
      expect(h.output, isEmpty);
    }, variant: const TargetPlatformVariant({TargetPlatform.macOS}));
  });

  group('Option on Apple platforms', () {
    testWidgets('macOS: Option is a text modifier, dead keys compose', (
      tester,
    ) async {
      final h = await InputHarness.pump(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      // Option+e: a dead key, left to the platform text input.
      expect(await tester.sendKeyDownEvent(LogicalKeyboardKey.keyE), isFalse);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyE);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await sendDeltas(tester, [delta('  ', 'é', 2, 2)]);
      expect(h.output, ['é']);
    }, variant: const TargetPlatformVariant({TargetPlatform.macOS}));

    testWidgets('iOS: Option+l types "@" through the text input', (
      tester,
    ) async {
      final h = await InputHarness.pump(tester);
      expect(
        await tapKey(
          tester,
          LogicalKeyboardKey.keyL,
          character: '@',
          modifiers: [LogicalKeyboardKey.altLeft],
        ),
        isFalse,
      );
      await sendDeltas(tester, [delta('  ', '@', 2, 2)]);
      expect(h.output, ['@']);
    }, variant: const TargetPlatformVariant({TargetPlatform.iOS}));

    testWidgets('iOS with Option as Alt sends ESC and the key', (tester) async {
      final h = await InputHarness.pump(
        tester,
        macosOptionAsAlt: () => OptionAsAlt.both,
      );
      expect(
        await tapKey(
          tester,
          LogicalKeyboardKey.keyW,
          character: '∑',
          modifiers: [LogicalKeyboardKey.altLeft],
        ),
        isTrue,
      );
      expect(h.output, ['\x1bw']);
    }, variant: const TargetPlatformVariant({TargetPlatform.iOS}));

    testWidgets('Option+arrow stays Alt', (tester) async {
      final h = await InputHarness.pump(tester);
      await tapKey(
        tester,
        LogicalKeyboardKey.arrowLeft,
        modifiers: [LogicalKeyboardKey.altLeft],
      );
      expect(h.output, ['\x1b[1;3D']);
    }, variant: const TargetPlatformVariant({TargetPlatform.macOS}));
  });

  testWidgets('Windows: Ctrl+right Alt without a character is not AltGr', (
    tester,
  ) async {
    final h = await InputHarness.pump(tester, hardwareKeyboardOnly: true);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altRight);
    // A US layout has no AltGr: Win32 produces no character (the
    // simulator would invent one from the logical key otherwise).
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyX, character: '');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyX);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(h.output, ['\x1b\x18']);
  }, variant: const TargetPlatformVariant({TargetPlatform.windows}));

  group('releases, repeats and focus', () {
    testWidgets('releases are sent while the IME composes', (tester) async {
      final h = await InputHarness.pump(tester);
      h.controller.write('\x1b[>11u');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await sendDeltas(tester, [
        delta('  ', 'k', 2, 2, composingBase: 2, composingExtent: 3),
      ]);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(h.output, hasLength(2));
      expect(h.output.last, endsWith(':3u'));
    });

    testWidgets('a repeat follows its press to the platform', (tester) async {
      final h = await InputHarness.pump(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA, character: 'a');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      expect(
        await tester.sendKeyRepeatEvent(
          LogicalKeyboardKey.keyA,
          character: 'a',
        ),
        isFalse,
      );
      await tester.pump(TerminalInputScope.commitTimeout);
      expect(h.output, isEmpty);
    });

    testWidgets('swapping the focus node reports and closes', (tester) async {
      final h = await InputHarness.pump(tester);
      h.controller.write('\x1b[?1004h');
      final other = FocusNode();
      addTearDown(other.dispose);
      await tester.pumpWidget(h.build(focusNode: other));
      await tester.pump();
      expect(h.output, ['\x1b[O']);
      expect(tester.testTextInput.hasAnyClients, isFalse);
      other.requestFocus();
      await tester.pump();
      expect(h.output, ['\x1b[O', '\x1b[I']);
      expect(tester.testTextInput.hasAnyClients, isTrue);
    });
  });

  group('macOS selectors go through the encoder', () {
    testWidgets('deleteBackward: and insertNewline:', (tester) async {
      final h = await InputHarness.pump(tester);
      await _performSelector(tester, 'deleteBackward:');
      await _performSelector(tester, 'insertNewline:');
      expect(h.output, ['\x7f', '\r']);
      // Enter is a key event: Kitty "report all" encodes it.
      h.controller.write('\x1b[>8u');
      await _performSelector(tester, 'insertNewline:');
      expect(h.output.last, '\x1b[13u');
    });
  });
}
