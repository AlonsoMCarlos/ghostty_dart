import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_dart/ghostty_dart.dart';
import 'package:ghostty_dart_flutter/src/seams/terminal_seams.dart';

import '../keyboard/input_harness.dart';

Map<String, Object?> clientConfig(WidgetTester tester) =>
    tester.testTextInput.setClientArgs!;

void main() {
  group('connection', () {
    testWidgets(
      'opens on focus with the terminal configuration',
      (tester) async {
        final h = await InputHarness.pump(tester);
        expect(tester.testTextInput.hasAnyClients, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);
        final config = clientConfig(tester);
        expect(config['enableDeltaModel'], isTrue);
        expect(config['autocorrect'], isFalse);
        expect(config['enableSuggestions'], isFalse);
        expect(config['enableIMEPersonalizedLearning'], isFalse);
        expect(config['smartDashesType'], '0');
        expect(config['smartQuotesType'], '0');
        expect(config['obscureText'], isFalse);
        expect(config['viewId'], tester.view.viewId);
        expect(
          (config['inputType']! as Map<Object?, Object?>)['name'],
          defaultTargetPlatform == TargetPlatform.android
              ? 'TextInputType.visiblePassword'
              : 'TextInputType.text',
        );
        // The sentinel, caret at its end.
        expect(tester.testTextInput.editingState!['text'], '  ');
        expect(tester.testTextInput.editingState!['selectionBase'], 2);
        // Losing focus closes it.
        h.otherNode.requestFocus();
        await tester.pump();
        expect(tester.testTextInput.hasAnyClients, isFalse);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.linux,
      }),
    );

    testWidgets('closeKeyboard and requestKeyboard', (tester) async {
      final h = await InputHarness.pump(tester);
      final state = h.scopeKey.currentState!..closeKeyboard();
      await tester.pump();
      expect(tester.testTextInput.hasAnyClients, isFalse);
      expect(h.focusNode.hasFocus, isTrue);
      state.requestKeyboard();
      await tester.pump();
      expect(tester.testTextInput.hasAnyClients, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
    });
  });

  group('committed text', () {
    testWidgets('an insertion is sent and the state reset', (tester) async {
      final h = await InputHarness.pump(tester);
      await sendDeltas(tester, [delta('  ', 'é', 2, 2)]);
      expect(h.output, ['é']);
      expect(tester.testTextInput.editingState!['text'], '  ');
    });

    testWidgets('whole-value updates work too (no delta support)', (
      tester,
    ) async {
      final h = await InputHarness.pump(tester);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '  ok',
          selection: TextSelection.collapsed(offset: 4),
        ),
      );
      await tester.pump();
      expect(h.output, ['ok']);
    });

    testWidgets('deleting sentinel characters sends one Backspace each', (
      tester,
    ) async {
      final h = await InputHarness.pump(tester);
      await sendDeltas(tester, [delta('  ', '', 1, 2)]);
      expect(h.output, ['\x7f']);
      // Samsung's deleteSurroundingText(2).
      await sendDeltas(tester, [delta('  ', '', 0, 2)]);
      expect(h.output, ['\x7f', '\x7f', '\x7f']);
      // DECBKM: Backspace sends BS.
      h.controller.write('\x1b[?67h');
      await sendDeltas(tester, [delta('  ', '', 1, 2)]);
      expect(h.output.last, '\x08');
    });

    testWidgets('a soft-keyboard newline is a carriage return', (tester) async {
      final h = await InputHarness.pump(tester);
      await sendDeltas(tester, [delta('  ', 'ls\n', 2, 2)]);
      expect(h.sent, 'ls\r');
      await tester.testTextInput.receiveAction(TextInputAction.newline);
      await tester.pump();
      expect(h.sent, 'ls\r\r');
    });

    testWidgets('a latched Ctrl turns the next character into a key', (
      tester,
    ) async {
      final h = await InputHarness.pump(tester);
      h.seams.latchedModifiers.value = KeyModifiers.ctrl;
      await sendDeltas(tester, [delta('  ', 'c', 2, 2)]);
      expect(h.output, ['\x03']);
      expect(h.seams.latchedModifiers.value, KeyModifiers.none);
      await sendDeltas(tester, [delta('  ', 'c', 2, 2)]);
      expect(h.output, ['\x03', 'c']);
    });

    testWidgets('readOnly opens no connection', (tester) async {
      await InputHarness.pump(tester, readOnly: true);
      expect(tester.testTextInput.hasAnyClients, isFalse);
    });
  });

  group('composing', () {
    testWidgets('the preedit is drawn at the cursor and committed', (
      tester,
    ) async {
      const style = TextStyle(fontFamily: 'TestMono', fontSize: 14);
      final h = await InputHarness.pump(tester, textStyle: style);
      h.controller.write('abc');
      await tester.pump();
      await sendDeltas(tester, [
        delta('  ', 'に', 2, 2, composingBase: 2, composingExtent: 3),
      ]);
      expect(h.output, isEmpty);
      expect(h.composing, [true]);
      final preedit = find.byKey(
        const ValueKey('ghostty_dart_flutter.composing'),
      );
      expect(preedit, findsOneWidget);
      final text = tester.widget<Text>(preedit);
      expect(text.data, 'に');
      expect(text.style!.fontFamily, 'TestMono');
      expect(text.style!.decoration, TextDecoration.underline);
      // At the cursor cell: column 3, row 0, 10 × 20 cells.
      expect(tester.getTopLeft(preedit), scopeOffset + const Offset(30, 0));
      // While composing, keys belong to the IME.
      expect(await tapKey(tester, LogicalKeyboardKey.enter), isFalse);
      expect(h.output, isEmpty);
      // The IME commits the conversion.
      await sendDeltas(tester, [delta('  に', '日本', 2, 3)]);
      expect(h.output, ['日本']);
      expect(h.composing, [true, false]);
      expect(preedit, findsNothing);
      expect(tester.testTextInput.editingState!['text'], '  ');
    });

    testWidgets('a collapsed composing region commits (Android)', (
      tester,
    ) async {
      final h = await InputHarness.pump(tester);
      await sendDeltas(tester, [
        delta('  ', 'hi', 2, 2, composingBase: 2, composingExtent: 4),
      ]);
      expect(h.output, isEmpty);
      await sendDeltas(tester, [delta('  hi', '', -1, -1, caret: 4)]);
      expect(h.output, ['hi']);
      expect(h.composing, [true, false]);
    });
  });

  group('IME rectangles', () {
    testWidgets('caret and composing rects follow the cursor, once per frame', (
      tester,
    ) async {
      final h = await InputHarness.pump(tester);
      await tester.pump();
      List<MethodCall> calls(String method) => tester.testTextInput.log
          .where((call) => call.method == method)
          .toList();

      final transform = calls('TextInput.setEditableSizeAndTransform').last;
      final args = transform.arguments as Map<Object?, Object?>;
      expect(args['width'], h.geometry.viewSize.width);
      expect(args['height'], h.geometry.viewSize.height);
      final matrix = (args['transform']! as List<Object?>).cast<double>();
      expect(matrix[12], scopeOffset.dx);
      expect(matrix[13], scopeOffset.dy);
      Map<Object?, Object?> lastCaret() =>
          calls('TextInput.setCaretRect').last.arguments
              as Map<Object?, Object?>;
      expect(lastCaret(), {'x': 0.0, 'y': 0.0, 'width': 10.0, 'height': 20.0});

      tester.testTextInput.log.clear();
      h.controller
        ..write('ab')
        ..write('\r\ncd');
      await tester.pump();
      await tester.idle(); // the platform messages are delivered async
      expect(calls('TextInput.setCaretRect'), hasLength(1));
      expect(calls('TextInput.setMarkedTextRect'), hasLength(1));
      expect(lastCaret(), {
        'x': 20.0,
        'y': 20.0,
        'width': 10.0,
        'height': 20.0,
      });
      // Nothing moved: nothing sent.
      tester.testTextInput.log.clear();
      h.controller.write('\x1b[m');
      await tester.pump();
      await tester.idle();
      expect(calls('TextInput.setCaretRect'), isEmpty);
    });

    testWidgets('password input sets obscureText', (tester) async {
      final sink = _PasswordSink();
      await InputHarness.pump(tester, text: sink);
      expect(clientConfig(tester)['obscureText'], isFalse);
      sink.password = true;
      await tester.pump();
      expect(clientConfig(tester)['obscureText'], isTrue);
      expect(clientConfig(tester)['enableSuggestions'], isFalse);
    });
  });

  group('widget updates', () {
    testWidgets('dispose while composing does not notify', (tester) async {
      final h = await InputHarness.pump(tester);
      await sendDeltas(tester, [
        delta('  ', 'に', 2, 2, composingBase: 2, composingExtent: 3),
      ]);
      expect(h.composing, [true]);
      await tester.pumpWidget(const SizedBox());
      expect(h.composing, [true]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('deleteDetection false idles at an empty text', (tester) async {
      final h = await InputHarness.pump(tester);
      expect(tester.testTextInput.editingState!['text'], '  ');
      await tester.pumpWidget(h.build(deleteDetection: false));
      await tester.pump();
      expect(tester.testTextInput.hasAnyClients, isTrue);
      expect(tester.testTextInput.editingState!['text'], '');
    });

    testWidgets('keyboardType and keyboardAppearance update the config', (
      tester,
    ) async {
      final h = await InputHarness.pump(tester);
      await tester.pumpWidget(
        h.build(
          keyboardType: TextInputType.emailAddress,
          keyboardAppearance: Brightness.dark,
        ),
      );
      await tester.pump();
      final config = clientConfig(tester);
      expect(
        (config['inputType']! as Map<Object?, Object?>)['name'],
        'TextInputType.emailAddress',
      );
      expect(config['keyboardAppearance'], 'Brightness.dark');
    });

    testWidgets('readOnly and hardwareKeyboardOnly close a live connection', (
      tester,
    ) async {
      final h = await InputHarness.pump(tester);
      await tester.pumpWidget(h.build(readOnly: true));
      expect(tester.testTextInput.hasAnyClients, isFalse);
      await tester.pumpWidget(h.build());
      expect(tester.testTextInput.hasAnyClients, isTrue);
      await tester.pumpWidget(h.build(hardwareKeyboardOnly: true));
      expect(tester.testTextInput.hasAnyClients, isFalse);
    });

    testWidgets('composingBackgroundColor fills behind the preedit', (
      tester,
    ) async {
      final h = await InputHarness.pump(tester);
      await tester.pumpWidget(
        h.build(composingBackgroundColor: const Color(0xFF123456)),
      );
      await sendDeltas(tester, [
        delta('  ', 'k', 2, 2, composingBase: 2, composingExtent: 3),
      ]);
      final fill = find.ancestor(
        of: find.byKey(const ValueKey('ghostty_dart_flutter.composing')),
        matching: find.byType(ColoredBox),
      );
      expect(tester.widget<ColoredBox>(fill).color, const Color(0xFF123456));
    });
  });
}

/// A text sink whose password heuristic the test controls.
class _PasswordSink extends Fake
    with ChangeNotifier
    implements TerminalTextSink {
  bool _password = false;

  set password(bool value) {
    _password = value;
    notifyListeners();
  }

  @override
  bool get isPasswordInput => _password;

  @override
  bool get isDisposed => false;

  @override
  GridPoint? get cursorViewportCell => const GridPoint.viewport(0, 0);

  @override
  void sendFocus({required bool focused}) {}
}
